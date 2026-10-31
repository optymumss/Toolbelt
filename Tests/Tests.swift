import AppKit
import Carbon
import Network
import SwiftUI

// Automated checks for Toolbelt's logic. Run with: bash test.sh
// They use the real code (minus the app's startup) with a scratch data folder,
// the real clipboard and real global shortcut registration, so they need a Mac.

@main
enum ToolbeltTests {
    @MainActor
    static func main() {
        // Windows (the large preview) need an app object, but no Dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Must run before anything touches SettingsStore, to test migration from v0.1.
        UserDefaults.standard.set(200, forKey: "historyLimit")

        let t = TestRun()
        t.group("Settings", SettingsTests.run)
        t.group("Shortcuts", ShortcutTests.run)
        t.group("Modules", ModuleTests.run)
        t.group("Clipboard history", ClipboardStoreTests.run)
        t.group("Clipboard panel", PanelTests.run)
        t.group("Clipboard recording", MonitorTests.run)
        t.group("Images, links and iPhone copies", RichCopyTests.run)
        t.group("Pasting", PasterTests.run)
        t.group("Pasting images", ImagePasteTests.run)
        t.group("Large preview", PreviewTests.run)
        t.group("Launcher: calculator", CalculatorTests.run)
        t.group("Launcher: unit converter", ConverterTests.run)
        t.group("Launcher: matching and ranking", LauncherSearchTests.run)
        t.group("Launcher: quicklinks and commands", LauncherProviderTests.run)
        t.group("Windows: layouts", WindowLayoutTests.run)
        t.group("Windows: snapping and displays", SnapTests.run)
        t.group("Windows: moving a real window", RealWindowTests.run)
        t.group("Snippets: placeholders", PlaceholderTests.run)
        t.group("Snippets: spotting keywords", TypingBufferTests.run)
        t.group("Snippets: saving and searching", SnippetStoreTests.run)
        t.group("Snippets: expanding in a real text field", SnippetTypingTests.run)
        t.group("Shelf: shaking to open", ShakeTests.run)
        t.group("Shelf: dropping and dragging out", ShelfStoreTests.run)
        t.group("Downloads: planning parts", DownloadPlanTests.run)
        t.group("Downloads: real downloads from a test server", DownloadTests.run)
        t.group("Downloads: queues, schedules, limits and the list", DownloadsNextTests.run)
        t.group("Downloads: the Chrome extension and its bridge", ChromeBridgeTests.run)
        t.group("Screenshots: capture, mark up and read text", ScreenshotTests.run)
        t.group("Gestures: trackpad, mouse and keys", GestureTests.run)
        t.group("Automation: macros, triggers and steps", AutomationTests.run)
        t.group("Clipboard: transforms, editing and the paste stack", ClipboardNextTests.run)
        t.group("Clipboard: pinboards, named clipboards and auto-delete", ClipboardCollectionsTests.run)
        t.group("Clipboard: text in images", ImageTextTests.run)
        t.group("Launcher: recently used, switcher and notes", LauncherNextTests.run)
        t.group("Snippets: fill-in blanks, picker and folders", SnippetsNextTests.run)
        t.group("Windows: saved layouts and snap areas", WindowsNextTests.run)
        t.group("Shelf: edges, watched folders, actions and drop targets", ShelfNextTests.run)
        t.group("Settings backup", BackupTests.run)
        t.group("Services menu and right-click", ServicesTests.run)
        t.group("Whole app: using Toolbelt like a person would", EndToEndTests.run)

        UserDefaults.standard.removeObject(forKey: "historyLimit")
        t.finish()
    }
}

@MainActor
final class TestRun {
    static var current: TestRun!
    private var passed = 0
    private var failed: [String] = []

    init() { TestRun.current = self }

    func group(_ name: String, _ body: () -> Void) {
        print("\n▸ \(name)")
        body()
    }

    func record(_ ok: Bool, _ name: String, detail: String) {
        if ok {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed.append(name)
            print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed.count) failed")
        if !failed.isEmpty {
            print("Failed:")
            for name in failed { print("  - \(name)") }
        }
        exit(failed.isEmpty ? 0 : 1)
    }
}

@MainActor
func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    TestRun.current.record(condition, name, detail: condition ? "" : detail())
}

@MainActor
func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    TestRun.current.record(actual == expected, name, detail: "got \(actual), expected \(expected)")
}

/// Lets timers (like the clipboard monitor's) run for a while.
@MainActor
func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - Settings

@MainActor
enum SettingsTests {
    static func run() {
        checkEqual(Prefs.historyLimit, 200, "v0.1 settings are carried over")
        check(SettingsStore.folder.path.contains("toolbelt-test"), "tests use a scratch data folder", SettingsStore.folder.path)

        Prefs.appearance = .dark
        checkEqual(Prefs.appearance, .dark, "appearance is remembered")
        Prefs.appearance = .system

        Prefs.setEnabled(false, .clipboard)
        check(!Prefs.isEnabled(.clipboard), "a module can be turned off")
        Prefs.setEnabled(true, .clipboard)

        let file = SettingsStore.folder.appendingPathComponent("settings.plist")
        let saved = (try? Data(contentsOf: file))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        check(saved != nil, "settings are saved to settings.plist in the data folder")
        checkEqual(saved?["historyLimit"] as? Int, 200, "saved file holds the values")
        checkEqual(saved?["appearance"] as? String, "system", "saved file follows changes")
    }
}

// MARK: - Shortcuts

@MainActor
enum ShortcutTests {
    static let cmdShiftV = Shortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)

    static func run() {
        checkEqual(cmdShiftV.display, "⇧⌘V", "shortcut is shown with Mac symbols")
        checkEqual(Shortcut(keyCode: kVK_Space, modifiers: optionKey).display, "⌥Space", "named keys are spelled out")
        checkEqual(Shortcut(plist: cmdShiftV.plist), cmdShiftV, "shortcut survives saving and loading")
        check(cmdShiftV.isUsable, "⇧⌘V is allowed")
        check(!Shortcut(keyCode: kVK_ANSI_V, modifiers: shiftKey).isUsable, "⇧V alone is refused (it would block typing)")
        check(Shortcut(keyCode: kVK_F5, modifiers: 0).isUsable, "F5 alone is allowed")
        checkEqual(cmdShiftV.menuKeyEquivalent?.key, "v", "menu shows the shortcut")

        let center = ShortcutCenter()
        checkEqual(center.shortcut(for: .clipboardHistory), cmdShiftV, "clipboard history defaults to ⇧⌘V")

        center.setActive([.clipboardHistory])
        check(center.failed.isEmpty, "⇧⌘V registers as a global shortcut")

        // Another app holding the keys: simulated with a second registration.
        let other = Shortcut(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey | controlKey)
        let otherApp = HotKey(shortcut: other) {}
        check(otherApp.isRegistered, "test setup: second registration works")
        let message = center.assign(other, to: .clipboardHistory)
        check(message?.contains("Another app") == true, "warns when another app uses the keys", message ?? "no warning")
        checkEqual(center.shortcut(for: .clipboardHistory), cmdShiftV, "a taken shortcut isn't saved")
        otherApp.unregister()

        // macOS's own shortcuts
        let spotlight = Shortcut(keyCode: kVK_Space, modifiers: cmdKey)
        let systemMessage = center.assign(spotlight, to: .clipboardHistory)
        check(systemMessage?.contains("macOS") == true, "warns that macOS uses ⌘Space (Spotlight)", systemMessage ?? "no warning")

        // A free shortcut is saved and registered.
        let free = Shortcut(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey | controlKey | shiftKey)
        checkEqual(center.assign(free, to: .clipboardHistory), nil, "a free shortcut is accepted")
        checkEqual(center.shortcut(for: .clipboardHistory), free, "the new shortcut is saved")
        check(center.failed.isEmpty, "the new shortcut is registered")
        let probe = HotKey(shortcut: free) {}
        check(!probe.isRegistered, "Toolbelt really holds the new shortcut")
        probe.unregister()

        checkEqual(center.assign(nil, to: .clipboardHistory), nil, "a shortcut can be removed")
        checkEqual(center.shortcut(for: .clipboardHistory), nil, "removed shortcut stays removed")

        checkEqual(center.resetToDefault(.clipboardHistory), nil, "reset to default works")
        checkEqual(center.shortcut(for: .clipboardHistory), cmdShiftV, "reset brings back ⇧⌘V")

        // Something else grabbing the keys before Toolbelt starts.
        center.setActive([])
        let squatter = HotKey(shortcut: cmdShiftV) {}
        center.setActive([.clipboardHistory])
        check(center.failed.contains(.clipboardHistory), "a shortcut that's taken at launch is reported")
        squatter.unregister()
        center.setActive([])
    }
}

// MARK: - Modules

@MainActor
final class FakeModule: ToolbeltModule {
    let id = ModuleID.clipboard
    let openTitle = "Fake"
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func open() {}
    func menuItems() -> [NSMenuItem] { [] }
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func willTerminate() {}
}

@MainActor
enum ModuleTests {
    static func run() {
        let shortcuts = ShortcutCenter()
        let manager = ModuleManager(shortcuts: shortcuts)
        let module = FakeModule()
        manager.register(module)
        manager.setPaused(false)
        manager.setEnabled(true, .clipboard)

        manager.refresh()
        checkEqual(module.starts, 1, "an enabled module starts")
        check(manager.isRunning(.clipboard), "and is reported as running")

        manager.setEnabled(false, .clipboard)
        checkEqual(module.stops, 1, "turning a module off stops it")
        let probe = HotKey(shortcut: ShortcutTests.cmdShiftV) {}
        check(probe.isRegistered, "and releases its shortcut")
        probe.unregister()

        manager.setEnabled(true, .clipboard)
        checkEqual(module.starts, 2, "turning it back on starts it again")

        manager.setPaused(true)
        checkEqual(module.stops, 2, "pausing Toolbelt stops every module")
        check(Prefs.appPaused, "pause is remembered")

        manager.setPaused(false)
        checkEqual(module.starts, 3, "resuming starts modules again")
        manager.setEnabled(false, .clipboard)
        manager.setEnabled(true, .clipboard)
        shortcuts.setActive([])
    }
}

// MARK: - Clipboard store

@MainActor
enum ClipboardStoreTests {
    static func text(_ s: String) -> ClipItem {
        ClipItem(kind: .text, text: s, hash: Hashing.of("text:" + s))
    }

    static func run() {
        let store = ClipboardStore()
        store.clearUnpinned()
        for item in store.items where item.pinned { store.delete(item.id) }

        store.add(text("one"))
        store.add(text("two"))
        store.add(text("one"))
        checkEqual(store.items.map { $0.text ?? "" }, ["one", "two"], "copying again moves an item to the top instead of duplicating it")

        store.togglePin(store.items[1].id) // pin "two"
        Prefs.historyLimit = 200
        for i in 0..<205 { store.add(text("bulk \(i)")) }
        checkEqual(store.items.filter { !$0.pinned }.count, 200, "history is trimmed to the limit")
        check(store.items.contains { $0.text == "two" && $0.pinned }, "pinned items survive trimming")

        store.clearUnpinned()
        checkEqual(store.items.map { $0.text ?? "" }, ["two"], "Clear History keeps pinned items")

        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        store.add(ClipItem(kind: .image, imageWidth: 4, imageHeight: 3, hash: Hashing.of(png)), imageData: png)
        let image = store.items[0]
        check(store.imageURL(for: image).map { FileManager.default.fileExists(atPath: $0.path) } == true, "images are saved as files")
        store.delete(image.id)
        check(store.imageURL(for: image).map { !FileManager.default.fileExists(atPath: $0.path) } == true, "deleting an image removes its file")

        store.add(text("saved"))
        store.saveNow()
        let reloaded = ClipboardStore()
        checkEqual(reloaded.items.map { $0.text ?? "" }, ["saved", "two"], "history is still there after a restart")

        Prefs.historyLimit = 1000
    }
}

// MARK: - Panel

@MainActor
enum PanelTests {
    static func run() {
        let store = ClipboardStore()
        store.clearUnpinned()
        for item in store.items { store.delete(item.id) }
        store.add(ClipboardStoreTests.text("hello world"))
        store.add(ClipItem(kind: .link, text: "https://example.com", hash: Hashing.of("text:https://example.com")))
        store.add(ClipItem(kind: .file, filePaths: ["/tmp/report.pdf"], hash: Hashing.of("file:/tmp/report.pdf")))

        let model = PanelModel(store: store)
        checkEqual(model.results.count, 3, "All shows everything")
        model.filter = .links
        checkEqual(model.results.map(\.kind), [.link], "Links filter")
        model.filter = .files
        checkEqual(model.results.map(\.kind), [.file], "Files filter")
        model.filter = .all
        model.query = "WORLD"
        checkEqual(model.results.map { $0.text ?? "" }, ["hello world"], "search ignores upper/lower case")
        model.query = "report"
        checkEqual(model.results.map(\.kind), [.file], "search finds file names")
        model.query = ""

        model.selectFirst()
        model.move(1)
        checkEqual(model.selectedItem?.kind, .link, "↓ moves the selection")
        model.move(10)
        checkEqual(model.selectedItem?.kind, .text, "selection stops at the last item")
        checkEqual(model.item(at: 0)?.kind, .file, "⌘1 is the newest item")

        model.cycleFilter(1)
        checkEqual(model.filter, .pinned, "⇥ moves to the next filter")
        model.cycleFilter(-1)
        model.cycleFilter(-1)
        checkEqual(model.filter, .files, "⇧⇥ wraps around backwards")
    }
}

// MARK: - Recording from the real clipboard

@MainActor
enum MonitorTests {
    static func run() {
        let store = ClipboardStore()
        store.clearUnpinned()
        for item in store.items { store.delete(item.id) }
        let monitor = ClipboardMonitor(store: store)
        let pb = NSPasteboard.general
        Prefs.clipboardPaused = false
        monitor.start()

        pb.clearContents()
        pb.setString("copied text \(UUID())", forType: .string)
        spin(1)
        check(store.items.first?.text?.hasPrefix("copied text") == true, "copied text is recorded", "\(store.items.count) items")

        pb.clearContents()
        pb.setString("https://www.apple.com/macos", forType: .string)
        spin(1)
        checkEqual(store.items.first?.kind, .link, "copied web addresses are recorded as links")

        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString("secret-password", forType: .string)
        spin(1)
        check(!store.items.contains { $0.text == "secret-password" }, "passwords marked private are skipped")

        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        pb.clearContents()
        pb.writeObjects([image])
        spin(1)
        checkEqual(store.items.first?.kind, .image, "copied images are recorded")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-test-file.txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        spin(1)
        checkEqual(store.items.first?.kind, .file, "files copied in Finder are recorded")

        let countBefore = store.items.count
        Prefs.clipboardPaused = true
        pb.clearContents()
        pb.setString("while paused", forType: .string)
        spin(1)
        checkEqual(store.items.count, countBefore, "nothing is recorded while recording is paused")
        Prefs.clipboardPaused = false

        monitor.stop()
        pb.clearContents()
        pb.setString("while off", forType: .string)
        spin(1)
        checkEqual(store.items.count, countBefore, "nothing is recorded while the module is off")

        monitor.start()
        spin(1)
        checkEqual(store.items.count, countBefore, "turning back on doesn't record what was copied while off")
        monitor.stop()
    }
}

// MARK: - Pasting

@MainActor
enum PasterTests {
    static func run() {
        let store = ClipboardStore()
        let monitor = ClipboardMonitor(store: store)
        let paster = Paster(store: store, monitor: monitor)
        let pb = NSPasteboard.general

        let styled = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = styled.rtf(from: NSRange(location: 0, length: styled.length))
        let item = ClipItem(kind: .text, text: "bold", rtf: rtf, hash: "x")

        paster.write(item, plainText: false)
        check(pb.data(forType: .rtf) != nil, "pasting keeps formatting")
        checkEqual(pb.string(forType: .string), "bold", "and the text")

        paster.write(item, plainText: true)
        check(pb.data(forType: .rtf) == nil, "⌥↩ pastes without formatting")
        checkEqual(pb.string(forType: .string), "bold", "but keeps the text")

        let files = ClipItem(kind: .file, filePaths: ["/tmp/a.txt", "/tmp/b.txt"], hash: "y")
        paster.write(files, plainText: true)
        checkEqual(pb.string(forType: .string), "/tmp/a.txt\n/tmp/b.txt", "files paste as their paths in plain-text mode")
    }
}

// MARK: - Images, links and copies from other devices

@MainActor
enum RichCopyTests {
    static func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        // Vary the pixels so each test image has a different hash.
        rep.setColor(NSColor(red: CGFloat(width % 255) / 255, green: 0.5, blue: 0.2, alpha: 1), atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }

