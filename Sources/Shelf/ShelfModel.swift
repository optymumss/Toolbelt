import AppKit
import Combine

enum ShelfColor: String, Codable, CaseIterable, Identifiable {
    case gray, red, orange, yellow, green, blue, purple

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .gray: return .systemGray
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        }
    }
}

struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file, text, link, image
    }

    var id = UUID()
    var kind: Kind
    /// Files (original or copied onto the shelf) and saved images.
    var path: String? = nil
    var text: String? = nil
    /// True when the shelf holds its own copy of the file.
    var isCopy = false

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    var title: String {
        switch kind {
        case .file, .image: return url?.lastPathComponent ?? "Item"
        case .link: return text ?? "Link"
        case .text:
            let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(line.prefix(80))
        }
    }

    /// What the item turns into when it's dragged out of the shelf.
    var dragWriter: NSPasteboardWriting? {
        switch kind {
        case .file, .image:
            return url as NSURL?
        case .link:
            return text.flatMap(URL.init(string:)) as NSURL?
        case .text:
            return text as NSString?
        }
    }
}

struct Shelf: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var color: ShelfColor = .blue
    var items: [ShelfItem] = []
    /// Where the window was, in screen coordinates (bottom-left origin).
    var originX: Double? = nil
    var originY: Double? = nil
}

/// Keeps shelves in ~/Library/Application Support/Toolbelt/shelves.json,
/// and copied files and dropped images in …/Toolbelt/shelves/<shelf>/.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var shelves: [Shelf] = []
    private let file: URL
    let folder: URL

    init() {
        file = SettingsStore.folder.appendingPathComponent("shelves.json")
        folder = SettingsStore.folder.appendingPathComponent("shelves", isDirectory: true)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Shelf].self, from: data) {
            shelves = saved
        }
    }

    func shelf(_ id: UUID) -> Shelf? {
        shelves.first { $0.id == id }
    }

    @discardableResult
    func newShelf() -> Shelf {
        let usedColors = Set(shelves.map(\.color))
        let color = ShelfColor.allCases.dropFirst().first { !usedColors.contains($0) } ?? .blue
        let shelf = Shelf(name: "Shelf \(shelves.count + 1)", color: color)
        shelves.append(shelf)
        save()
        return shelf
    }

    func update(_ id: UUID, _ change: (inout Shelf) -> Void) {
        guard let index = shelves.firstIndex(where: { $0.id == id }) else { return }
        change(&shelves[index])
        save()
    }

    /// Removes a shelf and anything the shelf itself was storing (never your original files).
    func remove(_ id: UUID) {
        shelves.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: storage(for: id))
        save()
    }

    func removeItem(_ itemID: UUID, from shelfID: UUID) {
        update(shelfID) { shelf in
            if let item = shelf.items.first(where: { $0.id == itemID }), item.isCopy || item.kind == .image, let url = item.url {
                try? FileManager.default.removeItem(at: url)
            }
            shelf.items.removeAll { $0.id == itemID }
        }
    }

    func storage(for shelfID: UUID) -> URL {
        folder.appendingPathComponent(shelfID.uuidString, isDirectory: true)
    }

    /// Adds whatever is on a pasteboard (a drop, or the clipboard) to a shelf.
    /// Returns how many items were added.
    @discardableResult
    func add(from pasteboard: NSPasteboard, to shelfID: UUID, copyFiles: Bool? = nil) -> Int {
        let copyFiles = copyFiles ?? Prefs.shelfCopiesFiles
        var newItems: [ShelfItem] = []
        let storage = storage(for: shelfID)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                if copyFiles {
                    let destination = Self.unusedURL(for: url.lastPathComponent, in: storage)
                    if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
                        newItems.append(ShelfItem(kind: .file, path: destination.path, isCopy: true))
                        continue
                    }
                }
                newItems.append(ShelfItem(kind: .file, path: url.path))
            }
        } else if let image = Self.imageData(from: pasteboard) {
            let destination = Self.unusedURL(for: "Image.png", in: storage)
            if (try? image.write(to: destination)) != nil {
                newItems.append(ShelfItem(kind: .image, path: destination.path, isCopy: true))
            }
        } else if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            newItems.append(ShelfItem(kind: ClipboardMonitor.isLink(string) ? .link : .text, text: string))
        } else if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            newItems.append(ShelfItem(kind: .link, text: url.absoluteString))
        }

        guard !newItems.isEmpty else { return 0 }
        update(shelfID) { $0.items.append(contentsOf: newItems) }
        return newItems.count
    }

    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// "Report.pdf", then "Report 2.pdf", "Report 3.pdf"… so copies never overwrite each other.
    nonisolated static func unusedURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func save() {
        do {
            try JSONEncoder().encode(shelves).write(to: file, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save shelves: \(error)")
        }
    }
}

/// Spots a quick side-to-side shake of the pointer, like Dropover's "shake to open a shelf".
struct ShakeDetector {
    /// Pointer must change direction this many times…
    var reversalsNeeded = 4
    /// …within this many seconds…
    var window: TimeInterval = 0.7
    /// …moving at least this far each way.
    var minimumTravel: CGFloat = 25

    private var lastX: CGFloat?
    private var direction: CGFloat = 0
    private var travel: CGFloat = 0
    private var reversals: [TimeInterval] = []

    /// Feed pointer positions while dragging. Returns true once when a shake is spotted.
    mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lastX else { return false }
        let dx = x - lastX
        guard abs(dx) > 0.5 else { return false }
        let newDirection: CGFloat = dx > 0 ? 1 : -1

        if newDirection == direction {
            travel += abs(dx)
            return false
        }
        if direction != 0, travel >= minimumTravel {
            reversals.append(time)
        }
        direction = newDirection
        travel = abs(dx)
        reversals.removeAll { time - $0 > window }
        if reversals.count >= reversalsNeeded {
            reset()
            return true
        }
        return false
    }

    mutating func reset() {
        lastX = nil
        direction = 0
        travel = 0
        reversals = []
    }
}
