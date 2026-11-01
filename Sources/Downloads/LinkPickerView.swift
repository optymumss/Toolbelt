import AppKit
import SwiftUI

// 0.34: the windows for downloading several links at once.
// - `LinkPickerModel` / `LinkPickerView`: a list of links to tick, with buttons for each type of file and a search box
//   (from Chrome's "Download All Links with Toolbelt", copied text with several links, and the site grabber).
// - `GrabberModel` / `GrabberView`: the site grabber (templates, depth, limits).
// - `LinkOfferPanel`: "Download manual.pdf?" when a link to a file is copied.

// MARK: - Choosing links

@MainActor
final class LinkPickerModel: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published private(set) var links: [FoundLink]
    @Published var ticked: Set<URL>
    /// The types shown (none: all).
    @Published var kinds: Set<String> = []
    @Published var search = ""
    /// Save everything into this folder instead of each file's category folder.
    @Published var folder: URL?
    let rules: [CategoryRule]
    /// The page they came from (sent as where each download came from).
    let page: String?
    private let headers: (URL) -> [String: String]

    init(title: String, links: [FoundLink], page: String? = nil, tickAll: Bool = false,
         headers: @escaping (URL) -> [String: String] = { _ in [:] }) {
        self.title = title
        let links = LinkSelection.unique(links)
        self.links = links
        self.ticked = tickAll ? Set(links.map(\.url)) : LinkSelection.initiallyTicked(links)
        self.page = page
        self.headers = headers
        self.rules = Prefs.downloadCategories
    }

    var visible: [FoundLink] { LinkSelection.visible(links, kinds: kinds, search: search, rules: rules) }
    var counts: [(kind: String, count: Int)] { LinkSelection.counts(links, rules: rules) }
    /// What "Download" downloads: the ticked links that are shown.
    var chosen: [FoundLink] { visible.filter { ticked.contains($0.url) } }

    func kind(of link: FoundLink) -> String { LinkSelection.kind(of: link, rules: rules) }

    func toggleKind(_ kind: String) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    func tickShown(_ on: Bool) {
        for link in visible {
            if on { ticked.insert(link.url) } else { ticked.remove(link.url) }
        }
    }

    func toggle(_ link: FoundLink) {
        if ticked.contains(link.url) { ticked.remove(link.url) } else { ticked.insert(link.url) }
    }

    func binding(for link: FoundLink) -> Binding<Bool> {
        Binding(get: { self.ticked.contains(link.url) },
                set: { on in if on { self.ticked.insert(link.url) } else { self.ticked.remove(link.url) } })
    }

    /// Starts the chosen downloads. Returns how many started.
    @discardableResult
    func download(with manager: DownloadManager) -> Int {
        var started = 0
        for link in chosen where manager.add(link.url.absoluteString, headers: headers(link.url), page: page, folder: folder) != nil {
            started += 1
        }
        return started
    }

    var statusText: String {
        "\(visible.count) shown, \(chosen.count) ticked: " + chosen.map(\.name).joined(separator: ",")
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case DownloadCategory.video.rawValue: return "film"
        case DownloadCategory.music.rawValue: return "music.note"
        case DownloadCategory.documents.rawValue: return "doc.text"
        case DownloadCategory.programs.rawValue: return "shippingbox"
        case DownloadCategory.archives.rawValue: return "archivebox"
        case DownloadCategory.images.rawValue: return "photo"
        case LinkSelection.pagesKind: return "globe"
        default: return "doc"
        }
    }
}

