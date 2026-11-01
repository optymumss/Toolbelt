import AppKit
import SwiftUI

// Updating Toolbelt from its GitHub releases: once a day (if switched on) Toolbelt asks GitHub for the
// latest release; if it's newer, a small window shows what's new with Install and Restart / Later /
// Skip This Version. Installing downloads the release's Toolbelt.dmg, checks that it holds Toolbelt at
// that version, swaps it in for the running copy and starts it again.
// The deciding parts (versions, the release's details, the swap script) are plain logic, tested in Tests.swift.

/// A release on GitHub.
struct ReleaseInfo: Equatable {
    var version: String
    var notes: String
    var dmg: URL
    var page: URL?
}

enum AppVersion {
    /// This copy's version ("0.33"). The real-use tests can pretend to be older (TOOLBELT_PRETEND_VERSION).
    static var current: String {
        ProcessInfo.processInfo.environment["TOOLBELT_PRETEND_VERSION"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// Compares versions number by number, so 0.10 is newer than 0.9. A leading "v" is ignored.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ text: String) -> [Int] {
            let trimmed = text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0, r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }
}

enum ReleaseFeed {
    static let latest = URL(string: "https://api.github.com/repos/optymumss/Toolbelt/releases/latest")!

    /// Where to ask (the real-use tests point it at a file of their own).
    static var url: URL {
        ProcessInfo.processInfo.environment["TOOLBELT_UPDATE_URL"].flatMap(URL.init(string:)) ?? latest
    }

    /// GitHub's answer for a release: its version (the tag without "v"), notes and the DMG to download.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        guard let link = dmg?["browser_download_url"] as? String, let url = URL(string: link) else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           dmg: url, page: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// The notes as plain words: Markdown's ## headings, **bold** and `code` marks taken out.
    static func plainNotes(_ markdown: String) -> String {
        markdown.components(separatedBy: .newlines).map { line in
            var text = line
            while text.hasPrefix("#") { text.removeFirst() }
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// The swap, done by a small script after Toolbelt has quit (an app can't replace itself while running).
enum UpdateSwap {
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Waits for `pid` to end (0: doesn't wait), puts `staged` where `target` is (keeping the old copy until
    /// the new one is in place, and putting it back if that fails) and, if asked, opens it.
    static func script(staged: URL, target: URL, pid: Int32, relaunch: Bool) -> String {
        let old = target.path + ".old"
        return """
        while [ \(pid) -gt 0 ] && kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(quoted(old))
        if [ -e \(quoted(target.path)) ]; then mv \(quoted(target.path)) \(quoted(old)) || exit 1; fi
        if mv \(quoted(staged.path)) \(quoted(target.path)); then
            rm -rf \(quoted(old))
        else
            mv \(quoted(old)) \(quoted(target.path)); exit 1
        fi
        xattr -dr com.apple.quarantine \(quoted(target.path)) 2>/dev/null
        \(relaunch ? "open \(quoted(target.path))" : "true")
        """
    }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case installing(ReleaseInfo)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var timer: Timer?
    private var window: NSWindow?

    /// For the real-use tests: "update-check", and "update-install-to:/path/Toolbelt.app" (installs there, doesn't quit).
    func registerTestHooks() {
        RealUseHooks.extraStatus["update"] = { Updater.shared.statusText }
        RealUseHooks.commands["update-check"] = { _ in Task { @MainActor in await Updater.shared.check(userAsked: false) } }
        RealUseHooks.commands["update-install-to"] = { path in
            guard case .available(let release) = Updater.shared.state else { return }
            Task { @MainActor in await Updater.shared.install(release, into: URL(fileURLWithPath: path), relaunch: false) }
        }
    }

    /// Checks a couple of minutes after starting, then once a day, while automatic checks are on.
    func start() {
        timer?.invalidate()
        guard Prefs.updateAutoCheck else { return }
        let lastCheck = Date(timeIntervalSince1970: Prefs.updateLastCheck)
        let next = max(Date().addingTimeInterval(120), lastCheck.addingTimeInterval(24 * 3600))
        let timer = Timer(fire: next, interval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userAsked: false) }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks GitHub. When `userAsked`, the window also says "up to date" or what went wrong, and a skipped
    /// version is offered again.
    func check(userAsked: Bool) async {
        if case .installing = state { return }
        state = .checking
        Prefs.updateLastCheck = Date().timeIntervalSince1970
        var request = URLRequest(url: ReleaseFeed.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.message(http.statusCode == 404 ? "There's no release on GitHub yet." : "GitHub answered \(http.statusCode).")
            }
            guard let release = ReleaseFeed.parse(data) else { throw UpdateError.message("The latest release has no Toolbelt.dmg.") }
            if AppVersion.isNewer(release.version, than: AppVersion.current), userAsked || release.version != Prefs.updateSkipped {
                state = .available(release)
                if !RealUseHooks.isOn || userAsked { showWindow() }
            } else {
                state = .upToDate
                if userAsked { showWindow() }
            }
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            if userAsked { showWindow() }
        }
        RealUseHooks.writeStatus()
    }

    func skip(_ release: ReleaseInfo) {
        Prefs.updateSkipped = release.version
        closeWindow()
    }

    func closeWindow() {
        window?.close()
        window = nil
    }

    /// Downloads, checks and installs the release, then quits so the new copy can start
    /// (`target` and `relaunch` are only changed by the real-use tests).
    func install(_ release: ReleaseInfo, into target: URL = Bundle.main.bundleURL, relaunch: Bool = true) async {
        state = .installing(release)
        RealUseHooks.writeStatus()
        do {
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError.message("Toolbelt can't replace itself in \(target.deletingLastPathComponent().path). Move it to Applications first.")
            }
            let (download, response) = try await URLSession.shared.download(from: release.dmg)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.message("The download failed (\(http.statusCode)).") }
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Toolbelt-\(release.version)-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: download, to: dmg)
            defer { try? FileManager.default.removeItem(at: dmg) }
            let staged = target.deletingLastPathComponent().appendingPathComponent(".Toolbelt-update-\(UUID().uuidString).app")
            try await Task.detached { try Self.unpack(dmg, version: release.version, to: staged) }.value
            let script = UpdateSwap.script(staged: staged, target: target, pid: relaunch ? ProcessInfo.processInfo.processIdentifier : 0,
                                           relaunch: relaunch)
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/bash")
            swap.arguments = ["-c", script]
            swap.standardOutput = FileHandle.nullDevice
            swap.standardError = FileHandle.nullDevice
            try swap.run()
            if relaunch {
                NSApp.terminate(nil)
            } else {
                swap.waitUntilExit()
                state = swap.terminationStatus == 0 ? .upToDate : .failed("The new copy couldn't be put in place.")
            }
        } catch {
            state = .failed("The update didn't install: \(error.localizedDescription)")
            showWindow()
        }
        RealUseHooks.writeStatus()
    }

