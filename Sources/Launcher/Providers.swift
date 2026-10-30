import AppKit

// MARK: - Calculator and unit converter

@MainActor
final class CalculatorProvider: LauncherProvider {
    func results(for query: String) -> [LauncherResult] {
        if let conversion = UnitConverter.convert(query) {
            return [answer(conversion.text, copying: UnitConverter.format(conversion.value), query: query, kind: "Convert", symbol: "arrow.left.arrow.right")]
        }
        if Calculator.isCalculation(query), let value = Calculator.evaluate(query) {
            let text = Calculator.format(value)
            return [answer("= \(text)", copying: text, query: query, kind: "Calculator", symbol: "plus.forwardslash.minus")]
        }
        return []
    }

    private func answer(_ title: String, copying text: String, query: String, kind: String, symbol: String) -> LauncherResult {
        LauncherResult(
            id: "calc", title: title, subtitle: "\(query) · press ↩ to copy the answer",
            kind: kind, icon: .symbol(symbol), score: 1000
        ) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }
}

// MARK: - Apps

@MainActor
final class AppsProvider: LauncherProvider {
    struct App {
        let name: String
        let url: URL
    }

    private(set) var apps: [App] = []
    private var loadedAt: Date?
    private var icons: [URL: NSImage] = [:]

    static let folders = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        // Since macOS 13, Safari and a few other Apple apps live in a protected "cryptex"
        // instead of /Applications.
        "/System/Cryptexes/App/System/Applications",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    /// Apps found by asking macOS where they are, wherever they're stored.
    static let wellKnown = ["com.apple.Safari", "com.apple.finder", "com.apple.systempreferences"]

    func results(for query: String) -> [LauncherResult] {
        refreshIfNeeded()
        return apps
            .map { ($0, FuzzyMatch.score(query, $0.name)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map { app, score in
                LauncherResult(
                    id: "app:" + app.url.path, title: app.name, subtitle: app.url.deletingLastPathComponent().path,
                    kind: "Application", icon: .image(icon(for: app.url)), score: score + 5, revealURL: app.url
                ) {
                    NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
            }
    }

    /// Apps don't change often; look again at most once a minute.
    func refreshIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        loadedAt = Date()
        var found: [String: App] = [:]
        let fm = FileManager.default
        func scan(_ folder: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                if item.pathExtension == "app" {
                    let name = item.deletingPathExtension().lastPathComponent
                    if found[name] == nil { found[name] = App(name: name, url: item) }
                } else if depth > 0, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    scan(item, depth: depth - 1) // apps inside folders, like "Microsoft Office"
                }
            }
        }
        for folder in Self.folders {
            scan(URL(fileURLWithPath: folder), depth: 1)
        }
        for bundleID in Self.wellKnown {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let name = url.deletingPathExtension().lastPathComponent
                if found[name] == nil { found[name] = App(name: name, url: url) }
            }
        }
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        found["Finder"] = App(name: "Finder", url: finder)
        apps = found.values.sorted { $0.name < $1.name }
    }

    private func icon(for url: URL) -> NSImage {
        if let cached = icons[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }
}

// MARK: - Files and folders (Spotlight)

/// Searches your home folder with Spotlight. Results arrive a moment after typing.
@MainActor
final class FileSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func search(_ text: String, completion: @escaping ([LauncherResult]) -> Void) {
        cancel()
        let cleaned = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
        guard !cleaned.isEmpty else { return }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(cleaned)*")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.query === query else { return }
                query.disableUpdates()
                let results = Self.results(from: query, text: cleaned)
                self.cancel()
                completion(results)
            }
        }
        self.query = query
        query.start()
    }

    func cancel() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private static func results(from query: NSMetadataQuery, text: String) -> [LauncherResult] {
        var results: [LauncherResult] = []
        for index in 0..<min(query.resultCount, 60) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            // Apps are listed by the apps search; Library folders are mostly app data.
            if path.hasSuffix(".app") || path.contains("/Library/") || path.contains("/.") { continue }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let score = FuzzyMatch.score(text, name)
            guard score > 0 else { continue }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let home = NSHomeDirectory()
            let shortPath = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            results.append(LauncherResult(
                id: "file:" + path, title: name, subtitle: shortPath,
                kind: isFolder ? "Folder" : "File",
                icon: .image(NSWorkspace.shared.icon(forFile: path)),
                score: score * 0.8 - Double(index) * 0.01, revealURL: url
            ) {
                NSWorkspace.shared.open(url)
            })
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(8))
    }
}

