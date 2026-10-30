import AppKit
import Combine
import SwiftUI

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case pinned = "Pinned"
    case text = "Text"
    case links = "Links"
    case images = "Images"
    case files = "Files"

    var id: String { rawValue }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return item.pinned
        case .text: return item.kind == .text
        case .links: return item.kind == .link
        case .images: return item.kind == .image
        case .files: return item.kind == .file
        }
    }
}

/// How the clipboard panel lays out items.
enum ClipboardLayout: String, CaseIterable, Identifiable {
    case list, grid, strip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List with preview"
        case .grid: return "Grid"
        case .strip: return "Strip along the bottom"
        }
    }

    /// Items per row in the grid (↑↓ move by a whole row).
    static let gridColumns = 4
}

/// What the history panel is showing: search text, filter and selection.
@MainActor
final class PanelModel: ObservableObject {
    let store: ClipboardStore
    var pinboards: PinboardStore?

    @Published var query = "" { didSet { selectFirst() } }
    @Published var filter: ClipFilter = .all { didSet { if filter != oldValue { pinboardFilter = nil }; selectFirst() } }
    /// When set, only this pinboard's items are shown.
    @Published var pinboardFilter: UUID? { didSet { selectFirst() } }
    @Published var selectedID: UUID?
    @Published var focusToken = 0
    @Published var layout: ClipboardLayout = .list
    /// Items picked for the paste stack, in the order they'll be pasted.
    @Published var stack: [UUID] = []
    /// The item being edited before pasting, and the edited text.
    @Published var editingID: UUID?
    @Published var draft = ""

    init(store: ClipboardStore, pinboards: PinboardStore? = nil) {
        self.store = store
        self.pinboards = pinboards
    }

    var results: [ClipItem] {
        if let boardID = pinboardFilter, let board = pinboards?.pinboards.first(where: { $0.id == boardID }) {
            let byID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
            return board.itemIDs.compactMap { byID[$0] }.filter { Self.matches($0, query) }
        }
        return store.items.filter { filter.matches($0) && Self.matches($0, query) }
    }

    // MARK: Paste stack

    func toggleStack(_ item: ClipItem) {
        if let index = stack.firstIndex(of: item.id) {
            stack.remove(at: index)
        } else {
            stack.append(item.id)
        }
    }

    /// 1-based position in the paste stack, if the item is in it.
    func stackPosition(of item: ClipItem) -> Int? {
        stack.firstIndex(of: item.id).map { $0 + 1 }
    }

    var stackedItems: [ClipItem] {
        let byID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        return stack.compactMap { byID[$0] }
    }

    // MARK: Editing

    func beginEditing(_ item: ClipItem) {
        guard item.kind == .text || item.kind == .link else { return }
        editingID = item.id
        draft = item.text ?? ""
    }

    func cancelEditing() {
        editingID = nil
    }

    /// Saves the edited text into the history item (its old formatting is dropped). Returns the updated item.
    @discardableResult
    func saveEditing() -> ClipItem? {
        guard let id = editingID else { return nil }
        let text = draft
        store.update(id) { item in
            item.text = text
            item.rtf = nil
            item.kind = ClipboardMonitor.isLink(text) ? .link : .text
            item.hash = Hashing.of("text:" + text)
        }
        editingID = nil
        return store.items.first { $0.id == id }
    }

    /// Every word typed must appear somewhere in the item, in any order and any case,
    /// so "apple macos" finds a link titled "macOS - Apple".
    static func matches(_ item: ClipItem, _ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = item.searchText
        return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }

    var selectedItem: ClipItem? {
        let r = results
        if let id = selectedID, let item = r.first(where: { $0.id == id }) { return item }
        return r.first
    }

    func selectFirst() {
        selectedID = results.first?.id
    }

    func move(_ delta: Int) {
        let r = results
        guard !r.isEmpty else { return }
        let current = r.firstIndex(where: { $0.id == selectedItem?.id }) ?? 0
        let next = max(0, min(r.count - 1, current + delta))
        selectedID = r[next].id
    }

    func item(at index: Int) -> ClipItem? {
        let r = results
        return r.indices.contains(index) ? r[index] : nil
    }

    func cycleFilter(_ delta: Int) {
        let all = ClipFilter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + delta + all.count) % all.count]
    }

    func togglePin(_ item: ClipItem) {
        store.togglePin(item.id)
        selectedID = item.id
    }

    func delete(_ item: ClipItem) {
        let before = results
        let index = before.firstIndex(where: { $0.id == item.id }) ?? 0
        store.delete(item.id)
        let after = results
        selectedID = after.indices.contains(index) ? after[index].id : after.last?.id
    }
}

/// A panel that can take keyboard input without activating Toolbelt,
/// so the app you were typing in stays frontmost (like Spotlight).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// What the panel can ask the clipboard module to do, besides plain pasting.
struct ClipActions {
    var paste: (ClipItem, Bool) -> Void
    var pasteTransformed: (ClipItem, TextTransform) -> Void
    var pasteStack: ([ClipItem]) -> Void
    var pasteAll: ([ClipItem]) -> Void
    var saveNamed: (ClipItem) -> Void
    var newPinboard: (ClipItem) -> Void
}

