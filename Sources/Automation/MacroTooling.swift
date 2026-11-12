import AppKit
import SwiftUI

// 0.38: tools around macros, like Keyboard Maestro's editor extras.
// - `MacroDebugger` / `DebuggerWindow`: run a macro step by step, watching its variables; steps marked
//   "Pause here" stop a macro that's let run on.
// - `HotKeyGroups` / `ConflictPalette`: when several macros share a shortcut, a small list to pick one.
// - `ProgressPanel`: the "Show progress" step's floating bar.
// - `MacroSync`: macros kept the same on several Macs through a shared folder (iCloud Drive by default).

// MARK: - Debugger

@MainActor
final class MacroDebugger: ObservableObject {
    enum Mode { case stepping, running }

    @Published private(set) var mode: Mode = .stepping
    @Published private(set) var current: String?
    @Published private(set) var variables: [(name: String, value: String)] = []
    @Published private(set) var finished = false
    @Published private(set) var stepsRun = 0
    let macroName: String
    private var waiting: CheckedContinuation<Bool, Never>?

    init(macroName: String, mode: Mode = .stepping) {
        self.macroName = macroName
        self.mode = mode
    }

    var isPaused: Bool { waiting != nil }

    /// Called before each step: waits for Step / Continue / Stop when stepping, or at a "Pause here" step.
    /// Returns false to stop the macro.
    func shouldRun(_ step: MacroStep, in run: MacroRun) async -> Bool {
        stepsRun += 1
        guard mode == .stepping || step.breakpoint == true else { return true }
        mode = .stepping
        current = step.summary
        variables = Self.snapshot(run)
        RealUseHooks.writeStatus()
        return await withCheckedContinuation { waiting = $0 }
    }

    static func snapshot(_ run: MacroRun) -> [(name: String, value: String)] {
        let globals = GlobalVariables.shared.values.map { (name: $0.key, value: $0.value) }
        return (run.variables.map { (name: $0.key, value: $0.value) } + globals).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func step() { resume(true) }

    func continueRun() {
        mode = .running
        resume(true)
    }

    func stop() { resume(false) }

    func done(_ run: MacroRun) {
        finished = true
        current = nil
        variables = Self.snapshot(run)
        resume(false)
        RealUseHooks.writeStatus()
    }

    private func resume(_ value: Bool) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: value)
        RealUseHooks.writeStatus()
    }

    var statusText: String {
        if finished { return "finished" }
        if let current, isPaused { return "paused at \(current)" }
        return "running"
    }
}

struct DebuggerView: View {
    @ObservedObject var debugger: MacroDebugger

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: debugger.finished ? "checkmark.circle.fill" : debugger.isPaused ? "pause.circle.fill" : "play.circle.fill")
                    .foregroundStyle(debugger.finished ? .green : debugger.isPaused ? .orange : .blue).font(.title2)
                VStack(alignment: .leading) {
                    Text(debugger.macroName).font(.headline)
                    Text(debugger.finished ? "Finished after \(debugger.stepsRun) steps" : debugger.isPaused ? "Paused before:" : "Running…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let current = debugger.current, debugger.isPaused {
                Text(current).font(.system(.body, design: .monospaced)).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Variables").font(.caption.weight(.semibold))
            List(debugger.variables, id: \.name) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.system(.caption, design: .monospaced)).frame(width: 150, alignment: .leading)
                    Text(item.value.isEmpty ? "(empty)" : item.value).font(.caption).foregroundStyle(item.value.isEmpty ? .secondary : .primary)
                        .lineLimit(3).textSelection(.enabled)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button("Stop") { debugger.stop() }.disabled(debugger.finished)
                Spacer()
                Button("Continue") { debugger.continueRun() }.disabled(!debugger.isPaused)
                    .help("Run on, stopping only at steps marked “Pause here when debugging”")
                Button("Step") { debugger.step() }.keyboardShortcut(.defaultAction).disabled(!debugger.isPaused)
            }
        }
        .padding(14)
        .frame(minWidth: 460, minHeight: 360)
    }
}

@MainActor
enum DebuggerWindow {
    private static var window: NSWindow?
    private(set) static var current: MacroDebugger?

    static func show(_ debugger: MacroDebugger) {
        current?.stop()
        current = debugger
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Debugging “\(debugger.macroName)”"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = NSHostingController(rootView: DebuggerView(debugger: debugger))
        if self.window == nil {
            window.setContentSize(NSSize(width: 520, height: 420))
            window.center()
            window.setFrameAutosaveName("ToolbeltDebugger")
        }
        self.window = window
        window.orderFrontRegardless()
    }

