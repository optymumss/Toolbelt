import AppKit
import Carbon
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
    private var store: ClipboardStore!
    private var monitor: ClipboardMonitor!
    private var paster: Paster!
    private var panel: HistoryPanelController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()

        store = ClipboardStore()
        monitor = ClipboardMonitor(store: store)
        paster = Paster(store: store, monitor: monitor)
        panel = HistoryPanelController(store: store, paster: paster)
        monitor.start()

        let hk = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.panel.toggle()
        }
        hotKey = hk

        setupStatusItem()

        if !hk.isRegistered {
            let alert = NSAlert()
            alert.messageText = "⌘⇧V is already in use"
            alert.informativeText = "Another app (for example Paste, Raycast or Maccy) already uses ⌘⇧V. Quit that app and relaunch Toolbelt, or open your history from the menu bar icon."
            alert.runModal()
        }

        if !Accessibility.isTrusted(prompt: false) {
            _ = Accessibility.isTrusted(prompt: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Toolbelt")

        let menu = NSMenu()

        let show = NSMenuItem(title: "Show Clipboard History", action: #selector(showHistory), keyEquivalent: "v")
        show.keyEquivalentModifierMask = [.command, .shift]
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.state = Prefs.paused ? .on : .off
        menu.addItem(pauseItem)

        let clear = NSMenuItem(title: "Clear History…", action: #selector(confirmClear), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Toolbelt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func showHistory() {
        panel.show()
    }

    @objc private func togglePause() {
        Prefs.paused.toggle()
        pauseItem.state = Prefs.paused ? .on : .off
        statusItem.button?.image = NSImage(
            systemSymbolName: Prefs.paused ? "clipboard" : "doc.on.clipboard",
            accessibilityDescription: "Toolbelt"
        )
    }

    @objc private func confirmClear() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All items except pinned ones will be deleted. This can't be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(onClear: { [weak self] in self?.confirmClear() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Toolbelt Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
