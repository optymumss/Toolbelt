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

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        Prefs.appearance.apply()

        shortcuts = ShortcutCenter()
        modules = ModuleManager(shortcuts: shortcuts)
        modules.register(ClipboardModule(shortcuts: shortcuts))
        modules.register(LauncherModule(shortcuts: shortcuts, modules: modules) { [weak self] in
            self?.settings.show(tab: nil)
        })

        settings = SettingsWindowController(modules: modules, shortcuts: shortcuts)
        statusMenu = StatusMenu(modules: modules, shortcuts: shortcuts) { [weak self] tab in
            self?.settings.show(tab: tab)
        }

        modules.refresh()
        warnAboutTakenShortcuts()
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
            case "menu": statusMenu.open()
            case "settings-launcher": settings.show(tab: .module(.launcher))
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
            .map { "• \(shortcuts.shortcut(for: $0)?.display ?? "") to \($0.title.lowercased())" }
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
