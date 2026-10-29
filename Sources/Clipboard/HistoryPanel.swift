import AppKit
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

/// What the history panel is showing: search text, filter and selection.
@MainActor
final class PanelModel: ObservableObject {
    let store: ClipboardStore

    @Published var query = "" { didSet { selectFirst() } }
    @Published var filter: ClipFilter = .all { didSet { selectFirst() } }
    @Published var selectedID: UUID?
    @Published var focusToken = 0

    init(store: ClipboardStore) {
        self.store = store
    }

    var results: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.items.filter { item in
            filter.matches(item) && (q.isEmpty || item.searchText.localizedCaseInsensitiveContains(q))
        }
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

@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    private let model: PanelModel
    private let paster: Paster
    private var keyMonitor: Any?

    private let size = NSSize(width: 780, height: 500)

    init(store: ClipboardStore, paster: Paster) {
        self.paster = paster
        model = PanelModel(store: store)
        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
            onPaste: { [weak self] item, plain in self?.paste(item, plain: plain) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        model.query = ""
        model.filter = .all
        model.selectFirst()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 + frame.height * 0.08
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        model.focusToken += 1
        installKeyMonitor()
    }

    func hide() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func paste(_ item: ClipItem, plain: Bool) {
        hide()
        paster.paste(item, plainText: plain)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Key codes for 1–9 on the top row.
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53: // esc
            if model.query.isEmpty { hide() } else { model.query = "" }
            return true
        case 125: // down
            model.move(1)
            return true
        case 126: // up
            model.move(-1)
            return true
        case 36, 76: // return, enter
            if let item = model.selectedItem { paste(item, plain: flags.contains(.option)) }
            return true
        case 48: // tab
            model.cycleFilter(flags.contains(.shift) ? -1 : 1)
            return true
        default:
            break
        }

        guard flags.contains(.command) else { return false }

        if event.keyCode == 35 { // ⌘P
            if let item = model.selectedItem { model.togglePin(item) }
            return true
        }
        if event.keyCode == 51 { // ⌘⌫
            if let item = model.selectedItem { model.delete(item) }
            return true
        }
        if let n = Self.digitKeys.firstIndex(of: event.keyCode) { // ⌘1–9
            if let item = model.item(at: n) { paste(item, plain: flags.contains(.option)) }
            return true
        }
        return false
    }
}