// MARK: - Quicklinks

struct Quicklink: Identifiable, Equatable {
    var id = UUID().uuidString
    var keyword: String
    var name: String
    /// Web address with {query} where the search words go.
    var url: String

    static let defaults = [
        Quicklink(keyword: "g", name: "Google", url: "https://www.google.com/search?q={query}"),
        Quicklink(keyword: "ddg", name: "DuckDuckGo", url: "https://duckduckgo.com/?q={query}"),
        Quicklink(keyword: "yt", name: "YouTube", url: "https://www.youtube.com/results?search_query={query}"),
        Quicklink(keyword: "w", name: "Wikipedia", url: "https://en.wikipedia.org/w/index.php?search={query}"),
        Quicklink(keyword: "maps", name: "Apple Maps", url: "https://maps.apple.com/?q={query}"),
        Quicklink(keyword: "gh", name: "GitHub", url: "https://github.com/search?q={query}"),
    ]

    var plist: [String: String] {
        ["id": id, "keyword": keyword, "name": name, "url": url]
    }

    init(keyword: String, name: String, url: String) {
        self.keyword = keyword
        self.name = name
        self.url = url
    }

    init?(plist: [String: String]) {
        guard let keyword = plist["keyword"], let name = plist["name"], let url = plist["url"] else { return nil }
        self.init(keyword: keyword, name: name, url: url)
        if let id = plist["id"] { self.id = id }
    }

    /// The address to open for some search words.
    func address(for words: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#/"))
        let encoded = words.addingPercentEncoding(withAllowedCharacters: allowed) ?? words
        return URL(string: url.replacingOccurrences(of: "{query}", with: encoded))
    }

    /// The site's home page, for when there are no search words.
    var homePage: URL? {
        guard let full = URL(string: url.replacingOccurrences(of: "{query}", with: "")),
              let scheme = full.scheme, let host = full.host else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }
}

@MainActor
final class QuicklinksProvider: LauncherProvider {
    func results(for query: String) -> [LauncherResult] {
        let links = Prefs.quicklinks
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let keyword = parts.first.map { String($0).lowercased() } ?? ""
        let words = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        var results: [LauncherResult] = []
        for link in links {
            if link.keyword.lowercased() == keyword, !words.isEmpty, let url = link.address(for: words) {
                results.append(LauncherResult(
                    id: "quicklink:" + link.id, title: "Search \(link.name) for “\(words)”", subtitle: url.absoluteString,
                    kind: "Quicklink", icon: .symbol("globe"), score: 500
                ) { NSWorkspace.shared.open(url) })
            } else if words.isEmpty {
                let score = max(link.keyword.lowercased() == keyword ? 95 : 0, FuzzyMatch.score(trimmed, link.name))
                guard score > 0, let home = link.homePage else { continue }
                results.append(LauncherResult(
                    id: "quicklink:" + link.id, title: link.name,
                    subtitle: "Type “\(link.keyword) ” and your search words, or press ↩ to open \(home.host ?? "")",
                    kind: "Quicklink", icon: .symbol("globe"), score: score
                ) { NSWorkspace.shared.open(home) })
            }
        }
        return results
    }
}

// MARK: - System commands

struct SystemCommand {
    let name: String
    var keywords: [String] = []
    let symbol: String
    let run: @MainActor () -> Void
}

@MainActor
final class SystemCommandsProvider: LauncherProvider {
    /// Commands added by Toolbelt itself, like "Toolbelt Settings".
    var extraCommands: [SystemCommand] = []

