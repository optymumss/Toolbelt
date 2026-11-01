import AppKit
import SwiftUI

@main
enum ToolbeltApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar app, no Dock icon
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shortcuts: ShortcutCenter!
    private var modules: ModuleManager!
    private var settings: SettingsWindowController!
    private var statusMenu: StatusMenu!
    private var services: ServicesProvider!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        Prefs.appearance.apply()

        shortcuts = ShortcutCenter()
        modules = ModuleManager(shortcuts: shortcuts)
        modules.register(ClipboardModule(shortcuts: shortcuts))
        modules.register(LauncherModule(shortcuts: shortcuts, modules: modules) { [weak self] in
            self?.settings.show(tab: nil)
        })
        modules.register(WindowsModule(shortcuts: shortcuts) { [weak self] in
            self?.settings.show(tab: .module(.windows))
        })
        modules.register(SnippetsModule(shortcuts: shortcuts) { [weak self] in
            self?.settings.show(tab: .module(.snippets))
        })
        modules.register(ShelfModule(shortcuts: shortcuts))
        modules.register(DownloadsModule())
        modules.register(ScreenshotsModule(shortcuts: shortcuts))
        let gestures = GesturesModule(shortcuts: shortcuts) { [weak self] in
            self?.settings.show(tab: .module(.gestures))
        }
        modules.register(gestures)
        modules.register(AutomationModule(shortcuts: shortcuts, gestures: gestures))

        settings = SettingsWindowController(modules: modules, shortcuts: shortcuts)
        statusMenu = StatusMenu(modules: modules, shortcuts: shortcuts) { [weak self] tab in
            self?.settings.show(tab: tab)
        }

        modules.refresh()

        // Right-click and Services menu entries (see NSServices in Info.plist).
        services = ServicesProvider(modules: modules)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        if !RealUseHooks.isOn { warnAboutTakenShortcuts() }
        RealUseHooks.start { [weak self] in
            guard let shortcuts = self?.shortcuts else { return [] }
            return ShortcutAction.allCases.filter { shortcuts.failed.contains($0) }.map(\.rawValue)
        }
        showForScreenshot()
    }

    /// Used by the automated screenshot check: TOOLBELT_SHOW opens one screen on launch.
    private func showForScreenshot() {
        guard let target = ProcessInfo.processInfo.environment["TOOLBELT_SHOW"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            switch target {
            case "settings-general": settings.show(tab: .general)
            case "settings-shortcuts": settings.show(tab: .shortcuts)
            case "settings-permissions": settings.show(tab: .permissions)
            case "settings-clipboard": settings.show(tab: .module(.clipboard))
            case "clipboard": modules.module(.clipboard)?.open()
            case "clipboard-preview": (modules.module(.clipboard) as? ClipboardModule)?.openWithPreview()
            case "clipboard-grid", "clipboard-strip":
                Prefs.clipboardLayout = target == "clipboard-grid" ? .grid : .strip
                modules.module(.clipboard)?.open()
                Prefs.clipboardLayout = .list
            case "clipboard-extras":
                // A pinboard, two items in the paste stack, then the edit-before-pasting box.
                guard let clipboard = modules.module(.clipboard) as? ClipboardModule else { break }
                let items = clipboard.store.items
                let board = clipboard.pinboards.create("Addresses")
                for item in items.prefix(2) { clipboard.pinboards.toggle(item.id, on: board.id) }
                clipboard.open()
                for item in items.prefix(2) { clipboard.panel.model.toggleStack(item) }
                if let first = items.first(where: { $0.kind == .text }) { clipboard.panel.model.beginEditing(first) }
            case "menu": statusMenu.open()
            case "energy-settings":
                // Open every Settings tab, then close the window, as a person might.
                let tabs: [SettingsTab] = [.general, .shortcuts, .permissions] + ModuleID.allCases.map { .module($0) }
                for (i, tab) in tabs.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) { [self] in settings.show(tab: tab) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(tabs.count) * 0.4 + 0.5) { [self] in settings.close() }
            case "settings-launcher": settings.show(tab: .module(.launcher))
            case "launcher-switcher": (modules.module(.launcher) as? LauncherModule)?.openSwitcher()
            case "notes-demo":
                guard let launcher = modules.module(.launcher) as? LauncherModule else { break }
                launcher.notes.newNote(text: "Call the bank about the mortgage\n\n– ask about fixed rates\n– bring payslips")
                let second = launcher.notes.newNote(text: "Ideas for the weekend\n• Kew Gardens\n• Borough Market")
                launcher.notes.store.update(second) { $0.x = 700; $0.y = 300 }
            case "settings-windows": settings.show(tab: .module(.windows))
            case "snap-areas-editor":
                guard let windows = modules.module(.windows) as? WindowsModule, let screen = NSScreen.screens.first else { break }
                let display = DisplayID.name(of: screen)
                windows.areas.areas = [
                    SnapArea(display: display, place: RelativeRect(x: 0, y: 0, width: 0.6, height: 1)),
                    SnapArea(display: display, place: RelativeRect(x: 0.6, y: 0, width: 0.4, height: 0.5)),
                ]
                windows.editor.open()
            case "settings-snippets": settings.show(tab: .module(.snippets))
            case "snippet-picker": (modules.module(.snippets) as? SnippetsModule)?.openPicker()
            case "snippet-form":
                (modules.module(.snippets) as? SnippetsModule)?.form.ask(
                    title: "Meeting follow-up",
                    fields: [("Name", "Sam"), ("Date", "Thursday")]) { _ in }
            case "settings-shelf": settings.show(tab: .module(.shelf))
            case "drop-grid": (modules.module(.shelf) as? ShelfModule)?.dropGrid.show()
            case "settings-screenshots": settings.show(tab: .module(.screenshots))
            case "settings-automation": settings.show(tab: .module(.automation))
            case "floating-menu":
                // An example floating menu and menu-bar item.
                if let automation = modules.module(.automation) as? AutomationModule {
                    let buttons = [
                        FloatingButton(title: "Launcher", symbol: "magnifyingglass", actions: [.toolbelt(.openLauncher)]),
                        FloatingButton(title: "Clipboard", symbol: "doc.on.clipboard", actions: [.toolbelt(.clipboardHistory)]),
                        FloatingButton(title: "Screenshot", symbol: "camera.viewfinder", actions: [.toolbelt(.captureArea)]),
                        FloatingButton(title: "Volume up", symbol: "speaker.wave.3", actions: [.system(.volumeUp)]),
                        FloatingButton(title: "Dark mode", symbol: "circle.lefthalf.filled", actions: [.system(.toggleDarkMode)]),
                        FloatingButton(title: "Lock", symbol: "lock", actions: [.system(.lockScreen)]),
                    ]
                    let menu = FloatingMenu(name: "Favourites", buttons: buttons, x: 300, y: 200)
                    automation.panels.store.menus = [menu]
                    automation.panels.store.menuBarItems = [MenuBarItem(title: "★", script: "date +'%H:%M'", every: 30)]
                    automation.panels.show(menu)
                    settings.show(tab: .module(.automation))
                }
            case "macros":
                // An example macro, opened in the Macros window.
                guard let automation = modules.module(.automation) as? AutomationModule else { break }
                var ask = MacroStep(kind: .askInput)
                ask.text = "Who is the email for?"
                ask.name = "Name"
                var check = MacroStep(kind: .ifThen)
                check.condition = MacroCondition(left: "%Name%", test: .isEmpty, right: "")
                check.steps = [MacroStep(kind: .stop)]
                ask.color = .blue
                ask.note = "Asked every time, so the greeting is personal."
                var lookUp = MacroStep(kind: .script)
                lookUp.action = MacroAction(kind: .shell, value: "grep -i \"$TB_Name\" ~/contacts.txt | head -1")
                lookUp.name = "Contact"
                lookUp.timeout = 5
                lookUp.onFailure = .stopAndNotify
                lookUp.color = .orange
                var log = MacroStep(kind: .notify)
                log.text = "Replied to %Name%"
                log.disabled = true
                var type = MacroStep(kind: .action)
                type.action = MacroAction(kind: .typeText, value: "Hi %Name%,\n\nThanks for your message.")
                var waitForReply = MacroStep(kind: .pauseUntil)
                waitForReply.condition = MacroCondition(left: "", test: .windowTitleContains, right: "Re:")
                waitForReply.timeout = 30
                var replyWindow = MacroTrigger(kind: .windowChanged)
                replyWindow.text = "Re:"
                var hotKey = MacroTrigger(kind: .hotKey)
                hotKey.keyCode = 14 // E
                hotKey.modifiers = 0x1000 | 0x0800 | 0x0100 // ⌃⌥⌘
                var morning = MacroTrigger(kind: .timeOfDay)
                morning.number = 9 * 60
                morning.weekdays = [2, 3, 4, 5, 6]
                automation.store.groups = [MacroGroup(name: "Email", scope: .only, apps: ["com.apple.mail"])]
                automation.store.macros = [
                    Macro(name: "Reply to email", groupID: automation.store.groups.first?.id, triggers: [hotKey, replyWindow, MacroTrigger(kind: .launcher)], steps: [ask, check, lookUp, waitForReply, type, log]),
                    Macro(name: "Start the work day", triggers: [morning, MacroTrigger(kind: .menuBar)], steps: [
                        MacroStep(kind: .action, action: MacroAction(kind: .openApp, value: "/System/Applications/Calendar.app")),
                        MacroStep(kind: .action, action: .toolbelt(.layout(1))),
                    ]),
                ]
                automation.selectOnOpen = automation.store.macros.first?.id
                automation.open()
            case "settings-gestures":
                // A few example gestures, one opened for editing.
                guard let gestures = modules.module(.gestures) as? GesturesModule else { break }
                gestures.store.rules = [
                    GestureRule(gesture: .touch(.trackpad, .tap, fingers: 3), action: .toolbelt(.openLauncher)),
                    GestureRule(gesture: .modifierTap(.rightCommand, taps: 2), action: .toolbelt(.clipboardHistory)),
                    GestureRule(gesture: .stroke(button: 1, path: "L"), action: .system(.back), scope: .only, apps: ["com.apple.Safari"]),
                    GestureRule(gesture: .mouseButton(3), action: .system(.missionControl)),
                ]
                settings.show(tab: .module(.gestures))
            case "screenshot-editor":
                // The screenshot the screenshot check took, marked up as a person might.
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Screenshot.png")
                guard let screenshots = modules.module(.screenshots) as? ScreenshotsModule,
                      let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { break }
                let editor = screenshots.edit(image)
                let w = CGFloat(image.width), h = CGFloat(image.height)
                editor.model.annotations = [
                    Annotation(tool: .highlight, start: CGPoint(x: w * 0.05, y: h * 0.02), end: CGPoint(x: w * 0.45, y: h * 0.08), color: .yellow),
                    Annotation(tool: .box, start: CGPoint(x: w * 0.55, y: h * 0.25), end: CGPoint(x: w * 0.9, y: h * 0.6)),
                    Annotation(tool: .arrow, start: CGPoint(x: w * 0.3, y: h * 0.75), end: CGPoint(x: w * 0.53, y: h * 0.45)),
                    Annotation(tool: .blur, start: CGPoint(x: w * 0.1, y: h * 0.3), end: CGPoint(x: w * 0.4, y: h * 0.5)),
                    Annotation(tool: .text, start: CGPoint(x: w * 0.12, y: h * 0.8), end: .zero, color: .red, text: "Look here"),
                ]
                editor.model.crop = CGRect(x: w * 0.02, y: h * 0.01, width: w * 0.96, height: h * 0.95)
            case "triggers", "trigger-conditions", "trigger-group", "trigger-keys":
                // The Triggers window with an example set: a group for browsers, a trigger with its own
                // conditions and notes, a keyboard shortcut with an on-screen message.
                guard let gestures = modules.module(.gestures) as? GesturesModule else { break }
                let browsers = ActivationGroup(name: "Browsers", condition: ConditionGroup(mode: .all, items: [
                    .group(ConditionGroup(mode: .any, items: ["Safari", "Chrome", "Firefox"].map { .rule(ConditionRule(field: .appName, op: .contains, value: $0)) })),
                    .group(ConditionGroup(mode: .none, items: ["Private", "Incognito"].map { .rule(ConditionRule(field: .windowTitle, op: .contains, value: $0)) })),
                ]))
                gestures.store.groups = [browsers]
                var corner = GestureRule(gesture: .touch(.trackpad, .tap, fingers: 3), action: .system(.missionControl))
                corner.notes = "Top-left quarter of the window"
                corner.condition = ConditionGroup(mode: .all, items: [
                    .rule(ConditionRule(field: .pointerXInWindow, op: .lessThan, value: "50")),
                    .rule(ConditionRule(field: .pointerYInWindow, op: .greaterOrEqual, value: "50")),
                ])
                var clipboard = GestureRule(gesture: .shortcut(keyCode: 9, modifiers: 6400), action: .toolbelt(.clipboardHistory))
                clipboard.notes = "Clipboard history"
                clipboard.showHUD = true
                clipboard.moreActions = [MacroAction(kind: .showHUD, value: "Clipboard")]
                var hold = GestureRule(gesture: .shortcut(keyCode: 0x7E, modifiers: 6400), action: .system(.volumeUp))
                hold.notes = "Hold for volume up; quick tap shows a message"
                hold.repeatWhileHeld = true
                hold.repeatRate = 12
                hold.distinguishSides = true
                hold.sideFlags = ShortcutMatch.rightCommand
                hold.phaseActions = [.quickRelease: [MacroAction(kind: .showHUD, value: "Quick tap")],
                                     .modifiersReleased: [MacroAction(kind: .showHUD, value: "All keys let go")]]
                var back = GestureRule(gesture: .touch(.trackpad, .swipeLeft, fingers: 3), action: .system(.back))
                back.groupID = browsers.id
                back.notes = "Back in browsers"
                gestures.store.rules = [
                    GestureRule(gesture: .touch(.trackpad, .doubleTap, fingers: 4), action: .system(.brightnessUp)),
                    corner,
                    clipboard,
                    GestureRule(gesture: .touch(.trackpad, .scrollRight, fingers: 3), action: .system(.volumeUp)),
                    back,
                ] + (target == "trigger-keys" ? [hold] : [])
                gestures.open()
                if let state = gestures.triggersWindowController?.state {
                    switch target {
                    case "trigger-group": state.scope = .group(browsers.id); state.editingGroup = browsers.id
                    case "trigger-conditions": state.selected = corner.id; state.editingCondition = true
                    case "trigger-keys": state.category = .shortcuts; state.selected = hold.id
                    default: state.selected = corner.id
                    }
                }
            case "settings-downloads": settings.show(tab: .module(.downloads))
            case "downloads": modules.module(.downloads)?.open()
            case "downloads-100":
                // 100 streamed videos from the test server the screenshot script starts, as if clicked
                // one after another in 100 Chrome tabs; the list shows them all downloading at once.
                guard let downloads = modules.module(.downloads) as? DownloadsModule,
                      let stream = ProcessInfo.processInfo.environment["TOOLBELT_DEMO_STREAM"] else { break }
                downloads.manager.queues[0].maxAtOnce = 0
                for number in 1...100 {
                    let request = DownloadRequest(url: stream, name: "Video \(number) (1080p).mp4", referrer: "https://videos.example/watch/\(number)",
                                                  kind: "hls", quiet: true)
                    downloads.received(request)
                }
                downloads.open()
            case "shelf-demo":
                // A shelf holding one of each kind of item, as if they'd been dropped on it.
                guard let shelfModule = modules.module(.shelf) as? ShelfModule else { break }
                let id = shelfModule.newShelf(at: NSPoint(x: 500, y: 450))
                shelfModule.store.update(id) { $0.name = "Project files" }
                let pb = NSPasteboard(name: NSPasteboard.Name("toolbelt-demo"))
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                let files = ["Meeting notes.txt", "Screenshot.png"].map { desktop.appendingPathComponent($0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                for content in [files.map { $0 as NSURL } as [NSPasteboardWriting], ["Remember to send the invoice" as NSString], [URL(string: "https://www.apple.com/macos/")! as NSURL]] where !content.isEmpty {
                    pb.clearContents()
                    pb.writeObjects(content)
                    shelfModule.store.add(from: pb, to: id)
                }
            case "windows-left-half", "windows-top-right", "windows-center":
                // Opens Settings, then moves it with the window manager, like pressing the shortcut.
                settings.show(tab: .module(.windows))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                    let action: WindowAction = target == "windows-left-half" ? .leftHalf : target == "windows-top-right" ? .topRight : .center
                    let window = AXWindow.focused(in: ProcessInfo.processInfo.processIdentifier)
                    (modules.module(.windows) as? WindowsModule)?.manager.perform(action, on: window)
                }
            case "windows-snap-preview":
                if let screen = Screens.all.first,
                   let frame = WindowLayout.frame(for: .leftHalf, in: screen.area, current: .zero) {
                    (modules.module(.windows) as? WindowsModule)?.snapping.overlayForScreenshot.show(frame)
                }
            case let show where show.hasPrefix("launcher:"):
                (modules.module(.launcher) as? LauncherModule)?.open(query: String(show.dropFirst("launcher:".count)))
            default: break
            }
        }
    }

    /// Opening Toolbelt again while it's running (for example from Applications) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(tab: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for module in modules.modules { module.willTerminate() }
    }

    private func warnAboutTakenShortcuts() {
        let taken = ShortcutAction.allCases.filter { shortcuts.failed.contains($0) }
        guard !taken.isEmpty else { return }

        let list = taken
            .map { "• \(shortcuts.shortcut(for: $0)?.display ?? "") for “\($0.title)”" }
            .joined(separator: "\n")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = taken.count == 1 ? "A shortcut is already in use" : "Some shortcuts are already in use"
        alert.informativeText = """
        Another app (for example Paste, Raycast or Maccy) already uses:
        \(list)

        Choose a different shortcut in Settings, or quit the other app and reopen Toolbelt. \
        You can still use everything from the menu bar icon.
        """
        alert.addButton(withTitle: "Change Shortcut…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.show(tab: .shortcuts)
        }
    }

    // Menu-bar apps have no visible menu, but text fields still need
    // an Edit menu for ⌘C / ⌘V / ⌘A / ⌘Z to work.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
