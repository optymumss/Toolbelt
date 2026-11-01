import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A download manager: fast downloads in several parts at once, that pause, resume and survive restarts.
@MainActor
final class DownloadsModule: ToolbeltModule {
    let id = ModuleID.downloads
    let openTitle = "Downloads…"

    let manager = DownloadManager()
    let notifier = DownloadNotifier()
    private(set) lazy var inbox = BrowserInbox { [weak self] request in self?.received(request) }
    private var window: NSWindow?
    private var badgeWatcher: AnyCancellable?
    /// 0.34: notices copied links to files (only while "Offer to download copied links" is on).
    private let clipboard = ClipboardWatcher()

    func start() {
        manager.onFinished = { [weak self] item in self?.notifier.finished(item) }
        manager.onAllDone = { [weak self] action in self?.confirm(action) }
        manager.onLowSpace = { free in
            DownloadNotifier.post(id: "toolbelt-low-space", title: "Downloads paused: your Mac is nearly full",
                                  body: "Only \(ByteFormat.size(free)) left. They'll carry on by themselves once you free up some space.", path: nil)
        }
        notifier.setUp()
        ChromeSetup.refreshIfSetUp()
        inbox.start()
        manager.resumeInterrupted()
        badgeWatcher = manager.$items.sink { items in
            MenuBarBadge.shared.show(active: Self.isActive(items), progress: Self.progress(of: items))
        }
        clipboard.onChange = { [weak self] text in self?.copied(text) }
        refreshClipboardCatching()
        LinkPickerWindows.registerTestHooks(manager: manager)
        GrabberWindow.registerTestHooks(manager: manager)
        LinkOfferPanel.registerTestHooks()
        RealUseHooks.commands["catch-clipboard"] = { [weak self] value in
            Prefs.downloadCatchClipboard = value == "on"
            self?.refreshClipboardCatching()
        }
    }

    /// Starts or stops watching the clipboard, following the setting.
    func refreshClipboardCatching() {
        if Prefs.downloadCatchClipboard { clipboard.start() } else { clipboard.stop() }
    }

    /// Something was copied: offer to download a link to a file, or to choose from several links.
    func copied(_ text: String) {
        switch ClipboardLinks.offer(for: text, extensions: Set(Prefs.downloadCatchExtensions)) {
        case .none:
            break
        case .one(let url):
            let link = FoundLink(url: url)
            LinkOfferPanel.show(message: "Download \(link.name)?", detail: url.host ?? url.absoluteString, button: "Download") { [weak self] in
                guard self?.manager.add(url.absoluteString) != nil else { return }
                MenuBarBadge.shared.flash()
            }
        case .several(let urls):
            LinkOfferPanel.show(message: "\(urls.count) links copied", detail: "Choose which to download", button: "Choose…") { [weak self] in
                self?.chooseLinks(urls.map { FoundLink(url: $0) }, title: "\(urls.count) copied links")
            }
        }
    }

    /// Opens the list of links to tick.
    func chooseLinks(_ links: [FoundLink], title: String, page: String? = nil, activate: Bool = true,
                     headers: @escaping (URL) -> [String: String] = { _ in [:] }) {
        LinkPickerWindows.show(LinkPickerModel(title: title, links: links, page: page, headers: headers), manager: manager, activate: activate)
    }

    func openGrabber(address: String? = nil) {
        GrabberWindow.show(manager: manager, address: address)
    }