    static func run() {
        let store = ClipboardStore()
        store.clearUnpinned()
        for item in store.items { store.delete(item.id) }
        let monitor = ClipboardMonitor(store: store)
        let pb = NSPasteboard.general
        Prefs.clipboardPaused = false
        monitor.start()

        // A screenshot copied with ⌃⇧⌘4 arrives as PNG data.
        pb.clearContents()
        pb.setData(pngData(width: 640, height: 400), forType: .png)
        spin(1)
        let shot = store.items.first
        checkEqual(shot?.kind, .image, "screenshots copied to the clipboard are recorded as images")
        checkEqual(shot.map { "\($0.imageWidth ?? 0)×\($0.imageHeight ?? 0)" }, "640×400", "and keep their size")

        // "Copy Image" in Safari or Chrome: the image plus its web address as text.
        pb.clearContents()
        pb.declareTypes([.tiff, .string], owner: nil)
        pb.setData(NSImage(data: pngData(width: 300, height: 200))!.tiffRepresentation!, forType: .tiff)
        pb.setString("https://example.com/photos/cat.jpg", forType: .string)
        spin(1)
        checkEqual(store.items.first?.kind, .image, "an image copied in a browser is kept as an image, not just its address")
        checkEqual(store.items.first?.text, "https://example.com/photos/cat.jpg", "and remembers where it came from")
        let browserImage = store.items.first
        check(browserImage.map { PanelModel.matches($0, "cat.jpg") } == true, "and can be found by searching its address")

        // Text copied from a document that also carries a picture of the selection stays text.
        pb.clearContents()
        pb.declareTypes([.string, .png], owner: nil)
        pb.setString("Quarterly results are up 12 percent", forType: .string)
        pb.setData(pngData(width: 120, height: 40), forType: .png)
        spin(1)
        checkEqual(store.items.first?.kind, .text, "copied text that comes with a picture is kept as text")

        // A link with its page title, as browsers copy it.
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("public.url-name")], owner: nil)
        pb.setString("https://www.apple.com/macos/", forType: .string)
        pb.setString("macOS - Apple", forType: NSPasteboard.PasteboardType("public.url-name"))
        spin(1)
        checkEqual(store.items.first?.kind, .link, "links are recorded as links")
        checkEqual(store.items.first?.linkTitle, "macOS - Apple", "and keep the page title")
        check(store.items.first.map { PanelModel.matches($0, "apple macos") } == true, "links can be found by their page title")

        check(ClipboardMonitor.isLink("http://example.com/a?b=c"), "http links are recognised")
        check(!ClipboardMonitor.isLink("see https://example.com for more"), "a sentence containing a link stays text")
        check(!ClipboardMonitor.isLink("example.com"), "plain names without https:// stay text")

        // Universal Clipboard: copied on an iPhone or iPad.
        pb.clearContents()
        pb.declareTypes([.string, ClipboardMonitor.remoteType], owner: nil)
        pb.setString("Copied on my iPhone", forType: .string)
        spin(1)
        checkEqual(store.items.first?.text, "Copied on my iPhone", "copies from an iPhone or iPad are recorded")
        checkEqual(store.items.first?.fromOtherDevice, true, "and marked as coming from another device")
        checkEqual(store.items.first?.sourceAppName, "iPhone or iPad", "and labelled iPhone or iPad")

        pb.clearContents()
        pb.declareTypes([.png, ClipboardMonitor.remoteType], owner: nil)
        pb.setData(pngData(width: 90, height: 160), forType: .png)
        spin(1)
        checkEqual(store.items.first?.kind, .image, "photos copied on an iPhone are recorded as images")

        monitor.stop()

        // Old history files (from v0.2 and earlier) still load.
        let old = #"[{"id":"\#(UUID().uuidString)","kind":"text","text":"old","hash":"h","created":0,"lastUsed":0,"pinned":false}]"#
        let decoded = try? JSONDecoder().decode([ClipItem].self, from: Data(old.utf8))
        checkEqual(decoded?.first?.text, "old", "history saved by earlier versions still loads")
    }
}

// MARK: - Large preview

@MainActor
enum PreviewTests {
    static func run() {
        check(!SpaceKey.isHold(pressedAt: 10, releasedAt: 10.1), "a quick tap of Space keeps the preview open")
        check(SpaceKey.isHold(pressedAt: 10, releasedAt: 10.8), "holding Space closes the preview when released")

        let store = ClipboardStore()
        let controller = LargePreviewController(store: store)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let item = ClipboardStoreTests.text("Preview me")
        controller.show(item, over: parent)
        check(controller.isVisible, "the preview opens")
        let other = ClipboardStoreTests.text("Next item")
        controller.update(other, over: parent)
        checkEqual(controller.item?.text, "Next item", "the preview follows the selection")
        controller.hide()
        check(!controller.isVisible, "the preview closes")
        controller.update(item, over: parent)
        check(!controller.isVisible, "moving the selection doesn't reopen a closed preview")
    }
}

// MARK: - Pasting images

@MainActor
enum ImagePasteTests {
    static func run() {
        let store = ClipboardStore()
        let paster = Paster(store: store, monitor: ClipboardMonitor(store: store))
        let png = RichCopyTests.pngData(width: 50, height: 30)
        store.add(ClipItem(kind: .image, imageWidth: 50, imageHeight: 30, hash: Hashing.of(png)), imageData: png)
        guard let item = store.items.first(where: { $0.kind == .image }) else {
            check(false, "test setup: image item")
            return
        }
        paster.write(item, plainText: false)
        let pb = NSPasteboard.general
        check(pb.data(forType: .png) != nil, "images paste as PNG")
        check(pb.data(forType: .tiff) != nil, "and as TIFF, for older apps")
    }
}

// MARK: - Launcher

@MainActor
enum CalculatorTests {
    static func run() {
        checkEqual(Calculator.evaluate("12 * 7 + 1"), 85, "12 * 7 + 1 = 85")
        checkEqual(Calculator.evaluate("(3 + 4)^2"), 49, "brackets and powers")
        checkEqual(Calculator.evaluate("2^3^2"), 512, "powers work right to left")
        checkEqual(Calculator.evaluate("-2^2"), -4, "minus applies after the power, like on paper")
        checkEqual(Calculator.evaluate("10 / 4"), 2.5, "division with a decimal answer")
        checkEqual(Calculator.evaluate("250 * 15%"), 37.5, "percentages")
        checkEqual(Calculator.evaluate("sqrt(16) + abs(-3)"), 7, "functions")
        checkEqual(Calculator.evaluate("1,000 + 1"), 1001, "thousands separators")
        checkEqual(Calculator.evaluate("6 × 7 ÷ 2"), 21, "× and ÷ signs")
        checkEqual(Calculator.evaluate("2 +"), nil, "an unfinished sum gives no answer")
        checkEqual(Calculator.evaluate("1 / 0"), nil, "dividing by zero gives no answer")
        checkEqual(Calculator.format(0.1 + 0.2), "0.3", "answers are tidied (0.1 + 0.2 shows 0.3)")
        checkEqual(Calculator.format(1024), "1024", "whole numbers have no decimals")
        check(Calculator.isCalculation("12*7"), "12*7 is treated as a sum")
        check(!Calculator.isCalculation("2048"), "a plain number isn't")
        check(!Calculator.isCalculation("iphone 15"), "words with numbers aren't")
        check(!Calculator.isCalculation("e"), "a single letter isn't")
    }
}

@MainActor
enum ConverterTests {
    static func value(_ text: String) -> Double? {
        UnitConverter.convert(text).map { ($0.value * 1000).rounded() / 1000 }
    }

    static func run() {
        checkEqual(value("5 km in miles"), 3.107, "5 km in miles")
        checkEqual(value("100 f to c"), 37.778, "100 °F in °C")
        checkEqual(value("1 kg in lb"), 2.205, "kilograms to pounds")
        checkEqual(value("3 ft in cm"), 91.44, "feet to centimetres")
        checkEqual(value("5 in in cm"), 12.7, "inches (\"in in\") to centimetres")
        checkEqual(value("2 GB to MB"), 2000, "gigabytes to megabytes")
        checkEqual(value("1.5 hours in minutes"), 90, "hours to minutes")
        checkEqual(value("2 weeks in days"), 14, "weeks to days")
        checkEqual(value("60 mph in kph"), 96.561, "speeds")
        checkEqual(UnitConverter.convert("5 km in miles")?.text, "3.10686 miles", "the answer is shown with its unit")
        checkEqual(value("5 kg in km"), nil, "different kinds of unit don't convert")
        checkEqual(value("5 bananas in apples"), nil, "unknown units are ignored")
    }
}

@MainActor
final class StaticProvider: LauncherProvider {
    let list: [LauncherResult]
    init(_ list: [LauncherResult]) { self.list = list }
    func results(for query: String) -> [LauncherResult] { list }
}

@MainActor
enum LauncherSearchTests {
    static func run() {
        check(FuzzyMatch.score("saf", "Safari") > FuzzyMatch.score("saf", "Kids Safari Game"), "names starting with the text come first")
        check(FuzzyMatch.score("vsc", "Visual Studio Code") > 0, "initials find apps (vsc → Visual Studio Code)")
        check(FuzzyMatch.score("code", "Visual Studio Code") > 0, "any word in the name matches")
        check(FuzzyMatch.score("sfri", "Safari") > 0, "letters in order with gaps match")
        checkEqual(FuzzyMatch.score("xyz", "Safari"), 0, "unrelated text doesn't match")
        checkEqual(FuzzyMatch.score("Safari", "Safari"), 100, "an exact name scores highest")

        let apps = AppsProvider()
        let safari = apps.results(for: "safari").first
        checkEqual(safari?.title, "Safari", "finds Safari in Applications")
        check(apps.results(for: "calc").contains { $0.title == "Calculator" }, "finds Calculator")
        check(apps.results(for: "sys set").contains { $0.title == "System Settings" }, "finds System Settings from \"sys set\"")
        check(apps.results(for: "finder").contains { $0.title == "Finder" }, "finds Finder")

        check(FileSearch.isProgramData("/Users/me/code/app/node_modules/lodash/index.js"), "program folders like node_modules are left out of file results")
        check(FileSearch.isProgramData("/Users/me/.config/thing"), "hidden folders are left out")
        check(!FileSearch.isProgramData("/Users/me/Documents/Taxes 2026.pdf"), "your documents are kept")

        Prefs.launcherSearchFiles = false
        let model = LauncherModel { [CalculatorProvider(), apps, StaticProvider([
            LauncherResult(id: "a", title: "A", kind: "Test", icon: .symbol("a"), score: 10) {},
            LauncherResult(id: "b", title: "B", kind: "Test", icon: .symbol("b"), score: 50) {},
        ])] }
        model.query = "2+2"
        checkEqual(model.results.first?.title, "= 4", "sums are answered first")
        model.query = "saf"
        checkEqual(model.results.first?.title, "Safari", "best match is selected first")
        checkEqual(model.selectedIndex, 0, "selection starts at the top")
        model.move(1)
        checkEqual(model.selectedIndex, 1, "↓ moves down")
        model.move(-5)
        checkEqual(model.selectedIndex, 0, "↑ stops at the top")
        model.query = ""
        check(model.results.isEmpty, "an empty search shows the tips instead of results")
        Prefs.launcherSearchFiles = true
    }
}

@MainActor
enum LauncherProviderTests {
    static func run() {
        let google = Quicklink(keyword: "g", name: "Google", url: "https://www.google.com/search?q={query}")
        checkEqual(google.address(for: "big cats")?.absoluteString, "https://www.google.com/search?q=big%20cats", "quicklink search words go into the address")
        checkEqual(google.address(for: "a&b")?.absoluteString, "https://www.google.com/search?q=a%26b", "special characters are made safe")
        checkEqual(google.homePage?.absoluteString, "https://www.google.com", "without search words it opens the home page")

        let provider = QuicklinksProvider()
        Prefs.quicklinks = Quicklink.defaults
        checkEqual(provider.results(for: "g cats").first?.title, "Search Google for “cats”", "\"g cats\" searches Google")
        checkEqual(provider.results(for: "yt lofi").first?.title, "Search YouTube for “lofi”", "\"yt lofi\" searches YouTube")
        check(provider.results(for: "zz cats").isEmpty, "an unknown keyword does nothing")
        Prefs.quicklinks = [Quicklink(keyword: "imdb", name: "IMDb", url: "https://www.imdb.com/find?q={query}")]
        checkEqual(provider.results(for: "imdb dune").first?.title, "Search IMDb for “dune”", "your own quicklinks work")
        checkEqual(Prefs.quicklinks.first?.keyword, "imdb", "quicklinks are saved")
        Prefs.quicklinks = Quicklink.defaults

        let commands = SystemCommandsProvider()
        checkEqual(commands.results(for: "lock").first?.title, "Lock Screen", "\"lock\" finds Lock Screen")
        check(commands.results(for: "dark").contains { $0.title == "Toggle Dark Mode" }, "\"dark\" finds Toggle Dark Mode")
        check(commands.results(for: "trash").contains { $0.title == "Empty Bin" }, "\"trash\" finds Empty Bin")
        check(commands.results(for: "reboot").contains { $0.title == "Restart" }, "\"reboot\" finds Restart")
        check(commands.results(for: "sleep").contains { $0.title == "Sleep" }, "\"sleep\" finds Sleep")

        let store = ClipboardStore()
        store.add(ClipboardStoreTests.text("42 Example Street, London"))
        let clips = ClipboardLauncherProvider(store: store, paster: Paster(store: store, monitor: ClipboardMonitor(store: store)))
        checkEqual(clips.results(for: "example street").first?.title, "42 Example Street, London", "the launcher finds clipboard history")
        checkEqual(clips.results(for: "example street").first?.kind, "Clipboard", "and labels it Clipboard")

        let center = ShortcutCenter()
        let clash = center.assign(Shortcut(keyCode: kVK_Space, modifiers: optionKey), to: .clipboardHistory)
        check(clash?.contains("Toolbelt already uses") == true, "warns when another Toolbelt shortcut (the launcher's ⌥Space) has the keys", clash ?? "no warning")
        checkEqual(ShortcutAction.openLauncher.defaultShortcut?.display, "⌥Space", "the launcher opens with ⌥Space")
    }
}

// MARK: - Window management

@MainActor
enum WindowLayoutTests {
    // A 1440 × 900 screen with a 25-point menu bar and no Dock, in top-left coordinates.
    static let area = CGRect(x: 0, y: 25, width: 1440, height: 875)
    static let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    static func frame(_ action: WindowAction, gap: CGFloat = 0) -> CGRect? {
        WindowLayout.frame(for: action, in: area, current: window, gap: gap)
    }

    static func run() {
        checkEqual(frame(.leftHalf), CGRect(x: 0, y: 25, width: 720, height: 875), "left half")
        checkEqual(frame(.rightHalf), CGRect(x: 720, y: 25, width: 720, height: 875), "right half")
        checkEqual(frame(.topHalf), CGRect(x: 0, y: 25, width: 1440, height: 438), "top half (rounded to whole points)")
        checkEqual(frame(.bottomHalf)?.maxY, 900, "bottom half reaches the bottom")
        checkEqual(frame(.topLeft), CGRect(x: 0, y: 25, width: 720, height: 438), "top left quarter")
        checkEqual(frame(.bottomRight)?.origin, CGPoint(x: 720, y: 462), "bottom right quarter")
        checkEqual(frame(.firstThird), CGRect(x: 0, y: 25, width: 480, height: 875), "first third")
        checkEqual(frame(.centerThird)?.minX, 480, "centre third")
        checkEqual(frame(.lastThird)?.minX, 960, "last third")
        checkEqual(frame(.firstTwoThirds)?.width, 960, "first two thirds")
        checkEqual(frame(.lastTwoThirds), CGRect(x: 480, y: 25, width: 960, height: 875), "last two thirds")
        checkEqual(frame(.maximize), area, "maximise fills the usable area")
        checkEqual(frame(.center), CGRect(x: 320, y: 163, width: 800, height: 600), "centre keeps the size")
        let big = WindowLayout.frame(for: .center, in: area, current: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        checkEqual(big, area, "centre shrinks a window bigger than the screen")
        checkEqual(frame(.restore), nil, "restore isn't a screen position")

        checkEqual(frame(.leftHalf, gap: 10), CGRect(x: 10, y: 35, width: 705, height: 855), "gaps leave space at the edges")
        let left = frame(.leftHalf, gap: 10)!, right = frame(.rightHalf, gap: 10)!
        checkEqual(right.minX - left.maxX, 10, "and between neighbouring windows")

        // AppKit counts y from the bottom; the Accessibility API from the top.
        checkEqual(WindowLayout.flip(CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900),
                   CGRect(x: 0, y: 25, width: 1440, height: 875), "screen coordinates are converted correctly")
    }
}

@MainActor
enum SnapTests {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    static func run() {
        checkEqual(SnapZone.action(for: CGPoint(x: 0, y: 450), in: screen), .leftHalf, "dragging to the left edge snaps to the left half")
        checkEqual(SnapZone.action(for: CGPoint(x: 1439, y: 450), in: screen), .rightHalf, "right edge → right half")
        checkEqual(SnapZone.action(for: CGPoint(x: 700, y: 0), in: screen), .maximize, "top edge → fill the screen")
        checkEqual(SnapZone.action(for: CGPoint(x: 0, y: 5), in: screen), .topLeft, "top left corner → quarter")
        checkEqual(SnapZone.action(for: CGPoint(x: 1439, y: 899), in: screen), .bottomRight, "bottom right corner → quarter")
        checkEqual(SnapZone.action(for: CGPoint(x: 700, y: 450), in: screen), nil, "the middle of the screen doesn't snap")
        checkEqual(SnapZone.action(for: CGPoint(x: 700, y: 899), in: screen), nil, "the bottom edge (Dock) doesn't snap")

        // Two screens side by side: a 1440 × 900 laptop and a 2560 × 1440 monitor to its right.
        let laptop = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let monitor = CGRect(x: 1440, y: 25, width: 2560, height: 1415)
        let moved = WindowLayout.move(CGRect(x: 720, y: 25, width: 720, height: 875), from: laptop, to: monitor)
        check(monitor.contains(moved), "moving to the next display lands on that display", "\(moved)")
        checkEqual(moved.size, CGSize(width: 720, height: 875), "a window that fits keeps its size")
        let back = WindowLayout.move(CGRect(x: 1440, y: 25, width: 2560, height: 1415), from: monitor, to: laptop)
        checkEqual(back, laptop, "a window too big for the smaller display is shrunk to fit")

        check(ShortcutAction.allCases.count == Set(ShortcutAction.allCases.map(\.rawValue)).count, "every shortcut has its own saved name")
        let defaults = ShortcutAction.allCases.compactMap(\.defaultShortcut)
        checkEqual(defaults.count, Set(defaults).count, "no two default shortcuts clash")
        checkEqual(ShortcutAction.window(.leftHalf).defaultShortcut?.display, "⌃⌥←", "left half is ⌃⌥←")
        checkEqual(ShortcutAction.window(.maximize).defaultShortcut?.display, "⌃⌥↩", "maximise is ⌃⌥↩")

        let provider = WindowsLauncherProvider(manager: WindowManager())
        checkEqual(provider.results(for: "left half").first?.title, "Left Half", "the launcher finds window moves")
    }
}

/// Moves a real Finder window, if this Mac lets the tests use Accessibility.
@MainActor
enum RealWindowTests {
    static func run() {
        guard AXIsProcessTrusted() else {
            print("  – skipped: this Mac hasn't given the test program the Accessibility permission")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        spin(2.5)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let window = AXWindow.focused(in: finder.processIdentifier),
              let before = window.frame else {
            check(false, "a Finder window opens to test with")
            return
        }
        check(true, "a Finder window opens to test with")
        let manager = WindowManager()
        check(manager.perform(.leftHalf, on: window), "left half runs")
        spin(0.5)
        let area = Screens.all[Screens.index(containing: before)].area
        let expected = WindowLayout.frame(for: .leftHalf, in: area, current: before, gap: CGFloat(Prefs.windowGap))!
        let after = window.frame ?? .zero
        check(abs(after.minX - expected.minX) < 2 && abs(after.minY - expected.minY) < 2, "the window moved to the left edge", "now \(after), expected \(expected)")
        check(abs(after.width - expected.width) < 2, "and is half the screen wide", "width \(after.width)")

        manager.perform(.restore, on: window)
        spin(0.5)
        let restored = window.frame ?? .zero
        check(abs(restored.minX - before.minX) < 2 && abs(restored.width - before.width) < 2, "restore puts it back", "now \(restored), was \(before)")

        // Close the test window so it doesn't sit in front of later screenshots.
        var close: CFTypeRef?
        if AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &close) == .success,
           let close, CFGetTypeID(close) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
        }
    }
}

