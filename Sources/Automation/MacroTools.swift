import AppKit
import Carbon

// Tools for the Macros window, like Keyboard Maestro's editor: copying and pasting steps, exporting
// and importing macros, the list of every shortcut in use, undo, and recording a macro by doing it.

// MARK: - New identities

extension MacroStep {
    /// The same step (and the steps inside it) as a new copy, so a pasted or imported step is its own.
    func renewingIDs() -> MacroStep {
        var copy = self
        copy.id = UUID()
        copy.steps = steps.map { $0.renewingIDs() }
        copy.elseSteps = elseSteps.map { $0.renewingIDs() }
        return copy
    }
}

// MARK: - Copying and pasting steps

enum StepClipboard {
    static let type = NSPasteboard.PasteboardType("local.personal.toolbelt.steps")

    /// Puts steps on the clipboard: as steps for pasting into a macro, and as plain text for anywhere else.
    static func copy(_ steps: [MacroStep], to pasteboard: NSPasteboard = .general) {
        guard let data = try? JSONEncoder().encode(steps) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        pasteboard.setString(steps.map(\.summary).joined(separator: "\n"), forType: .string)
    }

    /// The steps on the clipboard, as new copies (nil if there are none).
    static func paste(from pasteboard: NSPasteboard = .general) -> [MacroStep]? {
        guard let data = pasteboard.data(forType: type), let steps = try? JSONDecoder().decode([MacroStep].self, from: data) else { return nil }
        return steps.map { $0.renewingIDs() }
    }

    static var hasSteps: Bool { NSPasteboard.general.availableType(from: [type]) != nil }
}

// MARK: - Exporting and importing

/// Macros saved to a file (.toolbeltmacros) to keep, move to another Mac or share.
struct MacroTransfer: Codable {
    var format = 1
    var macros: [Macro]
    var groups: [MacroGroup]

    static let fileExtension = "toolbeltmacros"

    /// The chosen macros, with the groups they're in.
    static func export(_ macros: [Macro], groups: [MacroGroup]) -> Data? {
        let used = Set(macros.compactMap(\.groupID))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(MacroTransfer(macros: macros, groups: groups.filter { used.contains($0.id) }))
    }

    /// The macros in a file as new ones (new identities), and their groups: an existing group with the same
    /// name is used rather than making a second one. Nil if the file isn't a macros file.
    static func importing(_ data: Data, existingGroups: [MacroGroup]) -> (macros: [Macro], newGroups: [MacroGroup])? {
        guard let file = try? JSONDecoder().decode(MacroTransfer.self, from: data) else { return nil }
        var groupIDs: [UUID: UUID] = [:]
        var newGroups: [MacroGroup] = []
        for group in file.groups {
            if let existing = existingGroups.first(where: { $0.name.caseInsensitiveCompare(group.name) == .orderedSame }) {
                groupIDs[group.id] = existing.id
            } else {
                var copy = group
                copy.id = UUID()
                groupIDs[group.id] = copy.id
                newGroups.append(copy)
            }
        }
        let macros = file.macros.map { macro -> Macro in
            var copy = macro
            copy.id = UUID()
            copy.groupID = macro.groupID.flatMap { groupIDs[$0] }
            copy.triggers = macro.triggers.map { var trigger = $0; trigger.id = UUID(); return trigger }
            copy.steps = macro.steps.map { $0.renewingIDs() }
            return copy
        }
        return (macros, newGroups)
    }
}

// MARK: - Every shortcut in use

enum UsedShortcuts {
    struct Entry: Identifiable, Equatable {
        var id: String { keys + "|" + owner }
        let keys: String
        let owner: String
        let place: String
    }

    /// Every keyboard shortcut Toolbelt uses: its own commands, triggers and macros. Shortcuts that are
    /// the same keys are listed together.
    static func collect(commands: [(title: String, shortcut: Shortcut)], rules: [GestureRule], macros: [Macro]) -> [Entry] {
        var entries = commands.map { Entry(keys: $0.shortcut.display, owner: $0.title.capitalizedFirst, place: "Toolbelt command") }
        for rule in rules where rule.enabled {
            guard case let .shortcut(keyCode, modifiers) = rule.gesture, keyCode != 0 || modifiers != 0 else { continue }
            entries.append(Entry(keys: rule.gesture.title, owner: rule.hasNotes ? rule.notes ?? rule.summary : rule.summary, place: "Trigger"))
        }
        for macro in macros where macro.enabled {
            for trigger in macro.triggers where trigger.kind == .hotKey && (trigger.keyCode != 0 || trigger.modifiers != 0) {
                entries.append(Entry(keys: Shortcut(keyCode: trigger.keyCode, modifiers: trigger.modifiers).display,
                                     owner: macro.name, place: "Macro"))
            }
        }
        return entries.sorted { $0.keys == $1.keys ? $0.owner < $1.owner : $0.keys < $1.keys }
    }

    /// The keys used by more than one thing.
    static func clashes(_ entries: [Entry]) -> Set<String> {
        Set(Dictionary(grouping: entries, by: \.keys).filter { $0.value.count > 1 }.keys)
    }
}

// MARK: - Undo

/// The macros as they were before each change, for Undo and Redo in the Macros window.
struct UndoHistory<Value: Equatable> {
    private(set) var past: [Value] = []
    private(set) var future: [Value] = []
    var limit = 100

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// A change happened: `old` is how it was before.
    mutating func record(_ old: Value) {
        guard past.last != old else { return }
        past.append(old)
        if past.count > limit { past.removeFirst() }
        future = []
    }

    /// Goes back one change: returns what to show, given what's showing now.
    mutating func undo(from current: Value) -> Value? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(from current: Value) -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}

// MARK: - Recording