    static func registerTestHooks(debug: @escaping (String) -> Void) {
        RealUseHooks.extraStatus["debugger"] = { current?.statusText ?? "" }
        RealUseHooks.extraStatus["debuggerVariables"] = { current?.variables.map { "\($0.name)=\($0.value)" } ?? [] }
        RealUseHooks.commands["debug-run"] = { name in debug(name) }
        RealUseHooks.commands["debug-step"] = { _ in current?.step() }
        RealUseHooks.commands["debug-continue"] = { _ in current?.continueRun() }
        RealUseHooks.commands["debug-stop"] = { _ in current?.stop() }
        RealUseHooks.commands["debug-close"] = { _ in window?.close() }
    }
}

// MARK: - Shortcut conflicts

enum HotKeyGroups {
    /// Hot key triggers grouped by their shortcut, in the order first seen.
    static func group(_ pairs: [(Macro, MacroTrigger)]) -> [[(Macro, MacroTrigger)]] {
        var order: [String] = []
        var groups: [String: [(Macro, MacroTrigger)]] = [:]
        for pair in pairs {
            let key = "\(pair.1.keyCode)-\(pair.1.modifiers)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(pair)
        }
        return order.compactMap { groups[$0] }
    }
}

/// Lets a panel take key presses (1–9, Return, Esc) without bringing Toolbelt to the front.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// "Which macro?" when a shortcut belongs to several: click one, or press its number.
@MainActor
enum ConflictPalette {
    private static var panel: PickerPanel?
    private static var choose: ((Int) -> Void)?
    private(set) static var names: [String] = []

    static func show(_ names: [String], shortcut: String, choose: @escaping (Int) -> Void) {
        close()
        self.names = names
        self.choose = choose
        let view = ConflictView(names: names, shortcut: shortcut, pick: { pick($0) }, cancel: { close() })
        let hosting = FirstClickHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = PickerPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + 120))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        RealUseHooks.writeStatus()
    }

    static func pick(_ index: Int) {
        let action = choose
        close()
        if index >= 0, index < 9 { action?(index) }
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
        choose = nil
        names = []
        RealUseHooks.writeStatus()
    }

    static func registerTestHooks() {
        RealUseHooks.extraStatus["conflict"] = { names }
        RealUseHooks.commands["conflict-pick"] = { text in if let number = Int(text) { pick(number - 1) } }
    }
}

