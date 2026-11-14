import AppKit
import CryptoKit

// 0.40: keep everything the same on all your Macs, not just macros (0.38): triggers and their presets
// and groups, floating menus and menu-bar items, widgets, snippets, saved window layouts and snap areas,
// and settings. Each is a file in the same sync folder as the macros (iCloud Drive or any folder). When
// only one Mac changed something it's copied to the others; when both did, the newer change wins.
// Settings that only make sense on one Mac (the sync folder itself, whether keys are remapped right
// now) stay on that Mac.

/// One file in the sync folder: which Mac wrote it, when the data last changed, and the data.
struct SyncedFile: Codable, Equatable {
    var device: String
    var modified: Date
    var data: Data
}

/// What to do with one file. Pure, so it can be tested.
enum FileSync {
    enum Decision: Equatable { case nothing, push, pull }

    /// `last` is what both sides held at the last sync (a hash); nil means never synced.
    static func decide(local: String?, last: String?, remote: String?, localModified: Date, remoteModified: Date?) -> Decision {
        guard let remote else { return local == nil ? .nothing : .push }
        guard let local else { return .pull }
        if local == remote { return .nothing }
        let localChanged = local != last
        let remoteChanged = remote != last
        switch (localChanged, remoteChanged) {
        case (true, false): return .push
        case (false, true): return .pull
        default: return localModified >= (remoteModified ?? .distantPast) ? .push : .pull
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class EverythingSync {
    static let shared = EverythingSync()

    struct Item {
        let name: String
        let file: URL
        let reload: () -> Void
    }

    /// Kept on each Mac only.
    static let localSettings: Set<String> = ["macros.syncFolder", "sync.everything", "keys.applied"]

    static var isOn: Bool {
        get { SettingsStore.shared.value("sync.everything", default: false) }
        set { SettingsStore.shared.set(newValue, for: "sync.everything") }
    }

    private var items: [Item] = []
    private(set) var folder: URL?
    private var timer: Timer?
    /// The hash of each file at the last sync, kept between launches.
    private var last: [String: String] = [:]
    private(set) var lastSynced: Date?
    private(set) var pulled: [String] = []

    private static var stateFile: URL { SettingsStore.folder.appendingPathComponent("sync-state.json") }

    init() {
        last = ((try? Data(contentsOf: Self.stateFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
    }

    /// Called by the stores that own the files.
    func register(_ name: String, file: URL, reload: @escaping () -> Void) {
        items.removeAll { $0.name == name }
        items.append(Item(name: name, file: file, reload: reload))
    }

    var names: [String] { ["Settings"] + items.map(\.name) }

    /// Starts (or stops, with nil) syncing through this folder.
    func start(folder: URL?) {
        timer?.invalidate()
        timer = nil
        self.folder = folder
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        syncNow()
        // A look every 15 seconds while syncing is on (it reads a few small files; nothing otherwise).
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { EverythingSync.shared.syncNow() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func syncNow() {
        guard let folder else { return }
        pulled = []
        for item in items {
            sync(name: item.name, remoteURL: folder.appendingPathComponent("Toolbelt \(item.name).json"),
                 read: { (try? Data(contentsOf: item.file)).map { ($0, Self.modified(item.file)) } },
                 write: { data in
                     try? data.write(to: item.file, options: .atomic)
                     item.reload()
                 })
        }
        sync(name: "Settings", remoteURL: folder.appendingPathComponent("Toolbelt Settings.json"),
             read: { (SettingsStore.shared.syncedData(excluding: Self.localSettings), SettingsStore.shared.lastChanged) },
             write: { data in SettingsStore.shared.applySynced(data, keeping: Self.localSettings) })
        if let data = try? JSONEncoder().encode(last) { try? data.write(to: Self.stateFile, options: .atomic) }
        lastSynced = Date()
        RealUseHooks.writeStatus()
    }

    private func sync(name: String, remoteURL: URL, read: () -> (Data, Date)?, write: (Data) -> Void) {
        let local = read()
        let remote = (try? Data(contentsOf: remoteURL)).flatMap { try? Self.decoder.decode(SyncedFile.self, from: $0) }
        let localHash = local.map { FileSync.hash($0.0) }
        let remoteHash = remote.map { FileSync.hash($0.data) }
        switch FileSync.decide(local: localHash, last: last[name], remote: remoteHash, localModified: local?.1 ?? .distantPast,
                               remoteModified: remote?.modified) {
        case .nothing:
            if let localHash, localHash == remoteHash { last[name] = localHash }
        case .push:
            guard let local else { return }
            let file = SyncedFile(device: Host.current().localizedName ?? "Mac", modified: local.1, data: local.0)
            if let data = try? Self.encoder.encode(file) { try? data.write(to: remoteURL, options: .atomic) }
            last[name] = localHash
        case .pull:
            guard let remote else { return }
            write(remote.data)
            last[name] = remoteHash
            pulled.append(name)
        }
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func registerTestHooks() {
        RealUseHooks.commands["sync-now"] = { _ in shared.syncNow() }
        RealUseHooks.extraStatus["syncPulled"] = { shared.pulled }
        RealUseHooks.extraStatus["syncEverything"] = { shared.folder != nil ? "on" : "off" }
    }
}
