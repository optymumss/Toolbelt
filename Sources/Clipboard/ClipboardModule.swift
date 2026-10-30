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

    private(set) lazy var launcherProvider: LauncherProvider? = ClipboardLauncherProvider(store: store, paster: paster)

    func willTerminate() {
        store.saveNow()
    }

    /// Saves text or files from another app (the Services menu) and pins them.
    @discardableResult
    func pin(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            store.add(ClipItem(kind: .file, filePaths: paths, hash: Hashing.of("file:" + paths.joined(separator: "\n")), sourceAppName: "Services"))
        } else if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.add(ClipItem(kind: ClipboardMonitor.isLink(text) ? .link : .text, text: text, hash: Hashing.of("text:" + text), sourceAppName: "Services"))
        } else {
            return false
        }
        if let first = store.items.first, !first.pinned { store.togglePin(first.id) }
        return true
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

/// Lets the launcher find things in the clipboard history; choosing one pastes it.
@MainActor
final class ClipboardLauncherProvider: LauncherProvider {
    private let store: ClipboardStore
    private let paster: Paster

    init(store: ClipboardStore, paster: Paster) {
        self.store = store
        self.paster = paster
    }

    func results(for query: String) -> [LauncherResult] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return store.items
            .filter { PanelModel.matches($0, query) }
            .prefix(5)
            .enumerated()
            .map { index, item in
                let icon: LauncherIcon
                if item.kind == .image, let image = store.image(for: item) {
                    icon = .image(image)
                } else {
                    icon = .symbol(item.kind.symbol)
                }
                return LauncherResult(
                    id: "clip:" + item.id.uuidString, title: item.title,
                    subtitle: "\(item.sourceAppName ?? item.kind.label) · \(Formatters.ago(item.lastUsed)) · ↩ pastes it",
                    kind: "Clipboard", icon: icon, score: 40 - Double(index)
                ) { [paster] in
                    paster.paste(item, plainText: false)
                }
            }
    }
}