struct ConflictView: View {
    let names: [String]
    let shortcut: String
    let pick: (Int) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(shortcut) runs several macros. Which one?").font(.headline)
            ForEach(Array(names.prefix(9).enumerated()), id: \.offset) { index, name in
                Button { pick(index) } label: {
                    HStack {
                        Text("\(index + 1)").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(width: 18)
                        Text(name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

// MARK: - Progress

/// The "Show progress" step's floating bar, one per macro run. It goes away at 100%, when the step says so,
/// or when its macro ends.
@MainActor
enum ProgressPanel {
    private static var panel: NSPanel?
    private static var model = ProgressModel()
    private static var owner: ObjectIdentifier?

    final class ProgressModel: ObservableObject {
        @Published var label = ""
        @Published var fraction: Double? = nil
    }

    /// "50", "50%", "0.5 of 1"… → 0…1. Empty or unreadable: an unknown amount (a moving bar).
    nonisolated static func fraction(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = MacroCalculator.evaluate(cleaned) else { return nil }
        return max(0, min(1, value / 100))
    }

    static func show(_ label: String, percent: String, owner run: MacroRun) {
        owner = ObjectIdentifier(run)
        model.label = label
        model.fraction = fraction(percent)
        if panel == nil {
            let hosting = NSHostingView(rootView: ProgressPanelView(model: model))
            hosting.frame.size = NSSize(width: 340, height: 64)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 64), styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            panel.contentView = hosting
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.midX - 170, y: screen.minY + 80))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        if let value = model.fraction, value >= 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { if model.fraction ?? 0 >= 1 { hide() } } }
        }
        RealUseHooks.writeStatus()
    }

    static func hide(owner run: MacroRun? = nil) {
        if let run, owner != ObjectIdentifier(run) { return }
        panel?.orderOut(nil)
        panel = nil
        owner = nil
        RealUseHooks.writeStatus()
    }

    static var statusText: String {
        guard panel != nil else { return "" }
        return model.label + (model.fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? "")
    }

    static func registerTestHooks() {
        RealUseHooks.extraStatus["progress"] = { statusText }
    }
}

struct ProgressPanelView: View {
    @ObservedObject var model: ProgressPanel.ProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.label.isEmpty ? "Working…" : model.label).font(.callout).lineLimit(1)
            if let fraction = model.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(12)
        .frame(width: 340, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Syncing macros between Macs

/// What a Mac writes to the shared folder: its macros and groups, and the macros it deleted (with when).
struct SyncedMacros: Codable, Equatable {
    var device: String
    var macros: [Macro]
    var groups: [MacroGroup]
    var deleted: [UUID: Date]
}

enum MacroSync {
    static let fileName = "Toolbelt Macros.json"

    /// iCloud Drive's Toolbelt folder (made when sync is switched on).
    static var iCloudFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Toolbelt", isDirectory: true)
    }

    /// Both sides' macros, the newer copy of each (by `modified`), without any deleted after its last change.
    static func merge(local: [Macro], remote: [Macro], deleted: [UUID: Date]) -> [Macro] {
        var result: [Macro] = []
        var seen = Set<UUID>()
        func newer(_ a: Macro, _ b: Macro) -> Macro { (b.modified ?? .distantPast) > (a.modified ?? .distantPast) ? b : a }
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for macro in local {
            seen.insert(macro.id)
            result.append(remoteByID[macro.id].map { newer(macro, $0) } ?? macro)
        }
        for macro in remote where !seen.contains(macro.id) { result.append(macro) }
        return result.filter { macro in
            guard let when = deleted[macro.id] else { return true }
            return (macro.modified ?? .distantPast) > when
        }
    }

    /// Groups from both sides, local first (by id).
    static func mergeGroups(local: [MacroGroup], remote: [MacroGroup]) -> [MacroGroup] {
        let known = Set(local.map(\.id))
        return local + remote.filter { !known.contains($0.id) }
    }

    /// Deletion records from both sides (the later date of each), dropping ones older than 90 days.
    static func mergeDeleted(_ a: [UUID: Date], _ b: [UUID: Date], now: Date = Date()) -> [UUID: Date] {
        a.merging(b) { max($0, $1) }.filter { now.timeIntervalSince($0.value) < 90 * 24 * 3600 }
    }
}

/// Keeps this Mac's macros and the shared folder's file in step: writes after each change here, reads (and
/// merges) when the file changes from another Mac.
@MainActor
final class MacroSyncer {
    private let store: MacroStore
    private var watcher: FolderChangeWatcher?
    private(set) var folder: URL?
    private var knownIDs: Set<UUID> = []
    private var deleted: [UUID: Date] = [:]
    private var applying = false
    private(set) var lastSynced: Date?

    init(store: MacroStore) {
        self.store = store
    }

    var file: URL? { folder?.appendingPathComponent(MacroSync.fileName) }

    /// Starts (or stops, with nil) syncing through this folder.
    func start(folder: URL?) {
        watcher?.stop()
        watcher = nil
        self.folder = folder
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        knownIDs = Set(store.macros.map(\.id))
        pull()
        push()
        let watcher = FolderChangeWatcher(folder: folder) { [weak self] changed, _ in
            if changed.contains(where: { $0.lastPathComponent == MacroSync.fileName }) { self?.pull() }
        }
        watcher.start(lookEvery: 10)
        self.watcher = watcher
    }

    /// Something changed here: note deletions and write the file.
    func localChanged() {
        guard folder != nil, !applying else { return }
        let ids = Set(store.macros.map(\.id))
        let now = Date()
        for gone in knownIDs.subtracting(ids) { deleted[gone] = now }
        knownIDs = ids
        push()
    }

    func push() {
        guard let file else { return }
        let saved = SyncedMacros(device: Host.current().localizedName ?? "Mac", macros: store.macros, groups: store.groups, deleted: deleted)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
        lastSynced = Date()
    }

    /// The file changed (another Mac wrote it): merge it in.
    func pull() {
        guard let file, let data = try? Data(contentsOf: file),
              let remote = try? JSONDecoder().decode(SyncedMacros.self, from: data) else { return }
        deleted = MacroSync.mergeDeleted(deleted, remote.deleted)
        let merged = MacroSync.merge(local: store.macros, remote: remote.macros, deleted: deleted)
        let groups = MacroSync.mergeGroups(local: store.groups, remote: remote.groups)
        applying = true
        if merged != store.macros { store.macros = merged }
        if groups != store.groups { store.groups = groups }
        applying = false
        knownIDs = Set(store.macros.map(\.id))
        lastSynced = Date()
        if merged != remote.macros { push() }
        RealUseHooks.writeStatus()
    }
}