    func commands() -> [SystemCommand] {
        var list: [SystemCommand] = [
            SystemCommand(name: "Lock Screen", keywords: ["lock"], symbol: "lock") { SystemActions.lockScreen() },
            SystemCommand(name: "Sleep", keywords: ["sleep", "suspend"], symbol: "moon.zzz") { SystemActions.sleep() },
            SystemCommand(name: "Restart", keywords: ["reboot"], symbol: "arrow.clockwise.circle") { SystemActions.restart() },
            SystemCommand(name: "Shut Down", keywords: ["shutdown", "power off", "turn off"], symbol: "power") { SystemActions.shutDown() },
            SystemCommand(name: "Log Out", keywords: ["logout", "sign out"], symbol: "rectangle.portrait.and.arrow.right") { SystemActions.logOut() },
            SystemCommand(name: "Empty Bin", keywords: ["trash", "empty trash", "bin"], symbol: "trash") { SystemActions.emptyBin() },
            SystemCommand(name: "Toggle Dark Mode", keywords: ["dark mode", "light mode", "appearance"], symbol: "circle.lefthalf.filled") { SystemActions.toggleDarkMode() },
        ]
        let volumes = SystemActions.ejectableVolumes()
        for volume in volumes {
            list.append(SystemCommand(name: "Eject “\(volume.name)”", keywords: ["eject", "unmount"], symbol: "eject") {
                SystemActions.eject([volume.url])
            })
        }
        if volumes.count > 1 {
            list.append(SystemCommand(name: "Eject All Disks", keywords: ["eject", "unmount"], symbol: "eject") {
                SystemActions.eject(volumes.map(\.url))
            })
        }
        return list + extraCommands
    }

    func results(for query: String) -> [LauncherResult] {
        commands().compactMap { command in
            let byName = FuzzyMatch.score(query, command.name)
            let byKeyword = command.keywords.map { FuzzyMatch.score(query, $0) * 0.95 }.max() ?? 0
            let score = max(byName, byKeyword)
            guard score > 0 else { return nil }
            return LauncherResult(
                id: "command:" + command.name, title: command.name, kind: "Command",
                icon: .symbol(command.symbol), score: score + 2, action: command.run
            )
        }
    }
}

/// The macOS actions behind the system commands.
@MainActor
enum SystemActions {
    static func lockScreen() {
        // The same private call the Lock Screen menu item uses.
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFunction = @convention(c) () -> Int32
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
            return
        }
        // Otherwise press ⌃⌘Q, the Lock Screen shortcut.
        guard PermissionGate.ensure(.accessibility, to: "lock your screen") else { return }
        KeyPresser.press(keyCode: 12, flags: [.maskCommand, .maskControl])
    }

    static func sleep() {
        run("/usr/bin/pmset", ["sleepnow"])
    }

    // These ask macOS to show its own "Are you sure?" dialog.
    static func restart() { appleScript(#"tell application "loginwindow" to «event aevtrrst»"#) }
    static func shutDown() { appleScript(#"tell application "loginwindow" to «event aevtrsdn»"#) }
    static func logOut() { appleScript(#"tell application "loginwindow" to «event aevtlogo»"#) }

    static func emptyBin() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Empty the Bin?"
        alert.informativeText = "Everything in the Bin will be deleted. This can't be undone."
        alert.addButton(withTitle: "Empty Bin")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        appleScript(#"tell application "Finder" to empty trash"#)
    }

    static func toggleDarkMode() {
        appleScript(#"tell application "System Events" to tell appearance preferences to set dark mode to not dark mode"#)
    }

    struct Volume {
        let name: String
        let url: URL
    }

    static func ejectableVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeLocalizedNameKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path != "/", let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let ejectable = values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
            guard ejectable else { return nil }
            return Volume(name: values.volumeLocalizedName ?? url.lastPathComponent, url: url)
        }
    }

    static func eject(_ urls: [URL]) {
        for url in urls {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                showProblem("Couldn't eject “\(url.lastPathComponent)”", error.localizedDescription + " Close any files open from it and try again.")
            }
        }
    }

    static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    @discardableResult
    static func appleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return true }
        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        showProblem(
            "That didn't work",
            "\(message)\n\nIf macOS asked whether Toolbelt may control another app, allow it in System Settings › Privacy & Security › Automation."
        )
        return false
    }

    static func showProblem(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

/// Presses a key combination in whichever app is in front. Needs Accessibility.
enum KeyPresser {
    static func press(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
