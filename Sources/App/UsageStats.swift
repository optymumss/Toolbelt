import AppKit
import SwiftUI

// 0.39: how often each trigger and macro runs, like BetterTouchTool's usage statistics, so ones you
// never use can be tidied away. Kept in usage.json on this Mac only; nothing is sent anywhere.

struct UsageEntry: Codable, Equatable {
    var count: Int
    var last: Date
}

/// A trigger or macro as the Usage window lists it.
struct UsageItem: Identifiable, Equatable {
    var id: String
    var kind: String
    var name: String
    var count: Int
    var last: Date?
}

enum UsageFilter: String, CaseIterable, Identifiable {
    case all, unusedMonth, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .unusedMonth: return "Not used for 30 days"
        case .never: return "Never used"
        }
    }
}

@MainActor
final class UsageStats: ObservableObject {
    static let shared = UsageStats()

    @Published private(set) var entries: [String: UsageEntry] = [:]
    private var saveScheduled = false

    /// The triggers and macros that exist (key, kind, name), registered by the modules that own them.
    static var sources: [String: () -> [(key: String, kind: String, name: String)]] = [:]

    static var file: URL { SettingsStore.folder.appendingPathComponent("usage.json") }

    nonisolated static func ruleKey(_ id: UUID) -> String { "rule:" + id.uuidString }
    nonisolated static func macroKey(_ id: UUID) -> String { "macro:" + id.uuidString }

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = ((try? Data(contentsOf: Self.file)).flatMap { try? decoder.decode([String: UsageEntry].self, from: $0) }) ?? [:]
    }

    func record(_ key: String, at date: Date = Date()) {
        var entry = entries[key] ?? UsageEntry(count: 0, last: date)
        entry.count += 1
        entry.last = date
        entries[key] = entry
        scheduleSave()
    }

    func entry(_ key: String) -> UsageEntry? { entries[key] }

    /// For the screenshot's made-up numbers.
    func set(_ key: String, _ entry: UsageEntry) {
        entries[key] = entry
    }

    func reset() {
        entries = [:]
        saveNow()
    }

    /// Written a couple of seconds after a run, so a gesture repeating 20 times a second writes once.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.saveNow()
            }
        }
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) { try? data.write(to: Self.file, options: .atomic) }
        RealUseHooks.writeStatus()
    }

    /// Every known trigger and macro with its numbers.
    func items() -> [UsageItem] {
        Self.items(known: Self.sources.values.flatMap { $0() }, entries: entries)
    }

    nonisolated static func items(known: [(key: String, kind: String, name: String)], entries: [String: UsageEntry]) -> [UsageItem] {
        known.map { UsageItem(id: $0.key, kind: $0.kind, name: $0.name, count: entries[$0.key]?.count ?? 0, last: entries[$0.key]?.last) }
    }

    /// Most used first (ties: most recent, then by name), filtered.
    nonisolated static func list(_ items: [UsageItem], filter: UsageFilter, now: Date = Date()) -> [UsageItem] {
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        return items.filter { item in
            switch filter {
            case .all: return true
            case .never: return item.count == 0
            case .unusedMonth: return (item.last ?? .distantPast) < monthAgo
            }
        }
        .sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.last != b.last { return (a.last ?? .distantPast) > (b.last ?? .distantPast) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// "12 times · last today at 09:14" (or "Never used").
    nonisolated static func summary(_ entry: UsageEntry?, now: Date = Date()) -> String {
        guard let entry, entry.count > 0 else { return "Never used" }
        let times = entry.count == 1 ? "Once" : "\(entry.count) times"
        return "\(times) · last \(lastText(entry.last, now: now))"
    }

    nonisolated static func lastText(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday at \(time)" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    static func registerTestHooks() {
        // Counts by name: "macro:Test flow" → 2.
        RealUseHooks.extraStatus["usageCounts"] = {
            var counts: [String: Int] = [:]
            for item in shared.items() { counts[item.kind.lowercased() + ":" + item.name] = item.count }
            return counts
        }
    }
}

struct UsageView: View {
    @ObservedObject var stats = UsageStats.shared
    @State private var filter = UsageFilter.all
    @State private var search = ""
    @State private var confirmReset = false

    private var rows: [UsageItem] {
        UsageStats.list(stats.items(), filter: filter).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(UsageFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Table(rows) {
                TableColumn("Name") { item in Text(item.name).lineLimit(1) }
                TableColumn("Kind") { item in Text(item.kind).foregroundStyle(.secondary) }.width(70)
                TableColumn("Times") { item in Text("\(item.count)").monospacedDigit() }.width(50)
                TableColumn("Last used") { item in
                    Text(item.last.map { UsageStats.lastText($0) } ?? "never").foregroundStyle(item.last == nil ? .secondary : .primary)
                }
                .width(150)
            }
            HStack {
                Text("Counted on this Mac since \(stats.entries.isEmpty ? "now" : "the counts were last reset"). Turn off or delete what you never use in the Triggers and Macros windows.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Counts…") { confirmReset = true }
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 380)
        .confirmationDialog("Start counting from zero?", isPresented: $confirmReset) {
            Button("Reset Counts", role: .destructive) { stats.reset() }
        }
    }
}

@MainActor
enum UsageWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Usage Statistics"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: UsageView())
            window.setContentSize(NSSize(width: 640, height: 440))
            window.center()
            window.setFrameAutosaveName("ToolbeltUsage")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
