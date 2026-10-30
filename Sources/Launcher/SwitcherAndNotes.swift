import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Recently used

/// Remembers which launcher results you pick, so the ones you use often come first.
@MainActor
final class LauncherUsage {
    struct Use: Codable {
        var count: Int
        var last: Date
    }

    private(set) var uses: [String: Use] = [:]
    private let file = SettingsStore.folder.appendingPathComponent("launcher-usage.json")

    init() {
        uses = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Use].self, from: $0) } ?? [:]
    }

    func record(_ id: String, now: Date = Date()) {
        var use = uses[id] ?? Use(count: 0, last: now)
        use.count += 1
        use.last = now
        uses[id] = use
        if uses.count > 500 { // keep the 500 most recent
            let keep = uses.sorted { $0.value.last > $1.value.last }.prefix(500)
            uses = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        try? JSONEncoder().encode(uses).write(to: file, options: .atomic)
    }

    /// Extra score: up to 20 for how often, up to 10 for how recently (fading over a week).
    func boost(for id: String, now: Date = Date()) -> Double {
        guard let use = uses[id] else { return 0 }
        let often = min(20, Double(use.count) * 4)
        let days = now.timeIntervalSince(use.last) / 86_400
        let recent = max(0, 10 - days * 10 / 7)
        return often + recent
    }
}

// MARK: - App and window switcher

/// Running apps and their windows, most recently used first.
@MainActor
final class SwitcherProvider: LauncherProvider {
    /// Process IDs in the order apps were last brought to the front.
    private var recent: [pid_t] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.recent.removeAll { $0 == pid }
                self?.recent.insert(pid, at: 0)
            }
        }
    }

    var runningApps: [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        return apps.sorted { a, b in
            let ia = recent.firstIndex(of: a.processIdentifier) ?? Int.max
            let ib = recent.firstIndex(of: b.processIdentifier) ?? Int.max
            return ia != ib ? ia < ib : (a.localizedName ?? "") < (b.localizedName ?? "")
        }
    }

    /// An app's windows and their titles (needs Accessibility).
    static func windows(of app: NSRunningApplication) -> [(window: AXWindow, title: String)] {
        guard AXIsProcessTrusted() else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.compactMap { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard let text = title as? String, !text.isEmpty else { return nil }
            return (AXWindow(element: window), text)
        }
    }

    func results(for query: String) -> [LauncherResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var results: [LauncherResult] = []
        for (order, app) in runningApps.enumerated() {
            let name = app.localizedName ?? "App"
            let appScore = q.isEmpty ? 200 - Double(order) * 2 : FuzzyMatch.score(q, name)
            let windows = Self.windows(of: app)
            let icon: LauncherIcon = app.icon.map { .image($0) } ?? .symbol("app")

            if appScore > 0 {
                results.append(LauncherResult(
                    id: "running:\(app.bundleIdentifier ?? name)", title: name,
                    subtitle: (app.isHidden ? "Hidden · " : "") + "\(windows.count) window\(windows.count == 1 ? "" : "s") · ⌘Q quit · ⌘H hide",
                    kind: "Running", icon: icon, score: appScore,
                    revealURL: app.bundleURL,
                    action: { Self.bringForward(app) },
                    extraActions: [
                        "q": { app.terminate() },
                        "h": { app.hide() },
                    ]
                ))
            }
            for (index, entry) in windows.enumerated() {
                let score = q.isEmpty ? appScore - 1 - Double(index) * 0.1
                    : max(FuzzyMatch.score(q, entry.title), FuzzyMatch.score(q, name) * 0.9)
                guard score > 0 else { continue }
                let window = entry.window
                results.append(LauncherResult(
                    id: "window:\(app.processIdentifier):\(index):\(entry.title)", title: entry.title,
                    subtitle: "\(name) · ⌘W close", kind: "Window", icon: icon, score: score,
                    action: {
                        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                        Self.bringForward(app)
                    },
                    extraActions: ["w": { Self.close(window) }]
                ))
            }
        }
        return results
    }

    static func bringForward(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
    }

    static func close(_ window: AXWindow) {
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }
}

// MARK: - Floating notes

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var color: NoteColor = .yellow
    var x: Double? = nil
    var y: Double? = nil
    var width: Double = 260
    var height: Double = 220

    var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Empty note" : String(line.prefix(60))
    }
}

enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yellow: return Color(red: 1.0, green: 0.95, blue: 0.62)
        case .green: return Color(red: 0.78, green: 0.94, blue: 0.75)
        case .blue: return Color(red: 0.76, green: 0.87, blue: 1.0)
        case .pink: return Color(red: 1.0, green: 0.82, blue: 0.87)
        case .purple: return Color(red: 0.88, green: 0.8, blue: 1.0)
        case .gray: return Color(red: 0.9, green: 0.9, blue: 0.9)
        }
    }
}

