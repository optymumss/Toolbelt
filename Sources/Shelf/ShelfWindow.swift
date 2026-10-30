import AppKit
import Combine
import SwiftUI

/// The small floating window for one shelf.
@MainActor
final class ShelfWindowController: NSObject, NSWindowDelegate {
    let shelfID: UUID
    private let store: ShelfStore
    let panel: KeyPanel
    private let preview = ShelfPreviewController()

    static let size = NSSize(width: 260, height: 330)

    init(shelfID: UUID, store: ShelfStore, onAction: @escaping (ShelfAction, UUID) -> Void = { _, _ in }, onClose: @escaping (UUID) -> Void) {
        self.shelfID = shelfID
        self.store = store
        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let view = ShelfView(store: store, shelfID: shelfID,
                             onPreview: { [weak self] item in self?.preview.toggle(item, near: self?.panel) },
                             onAction: { action in onAction(action, shelfID) },
                             onClose: { onClose(shelfID) })
        let drop = ShelfDropView(store: store, shelfID: shelfID)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = drop.bounds
        hosting.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)
        panel.contentView = drop
    }

    /// Shows the shelf where it was last time, or near the pointer for a new one.
    func show(at point: NSPoint? = nil) {
        if let shelf = store.shelf(shelfID), let x = shelf.originX, let y = shelf.originY, point == nil {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            let p = point ?? NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: p.x - Self.size.width / 2, y: p.y - Self.size.height / 2))
        }
        if let screen = panel.screen ?? NSScreen.main {
            // Keep it fully on screen.
            var frame = panel.frame
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - frame.height))
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        rememberPosition()
    }

    func hide() {
        preview.hide()
        panel.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        rememberPosition()
    }

    private func rememberPosition() {
        let origin = panel.frame.origin
        store.update(shelfID) { $0.originX = origin.x; $0.originY = origin.y }
    }
}

/// Accepts anything dropped onto the shelf: files, folders, images, text and links.
final class ShelfDropView: NSView {
    private let store: ShelfStore
    private let shelfID: UUID

    init(store: ShelfStore, shelfID: UUID) {
        self.store = store
        self.shelfID = shelfID
        super.init(frame: NSRect(origin: .zero, size: ShelfWindowController.size))
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Dragging an item out of this same shelf onto itself does nothing.
        sender.draggingSource is ShelfDragSourceView ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        return MainActor.assumeIsolated {
            store.add(from: pasteboard, to: shelfID) > 0
        }
    }
}

/// Drags items out of the shelf (one item, or all of them at once).
final class ShelfDragSourceView: NSView, NSDraggingSource {
    var items: () -> [ShelfItem] = { [] }
    var image: NSImage?
    private var mouseDownEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 3 else { return }
        mouseDownEvent = nil

        let dragging = items().compactMap { item -> NSDraggingItem? in
            guard let writer = item.dragWriter else { return nil }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let icon = item.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: item.kind == .link ? "link" : "text.alignleft", accessibilityDescription: nil)
                ?? NSImage()
            draggingItem.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: icon)
            return draggingItem
        }
        guard !dragging.isEmpty else { return }
        beginDraggingSession(with: dragging, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The SwiftUI content inside is only a picture: clicks and drags belong to this view,
    // and dragging here drags the items rather than moving the shelf window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Wraps a SwiftUI view so it can be dragged out with the shelf's own drag code.
struct DragOut<Content: View>: NSViewRepresentable {
    let items: () -> [ShelfItem]
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.items = items
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        view.items = items
        (view.subviews.first as? NSHostingView<Content>)?.rootView = content()
    }
}

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    let shelfID: UUID
    var onPreview: (ShelfItem) -> Void
    var onAction: (ShelfAction) -> Void = { _ in }
    var onClose: () -> Void

    private var shelf: Shelf? { store.shelf(shelfID) }

    var body: some View {
        let shelf = self.shelf ?? Shelf(name: "")
        VStack(spacing: 0) {
            header(shelf)
            Divider()
            if shelf.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("Drop files, images,\ntext or links here")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(shelf.items) { item in
                            row(item)
                        }
                    }
                    .padding(6)
                }
                Divider()
                Menu {
                    ForEach(ShelfAction.allCases) { action in
                        Button(action.title) { onAction(action) }
                    }
                } label: {
                    Label("Actions", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .help("Zip, resize, convert, rename or copy the paths of the files on this shelf")
                Divider()
                DragOut(items: { store.shelf(shelfID)?.items ?? [] }) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                        Text("Drag all \(shelf.items.count) out")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .frame(height: 34)
                .help("Drag from here to move every item at once")
            }
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: shelf.color.color).opacity(0.6), lineWidth: 2)
        )
    }

    private func header(_ shelf: Shelf) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ShelfColor.allCases) { color in
                    Button(color.title) { store.update(shelfID) { $0.color = color } }
                }
            } label: {
                Circle().fill(Color(nsColor: shelf.color.color)).frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Colour tag")

            TextField("Shelf name", text: Binding(
                get: { store.shelf(shelfID)?.name ?? "" },
                set: { name in store.update(shelfID) { $0.name = name } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close this shelf (your original files stay where they are)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func row(_ item: ShelfItem) -> some View {
        HStack(spacing: 8) {
            DragOut(items: { [item] }) {
                HStack(spacing: 8) {
                    icon(for: item).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Text(subtitle(for: item)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .frame(height: 34)
            Button { onPreview(item) } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless)
                .help("Quick Look")
            Button { store.removeItem(item.id, from: shelfID) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove from shelf")
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func icon(for item: ShelfItem) -> some View {
        switch item.kind {
        case .image:
            if let url = item.url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
            }
        case .file:
            if let url = item.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        case .link:
            Image(systemName: "link").font(.system(size: 15))
        case .text:
            Image(systemName: "text.alignleft").font(.system(size: 15))
        }
    }

    private func subtitle(for item: ShelfItem) -> String {
        switch item.kind {
        case .file: return item.isCopy ? "Copy on this shelf" : (item.url?.deletingLastPathComponent().path ?? "")
        case .image: return "Image"
        case .link: return URL(string: item.text ?? "")?.host ?? "Link"
        case .text: return "\(item.text?.count ?? 0) characters"
        }
    }
}

/// A Quick Look window for one shelf item.
@MainActor
final class ShelfPreviewController {
    private var panel: NSPanel?
    private var itemID: UUID?

    func toggle(_ item: ShelfItem, near window: NSWindow?) {
        if itemID == item.id, panel?.isVisible == true {
            hide()
            return
        }
        itemID = item.id
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ShelfItemPreview(item: item))
        if let window {
            let frame = window.frame
            let size = NSSize(width: 520, height: 420)
            var origin = NSPoint(x: frame.maxX + 12, y: frame.maxY - size.height)
            if let screen = window.screen, origin.x + size.width > screen.visibleFrame.maxX {
                origin.x = frame.minX - size.width - 12
            }
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        itemID = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable],
                            backing: .buffered, defer: true)
        panel.title = "Quick Look"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        return panel
    }
}

struct ShelfItemPreview: View {
    let item: ShelfItem

    var body: some View {
        switch item.kind {
        case .file, .image:
            if let url = item.url {
                QuickLookView(url: url)
            }
        case .link, .text:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }
}