// MARK: - Snippets

@MainActor
enum PlaceholderTests {
    static func run() {
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                  year: 2026, month: 3, day: 14, hour: 9, minute: 5).date!
        let uk = Locale(identifier: "en_GB")
        checkEqual(Placeholders.render("Plain text", now: date).text, "Plain text", "text without placeholders is unchanged")
        checkEqual(Placeholders.render("Today is {date}", now: date, locale: uk).text, "Today is 14 Mar 2026", "{date}")
        checkEqual(Placeholders.render("{time}", now: date, locale: uk).text, "09:05", "{time}")
        checkEqual(Placeholders.render("{date:yyyy-MM-dd}", now: date).text, "2026-03-14", "{date:…} with your own format")
        checkEqual(Placeholders.render("Re: {clipboard}", clipboard: "Invoice 42").text, "Re: Invoice 42", "{clipboard}")
        let cursor = Placeholders.render("Dear {cursor},\nThanks")
        checkEqual(cursor.text, "Dear ,\nThanks", "{cursor} is removed from the text")
        checkEqual(cursor.cursorFromEnd, 8, "and the cursor goes back to where it was")
        checkEqual(Placeholders.render("{unknown} {braces", now: date).text, "{unknown} {braces", "other braces are left alone")
    }
}

@MainActor
enum TypingBufferTests {
    static let snippets = [
        Snippet(keyword: ";addr", name: "Address", text: "42 Example Street"),
        Snippet(keyword: "omw", name: "On my way", text: "On my way!"),
    ]

    static func typing(_ text: String) -> TypingBuffer {
        var buffer = TypingBuffer()
        for ch in text { buffer.type(String(ch)) }
        return buffer
    }

    static func run() {
        checkEqual(typing("hello ;addr").match(in: snippets)?.name, "Address", "a keyword at the end is spotted")
        checkEqual(typing(";add").match(in: snippets)?.name, nil, "an unfinished keyword isn't")
        checkEqual(typing("I'm omw").match(in: snippets)?.name, "On my way", "word keywords work after a space")
        checkEqual(typing("zomw").match(in: snippets)?.name, nil, "but not in the middle of a word")
        var buffer = typing(";adx")
        buffer.deleteBackward()
        buffer.type("dr")
        checkEqual(buffer.match(in: snippets)?.name, "Address", "typing mistakes fixed with ⌫ still count")
        buffer.reset()
        checkEqual(buffer.text, "", "clicking or pressing arrows starts afresh")
        checkEqual(typing(String(repeating: "x", count: 500) + ";addr").match(in: snippets)?.name, "Address", "long typing doesn't break it")
    }
}

@MainActor
enum SnippetStoreTests {
    static func run() {
        let store = SnippetStore()
        store.snippets = [Snippet(keyword: ";tb", name: "Toolbelt", text: "Toolbelt is {cursor}great")]
        let reloaded = SnippetStore()
        checkEqual(reloaded.snippets.first?.keyword, ";tb", "snippets are saved")
        check(FileManager.default.fileExists(atPath: SettingsStore.folder.appendingPathComponent("snippets.json").path), "in snippets.json in the data folder")

        let provider = SnippetsLauncherProvider(store: store)
        checkEqual(provider.results(for: "toolbelt").first?.kind, "Snippet", "the launcher finds snippets by name")
        checkEqual(provider.results(for: ";tb").first?.title, "Toolbelt", "and by keyword")
    }
}

/// Types a keyword into TextEdit, like a person would, and checks it expands — if this Mac
/// lets the test program use Input Monitoring and Accessibility.
@MainActor
enum SnippetTypingTests {
    static func run() {
        guard AXIsProcessTrusted(), Permission.inputMonitoring.isGranted else {
            print("  – skipped: this Mac hasn't given the test program Input Monitoring and Accessibility")
            return
        }
        // A real app with an empty document, in front, ready for typing.
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: document.path, contents: Data())
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "TextEdit", document.path]
        try? open.run()
        open.waitUntilExit()
        spin(3)
        guard let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            check(false, "TextEdit opens to type into")
            return
        }
        textEdit.activate()
        spin(1)
        check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit", "TextEdit is in front, ready for typing")

        let store = SnippetStore()
        store.snippets = [Snippet(keyword: ";tb", name: "Toolbelt", text: "Toolbelt says hi")]
        let expander = SnippetExpander(store: store)
        check(expander.start(), "listening to typing starts")

        for key in [kVK_ANSI_Semicolon, kVK_ANSI_T, kVK_ANSI_B] {
            typeKey(CGKeyCode(key))
            spin(0.15)
        }
        spin(2)
        checkEqual(text(in: textEdit), "Toolbelt says hi", "typing ;tb in TextEdit turns into the snippet")
        expander.stop()
        textEdit.forceTerminate()
        try? FileManager.default.removeItem(at: document)
    }

    /// The text in the app's focused text area, read through Accessibility.
    static func text(in app: NSRunningApplication) -> String {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "(nothing focused)" }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value)
        return value as? String ?? "(no text)"
    }

    /// A key press as if from the keyboard (not marked as Toolbelt's own).
    static func typeKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

// MARK: - Shelf

@MainActor
enum ShakeTests {
    static func feed(_ xs: [CGFloat], every step: TimeInterval) -> Bool {
        var detector = ShakeDetector()
        var shook = false
        for (i, x) in xs.enumerated() where detector.add(x: x, time: Double(i) * step) {
            shook = true
        }
        return shook
    }

    static func run() {
        // Left-right-left-right… 60 points each way, a few times a second.
        var zigzag: [CGFloat] = []
        for swing in 0..<6 {
            let from: CGFloat = swing % 2 == 0 ? 400 : 460
            let to: CGFloat = swing % 2 == 0 ? 460 : 400
            for step in 0...5 { zigzag.append(from + (to - from) * CGFloat(step) / 5) }
        }
        check(feed(zigzag, every: 0.016), "a quick shake while dragging opens a shelf")
        check(!feed(zigzag, every: 0.2), "a slow back-and-forth doesn't")
        check(!feed(Array(stride(from: 0, to: 600, by: 10)), every: 0.016), "a straight drag doesn't")
        let tiny = zigzag.map { 400 + ($0 - 400) / 10 }
        check(!feed(tiny, every: 0.016), "a tiny wobble doesn't")
    }
}

@MainActor
enum ShelfStoreTests {
    static func pasteboard(_ objects: [NSPasteboardWriting]) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("toolbelt-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(objects)
        return pb
    }

    static func run() {
        let store = ShelfStore()
        for shelf in store.shelves { store.remove(shelf.id) }
        let first = store.newShelf()
        let second = store.newShelf()
        check(first.color != second.color, "each new shelf gets its own colour")
        checkEqual(second.name, "Shelf 2", "new shelves are numbered")

        let original = FileManager.default.temporaryDirectory.appendingPathComponent("Shelf test.txt")
        try? "hello".write(to: original, atomically: true, encoding: .utf8)

        store.add(from: pasteboard([original as NSURL]), to: first.id, copyFiles: false)
        checkEqual(store.shelf(first.id)?.items.last?.path, original.path, "dropped files are linked to where they are")
        store.add(from: pasteboard([original as NSURL]), to: first.id, copyFiles: true)
        let copy = store.shelf(first.id)?.items.last
        check(copy?.isCopy == true && copy?.path != original.path, "or copied onto the shelf, if you choose")
        check(copy?.path.map { FileManager.default.fileExists(atPath: $0) } == true, "the copy exists")

        store.add(from: pasteboard(["Remember the invoice" as NSString]), to: first.id)
        checkEqual(store.shelf(first.id)?.items.last?.kind, .text, "dropped text is kept as text")
        store.add(from: pasteboard([URL(string: "https://www.apple.com")! as NSURL]), to: first.id)
        checkEqual(store.shelf(first.id)?.items.last?.kind, .link, "dropped links are kept as links")
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemGreen.setFill(); rect.fill(); return true
        }
        store.add(from: pasteboard([image]), to: first.id)
        let imageItem = store.shelf(first.id)?.items.last
        checkEqual(imageItem?.kind, .image, "dropped images are kept as images")
        check(imageItem?.path?.hasSuffix(".png") == true, "and saved as PNG files")
        checkEqual(store.shelf(first.id)?.items.count, 5, "one shelf holds everything dropped on it")

        checkEqual((store.shelf(first.id)?.items.first?.dragWriter as? URL)?.path, original.path, "files drag out as the file itself")
        checkEqual(store.shelf(first.id)?.items[2].dragWriter as? String, "Remember the invoice", "text drags out as text")

        let reloaded = ShelfStore()
        checkEqual(reloaded.shelf(first.id)?.items.count, 5, "shelves are still there after a restart")

        store.update(first.id) { $0.name = "Taxes"; $0.color = .red }
        checkEqual(ShelfStore().shelf(first.id)?.name, "Taxes", "shelves can be renamed")
        checkEqual(ShelfStore().shelf(first.id)?.color, .red, "and colour-tagged")

        let copiedPath = copy?.path ?? ""
        store.remove(first.id)
        check(!FileManager.default.fileExists(atPath: copiedPath), "closing a shelf deletes its own copies")
        check(FileManager.default.fileExists(atPath: original.path), "but never your original files")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-names-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Report.pdf").path, contents: Data())
        checkEqual(ShelfStore.unusedURL(for: "Report.pdf", in: folder).lastPathComponent, "Report 2.pdf", "copies with the same name don't overwrite each other")

        let module = ShelfModule(shortcuts: ShortcutCenter())
        module.store.update(second.id) { $0.name = "Holiday photos" }
        let provider = ShelfLauncherProvider(module: module)
        checkEqual(provider.results(for: "holiday").first?.title, "Holiday photos", "the launcher finds shelves")
        check(provider.results(for: "new shelf").contains { $0.title == "New Shelf" }, "and can open a new one")
        module.store.remove(second.id)
    }
}

// MARK: - Downloads

@MainActor
enum DownloadPlanTests {
    static func run() {
        let mb: Int64 = 1024 * 1024
        let plan = SegmentPlanner.plan(total: 10 * mb, connections: 8)
        checkEqual(plan.count, 8, "a 10 MB file is split into 8 parts")
        checkEqual(plan.first?.start, 0, "starting at the first byte")
        checkEqual(plan.last?.end, 10 * mb - 1, "ending at the last byte")
        check(zip(plan, plan.dropFirst()).allSatisfy { $0.end + 1 == $1.start }, "with no gaps or overlaps")
        checkEqual(SegmentPlanner.plan(total: 100 * 1024, connections: 8).count, 1, "small files use one connection")
        checkEqual(SegmentPlanner.plan(total: 0, connections: 8).first?.end, -1, "unknown sizes use one open-ended part")

        var segments = [Segment(start: 0, end: 10 * mb - 1, received: 2 * mb), Segment(start: 10 * mb, end: 11 * mb - 1, received: mb)]
        let split = SegmentPlanner.split(segments, busy: [0, 1])
        checkEqual(split?.shortened, 0, "a free connection helps with the biggest part left")
        checkEqual(split?.new.start, 2 * mb + 4 * mb, "taking the second half of what's left")
        segments[0].received = 10 * mb - 100
        checkEqual(SegmentPlanner.split(segments, busy: [0]) == nil, true, "nearly finished parts aren't split")

        checkEqual(DownloadCategory.of("Holiday.MP4"), .video, "videos go to Video")
        checkEqual(DownloadCategory.of("song.flac"), .music, "music goes to Music")
        checkEqual(DownloadCategory.of("Invoice.pdf"), .documents, "PDFs go to Documents")
        checkEqual(DownloadCategory.of("Installer.dmg"), .programs, "disk images go to Programs")
        checkEqual(DownloadCategory.of("photos.zip"), .archives, "zips go to Archives")
        checkEqual(DownloadCategory.of("data.bin"), .other, "anything else goes to Other")

        checkEqual(ByteFormat.timeLeft(42), "42 s left", "time left in seconds")
        checkEqual(ByteFormat.timeLeft(150), "3 min left", "in minutes")
        checkEqual(ByteFormat.timeLeft(3 * 3600 + 600), "3 h 10 min left", "in hours")

        check(DownloadManager.downloadableURL(from: "https://example.com/file.zip") != nil, "https links can be downloaded")
        check(DownloadManager.downloadableURL(from: "ftp://ftp.example.com/pub/file.iso") != nil, "so can FTP links")
        check(DownloadManager.downloadableURL(from: "not a link") == nil, "plain text can't")
        check(DownloadManager.downloadableURL(from: "file:///etc/hosts") == nil, "nor files on this Mac")
        let ftp = FTPDownloadJob.arguments(url: URL(string: "ftp://h/f.iso")!, output: URL(fileURLWithPath: "/tmp/f.part"), retries: 5)
        check(ftp.contains("--continue-at") && ftp.contains("--retry"), "FTP downloads resume and retry")
    }
}

/// A tiny web server for the download tests. Serves the same made-up file at every address;
/// the address chooses how it behaves (no parts, dropped connections, slow, a file name…).
final class TestServer: @unchecked Sendable {
    let body: Data
    private let listener: NWListener
    private let lock = NSLock()
    private var _partRequests = 0
    private var _resumedFrom: Int = 0
    private var flakyCount = 0
    private var _lastCookie: String?

    var partRequests: Int { lock.lock(); defer { lock.unlock() }; return _partRequests }
    /// The Cookie header of the latest request.
    var lastCookie: String? { lock.lock(); defer { lock.unlock() }; return _lastCookie }
    /// The largest starting point asked for, to tell resuming from restarting.
    var resumedFrom: Int { lock.lock(); defer { lock.unlock() }; return _resumedFrom }

