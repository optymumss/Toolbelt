import AppKit
import Carbon
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
