import AppKit
import SwiftUI

/// Floating shelves to park files, images, text and links on while you work.
@MainActor
final class ShelfModule: ToolbeltModule {
    let id = ModuleID.shelf
    let openTitle = "New Shelf"

    let store = ShelfStore()
    private var windows: [UUID: ShelfWindowController] = [:]
    private var monitors: [Any] = []
    private var shake = ShakeDetector()
    private var dragChangeCount = 0
    /// Whether the current drag is a real drag-and-drop (decided once per drag).
    private var isDragAndDrop = false
    private var lastDragCheck: TimeInterval = 0
    private let shortcuts: ShortcutCenter

    init(shortcuts: ShortcutCenter) {
        self.shortcuts = shortcuts
        shortcuts.setHandler(for: .newShelf) { [weak self] in
            self?.newShelf()
        }
    }

    func start() {
        for shelf in store.shelves {
            window(for: shelf.id).show()
        }
        startShakeWatching()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for window in windows.values { window.hide() }
    }

    func open() {
        newShelf()
    }

    @discardableResult
    func newShelf(at point: NSPoint? = nil) -> UUID {
        let shelf = store.newShelf()
        window(for: shelf.id).show(at: point ?? NSEvent.mouseLocation)
        return shelf.id
    }

    func close(_ id: UUID) {
        windows[id]?.hide()
        windows[id] = nil
        store.remove(id)
    }

    func show(_ id: UUID) {
        window(for: id).show()
    }

    private func window(for id: UUID) -> ShelfWindowController {
        if let existing = windows[id] { return existing }
        let controller = ShelfWindowController(shelfID: id, store: store) { [weak self] id in
            self?.close(id)
        }
        windows[id] = controller
        return controller
    }

    // MARK: Shake to open

    /// While you drag something (a file, text…), shaking the pointer opens a shelf under it.
    private func startShakeWatching() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Prefs.shelfShakeToOpen else { return }
                self.shake.reset()
                self.isDragAndDrop = false
                self.dragChangeCount = NSPasteboard(name: .drag).changeCount
            }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDragged(event) }
        }
        monitors = [down, dragged].compactMap { $0 }
    }

    private func mouseDragged(_ event: NSEvent) {
        guard Prefs.shelfShakeToOpen else { return }
        // Only a real drag-and-drop changes the drag pasteboard; moving a window doesn't.
        // Asking the pasteboard costs a little, so ask at most ten times a second.
        if !isDragAndDrop {
            guard event.timestamp - lastDragCheck > 0.1 else { return }
            lastDragCheck = event.timestamp
            guard NSPasteboard(name: .drag).changeCount != dragChangeCount else { return }
            isDragAndDrop = true
        }
        if shake.add(x: NSEvent.mouseLocation.x, time: event.timestamp) {
            newShelf(at: NSEvent.mouseLocation)
        }
    }

    // MARK: Menu, settings, launcher

    func menuItems() -> [NSMenuItem] {
        store.shelves.map { shelf in
            let item = ActionMenuItem("Show “\(shelf.name)” (\(shelf.items.count))") { [weak self] in self?.show(shelf.id) }
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [shelf.color.color]))
            return item
        }
    }

    func settingsView() -> AnyView {
        AnyView(ShelfSettingsTab(shortcuts: shortcuts))
    }

    func willTerminate() {}

    private(set) lazy var launcherProvider: LauncherProvider? = ShelfLauncherProvider(module: self)
}

/// Find shelves by name, or by what's on them.
@MainActor
final class ShelfLauncherProvider: LauncherProvider {
    private weak var module: ShelfModule?

    init(module: ShelfModule) {
        self.module = module
    }

    func results(for query: String) -> [LauncherResult] {
        guard let module, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        var results: [LauncherResult] = []
        for shelf in module.store.shelves {
            let byName = FuzzyMatch.score(query, shelf.name)
            let byItem = shelf.items.map { FuzzyMatch.score(query, $0.title) * 0.8 }.max() ?? 0
            let score = max(byName, byItem, FuzzyMatch.score(query, "shelf") * 0.6)
            guard score > 0 else { continue }
            let id = shelf.id
            results.append(LauncherResult(
                id: "shelf:" + id.uuidString, title: shelf.name,
                subtitle: shelf.items.isEmpty ? "Empty shelf" : shelf.items.prefix(3).map(\.title).joined(separator: ", "),
                kind: "Shelf", icon: .symbol("tray.full"), score: score
            ) { [weak module] in module?.show(id) })
        }
        if FuzzyMatch.score(query, "new shelf") > 0 {
            results.append(LauncherResult(id: "shelf:new", title: "New Shelf", kind: "Shelf", icon: .symbol("tray.and.arrow.down"),
                                          score: FuzzyMatch.score(query, "new shelf")) { [weak module] in module?.newShelf() })
        }
        return results
    }
}

struct ShelfSettingsTab: View {
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Group {
            Section {
                LabeledContent("New shelf") {
                    Text(shortcuts.shortcut(for: .newShelf)?.display ?? "No shortcut")
                        .font(.system(.body, design: .rounded))
                }
                Toggle("Shake the pointer while dragging to open a shelf", isOn: settings.binding("shelf.shake", default: true))
                Picker("When you drop files", selection: settings.binding("shelf.copy", default: false)) {
                    Text("Keep a link to the original").tag(false)
                    Text("Copy them onto the shelf").tag(true)
                }
            } header: {
                Text("Shelves")
            } footer: {
                Text("Open a shelf with the shortcut, the menu bar icon, or by shaking the pointer while dragging. Drop anything on it, then drag it all out somewhere else later. Linked files stay where they are; copies live in Toolbelt's data folder until you remove them or close the shelf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