    init(size: Int) throws {
        body = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 997) })
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global())
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    func resetCounts() {
        lock.lock(); _partRequests = 0; _resumedFrom = 0; flakyCount = 0; lock.unlock()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let lines = request.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var start = 0, end = body.count - 1, isRange = false
            for line in lines where line.lowercased().hasPrefix("range: bytes=") {
                let spec = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                if let s = Int(spec[0]) { start = s; isRange = true }
                if spec.count > 1, let e = Int(spec[1]) { end = min(e, body.count - 1) }
            }
            let ranges = isRange && !path.hasPrefix("/noranges")
            if !ranges { start = 0; end = body.count - 1 }
            let cookie = lines.first { $0.lowercased().hasPrefix("cookie: ") }.map { String($0.dropFirst("cookie: ".count)) }
            lock.lock()
            if let cookie { _lastCookie = cookie }
            if ranges { _partRequests += 1; _resumedFrom = max(_resumedFrom, start) }
            var dropHalfway = false
            if path.hasPrefix("/flaky") {
                flakyCount += 1
                dropHalfway = flakyCount <= 3
            }
            lock.unlock()

            var header = ranges ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            header += "Content-Length: \(end - start + 1)\r\n"
            if ranges { header += "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n" }
            if !path.hasPrefix("/noranges") { header += "Accept-Ranges: bytes\r\n" }
            if path.hasPrefix("/named") { header += "Content-Disposition: attachment; filename=\"report.pdf\"\r\n" }
            header += "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
            var slice = body[start...end]
            if dropHalfway { slice = slice.prefix(slice.count / 2) }

            if path.hasPrefix("/slow") {
                // About half a megabyte a second per connection, in small pieces.
                DispatchQueue.global().async {
                    connection.send(content: Data(header.utf8), completion: .idempotent)
                    var offset = slice.startIndex
                    while offset < slice.endIndex {
                        let next = min(offset + 16_384, slice.endIndex)
                        let done = DispatchSemaphore(value: 0)
                        connection.send(content: Data(slice[offset..<next]), completion: .contentProcessed { _ in done.signal() })
                        if done.wait(timeout: .now() + 5) == .timedOut { break }
                        offset = next
                        Thread.sleep(forTimeInterval: 0.03)
                        if connection.state != .ready { break }
                    }
                    connection.cancel()
                }
            } else {
                connection.send(content: Data(header.utf8) + Data(slice), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

@MainActor
enum DownloadTests {
    static func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            spin(0.1)
        }
        return condition()
    }

    static func run() {
        guard let server = try? TestServer(size: 6 * 1024 * 1024) else {
            check(false, "the test web server starts")
            return
        }
        _ = waitFor(5) { server.port != 0 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-downloads-\(UUID().uuidString)")
        Prefs.downloadFolder = folder
        Prefs.downloadSortByType = true
        Prefs.downloadConnections = 8
        Prefs.downloadRetries = 5
        let manager = DownloadManager()

        func download(_ path: String, _ name: String, timeout: TimeInterval = 30) -> DownloadItem? {
            guard let item = manager.add(server.url(path)) else { return nil }
            _ = waitFor(timeout) { manager.item(item.id)?.state != .downloading }
            return manager.item(item.id)
        }
        func contentMatches(_ item: DownloadItem?) -> Bool {
            guard let path = item?.finalPath, let data = FileManager.default.contents(atPath: path) else { return false }
            return data == server.body
        }

        // 1. Several parts at once
        server.resetCounts()
        let fast = download("/files/data.bin", "data.bin")
        checkEqual(fast?.state, .completed, "a 6 MB download finishes")
        check(contentMatches(fast), "and the file is exactly right, byte for byte")
        check(server.partRequests >= 4, "it was downloaded in several parts at once", "\(server.partRequests) part requests")
        checkEqual(fast?.finalPath, folder.appendingPathComponent("Other/data.bin").path, "and sorted into a folder by type")

        // 2. A server that can't send parts
        let whole = download("/noranges/whole.bin", "whole.bin")
        checkEqual(whole?.state, .completed, "servers that can't split files still work")
        check(contentMatches(whole), "with the right content")

        // 3. Dropped connections
        let flaky = download("/flaky/flaky.bin", "flaky.bin", timeout: 60)
        checkEqual(flaky?.state, .completed, "dropped connections are retried automatically")
        check(contentMatches(flaky), "and the file still comes out right")

        // 4. The server's own file name
        let named = download("/named/download", "report.pdf")
        checkEqual(named.flatMap { $0.finalPath.map { URL(fileURLWithPath: $0).lastPathComponent } }, "report.pdf", "the file name the server gives is used")
        check(named?.finalPath?.contains("/Documents/") == true, "and a PDF goes into Documents")

        // 5. Pause and resume
        server.resetCounts()
        guard let slow = manager.add(server.url("/slow/pause.bin")) else { check(false, "slow download starts"); return }
        _ = waitFor(10) { (manager.item(slow.id)?.received ?? 0) > 500_000 }
        manager.pause(slow.id)
        let paused = manager.item(slow.id)
        checkEqual(paused?.state, .paused, "a download can be paused")
        check((paused?.received ?? 0) > 0 && (paused?.received ?? 0) < Int64(server.body.count), "part-way through", "\(paused?.received ?? 0) bytes")
        spin(1)
        checkEqual(manager.item(slow.id)?.received, paused?.received, "and stays paused")
        manager.resume(slow.id)
        _ = waitFor(40) { manager.item(slow.id)?.state != .downloading }
        checkEqual(manager.item(slow.id)?.state, .completed, "then resumed to the end")
        check(contentMatches(manager.item(slow.id)), "with the right content")

        // 6. Quitting part-way (or a power cut) and starting again
        server.resetCounts()
        guard let interrupted = manager.add(server.url("/slow/restart.bin")) else { check(false, "download starts"); return }
        _ = waitFor(10) { (manager.item(interrupted.id)?.received ?? 0) > 1_000_000 }
        manager.stopAll() // like quitting Toolbelt
        let reopened = DownloadManager() // like opening it again
        checkEqual(reopened.item(interrupted.id)?.state, .downloading, "an interrupted download is remembered")
        reopened.resumeInterrupted()
        _ = waitFor(40) { reopened.item(interrupted.id)?.state != .downloading }
        checkEqual(reopened.item(interrupted.id)?.state, .completed, "and finishes after a restart")
        check(contentMatches(reopened.item(interrupted.id)), "with the right content")
        check(server.resumedFrom > 0, "carrying on from where it stopped, not from the start")
        reopened.stopAll()

        let module = DownloadsModule()
        let provider = DownloadsLauncherProvider(module: module)
        checkEqual(provider.results(for: "https://example.com/big.iso").first?.title, "Download big.iso", "pasting a link in the launcher offers to download it")
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A clock the throttle tests can move by hand.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
enum DownloadsNextTests {
    static func run() {
        throttle()
        schedule()
        listDetails()
        withServer()
    }

    static func throttle() {
        let hour = Date(timeIntervalSince1970: 3600 * 480_000)
        let clock = TestClock(hour.addingTimeInterval(60))
        let speed = DownloadThrottle(now: { clock.now })
        speed.configure(bytesPerSecond: 1_000_000, hourlyCap: 0)
        checkEqual(speed.take(400_000), 0, "a little data under the speed limit needn't wait")
        let wait = speed.take(1_100_000)
        check(abs(wait - 1) < 0.01, "going over the speed limit waits just long enough", "\(wait) s")
        let none = DownloadThrottle(now: { clock.now })
        checkEqual(none.take(500_000_000), 0, "with no limit nothing waits")

        let cap = DownloadThrottle(now: { clock.now })
        cap.configure(bytesPerSecond: 0, hourlyCap: 10_000_000)
        checkEqual(cap.take(5_000_000), 0, "under the hourly cap nothing waits")
        check(cap.capWait == nil, "and the cap isn't reached")
        checkEqual(cap.take(5_000_000), 3540, "using up the hourly cap waits until the next hour")
        checkEqual(cap.capWait, 3540, "which is when downloads carry on")
        clock.now = hour.addingTimeInterval(3601)
        check(cap.capWait == nil, "a new hour starts afresh")
        checkEqual(cap.take(1_000), 0, "and downloads carry on")
    }

    static func schedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        var night = DownloadQueue(name: "Night")
        night.startAt = 60
        night.stopAt = 7 * 60
        let next = DownloadSchedule.next(after: at(30, 23), queues: [night], calendar: calendar)
        checkEqual(next?.date, at(31, 1), "a queue set for 01:00–07:00 next starts at 01:00 tomorrow")
        checkEqual(next?.start, true, "as a start")
        checkEqual(DownloadSchedule.next(after: at(31, 3), queues: [night], calendar: calendar)?.date, at(31, 7), "and then stops at 07:00")
        checkEqual(DownloadSchedule.shouldRun(night, at: at(31, 3), calendar: calendar), true, "opening Toolbelt at 03:00 finds it running")
        checkEqual(DownloadSchedule.shouldRun(night, at: at(31, 8), calendar: calendar), false, "and at 08:00 stopped")
        checkEqual(DownloadSchedule.shouldRun(night, at: at(31, 0, 30), calendar: calendar), false, "and at 00:30 still stopped")
        check(DownloadSchedule.shouldRun(.main(), at: at(31, 3), calendar: calendar) == nil, "queues without set times aren't changed")
        checkEqual(night.scheduleText, "Runs 01:00–07:00", "the times are shown in the list")
    }

    static func listDetails() {
        var item = DownloadItem(url: URL(string: "https://example.com/a.zip")!, name: "a.zip")
        item.received = 1_000_000
        item.total = 4_000_000
        item.speed = 500_000
        item.connections = 4
        let all = DownloadRow.details(for: item, columns: DownloadColumn.allCases, queue: "Night")
        check(all.contains("/s") && all.contains("4 connections") && all.contains("left") && all.contains("Night"),
              "the list can show size, speed, time left, connections and queue", all)
        let sizeOnly = DownloadRow.details(for: item, columns: [.size], queue: "Night")
        check(sizeOnly.contains("of") && !sizeOnly.contains("/s") && !sizeOnly.contains("Night"), "or only the columns you choose", sizeOnly)
        Prefs.downloadColumns = [.speed, .queue]
        checkEqual(Prefs.downloadColumns, [.speed, .queue], "the chosen columns are saved")
        Prefs.downloadButtons = [.open]
        checkEqual(Prefs.downloadButtons, [.open], "and so are the chosen buttons")
        SettingsStore.shared.set(nil, for: "downloads.columns")
        SettingsStore.shared.set(nil, for: "downloads.buttons")
        checkEqual(DownloadManager.safeFileName("Clip: part 1/2"), "Clip- part 1-2", "names from the browser are made safe for files")
    }

    static func withServer() {
        guard let server = try? TestServer(size: 6 * 1024 * 1024) else {
            check(false, "the test web server starts")
            return
        }
        _ = DownloadTests.waitFor(5) { server.port != 0 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-dlnext-\(UUID().uuidString)")
        Prefs.downloadFolder = folder
        Prefs.downloadSortByType = false
        Prefs.downloadSpeedLimitKB = 0
        Prefs.downloadHourlyCapMB = 0
        let manager = DownloadManager()
        manager.resumeInterrupted()
        func matches(_ id: UUID) -> Bool {
            guard let path = manager.item(id)?.finalPath, let data = FileManager.default.contents(atPath: path) else { return false }
            return data == server.body
        }
        func done(_ ids: [UUID]) -> Bool { ids.allSatisfy { manager.item($0)?.state == .completed } }

        // Queues: one at a time
        manager.queues[0].maxAtOnce = 1
        let ids = (1...3).compactMap { manager.add(server.url("/slow/queue\($0).bin"))?.id }
        checkEqual(ids.count, 3, "three downloads are added")
        checkEqual(ids.map { manager.item($0)?.state }, [.downloading, .queued, .queued], "a queue of one downloads one at a time; the rest wait")
        check(DownloadTests.waitFor(90) { done(ids) }, "each starts when the one before finishes")
        let finishes = ids.compactMap { manager.item($0)?.finished }
        checkEqual(finishes, finishes.sorted(), "in the order they were added")
        check(ids.allSatisfy(matches), "and every file is right")
        manager.queues[0].maxAtOnce = 3

        // Stopping and starting a queue
        guard let paused = manager.add(server.url("/slow/stopped.bin")) else { check(false, "download starts"); return }
        _ = DownloadTests.waitFor(10) { (manager.item(paused.id)?.received ?? 0) > 300_000 }
        manager.stopQueue(manager.queues[0].id)
        checkEqual(manager.item(paused.id)?.state, .queued, "stopping a queue sends its downloads back to waiting")
        let kept = manager.item(paused.id)?.received ?? 0
        spin(1)
        checkEqual(manager.item(paused.id)?.received, kept, "and nothing more downloads")
        manager.startQueue(manager.queues[0].id)
        check(DownloadTests.waitFor(40) { done([paused.id]) }, "starting it again finishes the download")
        check(matches(paused.id), "with the right content")

        // A second queue that starts stopped
        var night = manager.addQueue(named: "Night")
        if let index = manager.queues.firstIndex(where: { $0.id == night.id }) {
            manager.queues[index].isRunning = false
            night = manager.queues[index]
        }
        guard let later = manager.add(server.url("/files/later.bin"), queue: night.id) else { check(false, "download added"); return }
        spin(1)
        checkEqual(manager.item(later.id)?.state, .queued, "downloads in a stopped queue wait")
        checkEqual(manager.hasWork, false, "and don't count as unfinished work")
        manager.startQueue(night.id)
        check(DownloadTests.waitFor(30) { done([later.id]) }, "until the queue starts")
        manager.removeQueue(night.id)
        checkEqual(manager.queues.count, 1, "queues can be deleted")
        checkEqual(manager.queue(of: manager.item(later.id)!).id, manager.queues[0].id, "and their downloads move to the first queue")
        let saved = DownloadManager()
        checkEqual(saved.queues.map(\.name), ["Main"], "queues are saved")

        // Speed limit
        Prefs.downloadSpeedLimitKB = 1024
        let began = Date()
        guard let limited = manager.add(server.url("/files/limited.bin")) else { check(false, "download added"); return }
        check(DownloadTests.waitFor(40) { done([limited.id]) }, "a speed-limited download finishes")
        let seconds = Date().timeIntervalSince(began)
        check(seconds > 4, "and takes as long as the limit says (6 MB at 1 MB/s)", "\(Int(seconds)) s")
        check(matches(limited.id), "with the right content")
        Prefs.downloadSpeedLimitKB = 0
        manager.applyLimits()

        // Hourly cap, with a clock 10 seconds before the hour
        let hour = Date(timeIntervalSince1970: 3600 * 480_000)
        let clock = TestClock(hour.addingTimeInterval(3590))
        let capped = DownloadManager(throttle: DownloadThrottle(now: { clock.now }))
        capped.resumeInterrupted()
        Prefs.downloadHourlyCapMB = 4
        guard let big = capped.add(server.url("/slow/capped.bin")) else { check(false, "download added"); return }
        check(DownloadTests.waitFor(20) { capped.cappedUntil != nil }, "downloads stop when the hourly cap is used up")
        checkEqual(capped.item(big.id)?.state, .queued, "and wait")
        let part = capped.item(big.id)?.received ?? 0
        check(part >= 4 * 1024 * 1024 && part < Int64(server.body.count), "having downloaded about the cap", "\(part) bytes")
        clock.now = hour.addingTimeInterval(3601)
        check(DownloadTests.waitFor(40) { capped.item(big.id)?.state == .completed }, "and carry on in the next hour")
        check(capped.item(big.id)?.finalPath.flatMap { FileManager.default.contents(atPath: $0) } == server.body, "with the right content")
        Prefs.downloadHourlyCapMB = 0
        capped.stopAll()

        // Cookies and the page address from the browser, and a chosen name
        guard let fromBrowser = manager.add(server.url("/files/members.bin"), name: "Members video.mp4",
                                            headers: ["Cookie": "session=abc123", "Referer": "https://example.com/"]) else {
            check(false, "download added"); return
        }
        check(DownloadTests.waitFor(30) { done([fromBrowser.id]) }, "downloads from the browser finish")
        checkEqual(server.lastCookie, "session=abc123", "and send the browser's cookies, for sites you're signed in to")
        checkEqual(manager.item(fromBrowser.id)?.name, "Members video.mp4", "with the name the browser chose")

        // Notification hook and "when done"
        var finishedNames: [String] = []
        var doneAction: WhenDone?
        manager.onFinished = { finishedNames.append($0.name) }
        manager.onAllDone = { doneAction = $0 }
        manager.whenDone = .sleep
        guard let last = manager.add(server.url("/files/last.bin")) else { check(false, "download added"); return }
        check(DownloadTests.waitFor(30) { done([last.id]) }, "the last download finishes")
        spin(0.5)
        checkEqual(finishedNames, ["last.bin"], "a finished download is announced (the notification)")
        checkEqual(doneAction, .sleep, "when everything has finished, the chosen action (sleep) is offered")
        checkEqual(manager.whenDone, .nothing, "only once")
        manager.stopAll()
        try? FileManager.default.removeItem(at: folder)
        Prefs.downloadSortByType = true
    }
}

@MainActor
enum ChromeBridgeTests {
    static func run() {
        // The extension and Chrome's note about the bridge agree on the extension's ID.
        let manifestURL = URL(fileURLWithPath: "Chrome/manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(manifest != nil, "the Chrome extension's manifest is valid")
        let key = manifest?["key"] as? String ?? ""
        checkEqual(ChromeSetup.extensionID(fromKey: key), ChromeSetup.extensionID, "its key gives the ID Toolbelt allows")
        let permissions = manifest?["permissions"] as? [String] ?? []
        check(["downloads", "nativeMessaging", "contextMenus"].allSatisfy(permissions.contains), "it can take over downloads and add a right-click item")
        checkEqual(manifest?["manifest_version"] as? Int, 3, "and uses Chrome's current extension format")

        let hosts = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-chrome-\(UUID().uuidString)")
        let problem = ChromeSetup.install(extensionSource: URL(fileURLWithPath: "Chrome"), bridgePath: "/Applications/Toolbelt.app/Contents/MacOS/ToolbeltBridge", hostsFolder: hosts)
        check(problem == nil, "setting up Chrome works", problem ?? "")
        let host = (try? Data(contentsOf: ChromeSetup.hostManifestURL(in: hosts))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        checkEqual(host?["allowed_origins"] as? [String], ["chrome-extension://\(ChromeSetup.extensionID)/"], "Chrome lets only the Toolbelt extension use the bridge")
        checkEqual(host?["path"] as? String, "/Applications/Toolbelt.app/Contents/MacOS/ToolbeltBridge", "and knows where the bridge is")
        check(FileManager.default.fileExists(atPath: ChromeSetup.extensionFolder.appendingPathComponent("background.js").path), "the extension is copied to a folder for Load unpacked")
        try? FileManager.default.removeItem(at: hosts)

        let bridge = "build/Toolbelt.app/Contents/MacOS/ToolbeltBridge"
        guard FileManager.default.fileExists(atPath: bridge) else {
            print("  – skipped the bridge: build the app first (bash build.sh)")
            return
        }
        check(FileManager.default.fileExists(atPath: "build/Toolbelt.app/Contents/Resources/ChromeExtension/manifest.json"), "the app carries the extension")

        // Talk to the bridge the way Chrome does, and check the links reach the download list.
        let module = DownloadsModule()
        var received: [DownloadRequest] = []
        let inbox = BrowserInbox { received.append($0) }
        try? FileManager.default.createDirectory(at: BrowserInbox.folder, withIntermediateDirectories: true)
        try? #"{"url":"https://example.com/waiting.zip"}"#.write(to: BrowserInbox.folder.appendingPathComponent("early.json"), atomically: true, encoding: .utf8)
        inbox.start()
        checkEqual(received.map(\.url), ["https://example.com/waiting.zip"], "links that arrived while Toolbelt was closed are picked up")

        let replies = talk(to: bridge, messages: [
            ["type": "ping"],
            ["type": "download", "url": "https://example.com/files/film.mp4", "cookies": "sid=42", "referrer": "https://example.com/watch", "name": "Film.mp4"],
            ["type": "download", "url": "javascript:alert(1)"],
        ])
        checkEqual(replies.count, 3, "the bridge answers every message")
        checkEqual(replies.first?["ok"] as? Bool, true, "it answers Chrome's “are you there?”")
        checkEqual(replies.dropFirst().first?["ok"] as? Bool, true, "it accepts a download link")
        checkEqual(replies.last?["ok"] as? Bool, false, "and refuses anything that isn't a web or FTP link")
        _ = DownloadTests.waitFor(5) { received.count >= 2 }
        let film = received.last
        checkEqual(film?.url, "https://example.com/files/film.mp4", "the link reaches Toolbelt")
        checkEqual(film?.headers["Cookie"], "sid=42", "with the browser's cookies")
        checkEqual(film?.headers["Referer"], "https://example.com/watch", "and the page it came from")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: BrowserInbox.folder.path)) ?? []
        checkEqual(leftovers, [], "and the handed-over files are tidied away")
        inbox.stop()

        if let film {
            module.manager.resumeInterrupted()
            module.received(film)
            let item = module.manager.items.first
            checkEqual(item?.name, "Film.mp4", "a link from Chrome joins the download list")
            checkEqual(item?.headers?["Cookie"], "sid=42", "keeping its cookies for every part")
            if let item { module.manager.remove(item.id) }
            module.stop()
        }
    }

    /// Sends messages with Chrome's framing (4-byte length, then JSON) and reads the replies.
    static func talk(to bridge: String, messages: [[String: Any]]) -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bridge)
        process.arguments = ["chrome-extension://\(ChromeSetup.extensionID)/"]
        var environment = ProcessInfo.processInfo.environment
        environment["TOOLBELT_DATA_DIR"] = SettingsStore.folder.path
        environment["TOOLBELT_BRIDGE_NO_LAUNCH"] = "1"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        for message in messages {
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { continue }
            var length = UInt32(body.count).littleEndian
            input.fileHandleForWriting.write(Data(bytes: &length, count: 4) + body)
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        var data = output.fileHandleForReading.readDataToEndOfFile()
        var replies: [[String: Any]] = []
        while data.count >= 4 {
            let length = data.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard data.count >= 4 + length else { break }
            if let reply = try? JSONSerialization.jsonObject(with: data.subdata(in: 4..<(4 + length))) as? [String: Any] {
                replies.append(reply)
            }
            data = data.subdata(in: (4 + length)..<data.count)
        }
        return replies
    }
}

// MARK: - Screenshots

/// Lets a background task hand a result back to a test.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
enum ScreenshotTests {
    /// A plain picture: white on the left half, black on the right.
    static func testImage(width: Int = 400, height: Int = 300) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    /// The colour of one pixel (x, y from the top left), as 0–255 red, green, blue.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    static func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 245 && p.g > 245 && p.b > 245 }

    static func run() {
        let base = testImage()
        checkEqual(isWhite(pixel(base, 100, 150)), true, "the test picture is white on the left")

        // Boxes
        let box = ScreenshotRenderer.render(base, annotations: [Annotation(tool: .box, start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 120), color: .red)])!
        let edge = pixel(box, 51, 85)
        check(edge.r > 200 && edge.g < 90 && edge.b < 90, "a box draws a red outline", "\(edge)")
        check(isWhite(pixel(box, 100, 85)), "and leaves the inside alone")

        // Arrows
        let arrow = ScreenshotRenderer.render(base, annotations: [Annotation(tool: .arrow, start: CGPoint(x: 20, y: 150), end: CGPoint(x: 180, y: 150), color: .blue)])!
        let shaft = pixel(arrow, 100, 150)
        check(shaft.b > 200 && shaft.r < 90, "an arrow draws a line", "\(shaft)")
        let tip = pixel(arrow, 172, 150)
        check(tip.b > 200 && tip.r < 90, "with a head at the end", "\(tip)")
        check(isWhite(pixel(arrow, 100, 120)), "and nothing else")

        // Highlight
        let highlighted = ScreenshotRenderer.render(base, annotations: [Annotation(tool: .highlight, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 120, y: 60), color: .yellow)])!
        let marker = pixel(highlighted, 60, 40)
        check(marker.r > 220 && marker.g > 180 && marker.b < 200, "highlighting tints white yellow, like a highlighter", "\(marker)")
        let dark = pixel(ScreenshotRenderer.render(base, annotations: [Annotation(tool: .highlight, start: CGPoint(x: 220, y: 20), end: CGPoint(x: 300, y: 60), color: .yellow)])!, 260, 40)
        check(dark.r < 30 && dark.g < 30, "and leaves black text black, so it stays readable", "\(dark)")

        // Blur (pixelate) across the black/white edge
        let blurred = ScreenshotRenderer.render(base, annotations: [Annotation(tool: .blur, start: CGPoint(x: 140, y: 100), end: CGPoint(x: 250, y: 200))])!
        let middle = pixel(blurred, 200, 150)
        check(middle.r > 30 && middle.r < 225, "blur turns the area into blocks, so the edge goes grey", "\(middle)")
        checkEqual(pixel(blurred, 141, 101).r, pixel(blurred, 147, 107).r, "pixels in a block are all the same")
        check(isWhite(pixel(blurred, 100, 150)), "outside the blurred area nothing changes")

        // Text
        let texted = ScreenshotRenderer.render(base, annotations: [Annotation(tool: .text, start: CGPoint(x: 10, y: 10), end: .zero, color: .red, text: "Hello")])!
        var redPixels = 0
        for x in stride(from: 10, to: 120, by: 2) {
            for y in stride(from: 10, to: 40, by: 2) {
                let p = pixel(texted, x, y)
                if p.r > 180 && p.g < 100 { redPixels += 1 }
            }
        }
        check(redPixels > 10, "text is written onto the picture", "\(redPixels) red points")

        // Crop
        let cropped = ScreenshotRenderer.render(base, annotations: [], crop: CGRect(x: 150, y: 50, width: 100, height: 80))!
        checkEqual([cropped.width, cropped.height], [100, 80], "cropping keeps just the chosen part")
        check(isWhite(pixel(cropped, 10, 40)) && pixel(cropped, 90, 40).r < 20, "the right part", "\(pixel(cropped, 10, 40)) \(pixel(cropped, 90, 40))")

        // The editor: drawing with the mouse, undo and redo
        let model = ScreenshotEditorModel(image: base)
        model.tool = .box
        model.dragChanged(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        check(model.draft != nil && model.annotations.isEmpty, "dragging shows the box before it's added")
        model.dragEnded(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        checkEqual(model.annotations.count, 1, "letting go adds it")
        model.dragEnded(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11))
        checkEqual(model.annotations.count, 1, "a click without dragging adds nothing")
        model.tool = .text
        model.text = "Here"
        model.dragEnded(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 80, y: 80))
        checkEqual(model.annotations.last?.text, "Here", "the text tool places text with a click")
        model.undo()
        checkEqual(model.annotations.count, 1, "⌘Z undoes")
        model.redo()
        checkEqual(model.annotations.count, 2, "⇧⌘Z redoes")
        model.tool = .crop
        model.dragEnded(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100))
        checkEqual([model.finalImage().width, model.finalImage().height], [200, 100], "the crop tool crops the final picture")
        check(model.preview.width == 400, "while the editor still shows the whole picture")

        model.copyImage()
        let copied = NSImage(pasteboard: NSPasteboard.general)
        checkEqual(copied.map { Int($0.representations.first?.pixelsWide ?? 0) }, 200, "Copy puts the finished picture on the clipboard")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-shots-\(UUID().uuidString)")
        let saved = model.save(to: folder)
        check(saved.map { FileManager.default.fileExists(atPath: $0.path) } == true, "Save writes a PNG to the screenshots folder")
        check(saved?.lastPathComponent.hasPrefix("Screenshot ") == true, "named like macOS's own screenshots", saved?.lastPathComponent ?? "")
        check(model.save(to: folder) != saved, "saving twice never overwrites")
        try? FileManager.default.removeItem(at: folder)

        // Reading text
        let words = ScreenshotEditorModel(image: testImage(width: 1200, height: 600))
        words.add(Annotation(tool: .text, start: CGPoint(x: 30, y: 200), end: .zero, color: .black, text: "Invoice 42"))
        words.crop = CGRect(x: 0, y: 150, width: 560, height: 160)
        let finished = Box(false)
        Task { @MainActor in await words.copyText(); finished.value = true }
        _ = DownloadTests.waitFor(20) { finished.value }
        let read = NSPasteboard.general.string(forType: .string) ?? ""
        check(read.contains("Invoice"), "Copy Text reads the words in the screenshot", read)

        // Capturing the screen for real (macOS's screencapture tool)
        check(CaptureMode.area.arguments(output: URL(fileURLWithPath: "/tmp/a.png")).contains("-s"), "area capture lets you drag out an area")
        check(CaptureMode.window.arguments(output: URL(fileURLWithPath: "/tmp/a.png")).contains("-w"), "window capture lets you click a window")
        let shot = Box<URL?>(nil), shotDone = Box(false)
        Task { @MainActor in shot.value = await ScreenshotCapture.capture(.screen); shotDone.value = true }
        _ = DownloadTests.waitFor(20) { shotDone.value }
        let screen = shot.value.flatMap { NSImage(contentsOf: $0) }
        check((screen?.representations.first?.pixelsWide ?? 0) >= 800, "a whole-screen screenshot is taken", "\(screen?.size ?? .zero)")
        let area = Box<URL?>(nil), areaDone = Box(false)
        Task { @MainActor in area.value = await ScreenshotCapture.capture(rect: CGRect(x: 0, y: 0, width: 300, height: 200)); areaDone.value = true }
        _ = DownloadTests.waitFor(20) { areaDone.value }
        let part = area.value.flatMap { NSImage(contentsOf: $0) }
        checkEqual(part.map { Int($0.size.width) }, 300, "and of just an area")
        for file in [shot.value, area.value].compactMap({ $0 }) { try? FileManager.default.removeItem(at: file) }

        // The module: shortcuts, editor window and launcher
        let module = ScreenshotsModule(shortcuts: ShortcutCenter())
        checkEqual(ShortcutAction.captureArea.defaultShortcut?.display, "⌥⇧⌘4", "⌥⇧⌘4 takes a screenshot of an area")
        let editor = module.edit(base)
        check(editor.window.isVisible, "the editor opens in a window")
        editor.window.close()
        let provider = ScreenshotsLauncherProvider(module: module)
        check(provider.results(for: "screenshot").contains { $0.title == "Screenshot of Window" }, "the launcher can take screenshots")
        check(provider.results(for: "ocr").contains { $0.title == "Copy Text from Screen" }, "and copy text from the screen")
        Prefs.screenshotAfterCapture = .save
        checkEqual(Prefs.screenshotAfterCapture, .save, "what happens after a screenshot is saved in Settings")
        SettingsStore.shared.set(nil, for: "screenshots.after")
    }
}