struct LinkPickerView: View {
    @ObservedObject var model: LinkPickerModel
    var onDownload: () -> Void
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(model.links.count) links").foregroundStyle(.secondary)
            }
            kindButtons
            TextField("Search, or type an extension like .pdf", text: $model.search)
                .textFieldStyle(.roundedBorder)
            List(model.visible) { link in
                HStack(spacing: 8) {
                    Toggle("", isOn: model.binding(for: link)).labelsHidden().toggleStyle(.checkbox)
                    Image(systemName: LinkPickerModel.symbol(for: model.kind(of: link)))
                        .frame(width: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.name).lineLimit(1).truncationMode(.middle)
                        Text(link.text.isEmpty ? link.url.absoluteString : "\(link.text) — \(link.url.absoluteString)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(link) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button("Tick All") { model.tickShown(true) }
                Button("Tick None") { model.tickShown(false) }
                Spacer()
                Menu(model.folder.map { "Save to \($0.lastPathComponent)" } ?? "Save to category folders") {
                    Button("Category folders (Video, Documents, …)") { model.folder = nil }
                    Button("Choose a Folder…") { chooseFolder() }
                }
                .fixedSize()
                if let onCancel { Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
                Button("Download \(model.chosen.count)") { onDownload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosen.isEmpty)
            }
        }
        .padding(14)
    }

    private var kindButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { model.kinds = [] } label: { chip("All", count: model.links.count, on: model.kinds.isEmpty, symbol: "square.grid.2x2") }
                ForEach(model.counts, id: \.kind) { entry in
                    Button { model.toggleKind(entry.kind) } label: {
                        chip(entry.kind, count: entry.count, on: model.kinds.contains(entry.kind), symbol: LinkPickerModel.symbol(for: entry.kind))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, count: Int, on: Bool, symbol: String) -> some View {
        Label("\(title) \(count)", systemImage: symbol)
            .font(.callout)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.folder ?? Prefs.downloadFolder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { model.folder = url }
    }
}

/// The windows with lists of links. The newest one answers the test commands.
@MainActor
enum LinkPickerWindows {
    private static var windows: [(model: LinkPickerModel, window: NSWindow)] = []
    /// The picker the test commands use: the newest window's, or the grabber's list.
    static var current: LinkPickerModel? { windows.last?.model ?? GrabberWindow.model?.picker }

    static func show(_ model: LinkPickerModel, manager: DownloadManager, activate: Bool = true) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Download Links"
        window.isReleasedWhenClosed = false
        let close: () -> Void = { [weak window] in window?.close() }
        window.contentViewController = NSHostingController(rootView: LinkPickerView(model: model, onDownload: {
            if model.download(with: manager) > 0 { MenuBarBadge.shared.flash() }
            close()
        }, onCancel: close))
        window.setContentSize(NSSize(width: 640, height: 480))
        window.center()
        windows.append((model, window))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0.model.id == model.id }
                RealUseHooks.writeStatus()
            }
        }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        RealUseHooks.writeStatus()
    }

    static func registerTestHooks(manager: DownloadManager) {
        RealUseHooks.extraStatus["linkPicker"] = { current?.statusText ?? "" }
        RealUseHooks.commands["picker-kind"] = { kind in current?.toggleKind(kind); RealUseHooks.writeStatus() }
        RealUseHooks.commands["picker-search"] = { text in current?.search = text; RealUseHooks.writeStatus() }
        RealUseHooks.commands["picker-close"] = { _ in
            for entry in windows { entry.window.close() }
            GrabberWindow.close()
        }
        RealUseHooks.commands["picker-download"] = { _ in
            guard let model = current else { return }
            model.download(with: manager)
            if let index = windows.lastIndex(where: { $0.model.id == model.id }) { windows[index].window.close() }
            RealUseHooks.writeStatus()
        }
    }
}

// MARK: - Site grabber

@MainActor
final class GrabberModel: ObservableObject {
    enum State: Equatable {
        case ready
        case working(SiteGrabber.Progress)
        case found(Int)
        case saved(String)
        case failed(String)
    }

    @Published var address = ""
    @Published var template: GrabTemplate = .pictures { didSet { depth = template.defaultDepth } }
    @Published var depth = GrabTemplate.pictures.defaultDepth
    @Published var maxFiles = 500
    @Published var sameSite = true
    @Published private(set) var state: State = .ready
    @Published private(set) var picker: LinkPickerModel?
    private var grabber: SiteGrabber?
    let manager: DownloadManager

    init(manager: DownloadManager) {
        self.manager = manager
    }

    var isWorking: Bool { if case .working = state { return true } else { return false } }

