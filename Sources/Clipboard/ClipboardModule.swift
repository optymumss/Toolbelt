import AppKit
import SwiftUI

/// Connects the clipboard manager to the app shell.
@MainActor
final class ClipboardModule: ToolbeltModule {
    let id = ModuleID.clipboard
    let openTitle = "Clipboard History"

    let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let paster: Paster
    private let panel: HistoryPanelController
    private let shortcuts: ShortcutCenter

    init(shortcuts: ShortcutCenter) {
        self.shortcuts = shortcuts
        store = ClipboardStore()
        monitor = ClipboardMonitor(store: store)
        paster = Paster(store: store, monitor: monitor)
        panel = HistoryPanelController(store: store, paster: paster)

        shortcuts.setHandler(for: .clipboardHistory) { [weak self] in
            self?.panel.toggle()
        }
    }

    func start() {
        monitor.start()
    }

    func stop() {
        monitor.stop()
        panel.hide()
    }

    func open() {
        panel.show()
    }

    /// Opens the history with the large preview of the newest item (for screenshots).
    func openWithPreview() {
        panel.show()
        panel.togglePreview()
    }

    func menuItems() -> [NSMenuItem] {
        let pause = ActionMenuItem("Pause Recording") {
            Prefs.clipboardPaused.toggle()
        }
        pause.state = Prefs.clipboardPaused ? .on : .off

        let clear = ActionMenuItem("Clear History…") { [weak self] in
            self?.confirmClear()
        }
        return [pause, clear]
    }

    func settingsView() -> AnyView {
        AnyView(ClipboardSettingsTab(shortcuts: shortcuts, onClear: { [weak self] in self?.confirmClear() }))
    }

    func willTerminate() {
        store.saveNow()
    }

    func confirmClear() {
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
}
