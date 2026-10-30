import AppKit
import Combine

/// Holds clipboard history in memory and saves it to
/// ~/Library/Application Support/Toolbelt/
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    let folder: URL
    let imagesFolder: URL
    private let historyFile: URL
    private var saveTask: Task<Void, Never>?
    private let imageCache = NSCache<NSString, NSImage>()
    /// Items that must be kept like pinned ones (for example, those on a pinboard).
    var isProtected: (UUID) -> Bool = { _ in false }
    /// Called with each new image, so its text can be read for searching.
    var onNewImage: ((ClipItem) -> Void)?

    init() {
        folder = SettingsStore.folder
        imagesFolder = folder.appendingPathComponent("images", isDirectory: true)
        historyFile = folder.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        load()
    }

    // MARK: Changes

    func add(_ newItem: ClipItem, imageData: Data? = nil) {
        if let index = items.firstIndex(where: { $0.hash == newItem.hash }) {
            // Already in history: move it to the top instead of duplicating.
            var existing = items.remove(at: index)
            existing.lastUsed = Date()
            existing.sourceAppName = newItem.sourceAppName ?? existing.sourceAppName
            existing.sourceBundleID = newItem.sourceBundleID ?? existing.sourceBundleID
            items.insert(existing, at: 0)
        } else {
            var item = newItem
            if let imageData {
                let name = "\(item.id.uuidString).png"
                do {
                    try imageData.write(to: imagesFolder.appendingPathComponent(name), options: .atomic)
                    item.imageFile = name
                } catch {
                    return
                }
            }
            items.insert(item, at: 0)
            trimToLimit()
            if item.kind == .image { onNewImage?(item) }
        }
        scheduleSave()
    }

    /// Changes one item in place (for example after editing its text or reading text in an image).
    func update(_ id: UUID, _ change: (inout ClipItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        scheduleSave()
    }

    private func keeps(_ item: ClipItem) -> Bool {
        item.pinned || isProtected(item.id)
    }

    /// Deletes items not used for `days` days, except pinned ones and pinboard items.
    func deleteOlder(thanDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let old = items.filter { !keeps($0) && $0.lastUsed < cutoff }
        guard !old.isEmpty else { return }
        for item in old { removeImageFile(for: item) }
        let oldIDs = Set(old.map(\.id))
        items.removeAll { oldIDs.contains($0.id) }
        scheduleSave()
    }

    /// Moves an item to the top after it has been pasted.
    func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastUsed = Date()
        items.insert(item, at: 0)
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        removeImageFile(for: items[index])
        items.remove(at: index)
        scheduleSave()
    }

    func clearUnpinned() {
        for item in items where !keeps(item) { removeImageFile(for: item) }
        items.removeAll { !keeps($0) }
        scheduleSave()
    }

    private func trimToLimit() {
        let limit = Prefs.historyLimit
        guard limit > 0 else { return }
        var unpinnedSeen = 0
        var keep: [ClipItem] = []
        for item in items {
            if keeps(item) {
                keep.append(item)
            } else if unpinnedSeen < limit {
                unpinnedSeen += 1
                keep.append(item)
            } else {
                removeImageFile(for: item)
            }
        }
        items = keep
    }

    // MARK: Images

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFile else { return nil }
        return imagesFolder.appendingPathComponent(name)
    }

    func image(for item: ClipItem) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let url = imageURL(for: item), let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private func removeImageFile(for item: ClipItem) {
        guard let url = imageURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
        imageCache.removeObject(forKey: item.id.uuidString as NSString)
    }

    // MARK: Saving and loading

    private func load() {
        guard let data = try? Data(contentsOf: historyFile) else { return }
        do {
            items = try JSONDecoder().decode([ClipItem].self, from: data)
        } catch {
            // Keep the unreadable file aside rather than overwriting it.
            let backup = folder.appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: historyFile, to: backup)
            items = []
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: historyFile, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save history: \(error)")
        }
    }
}