/// Turns what you did while recording into macro steps: typing becomes "Type text", shortcuts and
/// special keys "Press keys", clicks "Click at", switching apps "Open an app", and waits of more than
/// a second and a half become pauses.
struct RecordingBuilder {
    enum Event: Equatable {
        case typed(String)
        case keys(keyCode: Int, modifiers: Int)
        case click(button: Int, at: CGPoint, count: Int)
        case app(path: String)
    }

    private(set) var steps: [MacroStep] = []
    private var lastTime: Double?
    /// The longest pause written (seconds), and the shortest gap that counts as one.
    var longestPause = 30.0
    var pauseFrom = 1.5

    /// Keys that move or edit rather than type: recorded as key presses.
    static let specialKeys: Set<Int> = [kVK_Return, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
                                        kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_KeypadEnter]

    mutating func add(_ event: Event, at time: Double) {
        if let lastTime, time - lastTime >= pauseFrom {
            var pause = MacroStep(kind: .pause)
            pause.number = min(longestPause, ((time - lastTime) * 2).rounded() / 2)
            steps.append(pause)
        }
        lastTime = time
        switch event {
        case .typed(let text):
            // Typing carries on the text being typed.
            if let last = steps.last, last.kind == .action, last.action.kind == .typeText {
                steps[steps.count - 1].action.value += text
            } else {
                var step = MacroStep(kind: .action)
                step.action = MacroAction(kind: .typeText, value: text)
                steps.append(step)
            }
        case let .keys(keyCode, modifiers):
            var step = MacroStep(kind: .action)
            step.action = MacroAction(kind: .pressKeys, keyCode: keyCode, modifiers: modifiers)
            steps.append(step)
        case let .click(button, point, count):
            let kind: MouseCommand.Kind = button == 1 ? .rightClick : button == 2 ? .middleClick : count >= 2 ? .doubleClick : .click
            // The second click of a double-click replaces the single click just recorded.
            if kind == .doubleClick, let last = steps.last, last.kind == .action, last.action.kind == .mouse,
               MouseCommand(text: last.action.value).kind == .click {
                steps.removeLast()
            }
            var step = MacroStep(kind: .action)
            step.action = MacroAction(kind: .mouse, value: MouseCommand(kind: kind, at: point).text)
            steps.append(step)
        case .app(let path):
            var step = MacroStep(kind: .action)
            step.action = MacroAction(kind: .openApp, value: path)
            steps.append(step)
        }
    }

    /// A key press, as the event tap sees it: typing, a shortcut, or nothing (modifier keys alone).
    static func event(keyCode: Int, flags: CGEventFlags, characters: String?) -> Event? {
        let modifiers = ShortcutMatch.carbonModifiers(flags.rawValue)
        let commandOrControl = modifiers & (cmdKey | controlKey) != 0
        if !commandOrControl, !specialKeys.contains(keyCode), let characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
            return .typed(characters)
        }
        guard ModifierKey.side(forKeyCode: keyCode) == nil else { return nil }
        return .keys(keyCode: keyCode, modifiers: modifiers)
    }
}

/// Records what you do (keys, clicks, switching apps) into macro steps until you press ⌃⌥⌘. (full stop),
/// or `stop()` is called. Needs Input Monitoring.
@MainActor
final class MacroRecorder {
    static let stopKeys = "⌃⌥⌘."
    private var tap: (port: CFMachPort, source: CFRunLoopSource)?
    private var builder = RecordingBuilder()
    private var appObserver: NSObjectProtocol?
    private var finished: (([MacroStep]) -> Void)?

    var isRecording: Bool { tap != nil }

    @discardableResult
    func start(_ done: @escaping ([MacroStep]) -> Void) -> Bool {
        guard !isRecording, PermissionGate.ensure(.inputMonitoring, to: "record what you do into a macro") else { return false }
        builder = RecordingBuilder()
        finished = done
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask), callback: recorderCallback, userInfo: me),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = (port, source)
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                        queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let path = app?.bundleURL?.path, app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.builder.add(.app(path: path), at: ProcessInfo.processInfo.systemUptime) }
        }
        HUD.show("Recording", detail: "Do the task, then press \(Self.stopKeys) to stop.", symbol: "record.circle", seconds: 2.5)
        return true
    }

    /// Stops and hands over the steps.
    func stop() {
        guard let current = tap else { return }
        CGEvent.tapEnable(tap: current.port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), current.source, .commonModes)
        tap = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        let steps = builder.steps
        HUD.show("Recorded \(steps.count) step\(steps.count == 1 ? "" : "s")", symbol: "record.circle")
        finished?(steps)
        finished = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap.port, enable: true) }
            return
        }
        // Toolbelt's own key presses and clicks aren't you.
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard marker != GestureEventTap.ownEventMarker, marker != SnippetExpander.marker else { return }
        let time = Double(event.timestamp) / 1_000_000_000
        switch type {
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if keyCode == kVK_ANSI_Period, ShortcutMatch.carbonModifiers(flags.rawValue) == controlKey | optionKey | cmdKey {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.stop() } }
                return
            }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            let characters = length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
            if let recorded = RecordingBuilder.event(keyCode: keyCode, flags: flags, characters: characters) {
                builder.add(recorded, at: time)
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = type == .leftMouseDown ? 0 : type == .rightMouseDown ? 1 : Int(event.getIntegerValueField(.mouseEventButtonNumber))
            builder.add(.click(button: button, at: event.location, count: Int(event.getIntegerValueField(.mouseEventClickState))), at: time)
        default:
            break
        }
    }
}

private func recorderCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        let recorder = Unmanaged<MacroRecorder>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { recorder.handle(type, event) }
    }
    return Unmanaged.passUnretained(event)
}