    var startURL: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        return DownloadManager.downloadableURL(from: text)
    }

    var statusText: String {
        switch state {
        case .ready: return "ready"
        case .working(let progress): return "working \(progress.pagesChecked) pages, \(progress.filesFound) found, \(progress.saved) saved"
        case .found(let count): return "found \(count)"
        case .saved(let path): return "saved \(path)"
        case .failed(let problem): return "failed \(problem)"
        }
    }

    func start() {
        guard let start = startURL else {
            state = .failed("That isn't a web address.")
            return
        }
        var settings = GrabSettings(start: start, template: template, depth: depth)
        settings.maxFiles = max(1, maxFiles)
        settings.sameSite = sameSite
        let grabber = SiteGrabber(settings: settings, rules: Prefs.downloadCategories, fetch: Self.fetch)
        self.grabber = grabber
        picker = nil
        state = .working(SiteGrabber.Progress())
        let report: @Sendable (SiteGrabber.Progress) -> Void = { progress in
            Task { @MainActor [weak self] in
                guard let self, self.isWorking else { return }
                self.state = .working(progress)
                RealUseHooks.writeStatus()
            }
        }
        Task { @MainActor in
            if template == .site {
                let folder = ShelfStore.unusedURL(for: OfflinePaths.safe(start.host ?? "Site"),
                                                  in: Prefs.downloadFolder.appendingPathComponent("Sites", isDirectory: true))
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = await grabber.mirror(into: folder, save: Self.save, progress: report)
                if let startFile = result.startFile {
                    state = .saved(folder.appendingPathComponent(startFile).path)
                } else {
                    state = .failed("Couldn't open \(start.absoluteString).")
                }
            } else {
                let result = await grabber.explore(progress: report)
                if result.pages.isEmpty {
                    state = .failed("Couldn't open \(start.absoluteString).")
                } else {
                    picker = LinkPickerModel(title: "\(result.files.count) files on \(result.pages.count) pages of \(start.host ?? "")",
                                             links: result.files, page: start.absoluteString, tickAll: true)
                    state = .found(result.files.count)
                }
            }
            RealUseHooks.writeStatus()
        }
    }

    func stop() { grabber?.cancel() }

    /// For the screenshot: as if it had just found these on the site.
    func showExample(links: [FoundLink]) {
        picker = LinkPickerModel(title: "\(links.count) files on 4 pages of \(startURL?.host ?? "")", links: links, page: address, tickAll: true)
        state = .found(links.count)
    }

    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// One page: read only when it's a web page (anything else stops after its headers), at most 5 MB.
    nonisolated static func fetch(_ url: URL) async -> SiteGrabber.Page? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let type = http.mimeType ?? ""
        let finalURL = http.url ?? url
        if !type.isEmpty, !type.lowercased().contains("html") {
            bytes.task.cancel()
            return SiteGrabber.Page(data: Data(), mimeType: type, url: finalURL)
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 5_000_000 { break }
            }
        } catch {
            return nil
        }
        return SiteGrabber.Page(data: data, mimeType: type, url: finalURL)
    }

    /// One file of an offline copy, saved to `destination`. Returns its type, or nil if it failed.
    nonisolated static func save(_ url: URL, to destination: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (file, response) = try? await URLSession.shared.download(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: file, to: destination)) != nil else { return nil }
        return http.mimeType ?? ""
    }
}