    /// Opens the DMG, checks it holds Toolbelt at this version, and copies the app to `staged`.
    nonisolated static func unpack(_ dmg: URL, version: String, to staged: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-quiet", "-mountpoint", mount.path, dmg.path]) else {
            throw UpdateError.message("The downloaded disk image couldn't be opened.")
        }
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard let name = apps.first else { throw UpdateError.message("There's no app in the downloaded disk image.") }
        let app = mount.appendingPathComponent(name)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier ?? "local.personal.toolbelt" else {
            throw UpdateError.message("The downloaded app isn't Toolbelt.")
        }
        guard let found = info["CFBundleShortVersionString"] as? String, AppVersion.compare(found, version) == .orderedSame else {
            throw UpdateError.message("The downloaded app isn't version \(version).")
        }
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [app.path, staged.path]) else { throw UpdateError.message("The new copy couldn't be copied out.") }
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UpdateView(updater: self)))
            window.title = "Toolbelt Update"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// For the screenshots: the window with a made-up release.
    func showExample() {
        state = .available(ReleaseInfo(version: "0.34", notes: """
        ## What's new in 0.34: download everything on a page
        - **Download all links:** right-click a page in Chrome → Download All Links with Toolbelt, then tick what you want.
        - **Site grabber:** all pictures of a site, all videos, or the start page and one level down.
        """, dmg: URL(string: "https://example.com/Toolbelt.dmg")!))
        showWindow()
    }

    var statusText: String {
        switch state {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "up to date"
        case .available(let release): return "available \(release.version)"
        case .installing(let release): return "installing \(release.version)"
        case .failed(let message): return "failed: \(message)"
        }
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updater.state {
            case .available(let release):
                Label("Toolbelt \(release.version) is available", systemImage: "arrow.down.circle.fill").font(.title3.weight(.semibold))
                Text("You have \(AppVersion.current).").foregroundStyle(.secondary)
                ScrollView {
                    Text(release.notes.isEmpty ? "No notes for this version." : ReleaseFeed.plainNotes(release.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Text("Toolbelt quits, swaps in the new version and opens again. macOS then asks once more for its permissions.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Skip This Version") { updater.skip(release) }
                    Spacer()
                    Button("Later") { updater.closeWindow() }.keyboardShortcut(.cancelAction)
                    Button("Install and Restart") { Task { await updater.install(release) } }.keyboardShortcut(.defaultAction)
                }
            case .installing(let release):
                Label("Installing Toolbelt \(release.version)…", systemImage: "arrow.down.circle").font(.title3.weight(.semibold))
                ProgressView().progressViewStyle(.linear)
                Text("Downloading and checking the new version. Toolbelt will restart by itself.").foregroundStyle(.secondary)
            case .checking:
                Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath").font(.title3.weight(.semibold))
                ProgressView().progressViewStyle(.linear)
            case .upToDate, .idle:
                Label("Toolbelt is up to date", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold))
                Text("You have the latest version, \(AppVersion.current).").foregroundStyle(.secondary)
                HStack { Spacer(); Button("OK") { updater.closeWindow() }.keyboardShortcut(.defaultAction) }
            case .failed(let message):
                Label("Update problem", systemImage: "exclamationmark.triangle.fill").font(.title3.weight(.semibold))
                Text(message).foregroundStyle(.secondary)
                HStack { Spacer(); Button("OK") { updater.closeWindow() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Settings → General → Updates.
struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared
    @State private var automatic = Prefs.updateAutoCheck

    var body: some View {
        Section {
            Toggle("Check for updates once a day", isOn: $automatic)
                .onChange(of: automatic) { _, value in
                    Prefs.updateAutoCheck = value
                    updater.start()
                }
            LabeledContent("This version", value: AppVersion.current)
            HStack {
                Button("Check Now") { Task { await updater.check(userAsked: true) } }
                if updater.state == .checking { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("New versions come from Toolbelt's releases on GitHub. You're asked before anything is installed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
