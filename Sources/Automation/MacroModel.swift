import AppKit

// Macros: triggers that start them, and the steps they run. Saved in
// ~/Library/Application Support/Toolbelt/macros.json.

/// A set of macros that can be switched on and off together, or limited to some apps.
struct MacroGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var scope: GestureRule.AppScope = .everywhere
    var apps: [String] = []

    func applies(in app: String?) -> Bool {
        GestureRule(gesture: .mouseButton(0), action: .toolbelt(.openLauncher), scope: scope, apps: apps).applies(in: app)
    }
}

struct Macro: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var groupID: UUID?
    var triggers: [MacroTrigger] = []
    var steps: [MacroStep] = []
}

/// What starts a macro.
struct MacroTrigger: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case hotKey, typedText, gesture, deviceKey
        case appLaunched, appQuit, appActivated, fileAdded
        case wifiChanged, networkChanged, displayConnected, displayDisconnected, spaceChanged
        case timeOfDay, every
        case menuBar, launcher, terminal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hotKey: return "Keyboard shortcut"
            case .typedText: return "Typed text"
            case .gesture: return "Gesture"
            case .deviceKey: return "Key on another keyboard or device"
            case .appLaunched: return "App opens"
            case .appQuit: return "App quits"
            case .appActivated: return "Switch to app"
            case .fileAdded: return "File added to a folder"
            case .wifiChanged: return "Wi-Fi network changes"
            case .networkChanged: return "Network connection changes"
            case .displayConnected: return "Display connected"
            case .displayDisconnected: return "Display disconnected"
            case .spaceChanged: return "Space (desktop) changes"
            case .timeOfDay: return "At a time of day"
            case .every: return "Repeatedly"
            case .menuBar: return "Menu bar item"
            case .launcher: return "Launcher"
            case .terminal: return "Command in Terminal"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// hotKey: the keys.
    var keyCode = 0
    var modifiers = 0
    /// typedText: the text; app triggers: bundle ID; fileAdded: folder; wifiChanged: network name
    /// (empty for any); deviceKey: the device's name.
    var text = ""
    var gesture: Gesture? = nil
    /// deviceKey: the key's HID usage. timeOfDay: minutes after midnight. every: minutes between runs.
    var number = 0
    /// timeOfDay: days of the week (1 = Sunday … 7 = Saturday); empty means every day.
    var weekdays: [Int] = []
    /// deviceKey: try to keep the device's keys from other apps.
    var exclusive = false

    var summary: String {
        switch kind {
        case .hotKey: return "Press \(Shortcut(keyCode: keyCode, modifiers: modifiers).display)"
        case .typedText: return "Type “\(text)”"
        case .gesture: return gesture?.title ?? "Gesture"
        case .deviceKey: return text.isEmpty ? "A key on another device" : "Key \(number) on \(text)"
        case .appLaunched: return "\(AppNames.name(of: text)) opens"
        case .appQuit: return "\(AppNames.name(of: text)) quits"
        case .appActivated: return "Switch to \(AppNames.name(of: text))"
        case .fileAdded: return "File added to \((text as NSString).abbreviatingWithTildeInPath)"
        case .wifiChanged: return text.isEmpty ? "Wi-Fi changes" : "Joined Wi-Fi “\(text)”"
        case .timeOfDay:
            let days = weekdays.isEmpty ? "every day" : weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[($0 - 1) % 7] }.joined(separator: ", ")
            return "At \(DownloadQueue.clock(number)), \(days)"
        case .every: return "Every \(number) minute\(number == 1 ? "" : "s")"
        default: return kind.title
        }
    }
}

