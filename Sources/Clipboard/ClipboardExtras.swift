import AppKit
import Combine
import Vision

// MARK: - Text transforms

/// Changes applied to text as it's pasted.
enum TextTransform: String, CaseIterable, Identifiable {
    case uppercase, lowercase, titleCase, trimSpaces, removeLineBreaks, removeFormatting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .trimSpaces: return "Trim Spaces"
        case .removeLineBreaks: return "Remove Line Breaks"
        case .removeFormatting: return "Remove Formatting"
        }
    }

    func apply(_ text: String) -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .trimSpaces:
            // Trims each line and squeezes runs of spaces, keeping the line breaks.
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeLineBreaks:
            return text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .removeFormatting:
            return text
        }
    }
}

// MARK: - Text in images (OCR)

/// Reads the text in copied images so they can be found by searching.
/// Runs once per image, in the background at low priority, so it doesn't drain the battery.
enum ImageText {
    static func recognize(at url: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(url: url)
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}

// MARK: - Pinboards

/// A named collection of clipboard items, like "Email replies" or "Addresses".
struct Pinboard: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var itemIDs: [UUID] = []
}

@MainActor
final class PinboardStore: ObservableObject {
    @Published var pinboards: [Pinboard] {
        didSet { if pinboards != oldValue { save() } }
    }
    private let file = SettingsStore.folder.appendingPathComponent("pinboards.json")

    init() {
        pinboards = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Pinboard].self, from: $0) } ?? []
    }

    /// Every item on any pinboard; these are kept like pinned items.
    var allItemIDs: Set<UUID> {
        Set(pinboards.flatMap(\.itemIDs))
    }

    @discardableResult
    func create(_ name: String) -> Pinboard {
        let board = Pinboard(name: name)
        pinboards.append(board)
        return board
    }

    func toggle(_ itemID: UUID, on boardID: UUID) {
        guard let index = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
        if pinboards[index].itemIDs.contains(itemID) {
            pinboards[index].itemIDs.removeAll { $0 == itemID }
        } else {
            pinboards[index].itemIDs.insert(itemID, at: 0)
        }
    }

    func forget(_ itemID: UUID) {
        for index in pinboards.indices {
            pinboards[index].itemIDs.removeAll { $0 == itemID }
        }
    }

    private func save() {
        try? JSONEncoder().encode(pinboards).write(to: file, options: .atomic)
    }
}

// MARK: - Named clipboards

/// A fixed slot you save something into and paste by name, like "Invoice address".
/// Each keeps its own copy, so it stays even if the history item is deleted.
struct NamedClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var item: ClipItem
}

@MainActor
final class NamedClipboardStore: ObservableObject {
    @Published private(set) var clips: [NamedClip] = []
    private let file = SettingsStore.folder.appendingPathComponent("namedclipboards.json")
    private let imagesFolder: URL

    init(imagesFolder: URL) {
        self.imagesFolder = imagesFolder
        clips = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([NamedClip].self, from: $0) } ?? []
    }

    /// Saves (or replaces) a named clipboard with a copy of an item.
    func save(_ item: ClipItem, as name: String) {
        var copy = item
        copy.id = UUID()
        copy.pinned = false
        if let imageFile = item.imageFile {
            let newName = "named-\(copy.id.uuidString).png"
            try? FileManager.default.copyItem(at: imagesFolder.appendingPathComponent(imageFile),
                                              to: imagesFolder.appendingPathComponent(newName))
            copy.imageFile = newName
        }
        remove(named: name)
        clips.append(NamedClip(name: name, item: copy))
        clips.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func clip(named name: String) -> NamedClip? {
        clips.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func remove(named name: String) {
        guard let existing = clip(named: name) else { return }
        if let imageFile = existing.item.imageFile {
            try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(imageFile))
        }
        clips.removeAll { $0.id == existing.id }
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = clips.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        clips[index].name = name
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(clips).write(to: file, options: .atomic)
    }
}

// MARK: - Paste stack

/// Several items picked in order; each press of the "paste next" shortcut pastes the next one.
@MainActor
final class PasteStack: ObservableObject {
    @Published private(set) var queued: [ClipItem] = []

    var isEmpty: Bool { queued.isEmpty }

    func load(_ items: [ClipItem]) {
        queued = items
    }

    /// Takes the next item off the stack.
    func next() -> ClipItem? {
        guard !queued.isEmpty else { return nil }
        return queued.removeFirst()
    }

    func clear() {
        queued = []
    }
}

// MARK: - Auto-delete

enum ClipboardAge {
    /// Choices for "Delete items older than", in days (0 = never).
    static let choices: [(days: Int, title: String)] = [
        (0, "Never"), (1, "1 day"), (7, "1 week"), (30, "1 month"), (90, "3 months"), (365, "1 year"),
    ]
}
