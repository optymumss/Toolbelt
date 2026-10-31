import AppKit
import CryptoKit
import UserNotifications

// MARK: - Links from Chrome

/// The folder ToolbeltBridge drops download requests into. Watched with the kernel's file events,
/// so it costs nothing while no links arrive.
@MainActor
final class BrowserInbox {
    static var folder: URL { SettingsStore.folder.appendingPathComponent("inbox", isDirectory: true) }

    private var watcher: FolderWatcher?
    private let onRequest: (DownloadRequest) -> Void

    init(onRequest: @escaping (DownloadRequest) -> Void) {
        self.onRequest = onRequest
    }

    func start() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        // Links that arrived while Toolbelt was closed (the bridge opens it, but it takes a moment).
        let waiting = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        process(waiting.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent })
        let watcher = FolderWatcher(folder: Self.folder) { [weak self] files in self?.process(files) }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func process(_ files: [URL]) {
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let request = try? JSONDecoder().decode(DownloadRequest.self, from: data) else { continue }
            onRequest(request)
        }
    }
}

/// Installs the Chrome extension and tells Chrome where ToolbeltBridge is.
enum ChromeSetup {
    static let hostName = "local.personal.toolbelt"
    /// Fixed by the "key" in Chrome/manifest.json, so it's the same on every Mac.
    static let extensionID = "giacgggbidbllaoaolhfnkdbnimcgbgo"

    /// How Chrome turns an extension's public key into its ID: the first 32 hex digits of its
    /// SHA-256, written with the letters a–p instead of 0–9 and a–f.
    static func extensionID(fromKey base64: String) -> String? {
        guard let key = Data(base64Encoded: base64) else { return nil }
        let hex = SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
        return String(hex.map { Character(UnicodeScalar(UInt8(97) + UInt8(Int(String($0), radix: 16)!))) })
    }

    static var hostsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
    }

    static func hostManifestURL(in folder: URL = hostsFolder) -> URL { folder.appendingPathComponent(hostName + ".json") }

    /// Where the extension is copied for "Load unpacked" (a folder that doesn't move when Toolbelt is updated).
    static var extensionFolder: URL { SettingsStore.folder.appendingPathComponent("Chrome Extension", isDirectory: true) }

    static var bridgeURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ToolbeltBridge") }

    static func hostManifest(bridgePath: String) -> Data {
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Toolbelt download manager",
            "path": bridgePath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: hostManifestURL().path) }

    /// Writes Chrome's note about ToolbeltBridge and copies the extension. Returns a problem, if any.
    @discardableResult
    static func install(extensionSource: URL? = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension"),
                        bridgePath: String = bridgeURL.path, hostsFolder: URL = hostsFolder) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: hostsFolder, withIntermediateDirectories: true)
            try hostManifest(bridgePath: bridgePath).write(to: hostManifestURL(in: hostsFolder), options: .atomic)
            if let extensionSource, fm.fileExists(atPath: extensionSource.path) {
                try? fm.removeItem(at: extensionFolder)
                try fm.copyItem(at: extensionSource, to: extensionFolder)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Keeps Chrome pointed at this copy of Toolbelt, in case it was moved or reinstalled.
    static func refreshIfSetUp() {
        // Never from the test program or a test copy of the app (they use a scratch data folder).
        guard Bundle.main.bundleURL.pathExtension == "app",
              ProcessInfo.processInfo.environment["TOOLBELT_DATA_DIR"] == nil, isInstalled else { return }
        let wanted = hostManifest(bridgePath: bridgeURL.path)
        if (try? Data(contentsOf: hostManifestURL())) != wanted {
            try? wanted.write(to: hostManifestURL(), options: .atomic)
        }
        // A newer extension inside this copy of Toolbelt: update the folder Chrome loads it from.
        // (Chrome picks it up when it next starts, or straight away with Reload on its Extensions page.)
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension"),
           extensionVersion(in: bundled) != nil, extensionVersion(in: bundled) != extensionVersion(in: extensionFolder) {
            try? FileManager.default.removeItem(at: extensionFolder)
            try? FileManager.default.copyItem(at: bundled, to: extensionFolder)
        }
    }

    static func extensionVersion(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["version"] as? String
    }

    /// Installs, then shows the folder and Chrome's extensions page with the steps to finish.
    @MainActor
    static func setUpInteractively() {
        if let problem = install() {
            let alert = NSAlert()
            alert.messageText = "Couldn't set up Chrome"
            alert.informativeText = problem
            alert.runModal()
            return
        }
        Prefs.downloadChromeSetUp = true
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome, configuration: configuration)
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Three clicks left in Chrome"
        alert.informativeText = """
        Chrome's Extensions page is open, and the extension folder is shown in Finder.

        1. Turn on “Developer mode” (top right of the Extensions page).
        2. Click “Load unpacked”.
        3. Choose the “Chrome Extension” folder that Finder is showing.

        Then click the Toolbelt button in Chrome's toolbar (in the puzzle-piece menu) to check it says “Connected”.
        """
        alert.runModal()
    }
}

// MARK: - Notifications

/// "Download finished" notifications. Clicking one shows the file in Finder.
@MainActor
final class DownloadNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Notifications only work from the real app (not the automated test program).
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func finished(_ item: DownloadItem) {
        guard available, Prefs.downloadNotify else { return }
        Self.post(id: item.id.uuidString, title: "Download finished", body: item.name, path: item.finalPath)
    }

    /// Shows a notification (macOS asks once whether Toolbelt may). Clicking one with a path shows the file.
    /// Not on the main actor: macOS calls back on its own threads.
    nonisolated static func post(id: String, title: String, body: String, path: String?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let path { content.userInfo = ["path": path] }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