/// One step of a macro. A flat struct (rather than an enum) so the editor can bind to every field.
struct MacroStep: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case action, script, pause, setVariable, setClipboard, textFilter, askInput, pickFromList, notify
        case ifThen, repeatTimes, repeatWhile, stop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .action: return "Do something"
            case .script: return "Run a script and keep its output"
            case .pause: return "Pause"
            case .setVariable: return "Set a variable"
            case .setClipboard: return "Set the clipboard"
            case .textFilter: return "Change text"
            case .askInput: return "Ask me for text"
            case .pickFromList: return "Ask me to pick from a list"
            case .notify: return "Show a notification"
            case .ifThen: return "If… then… otherwise…"
            case .repeatTimes: return "Repeat a number of times"
            case .repeatWhile: return "Repeat while…"
            case .stop: return "Stop the macro"
            }
        }

        var hasChildren: Bool { self == .ifThen || self == .repeatTimes || self == .repeatWhile }
    }

    var id = UUID()
    var kind: Kind
    var action: MacroAction = .toolbelt(.openLauncher)
    /// A variable's name (setVariable, textFilter, askInput, pickFromList, script output).
    var name = ""
    /// The main text: a value, prompt, message, script or find pattern.
    var text = ""
    /// A second text: the list to pick from, a replacement, a title, or where a count goes.
    var text2 = ""
    var number: Double = 1
    var filter: TextFilter = .uppercase
    var condition = MacroCondition()
    var steps: [MacroStep] = []
    var elseSteps: [MacroStep] = []

    /// In plain words, for the list.
    var summary: String {
        switch kind {
        case .action: return action.summary
        case .script: return "Run \(action.kind == .shell ? "shell script" : action.kind == .appleScript ? "AppleScript" : "JavaScript")" + (name.isEmpty ? "" : " → %\(name)%")
        case .pause: return "Pause \(number.formatted()) s"
        case .setVariable: return "%\(name)% = \(text)"
        case .setClipboard: return "Clipboard = \(text)"
        case .textFilter: return "\(filter.title) in %\(name)%"
        case .askInput: return "Ask “\(text)” → %\(name)%"
        case .pickFromList: return "Pick “\(text)” → %\(name)%"
        case .notify: return "Notify “\(text)”"
        case .ifThen: return "If \(condition.summary)"
        case .repeatTimes: return "Repeat \(Int(number)) times"
        case .repeatWhile: return "Repeat while \(condition.summary)"
        case .stop: return "Stop"
        }
    }
}

enum TextFilter: String, Codable, CaseIterable, Identifiable {
    case uppercase, lowercase, titleCase, trim, removeLineBreaks, findReplace, regexReplace
    case countCharacters, countWords, countLines, extractMatch, firstLine, removeFormatting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .trim: return "Trim spaces"
        case .removeLineBreaks: return "Remove line breaks"
        case .findReplace: return "Find and replace"
        case .regexReplace: return "Find and replace (pattern)"
        case .countCharacters: return "Count characters"
        case .countWords: return "Count words"
        case .countLines: return "Count lines"
        case .extractMatch: return "Keep only what matches a pattern"
        case .firstLine: return "Keep the first line"
        case .removeFormatting: return "Remove formatting"
        }
    }

    /// Applies the filter. `find` and `replace` are used by the find-and-replace and pattern filters.
    func apply(_ text: String, find: String = "", replace: String = "") -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .trim: return TextTransform.trimSpaces.apply(text).trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeLineBreaks: return TextTransform.removeLineBreaks.apply(text)
        case .findReplace: return find.isEmpty ? text : text.replacingOccurrences(of: find, with: replace)
        case .regexReplace:
            return (try? NSRegularExpression(pattern: find)).map {
                $0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replace)
            } ?? text
        case .countCharacters: return String(text.count)
        case .countWords: return String(text.split { $0.isWhitespace || $0.isNewline }.count)
        case .countLines: return String(text.isEmpty ? 0 : text.components(separatedBy: .newlines).count)
        case .extractMatch:
            guard let regex = try? NSRegularExpression(pattern: find),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return "" }
            // The first bracketed group if there is one, otherwise the whole match.
            let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
            return Range(range, in: text).map { String(text[$0]) } ?? ""
        case .firstLine: return text.components(separatedBy: .newlines).first ?? ""
        case .removeFormatting: return text
        }
    }

    var usesFind: Bool { [.findReplace, .regexReplace, .extractMatch].contains(self) }
    var usesReplace: Bool { self == .findReplace || self == .regexReplace }
}

