import AppKit
import Combine

/// The Toolbelt icon in the menu bar and its menu.
/// The menu is rebuilt each time it opens, so it always matches the current settings.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let modules: ModuleManager
    private let shortcuts: ShortcutCenter
    private let openSettings: (SettingsTab?) -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var pausedWatcher: AnyCancellable?

    init(modules: ModuleManager, shortcuts: ShortcutCenter, openSettings: @escaping (SettingsTab?) -> Void) {
        self.modules = modules
        self.shortcuts = shortcuts
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Toolbelt")
        menu.delegate = self
        statusItem.menu = menu

        // Pausing can also happen from Settings, so follow the setting itself.
        pausedWatcher = modules.$appPaused.sink { [weak self] paused in
            self?.statusItem.button?.appearsDisabled = paused
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for module in modules.modules where modules.isEnabled(module.id) {
            let running = modules.isRunning(module.id)

            let open = ActionMenuItem(module.openTitle) { module.open() }
            open.image = NSImage(systemSymbolName: module.id.symbol, accessibilityDescription: nil)
            open.isEnabled = running
            if let action = ShortcutAction.allCases.first(where: { $0.module == module.id }),
               let key = shortcuts.shortcut(for: action)?.menuKeyEquivalent {
                open.keyEquivalent = key.key
                open.keyEquivalentModifierMask = key.modifiers
            }
            menu.addItem(open)

            for item in module.menuItems() {
                item.indentationLevel = 1
                if !running { item.isEnabled = false }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let pause = ActionMenuItem("Pause Toolbelt") { [weak self] in
            guard let self else { return }
            self.modules.setPaused(!self.modules.appPaused)
        }
        pause.state = modules.appPaused ? .on : .off
        menu.addItem(pause)

        let settings = ActionMenuItem("Settings…", keyEquivalent: ",") { [weak self] in
            self?.openSettings(nil)
        }
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Toolbelt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Opens the menu as if the icon was clicked.
    func open() {
        statusItem.button?.performClick(nil)
    }
}