    /// Opens a page in Chrome (where the extension can start the download again), or the default browser.
    static func openInChrome(_ page: URL) {
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(page)
        }
    }

    static func isActive(_ items: [DownloadItem]) -> Bool { items.contains { $0.state == .downloading } }

    /// How far all running downloads have got together, when their sizes are known.
    static func progress(of items: [DownloadItem]) -> Double? {
        let active = items.filter { $0.state == .downloading }
        guard !active.isEmpty, active.allSatisfy({ ($0.total ?? 0) > 0 }) else { return nil }
        let total = active.reduce(Int64(0)) { $0 + ($1.total ?? 0) }
        return min(1, Double(active.reduce(Int64(0)) { $0 + $1.received }) / Double(total))
    }

    func stop() {
        badgeWatcher = nil
        MenuBarBadge.shared.show(active: false, progress: nil)
        inbox.stop()
        clipboard.stop()
        LinkOfferPanel.close()
        manager.stopAll()
        window?.orderOut(nil)
    }

    /// A link from the Chrome extension: download it and show the list, without taking the focus from Chrome.
    /// From the video button the list stays hidden: progress shows next to the menu bar icon instead.
    func received(_ request: DownloadRequest) {
        // "Download All Links with Toolbelt": choose from the page's links (without taking the focus from Chrome).
        if request.links != nil {
            let links = request.foundLinks
            guard !links.isEmpty else { return }
            let title = (request.title?.isEmpty == false ? request.title! : URL(string: request.url)?.host) ?? "Links"
            chooseLinks(links, title: title, page: request.url, activate: false, headers: request.headers(for:))
            return
        }
        guard manager.add(request.url, name: request.name, headers: request.headers,
                          stream: request.kind == "hls", audio: request.audioUrl, page: request.referrer) != nil else { return }
        if request.quiet == true {
            MenuBarBadge.shared.flash()
            return
        }
        makeWindow()
        window?.orderFrontRegardless()
    }

    /// Everything has finished and "when done" was set: count down a minute, then sleep or shut down.
    private func confirm(_ action: WhenDone) {
        guard action != .nothing else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Downloads finished"
        alert.addButton(withTitle: action == .sleep ? "Sleep Now" : "Shut Down Now")
        alert.addButton(withTitle: "Cancel")
        let countdown = Countdown()
        let verb = action == .sleep ? "go to sleep" : "shut down"
        alert.informativeText = "Your Mac will \(verb) in \(countdown.seconds) seconds."
        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                countdown.seconds -= 1
                alert.informativeText = "Your Mac will \(verb) in \(countdown.seconds) seconds."
                if countdown.seconds <= 0 {
                    timer.invalidate()
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let answer = alert.runModal()
        timer.invalidate()
        if answer == .alertFirstButtonReturn { action.perform() }
    }

    private func makeWindow() {
        if window == nil {
            let view = DownloadsView(manager: manager)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Downloads"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 700, height: 460))
            window.center()
            window.setFrameAutosaveName("ToolbeltDownloads")
            self.window = window
        }
    }

    func open() {
        makeWindow()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Starts a download from the link on the clipboard, or lists the links when there are several.
    func downloadFromClipboard() {
        let links = ClipboardLinks.links(in: NSPasteboard.general.string(forType: .string) ?? "")
        if links.count > 1 {
            chooseLinks(links.map { FoundLink(url: $0) }, title: "\(links.count) copied links")
        } else if let link = links.first, manager.add(link.absoluteString) != nil {
            open()
        } else {
            NSSound.beep()
        }
    }

    func menuItems() -> [NSMenuItem] {
        var list: [NSMenuItem] = [ActionMenuItem("Download Link from Clipboard") { [weak self] in self?.downloadFromClipboard() },
                                  ActionMenuItem("Site Grabber…") { [weak self] in self?.openGrabber() }]
        let active = manager.items.filter { $0.state == .downloading }
        let whenDone = NSMenuItem(title: "When Downloads Finish", action: nil, keyEquivalent: "")
        whenDone.submenu = NSMenu()
        for choice in WhenDone.allCases {
            let item = ActionMenuItem(choice.title) { [weak self] in self?.manager.whenDone = choice }
            item.state = manager.whenDone == choice ? .on : .off
            whenDone.submenu?.addItem(item)
        }
        list.append(whenDone)
        if !active.isEmpty {
            let total = active.reduce(0.0) { $0 + $1.speed }
            let progress = Self.progress(of: manager.items).map { " · \(Int($0 * 100))%" } ?? ""
            list.insert(ActionMenuItem("Show Downloads — \(active.count) downloading\(progress) · \(ByteFormat.speed(total))") { [weak self] in
                self?.open()
            }, at: 0)
        }
        return list
    }

    func settingsView() -> AnyView {
        AnyView(DownloadsSettingsTab(manager: manager, module: self))
    }

    func willTerminate() {
        manager.stopAll()
    }

    private(set) lazy var launcherProvider: LauncherProvider? = DownloadsLauncherProvider(module: self)
}

private final class Countdown {
    var seconds = 60
}

/// Paste a link in the launcher to download it; search finished downloads by name.
@MainActor
final class DownloadsLauncherProvider: LauncherProvider {
    private weak var module: DownloadsModule?

    init(module: DownloadsModule) {
        self.module = module
    }

    func results(for query: String) -> [LauncherResult] {
        guard let module else { return [] }
        var results: [LauncherResult] = []
        if let url = DownloadManager.downloadableURL(from: query) {
            results.append(LauncherResult(
                id: "download:new", title: "Download \(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)",
                subtitle: url.absoluteString, kind: "Download", icon: .symbol("arrow.down.circle"), score: 300
            ) { [weak module] in
                module?.manager.add(url.absoluteString)
                module?.open()
            })
            results.append(LauncherResult(
                id: "download:grab", title: "Grab Files from \(url.host ?? "This Site")…",
                subtitle: "Site Grabber: pictures, videos, files, or the whole site", kind: "Download",
                icon: .symbol("square.and.arrow.down.on.square"), score: 120
            ) { [weak module] in
                module?.openGrabber(address: url.absoluteString)
            })
        }
        guard query.count >= 2 else { return results }
        for item in module.manager.items {
            let score = FuzzyMatch.score(query, item.name)
            guard score > 0 else { continue }
            let path = item.finalPath
            results.append(LauncherResult(
                id: "download:" + item.id.uuidString, title: item.name,
                subtitle: item.state == .completed ? (path ?? "") : "Downloading…",
                kind: "Download", icon: path.map { .image(NSWorkspace.shared.icon(forFile: $0)) } ?? .symbol("arrow.down.circle"),
                score: score * 0.9, revealURL: path.map { URL(fileURLWithPath: $0) }
            ) { [weak module] in
                if let path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } else { module?.open() }
            })
        }
        return results
    }
}

