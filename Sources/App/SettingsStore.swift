import AppKit
import SwiftUI

/// All of Toolbelt's settings, kept in one file:
/// ~/Library/Application Support/Toolbelt/settings.plist
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// ~/Library/Application Support/Toolbelt/
    /// (Automated tests point TOOLBELT_DATA_DIR at a scratch folder instead.)
    nonisolated static var folder: URL {
        if let custom = ProcessInfo.processInfo.environment["TOOLBELT_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Toolbelt", isDirectory: true)
    }

    private let file: URL
    private var values: [String: Any] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        file = Self.folder.appendingPathComponent("settings.plist")

        if let data = try? Data(contentsOf: file),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = dict
        } else {
            migrateFromV01()
        }
    }

    func raw(_ key: String) -> Any? {
        values[key]
    }

    func value<T>(_ key: String, default defaultValue: T) -> T {
        values[key] as? T ?? defaultValue
    }

    /// Saves a value. Passing nil removes the key, so its default applies again.
    func set(_ value: Any?, for key: String) {
        objectWillChange.send()
        values[key] = value
        save()
    }

    func binding<T>(_ key: String, default defaultValue: T) -> Binding<T> {
        Binding(
            get: { MainActor.assumeIsolated { self.value(key, default: defaultValue) } },
            set: { newValue in MainActor.assumeIsolated { self.set(newValue, for: key) } }
        )
    }

    private func save() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save settings: \(error)")
        }
    }

    /// v0.1 kept its settings in macOS's preferences system; bring them over once.
    private func migrateFromV01() {
        let old = UserDefaults.standard
        for key in ["paused", "pasteAfterSelect", "historyLimit", "ignoredBundleIDs"] {
            if let value = old.object(forKey: key) { values[key] = value }
        }
        save()
    }
}

// MARK: - Typed settings

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
enum Prefs {
    private static var store: SettingsStore { .shared }

    static let defaultIgnoredApps = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    // App

    /// Pauses every module at once, from the menu bar.
    static var appPaused: Bool {
        get { store.value("appPaused", default: false) }
        set { store.set(newValue, for: "appPaused") }
    }