// MARK: - Gestures

@MainActor
enum GestureTests {
    static func fingers(_ points: [(Double, Double)]) -> [TouchPoint] {
        points.enumerated().map { TouchPoint(id: $0.offset, x: $0.element.0, y: $0.element.1) }
    }

    /// Raw touch records laid out the way macOS hands them over (96 bytes each).
    static func records(_ touches: [(id: Int32, state: Int32, x: Float, y: Float)]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: max(1, touches.count) * 96)
        bytes.withUnsafeMutableBytes { raw in
            for (index, touch) in touches.enumerated() {
                raw.storeBytes(of: touch.id, toByteOffset: index * 96 + 16, as: Int32.self)
                raw.storeBytes(of: touch.state, toByteOffset: index * 96 + 20, as: Int32.self)
                raw.storeBytes(of: touch.x, toByteOffset: index * 96 + 32, as: Float.self)
                raw.storeBytes(of: touch.y, toByteOffset: index * 96 + 36, as: Float.self)
            }
        }
        return bytes
    }

    static func read(_ touches: [(id: Int32, state: Int32, x: Float, y: Float)], count: Int? = nil) -> [TouchPoint]? {
        let bytes = records(touches)
        return bytes.withUnsafeBytes { MultitouchReader.readTouches($0.baseAddress!, count: count ?? touches.count) }
    }

    static func run() {
        // Reading raw touch data: good frames give fingers, nonsense is refused
        checkEqual(read([(1, 4, 0.25, 0.5), (2, 4, 0.75, 0.5)]), [TouchPoint(id: 1, x: 0.25, y: 0.5), TouchPoint(id: 2, x: 0.75, y: 0.5)],
                   "two fingers on the trackpad are read")
        checkEqual(read([(1, 4, 0.5, 0.5), (2, 1, 0.9, 0.9), (3, 6, 0.1, 0.1)])?.map(\.id), [1],
                   "hovering and lifting fingers are left out")
        check(read([(1, 4, 5, 0.5)]) == nil, "a position far outside the trackpad is refused")
        check(read([(1, 4, .nan, 0.5)]) == nil, "a position that isn't a number is refused")
        check(read([(1, 42, 0.5, 0.5)]) == nil, "an unknown touch state is refused")
        check(read([(-7, 4, 0.5, 0.5)]) == nil, "a nonsense touch id is refused")
        check(read([(1, 4, 0.5, 0.5)], count: 5000) == nil, "a nonsense finger count is refused")
        check(MultitouchReader.Status.unreadable.isProblem && !MultitouchReader.Status.working(devices: 1).isProblem,
              "bad touch data is shown as a problem in Settings")
        check(MultitouchReader.Status.working(devices: 2).text.contains("working (2 devices)"), "the reader's status reads well")

        // Trackpad: taps, swipes and pinches from made-up touches
        var pad = TouchRecognizer(source: .trackpad)
        let three = [(0.4, 0.5), (0.5, 0.52), (0.6, 0.5)]
        _ = pad.feed(fingers([three[0]]), at: 0)
        _ = pad.feed(fingers(three), at: 0.03)
        _ = pad.feed(fingers(three), at: 0.12)
        checkEqual(pad.feed([], at: 0.18), .touch(.trackpad, .tap, fingers: 3), "a quick three-finger tap is recognised")

        _ = pad.feed(fingers(three), at: 1)
        check(pad.feed(fingers(three), at: 1.6) == nil && pad.feed([], at: 1.7) == nil, "holding fingers still isn't a tap")

        var fired: [Gesture] = []
        for step in 0...10 {
            let dx = -0.025 * Double(step)
            if let g = pad.feed(fingers(three.map { ($0.0 + dx, $0.1) }), at: 2 + Double(step) * 0.02) { fired.append(g) }
        }
        _ = pad.feed([], at: 2.3)
        checkEqual(fired, [.touch(.trackpad, .swipeLeft, fingers: 3)], "a three-finger swipe left fires once")

        fired = []
        let four = [(0.3, 0.3), (0.7, 0.3), (0.3, 0.7), (0.7, 0.7)]
        for step in 0...10 {
            let f = 1 - 0.07 * Double(step)
            if let g = pad.feed(fingers(four.map { (0.5 + ($0.0 - 0.5) * f, 0.5 + ($0.1 - 0.5) * f) }), at: 3 + Double(step) * 0.02) { fired.append(g) }
        }
        _ = pad.feed([], at: 3.4)
        checkEqual(fired, [.touch(.trackpad, .pinchIn, fingers: 4)], "four fingers pinching in")

        fired = []
        for step in 0...10 {
            if let g = pad.feed(fingers([(0.45, 0.4 + 0.03 * Double(step)), (0.55, 0.4 + 0.03 * Double(step))]), at: 4 + Double(step) * 0.02) { fired.append(g) }
        }
        _ = pad.feed([], at: 4.4)
        checkEqual(fired, [.touch(.trackpad, .swipeUp, fingers: 2)], "two fingers moving up (a scroll) is a two-finger swipe, so only rules for it react")

        _ = pad.feed(fingers(three), at: 5)
        checkEqual(pad.click(), .touch(.trackpad, .click, fingers: 3), "clicking with three fingers down")
        _ = pad.feed([], at: 5.5)
        _ = pad.feed(fingers([(0.92, 0.08)]), at: 6)
        checkEqual(pad.click(), .touch(.trackpad, .cornerBottomRight, fingers: 1), "clicking in the bottom-right corner")
        _ = pad.feed(fingers([(0.5, 0.5)]), at: 6.5)
        check(pad.click() == nil, "an ordinary click is left alone")
        _ = pad.feed([], at: 7)

        var mouse = TouchRecognizer(source: .magicMouse)
        var mouseFired: Gesture?
        for step in 0...8 {
            if let g = mouse.feed(fingers([(0.4 + 0.03 * Double(step), 0.6), (0.5 + 0.03 * Double(step), 0.6)]), at: Double(step) * 0.02) { mouseFired = g }
        }
        checkEqual(mouseFired, .touch(.magicMouse, .swipeRight, fingers: 2), "Magic Mouse swipes are told apart from the trackpad's")

        // Mouse strokes
        checkEqual(StrokeRecognizer.path(of: (0...10).map { CGPoint(x: 500 - $0 * 15, y: 300) }), "L", "dragging left draws L")
        let downRight = (0...6).map { CGPoint(x: 300, y: 300 + $0 * 15) } + (1...6).map { CGPoint(x: 300 + $0 * 15, y: 390) }
        checkEqual(StrokeRecognizer.path(of: downRight), "DR", "down then right draws DR")
        checkEqual(StrokeRecognizer.path(of: [CGPoint(x: 10, y: 10), CGPoint(x: 14, y: 12)]), "", "a wobble isn't a stroke (it's a right-click)")

        // Tapping modifier keys
        var keys = ModifierTapDetector()
        check(keys.modifierChanged(.rightShift, flags: .maskShift, at: 0) == nil, "pressing a modifier does nothing yet")
        checkEqual(keys.modifierChanged(.rightShift, flags: [], at: 0.1), .modifierTap(.rightShift, taps: 1), "letting go quickly is a tap")
        _ = keys.modifierChanged(.rightShift, flags: .maskShift, at: 0.25)
        checkEqual(keys.modifierChanged(.rightShift, flags: [], at: 0.32), .modifierTap(.rightShift, taps: 2), "a second tap straight after is a double tap")
        _ = keys.modifierChanged(.leftCommand, flags: .maskCommand, at: 2)
        check(keys.modifierChanged(.leftCommand, flags: [], at: 2.9) == nil, "holding it for a while isn't a tap")
        _ = keys.modifierChanged(.leftShift, flags: [.maskShift, .maskCommand], at: 3)
        check(keys.modifierChanged(.leftShift, flags: .maskCommand, at: 3.1) == nil, "nor is pressing it with another modifier (⌘⇧)")
        _ = keys.modifierChanged(.leftOption, flags: .maskAlternate, at: 4)
        keys.interrupted() // ⌥ plus a letter
        check(keys.modifierChanged(.leftOption, flags: [], at: 4.1) == nil, "nor using it as part of a shortcut")

        // Which rule applies
        let either = GestureRule(gesture: .modifierTap(.shift, taps: 2), action: .toolbelt(.openLauncher))
        check(GestureRule.match(.modifierTap(.rightShift, taps: 2), app: nil, in: [either]) != nil, "“Shift (either)” matches the right Shift")
        check(GestureRule.match(.modifierTap(.rightShift, taps: 1), app: nil, in: [either]) == nil, "but a single tap doesn't match a double-tap rule")
        let safariOnly = GestureRule(gesture: .mouseButton(3), action: .system(.back), scope: .only, apps: ["com.apple.Safari"])
        let general = GestureRule(gesture: .mouseButton(3), action: .system(.missionControl))
        checkEqual(GestureRule.match(.mouseButton(3), app: "com.apple.Safari", in: [general, safariOnly])?.action, .system(.back), "an app's own rule wins in that app")
        checkEqual(GestureRule.match(.mouseButton(3), app: "com.apple.TextEdit", in: [general, safariOnly])?.action, .system(.missionControl), "and the general rule applies elsewhere")
        let notInTerminal = GestureRule(gesture: .keySequence(";;"), action: .toolbelt(.openLauncher), scope: .except, apps: ["com.apple.Terminal"])
        check(!notInTerminal.applies(in: "com.apple.Terminal") && notInTerminal.applies(in: "com.apple.Notes"), "“Everywhere except” leaves out the chosen apps")
        var off = general
        off.enabled = false
        check(GestureRule.match(.mouseButton(3), app: nil, in: [off]) == nil, "switched-off rules do nothing")
        check(GestureRule.match(.touch(.trackpad, .cornerTopLeft, fingers: 1), app: nil,
                                in: [GestureRule(gesture: .touch(.trackpad, .cornerTopLeft, fingers: 1), action: .toolbelt(.newNote))]) != nil, "corner clicks match")

        // Saving
        let rules = [safariOnly, either, GestureRule(gesture: .stroke(button: 1, path: "DR"), action: MacroAction(kind: .shell, value: "echo hi"))]
        let decoded = (try? JSONEncoder().encode(rules)).flatMap { try? JSONDecoder().decode([GestureRule].self, from: $0) }
        checkEqual(decoded, rules, "gesture rules are saved and read back exactly")

        // Actions
        let shortcuts = ShortcutCenter()
        let ran = Box(false)
        shortcuts.setHandler(for: .newNote) { ran.value = true }
        let runner = ActionRunner(shortcuts: shortcuts)
        runner.run(.toolbelt(.newNote))
        check(ran.value, "a gesture can run any Toolbelt command")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-action-\(UUID().uuidString)")
        runner.run(MacroAction(kind: .shell, value: "printf done > '\(marker.path)'"))
        _ = DownloadTests.waitFor(5) { FileManager.default.fileExists(atPath: marker.path) }
        checkEqual(try? String(contentsOf: marker, encoding: .utf8), "done", "or a shell script")
        let output = Box<String?>(nil)
        ActionRunner.runScript("/usr/bin/osascript", ["-e", "return 6 * 7"]) { output.value = $0 }
        _ = DownloadTests.waitFor(10) { output.value != nil }
        checkEqual(output.value, "42", "or an AppleScript")
        checkEqual(ActionRunner.url(from: "apple.com")?.absoluteString, "https://apple.com", "web addresses without https:// still open")
        checkEqual(ActionRunner.url(from: "~/Desktop")?.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path, "and so do file paths")
        checkEqual(MacroAction(kind: .pressKeys, keyCode: kVK_ANSI_T, modifiers: cmdKey).summary, "Press ⌘T", "actions are described in plain words")
        try? FileManager.default.removeItem(at: marker)

        // The trackpad reader
        check(MultitouchReader.shared.isAvailable, "macOS's touch framework loads")
        MultitouchReader.shared.start()
        check(MultitouchReader.shared.deviceCount >= 0, "and starts even without a trackpad (as on a Mac mini)")
        MultitouchReader.shared.stop()

        // The module only listens when a rule needs it
        let module = GesturesModule(shortcuts: shortcuts)
        module.store.rules = []
        module.start()
        check(!module.tap.isRunning, "with no gestures, nothing listens (no battery used)")
        module.store.rules = [GestureRule(gesture: .mouseButton(4), action: .toolbelt(.newNote))]
        check(module.tap.isRunning == AXIsProcessTrusted(), "a mouse-button gesture starts listening to the mouse")
        module.store.rules = []
        check(!module.tap.isRunning, "and stops again when it's removed")
        module.stop()
    }
}