struct GrabberView: View {
    @ObservedObject var model: GrabberModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Start page", text: $model.address, prompt: Text("https://example.com"))
                Picker("Grab", selection: $model.template) {
                    ForEach(GrabTemplate.allCases) { Text($0.title).tag($0) }
                }
                Text(model.template.summary).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $model.depth, in: 0...6) {
                    LabeledContent("Pages to follow", value: depthText)
                }
                if model.template != .site {
                    Picker("At most", selection: $model.maxFiles) {
                        ForEach([100, 500, 2000, 10000], id: \.self) { Text("\($0) files").tag($0) }
                    }
                }
                Toggle("Only this site (don't follow links to other sites)", isOn: $model.sameSite)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: model.template == .site ? 250 : 290)
            HStack {
                status
                Spacer()
                if model.isWorking {
                    Button("Stop") { model.stop() }
                } else {
                    Button(model.template == .site ? "Save Site" : "Find Files") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.startURL == nil)
                }
            }
            .padding(.horizontal, 20)
            if let picker = model.picker {
                LinkPickerView(model: picker, onDownload: {
                    if picker.download(with: model.manager) > 0 { MenuBarBadge.shared.flash() }
                })
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 620, minHeight: 360)
    }

    private var depthText: String {
        switch model.depth {
        case 0: return "Only the start page"
        case 1: return "Start page + one level of links"
        default: return "Start page + \(model.depth) levels of links"
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready:
            Text("Looks through the pages, then lists what it found.").foregroundStyle(.secondary)
        case .working(let progress):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.template == .site
                     ? "\(progress.pagesChecked) pages read, \(progress.saved) files saved…"
                     : "\(progress.pagesChecked) pages checked, \(progress.filesFound) files found…")
            }
        case .found(let count):
            Text(count == 0 ? "Nothing of that kind found. Try more levels, or another template." : "Found \(count). Tick what you want, then Download.")
        case .saved(let path):
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved.")
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        case .failed(let problem):
            Text(problem).foregroundStyle(.red)
        }
    }
}

@MainActor
enum GrabberWindow {
    private(set) static var model: GrabberModel?
    private static var window: NSWindow?

    static func show(manager: DownloadManager, address: String? = nil, template: GrabTemplate? = nil) {
        if window == nil {
            let model = GrabberModel(manager: manager)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Site Grabber"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: GrabberView(model: model))
            window.setContentSize(NSSize(width: 680, height: 720))
            window.center()
            window.setFrameAutosaveName("ToolbeltGrabber")
            self.model = model
            self.window = window
        }
        if let template { model?.template = template }
        if let address { model?.address = address }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }

    static func showExample(manager: DownloadManager, address: String, links: [FoundLink]) {
        show(manager: manager, address: address, template: .pictures)
        model?.showExample(links: links)
    }

    static func registerTestHooks(manager: DownloadManager) {
        RealUseHooks.extraStatus["grabber"] = { model?.statusText ?? "" }
        // "grab:pictures 1 http://…": template, depth, start page.
        RealUseHooks.commands["grab"] = { text in
            let parts = text.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let template = GrabTemplate(rawValue: parts[0]), let depth = Int(parts[1]) else { return }
            show(manager: manager, address: parts[2], template: template)
            model?.depth = depth
            model?.start()
        }
    }
}

// MARK: - Copied links

/// "Download manual.pdf?" in the top-right corner when a link to a file is copied. Goes away by itself.
@MainActor
enum LinkOfferPanel {
    private static var panel: NSPanel?
    private static var closeTimer: Timer?
    private(set) static var message = ""
    private static var accept: (() -> Void)?

    static func show(message: String, detail: String, button: String, onAccept: @escaping () -> Void) {
        close()
        self.message = message
        accept = onAccept
        let view = LinkOfferView(message: message, detail: detail, button: button,
                                 onAccept: { acceptOffer() }, onDismiss: { close() })
        // Clickable straight away, without first bringing Toolbelt to the front.
        let hosting = FirstClickHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - hosting.fittingSize.width - 16, y: screen.maxY - hosting.fittingSize.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        closeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
            MainActor.assumeIsolated { close() }
        }
        RealUseHooks.writeStatus()
    }

    static func acceptOffer() {
        let action = accept
        close()
        action?()
    }

    static func close() {
        closeTimer?.invalidate()
        closeTimer = nil
        panel?.orderOut(nil)
        panel = nil
        message = ""
        accept = nil
        RealUseHooks.writeStatus()
    }

    static func registerTestHooks() {
        RealUseHooks.extraStatus["linkOffer"] = { message }
        RealUseHooks.commands["link-offer-accept"] = { _ in acceptOffer() }
    }
}

struct LinkOfferView: View {
    let message: String
    let detail: String
    let button: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 260, alignment: .leading)
            Button("Not Now", action: onDismiss)
            Button(button, action: onAccept).keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .padding(2)
    }
}
