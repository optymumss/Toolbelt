import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: ClipboardStore
    @ObservedObject var pinboards: PinboardStore
    var actions: () -> ClipActions?

    @FocusState private var searchFocused: Bool

    private func onPaste(_ item: ClipItem, _ plain: Bool) {
        actions()?.paste(item, plain)
    }

    var body: some View {
        let results = model.results
        let selected = model.selectedItem

        VStack(spacing: 0) {
            header(count: results.count)
            Divider()
            switch model.layout {
            case .list:
                HStack(spacing: 0) {
                    list(results, selectedID: selected?.id)
                        .frame(width: 340)
                    Divider()
                    preview(selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .grid:
                cards(results, selectedID: selected?.id, horizontal: false)
            case .strip:
                cards(results, selectedID: selected?.id, horizontal: true)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if model.editingID != nil { editor } }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = true }
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searchFocused)
            }
            HStack(spacing: 6) {
                ForEach(ClipFilter.allCases) { filter in
                    Button(filter.rawValue) { model.filter = filter; model.pinboardFilter = nil }
                        .buttonStyle(ChipStyle(selected: model.filter == filter && model.pinboardFilter == nil))
                }
                if !pinboards.pinboards.isEmpty {
                    Divider().frame(height: 16)
                    ForEach(pinboards.pinboards) { board in
                        Button(board.name) { model.pinboardFilter = board.id }
                            .buttonStyle(ChipStyle(selected: model.pinboardFilter == board.id))
                    }
                }
                Spacer()
                Text(count == 1 ? "1 item" : "\(count) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: List

    @ViewBuilder
    private func list(_ results: [ClipItem], selectedID: UUID?) -> some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(store.items.isEmpty ? "Nothing copied yet" : "No matches")
                    .foregroundStyle(.secondary)
                if store.items.isEmpty {
                    Text("Copy something in any app and it will appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item, index: index, selected: item.id == selectedID, store: store,
                                    stackPosition: model.stackPosition(of: item))
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onPaste(item, false) }
                                .onTapGesture { model.selectedID = item.id }
                                .onDrag { dragProvider(for: item) }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selectedID) {
                    if let id = model.selectedID { proxy.scrollTo(id) }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: ClipItem) -> some View {
        Button("Paste") { onPaste(item, false) }
        if item.kind != .image {
            Button("Paste as Plain Text") { onPaste(item, true) }
        }
        if item.kind == .text || item.kind == .link {
            Menu("Paste as") {
                ForEach(TextTransform.allCases) { transform in
                    Button(transform.title) { actions()?.pasteTransformed(item, transform) }
                }
            }
            Button("Edit Before Pasting…") { model.beginEditing(item) }
        }
        Button(model.stackPosition(of: item) == nil ? "Add to Paste Stack" : "Remove from Paste Stack") { model.toggleStack(item) }
        if let text = item.text, !ClipboardFilterHooks.names().isEmpty {
            Menu("Run Macro on It") {
                ForEach(ClipboardFilterHooks.names(), id: \.self) { name in
                    Button(name) { ClipboardFilterHooks.run(name, text) }
                }
            }
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item) }
        Menu("Pinboards") {
            ForEach(pinboards.pinboards) { board in
                Toggle(board.name, isOn: Binding(
                    get: { board.itemIDs.contains(item.id) },
                    set: { _ in pinboards.toggle(item.id, on: board.id) }
                ))
            }
            if !pinboards.pinboards.isEmpty { Divider() }
            Button("New Pinboard…") { actions()?.newPinboard(item) }
        }
        Button("Save as Named Clipboard…") { actions()?.saveNamed(item) }
        if item.kind == .file, let first = item.filePaths?.first {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
            }
        }
        if item.kind == .link, let text = item.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item) }
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ item: ClipItem?) -> some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                previewContent(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                details(item)
                    .padding(14)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func previewContent(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text, .link:
            ScrollView {
                Text(String((item.text ?? "").prefix(20_000)))
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            } else {
                Text("Image file missing").foregroundStyle(.secondary).padding(16)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.filePaths ?? [], id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 12.5))
                                Text(path)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func details(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                detailRow("Type", item.kind.label)
                detailRow("From", item.sourceAppName ?? "Unknown")
                if item.kind == .link, let title = item.linkTitle {
                    detailRow("Page", title)
                }
                if item.kind == .image, let link = item.text {
                    detailRow("Link", link)
                }
                detailRow("Copied", Formatters.full.string(from: item.created))
                if let text = item.text, item.kind != .image {
                    detailRow("Length", "\(text.count) characters")
                }
            }
            HStack(spacing: 8) {
                Button("Paste") { onPaste(item, false) }
                if item.kind != .image {
                    Button("Plain Text") { onPaste(item, true) }
                }
                Spacer()
                Button {
                    model.togglePin(item)
                } label: {
                    Image(systemName: item.pinned ? "pin.slash" : "pin")
                }
                .help(item.pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
                Button {
                    model.delete(item)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete (⌘⌫)")
            }
            .controlSize(.small)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
    }

    // MARK: Grid and strip

    private func cards(_ results: [ClipItem], selectedID: UUID?, horizontal: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(horizontal ? .horizontal : .vertical) {
                let content = ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                    ClipCard(item: item, index: index, selected: item.id == selectedID, store: store,
                             stackPosition: model.stackPosition(of: item), large: horizontal)
                        .id(item.id)
                        .onTapGesture(count: 2) { onPaste(item, false) }
                        .onTapGesture { model.selectedID = item.id }
                        .onDrag { dragProvider(for: item) }
                        .contextMenu { menu(for: item) }
                }
                if horizontal {
                    LazyHStack(spacing: 12) { content }.padding(12)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: ClipboardLayout.gridColumns), spacing: 10) {
                        content
                    }
                    .padding(12)
                }
            }
            .onChange(of: model.selectedID) {
                if let id = model.selectedID { proxy.scrollTo(id) }
            }
        }
    }

    // MARK: Dragging out

    /// Dragging an item out of the panel drops it into another app.
    private func dragProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .link:
            if let url = URL(string: (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .image:
            return store.imageURL(for: item).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        case .file:
            return item.filePaths?.first.flatMap { NSItemProvider(contentsOf: URL(fileURLWithPath: $0)) } ?? NSItemProvider()
        }
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit before pasting").font(.headline)
            TextEditor(text: $model.draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            HStack {
                KeyHint(keys: "esc", label: "Cancel")
                Spacer()
                Button("Save") { model.saveEditing() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Paste") {
                    if let item = model.saveEditing() { onPaste(item, false) }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(30)
        .shadow(radius: 12)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(keys: "↩", label: "Paste")
            KeyHint(keys: "⌥↩", label: "Plain text")
            KeyHint(keys: "space", label: "Preview")
            KeyHint(keys: "⌘1–9", label: "Quick paste")
            KeyHint(keys: "⌘P", label: "Pin")
            KeyHint(keys: "⌘E", label: "Edit")
            KeyHint(keys: "⌘K", label: "Stack")
            Spacer()
            if !model.stack.isEmpty {
                KeyHint(keys: "⌘↩", label: "Paste stack of \(model.stack.count)")
            }
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Row

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let store: ClipboardStore
    var stackPosition: Int? = nil

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? " " : item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                    }
                    Image(systemName: item.kind.symbol).font(.system(size: 9))
                    Text("\(item.sourceAppName ?? item.kind.label) · \(Formatters.ago(item.lastUsed))")
                }
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let stackPosition {
                Text("\(stackPosition)")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.orange))
                    .foregroundStyle(.white)
                    .help("Paste stack position")
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.kind == .image, let image = store.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else if item.fromOtherDevice == true {
            Image(systemName: "iphone")
                .font(.system(size: 16))
        } else if let icon = AppIcons.icon(for: item.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 14))
        }
    }
}

