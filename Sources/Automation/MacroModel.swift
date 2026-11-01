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
    /// When it was last changed (for "Recently changed" in the Macros window).
    var modified: Date? = nil
}

/// Which macros the Macros window lists.
enum MacroListFilter: String, CaseIterable, Identifiable {
    case all, on, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .on: return "Switched on"
        case .recent: return "Recently changed"
        }
    }
}

/// Back and forward through the macros you've looked at, like a web browser.
struct SelectionHistory: Equatable {
    private(set) var items: [UUID] = []
    private(set) var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < items.count - 1 }

    /// Looking at a macro: going forward from here is forgotten.
    mutating func visit(_ id: UUID) {
        guard items.indices.contains(index) ? items[index] != id : true else { return }
        items = Array(items.prefix(index + 1)) + [id]
        if items.count > 100 { items.removeFirst() }
        index = items.count - 1
    }

    mutating func back() -> UUID? {
        guard canGoBack else { return nil }
        index -= 1
        return items[index]
    }

    mutating func forward() -> UUID? {
        guard canGoForward else { return nil }
        index += 1
        return items[index]
    }

    /// A macro that was deleted is taken out.
    mutating func remove(_ id: UUID) {
        let before = items.prefix(max(0, index + 1)).filter { $0 == id }.count
        items.removeAll { $0 == id }
        index = min(items.count - 1, index - before)
    }
}

/// What starts a macro.
struct MacroTrigger: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case hotKey, typedText, gesture, deviceKey
        case appLaunched, appQuit, appActivated, fileAdded
        case wifiChanged, networkChanged, displayConnected, displayDisconnected, spaceChanged
        case timeOfDay, every
        case menuBar, launcher, terminal
        case macWakes, macSleeps, screenLocked, screenUnlocked
        case powerConnected, powerDisconnected, batteryBelow
        case usbConnected, usbDisconnected, bluetoothConnected, bluetoothDisconnected, diskMounted, diskUnmounted
        case idle, activeAgain
        case clipboardChanged, toolbeltStarts, atLogin, windowChanged, windowTitleChanged, calledByMacro
        case clipboardFilter

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
            case .macWakes: return "Mac wakes up"
            case .macSleeps: return "Mac goes to sleep"
            case .screenLocked: return "Screen locks"
            case .screenUnlocked: return "Screen unlocks"
            case .powerConnected: return "Charger plugged in"
            case .powerDisconnected: return "Charger unplugged"
            case .batteryBelow: return "Battery goes below a level"
            case .usbConnected: return "USB device plugged in"
            case .usbDisconnected: return "USB device unplugged"
            case .bluetoothConnected: return "Bluetooth device connects"
            case .bluetoothDisconnected: return "Bluetooth device disconnects"
            case .diskMounted: return "Disk appears (plugged in or opened)"
            case .diskUnmounted: return "Disk ejected"
            case .idle: return "Not used for a while (idle)"
            case .activeAgain: return "Used again after being idle"
            case .clipboardChanged: return "Clipboard changes"
            case .toolbeltStarts: return "Toolbelt starts"
            case .atLogin: return "At login"
            case .windowChanged: return "Front window changes"
            case .windowTitleChanged: return "Front window's title changes"
            case .calledByMacro: return "Run by another macro"
            case .clipboardFilter: return "Clipboard history: run on an item"
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

    /// A new trigger of this kind with sensible starting values.
    static func starting(_ kind: Kind) -> MacroTrigger {
        var trigger = MacroTrigger(kind: kind, gesture: kind == .gesture ? .touch(.trackpad, .tap, fingers: 3) : nil)
        if kind == .batteryBelow { trigger.number = 20 }
        if kind == .idle || kind == .activeAgain { trigger.number = 5 }
        return trigger
    }

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
        case .batteryBelow: return "Battery below \(number)%"
        case .idle, .activeAgain:
            return kind == .idle ? "Idle for \(number) minute\(number == 1 ? "" : "s")" : "Used again after \(number) idle minute\(number == 1 ? "" : "s")"
        case .usbConnected, .usbDisconnected, .bluetoothConnected, .bluetoothDisconnected, .diskMounted, .diskUnmounted:
            return text.isEmpty ? kind.title : kind.title + " (“\(text)”)"
        case .clipboardChanged: return text.isEmpty ? "Clipboard changes" : "Copied text containing “\(text)”"
        case .windowChanged: return text.isEmpty ? kind.title : "Front window changes (title contains “\(text)”)"
        case .windowTitleChanged: return text.isEmpty ? kind.title : "Front window's title changes to one containing “\(text)”"
        default: return kind.title
        }
    }
}

enum StepColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }
    var title: String { rawValue.capitalizedFirst }
}