/// Floating notes, saved in notes.json, each in its own small window that stays on top.
@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet { if notes != oldValue { save() } }
    }
    private let file = SettingsStore.folder.appendingPathComponent("notes.json")

    init() {
        notes = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Note].self, from: $0) } ?? []
    }

    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
    }

    private func save() {
        try? JSONEncoder().encode(notes).write(to: file, options: .atomic)
    }
}

@MainActor
final class NotesController: NSObject, NSWindowDelegate {
    let store: NotesStore
    private var windows: [UUID: NSPanel] = [:]
    private var shown = false

    init(store: NotesStore) {
        self.store = store
    }

    var openWindowCount: Int { windows.values.filter(\.isVisible).count }

    func showAll() {
        shown = true
        for note in store.notes { window(for: note.id)?.orderFrontRegardless() }
    }

    func hideAll() {
        shown = false
        for window in windows.values { window.orderOut(nil) }
    }

    @discardableResult
    func newNote(text: String = "") -> UUID {
        var note = Note(text: text)
        let colors = NoteColor.allCases
        note.color = colors[store.notes.count % colors.count]
        let mouse = NSEvent.mouseLocation
        note.x = mouse.x - note.width / 2
        note.y = mouse.y - note.height / 2
        store.notes.append(note)
        if let window = window(for: note.id) {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        return note.id
    }

    func show(_ id: UUID) {
        guard let window = window(for: id) else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func delete(_ id: UUID) {
        windows[id]?.delegate = nil
        windows[id]?.orderOut(nil)
        windows[id] = nil
        store.notes.removeAll { $0.id == id }
    }

    private func window(for id: UUID) -> NSPanel? {
        if let existing = windows[id] { return existing }
        guard let note = store.notes.first(where: { $0.id == id }) else { return nil }
        let frame = NSRect(x: note.x ?? 200, y: note.y ?? 200, width: note.width, height: note.height)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 160, height: 120)
        panel.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        panel.contentView = NSHostingView(rootView: NoteView(store: store, id: id))
        panel.delegate = self
        windows[id] = panel
        return panel
    }

    // MARK: Window delegate

    private func noteID(of notification: Notification) -> UUID? {
        (notification.object as? NSWindow)?.identifier.flatMap { UUID(uuidString: $0.rawValue) }
    }

    func windowDidMove(_ notification: Notification) { rememberFrame(notification) }
    func windowDidResize(_ notification: Notification) { rememberFrame(notification) }

    private func rememberFrame(_ notification: Notification) {
        guard let id = noteID(of: notification), let frame = (notification.object as? NSWindow)?.frame else { return }
        store.update(id) {
            $0.x = frame.minX
            $0.y = frame.minY
            $0.width = frame.width
            $0.height = frame.height
        }
    }

    /// Closing a note's window deletes the note (after asking, if it has text in it).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let note = store.notes.first(where: { $0.id == id }) else { return true }
        if !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Delete this note?"
            alert.informativeText = note.title
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Keep")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        delete(id)
        return false // already hidden and forgotten
    }
}

struct NoteView: View {
    @ObservedObject var store: NotesStore
    let id: UUID

    var body: some View {
        let note = store.notes.first { $0.id == id } ?? Note()
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Menu {
                    ForEach(NoteColor.allCases) { color in
                        Button(color.rawValue.capitalized) { store.update(id) { $0.color = color } }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 8)
            }
            .frame(height: 26)
            TextEditor(text: Binding(
                get: { MainActor.assumeIsolated { store.notes.first { $0.id == id }?.text ?? "" } },
                set: { text in MainActor.assumeIsolated { store.update(id) { $0.text = text } } }
            ))
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .background(note.color.color)
    }
}

/// Notes in the launcher: "New Note", and finding notes by their text.
@MainActor
final class NotesLauncherProvider: LauncherProvider {
    private let controller: NotesController

    init(controller: NotesController) {
        self.controller = controller
    }

    func results(for query: String) -> [LauncherResult] {
        var results: [LauncherResult] = []
        let newScore = max(FuzzyMatch.score(query, "new note"), FuzzyMatch.score(query, "note"))
        if newScore > 0 {
            results.append(LauncherResult(id: "note:new", title: "New Floating Note", kind: "Note",
                                          icon: .symbol("note.text.badge.plus"), score: newScore) { [controller] in
                controller.newNote()
            })
        }
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return results }
        for note in controller.store.notes where note.text.localizedCaseInsensitiveContains(query) || FuzzyMatch.score(query, note.title) > 0 {
            let id = note.id
            results.append(LauncherResult(id: "note:" + id.uuidString, title: note.title, subtitle: "Floating note",
                                          kind: "Note", icon: .symbol("note.text"), score: 50) { [controller] in
                controller.show(id)
            })
        }
        return results
    }
}