@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    let model: PanelModel
    private let preview: LargePreviewController
    private var keyMonitor: Any?
    private var selectionWatcher: AnyCancellable?
    /// When Space opened the preview, so holding Space can close it on release.
    private var spacePressedAt: TimeInterval?
    var actions: ClipActions!

    init(store: ClipboardStore, pinboards: PinboardStore? = nil) {
        model = PanelModel(store: store, pinboards: pinboards)
        preview = LargePreviewController(store: store)
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        let root = HistoryView(
            model: model,
            store: store,
            pinboards: pinboards ?? PinboardStore(),
            actions: { [weak self] in self?.wrappedActions }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // The large preview follows the selection (keys or mouse).
        selectionWatcher = model.$selectedID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.preview.update(self.model.selectedItem, over: self.panel)
            }
    }

    /// The module's actions, each closing the panel first.
    private var wrappedActions: ClipActions? {
        guard let actions else { return nil }
        return ClipActions(
            paste: { [weak self] item, plain in self?.hide(); actions.paste(item, plain) },
            pasteTransformed: { [weak self] item, transform in self?.hide(); actions.pasteTransformed(item, transform) },
            pasteStack: { [weak self] items in self?.hide(); actions.pasteStack(items) },
            pasteAll: { [weak self] items in self?.hide(); actions.pasteAll(items) },
            saveNamed: { [weak self] item in self?.hide(); actions.saveNamed(item) },
            newPinboard: { [weak self] item in self?.hide(); actions.newPinboard(item) }
        )
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// Panel size and place for the chosen layout.
    static func frame(for layout: ClipboardLayout, on screen: NSRect) -> NSRect {
        switch layout {
        case .list:
            let size = NSSize(width: 780, height: 500)
            return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.08,
                          width: size.width, height: size.height)
        case .grid:
            let size = NSSize(width: 900, height: 580)
            return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.05,
                          width: size.width, height: size.height)
        case .strip:
            return NSRect(x: screen.minX + 20, y: screen.minY + 20, width: screen.width - 40, height: 330)
        }
    }

    func show() {
        model.query = ""
        model.filter = .all
        model.pinboardFilter = nil
        model.editingID = nil
        model.layout = Prefs.clipboardLayout
        model.selectFirst()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(Self.frame(for: model.layout, on: visible), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        model.focusToken += 1
        installKeyMonitor()
    }

    func hide() {
        preview.hide()
        spacePressedAt = nil
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Alerts (naming a pinboard, say) take focus on purpose; everything else closes the panel.
        if model.editingID == nil { hide() }
    }

    // MARK: Large preview

    func togglePreview() {
        if preview.isVisible {
            preview.hide()
        } else if let item = model.selectedItem {
            preview.show(item, over: panel)
        }
    }

    var isPreviewVisible: Bool { preview.isVisible }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return event.type == .keyUp ? self.handleKeyUp(event) : self.handle(event)
            }
            return handled ? nil : event
        }
    }

    /// Releasing Space after holding it closes the preview it opened.
    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard event.window === panel, event.keyCode == 49, let pressedAt = spacePressedAt else { return false }
        spacePressedAt = nil
        if SpaceKey.isHold(pressedAt: pressedAt, releasedAt: event.timestamp) {
            preview.hide()
        }
        return true
    }

    /// Key codes for 1–9 on the top row.
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === panel, let actions = wrappedActions else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // While editing, keys go to the text, except these.
        if model.editingID != nil {
            switch event.keyCode {
            case 53: // esc
                model.cancelEditing()
                return true
            case 36 where flags.contains(.command): // ⌘↩ pastes the edited text
                if let item = model.saveEditing() { actions.paste(item, false) }
                return true
            case 1 where flags.contains(.command): // ⌘S saves it
                model.saveEditing()
                return true
            default:
                return false
            }
        }

        switch event.keyCode {
        case 53: // esc
            if preview.isVisible {
                preview.hide()
            } else if model.query.isEmpty {
                hide()
            } else {
                model.query = ""
            }
            return true
        case 49 where flags.isDisjoint(with: [.command, .option, .control]): // space
            // While searching, Space types a space; otherwise it opens the preview.
            guard model.query.isEmpty || preview.isVisible else { return false }
            if !event.isARepeat {
                let wasVisible = preview.isVisible
                togglePreview()
                spacePressedAt = (!wasVisible && preview.isVisible) ? event.timestamp : nil
            }
            return true
        case 125: // down
            model.move(model.layout == .grid ? ClipboardLayout.gridColumns : 1)
            return true
        case 126: // up
            model.move(model.layout == .grid ? -ClipboardLayout.gridColumns : -1)
            return true
        case 123 where model.layout != .list: // left (grid and strip)
            model.move(-1)
            return true
        case 124 where model.layout != .list: // right
            model.move(1)
            return true
        case 36, 76: // return, enter
            if flags.contains(.command), !model.stack.isEmpty {
                // ⌘↩ starts the paste stack; ⌥⌘↩ pastes the whole stack at once.
                let items = model.stackedItems
                model.stack = []
                flags.contains(.option) ? actions.pasteAll(items) : actions.pasteStack(items)
            } else if let item = model.selectedItem {
                actions.paste(item, flags.contains(.option))
            }
            return true
        case 48: // tab
            model.cycleFilter(flags.contains(.shift) ? -1 : 1)
            return true
        default:
            break
        }

        guard flags.contains(.command) else { return false }

        switch event.keyCode {
        case 16: // ⌘Y, the Quick Look shortcut
            togglePreview()
            return true
        case 35: // ⌘P
            if let item = model.selectedItem { model.togglePin(item) }
            return true
        case 51: // ⌘⌫
            if let item = model.selectedItem { model.delete(item) }
            return true
        case 14: // ⌘E edits the text before pasting
            if let item = model.selectedItem { model.beginEditing(item) }
            return true
        case 40: // ⌘K adds to (or removes from) the paste stack
            if let item = model.selectedItem { model.toggleStack(item) }
            return true
        default:
            break
        }
        if let n = Self.digitKeys.firstIndex(of: event.keyCode) { // ⌘1–9
            if let item = model.item(at: n) { actions.paste(item, flags.contains(.option)) }
            return true
        }
        return false
    }
}