struct MacroCondition: Codable, Equatable {
    enum Test: String, Codable, CaseIterable, Identifiable {
        case equals, notEquals, contains, notContains, isEmpty, isNotEmpty, matches, greaterThan, lessThan, frontAppIs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .equals: return "is"
            case .notEquals: return "is not"
            case .contains: return "contains"
            case .notContains: return "doesn't contain"
            case .isEmpty: return "is empty"
            case .isNotEmpty: return "is not empty"
            case .matches: return "matches the pattern"
            case .greaterThan: return "is more than"
            case .lessThan: return "is less than"
            case .frontAppIs: return "(the app in front) is"
            }
        }

        var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }
    }

    /// Usually a variable, like %Clipboard%.
    var left = "%Clipboard%"
    var test: Test = .contains
    var right = ""

    var summary: String {
        test == .frontAppIs ? "the app in front is \(right)" : "\(left) \(test.title)\(test.needsValue ? " “\(right)”" : "")"
    }

    /// `left` and `right` have already had their variables filled in.
    func isTrue(left: String, right: String, frontApp: String?) -> Bool {
        switch test {
        case .equals: return left == right
        case .notEquals: return left != right
        case .contains: return left.localizedCaseInsensitiveContains(right)
        case .notContains: return !left.localizedCaseInsensitiveContains(right)
        case .isEmpty: return left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .isNotEmpty: return !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .matches: return left.range(of: right, options: .regularExpression) != nil
        case .greaterThan: return (Double(left) ?? 0) > (Double(right) ?? 0)
        case .lessThan: return (Double(left) ?? 0) < (Double(right) ?? 0)
        case .frontAppIs:
            guard let frontApp else { return false }
            return frontApp == right || AppNames.name(of: frontApp).localizedCaseInsensitiveCompare(right) == .orderedSame
        }
    }
}

@MainActor
final class MacroStore: ObservableObject {
    @Published var macros: [Macro] = [] { didSet { if macros != oldValue { save(); onChange?() } } }
    @Published var groups: [MacroGroup] = [] { didSet { if groups != oldValue { save(); onChange?() } } }
    var onChange: (() -> Void)?
    private let file = SettingsStore.folder.appendingPathComponent("macros.json")

    private struct Saved: Codable {
        var macros: [Macro]
        var groups: [MacroGroup]
    }

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            macros = saved.macros
            groups = saved.groups
        }
    }

    func group(of macro: Macro) -> MacroGroup? {
        groups.first { $0.id == macro.groupID }
    }

    /// Whether a macro can run now: it and its group are on, and its group allows the app in front.
    func isActive(_ macro: Macro, in app: String?) -> Bool {
        guard macro.enabled else { return false }
        guard let group = group(of: macro) else { return true }
        return group.enabled && group.applies(in: app)
    }

    func macro(named name: String) -> Macro? {
        macros.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Macros whose name, triggers or steps mention the text.
    func search(_ text: String) -> [Macro] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return macros }
        func stepText(_ steps: [MacroStep]) -> String {
            steps.map { "\($0.summary) \($0.text) \($0.text2) \(stepText($0.steps)) \(stepText($0.elseSteps))" }.joined(separator: " ")
        }
        return macros.filter { macro in
            let haystack = ([macro.name] + macro.triggers.map(\.summary) + [stepText(macro.steps), group(of: macro)?.name ?? ""]).joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(Saved(macros: macros, groups: groups)).write(to: file, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save macros: \(error)")
        }
    }
}
