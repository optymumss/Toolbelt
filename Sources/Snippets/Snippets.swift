import AppKit
import Combine

struct Snippet: Identifiable, Codable, Equatable {
    var id = UUID()
    /// What you type, for example ";addr".
    var keyword: String
    var name: String
    /// What it turns into. May contain placeholders like {date} and {cursor}.
    var text: String
}

/// Keeps snippets in ~/Library/Application Support/Toolbelt/snippets.json
@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] {
        didSet { if snippets != oldValue { save() } }
    }

    private let file: URL

    init() {
        file = SettingsStore.folder.appendingPathComponent("snippets.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = saved
        } else {
            snippets = []
        }
    }

    func snippet(forKeyword keyword: String) -> Snippet? {
        snippets.first { $0.keyword == keyword }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(snippets).write(to: file, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save snippets: \(error)")
        }
    }
}

/// Fills in placeholders: {date}, {time}, {datetime}, {date:yyyy-MM-dd},
/// {clipboard} and {cursor}.
enum Placeholders {
    struct Result: Equatable {
        let text: String
        /// How many characters the cursor moves back from the end ({cursor}).
        let cursorFromEnd: Int
    }

    static let help = [
        ("{date}", "today's date"),
        ("{time}", "the time now"),
        ("{datetime}", "date and time"),
        ("{date:dd/MM/yyyy}", "date in your own format"),
        ("{clipboard}", "whatever you last copied"),
        ("{cursor}", "where the cursor ends up"),
    ]

    static func render(_ template: String, now: Date = Date(), clipboard: String? = nil, locale: Locale = .current) -> Result {
        var output = ""
        var cursorIndex: Int?
        var rest = Substring(template)

        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                output += rest[open...]
                rest = ""
                break
            }
            let name = String(rest[rest.index(after: open)..<close])
            if name == "cursor" {
                cursorIndex = output.count
            } else if let value = value(for: name, now: now, clipboard: clipboard, locale: locale) {
                output += value
            } else {
                output += rest[open...close] // not a placeholder: keep it as typed
            }
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        return Result(text: output, cursorFromEnd: cursorIndex.map { output.count - $0 } ?? 0)
    }

    private static func value(for name: String, now: Date, clipboard: String?, locale: Locale) -> String? {
        let formatter = DateFormatter()
        formatter.locale = locale
        switch name {
        case "date":
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case "time":
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case "datetime":
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        case "clipboard":
            return clipboard ?? NSPasteboard.general.string(forType: .string) ?? ""
        default:
            guard name.hasPrefix("date:") else { return nil }
            formatter.dateFormat = String(name.dropFirst("date:".count))
        }
        return formatter.string(from: now)
    }
}

/// Watches what you type (one key at a time) and spots a snippet keyword at the end.
struct TypingBuffer {
    private(set) var text = ""
    private let limit = 64

    mutating func type(_ characters: String) {
        text += characters
        if text.count > limit { text = String(text.suffix(limit)) }
    }

    mutating func deleteBackward() {
        if !text.isEmpty { text.removeLast() }
    }

    mutating func reset() {
        text = ""
    }

    /// The snippet whose keyword was just typed, if any. Keywords that start with a letter
    /// or digit only count at the start of a word, so "addr" doesn't fire inside "unaddressed".
    func match(in snippets: [Snippet]) -> Snippet? {
        for snippet in snippets.sorted(by: { $0.keyword.count > $1.keyword.count }) {
            let keyword = snippet.keyword
            guard !keyword.isEmpty, text.hasSuffix(keyword) else { continue }
            if let first = keyword.first, first.isLetter || first.isNumber {
                let before = text.dropLast(keyword.count).last
                if let before, before.isLetter || before.isNumber { continue }
            }
            return snippet
        }
        return nil
    }
}