// MARK: - Small views

struct ChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.07))
            )
            .contentShape(Capsule())
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }
}

/// One item as a card, for the grid and strip layouts.
struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let store: ClipboardStore
    var stackPosition: Int? = nil
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if item.fromOtherDevice == true {
                    Image(systemName: "iphone")
                } else if let icon = AppIcons.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: item.kind.symbol)
                }
                Text(item.sourceAppName ?? item.kind.label).lineLimit(1)
                Spacer(minLength: 2)
                if item.pinned { Image(systemName: "pin.fill") }
                if let stackPosition {
                    Text("\(stackPosition)").font(.system(size: 10, weight: .bold))
                        .frame(width: 16, height: 16).background(Circle().fill(Color.orange)).foregroundStyle(.white)
                }
                if index < 9 { Text("⌘\(index + 1)") }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(width: large ? 230 : nil, height: large ? 240 : 150)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            VStack(alignment: .leading, spacing: 4) {
                if let path = item.filePaths?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 44, height: 44)
                }
                Text(item.title).font(.system(size: 12)).lineLimit(2)
            }
        case .text, .link:
            Text(String((item.text ?? "").prefix(400)))
                .font(.system(size: 12))
                .lineLimit(large ? 12 : 6)
                .foregroundStyle(item.kind == .link ? Color.accentColor : Color.primary)
        }
    }
}
