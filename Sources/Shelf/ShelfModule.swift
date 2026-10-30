import AppKit
import SwiftUI

/// Floating shelves to park files, images, text and links on while you work.
@MainActor
final class ShelfModule: ToolbeltModule {
    let id = ModuleID.shelf
    let openTitle = "New Shelf"

    let store = ShelfStore()
    let dropTargets = DropTargetStore()
    private(set) lazy var dropGrid: DropGridController = {
        let grid = DropGridController(store: dropTargets)
        grid.newShelf = { [weak self] files in self?.shelve(files, onShelfNamed: nil) }
        return grid
    }()
    private var watchers: [FolderWatcher] = []
    /// Only one shelf per drag when dragging to an edge.
    private var openedThisDrag = false
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
        shortcuts.setHandler(for: .dropGrid) { [weak self] in
            self?.dropGrid.toggle()
        }
        for slot in 1...9 {
            shortcuts.setHandler(for: .dropTarget(slot)) { [weak self] in
                self?.runDropTarget(slot: slot)
            }
        }
    }

    func start() {
        for shelf in store.shelves {
            window(for: shelf.id).show()
        }
        startShakeWatching()
        startWatchingFolders()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for window in windows.values { window.hide() }
        for watcher in watchers { watcher.stop() }
        watchers = []
        dropGrid.hide()
    }

    // MARK: Watched folders and screenshots

    func startWatchingFolders() {
        for watcher in watchers { watcher.stop() }
        watchers = []
        if Prefs.shelfCatchScreenshots {
            let watcher = FolderWatcher(folder: ScreenshotFolder.url) { [weak self] files in
                let shots = files.filter { ScreenshotFolder.isScreenshot($0.lastPathComponent) }
                if !shots.isEmpty { self?.shelve(shots, onShelfNamed: "Screenshots") }
            }
            watcher.start()
            watchers.append(watcher)
        }
        for path in Prefs.shelfWatchedFolders {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let watcher = FolderWatcher(folder: folder) { [weak self] files in
                self?.shelve(files, onShelfNamed: folder.lastPathComponent)
            }
            watcher.start()
            watchers.append(watcher)
        }
    }

    /// Puts files on the shelf with this name (made if needed), or a new shelf, and shows it.
    @discardableResult
    func shelve(_ files: [URL], onShelfNamed name: String?) -> UUID {
        let id: UUID
        if let name, let existing = store.shelves.first(where: { $0.name == name }) {
            id = existing.id
        } else {
            id = store.newShelf().id
            if let name { store.update(id) { $0.name = name } }
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("toolbelt-shelve-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(files.map { $0 as NSURL })
        store.add(from: pb, to: id, copyFiles: false)
        pb.releaseGlobally()
        window(for: id).show()
        return id
    }

    // MARK: Drop targets

    func runDropTarget(slot: Int) {
        guard dropTargets.targets.indices.contains(slot - 1) else { return NSSound.beep() }
        let files = DropTargetRunner.finderSelection()
        let target = dropTargets.targets[slot - 1]
        guard !files.isEmpty || target.kind == .app || target.kind == .website else { return NSSound.beep() }
        DropTargetRunner.run(target, files: files) { [weak self] files in self?.shelve(files, onShelfNamed: nil) }
    }

    // MARK: Shelf actions

    func perform(_ action: ShelfAction, on id: UUID) {
        guard let shelf = store.shelf(id) else { return }
        let fileItems = shelf.items.filter { $0.kind == .file || $0.kind == .image }
        let files = fileItems.compactMap(\.url)
        guard !files.isEmpty else { return NSSound.beep() }
        let storage = store.storage(for: id)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        var made: [URL] = []
        switch action {
        case .zip: made = ShelfActions.zip(files, into: storage, name: shelf.name).map { [$0] } ?? []
        case .resizeHalf: made = ShelfActions.resize(files, into: storage, maxSize: nil)
        case .resize1024: made = ShelfActions.resize(files, into: storage, maxSize: 1024)
        case .convertJPEG: made = ShelfActions.convert(files, into: storage, format: "jpeg", fileExtension: "jpg")
        case .convertPNG: made = ShelfActions.convert(files, into: storage, format: "png", fileExtension: "png")
        case .convertHEIC: made = ShelfActions.convert(files, into: storage, format: "heic", fileExtension: "heic")
        case .copyPaths:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            return
        case .renameInBulk:
            renameInBulk(fileItems, on: id)
            return
        }
        guard !made.isEmpty else { return NSSound.beep() }
        let items = made.map { ShelfItem(kind: ShelfAction.isImage($0) ? .image : .file, path: $0.path, isCopy: true) }
        store.update(id) { $0.items.append(contentsOf: items) }
    }

    private func renameInBulk(_ items: [ShelfItem], on id: UUID) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Rename \(items.count) files"
        let linked = items.filter { !$0.isCopy }.count
        alert.informativeText = "They'll be named “Name 1”, “Name 2”… in the order they're on the shelf."
            + (linked > 0 ? " This renames your original files (\(linked) of them), not copies." : "")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = store.shelf(id)?.name ?? "File"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        rename(items, on: id, base: field.stringValue)
    }

    /// Renames the files in place and updates the shelf.
    func rename(_ items: [ShelfItem], on id: UUID, base: String) {
        let urls = items.compactMap(\.url)
        let targets = ShelfActions.bulkNames(for: urls, base: base)
        var renamed: [UUID: String] = [:]
        for (item, (from, to)) in zip(items, zip(urls, targets)) where from != to {
            let destination = FileManager.default.fileExists(atPath: to.path)
                ? ShelfStore.unusedURL(for: to.lastPathComponent, in: to.deletingLastPathComponent()) : to
            if (try? FileManager.default.moveItem(at: from, to: destination)) != nil {
                renamed[item.id] = destination.path
            }
        }
        store.update(id) { shelf in
            for index in shelf.items.indices {
                if let path = renamed[shelf.items[index].id] { shelf.items[index].path = path }
            }
        }
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
        let controller = ShelfWindowController(shelfID: id, store: store, onAction: { [weak self] action, id in
            self?.perform(action, on: id)
        }) { [weak self] id in
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
                guard let self, Prefs.shelfShakeToOpen || Prefs.shelfEdge != .off else { return }
                self.shake.reset()
                self.openedThisDrag = false
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
        guard Prefs.shelfShakeToOpen || Prefs.shelfEdge != .off else { return }
        // Only a real drag-and-drop changes the drag pasteboard; moving a window doesn't.
        // Asking the pasteboard costs a little, so ask at most ten times a second.
        if !isDragAndDrop {
            guard event.timestamp - lastDragCheck > 0.1 else { return }
            lastDragCheck = event.timestamp
            guard NSPasteboard(name: .drag).changeCount != dragChangeCount else { return }
            isDragAndDrop = true
        }
        let point = NSEvent.mouseLocation
        // Dragging to the notch or a chosen screen edge opens a shelf there (once per drag).
        if !openedThisDrag, Prefs.shelfEdge != .off,
           let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
           Prefs.shelfEdge.contains(point, screen: screen.frame) {
            openedThisDrag = true
            let size = ShelfWindowController.size
            let x = min(max(point.x, screen.visibleFrame.minX + size.width / 2), screen.visibleFrame.maxX - size.width / 2)
            let y = min(point.y, screen.visibleFrame.maxY) - size.height / 2 - 10
            newShelf(at: NSPoint(x: x, y: y))
            return
        }
        if Prefs.shelfShakeToOpen, shake.add(x: point.x, time: event.timestamp) {
            newShelf(at: point)
        }
    }

    // MARK: Menu, settings, launcher

    func menuItems() -> [NSMenuItem] {
        [ActionMenuItem("Drop Targets…") { [weak self] in self?.dropGrid.toggle() }] + store.shelves.map { shelf in
            let item = ActionMenuItem("Show “\(shelf.name)” (\(shelf.items.count))") { [weak self] in self?.show(shelf.id) }
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [shelf.color.color]))
            return item
        }
    }

    func settingsView() -> AnyView {
        AnyView(ShelfSettingsTab(shortcuts: shortcuts, targets: dropTargets) { [weak self] in self?.startWatchingFolders() })
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
    @ObservedObject var targets: DropTargetStore
    var onFoldersChanged: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @State private var watched: [String] = Prefs.shelfWatchedFolders

    var body: some View {
        Group {
            Section {
                LabeledContent("New shelf") {
                    Text(shortcuts.shortcut(for: .newShelf)?.display ?? "No shortcut")
                        .font(.system(.body, design: .rounded))
                }
                Toggle("Shake the pointer while dragging to open a shelf", isOn: settings.binding("shelf.shake", default: true))
                Picker("Drag to an edge to open a shelf", selection: settings.binding("shelf.edge", default: ShelfEdge.notch.rawValue)) {
                    ForEach(ShelfEdge.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("When you drop files", selection: settings.binding("shelf.copy", default: false)) {
                    Text("Keep a link to the original").tag(false)
                    Text("Copy them onto the shelf").tag(true)
                }
            } header: {
                Text("Shelves")
            } footer: {
                Text("Open a shelf with the shortcut, the menu bar icon, by shaking the pointer while dragging, or by dragging to the notch or an edge. The Actions menu on a shelf zips, resizes, converts or renames its files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Put new screenshots on a shelf", isOn: Binding(
                    get: { MainActor.assumeIsolated { Prefs.shelfCatchScreenshots } },
                    set: { on in MainActor.assumeIsolated { Prefs.shelfCatchScreenshots = on; onFoldersChanged() } }
                ))
                ForEach(watched, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { watched.removeAll { $0 == path }; save() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Watch a Folder…", action: addFolder)
            } header: {
                Text("Watched folders")
            } footer: {
                Text("New files in a watched folder appear on a shelf named after it. Screenshots are caught from wherever macOS saves them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Show the grid") {
                    Text(shortcuts.shortcut(for: .dropGrid)?.display ?? "No shortcut").font(.system(.body, design: .rounded))
                }
                ForEach(Array(targets.targets.enumerated()), id: \.element.id) { index, target in
                    HStack {
                        Image(systemName: target.symbol).frame(width: 20)
                        TextField("Name", text: Binding(
                            get: { target.name },
                            set: { name in if let i = targets.targets.firstIndex(where: { $0.id == target.id }) { targets.targets[i].name = name } }
                        ))
                        .labelsHidden()
                        .frame(width: 120)
                        Text(target.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if target.kind == .folder {
                            Picker("", selection: Binding(
                                get: { target.copies },
                                set: { copies in if let i = targets.targets.firstIndex(where: { $0.id == target.id }) { targets.targets[i].copies = copies } }
                            )) {
                                Text("Copy").tag(true)
                                Text("Move").tag(false)
                            }
                            .labelsHidden()
                            .frame(width: 80)
                        }
                        if index < 9 {
                            Text(shortcuts.shortcut(for: .dropTarget(index + 1))?.display ?? "—")
                                .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                        }
                        Button { targets.targets.removeAll { $0.id == target.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…") { addTarget(.folder) }
                    Button("Add App…") { addTarget(.app) }
                    Button("Add Website…") { addWebsite() }
                    Menu("Add Action") {
                        Button("Zip onto the Desktop") { targets.targets.append(DropTarget(kind: .zipToDesktop, name: "Zip")) }
                        Button("Copy Paths") { targets.targets.append(DropTarget(kind: .copyPaths, name: "Copy Paths")) }
                        Button("Put on a Shelf") { targets.targets.append(DropTarget(kind: .newShelf, name: "Shelf")) }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Drop targets")
            } footer: {
                Text("A grid of targets to drop files on: move or copy to a folder, open with an app, or run an action. Clicking an app or website opens it. Give a target a shortcut in the Shortcuts tab (“Drop target 1–9”) to use it on the files selected in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        Prefs.shelfWatchedFolders = watched
        onFoldersChanged()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, !watched.contains(url.path) else { return }
        watched.append(url.path)
        save()
    }

    private func addTarget(_ kind: DropTarget.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind == .app
        panel.allowedContentTypes = kind == .app ? [.application] : []
        panel.directoryURL = kind == .app ? URL(fileURLWithPath: "/Applications") : nil
        panel.prompt = "Add"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        targets.targets.append(DropTarget(kind: kind, name: name, target: url.path))
    }

    private func addWebsite() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Add a website"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue), url.host != nil else { return }
        targets.targets.append(DropTarget(kind: .website, name: url.host ?? "Website", target: url.absoluteString))
    }
}