// MARK: - Automation

/// The same file layout as MacroStore's macros.json, for writing test macros.
struct SavedMacros: Codable {
    var macros: [Macro]
    var groups: [MacroGroup]
}

@MainActor
enum AutomationTests {
    static func step(_ kind: MacroStep.Kind, name: String = "", text: String = "", text2: String = "", number: Double = 1,
                     filter: TextFilter = .uppercase, condition: MacroCondition = MacroCondition(),
                     steps: [MacroStep] = [], elseSteps: [MacroStep] = [], action: MacroAction = .toolbelt(.openLauncher)) -> MacroStep {
        MacroStep(kind: kind, action: action, name: name, text: text, text2: text2, number: number, filter: filter,
                  condition: condition, steps: steps, elseSteps: elseSteps)
    }

    static func runSteps(_ run: MacroRun, _ steps: [MacroStep], timeout: TimeInterval = 20) {
        let done = Box(false)
        Task { @MainActor in await run.run(steps); done.value = true }
        _ = DownloadTests.waitFor(timeout) { done.value }
    }

    static func run() {
        let shortcuts = ShortcutCenter()
        let runner = ActionRunner(shortcuts: shortcuts)

        // Variables
        let vars = MacroRun(runner: runner, trigger: "/tmp/new file.pdf")
        vars.set("Name", "Sam")
        checkEqual(vars.expand("Hi %Name%, 50% off %%"), "Hi Sam, 50% off %", "%Name% is filled in; other percent signs stay")
        checkEqual(vars.expand("%Trigger%"), "/tmp/new file.pdf", "%Trigger% is what started the macro")
        vars.set("Clipboard", "from a macro")
        checkEqual(NSPasteboard.general.string(forType: .string), "from a macro", "setting %Clipboard% sets the real clipboard")
        checkEqual(vars.expand("[%Clipboard%]"), "[from a macro]", "and reading it reads the clipboard")

        // Text filters
        checkEqual(TextFilter.findReplace.apply("a-b-c", find: "-", replace: "+"), "a+b+c", "find and replace")
        checkEqual(TextFilter.regexReplace.apply("Order 123 and 456", find: "[0-9]+", replace: "#"), "Order # and #", "find and replace with a pattern")
        checkEqual(TextFilter.extractMatch.apply("Invoice INV-2041 due", find: "INV-([0-9]+)"), "2041", "keep only the part that matches")
        checkEqual(TextFilter.countWords.apply("one two  three\nfour"), "4", "count words")
        checkEqual(TextFilter.countLines.apply("a\nb\nc"), "3", "count lines")
        checkEqual(TextFilter.titleCase.apply("hello there"), "Hello There", "change case")
        checkEqual(TextFilter.firstLine.apply("first\nsecond"), "first", "keep the first line")

        // Conditions
        let contains = MacroCondition(left: "%Name%", test: .contains, right: "sa")
        check(vars.isTrue(contains), "conditions: contains (ignoring case)")
        check(!vars.isTrue(MacroCondition(left: "%Name%", test: .equals, right: "Alex")), "is")
        check(vars.isTrue(MacroCondition(left: "%Missing%", test: .isEmpty)), "is empty")
        check(vars.isTrue(MacroCondition(left: "12", test: .greaterThan, right: "9")), "numbers compare as numbers (12 > 9)")
        check(vars.isTrue(MacroCondition(left: "ABC-123", test: .matches, right: "^[A-Z]+-[0-9]+$")), "matches a pattern")

        // A whole macro: variables, loops, if/otherwise, scripts, questions, notifications, pause and stop
        let engine = MacroRun(runner: runner)
        var asked: [String] = []
        engine.ask = { prompt, options in asked.append(prompt); return options?.last ?? "Robin" }
        var notes: [String] = []
        engine.notify = { title, message in notes.append("\(title): \(message)") }
        let started = Date()
        runSteps(engine, [
            step(.setVariable, name: "Total", text: "0"),
            step(.repeatTimes, number: 4, steps: [step(.setVariable, name: "Total", text: "%Index%")]),
            step(.askInput, name: "Who", text: "Who?"),
            step(.pickFromList, name: "Colour", text: "Colour?", text2: "Red\nBlue"),
            step(.setVariable, name: "Greeting", text: "hello %Who%"),
            step(.textFilter, name: "Greeting", filter: .uppercase),
            step(.ifThen, condition: MacroCondition(left: "%Greeting%", test: .contains, right: "ROBIN"),
                 steps: [step(.setVariable, name: "Branch", text: "then")], elseSteps: [step(.setVariable, name: "Branch", text: "otherwise")]),
            step(.script, name: "Shell", action: MacroAction(kind: .shell, value: "echo \"script saw $TB_Who\"")),
            step(.script, name: "Apple", action: MacroAction(kind: .appleScript, value: "return 2 + 3")),
            step(.textFilter, name: "Greeting", text2: "Words", filter: .countWords),
            step(.repeatWhile, condition: MacroCondition(left: "%Index%", test: .lessThan, right: "3"),
                 steps: [step(.setVariable, name: "Loops", text: "%Index%")]),
            step(.pause, number: 0.5),
            step(.notify, text: "%Who% chose %Colour%", text2: "Done"),
            step(.stop),
            step(.setVariable, name: "AfterStop", text: "ran"),
        ])
        checkEqual(engine.value(of: "Total"), "4", "Repeat runs its steps the number of times (%Index% counts)")
        checkEqual(asked, ["Who?", "Colour?"], "macros can ask for text and for a choice from a list")
        checkEqual(engine.value(of: "Colour"), "Blue", "and keep the answer")
        checkEqual(engine.value(of: "Greeting"), "HELLO ROBIN", "text can be changed (here to UPPERCASE)")
        checkEqual(engine.value(of: "Branch"), "then", "If… then… runs the right branch")
        checkEqual(engine.value(of: "Shell"), "script saw Robin", "shell scripts see the variables and give back their output")
        checkEqual(engine.value(of: "Apple"), "5", "so do AppleScripts")
        checkEqual(engine.value(of: "Words"), "2", "counts can go into another variable")
        checkEqual(engine.value(of: "Loops"), "3", "Repeat while stops when its condition is no longer true")
        check(Date().timeIntervalSince(started) >= 0.5, "Pause waits")
        checkEqual(notes, ["Done: Robin chose Blue"], "notifications are shown with the variables filled in")
        checkEqual(engine.value(of: "AfterStop"), "", "Stop ends the macro")

        let endless = MacroRun(runner: runner)
        runSteps(endless, [step(.repeatWhile, condition: MacroCondition(left: "x", test: .equals, right: "x"),
                                steps: [step(.setVariable, name: "N", text: "%Index%")])])
        checkEqual(endless.value(of: "N"), String(MacroRun.loopLimit), "a loop that would never end stops after \(MacroRun.loopLimit) rounds")
        let cancelled = MacroRun(runner: runner)
        cancelled.ask = { _, _ in nil }
        runSteps(cancelled, [step(.askInput, name: "A", text: "?"), step(.setVariable, name: "B", text: "after")])
        checkEqual(cancelled.value(of: "B"), "", "cancelling a question stops the macro")

        // Times
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 18))! // a Friday
        var weekdays = MacroTrigger(kind: .timeOfDay)
        weekdays.number = 9 * 60
        weekdays.weekdays = [2, 3, 4, 5, 6]
        checkEqual(MacroSchedule.next(weekdays, after: friday, calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)),
                   "a weekday 09:00 macro next runs on Monday at 09:00")
        var daily = weekdays
        daily.weekdays = []
        checkEqual(MacroSchedule.next(daily, after: friday, calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9)),
                   "an every-day one tomorrow")
        var every = MacroTrigger(kind: .every)
        every.number = 15
        checkEqual(MacroSchedule.next(every, after: friday, calendar: calendar), friday.addingTimeInterval(900), "and a repeating one 15 minutes later")

        // The store: groups, search, saving
        let module = AutomationModule(shortcuts: shortcuts)
        let group = MacroGroup(name: "Writing", scope: .only, apps: ["com.apple.TextEdit"])
        var appMacro = Macro(name: "When TextEdit is in front", groupID: group.id)
        appMacro.triggers = [MacroTrigger(kind: .appActivated, text: "com.apple.TextEdit"), MacroTrigger(kind: .launcher), MacroTrigger(kind: .menuBar)]
        appMacro.steps = [step(.setVariable, name: "Seen", text: "yes")]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-macro-folder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var fileMacro = Macro(name: "New invoice")
        fileMacro.triggers = [MacroTrigger(kind: .fileAdded, text: folder.path), MacroTrigger(kind: .terminal), MacroTrigger(kind: .typedText, text: ";;inv")]
        fileMacro.steps = [step(.setVariable, name: "File", text: "%Trigger%")]
        module.store.groups = [group]
        module.store.macros = [appMacro, fileMacro]
        checkEqual(MacroStore().macros.map(\.name), ["When TextEdit is in front", "New invoice"], "macros are saved")
        checkEqual(module.store.search("invoice").map(\.name), ["New invoice"], "macros can be searched by name")
        checkEqual(module.store.search("textedit").map(\.name), ["When TextEdit is in front"], "or by what starts them")
        checkEqual(module.store.search("trigger").map(\.name), ["New invoice"], "or by their steps")
        check(module.store.isActive(appMacro, in: "com.apple.TextEdit") && !module.store.isActive(appMacro, in: "com.apple.Safari"),
              "a group can limit its macros to certain apps")

        module.start()
        module.appEvent(.appActivated, bundleID: "com.apple.TextEdit", name: "TextEdit")
        spin(0.3)
        checkEqual(module.history.last, "When TextEdit is in front", "switching to an app runs its macro")
        let ranBefore = module.history.filter { $0 == "When TextEdit is in front" }.count
        module.appEvent(.appActivated, bundleID: "com.apple.Safari", name: "Safari")
        spin(0.3)
        checkEqual(module.history.filter { $0 == "When TextEdit is in front" }.count, ranBefore, "switching to another app doesn't")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("INV-7.pdf").path, contents: Data("pdf".utf8))
        _ = DownloadTests.waitFor(5) { module.history.last == "New invoice" && module.lastRun?.value(of: "File").isEmpty == false }
        checkEqual(module.history.last, "New invoice", "adding a file to a watched folder runs its macro")
        check(module.lastRun?.value(of: "File").hasSuffix("INV-7.pdf") == true, "with the file in %Trigger%")
        check(module.gestureRules().contains { $0.gesture == .keySequence(";;inv") && $0.action == MacroAction(kind: .macro, value: "New invoice") },
              "typed-text triggers are handed to the Gestures module")
        check(module.menuItems().contains { $0.title.contains("When TextEdit is in front") }, "menu-bar macros are in the menu")
        check(MacrosLauncherProvider(module: module).results(for: "textedit").contains { $0.title == "When TextEdit is in front" }, "launcher macros are in the launcher")
        let bridge = "build/Toolbelt.app/Contents/MacOS/ToolbeltBridge"
        if FileManager.default.fileExists(atPath: bridge) {
            let terminal = Process()
            terminal.executableURL = URL(fileURLWithPath: bridge)
            terminal.arguments = ["run", "new invoice", "from", "Terminal"]
            var environment = ProcessInfo.processInfo.environment
            environment["TOOLBELT_DATA_DIR"] = SettingsStore.folder.path
            environment["TOOLBELT_BRIDGE_NO_LAUNCH"] = "1"
            terminal.environment = environment
            try? terminal.run()
            terminal.waitUntilExit()
            _ = DownloadTests.waitFor(5) { module.lastRun?.value(of: "File") == "from Terminal" }
            checkEqual(module.lastRun?.value(of: "File"), "from Terminal", "a command in Terminal runs a macro by name")
        }
        module.stop()
        try? FileManager.default.removeItem(at: folder)

        // Actions added for macros
        runner.run(MacroAction(kind: .setClipboard, value: "set by an action"))
        checkEqual(NSPasteboard.general.string(forType: .string), "set by an action", "an action can set the clipboard")
        check(DisplayModes.size(from: "1920 × 1080")! == (1920, 1080), "screen sizes are understood")
        check(!DisplayModes.available().isEmpty, "the display's sizes can be listed")
        check(AudioOutputs.all().count >= 0, "sound outputs can be listed")
        checkEqual(MenuClicker.normalise("Export as PDF…"), "export as pdf", "menu items are found ignoring case and …")
    }
}

// MARK: - End to end

