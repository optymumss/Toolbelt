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

/// Types a keyword into a real text field and checks it expands, if this Mac allows it.
@MainActor
enum SnippetTypingTests {
    static func run() {
        guard AXIsProcessTrusted(), Permission.inputMonitoring.isGranted else {
            print("  – skipped: this Mac hasn't given the test program Input Monitoring and Accessibility")
            return
        }
        // ⌘V needs an Edit menu to reach the text field.
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        NSApp.mainMenu = main

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(textView)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        spin(1)

        let store = SnippetStore()
        store.snippets = [Snippet(keyword: ";tb", name: "Toolbelt", text: "Toolbelt says hi")]
        let expander = SnippetExpander(store: store)
        check(expander.start(), "listening to typing starts")

        for key in [kVK_ANSI_Semicolon, kVK_ANSI_T, kVK_ANSI_B] {
            typeKey(CGKeyCode(key))
            spin(0.1)
        }
        spin(1.5)
        checkEqual(textView.string, "Toolbelt says hi", "typing ;tb in a text field turns into the snippet")
        expander.stop()
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
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

    var partRequests: Int { lock.lock(); defer { lock.unlock() }; return _partRequests }
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
            lock.lock()
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