enum FailureMode: String, Codable, CaseIterable, Identifiable {
    /// Carry on with the next step (the default).
    case carryOn
    /// Stop the macro.
    case stop
    /// Stop the macro and show a notification saying which step failed.
    case stopAndNotify

    var id: String { rawValue }
    var title: String {
        switch self {
        case .carryOn: return "Carry on"
        case .stop: return "Stop the macro"
        case .stopAndNotify: return "Stop the macro and tell me"
        }
    }
}

/// One step of a macro. A flat struct (rather than an enum) so the editor can bind to every field.
struct MacroStep: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case action, script, pause, setVariable, setClipboard, textFilter, askInput, pickFromList, notify
        case ifThen, repeatTimes, repeatWhile, stop
        case pauseUntil
        case readFile, browserGet, alert, askFolder, askFile, askSeveral
        case calculate, pictureFilter, runMacro

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
            case .pauseUntil: return "Pause until…"
            case .readFile: return "Read a text file"
            case .browserGet: return "Get the page's address, title or text (Safari / Chrome)"
            case .alert: return "Show an alert with buttons"
            case .askFolder: return "Ask me to choose a folder"
            case .askFile: return "Ask me to choose a file"
            case .askSeveral: return "Ask me several things at once"
            case .calculate: return "Calculate"
            case .pictureFilter: return "Change the clipboard's picture"
            case .runMacro: return "Run another macro and wait for it"
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
    /// Switched off: skipped when the macro runs (kept, like Keyboard Maestro's "Disable Action").
    var disabled: Bool? = nil
    /// Your own note about the step, and a colour to pick it out.
    var note: String? = nil
    var color: StepColor? = nil
    /// Scripts: seconds to wait before giving up (nil: no limit). Pause until: how long to wait (nil: a minute).
    var timeout: Double? = nil
    /// What happens when the step fails (a script ending with an error, or running out of time).
    var onFailure: FailureMode? = nil
    /// Change the clipboard's picture: which change.
    var picture: PictureFilter? = nil

    var isOn: Bool { disabled != true }

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
        case .pauseUntil: return "Pause until \(condition.summary)"
        case .readFile: return "Read \((text as NSString).lastPathComponent) → %\(name)%"
        case .browserGet: return "Get the page's \(BrowserPart(rawValue: text2)?.title ?? "address") → %\(name)%"
        case .alert: return "Alert “\(text.prefix(30))” → %\(name)%"
        case .askFolder: return "Choose a folder → %\(name)%"
        case .askFile: return "Choose a file → %\(name)%"
        case .calculate: return "%\(name.isEmpty ? "Result" : name)% = \(text)"
        case .pictureFilter:
            let filter = picture ?? .flipHorizontal
            return filter == .readText ? "Read the clipboard picture's text → %\(name.isEmpty ? "Text" : name)%" : "Clipboard picture: \(filter.title)"
        case .runMacro: return "Run macro “\(text)”" + (name.isEmpty ? "" : " → %\(name)%")
        case .askSeveral: return "Ask \(MacroRun.fields(text2).map { "%\(MacroRun.variableName(for: $0))%" }.joined(separator: ", "))"
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
        case windowTitleContains, appRunning, appNotRunning, fileExists, fileMissing, modifiersHeld
        case pixelColorIs, screenShows, screenDoesNotShow

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
            case .windowTitleContains: return "(the front window's title) contains"
            case .appRunning: return "(this app) is running"
            case .appNotRunning: return "(this app) is not running"
            case .fileExists: return "(this file or folder) exists"
            case .fileMissing: return "(this file or folder) doesn't exist"
            case .modifiersHeld: return "(these keys) are held down"
            case .pixelColorIs: return "(the screen at x,y) has the colour"
            case .screenShows: return "(the screen) shows the picture"
            case .screenDoesNotShow: return "(the screen) doesn't show the picture"
            }
        }

        var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }

        /// Whether the left field is used: tests about the Mac (the app in front, running apps, keys,
        /// the screen) have no "left" text, except the point for a pixel's colour.
        var usesLeft: Bool {
            switch self {
            case .frontAppIs, .windowTitleContains, .appRunning, .appNotRunning, .modifiersHeld, .screenShows, .screenDoesNotShow: return false
            default: return true
            }
        }

        /// Whether the answer depends on the screen (needs Screen Recording).
        var readsScreen: Bool { self == .pixelColorIs || self == .screenShows || self == .screenDoesNotShow }

        var leftPlaceholder: String {
            switch self {
            case .fileExists, .fileMissing: return "Path, e.g. ~/Desktop/report.pdf"
            case .pixelColorIs: return "x,y from the top left, e.g. 200,300"
            default: return "Text or %Variable%"
            }
        }

        var rightPlaceholder: String {
            switch self {
            case .frontAppIs, .appRunning, .appNotRunning: return "App name"
            case .windowTitleContains: return "Part of the title"
            case .modifiersHeld: return "e.g. ⌘⌥ or command option"
            case .pixelColorIs: return "Colour, e.g. #FF8800"
            case .screenShows, .screenDoesNotShow: return "Picture file (PNG)"
            default: return "Value"
            }
        }
    }

    /// Usually a variable, like %Clipboard%.
    var left = "%Clipboard%"
    var test: Test = .contains
    var right = ""

    var summary: String {
        switch test {
        case .frontAppIs: return "the app in front is \(right)"
        case .windowTitleContains: return "the front window's title contains “\(right)”"
        case .appRunning: return "\(right) is running"
        case .appNotRunning: return "\(right) is not running"
        case .fileExists: return "\(left) exists"
        case .fileMissing: return "\(left) doesn't exist"
        case .modifiersHeld: return "\(ModifierNames.display(ModifierNames.parse(right))) held down"
        case .pixelColorIs: return "the screen at \(left) is \(right)"
        case .screenShows: return "the screen shows \((right as NSString).lastPathComponent)"
        case .screenDoesNotShow: return "the screen doesn't show \((right as NSString).lastPathComponent)"
        default: return "\(left) \(test.title)\(test.needsValue ? " “\(right)”" : "")"
        }
    }

    /// `left` and `right` have already had their variables filled in. Only the text tests and the app in front.
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
            return Self.sameApp(frontApp, right)
        default: return false
        }
    }

    /// Every test, asking `world` about the Mac when the test needs it.
    func isTrue(left: String, right: String, world: ConditionWorld) async -> Bool {
        switch test {
        case .windowTitleContains:
            guard let title = world.windowTitle() else { return false }
            return right.isEmpty || title.localizedCaseInsensitiveContains(right)
        case .appRunning, .appNotRunning:
            let running = world.runningApps().contains { Self.sameApp($0, right) }
            return running == (test == .appRunning)
        case .fileExists, .fileMissing:
            let exists = !left.isEmpty && world.fileExists((left as NSString).expandingTildeInPath)
            return exists == (test == .fileExists)
        case .modifiersHeld:
            let wanted = ModifierNames.parse(right)
            return !wanted.isEmpty && world.modifiers().intersection(ModifierNames.all).isSuperset(of: wanted)
        case .pixelColorIs:
            guard let point = ScreenPoint.parse(left), let wanted = RGBColor(hex: right) else { return false }
            let seen = await world.pixel(point)
            return seen.contains { $0.isClose(to: wanted) }
        case .screenShows, .screenDoesNotShow:
            let path = (right as NSString).expandingTildeInPath
            guard !path.isEmpty else { return false }
            let found = await world.findOnScreen(path) != nil
            return found == (test == .screenShows)
        default:
            return isTrue(left: left, right: right, frontApp: world.frontApp())
        }
    }

    /// `app` is a bundle ID or an app's name; `wanted` is either.
    static func sameApp(_ app: String, _ wanted: String) -> Bool {
        app == wanted || app.localizedCaseInsensitiveCompare(wanted) == .orderedSame
            || AppNames.name(of: app).localizedCaseInsensitiveCompare(wanted) == .orderedSame
    }
}

@MainActor
final class MacroStore: ObservableObject {
    @Published var macros: [Macro] = [] {
        didSet {
            guard macros != oldValue else { return }
            if !stamping {
                let stamped = Self.stamped(macros, comparedWith: oldValue, now: Date())
                if stamped != macros {
                    stamping = true
                    macros = stamped
                    stamping = false
                    return // the assignment above saved
                }
            }
            save()
            onChange?()
        }
    }
    private var stamping = false

    /// `macros` with `modified` set to now on each one that's new or changed since `old`.
    nonisolated static func stamped(_ macros: [Macro], comparedWith old: [Macro], now: Date) -> [Macro] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return macros.map { macro in
            var current = macro, previous = before[macro.id]
            current.modified = nil
            previous?.modified = nil
            var result = macro
            if previous != current { result.modified = now }
            return result
        }
    }

    /// The macros a list shows: all, the ones switched on (and in a switched-on group), or the 20 changed last.
    func listed(_ filter: MacroListFilter, matching text: String) -> [Macro] {
        let found = search(text)
        switch filter {
        case .all: return found
        case .on: return found.filter { $0.enabled && (group(of: $0)?.enabled ?? true) }
        case .recent:
            return Array(found.filter { $0.modified != nil }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(20))
        }
    }
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