/// Starts the real Toolbelt app and uses it with real key presses, checking the results in
/// TextEdit and Calculator — the closest an automated test gets to a person using it.
@MainActor
enum EndToEndTests {
    static let letters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        " ": kVK_Space, ";": kVK_ANSI_Semicolon,
    ]

    static func press(_ key: Int, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        // A real keyboard marks arrow keys as keypad + Fn keys; shortcuts with arrows rely on it.
        var flags = flags
        if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(key) {
            flags.formUnion([.maskNumericPad, .maskSecondaryFn])
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        spin(0.08)
    }

    static func type(_ text: String) {
        for ch in text {
            if ch == "*" { press(kVK_ANSI_8, .maskShift) } else if let key = letters[ch] { press(key) }
        }
    }

    /// Windows Toolbelt has on screen (panels, shelves, Settings).
    static func windowCount(of pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }.count
    }

    static func run() {
        let appPath = "build/Toolbelt.app/Contents/MacOS/Toolbelt"
        guard FileManager.default.fileExists(atPath: appPath) else {
            print("  – skipped: build the app first (bash build.sh)")
            return
        }
        guard AXIsProcessTrusted(), Permission.inputMonitoring.isGranted else {
            print("  – skipped: this Mac hasn't given the test program Input Monitoring and Accessibility")
            return
        }

        // Toolbelt with its own scratch data, some snippets, and a saved layout for TextEdit.
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-e2e-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if let screen = NSScreen.screens.first {
            let layout = SavedLayout(name: "Writing", entries: [SavedLayout.Entry(
                bundleID: "com.apple.TextEdit", appName: "TextEdit", display: DisplayID.name(of: screen),
                place: RelativeRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))])
            try? JSONEncoder().encode([layout]).write(to: data.appendingPathComponent("layouts.json"))
        }
        try? #"[{"id":"8E3C1E2A-0000-4000-8000-000000000001","keyword":";ee","name":"E2E","text":"End to end works"},{"id":"8E3C1E2A-0000-4000-8000-000000000002","keyword":";hi","name":"Greeting","text":"Hello {input:Name}!"}]"#
            .write(to: data.appendingPathComponent("snippets.json"), atomically: true, encoding: .utf8)
        // Gestures that leave a mark when they work, and one that types into TextEdit.
        let gestureRules = [
            GestureRule(gesture: .mouseButton(3), action: MacroAction(kind: .shell, value: "touch \"$TOOLBELT_DATA_DIR/button4\"")),
            GestureRule(gesture: .modifierTap(.rightShift, taps: 2), action: MacroAction(kind: .shell, value: "touch \"$TOOLBELT_DATA_DIR/doubleshift\"")),
            GestureRule(gesture: .stroke(button: 1, path: "L"), action: MacroAction(kind: .shell, value: "touch \"$TOOLBELT_DATA_DIR/strokeleft\"")),
            GestureRule(gesture: .keySequence(";;z"), action: MacroAction(kind: .typeText, value: "sequence works")),
        ]
        try? JSONEncoder().encode(gestureRules).write(to: data.appendingPathComponent("gestures.json"))
        // Macros started by a shortcut, typed text, an app opening and Terminal.
        func touch(_ name: String) -> MacroStep {
            MacroStep(kind: .script, action: MacroAction(kind: .shell, value: "printf '%s' \"$TB_Trigger\" > \"$TOOLBELT_DATA_DIR/\(name)\""))
        }
        var hotKey = MacroTrigger(kind: .hotKey)
        hotKey.keyCode = kVK_ANSI_M
        hotKey.modifiers = controlKey | optionKey | cmdKey
        let macros = SavedMacros(macros: [
            Macro(name: "Clear the document", triggers: [hotKey], steps: [
                MacroStep(kind: .action, action: MacroAction(kind: .menuItem, value: "Edit > Select All")),
                MacroStep(kind: .pause, number: 0.3),
                MacroStep(kind: .action, action: MacroAction(kind: .pressKeys, keyCode: kVK_Delete)),
                touch("macro-hotkey"),
            ]),
            Macro(name: "Typed", triggers: [MacroTrigger(kind: .typedText, text: ";;m")], steps: [touch("macro-typed")]),
            Macro(name: "Calculator opened", triggers: [MacroTrigger(kind: .appLaunched, text: "com.apple.calculator")], steps: [touch("macro-app")]),
            Macro(name: "From Terminal", triggers: [MacroTrigger(kind: .terminal)], steps: [touch("macro-terminal")]),
        ], groups: [])
        try? JSONEncoder().encode(macros).write(to: data.appendingPathComponent("macros.json"))
        let app = Process()
        app.executableURL = URL(fileURLWithPath: appPath)
        var environment = ProcessInfo.processInfo.environment
        environment["TOOLBELT_DATA_DIR"] = data.path
        app.environment = environment
        do { try app.run() } catch { check(false, "Toolbelt starts", "\(error)"); return }
        spin(4)
        check(app.isRunning, "Toolbelt starts and keeps running")
        let pid = app.processIdentifier

        // TextEdit with an empty document, in front.
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: document.path, contents: Data())
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "TextEdit", document.path]
        try? open.run()
        open.waitUntilExit()
        spin(3)
        guard let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            check(false, "TextEdit opens")
            app.terminate()
            return
        }
        func focusTextEdit() {
            textEdit.activate()
            spin(0.8)
        }
        func clearDocument() {
            focusTextEdit()
            press(kVK_ANSI_A, .maskCommand)
            press(kVK_Delete)
        }
        focusTextEdit()

        // 1. Clipboard: copy, ⌘⇧V, Return → pasted into TextEdit
        let unique = "Copied for the end to end test \(Int.random(in: 1000...9999))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(unique, forType: .string)
        spin(1.5)
        clearDocument()
        let before = windowCount(of: pid)
        press(kVK_ANSI_V, [.maskCommand, .maskShift])
        spin(1)
        check(windowCount(of: pid) > before, "⌘⇧V opens the clipboard history over TextEdit")
        press(kVK_Return)
        spin(1.5)
        checkEqual(SnippetTypingTests.text(in: textEdit), unique, "pressing Return pastes the copied text into TextEdit")

        // 1b. Paste stack: pick two items in order, ⌘↩ pastes the first, ⌃⌥V the next
        for text in ["Stack one ", "Stack two"] {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            spin(1.2)
        }
        clearDocument()
        press(kVK_ANSI_V, [.maskCommand, .maskShift])
        spin(1)
        press(kVK_DownArrow)             // "Stack one" (the older of the two)
        press(kVK_ANSI_K, .maskCommand)
        press(kVK_UpArrow)               // "Stack two"
        press(kVK_ANSI_K, .maskCommand)
        press(kVK_Return, .maskCommand)
        spin(1.5)
        press(kVK_ANSI_V, [.maskControl, .maskAlternate])
        spin(1.5)
        checkEqual(SnippetTypingTests.text(in: textEdit), "Stack one Stack two", "the paste stack pastes items in the order picked (⌘K, ⌘↩, ⌃⌥V)")

        // 2. Snippets in the real app
        clearDocument()
        type(";ee")
        spin(1.5)
        checkEqual(SnippetTypingTests.text(in: textEdit), "End to end works", "typing ;ee in TextEdit expands the snippet")

        // 2b. A fill-in snippet asks for the blank, then types the result
        clearDocument()
        let beforeForm = windowCount(of: pid)
        type(";hi")
        spin(1.5)
        check(windowCount(of: pid) > beforeForm, "a fill-in snippet asks for its blanks")
        type("sam")
        press(kVK_Return)
        spin(2)
        checkEqual(SnippetTypingTests.text(in: textEdit), "Hello sam!", "and types the snippet with the answer filled in")

        // 2c. The snippet picker
        clearDocument()
        press(kVK_ANSI_Semicolon, [.maskControl, .maskAlternate])
        spin(1)
        type("end to end")
        spin(0.6)
        press(kVK_Return)
        spin(1.5)
        checkEqual(SnippetTypingTests.text(in: textEdit), "End to end works", "⌃⌥; finds a snippet and Return types it")

        // 3. Window shortcuts on TextEdit's window
        focusTextEdit()
        if let window = AXWindow.focused(in: textEdit.processIdentifier), let start = window.frame {
            press(kVK_LeftArrow, [.maskControl, .maskAlternate])
            spin(1)
            let area = Screens.all[Screens.index(containing: start)].area
            let moved = window.frame ?? .zero
            check(abs(moved.minX - area.minX) < 2 && abs(moved.width - area.width / 2) < 3, "⌃⌥← moves TextEdit's window to the left half", "\(moved) in \(area)")
            press(kVK_Return, [.maskControl, .maskAlternate])
            spin(1)
            let full = window.frame ?? .zero
            check(abs(full.width - area.width) < 3, "⌃⌥↩ fills the screen", "\(full) in \(area)")
            press(kVK_Delete, [.maskControl, .maskAlternate])
            spin(1)
            check(abs((window.frame ?? .zero).width - full.width) > 3, "⌃⌥⌫ puts it back")
        } else {
            check(false, "TextEdit's window can be found")
        }

        // 3b. Saved layout 1 (⌃⌥⌘1) puts TextEdit in the bottom-right quarter
        focusTextEdit()
        press(kVK_ANSI_1, [.maskControl, .maskAlternate, .maskCommand])
        spin(1.5)
        if let window = AXWindow.focused(in: textEdit.processIdentifier), let frame = window.frame {
            let area = Screens.all[0].area
            check(abs(frame.minX - area.midX) < 3 && abs(frame.width - area.width / 2) < 3,
                  "⌃⌥⌘1 applies a saved layout", "\(frame) in \(area)")
        }

        // 4. Launcher: sums and opening apps
        focusTextEdit()
        let beforeLauncher = windowCount(of: pid)
        press(kVK_Space, .maskAlternate)
        spin(1)
        check(windowCount(of: pid) > beforeLauncher, "⌥Space opens the launcher")
        type("6*7")
        spin(0.5)
        press(kVK_Return)
        spin(1)
        checkEqual(NSPasteboard.general.string(forType: .string), "42", "typing 6*7 and Return copies the answer, 42")

        focusTextEdit()
        press(kVK_Space, .maskAlternate)
        spin(1)
        type("calculator")
        spin(1)
        press(kVK_Return)
        // Opening an app can take a while on a busy Mac; wait for it (and for it to settle in front).
        _ = DownloadTests.waitFor(15) { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").isEmpty }
        spin(2)
        let calculator = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first
        check(calculator != nil, "typing calculator and Return opens Calculator")
        calculator?.forceTerminate()

        // 4b. App switcher: ⌥⇥, type, ⌘H hides; ⌥⇥, type, Return brings it back
        focusTextEdit()
        let beforeSwitcher = windowCount(of: pid)
        press(kVK_Tab, .maskAlternate)
        spin(1)
        check(windowCount(of: pid) > beforeSwitcher, "⌥⇥ opens the app switcher")
        type("textedit")
        spin(0.6)
        // Plain h, q and w are just typed into the search; only ⌘H, ⌘Q and ⌘W act on the app.
        type("h")
        spin(0.6)
        check(!textEdit.isHidden && !textEdit.isTerminated, "typing h in the switcher's search doesn't hide anything")
        press(kVK_Delete)
        spin(0.4)
        press(kVK_ANSI_H, .maskCommand)
        spin(1)
        check(textEdit.isHidden, "⌘H in the switcher hides the chosen app")
        press(kVK_Escape)
        press(kVK_Tab, .maskAlternate)
        spin(1)
        type("textedit")
        spin(0.6)
        press(kVK_Return)
        spin(1.5)
        check(!textEdit.isHidden && textEdit.isActive, "Return in the switcher brings it back to the front")

        // 4c. Floating note
        let beforeNote = windowCount(of: pid)
        press(kVK_ANSI_N, [.maskControl, .maskAlternate])
        spin(1)
        check(windowCount(of: pid) > beforeNote, "⌃⌥N opens a new floating note")

        // 5. Shelf shortcut
        focusTextEdit()
        let windowsBefore = windowCount(of: pid)
        press(kVK_ANSI_S, [.maskControl, .maskAlternate])
        spin(1)
        check(windowCount(of: pid) > windowsBefore, "⌃⌥S opens a new shelf")

        // 5b. A new screenshot appears on a shelf; ⌃⌥⌘G shows the drop targets
        let beforeScreenshot = windowCount(of: pid)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let shot = desktop.appendingPathComponent("Screenshot e2e \(Int.random(in: 1000...9999)).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", shot.path]
        try? capture.run()
        capture.waitUntilExit()
        spin(2.5)
        check(windowCount(of: pid) > beforeScreenshot, "a new screenshot appears on a shelf by itself")
        try? FileManager.default.removeItem(at: shot)
        let beforeGrid = windowCount(of: pid)
        press(kVK_ANSI_G, [.maskControl, .maskAlternate, .maskCommand])
        spin(1)
        check(windowCount(of: pid) > beforeGrid, "⌃⌥⌘G shows the drop targets")

        // 6. The Services menu, as used from another app's right-click menu
        let register = Process()
        register.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        register.arguments = ["-f", URL(fileURLWithPath: "build/Toolbelt.app").path]
        try? register.run()
        register.waitUntilExit()
        let refresh = Process()
        refresh.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        refresh.arguments = ["-update"]
        try? refresh.run()
        refresh.waitUntilExit()
        spin(2)
        let shelvesBefore = windowCount(of: pid)
        let selection = NSPasteboard(name: NSPasteboard.Name("toolbelt-e2e-service"))
        selection.clearContents()
        selection.setString("Sent from the Services menu", forType: .string)
        check(NSPerformService("Add to Toolbelt Shelf", selection), "“Add to Toolbelt Shelf” is offered in the Services menu")
        spin(1.5)
        check(windowCount(of: pid) > shelvesBefore, "and choosing it opens a shelf in Toolbelt")

        // 7. Gestures: an extra mouse button, a double-tap of right Shift, a right-button stroke, a typed sequence
        func mark(_ name: String) -> Bool { FileManager.default.fileExists(atPath: data.appendingPathComponent(name).path) }
        focusTextEdit()
        let centre = CGPoint(x: (NSScreen.main?.frame.midX ?? 600), y: (NSScreen.main?.frame.midY ?? 400))
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: centre, mouseButton: .center)
            event?.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            event?.post(tap: .cghidEventTap)
            spin(0.05)
        }
        spin(1.5)
        check(mark("button4"), "pressing mouse button 4 runs its gesture")
        for _ in 0..<2 {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 60, keyDown: true)
            down?.flags = .maskShift
            down?.post(tap: .cghidEventTap)
            spin(0.06)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 60, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
            spin(0.12)
        }
        spin(1.5)
        check(mark("doubleshift"), "tapping right Shift twice runs its gesture")
        CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: centre, mouseButton: .right)?.post(tap: .cghidEventTap)
        for step in 1...10 {
            spin(0.02)
            CGEvent(mouseEventSource: source, mouseType: .rightMouseDragged, mouseCursorPosition: CGPoint(x: centre.x - CGFloat(step) * 20, y: centre.y), mouseButton: .right)?.post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: CGPoint(x: centre.x - 200, y: centre.y), mouseButton: .right)?.post(tap: .cghidEventTap)
        spin(1.5)
        check(mark("strokeleft"), "holding the right button and drawing left runs its gesture")
        clearDocument()
        type(";;z")
        spin(2)
        checkEqual(SnippetTypingTests.text(in: textEdit), "sequence works", "typing ;;z runs its gesture (here: typing text in its place)")

        // 8. Macros: a shortcut that chooses a menu item and presses a key, typed text, an app opening, Terminal
        check(mark("macro-app"), "opening Calculator (earlier) ran the “app opens” macro")
        clearDocument()
        type("text to clear")
        spin(0.5)
        press(kVK_ANSI_M, [.maskControl, .maskAlternate, .maskCommand])
        spin(2.5)
        check(mark("macro-hotkey"), "⌃⌥⌘M runs its macro")
        checkEqual(SnippetTypingTests.text(in: textEdit), "", "which chose Edit › Select All and pressed ⌫ in TextEdit")
        type(";;m")
        spin(2)
        check(mark("macro-typed"), "typing ;;m runs its macro")
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "build/Toolbelt.app/Contents/MacOS/ToolbeltBridge")
        terminal.arguments = ["run", "From Terminal", "hello"]
        var terminalEnvironment = ProcessInfo.processInfo.environment
        terminalEnvironment["TOOLBELT_DATA_DIR"] = data.path
        terminalEnvironment["TOOLBELT_BRIDGE_NO_LAUNCH"] = "1"
        terminal.environment = terminalEnvironment
        try? terminal.run()
        terminal.waitUntilExit()
        spin(2)
        checkEqual(try? String(contentsOf: data.appendingPathComponent("macro-terminal"), encoding: .utf8), "hello", "`ToolbeltBridge run \"From Terminal\" hello` runs that macro")

        check(app.isRunning, "Toolbelt is still running after all that")
        app.terminate()
        textEdit.forceTerminate()
        try? FileManager.default.removeItem(at: data)
        try? FileManager.default.removeItem(at: document)
    }
}

// MARK: - Backup and Services

@MainActor
enum BackupTests {
    static func run() {
        let from = FileManager.default.temporaryDirectory.appendingPathComponent("backup-from-\(UUID().uuidString)")
        let to = FileManager.default.temporaryDirectory.appendingPathComponent("backup-to-\(UUID().uuidString)")
        for folder in [from, to] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try? Data("settings".utf8).write(to: from.appendingPathComponent("settings.plist"))
        try? Data("snippets".utf8).write(to: from.appendingPathComponent("snippets.json"))
        try? Data("history".utf8).write(to: from.appendingPathComponent("history.json"))

        guard let data = try? Backup.export(from: from) else { check(false, "settings can be exported"); return }
        check(true, "settings can be exported to one file")
        let restored = (try? Backup.restore(data, into: to)) ?? []
        checkEqual(restored, ["settings.plist", "snippets.json"], "importing restores settings and snippets")
        checkEqual(FileManager.default.contents(atPath: to.appendingPathComponent("snippets.json").path), Data("snippets".utf8), "with the same contents")
        check(!FileManager.default.fileExists(atPath: to.appendingPathComponent("history.json").path), "clipboard history isn't part of a settings backup")
        check((try? Backup.restore(Data("not a backup".utf8), into: to)) == nil, "other files are refused")
    }
}

