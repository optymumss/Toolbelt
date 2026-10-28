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

        settings = SettingsWindowController(modules: modules, shortcuts: shortcuts)
        statusMenu = StatusMenu(modules: modules, shortcuts: shortcuts) { [weak self] tab in
            self?.settings.show(tab: tab)
        }

        modules.refresh()
        warnAboutTakenShortcuts()
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
