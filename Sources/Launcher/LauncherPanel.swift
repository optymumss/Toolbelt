import AppKit
import SwiftUI

/// What the launcher shows: the typed search and the ranked results.
@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    @Published private(set) var results: [LauncherResult] = []
    @Published var selectedIndex = 0
    @Published var focusToken = 0

    private let providers: () -> [LauncherProvider]
    private let files = FileSearch()
    private var instantResults: [LauncherResult] = []

    init(providers: @escaping () -> [LauncherProvider]) {
        self.providers = providers
    }

    var selected: LauncherResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    func refresh() {
        let q = query.trimmingCharacters(in: .whitespaces)
        files.cancel()
        guard !q.isEmpty else {
            instantResults = []
            results = []
            selectedIndex = 0
            return
        }
        instantResults = providers().flatMap { $0.results(for: q) }
        publish(instantResults, keepSelection: false)

        if Prefs.launcherSearchFiles, q.count >= 2 {
            files.search(q) { [weak self] found in
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == q else { return }
                self.publish(self.instantResults + found, keepSelection: true)
            }
        }
    }

    private func publish(_ list: [LauncherResult], keepSelection: Bool) {
        let selectedID = keepSelection ? selected?.id : nil
        results = Self.rank(list)
        selectedIndex = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    }

    /// Best score first; ties keep the order the providers gave.
    static func rank(_ list: [LauncherResult]) -> [LauncherResult] {
        let sorted = list.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }
        return Array(sorted.map(\.element).prefix(30))
    }
}

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    let model: LauncherModel
    private let panel: KeyPanel
    private var keyMonitor: Any?
    static let size = NSSize(width: 680, height: 440)

    init(model: LauncherModel) {
        self.model = model
        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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

        let view = LauncherView(model: model) { [weak self] result in self?.run(result) }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show(query: String = "") {
        model.query = query

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2 + frame.height * 0.12)
            panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
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

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func run(_ result: LauncherResult) {
        hide()
        result.action()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

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
            guard let result = model.selected else { return true }
            if flags.contains(.command), let url = result.revealURL {
                hide()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                run(result)
            }
            return true
        default:
            return false
        }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    var onRun: (LauncherResult) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                TextField("Search apps, files, commands, sums…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            if model.results.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }

            Divider()
            HStack(spacing: 14) {
                KeyHint(keys: "↩", label: "Open")
                KeyHint(keys: "⌘↩", label: "Show in Finder")
                KeyHint(keys: "↑↓", label: "Move")
                Spacer()
                KeyHint(keys: "esc", label: "Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: LauncherPanelController.size.width, height: LauncherPanelController.size.height)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        LauncherRow(result: result, selected: index == model.selectedIndex)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onRun(result) }
                            .onTapGesture { model.selectedIndex = index }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selectedIndex) {
                if let result = model.selected { proxy.scrollTo(result.id) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Try typing").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                hint("app.badge", "Safari", "open an app, file or folder")
                hint("plus.forwardslash.minus", "12 * 7 + 1", "work out a sum")
                hint("arrow.left.arrow.right", "5 km in miles", "convert units")
                hint("globe", "g cats", "search Google (quicklinks are in Settings)")
                hint("lock", "lock", "lock screen, sleep, empty Bin, dark mode…")
                hint("doc.on.clipboard", "address", "find something you copied")
            }
            .padding(24)
        } else {
            Text("No results").foregroundStyle(.secondary)
        }
    }

    private func hint(_ symbol: String, _ example: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(example).font(.system(size: 13, weight: .medium, design: .rounded))
            Text("— \(label)").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

struct LauncherRow: View {
    let result: LauncherResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(result.kind)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch result.icon {
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 17))
        }
    }
}