@MainActor
enum ServicesTests {
    static func run() {
        let shortcuts = ShortcutCenter()
        let manager = ModuleManager(shortcuts: shortcuts)
        let shelf = ShelfModule(shortcuts: shortcuts)
        let snippets = SnippetsModule(shortcuts: shortcuts) {}
        let clipboard = ClipboardModule(shortcuts: shortcuts)
        manager.register(shelf)
        manager.register(snippets)
        manager.register(clipboard)
        let provider = ServicesProvider(modules: manager)
        var error: NSString = ""

        let shelvesBefore = shelf.store.shelves.count
        provider.addToShelf(ShelfStoreTests.pasteboard(["Text from another app" as NSString]), userData: nil, error: &error)
        checkEqual(shelf.store.shelves.count, shelvesBefore + 1, "“Add to Toolbelt Shelf” opens a shelf")
        checkEqual(shelf.store.shelves.last?.items.first?.text, "Text from another app", "holding what was selected")
        if let id = shelf.store.shelves.last?.id { shelf.close(id) }

        provider.saveSnippet(ShelfStoreTests.pasteboard(["Kind regards,\nAlex" as NSString]), userData: nil, error: &error)
        checkEqual(snippets.store.snippets.last?.text, "Kind regards,\nAlex", "“Save as Toolbelt Snippet” makes a snippet from the selection")
        snippets.store.snippets.removeLast()

        provider.pinInClipboard(ShelfStoreTests.pasteboard(["Keep this safe" as NSString]), userData: nil, error: &error)
        check(clipboard.store.items.first.map { $0.text == "Keep this safe" && $0.pinned } == true, "“Pin in Toolbelt Clipboard” saves and pins it")

        error = ""
        provider.downloadLink(ShelfStoreTests.pasteboard(["just words" as NSString]), userData: nil, error: &error)
        check(error.length > 0, "a selection that isn't a link is explained, not downloaded")

        let plist = (try? Data(contentsOf: URL(fileURLWithPath: "Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let services = (plist?["NSServices"] as? [[String: Any]])?.compactMap { $0["NSMessage"] as? String } ?? []
        checkEqual(services.sorted(), ["addToShelf", "downloadLink", "pinInClipboard", "saveSnippet"], "every service in Info.plist has a matching method")
        for message in services {
            check(provider.responds(to: Selector("\(message):userData:error:")), "Toolbelt answers “\(message)”")
        }
    }
}

// MARK: - Clipboard [Next]

@MainActor
func freshClipboard() -> ClipboardStore {
    let store = ClipboardStore()
    for item in store.items { store.delete(item.id) }
    return store
}

@MainActor
enum ClipboardNextTests {
    static func run() {
        checkEqual(TextTransform.uppercase.apply("Hello there"), "HELLO THERE", "UPPERCASE")
        checkEqual(TextTransform.lowercase.apply("Hello THERE"), "hello there", "lowercase")
        checkEqual(TextTransform.titleCase.apply("the quick brown fox"), "The Quick Brown Fox", "Title Case")
        checkEqual(TextTransform.trimSpaces.apply("  too   many  spaces \n  second   line  "), "too many spaces\nsecond line", "trim spaces (keeps line breaks)")
        checkEqual(TextTransform.removeLineBreaks.apply("line one\nline two\n\nline three"), "line one line two line three", "remove line breaks")

        let store = freshClipboard()
        let paster = Paster(store: store, monitor: ClipboardMonitor(store: store))
        let styled = NSAttributedString(string: "Shout this", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        store.add(ClipItem(kind: .text, text: "Shout this", rtf: styled.rtf(from: NSRange(location: 0, length: styled.length)), hash: "shout"))
        Prefs.pasteAfterSelect = false // only put it on the clipboard; don't press ⌘V in the test
        paster.paste(store.items[0], plainText: false, transform: .uppercase)
        checkEqual(NSPasteboard.general.string(forType: .string), "SHOUT THIS", "pasting with a transform changes the text")
        check(NSPasteboard.general.data(forType: .rtf) == nil, "and drops the old formatting")
        checkEqual(store.items.first?.text, "Shout this", "the history item itself is unchanged")

        // Editing before pasting
        let model = PanelModel(store: store)
        model.beginEditing(store.items[0])
        check(model.editingID != nil, "⌘E starts editing a text item")
        model.draft = "Edited text"
        let edited = model.saveEditing()
        checkEqual(edited?.text, "Edited text", "the edited text is saved")
        checkEqual(store.items.first?.text, "Edited text", "into the history item")
        check(store.items.first?.rtf == nil, "with its old formatting dropped")

        // Paste stack: chosen order, not history order
        for word in ["first", "second", "third"] { store.add(ClipboardStoreTests.text(word)) } // newest: third
        let byText = { (t: String) in store.items.first { $0.text == t }! }
        model.toggleStack(byText("first"))
        model.toggleStack(byText("third"))
        model.toggleStack(byText("second"))
        checkEqual(model.stackedItems.map { $0.text ?? "" }, ["first", "third", "second"], "⌘K builds a paste stack in the order chosen")
        checkEqual(model.stackPosition(of: byText("third")), 2, "each item shows its place in the stack")
        model.toggleStack(byText("third"))
        checkEqual(model.stackedItems.map { $0.text ?? "" }, ["first", "second"], "⌘K again takes an item out")
        let stack = PasteStack()
        stack.load(model.stackedItems)
        checkEqual(stack.next()?.text, "first", "the stack pastes the first item first")
        checkEqual(stack.next()?.text, "second", "then the next")
        check(stack.next() == nil, "and then it's empty")
        Prefs.pasteAfterSelect = true

        // Layouts
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let strip = HistoryPanelController.frame(for: .strip, on: screen)
        check(strip.width > 1300 && strip.minY < 50, "the strip layout runs along the bottom of the screen", "\(strip)")
        check(HistoryPanelController.frame(for: .grid, on: screen).width > HistoryPanelController.frame(for: .list, on: screen).width, "the grid layout is wider than the list")
        Prefs.clipboardLayout = .grid
        checkEqual(Prefs.clipboardLayout, .grid, "the chosen layout is remembered")
        Prefs.clipboardLayout = .list
    }
}

@MainActor
enum ClipboardCollectionsTests {
    static func run() {
        let module = ClipboardModule(shortcuts: ShortcutCenter())
        let store = module.store
        for item in store.items { store.delete(item.id) }
        for board in module.pinboards.pinboards { module.pinboards.pinboards.removeAll { $0.id == board.id } }
        for word in ["home address", "work address", "random note"] { store.add(ClipboardStoreTests.text(word)) }
        let home = store.items.first { $0.text == "home address" }!
        let work = store.items.first { $0.text == "work address" }!

        let board = module.pinboards.create("Addresses")
        module.pinboards.toggle(home.id, on: board.id)
        module.pinboards.toggle(work.id, on: board.id)
        let model = module.panel.model
        model.pinboardFilter = board.id
        checkEqual(Set(model.results.map { $0.text ?? "" }), ["home address", "work address"], "a pinboard shows just its items")
        model.pinboardFilter = nil
        checkEqual(PinboardStore().pinboards.first?.name, "Addresses", "pinboards are saved")

        store.clearUnpinned()
        checkEqual(Set(store.items.map { $0.text ?? "" }), ["home address", "work address"], "Clear History keeps pinboard items")

        // Auto-delete
        store.add(ClipboardStoreTests.text("old note"))
        store.update(store.items[0].id) { $0.lastUsed = Date().addingTimeInterval(-10 * 86_400) }
        store.update(home.id) { $0.lastUsed = Date().addingTimeInterval(-10 * 86_400) }
        store.deleteOlder(thanDays: 7)
        check(!store.items.contains { $0.text == "old note" }, "items older than the chosen age are deleted")
        check(store.items.contains { $0.text == "home address" }, "but pinboard items stay")
        store.deleteOlder(thanDays: 0)
        checkEqual(store.items.count, 2, "“Never” deletes nothing")

        // Named clipboards
        module.named.save(home, as: "Home")
        checkEqual(module.named.clip(named: "home")?.item.text, "home address", "a named clipboard is found by its name")
        store.delete(home.id)
        checkEqual(NamedClipboardStore(imagesFolder: store.imagesFolder).clip(named: "Home")?.item.text, "home address", "and keeps its own copy after the history item is deleted")
        module.named.save(work, as: "Home")
        checkEqual(module.named.clip(named: "Home")?.item.text, "work address", "saving under the same name replaces it")
        let provider = ClipboardLauncherProvider(store: store, paster: module.paster, named: module.named)
        checkEqual(provider.results(for: "home").first?.kind, "Named Clipboard", "the launcher pastes named clipboards by name")
        module.named.remove(named: "Home")
        check(module.named.clip(named: "Home") == nil, "named clipboards can be removed")
    }
}

@MainActor
enum ImageTextTests {
    static func run() {
        // Draw some words into an image, then read them back.
        let image = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Invoice 4471 overdue" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [
                .font: NSFont.systemFont(ofSize: 42, weight: .semibold), .foregroundColor: NSColor.black,
            ])
            return true
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            check(false, "test image can be made")
            return
        }
        try? png.write(to: url)
        final class Result: @unchecked Sendable { var text: String? }
        let result = Result()
        Task { @MainActor in result.text = await ImageText.recognize(at: url) }
        _ = DownloadTests.waitFor(20) { result.text != nil }
        let text = result.text ?? ""
        check(text.contains("Invoice") && text.contains("4471"), "text in an image is read", "read: \(text)")
        var item = ClipItem(kind: .image, hash: "ocr")
        item.ocrText = text
        check(PanelModel.matches(item, "invoice overdue"), "so the image can be found by searching for its words")
    }
}

// MARK: - Launcher [Next]

@MainActor
enum LauncherNextTests {
    static func run() {
        let usage = LauncherUsage()
        checkEqual(usage.boost(for: "never-used"), 0, "results you've never picked get no boost")
        usage.record("app:/Applications/Notes.app")
        usage.record("app:/Applications/Notes.app")
        check(usage.boost(for: "app:/Applications/Notes.app") > 15, "results you pick often and recently get a boost")
        let longAgo = Date().addingTimeInterval(-30 * 86_400)
        let stale = LauncherUsage()
        stale.record("old", now: longAgo)
        check(stale.boost(for: "old") < usage.boost(for: "app:/Applications/Notes.app"), "the boost fades over time")

        let model = LauncherModel { [StaticProvider([
            LauncherResult(id: "pages", title: "Pages", kind: "Test", icon: .symbol("a"), score: 80) {},
            LauncherResult(id: "preview", title: "Preview", kind: "Test", icon: .symbol("b"), score: 80) {},
        ])] }
        model.usage = LauncherUsage()
        model.query = "p"
        checkEqual(model.results.first?.title, "Pages", "equal matches keep their order at first")
        model.usage?.record("preview")
        model.usage?.record("preview")
        model.query = "pr"
        model.query = "p"
        checkEqual(model.results.first?.title, "Preview", "recently used comes first")
        checkEqual(LauncherUsage().uses["preview"]?.count, 2, "what you use is remembered")

        // Switcher
        let switcher = SwitcherProvider()
        let all = switcher.results(for: "")
        check(all.contains { $0.title == "Finder" && $0.kind == "Running" }, "the switcher lists running apps before you type")
        check(all.first { $0.title == "Finder" }?.extraActions["h"] != nil, "with hide and quit available")
        check(!all.contains { $0.title == "ToolbeltTests" }, "but not Toolbelt itself")
        if AXIsProcessTrusted() {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
            spin(2)
            let windows = switcher.results(for: "finder")
            check(windows.contains { $0.kind == "Window" && $0.extraActions["w"] != nil }, "and their windows, which ⌘W can close")
            if let finderWindow = windows.first(where: { $0.kind == "Window" }) {
                finderWindow.extraActions["w"]?()
                spin(1)
            }
        }
        model.switcher = switcher
        model.query = ""
        check(!model.results.isEmpty, "the launcher in switcher mode shows everything straight away")

        // Notes
        let notes = NotesController(store: NotesStore())
        for note in notes.store.notes { notes.delete(note.id) }
        let id = notes.newNote(text: "Remember the milk")
        checkEqual(notes.store.notes.count, 1, "a new floating note is made")
        check(notes.openWindowCount >= 1, "and shown on screen")
        notes.store.update(id) { $0.text = "Remember the milk and eggs" }
        checkEqual(NotesStore().notes.first?.text, "Remember the milk and eggs", "notes are saved as you type")
        notes.newNote(text: "Second note")
        checkEqual(notes.store.notes.count, 2, "you can have as many notes as you like")
        let provider = NotesLauncherProvider(controller: notes)
        check(provider.results(for: "new note").contains { $0.title == "New Floating Note" }, "the launcher can make a new note")
        check(provider.results(for: "milk").contains { $0.title == "Remember the milk and eggs" }, "and find notes by what's in them")
        for note in notes.store.notes { notes.delete(note.id) }
        checkEqual(NotesStore().notes.count, 0, "deleted notes are gone")
    }
}

// MARK: - Snippets [Next]

@MainActor
enum SnippetsNextTests {
    static func run() {
        let template = "Hi {input:Name}, your order {input:Order|#000} ships today. Thanks again, {input:Name}!"
        let fields = Placeholders.fields(in: template)
        checkEqual(fields.map(\.name), ["Name", "Order"], "the blanks in a fill-in snippet are found, each once")
        checkEqual(fields.map(\.defaultValue), ["", "#000"], "with their suggested answers")
        checkEqual(Placeholders.render(template, inputs: ["Name": "Sam", "Order": "#4471"]).text,
                   "Hi Sam, your order #4471 ships today. Thanks again, Sam!", "answers are filled in everywhere")
        checkEqual(Placeholders.render("Order {input:Order|#000}").text, "Order #000", "an unanswered blank uses its suggestion")
        check(Placeholders.fields(in: "No blanks here {date}").isEmpty, "ordinary snippets have no blanks")

        let old = #"[{"id":"9E3C1E2A-0000-4000-8000-000000000001","keyword":";a","name":"Old","text":"x"}]"#
        let decoded = try? JSONDecoder().decode([Snippet].self, from: Data(old.utf8))
        checkEqual(decoded?.first?.folderName, "No folder", "snippets saved before folders existed still load")

        let store = SnippetStore()
        store.snippets = [
            Snippet(keyword: ";sig", name: "Sign-off", text: "Best wishes", folder: "Email"),
            Snippet(keyword: ";addr", name: "Address", text: "42 Example Street", folder: "Personal"),
        ]
        checkEqual(SnippetStore().snippets.first?.folder, "Email", "folders are saved")
        var inserted: [String] = []
        let picker = SnippetsLauncherProvider(store: store, listAll: true) { inserted.append($0.keyword) }
        checkEqual(picker.results(for: "").count, 2, "the picker lists every snippet before you type")
        checkEqual(picker.results(for: "personal").first?.title, "Address", "snippets can be found by folder")
        picker.results(for: "sign").first?.action()
        checkEqual(inserted, [";sig"], "choosing one in the picker inserts it")
        check(SnippetsLauncherProvider(store: store).results(for: "").isEmpty, "the launcher itself waits for you to type")

        let form = SnippetFormController()
        var answered: [String: String]?? = .none
        form.ask(title: "Test", fields: [("Name", "Sam")]) { answered = .some($0) }
        spin(0.5)
        check(form.isVisible, "a fill-in form opens")
        form.ask(title: "Another", fields: [("X", "")]) { _ in }
        check(answered == .some(nil), "opening another form cancels the first")
        spin(0.3)
    }
}

// MARK: - Windows [Next]

@MainActor
enum WindowsNextTests {
    static func run() {
        let area = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = CGRect(x: 360, y: 243, width: 720, height: 438)
        let relative = RelativeRect(frame, in: area)
        checkEqual(relative.frame(in: area), frame, "window places are stored relative to the screen and come back exactly")
        let bigger = CGRect(x: 0, y: 25, width: 2880, height: 1750)
        checkEqual(relative.frame(in: bigger).width, 1440, "and scale to a different screen size")

        let areas = [
            SnapArea(display: "D", place: RelativeRect(x: 0, y: 0, width: 1, height: 1)),
            SnapArea(display: "D", place: RelativeRect(x: 0, y: 0, width: 0.25, height: 0.5)),
        ]
        checkEqual(SnapAreaStore.area(at: CGPoint(x: 100, y: 100), among: areas, in: area),
                   CGRect(x: 0, y: 25, width: 360, height: 438), "where snap areas overlap, the smaller one wins")
        checkEqual(SnapAreaStore.area(at: CGPoint(x: 1000, y: 800), among: areas, in: area), area, "a point in only the big area uses it")
        check(SnapAreaStore.area(at: CGPoint(x: 100, y: 100), among: [], in: area) == nil, "no areas, no snapping")
        let store = SnapAreaStore()
        store.areas = areas
        checkEqual(SnapAreaStore().areas.count, 2, "snap areas are saved")
        store.areas = []

        // Save the current layout, mess the windows up, then put the layout back.
        guard AXIsProcessTrusted() else {
            print("  – skipped the real-window part: Accessibility isn't allowed for the test program")
            return
        }
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: document.path, contents: Data())
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "TextEdit", document.path]
        try? open.run()
        open.waitUntilExit()
        spin(3)
        guard let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first,
              let window = LayoutRunner.mainWindow(of: textEdit.processIdentifier) else {
            check(false, "TextEdit opens for the layout test")
            return
        }
        let manager = WindowManager()
        manager.perform(.topLeft, on: window)
        spin(0.8)
        let saved = window.frame ?? .zero
        let entries = LayoutRunner.capture()
        check(entries.contains { $0.bundleID == "com.apple.TextEdit" }, "“Save Current Layout” records each visible app's window")
        manager.perform(.bottomRight, on: window)
        spin(0.8)
        LayoutRunner.apply(SavedLayout(name: "Test", entries: entries.filter { $0.bundleID == "com.apple.TextEdit" }), manager: manager)
        spin(2)
        let restored = window.frame ?? .zero
        check(abs(restored.minX - saved.minX) < 3 && abs(restored.minY - saved.minY) < 3 && abs(restored.width - saved.width) < 3,
              "applying the layout puts the window back where it was saved", "now \(restored), saved \(saved)")
        textEdit.forceTerminate()
        spin(1)
        LayoutRunner.apply(SavedLayout(name: "Test", entries: entries.filter { $0.bundleID == "com.apple.TextEdit" }), manager: manager)
        _ = DownloadTests.waitFor(8) { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty }
        check(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty,
              "applying a layout opens apps that aren't running")
        spin(3)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.forceTerminate()
        try? FileManager.default.removeItem(at: document)
    }
}

// MARK: - Shelf [Next]

@MainActor
enum ShelfNextTests {
    static func makeImage(width: Int, height: Int, at url: URL) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.systemTeal, atX: 1, y: 1)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func run() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        check(ShelfEdge.notch.contains(NSPoint(x: 756, y: 981), screen: screen), "dragging to the top centre (the notch) opens a shelf")
        check(!ShelfEdge.notch.contains(NSPoint(x: 100, y: 981), screen: screen), "but not the top corners")
        check(ShelfEdge.left.contains(NSPoint(x: 0, y: 500), screen: screen), "the left edge works when chosen")
        check(!ShelfEdge.off.contains(NSPoint(x: 756, y: 981), screen: screen), "and nothing happens when it's off")

        check(ScreenshotFolder.isScreenshot("Screenshot 2026-10-30 at 09.41.12.png"), "macOS screenshot names are recognised")
        check(ScreenshotFolder.isScreenshot("Screen Recording 2026-10-30 at 09.41.12.mov"), "and screen recordings")
        check(!ScreenshotFolder.isScreenshot("Holiday.png"), "other pictures aren't")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-next-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Watching a folder
        var seen: [String] = []
        let watcher = FolderWatcher(folder: folder) { urls in seen += urls.map(\.lastPathComponent) }
        watcher.start()
        FileManager.default.createFile(atPath: folder.appendingPathComponent("new report.txt").path, contents: Data("hi".utf8))
        _ = DownloadTests.waitFor(5) { !seen.isEmpty }
        checkEqual(seen, ["new report.txt"], "a watched folder notices new files")
        watcher.stop()

        // Actions
        let big = folder.appendingPathComponent("Photo.png")
        let small = folder.appendingPathComponent("Icon.png")
        makeImage(width: 400, height: 300, at: big)
        makeImage(width: 64, height: 64, at: small)
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        if let archive = ShelfActions.zip([big, small], into: out, name: "Holiday") {
            let list = Process()
            list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            list.arguments = ["-l", archive.path]
            let pipe = Pipe()
            list.standardOutput = pipe
            try? list.run()
            list.waitUntilExit()
            let contents = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            check(contents.contains("Photo.png") && contents.contains("Icon.png"), "Zip makes one archive with every file")
        } else {
            check(false, "Zip makes an archive")
        }
        let halves = ShelfActions.resize([big], into: out, maxSize: nil)
        checkEqual(halves.first.flatMap { NSImageRep(contentsOf: $0) }.map { "\($0.pixelsWide)×\($0.pixelsHigh)" }, "200×150", "Resize to half size")
        check(ShelfActions.resize([small], into: out, maxSize: 1024).isEmpty, "resizing never makes an image bigger")
        let jpegs = ShelfActions.convert([big], into: out, format: "jpeg", fileExtension: "jpg")
        check(jpegs.first.map { $0.pathExtension == "jpg" && NSImage(contentsOf: $0) != nil } == true, "Convert to JPEG makes a real JPEG")
        checkEqual(ShelfActions.bulkNames(for: [big, small], base: "Trip").map(\.lastPathComponent), ["Trip 1.png", "Trip 2.png"], "Rename in Bulk numbers the files")
        let twelve = (1...12).map { folder.appendingPathComponent("f\($0).txt") }
        checkEqual(ShelfActions.bulkNames(for: twelve, base: "Doc").first?.lastPathComponent, "Doc 01.txt", "with leading zeros so they sort in order")

        let module = ShelfModule(shortcuts: ShortcutCenter())
        let id = module.shelve([big, small], onShelfNamed: "Actions test")
        module.perform(.zip, on: id)
        check(module.store.shelf(id)?.items.contains { $0.url?.pathExtension == "zip" } == true, "the shelf's Actions menu adds the zip to the shelf")
        let fileItems = module.store.shelf(id)?.items.filter { $0.url?.pathExtension == "png" } ?? []
        module.rename(fileItems, on: id, base: "Trip")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Trip 1.png").path), "Rename in Bulk renames the files")
        check(module.store.shelf(id)?.items.contains { $0.url?.lastPathComponent == "Trip 2.png" } == true, "and the shelf follows the new names")
        module.close(id)

        // Drop targets
        let renamed = folder.appendingPathComponent("Trip 1.png")
        let destination = folder.appendingPathComponent("Destination")
        var target = DropTarget(kind: .folder, name: "Dest", target: destination.path, copies: true)
        DropTargetRunner.run(target, files: [renamed])
        check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Trip 1.png").path)
              && FileManager.default.fileExists(atPath: renamed.path), "a folder target copies dropped files")
        target.copies = false
        DropTargetRunner.run(target, files: [renamed])
        check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Trip 1 2.png").path)
              && !FileManager.default.fileExists(atPath: renamed.path), "or moves them, when set to move")
        DropTargetRunner.run(DropTarget(kind: .copyPaths, name: "Paths"), files: [destination])
        checkEqual(NSPasteboard.general.string(forType: .string), destination.path, "Copy Paths copies the paths")
        var shelved: [URL] = []
        DropTargetRunner.run(DropTarget(kind: .newShelf, name: "Shelf"), files: [destination]) { shelved = $0 }
        checkEqual(shelved, [destination], "the Shelf target puts files on a shelf")
        check(DropTargetStore().targets.count >= 4, "the grid starts with useful targets")

        try? FileManager.default.removeItem(at: folder)
    }
}
