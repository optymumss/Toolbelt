import AppKit
import SwiftUI

/// Connects the clipboard manager to the app shell.
@MainActor
final class ClipboardModule: ToolbeltModule {
    let id = ModuleID.clipboard
    let openTitle = "Clipboard History"

    let store: ClipboardStore
    let pinboards = PinboardStore()
    let named: NamedClipboardStore
    let pasteStack = PasteStack()
    private let monitor: ClipboardMonitor
    let paster: Paster
    let panel: HistoryPanelController
    private let shortcuts: ShortcutCenter
    private var cleanupTimer: Timer?
    private var readingText = false

    init(shortcuts: ShortcutCenter) {
        self.shortcuts = shortcuts
        store = ClipboardStore()
        named = NamedClipboardStore(imagesFolder: store.imagesFolder)
        monitor = ClipboardMonitor(store: store)
        paster = Paster(store: store, monitor: monitor)
        panel = HistoryPanelController(store: store, pinboards: pinboards)

        let pinboards = self.pinboards
        store.isProtected = { id in MainActor.assumeIsolated { pinboards.allItemIDs.contains(id) } }
        store.onNewImage = { [weak self] _ in self?.readTextInImages() }

        panel.actions = ClipActions(
            paste: { [weak self] item, plain in self?.paster.paste(item, plainText: plain) },
            pasteTransformed: { [weak self] item, transform in
                self?.paster.paste(item, plainText: transform == .removeFormatting, transform: transform)
            },
            pasteStack: { [weak self] items in self?.startPasteStack(items) },
            pasteAll: { [weak self] items in self?.pasteAll(items) },
            saveNamed: { [weak self] item in self?.askToSaveNamed(item) },
            newPinboard: { [weak self] item in self?.askForNewPinboard(adding: item) }
        )

        shortcuts.setHandler(for: .clipboardHistory) { [weak self] in
            self?.panel.toggle()
        }
        shortcuts.setHandler(for: .pasteNextFromStack) { [weak self] in
            self?.pasteNextFromStack()
        }
        // Gestures and macros can paste named clipboards.
        ActionRunner.pasteNamedClipboard = { [weak self] name in
            guard let self, let clip = self.named.clip(named: name) else { return }
            self.paster.paste(clip.item, plainText: false)
        }
    }

    func start() {
        monitor.start()
        cleanUp()
        // Old items are deleted once an hour; the long tolerance keeps it from waking the Mac.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanUp() }
        }
        cleanupTimer?.tolerance = 600
        readTextInImages()
    }

    func stop() {
        monitor.stop()
        panel.hide()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }

    /// Deletes items older than the chosen age (pinned and pinboard items stay).
    func cleanUp() {
        store.deleteOlder(thanDays: Prefs.clipboardAutoDeleteDays)
        // Pinboards forget items that no longer exist.
        let existing = Set(store.items.map(\.id))
        for board in pinboards.pinboards {
            for id in board.itemIDs where !existing.contains(id) { pinboards.forget(id) }
        }
    }

    /// Reads the text in images one at a time, in the background, so they can be searched.
    func readTextInImages() {
        guard Prefs.clipboardReadImageText, !readingText,
              let item = store.items.first(where: { $0.kind == .image && $0.ocrText == nil }),
              let url = store.imageURL(for: item) else { return }
        readingText = true
        Task { @MainActor [weak self] in
            let text = await ImageText.recognize(at: url)
            guard let self else { return }
            self.store.update(item.id) { $0.ocrText = text }
            self.readingText = false
            self.readTextInImages()
        }
    }

    // MARK: Paste stack

    func startPasteStack(_ items: [ClipItem]) {
        pasteStack.load(items)
        pasteNextFromStack()
    }

    /// Pastes the next item of the stack (the "Paste next from stack" shortcut, ⌃⌥V).
    func pasteNextFromStack() {
        guard let item = pasteStack.next() else {
            NSSound.beep()
            return
        }
        paster.paste(item, plainText: false)
    }

    /// Pastes the whole stack at once, one item per line.
    func pasteAll(_ items: [ClipItem]) {
        let text = items.compactMap { $0.kind == .file ? $0.filePaths?.joined(separator: "\n") : $0.text }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        paster.paste(ClipItem(kind: .text, text: text, hash: Hashing.of("text:" + text)), plainText: true)
    }

    // MARK: Pinboards and named clipboards

    private func askForName(title: String, detail: String, button: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    func askForNewPinboard(adding item: ClipItem) {
        guard let name = askForName(title: "New pinboard", detail: "For example “Email replies” or “Addresses”.", button: "Create") else { return }
        let board = pinboards.create(name)
        pinboards.toggle(item.id, on: board.id)
    }

    func askToSaveNamed(_ item: ClipItem) {
        guard let name = askForName(title: "Save as a named clipboard",
                                     detail: "Paste it any time by typing its name in the launcher (⌥Space). Saving under an existing name replaces it.",
                                     button: "Save") else { return }
        named.save(item, as: name)
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
        var items = [pause, clear]
        if !pasteStack.isEmpty {
            let key = shortcuts.shortcut(for: .pasteNextFromStack)?.display ?? ""
            items.append(ActionMenuItem("Paste Next from Stack (\(pasteStack.queued.count) left) \(key)") { [weak self] in
                self?.pasteNextFromStack()
            })
            items.append(ActionMenuItem("Clear Paste Stack") { [weak self] in self?.pasteStack.clear() })
        }
        return items
    }

    func settingsView() -> AnyView {
        AnyView(ClipboardSettingsTab(shortcuts: shortcuts, pinboards: pinboards, named: named,
                                     onClear: { [weak self] in self?.confirmClear() }))
    }

    private(set) lazy var launcherProvider: LauncherProvider? = ClipboardLauncherProvider(store: store, paster: paster, named: named)

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
    private let named: NamedClipboardStore?

    init(store: ClipboardStore, paster: Paster, named: NamedClipboardStore? = nil) {
        self.store = store
        self.paster = paster
        self.named = named
    }

    func results(for query: String) -> [LauncherResult] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        // Named clipboards: paste by name.
        let namedResults: [LauncherResult] = (named?.clips ?? []).compactMap { clip in
            let score = FuzzyMatch.score(query, clip.name)
            guard score > 0 else { return nil }
            return LauncherResult(
                id: "named:" + clip.id.uuidString, title: clip.name, subtitle: "Named clipboard · \(clip.item.title) · ↩ pastes it",
                kind: "Named Clipboard", icon: .symbol("tray.full"), score: score + 3
            ) { [paster] in paster.paste(clip.item, plainText: false) }
        }
        return namedResults + store.items
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