    static var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: store.value("appearance", default: "")) ?? .system }
        set { store.set(newValue.rawValue, for: "appearance") }
    }

    static func isEnabled(_ module: ModuleID) -> Bool {
        store.value("module.\(module.rawValue).enabled", default: true)
    }

    static func setEnabled(_ enabled: Bool, _ module: ModuleID) {
        store.set(enabled, for: "module.\(module.rawValue).enabled")
    }

    // Launcher

    static var launcherSearchFiles: Bool {
        get { store.value("launcher.files", default: true) }
        set { store.set(newValue, for: "launcher.files") }
    }

    static var launcherSearchClipboard: Bool {
        get { store.value("launcher.clipboard", default: true) }
        set { store.set(newValue, for: "launcher.clipboard") }
    }

    static var quicklinks: [Quicklink] {
        get {
            guard let stored = store.raw("launcher.quicklinks") as? [[String: String]] else { return Quicklink.defaults }
            return stored.compactMap(Quicklink.init(plist:))
        }
        set { store.set(newValue.map(\.plist), for: "launcher.quicklinks") }
    }

    // Downloads

    static var downloadFolder: URL {
        get {
            if let path = store.raw("downloads.folder") as? String { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { store.set(newValue.path, for: "downloads.folder") }
    }

    static var downloadSortByType: Bool {
        get { store.value("downloads.sort", default: true) }
        set { store.set(newValue, for: "downloads.sort") }
    }

    static var downloadConnections: Int {
        get { store.value("downloads.connections", default: 8) }
        set { store.set(newValue, for: "downloads.connections") }
    }

    static var downloadRetries: Int {
        get { store.value("downloads.retries", default: 5) }
        set { store.set(newValue, for: "downloads.retries") }
    }

    /// 0 means no limit.
    static var downloadSpeedLimitKB: Int {
        get { store.value("downloads.speedLimitKB", default: 0) }
        set { store.set(newValue, for: "downloads.speedLimitKB") }
    }

    /// 0 means no cap.
    static var downloadHourlyCapMB: Int {
        get { store.value("downloads.hourlyCapMB", default: 0) }
        set { store.set(newValue, for: "downloads.hourlyCapMB") }
    }

    static var downloadNotify: Bool {
        get { store.value("downloads.notify", default: true) }
        set { store.set(newValue, for: "downloads.notify") }
    }

    /// Hand downloads from Chrome to Toolbelt (once the extension is set up).
    /// Trackpad and Magic Mouse gestures: below 1 easier to trigger, above 1 harder.
    static var gestureSensitivity: Double {
        get { store.value("gestures.sensitivity", default: 1.0) }
        set { store.set(newValue, for: "gestures.sensitivity") }
    }

    /// Seconds after a key press during which trackpad gestures are ignored (0: off).
    static var gestureTypingPause: Double {
        get { store.value("gestures.typingPause", default: 0.0) }
        set { store.set(newValue, for: "gestures.typingPause") }
    }

    /// Caps Lock as the Hyper key (⌃⌥⇧⌘), and whether tapping it alone types Esc.
    static var hyperKey: Bool {
        get { store.value("keys.hyper", default: false) }
        set { store.set(newValue, for: "keys.hyper") }
    }

    static var hyperEscape: Bool {
        get { store.value("keys.hyperEscape", default: true) }
        set { store.set(newValue, for: "keys.hyperEscape") }
    }

    /// Keys changed into other keys (HID usages).
    static var keyRemaps: [KeyRemap] {
        get {
            let saved: [[String: Int]] = store.value("keys.remaps", default: [])
            return saved.compactMap { item in
                guard let from = item["from"], let to = item["to"] else { return nil }
                return KeyRemap(from: from, to: to)
            }
        }
        set { store.set(newValue.map { ["from": $0.from, "to": $0.to] }, for: "keys.remaps") }
    }

    /// Whether Toolbelt has changed macOS's key mapping (so it knows to put it back, and leaves it alone otherwise).
    static var keyMappingApplied: Bool {
        get { store.value("keys.applied", default: false) }
        set { store.set(newValue, for: "keys.applied") }
    }

    /// The web server (Settings → Automation): off unless switched on.
    static var webServerOn: Bool {
        get { store.value("web.on", default: false) }
        set { store.set(newValue, for: "web.on") }
    }

    static var webServerPort: Int {
        get { store.value("web.port", default: 12345) }
        set { store.set(newValue, for: "web.port") }
    }

    /// Let other devices on the network reach it (otherwise only this Mac).
    static var webServerEveryone: Bool {
        get { store.value("web.everyone", default: false) }
        set { store.set(newValue, for: "web.everyone") }
    }

    /// The shared secret every request must carry; made up the first time it's needed.
    static var webServerSecret: String {
        get {
            let saved: String = store.value("web.secret", default: "")
            if !saved.isEmpty { return saved }
            let secret = WebAPI.newSecret()
            store.set(secret, for: "web.secret")
            return secret
        }
        set { store.set(newValue, for: "web.secret") }
    }

    /// Set once queues have moved from the old "3 at a time" default to "No limit".
    static var downloadsUnlimitedByDefault: Bool {
        get { store.value("downloads.unlimited", default: false) }
        set { store.set(newValue, for: "downloads.unlimited") }
    }

    static var downloadChromeSetUp: Bool {
        get { store.value("downloads.chrome", default: false) }
        set { store.set(newValue, for: "downloads.chrome") }
    }

    static var downloadColumns: [DownloadColumn] {
        get {
            guard let raw = store.raw("downloads.columns") as? [String] else { return DownloadColumn.defaults }
            return raw.compactMap(DownloadColumn.init(rawValue:))
        }
        set { store.set(newValue.map(\.rawValue), for: "downloads.columns") }
    }

    static var downloadButtons: [DownloadButton] {
        get {
            guard let raw = store.raw("downloads.buttons") as? [String] else { return DownloadButton.defaults }
            return raw.compactMap(DownloadButton.init(rawValue:))
        }
        set { store.set(newValue.map(\.rawValue), for: "downloads.buttons") }
    }

    // Screenshots

    static var screenshotFolder: URL {
        get {
            if let path = store.raw("screenshots.folder") as? String { return URL(fileURLWithPath: path, isDirectory: true) }
            return ScreenshotFolder.url
        }
        set { store.set(newValue.path, for: "screenshots.folder") }
    }

    static var screenshotAfterCapture: AfterCapture {
        get { AfterCapture(rawValue: store.value("screenshots.after", default: "")) ?? .edit }
        set { store.set(newValue.rawValue, for: "screenshots.after") }
    }

    // Shelf

    static var shelfShakeToOpen: Bool {
        get { store.value("shelf.shake", default: true) }
        set { store.set(newValue, for: "shelf.shake") }
    }

    /// false: shelves keep a link to dropped files; true: they keep their own copy.
    static var shelfCopiesFiles: Bool {
        get { store.value("shelf.copy", default: false) }
        set { store.set(newValue, for: "shelf.copy") }
    }

    static var shelfEdge: ShelfEdge {
        get { ShelfEdge(rawValue: store.value("shelf.edge", default: ShelfEdge.notch.rawValue)) ?? .notch }
        set { store.set(newValue.rawValue, for: "shelf.edge") }
    }

    static var shelfCatchScreenshots: Bool {
        get { store.value("shelf.screenshots", default: true) }
        set { store.set(newValue, for: "shelf.screenshots") }
    }

    static var shelfWatchedFolders: [String] {
        get { store.value("shelf.watched", default: [String]()) }
        set { store.set(newValue, for: "shelf.watched") }
    }

    // Snippets

    static var snippetsExpandWhileTyping: Bool {
        get { store.value("snippets.expand", default: true) }
        set { store.set(newValue, for: "snippets.expand") }
    }

    // Windows

    static var windowSnapping: Bool {
        get { store.value("windows.snap", default: true) }
        set { store.set(newValue, for: "windows.snap") }
    }

    /// Space in points left between snapped windows and screen edges.
    static var windowGap: Int {
        get { store.value("windows.gap", default: 0) }
        set { store.set(newValue, for: "windows.gap") }
    }

    // Clipboard

    static var clipboardLayout: ClipboardLayout {
        get { ClipboardLayout(rawValue: store.value("clipboard.layout", default: "")) ?? .list }
        set { store.set(newValue.rawValue, for: "clipboard.layout") }
    }

    /// Delete unpinned items not used for this many days (0 = never).
    static var clipboardAutoDeleteDays: Int {
        get { store.value("clipboard.autoDeleteDays", default: 0) }
        set { store.set(newValue, for: "clipboard.autoDeleteDays") }
    }

    static var clipboardReadImageText: Bool {
        get { store.value("clipboard.readImageText", default: true) }
        set { store.set(newValue, for: "clipboard.readImageText") }
    }

    static var clipboardPaused: Bool {
        get { store.value("paused", default: false) }
        set { store.set(newValue, for: "paused") }
    }

    static var pasteAfterSelect: Bool {
        get { store.value("pasteAfterSelect", default: true) }
        set { store.set(newValue, for: "pasteAfterSelect") }
    }

    /// 0 means unlimited. Pinned items never count toward the limit.
    static var historyLimit: Int {
        get { store.value("historyLimit", default: 1000) }
        set { store.set(newValue, for: "historyLimit") }
    }

    static var ignoredBundleIDs: [String] {
        get { store.value("ignoredBundleIDs", default: defaultIgnoredApps) }
        set { store.set(newValue, for: "ignoredBundleIDs") }
    }
}
