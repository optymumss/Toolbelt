import AppKit
import Carbon

// Real-use tests: starts the real Toolbelt app, then uses it the way a person would: presses
// shortcuts, holds keys, taps modifier keys, types, clicks and drags with the mouse, and sends
// pretend trackpad touches (GitHub's Macs have no trackpad). After each one it checks that the
// trigger really ran its action: a line written to a file, text typed into this app's window,
// this window moving, a Toolbelt panel opening, a screenshot saved…
//
// Run by .github/scripts/real-use.sh, which builds this into ToolbeltE2E.app, gives it and
// Toolbelt the permissions they need, and opens it with:
//   <data folder> <Toolbelt.app> <results file> real-use|stability [minutes]
// It's compiled with all of Toolbelt's sources (except App.swift), so it saves settings and
// triggers with Toolbelt's own types, exactly as Settings and the Triggers window would.

@main
enum RealUseMain {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") })
        guard args.count >= 4 else {
            print("Usage: ToolbeltE2E <data folder> <Toolbelt.app> <results file> real-use|stability [minutes]")
            exit(2)
        }
        // Before anything reads SettingsStore: everything goes to the scratch data folder.
        setenv("TOOLBELT_DATA_DIR", args[0], 1)
        let app = NSApplication.shared
        let delegate = RealUse(data: URL(fileURLWithPath: args[0]), toolbelt: URL(fileURLWithPath: args[1]),
                               results: URL(fileURLWithPath: args[2]), mode: args[3],
                               minutes: args.count > 4 ? Double(args[4]) ?? 20 : 20)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class RealUse: NSObject, NSApplicationDelegate {
    let data: URL
    let toolbeltURL: URL
    let resultsURL: URL
    let mode: String
    let minutes: Double
    var markersURL: URL { data.appendingPathComponent("markers.txt") }
    var shotsFolder: URL { data.appendingPathComponent("Screenshots", isDirectory: true) }

    var window: NSWindow!
    var textView: NSTextView!
    var pad: InputPad!
    var toolbelt: NSRunningApplication?
    var passed = 0
    var failed = 0
    var lines: [String] = []

    init(data: URL, toolbelt: URL, results: URL, mode: String, minutes: Double) {
        self.data = data
        self.toolbeltURL = toolbelt
        self.resultsURL = results
        self.mode = mode
        self.minutes = minutes
    }

    /// Web addresses opened with the toolbelte2e: scheme (the web-search action's test search site).
    var openedURLs: [String] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        if let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue { openedURLs.append(text) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        Task { @MainActor in
            await self.runAll()
            self.finish()
        }
    }

    // MARK: - Results

    func say(_ text: String) {
        print(text)
        lines.append(text)
        try? (lines.joined(separator: "\n") + "\n").write(to: resultsURL, atomically: true, encoding: .utf8)
    }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            say("✓ \(name)")
        } else {
            failed += 1
            let more = detail()
            say("✗ \(name)" + (more.isEmpty ? "" : " — \(more)"))
        }
    }

    func finish() {
        if let toolbelt, !toolbelt.isTerminated {
            toolbelt.terminate()
        }
        say("")
        say("RESULT: \(passed) passed, \(failed) failed")
        say(failed == 0 ? "STATUS: ok" : "STATUS: failed")
        NSApp.terminate(nil)
    }

    // MARK: - Waiting

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits until the condition is true (checking ten times a second); returns whether it became true.
    func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            await pause(0.1)
        }
        return condition()
    }

    // MARK: - Markers (what the test triggers' shell actions write)

    func markers() -> [String] {
        guard let text = try? String(contentsOf: markersURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func count(_ name: String) -> Int { markers().filter { $0 == name }.count }

    /// A shell action that writes `name` as a line in the markers file.
    func mark(_ name: String) -> MacroAction {
        MacroAction(kind: .shell, value: "echo \(name) >> '\(markersURL.path)'")
    }

    // MARK: - This app's window (the "app in front" that keys are typed into)

    func makeWindow() {
        // Like every real app, an Edit menu: without it ⌘V (how Toolbelt pastes) does nothing.
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Toolbelt real-use test"
        // A pad along the bottom that notes every click, scroll and drag (for the mouse actions).
        pad = InputPad(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        pad.autoresizingMask = [.width]
        window.contentView?.addSubview(pad)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 120, width: 640, height: 300))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 15)
        scroll.documentView = textView
        window.contentView?.addSubview(scroll)
        window.center()
        homeFrame = window.frame
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Where the window starts; it's put back exactly here after the window-moving tests (the mouse
    /// actions' places are worked out from it).
    var homeFrame = NSRect.zero

    /// Brings this app and its text box to the front, and empties the text box.
    func focus(clear: Bool = true) async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        if clear { textView.string = "" }
        _ = await waitUntil(3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
        await pause(0.2)
    }

    var isFront: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }

    // MARK: - Pretend input

    let source = CGEventSource(stateID: .hidSystemState)

    struct Mod {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
        let side: UInt64
        static let leftCommand = Mod(keyCode: 55, flag: .maskCommand, side: 0x08)
        static let rightCommand = Mod(keyCode: 54, flag: .maskCommand, side: 0x10)
        static let leftOption = Mod(keyCode: 58, flag: .maskAlternate, side: 0x20)
        static let rightOption = Mod(keyCode: 61, flag: .maskAlternate, side: 0x40)
        static let leftControl = Mod(keyCode: 59, flag: .maskControl, side: 0x01)
        static let leftShift = Mod(keyCode: 56, flag: .maskShift, side: 0x02)
    }

    /// ⌃⌥⇧: no Toolbelt or macOS shortcut uses it with these keys (⌃⌥⌘ + digits are saved layouts).
    static let testMods: [Mod] = [.leftControl, .leftOption, .leftShift]
    static let ctrlOpt: [Mod] = [.leftControl, .leftOption]

    func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    func keyEvent(_ code: CGKeyCode, down: Bool, flags: UInt64, character: String? = nil) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        // A real keyboard marks the arrow keys (and Home, End, Page Up/Down) as "fn" and "keypad" keys.
        let special: Set<CGKeyCode> = [123, 124, 125, 126, 115, 116, 119, 121]
        event.flags = CGEventFlags(rawValue: flags | (special.contains(code) ? CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskNumericPad.rawValue : 0))
        if let character {
            let units = Array(character.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        post(event)
    }

    func flagsEvent(_ code: CGKeyCode, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: flags)
        post(event)
    }

    /// Presses a key with modifier keys held: modifiers go down one by one, the key is held for
    /// `hold` seconds, then everything is let go (the key first, then the modifiers).
    func press(_ code: CGKeyCode, _ mods: [Mod], hold: Double = 0.05, character: String? = nil, betweenUpAndModifiers: Double = 0.05) async {
        var flags: UInt64 = 0
        for mod in mods {
            flags |= mod.flag.rawValue | mod.side
            flagsEvent(mod.keyCode, flags: flags)
            await pause(0.02)
        }
        keyEvent(code, down: true, flags: flags, character: character)
        await pause(hold)
        keyEvent(code, down: false, flags: flags, character: character)
        await pause(betweenUpAndModifiers)
        for mod in mods.reversed() {
            flags &= ~mod.side
            // The ⌘/⌥/⌃/⇧ flag stays while the other side's key of the same kind is still down.
            if !mods.contains(where: { $0.flag == mod.flag && $0.side != mod.side && flags & $0.side != 0 }) {
                flags &= ~mod.flag.rawValue
            }
            flagsEvent(mod.keyCode, flags: flags)
            await pause(0.02)
        }
    }

    /// Taps a modifier key on its own (down and straight up).
    func tapModifier(_ mod: Mod) async {
        flagsEvent(mod.keyCode, flags: mod.flag.rawValue | mod.side)
        await pause(0.06)
        flagsEvent(mod.keyCode, flags: 0)
    }

    static let keyCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        ";": 41, "n": 45, "m": 46, ".": 47, " ": 49,
    ]

    /// Types text (lower-case letters, digits, ; . and spaces) key by key, like a person.
    func type(_ text: String) async {
        for character in text {
            guard let code = Self.keyCodes[character] else { continue }
            keyEvent(code, down: true, flags: 0, character: String(character))
            await pause(0.03)
            keyEvent(code, down: false, flags: 0, character: String(character))
            await pause(0.05)
        }
    }

    /// The middle of this app's window, in the screen coordinates mouse events use (top-left origin).
    var windowMiddle: CGPoint {
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.midX, y: screenHeight - frame.midY)
    }

    func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, number: Int64? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if let number { event.setIntegerValueField(.mouseEventButtonNumber, value: number) }
        post(event)
    }

    /// Pretend trackpad touches, sent to Toolbelt (which only accepts them in test mode).
    func touches(_ frames: [(time: Double, touches: [TouchPoint])]) {
        DistributedNotificationCenter.default().postNotificationName(RealUseHooks.touchNotification, object: RealUseHooks.framesText(frames),
                                                                     userInfo: nil, deliverImmediately: true)
    }

    /// Fingers held at `points` from `start` for `duration` (a frame every 10 ms), moving by `move` in total.
    func fingers(_ points: [(Double, Double)], start: Double, duration: Double, move: (Double, Double) = (0, 0)) -> [(time: Double, touches: [TouchPoint])] {
        let steps = max(2, Int(duration / 0.01))
        return (0...steps).map { step in
            let progress = Double(step) / Double(steps)
            let touches = points.enumerated().map { index, point in
                TouchPoint(id: index + 1, x: point.0 + move.0 * progress, y: point.1 + move.1 * progress)
            }
            return (start + duration * progress, touches)
        }
    }

    /// Sends a touch, waits, then lifts the fingers (as separate frames, like a real trackpad).
    func touch(_ points: [(Double, Double)], duration: Double, move: (Double, Double) = (0, 0)) async {
        let start = ProcessInfo.processInfo.systemUptime
        touches(fingers(points, start: start, duration: duration, move: move))
        await pause(0.3)
        touches([(start + duration + 0.01, [])])
        await pause(0.2)
    }

    // MARK: - Toolbelt's windows

    /// Toolbelt's windows on screen now (not its menu bar icon).
    func toolbeltWindows() -> Int {
        guard let pid = toolbelt?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return list.filter { info in
            (info[kCGWindowOwnerPID as String] as? Int32) == pid && (info[kCGWindowLayer as String] as? Int ?? 0) != 25
                && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }.count
    }

    var toolbeltRSS: Int? {
        guard let pid = toolbelt?.processIdentifier else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) // kilobytes
    }

    // MARK: - Setting Toolbelt up

    static let webPort = 12399
    static let webSecret = "e2e-secret-4821"
    static let frontCondition = ConditionGroup(mode: .all, items: [.rule(ConditionRule(field: .appID, op: .is, value: "local.toolbelt.e2e"))])
    let workPreset = TriggerPreset(name: "Work")
    let frontGroup = ActivationGroup(name: "Test app in front", condition: RealUse.frontCondition)
    let neverGroup = ActivationGroup(name: "Never", condition: ConditionGroup(mode: .all, items: [.rule(ConditionRule(field: .appName, op: .is, value: "No such app"))]))

    func rule(_ gesture: Gesture, _ action: MacroAction, _ change: (inout GestureRule) -> Void = { _ in }) -> GestureRule {
        var rule = GestureRule(gesture: gesture, action: action)
        change(&rule)
        return rule
    }

    func place(_ point: CGPoint) -> String { "\(Int(point.x)),\(Int(point.y))" }

    func mouseAction(_ command: String, _ point: CGPoint) -> MacroAction {
        MacroAction(kind: .mouse, value: "\(command) \(place(point))")
    }

    /// A point across the middle of the pad (0 = left end, 1 = right end), in mouse-event coordinates (top left).
    func padPoint(_ across: CGFloat) -> CGPoint {
        let frame = window.convertToScreen(pad.convert(pad.bounds, to: nil))
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: (frame.minX + frame.width * across).rounded(), y: (screenHeight - frame.midY).rounded())
    }

    func shortcut(_ code: Int, _ modifiers: Int = controlKey | optionKey | shiftKey) -> Gesture {
        .shortcut(keyCode: code, modifiers: modifiers)
    }

    func writeSetup() throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shotsFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markersURL)

        let rules: [GestureRule] = [
            // A plain shortcut (macOS's own hot keys).
            rule(shortcut(kVK_ANSI_1), mark("plain")),
            // A shortcut with actions for every other moment (Toolbelt watches the keys itself).
            rule(shortcut(kVK_ANSI_2), mark("b-down")) {
                $0.phaseActions = [.release: [mark("b-release")], .longHold: [mark("b-long")], .quickRelease: [mark("b-quick")],
                                   .releaseAfterLongHold: [mark("b-afterlong")], .modifiersReleased: [mark("b-mods")]]
            },
            // Repeats while held.
            rule(shortcut(kVK_ANSI_3), mark("c-repeat")) {
                $0.repeatWhileHeld = true
                $0.repeatRate = 10
                $0.repeatDelay = 0.2
            },
            // Only with the right ⌘ key (and either ⌥).
            rule(shortcut(kVK_ANSI_4, cmdKey | optionKey), mark("d-right")) {
                $0.distinguishSides = true
                $0.sideFlags = ShortcutMatch.rightCommand
            },
            // Follows the keyboard layout: recorded as the letter k, whatever key that is.
            rule(shortcut(kVK_F3), mark("e-layout")) {
                $0.followLayout = true
                $0.keyCharacter = "k"
            },
            // Two rules for the same keys: the one whose condition is true wins.
            rule(shortcut(kVK_ANSI_5), mark("f-general")),
            rule(shortcut(kVK_ANSI_5), mark("f-specific")) { $0.condition = RealUse.frontCondition },
            // Activation groups: one whose conditions are true, one whose never are.
            rule(shortcut(kVK_ANSI_6), mark("g-group")) { $0.groupID = self.frontGroup.id },
            rule(shortcut(kVK_ANSI_7), mark("h-never")) { $0.groupID = self.neverGroup.id },
            // A trigger running a Toolbelt command: move the window in front to the right half.
            rule(shortcut(kVK_ANSI_9), .toolbelt(.window(.rightHalf))),
            // Keys and mouse.
            rule(.modifierTap(.option, taps: 2), mark("optdouble")),
            rule(.keySequence("qqz"), mark("typed")) { $0.deleteTyped = false },
            rule(.mouseButton(3), mark("button4")),
            rule(.stroke(button: 1, path: "L"), mark("strokeL")),
            // Trackpad (pretend touches).
            rule(.touch(.trackpad, .tap, fingers: 3), mark("tap3")),
            rule(.touch(.trackpad, .swipeLeft, fingers: 4), mark("swipe4")),
            rule(.touch(.trackpad, .longTouch, fingers: 2), mark("long2")) { $0.phaseActions = [.release: [mark("lift2")]] },
            // 0.26: more trackpad gestures, the mouse wheel, screen corners and the Hyper key.
            rule(.touch(.trackpad, .rotateRight, fingers: 2), mark("rotate")),
            rule(.touch(.trackpad, .edgeSwipeFromRight, fingers: 2), mark("edge")),
            rule(.touch(.trackpad, .swipeLeft, fingers: 2), mark("plainswipe")),
            rule(.touch(.trackpad, .tipSwipeRight, fingers: 3), mark("tipswipe")),
            rule(.wheel(button: 0, direction: "L"), mark("tilt")),
            rule(.wheel(button: 2, direction: "U"), mark("middlescroll")),
            rule(.screenSpot(.topLeft), mark("corner")),
            rule(shortcut(kVK_ANSI_1, controlKey | optionKey | shiftKey | cmdKey), mark("hyper")),
            // 0.27: actions. Places are on the test window's pad (worked out now; the window is put back here after moving).
            rule(shortcut(kVK_ANSI_A), mouseAction("click", padPoint(0.2))),
            rule(shortcut(kVK_ANSI_S), mouseAction("doubleClick", padPoint(0.4))),
            rule(shortcut(kVK_ANSI_D), mouseAction("rightClick", padPoint(0.5))),
            rule(shortcut(kVK_ANSI_F), mouseAction("middleClick", padPoint(0.6))),
            rule(shortcut(kVK_ANSI_G), MacroAction(kind: .mouse, value: "scrollDown 3")),
            rule(shortcut(kVK_ANSI_H), MacroAction(kind: .mouse, value: "drag \(place(padPoint(0.2))) \(place(padPoint(0.8)))")),
            rule(shortcut(kVK_ANSI_J), mouseAction("moveTo", CGPoint(x: 77, y: 155))),
            rule(shortcut(kVK_ANSI_L), MacroAction(kind: .webSearch, value: "toolbelte2e://search?q=%s")),
            rule(shortcut(kVK_ANSI_Z), .system(.ejectDisks)),
            rule(shortcut(kVK_ANSI_X), .system(.toggleDockHiding)),
            rule(shortcut(kVK_ANSI_C), mark("trashpressed")) { $0.moreActions = [.system(.emptyTrash)] },
            // 0.28: presets, a floating menu.
            rule(shortcut(kVK_ANSI_Q), mark("work")) { $0.presetID = self.workPreset.id },
            rule(shortcut(kVK_ANSI_W), MacroAction(kind: .switchPreset, value: "Work")),
            rule(shortcut(kVK_ANSI_E), MacroAction(kind: .floatingMenu, value: "Test menu")),
        ]
        try JSONEncoder().encode([workPreset]).write(to: data.appendingPathComponent("presets.json"), options: .atomic)
        Prefs.activePreset = nil
        let menu = FloatingMenu(name: "Test menu", buttons: [FloatingButton(title: "Press me", actions: [mark("floatbutton")])],
                                x: 300, y: 250, columns: 1, closeAfterClick: true)
        let item = MenuBarItem(title: "E2E", script: "echo E2E-$((6*7))", every: 5, actions: [mark("menubar")])
        try JSONEncoder().encode(PanelStore.Saved(menus: [menu], menuBarItems: [item]))
            .write(to: data.appendingPathComponent("panels.json"), options: .atomic)
        try JSONEncoder().encode(rules).write(to: data.appendingPathComponent("gestures.json"), options: .atomic)
        try JSONEncoder().encode([frontGroup, neverGroup]).write(to: data.appendingPathComponent("trigger-groups.json"), options: .atomic)

        // A macro with a shortcut, a variable, an if/otherwise and typing; one the web server runs.
        var setVariable = MacroStep(kind: .setVariable)
        setVariable.name = "answer"
        setVariable.text = "ok-42"
        var ifThen = MacroStep(kind: .ifThen)
        ifThen.condition.left = "%answer%"
        ifThen.condition.test = .contains
        ifThen.condition.right = "42"
        var then = MacroStep(kind: .action)
        then.action = mark("macro-then")
        var otherwise = MacroStep(kind: .action)
        otherwise.action = mark("macro-else")
        ifThen.steps = [then]
        ifThen.elseSteps = [otherwise]
        var typeStep = MacroStep(kind: .action)
        typeStep.action = MacroAction(kind: .typeText, value: "Typed by a macro")
        var hotKey = MacroTrigger(kind: .hotKey)
        hotKey.keyCode = kVK_ANSI_8
        hotKey.modifiers = controlKey | optionKey | shiftKey
        let macro = Macro(name: "Test macro", triggers: [hotKey], steps: [setVariable, ifThen, typeStep])
        var webStep = MacroStep(kind: .action)
        webStep.action = mark("web")
        let webMacro = Macro(name: "Test web", steps: [webStep])
        struct SavedMacros: Codable { var macros: [Macro]; var groups: [MacroGroup] }
        // 0.26: the Mac's own events.
        func eventMacro(_ name: String, _ kind: MacroTrigger.Kind, text: String = "", number: Int = 0) -> Macro {
            var trigger = MacroTrigger(kind: kind)
            trigger.text = text
            trigger.number = number
            var step = MacroStep(kind: .action)
            step.action = mark(name)
            return Macro(name: "Test \(name)", triggers: [trigger], steps: [step])
        }
        let eventMacros = [
            eventMacro("locked", .screenLocked), eventMacro("unlocked", .screenUnlocked),
            eventMacro("diskin", .diskMounted, text: "ToolbeltTest"), eventMacro("diskout", .diskUnmounted, text: "ToolbeltTest"),
            eventMacro("otherdisk", .diskMounted, text: "Something else"),
            eventMacro("idle", .idle, number: 1), eventMacro("back", .activeAgain, number: 1),
        ]
        // 0.29: a script that runs out of time (stops the macro), one that fails (carries on), and a step switched off.
        var slow = MacroStep(kind: .script)
        slow.action = MacroAction(kind: .shell, value: "sleep 5")
        slow.timeout = 1
        slow.onFailure = .stop
        var afterTimeout = MacroStep(kind: .action)
        afterTimeout.action = mark("after-timeout")
        var failing = MacroStep(kind: .script)
        failing.action = MacroAction(kind: .shell, value: "exit 3")
        var afterError = MacroStep(kind: .action)
        afterError.action = mark("after-error")
        var switchedOff = MacroStep(kind: .action)
        switchedOff.action = mark("switched-off")
        switchedOff.disabled = true
        let timeoutMacro = Macro(name: "Test timeout", steps: [slow, afterTimeout])
        let errorMacro = Macro(name: "Test error", steps: [failing, afterError, switchedOff])
        // 0.30: new triggers, “Pause until” and conditions about the Mac.
        func markStep(_ name: String) -> MacroStep {
            var step = MacroStep(kind: .action)
            step.action = mark(name)
            return step
        }
        func when(_ test: MacroCondition.Test, _ left: String = "", right: String = "", yes: String, no: String) -> MacroStep {
            var step = MacroStep(kind: .ifThen)
            step.condition = MacroCondition(left: left, test: test, right: right)
            step.steps = [markStep(yes)]
            step.elseSteps = [markStep(no)]
            return step
        }
        var copied = eventMacro("copied", .clipboardChanged, text: "e2e-copy")
        var copyAgain = MacroStep(kind: .setClipboard)
        copyAgain.text = "e2e-copy made by the macro"
        copied.steps.append(copyAgain) // its own copy mustn't start it again
        var waitForFile = MacroStep(kind: .pauseUntil)
        waitForFile.condition = MacroCondition(left: data.appendingPathComponent("go.txt").path, test: .fileExists)
        waitForFile.timeout = 15
        var waitTooLong = MacroStep(kind: .pauseUntil)
        waitTooLong.condition = MacroCondition(left: "/no/such/file", test: .fileExists)
        waitTooLong.timeout = 1
        waitTooLong.onFailure = .stop
        let newMacros = [
            eventMacro("started", .toolbeltStarts), eventMacro("login", .atLogin), copied,
            eventMacro("window", .windowChanged, text: "Second test window"), eventMacro("title", .windowTitleChanged, text: "Renamed"),
            Macro(name: "Test pause until", steps: [waitForFile, markStep("paused-done")]),
            Macro(name: "Test give up", steps: [waitTooLong, markStep("gave-up-wrongly")]),
            Macro(name: "Test conditions", steps: [
                when(.appRunning, right: "Finder", yes: "cond-running", no: "cond-not-running"),
                when(.appNotRunning, right: "No Such App", yes: "cond-not-running-ok", no: "cond-not-running-wrong"),
                when(.fileExists, data.appendingPathComponent("macros.json").path, yes: "cond-file", no: "cond-no-file"),
                when(.windowTitleContains, right: "Second test window", yes: "cond-title", no: "cond-no-title"),
                when(.pixelColorIs, "%Trigger%", right: "#C86432", yes: "cond-pixel", no: "cond-no-pixel"),
                when(.screenShows, right: data.appendingPathComponent("needle.png").path, yes: "cond-image", no: "cond-no-image"),
                when(.screenShows, right: data.appendingPathComponent("absent.png").path, yes: "cond-absent-wrong", no: "cond-absent-ok"),
            ]),
            Macro(name: "Test held", steps: [when(.modifiersHeld, right: "⇧", yes: "cond-held", no: "cond-not-held")]),
        ]
        // 0.31: actions like Keyboard Maestro's.
        func act(_ kind: MacroAction.Kind, _ value: String = "", option: String? = nil, _ second: String? = nil) -> MacroStep {
            var step = MacroStep(kind: .action)
            step.action = MacroAction(kind: kind, value: value, option: option, value2: second)
            step.onFailure = .stop // so a marker after it shows it worked
            return step
        }
        func shellMark(_ text: String) -> MacroStep {
            var step = MacroStep(kind: .action)
            step.action = MacroAction(kind: .shell, value: "echo '\(text)' >> '\(markersURL.path)'")
            return step
        }
        let km = data.appendingPathComponent("km").path
        var readBack = MacroStep(kind: .readFile)
        readBack.text = km + "/b.txt"
        readBack.name = "Text"
        var alertStep = MacroStep(kind: .alert)
        alertStep.text = "E2E alert"
        alertStep.text2 = "First\nSecond"
        alertStep.name = "Button"
        var severalStep = MacroStep(kind: .askSeveral)
        severalStep.text = "E2E questions"
        severalStep.text2 = "Name\nPlace"
        var pageTitle = MacroStep(kind: .browserGet)
        pageTitle.text2 = BrowserPart.title.rawValue
        pageTitle.name = "Title"
        var pageAddress = MacroStep(kind: .browserGet)
        pageAddress.text2 = BrowserPart.url.rawValue
        pageAddress.name = "Address"
        var waitPage = MacroStep(kind: .pause)
        waitPage.number = 3
        var waitClick = MacroStep(kind: .pause)
        waitClick.number = 1
        let chrome = "Google Chrome"
        let actionMacros = [
            Macro(name: "Test files", steps: [
                act(.file, km + "/a.txt", option: FileCommand.write.rawValue, "hello"),
                act(.file, km + "/a.txt", option: FileCommand.append.rawValue, " world"),
                act(.file, km + "/a.txt", option: FileCommand.copy.rawValue, km + "/copies"),
                act(.file, km + "/a.txt", option: FileCommand.rename.rawValue, "b.txt"),
                readBack, shellMark("file-%Text%"),
            ]),
            Macro(name: "Test trash file", steps: [act(.file, km + "/b.txt", option: FileCommand.trash.rawValue), shellMark("trashed")]),
            Macro(name: "Test app back", steps: [act(.app, option: AppCommand.activateLast.rawValue), shellMark("app-back")]),
            Macro(name: "Test hide app", steps: [act(.app, "Calculator", option: AppCommand.hide.rawValue)]),
            Macro(name: "Test quit app", steps: [act(.app, "Calculator", option: AppCommand.quit.rawValue)]),
            Macro(name: "Test close all", steps: [act(.window, option: WindowCommand.closeAll.rawValue)]),
            Macro(name: "Test window frame", steps: [act(.window, "120,140,520,380", option: WindowCommand.setFrame.rawValue)]),
            Macro(name: "Test minimise", steps: [act(.window, option: WindowCommand.minimize.rawValue)]),
            Macro(name: "Test window click", steps: [act(.mouse, "click window %Trigger%")]),
            Macro(name: "Test picture click", steps: [act(.mouse, "click image " + data.appendingPathComponent("clickme.png").path), shellMark("picture-clicked")]),
            Macro(name: "Test speak", steps: [act(.speak, "Toolbelt is testing speech, one two three four five six seven eight nine ten")]),
            Macro(name: "Test large text", steps: [act(.largeText, "E2E LARGE")]),
            Macro(name: "Test alert", steps: [alertStep, shellMark("alert-%Button%")]),
            Macro(name: "Test ask several", steps: [severalStep, shellMark("asked-%Name%-%Place%")]),
            Macro(name: "Test volume", steps: [act(.setVolume, "30")]),
            Macro(name: "Test desktop", steps: [act(.desktopPicture, data.appendingPathComponent("desk.png").path), shellMark("desktop-set")]),
            Macro(name: "Test layout", steps: [act(.keyboardLayout, "%Trigger%"), shellMark("layout-ok")]),
            Macro(name: "Test download", steps: [act(.download, "http://127.0.0.1:\(Self.webPort)/remote", data.appendingPathComponent("dl").path), shellMark("downloaded")]),
            Macro(name: "Test browser", steps: [
                act(.browser, "%Trigger%", option: BrowserCommand.openTab.rawValue, chrome), waitPage,
                act(.browser, "email=e2e@example.com", option: BrowserCommand.fillField.rawValue, chrome),
                act(.browser, "Send", option: BrowserCommand.clickButton.rawValue, chrome), waitClick,
                pageTitle, shellMark("browser-%Title%"),
                act(.browser, "Next page", option: BrowserCommand.clickLink.rawValue, chrome), waitClick,
                pageAddress, shellMark("address-%Address%"),
            ]),
        ]
        try JSONEncoder().encode(SavedMacros(macros: [macro, webMacro, timeoutMacro, errorMacro] + eventMacros + newMacros + actionMacros, groups: []))
            .write(to: data.appendingPathComponent("macros.json"), options: .atomic)

        let snippets = [Snippet(keyword: ";e2snip", name: "Test snippet", text: "Expanded by Toolbelt")]
        try JSONEncoder().encode(snippets).write(to: data.appendingPathComponent("snippets.json"), options: .atomic)

        Prefs.webServerOn = true
        Prefs.webServerPort = Self.webPort
        Prefs.webServerSecret = Self.webSecret
        Prefs.screenshotFolder = shotsFolder
        Prefs.screenshotAfterCapture = .save
        Prefs.hyperKey = true
        Prefs.hyperEscape = false
        Prefs.keyRemaps = [KeyRemap(from: 0x64, to: 0x29)] // § becomes Esc
    }

    func startToolbelt() async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["TOOLBELT_DATA_DIR": data.path, "TOOLBELT_E2E": "1"]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        do {
            toolbelt = try await NSWorkspace.shared.openApplication(at: toolbeltURL, configuration: configuration)
        } catch {
            say("✗ Toolbelt didn't start: \(error.localizedDescription)")
            failed += 1
            return false
        }
        let statusFile = data.appendingPathComponent("e2e-status.json")
        guard await waitUntil(15, { FileManager.default.fileExists(atPath: statusFile.path) }) else {
            say("✗ Toolbelt started but never got going (no status file)")
            failed += 1
            return false
        }
        await pause(3) // the status is written again after two seconds; let every module start
        return true
    }

    func toolbeltStatus() -> [String: Any] {
        guard let data = try? Data(contentsOf: data.appendingPathComponent("e2e-status.json")),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return status
    }

    // MARK: - The tests

    func runAll() async {
        say("Toolbelt real-use test (\(mode)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard AXIsProcessTrusted() else {
            check("the test app may press keys and click (Accessibility)", false, "macOS didn't give the test app the permission, so nothing can be tested")
            return
        }
        do {
            try writeSetup()
        } catch {
            check("set up test triggers", false, "\(error)")
            return
        }
        guard await startToolbelt() else { return }
        let status = toolbeltStatus()
        say("Toolbelt's status: \(status)")
        check("Toolbelt has Accessibility", status["accessibility"] as? Bool == true, "status: \(status)")
        check("Toolbelt has Input Monitoring", status["inputMonitoring"] as? Bool == true, "status: \(status)")
        await focus()
        check("the test app is in front", isFront, "front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")

        if mode == "stability" {
            await stability()
        } else {
            await keyboardTests()
            await mouseTests()
            await touchTests()
            await typingTests()
            await moduleTests()
            await moreTests()
            await actionTests()
            await panelTests()
            await editorTests()
            await conditionTests()
            await kmActionTests()
            await macEventTests()
        }
        check("Toolbelt is still running at the end", toolbelt.map { !$0.isTerminated } ?? false, "it quit or crashed")
        if mode != "stability", let toolbelt {
            toolbelt.terminate()
            _ = await waitUntil(10) { toolbelt.isTerminated }
            let mapping = hidutilMapping()
            check("quitting Toolbelt puts the keys back", !mapping.contains("30064771129") && !mapping.contains("30064771172"),
                  "macOS's key mapping is still \(mapping)")
        }
    }

    /// macOS's current key mapping, as hidutil prints it.
    func hidutilMapping() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--get", "UserKeyMapping"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
    }

    func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func scroll(vertical: Int32, horizontal: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        event.location = windowMiddle
        post(event)
    }

    func moveMouse(to point: CGPoint) {
        mouse(.mouseMoved, at: point, button: .left)
    }

    func moreTests() async {
        say("— 0.26: rotate, edge swipes, TipSwipe, mouse wheel, screen corners, keys")
        await focus()
        await pause(0.5)
        // Clockwise: the line between the two fingers turns from flat to pointing down-right.
        let start = ProcessInfo.processInfo.systemUptime
        let turn: [(time: Double, touches: [TouchPoint])] = (0...30).map { step in
            let angle = -0.7 * Double(step) / 30
            return (start + Double(step) * 0.01, [TouchPoint(id: 1, x: 0.5 - 0.1 * cos(angle), y: 0.5 - 0.1 * sin(angle)),
                                                  TouchPoint(id: 2, x: 0.5 + 0.1 * cos(angle), y: 0.5 + 0.1 * sin(angle))])
        }
        touches(turn)
        await pause(0.3)
        touches([(start + 0.32, [])])
        check("two-finger rotate right", await waitUntil(3) { self.count("rotate") == 1 }, "ran \(count("rotate")) times")

        await touch([(0.97, 0.45), (0.97, 0.55)], duration: 0.2, move: (-0.3, 0))
        check("two-finger swipe in from the right edge", await waitUntil(3) { self.count("edge") == 1 }, "ran \(count("edge")) times")
        await pause(0.5)
        check("… without also running the plain swipe left", count("plainswipe") == 0, "the plain swipe ran \(count("plainswipe")) times")
        await touch([(0.7, 0.45), (0.7, 0.55)], duration: 0.2, move: (-0.3, 0))
        check("a swipe left from the middle is the plain swipe", await waitUntil(3) { self.count("plainswipe") == 1 }, "ran \(count("plainswipe")) times")

        let tipStart = ProcessInfo.processInfo.systemUptime
        let tip: [(time: Double, touches: [TouchPoint])] = (0...20).map { step in
            let move = 0.25 * Double(step) / 20
            return (tipStart + Double(step) * 0.01, [TouchPoint(id: 1, x: 0.3, y: 0.5), TouchPoint(id: 2, x: 0.5 + move, y: 0.5),
                                                     TouchPoint(id: 3, x: 0.6 + move, y: 0.5)])
        }
        touches(tip)
        await pause(0.3)
        touches([(tipStart + 0.22, [])])
        check("TipSwipe right (one finger resting)", await waitUntil(3) { self.count("tipswipe") == 1 }, "ran \(count("tipswipe")) times")

        await focus()
        scroll(vertical: 0, horizontal: 1)
        check("tilting the mouse wheel left", await waitUntil(3) { self.count("tilt") == 1 }, "ran \(count("tilt")) times")
        let middle = windowMiddle
        mouse(.otherMouseDown, at: middle, button: .center, number: 2)
        await pause(0.1)
        scroll(vertical: 1, horizontal: 0)
        await pause(0.1)
        mouse(.otherMouseUp, at: middle, button: .center, number: 2)
        check("holding the middle button and scrolling up", await waitUntil(3) { self.count("middlescroll") == 1 }, "ran \(count("middlescroll")) times")

        moveMouse(to: CGPoint(x: 300, y: 300))
        await pause(0.2)
        moveMouse(to: CGPoint(x: 0, y: 0)) // the top-left corner (mouse events count from the top left)
        check("pointer pushed into the top-left corner", await waitUntil(3) { self.count("corner") == 1 }, "ran \(count("corner")) times")
        await pause(0.6)
        check("… runs once while it stays there", count("corner") == 1, "ran \(count("corner")) times")
        moveMouse(to: windowMiddle)

        // Hyper key: Caps Lock is remapped to F18; F18 held adds ⌃⌥⇧⌘ to other keys.
        let mapping = hidutilMapping()
        check("Caps Lock is remapped for the Hyper key", mapping.contains("30064771129") && mapping.contains("30064771181"), "mapping: \(mapping)")
        check("§ is changed into Esc", mapping.contains("30064771172") && mapping.contains("30064771113"), "mapping: \(mapping)")
        await focus()
        keyEvent(79, down: true, flags: 0)
        await pause(0.1)
        keyEvent(CGKeyCode(kVK_ANSI_1), down: true, flags: 0, character: "1")
        await pause(0.05)
        keyEvent(CGKeyCode(kVK_ANSI_1), down: false, flags: 0, character: "1")
        await pause(0.1)
        keyEvent(79, down: false, flags: 0)
        check("Hyper key + 1 runs the ⌃⌥⇧⌘1 trigger", await waitUntil(3) { self.count("hyper") == 1 }, "ran \(count("hyper")) times")
        check("… and the 1 doesn't reach the app as typing", !textView.string.contains("1"), "text box has “\(textView.string)”")
    }

    func output(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For failures: the pad's place on screen, and the window that's really at a point.
    func whereIs(_ point: CGPoint) -> String {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = list.first { info in
            guard let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return false }
            return bounds.contains(point) && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        let owner = top?[kCGWindowOwnerName as String] as? String ?? "nothing"
        let layer = top?[kCGWindowLayer as String] as? Int ?? -1
        return "at \(Int(point.x)),\(Int(point.y)) the top window is \(owner)'s (layer \(layer)); pad \(padPoint(0)) to \(padPoint(1)), window \(window.frame)"
    }

    func actionTests() async {
        say("— 0.27: mouse actions, web search, Dock, disks, Trash")
        await focus()
        pad.log = []
        await press(CGKeyCode(kVK_ANSI_A), Self.testMods)
        check("click at a place", await waitUntil(3) { self.pad.log.contains("left 1") }, "the pad saw \(pad.log); \(whereIs(padPoint(0.2)))")
        await pause(0.6)
        pad.log = []
        await press(CGKeyCode(kVK_ANSI_S), Self.testMods)
        check("double-click", await waitUntil(3) { self.pad.log.contains("left 2") }, "the pad saw \(pad.log)")
        pad.log = []
        await press(CGKeyCode(kVK_ANSI_D), Self.testMods)
        check("right-click", await waitUntil(3) { self.pad.log.contains("right") }, "the pad saw \(pad.log)")
        await focus()
        pad.log = []
        await press(CGKeyCode(kVK_ANSI_F), Self.testMods)
        check("middle-click", await waitUntil(3) { self.pad.log.contains("middle") }, "the pad saw \(pad.log)")
        pad.log = []
        moveMouse(to: padPoint(0.5))
        await pause(0.2)
        await press(CGKeyCode(kVK_ANSI_G), Self.testMods)
        check("scroll where the pointer is", await waitUntil(3) { self.pad.log.contains { $0.hasPrefix("scroll") } },
              "the pad saw \(pad.log); pointer at \(MouseDriver.pointer); \(whereIs(MouseDriver.pointer))")
        pad.log = []
        await press(CGKeyCode(kVK_ANSI_H), Self.testMods)
        check("drag from one place to another", await waitUntil(3) { self.pad.log.contains("drop") } && pad.dragDistance > 150,
              "the pad saw \(pad.log), dragged \(Int(pad.dragDistance)) points")
        await press(CGKeyCode(kVK_ANSI_J), Self.testMods)
        let moved = await waitUntil(3) { abs(MouseDriver.pointer.x - 77) < 2 && abs(MouseDriver.pointer.y - 155) < 2 }
        check("move the pointer", moved, "pointer at \(MouseDriver.pointer)")

        // Search the web for the selected text (a test search address this app answers), keeping the clipboard.
        await focus()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("keep this copy", forType: .string)
        textView.string = "find me please"
        textView.selectAll(nil)
        await pause(0.3)
        await press(CGKeyCode(kVK_ANSI_L), Self.testMods)
        let searched = await waitUntil(5) { self.openedURLs.contains { $0.contains("find%20me%20please") } }
        check("search the web for the selected text", searched, "opened \(openedURLs)")
        await pause(0.5)
        check("… and the clipboard is put back", NSPasteboard.general.string(forType: .string) == "keep this copy",
              "clipboard has “\(NSPasteboard.general.string(forType: .string) ?? "")”")

        // Hide / show the Dock (macOS's own ⌥⌘D), then put it back.
        func dockHides() -> String { output("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"]) }
        let before = dockHides()
        await press(CGKeyCode(kVK_ANSI_X), Self.testMods)
        let changed = await waitUntil(5) { dockHides() != before }
        check("hide / show the Dock", changed, "autohide was “\(before)”, now “\(dockHides())”")
        if changed {
            await pause(1)
            await press(CGKeyCode(kVK_ANSI_X), Self.testMods)
            _ = await waitUntil(5) { dockHides() == before }
        }

        // Eject all disks: a disk image is attached, then ejected.
        let image = data.appendingPathComponent("ToolbeltEject.dmg").path
        let attached = run("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "HFS+", "-volname", "ToolbeltEject", "-ov", image])
            && run("/usr/bin/hdiutil", ["attach", image])
        let mounted = attached ? await waitUntil(5) { FileManager.default.fileExists(atPath: "/Volumes/ToolbeltEject") } : false
        await press(CGKeyCode(kVK_ANSI_Z), Self.testMods)
        let ejected = mounted ? await waitUntil(10) { !FileManager.default.fileExists(atPath: "/Volumes/ToolbeltEject") } : false
        check("eject all disks", ejected, "attached \(attached), mounted \(mounted)")

        // Empty the Trash (through Finder).
        let file = data.appendingPathComponent("throw away \(Int.random(in: 1000...9999)).txt")
        try? "rubbish".write(to: file, atomically: true, encoding: .utf8)
        var inTrash: NSURL?
        try? FileManager.default.trashItem(at: file, resultingItemURL: &inTrash)
        let trashed = (inTrash as URL?).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // Like a person: Finder takes a moment to notice something new in the Trash.
        await pause(2)
        await press(CGKeyCode(kVK_ANSI_C), Self.testMods)
        let emptied = trashed ? await waitUntil(40) { !FileManager.default.fileExists(atPath: (inTrash as URL?)?.path ?? "") } : false
        check("empty the Trash", emptied,
              "put in the Trash: \(trashed); the trigger ran: \(count("trashpressed")); still asking Finder: \(output("/usr/bin/pgrep", ["-lf", "empty trash"]).isEmpty ? "no" : "yes"); "
                + "Finder running: \(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty ? "no" : "yes"); "
                + "the Trash holds \((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash"))?.count ?? -1) items, "
                + "the file is at \((inTrash as URL?)?.path ?? "?")")
    }

    func click(_ point: CGPoint) async {
        moveMouse(to: point)
        await pause(0.1)
        mouse(.leftMouseDown, at: point, button: .left)
        await pause(0.05)
        mouse(.leftMouseUp, at: point, button: .left)
    }

    func panelTests() async {
        say("— 0.28: presets, floating menus, menu-bar items")
        await focus()
        await press(CGKeyCode(kVK_ANSI_Q), Self.testMods)
        await pause(1)
        check("a trigger in the Work preset is off while Work isn't in use", count("work") == 0, "ran \(count("work")) times")
        await press(CGKeyCode(kVK_ANSI_W), Self.testMods)
        let switched = await waitUntil(3) { self.toolbeltStatus()["activePreset"] as? String == "Work" }
        check("an action switches to the Work preset", switched, "preset now “\(toolbeltStatus()["activePreset"] ?? "")”")
        await pause(0.5)
        await press(CGKeyCode(kVK_ANSI_Q), Self.testMods)
        check("… and then the Work trigger works", await waitUntil(3) { self.count("work") == 1 }, "ran \(count("work")) times")

        func menuFrame() -> [Double]? { (toolbeltStatus()["floatingMenus"] as? [String: [Double]])?["Test menu"] }
        await press(CGKeyCode(kVK_ANSI_E), Self.testMods)
        let shown = await waitUntil(3) { menuFrame() != nil }
        check("an action shows a floating menu", shown, "status: \(toolbeltStatus()["floatingMenus"] ?? "none")")
        if let frame = menuFrame(), frame.count == 4 {
            await click(CGPoint(x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2))
            check("clicking its button runs the button's action", await waitUntil(3) { self.count("floatbutton") == 1 },
                  "ran \(count("floatbutton")) times; \(whereIs(CGPoint(x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2)))")
            check("… and it closes after the click", await waitUntil(3) { menuFrame() == nil }, "still showing")
        }

        func menuBarItem() -> [String: Any]? { (toolbeltStatus()["menuBarItems"] as? [[String: Any]])?.first }
        let titled = await waitUntil(10) { menuBarItem()?["title"] as? String == "E2E-42" }
        check("a menu-bar item shows its script's output", titled, "item: \(menuBarItem().map { "\($0)" } ?? "none")")
        if let frame = menuBarItem()?["frame"] as? [Double], frame.count == 4 {
            await click(CGPoint(x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2))
            check("clicking the menu-bar item runs its action", await waitUntil(3) { self.count("menubar") == 1 }, "ran \(count("menubar")) times")
            keyEvent(CGKeyCode(kVK_Escape), down: true, flags: 0)
            keyEvent(CGKeyCode(kVK_Escape), down: false, flags: 0)
        }
    }

    func command(_ text: String) {
        DistributedNotificationCenter.default().postNotificationName(RealUseHooks.commandNotification, object: text, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    func runMacro(_ name: String) async -> Int? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return await get("http://127.0.0.1:\(Self.webPort)/run_macro?name=\(encoded)&secret=\(Self.webSecret)")
    }

    func editorTests() async {
        say("— 0.29: recording, time limits, failures, switched-off steps")
        // Record typing into this window, then play it back.
        await focus()
        command("record-start:Recorded")
        await pause(1)
        await type("rec hello")
        await pause(0.5)
        command("record-stop")
        let recorded = await waitUntil(5) { (self.toolbeltStatus()["recorded"] as? [String])?.contains { $0.contains("rec hello") } == true }
        check("recording typing makes a “Type text” step", recorded, "recorded: \(toolbeltStatus()["recorded"] ?? "nothing")")
        await focus()
        _ = await runMacro("Recorded")
        check("the recorded macro types it again", await waitUntil(5) { self.textView.string.contains("rec hello") },
              "text box has “\(textView.string)”")

        _ = await runMacro("Test timeout")
        await pause(3)
        check("a script that runs out of time stops the macro (as asked)", count("after-timeout") == 0, "the next step ran \(count("after-timeout")) times")
        _ = await runMacro("Test error")
        check("a script that fails carries on (the default)", await waitUntil(5) { self.count("after-error") == 1 }, "ran \(count("after-error")) times")
        check("a step that's switched off doesn't run", count("switched-off") == 0, "ran \(count("switched-off")) times")
    }

    func conditionTests() async {
        say("— 0.30: new triggers, “Pause until”, conditions about the Mac")
        check("Toolbelt starts (trigger)", await waitUntil(3) { self.count("started") == 1 }, "ran \(count("started")) times")
        check("… and “at login” doesn't run long after logging in", count("login") == 0, "ran \(count("login")) times")

        await focus()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("something else", forType: .string)
        await pause(1.5)
        check("a copy without the text doesn't start the clipboard macro", count("copied") == 0, "ran \(count("copied")) times")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("invoice e2e-copy 2041", forType: .string)
        check("the clipboard changes (to text containing e2e-copy)", await waitUntil(4) { self.count("copied") == 1 }, "ran \(count("copied")) times")
        await pause(2.5)
        check("… and the macro's own copy doesn't start it again", count("copied") == 1, "ran \(count("copied")) times")

        // A second window: in front, then renamed. It also holds a pink square and a pattern for the screen tests.
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        second.title = "Second test window"
        second.isReleasedWhenClosed = false
        let patch = SolidView(frame: NSRect(x: 20, y: 60, width: 80, height: 80))
        let pattern = PatternView(frame: NSRect(x: 160, y: 40, width: 120, height: 120))
        second.contentView?.addSubview(patch)
        second.contentView?.addSubview(pattern)
        second.setFrameTopLeftPoint(NSPoint(x: window.frame.minX + 40, y: window.frame.maxY - 40))
        second.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        check("the front window changes", await waitUntil(4) { self.count("window") == 1 }, "ran \(count("window")) times")
        await pause(0.5)
        second.title = "Renamed test window"
        check("the front window's title changes", await waitUntil(4) { self.count("title") == 1 }, "ran \(count("title")) times")
        check("… a window or title not matching doesn't run them", count("window") == 1, "window macro ran \(count("window")) times")
        second.title = "Second test window"
        await pause(0.5)

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func topLeft(_ view: NSView, _ rect: NSRect) -> NSRect {
            let frame = second.convertToScreen(view.convert(rect, to: nil))
            return NSRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
        }
        let patchSpot = topLeft(patch, patch.bounds)
        let needleRect = topLeft(pattern, pattern.bounds.insetBy(dx: 20, dy: 20)).integral
        let needle = data.appendingPathComponent("needle.png").path
        let captured = run("/usr/sbin/screencapture", ["-x", "-R\(Int(needleRect.minX)),\(Int(needleRect.minY)),\(Int(needleRect.width)),\(Int(needleRect.height))", needle])
        // A picture that isn't on screen: grey blocks in another random order (drawn straight into a file).
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 3,
                                         hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            // Bytes written straight in (setColor with a grey colour does nothing on an RGB bitmap, leaving it black).
            var seed: UInt32 = 977
            if let bytes = bitmap.bitmapData {
                for blockY in 0..<8 {
                    for blockX in 0..<8 {
                        seed = seed &* 1_103_515_245 &+ 12345
                        let grey = UInt8((seed >> 16) & 0xFF)
                        for y in 0..<10 {
                            for x in 0..<10 {
                                let offset = (blockY * 10 + y) * bitmap.bytesPerRow + (blockX * 10 + x) * 3
                                bytes[offset] = grey; bytes[offset + 1] = grey; bytes[offset + 2] = grey
                            }
                        }
                    }
                }
            }
            try? bitmap.representation(using: .png, properties: [:])?.write(to: data.appendingPathComponent("absent.png"))
        }
        let point = "\(Int(patchSpot.midX)),\(Int(patchSpot.midY))"
        let encoded = point.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? point
        _ = await get("http://127.0.0.1:\(Self.webPort)/run_macro?name=Test%20conditions&input=\(encoded)&secret=\(Self.webSecret)")
        let done = await waitUntil(25) { self.markers().contains { $0.hasPrefix("cond-absent") } }
        check("conditions ran", done, "markers: \(markers().filter { $0.hasPrefix("cond") })")
        check("condition: an app is running (Finder)", count("cond-running") == 1, "markers: \(markers().filter { $0.hasPrefix("cond") })")
        check("condition: an app isn't running", count("cond-not-running-ok") == 1, "markers: \(markers().filter { $0.hasPrefix("cond") })")
        check("condition: a file exists", count("cond-file") == 1, "markers: \(markers().filter { $0.hasPrefix("cond") })")
        check("condition: the front window's title", count("cond-title") == 1, "markers: \(markers().filter { $0.hasPrefix("cond") })")
        let seenColours = await ScreenReader.colors(at: CGPoint(x: patchSpot.midX.rounded(.down), y: patchSpot.midY.rounded(.down)))
        check("condition: the colour at a point (\(point))", count("cond-pixel") == 1,
              "read \(seenColours.map(\.hex)) there (sRGB, screen's own); markers: \(markers().filter { $0.hasPrefix("cond") })")
        check("condition: the screen shows a picture", captured && count("cond-image") == 1,
              "captured \(captured), markers: \(markers().filter { $0.hasPrefix("cond") })")
        check("condition: … and not a picture that isn't there", count("cond-absent-ok") == 1, "markers: \(markers().filter { $0.hasPrefix("cond") })")
        second.close()

        // A key held down: hold ⇧ while the macro checks.
        flagsEvent(CGKeyCode(kVK_Shift), flags: CGEventFlags.maskShift.rawValue)
        await pause(0.3)
        _ = await runMacro("Test held")
        let held = await waitUntil(5) { self.count("cond-held") + self.count("cond-not-held") > 0 }
        flagsEvent(CGKeyCode(kVK_Shift), flags: 0)
        check("condition: a key is held down (⇧)", held && count("cond-held") == 1, "held \(count("cond-held")), not held \(count("cond-not-held"))")

        // Pause until a file appears.
        let go = data.appendingPathComponent("go.txt")
        try? FileManager.default.removeItem(at: go)
        _ = await runMacro("Test pause until")
        await pause(2)
        check("“Pause until” waits", count("paused-done") == 0, "ran \(count("paused-done")) times before the file was made")
        FileManager.default.createFile(atPath: go.path, contents: Data("go".utf8))
        check("… and carries on when it happens", await waitUntil(5) { self.count("paused-done") == 1 }, "ran \(count("paused-done")) times")
        _ = await runMacro("Test give up")
        await pause(3)
        check("“Pause until” gives up after its time (and stops, as asked)", count("gave-up-wrongly") == 0, "the next step ran \(count("gave-up-wrongly")) times")
        await focus()
    }

    /// The front window of an app, from the window list (top-left based), and how many it has.
    func windows(of bundleID: String) -> [CGRect] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
    }

    func kmActionTests() async {
        say("— 0.31: actions like Keyboard Maestro's")
        // Files
        _ = await runMacro("Test files")
        let km = data.appendingPathComponent("km").path
        check("files: write, add to, copy, rename and read a file", await waitUntil(8) { self.count("file-hello world") == 1 },
              "markers: \(markers().filter { $0.hasPrefix("file") }), files: \((try? FileManager.default.contentsOfDirectory(atPath: km)) ?? [])")
        check("… the copy is in its folder", FileManager.default.fileExists(atPath: km + "/copies/a.txt"))
        _ = await runMacro("Test trash file")
        check("files: move to the Trash", await waitUntil(5) { self.count("trashed") == 1 } && !FileManager.default.fileExists(atPath: km + "/b.txt"),
              "marker \(count("trashed")), still there: \(FileManager.default.fileExists(atPath: km + "/b.txt"))")

        // Apps
        await focus()
        _ = run("/usr/bin/open", ["-a", "Finder"])
        _ = await waitUntil(5) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" }
        _ = await runMacro("Test app back")
        check("apps: switch back to the app used before", await waitUntil(5) { self.isFront && self.count("app-back") == 1 },
              "front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), marker \(count("app-back"))")
        _ = run("/usr/bin/open", ["-a", "Calculator"])
        let calculator = "com.apple.calculator"
        _ = await waitUntil(8) { !self.windows(of: calculator).isEmpty }
        _ = await runMacro("Test close all")
        check("windows: close all the front app's windows", await waitUntil(5) { self.windows(of: calculator).isEmpty },
              "Calculator still has \(windows(of: calculator).count) windows")
        _ = run("/usr/bin/open", ["-a", "Calculator"])
        _ = await waitUntil(5) { !self.windows(of: calculator).isEmpty }
        _ = await runMacro("Test hide app")
        check("apps: hide an app", await waitUntil(5) { NSRunningApplication.runningApplications(withBundleIdentifier: calculator).first?.isHidden == true },
              "Calculator hidden: \(NSRunningApplication.runningApplications(withBundleIdentifier: calculator).first?.isHidden ?? false)")
        _ = await runMacro("Test quit app")
        check("apps: quit an app", await waitUntil(8) { NSRunningApplication.runningApplications(withBundleIdentifier: calculator).isEmpty },
              "Calculator is still running")

        // The front window
        await focus()
        _ = await runMacro("Test window frame")
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func topLeftFrame() -> CGRect { CGRect(x: window.frame.minX, y: screenHeight - window.frame.maxY, width: window.frame.width, height: window.frame.height) }
        let moved = await waitUntil(5) {
            let f = topLeftFrame()
            return abs(f.minX - 120) <= 2 && abs(f.minY - 140) <= 2 && abs(f.width - 520) <= 2 && abs(f.height - 380) <= 2
        }
        check("windows: move and resize the front window to an exact place", moved, "frame is \(topLeftFrame())")
        window.setFrame(homeFrame, display: true)
        await focus()
        _ = await runMacro("Test minimise")
        check("windows: minimise the front window", await waitUntil(5) { self.window.isMiniaturized }, "not minimised")
        window.deminiaturize(nil)
        _ = await waitUntil(5) { !self.window.isMiniaturized }
        window.setFrame(homeFrame, display: true)

        // The mouse, from the window's corner and on a picture
        await focus(clear: false)
        pad.log = []
        let corner = CGPoint(x: window.frame.minX, y: screenHeight - window.frame.maxY)
        let target = padPoint(0.5)
        let offset = "\(Int(target.x - corner.x)),\(Int(target.y - corner.y))"
        _ = await get("http://127.0.0.1:\(Self.webPort)/run_macro?name=Test%20window%20click&input=\(offset)&secret=\(Self.webSecret)")
        check("mouse: click counted from the front window's corner", await waitUntil(4) { self.pad.log.contains("left 1") }, "the pad saw \(pad.log)")

        let pictureWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        pictureWindow.title = "Picture to click"
        pictureWindow.isReleasedWhenClosed = false
        let clickable = PatternView(frame: NSRect(x: 30, y: 20, width: 200, height: 160))
        clickable.seed = 11
        pictureWindow.contentView?.addSubview(clickable)
        pictureWindow.setFrameTopLeftPoint(NSPoint(x: window.frame.midX - 130, y: window.frame.maxY - 60))
        pictureWindow.makeKeyAndOrderFront(nil)
        await pause(0.8)
        let spot = pictureWindow.convertToScreen(clickable.convert(clickable.bounds.insetBy(dx: 50, dy: 40), to: nil))
        let needleRect = CGRect(x: spot.minX, y: screenHeight - spot.maxY, width: spot.width, height: spot.height).integral
        let needle = data.appendingPathComponent("clickme.png").path
        let captured = run("/usr/sbin/screencapture", ["-x", "-R\(Int(needleRect.minX)),\(Int(needleRect.minY)),\(Int(needleRect.width)),\(Int(needleRect.height))", needle])
        clickable.clicks = []
        _ = await runMacro("Test picture click")
        let clicked = await waitUntil(15) { !clickable.clicks.isEmpty }
        let middle = CGPoint(x: clickable.bounds.midX, y: clickable.bounds.midY)
        check("mouse: click on a picture found on screen (its middle)",
              captured && clicked && clickable.clicks.allSatisfy { abs($0.x - middle.x) < 8 && abs($0.y - middle.y) < 8 },
              "captured \(captured), clicks at \(clickable.clicks), middle \(middle), marker \(count("picture-clicked"))")
        pictureWindow.close()

        // Speech, large text, alerts and questions
        _ = await runMacro("Test speak")
        check("say text out loud", await waitUntil(4) { self.output("/usr/bin/pgrep", ["-x", "say"]).isEmpty == false }, "no say process was seen")
        await focus()
        let before = toolbeltWindows()
        _ = await runMacro("Test large text")
        check("show text large", await waitUntil(4) { self.toolbeltWindows() > before }, "Toolbelt's windows: \(before) → \(toolbeltWindows())")
        await click(windowMiddle)
        check("… gone after a click", await waitUntil(4) { self.toolbeltWindows() <= before }, "Toolbelt's windows: \(toolbeltWindows())")

        _ = await runMacro("Test alert")
        await pause(2)
        // Like clicking on it: macOS doesn't let an app in the background take the keyboard by itself.
        toolbelt?.activate()
        await pause(0.8)
        await press(CGKeyCode(kVK_Return), [])
        check("an alert with buttons (Return clicks the first)", await waitUntil(5) { self.count("alert-First") == 1 },
              "markers: \(markers().filter { $0.hasPrefix("alert") })")
        _ = await runMacro("Test ask several")
        await pause(2)
        toolbelt?.activate()
        await pause(1.5)
        await type("Sam")
        await pause(0.3)
        await press(CGKeyCode(kVK_Tab), [])
        await pause(0.3)
        await type("Home")
        await pause(0.3)
        await press(CGKeyCode(kVK_Return), [])
        check("several questions at once, each into its own variable", await waitUntil(5) { self.count("asked-Sam-Home") == 1 },
              "markers: \(markers().filter { $0.hasPrefix("asked") })")
        await focus()

        // The Mac: volume, desktop picture, keyboard layout
        let volumeBefore = output("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"])
        _ = await runMacro("Test volume")
        if Int(volumeBefore) != nil {
            check("set the volume to 30%", await waitUntil(5) { self.output("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"]) == "30" },
                  "volume is \(output("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"]))")
        } else {
            say("  (this Mac has no sound output, so the volume can't be read: \(volumeBefore))")
        }
        let picture = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor.systemPurple.setFill(); rect.fill(); return true }
        if let png = picture.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
            try? png.write(to: data.appendingPathComponent("desk.png"))
        }
        _ = await runMacro("Test desktop")
        check("change the desktop picture", await waitUntil(5) {
            self.count("desktop-set") == 1 && NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?.lastPathComponent == "desk.png"
        }, "marker \(count("desktop-set")), picture \(NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?.path ?? "none")")
        let layout = KeyboardLayouts.currentName
        _ = await get("http://127.0.0.1:\(Self.webPort)/run_macro?name=Test%20layout&input=\(layout.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")&secret=\(Self.webSecret)")
        check("switch keyboard layout (to \(layout))", await waitUntil(5) { self.count("layout-ok") == 1 } && KeyboardLayouts.currentName == layout,
              "marker \(count("layout-ok")), layout now \(KeyboardLayouts.currentName); layouts: \(KeyboardLayouts.names)")

        // Downloading a file
        _ = await runMacro("Test download")
        let downloads = data.appendingPathComponent("dl").path
        check("download a file into a folder", await waitUntil(10) { self.count("downloaded") == 1 }
              && ((try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? []).isEmpty == false,
              "marker \(count("downloaded")), folder: \((try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? [])")

        await browserTests()
        await focus()
    }

    /// Chrome, started with its own settings folder where "Allow JavaScript from Apple Events" is on.
    func browserTests() async {
        let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        guard FileManager.default.fileExists(atPath: chromeApp.path) else {
            check("Chrome is installed (for the browser actions)", false, "no \(chromeApp.path)")
            return
        }
        let profile = data.appendingPathComponent("chrome-profile")
        try? FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try? Data(#"{"browser":{"allow_javascript_apple_events":true,"check_default_browser":false}}"#.utf8)
            .write(to: profile.appendingPathComponent("Default/Preferences"))
        let page = data.appendingPathComponent("form.html")
        try? Data("""
        <!doctype html><title>E2E form</title>
        <form onsubmit="return false"><label>Email <input name="email"></label>
        <button onclick="document.title='sent '+document.getElementsByName('email')[0].value">Send</button></form>
        <a href="#next">Next page</a>
        """.utf8).write(to: page)
        // Chrome's own program, started in the background (not waited for); no keychain or first-run windows.
        let chrome = Process()
        chrome.executableURL = chromeApp.appendingPathComponent("Contents/MacOS/Google Chrome")
        chrome.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
                            "--use-mock-keychain", "--password-store=basic", "about:blank"]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        do { try chrome.run() } catch {
            check("Chrome starts (for the browser actions)", false, "\(error)")
            return
        }
        defer { if chrome.isRunning { chrome.terminate() } }
        _ = await waitUntil(15) { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty }
        await pause(4)
        _ = await get("http://127.0.0.1:\(Self.webPort)/run_macro?name=Test%20browser&input=\(page.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")&secret=\(Self.webSecret)")
        check("browser: open a page, fill in a field, click a button, read the title",
              await waitUntil(30) { self.count("browser-sent e2e@example.com") == 1 },
              "markers: \(markers().filter { $0.hasPrefix("browser") || $0.hasPrefix("address") })")
        check("browser: click a link, read the address", await waitUntil(10) { self.markers().contains { $0.hasPrefix("address-") && $0.hasSuffix("#next") } },
              "markers: \(markers().filter { $0.hasPrefix("address") })")
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") { app.terminate() }
    }

    func macEventTests() async {
        say("— 0.26: the Mac's own events")
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.apple.screenIsLocked"), object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        check("screen locks", await waitUntil(3) { self.count("locked") == 1 }, "ran \(count("locked")) times")
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.apple.screenIsUnlocked"), object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        check("screen unlocks", await waitUntil(3) { self.count("unlocked") == 1 }, "ran \(count("unlocked")) times")

        let image = data.appendingPathComponent("ToolbeltTest.dmg").path
        let made = run("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "HFS+", "-volname", "ToolbeltTest", "-ov", image])
        let attached = made && run("/usr/bin/hdiutil", ["attach", image])
        let diskIn = attached ? await waitUntil(8) { self.count("diskin") == 1 } : false
        check("disk appears (named ToolbeltTest)", diskIn,
              "made \(made), attached \(attached), ran \(count("diskin")) times")
        check("… not the trigger for a disk with another name", count("otherdisk") == 0, "ran \(count("otherdisk")) times")
        let detached = run("/usr/bin/hdiutil", ["detach", "/Volumes/ToolbeltTest", "-force"])
        let diskOut = detached ? await waitUntil(8) { self.count("diskout") == 1 } : false
        check("disk ejected", diskOut, "detached \(detached), ran \(count("diskout")) times")

        // Idle for a minute (no key, click or mouse move), then used again.
        say("  waiting a minute and a half without touching anything…")
        let idle = await waitUntil(100) { self.count("idle") == 1 }
        check("not used for a minute (idle)", idle, "ran \(count("idle")) times after \(Int(InputIdle.seconds)) idle seconds")
        moveMouse(to: CGPoint(x: windowMiddle.x + 5, y: windowMiddle.y))
        check("used again", await waitUntil(6) { self.count("back") == 1 }, "ran \(count("back")) times")
    }

    func keyboardTests() async {
        say("— Keyboard shortcuts")
        await focus()
        await press(CGKeyCode(kVK_ANSI_1), Self.testMods)
        check("plain shortcut ⌃⌥⇧1 runs its action", await waitUntil(3) { self.count("plain") == 1 }, "ran \(count("plain")) times")

        // Quick press: down, quick release, then the modifier keys let go.
        await press(CGKeyCode(kVK_ANSI_2), Self.testMods, hold: 0.1, betweenUpAndModifiers: 0.15)
        _ = await waitUntil(3) { self.count("b-mods") >= 1 }
        await pause(0.4)
        check("key down action", count("b-down") == 1, "ran \(count("b-down")) times")
        check("on key release", count("b-release") == 1, "ran \(count("b-release")) times")
        check("on quick release", count("b-quick") == 1, "ran \(count("b-quick")) times")
        check("after all modifier keys are released", count("b-mods") == 1, "ran \(count("b-mods")) times")
        check("no long-hold action for a quick press", count("b-long") == 0, "ran \(count("b-long")) times")
        // Long hold.
        await pause(0.5)
        await press(CGKeyCode(kVK_ANSI_2), Self.testMods, hold: 0.9)
        _ = await waitUntil(3) { self.count("b-afterlong") >= 1 }
        await pause(0.4)
        check("on long key hold", count("b-long") == 1, "ran \(count("b-long")) times")
        check("on release after a long hold", count("b-afterlong") == 1, "ran \(count("b-afterlong")) times")
        check("a long hold isn't also a quick release", count("b-quick") == 1, "quick release ran \(count("b-quick")) times")

        // Repeat while held.
        await press(CGKeyCode(kVK_ANSI_3), Self.testMods, hold: 1.2)
        await pause(0.6)
        let repeats = count("c-repeat")
        await pause(1.0)
        check("repeats while the keys are held (10 a second)", repeats >= 6, "ran \(repeats) times in 1.2 seconds")
        check("stops repeating when let go", count("c-repeat") == repeats, "went on from \(repeats) to \(count("c-repeat"))")

        // Left and right ⌘.
        await press(CGKeyCode(kVK_ANSI_4), [.leftCommand, .leftOption])
        await pause(0.8)
        check("right-⌘ shortcut ignores the left ⌘ key", count("d-right") == 0, "ran \(count("d-right")) times")
        await press(CGKeyCode(kVK_ANSI_4), [.rightCommand, .leftOption])
        check("right-⌘ shortcut works with the right ⌘ key", await waitUntil(3) { self.count("d-right") == 1 }, "ran \(count("d-right")) times")

        // Follows the layout: the key that types k.
        await press(CGKeyCode(kVK_ANSI_K), Self.testMods, character: "k")
        check("shortcut that follows the keyboard layout", await waitUntil(3) { self.count("e-layout") == 1 }, "ran \(count("e-layout")) times")

        // Conditions and activation groups (this app is in front).
        await press(CGKeyCode(kVK_ANSI_5), Self.testMods)
        _ = await waitUntil(3) { self.count("f-specific") + self.count("f-general") > 0 }
        await pause(0.4)
        check("the trigger whose condition is true wins", count("f-specific") == 1 && count("f-general") == 0,
              "specific \(count("f-specific")), general \(count("f-general"))")
        await press(CGKeyCode(kVK_ANSI_6), Self.testMods)
        check("a trigger in an activation group that applies", await waitUntil(3) { self.count("g-group") == 1 }, "ran \(count("g-group")) times")
        await press(CGKeyCode(kVK_ANSI_7), Self.testMods)
        await pause(1)
        check("a trigger in an activation group that doesn't apply stays off", count("h-never") == 0, "ran \(count("h-never")) times")

        // Modifier double tap.
        await pause(0.5)
        await tapModifier(.leftOption)
        await pause(0.12)
        await tapModifier(.leftOption)
        check("double tap of ⌥", await waitUntil(3) { self.count("optdouble") == 1 }, "ran \(count("optdouble")) times")

        // Window commands: Toolbelt's own shortcut, and a trigger running the command.
        await focus()
        await press(CGKeyCode(kVK_LeftArrow), Self.ctrlOpt)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let left = await waitUntil(3) { abs(self.window.frame.minX - visible.minX) < 20 && abs(self.window.frame.width - visible.width / 2) < 30 }
        check("⌃⌥← moves the window to the left half", left, "window \(window.frame), screen \(visible)")
        await press(CGKeyCode(kVK_ANSI_9), Self.testMods)
        let right = await waitUntil(3) { abs(self.window.frame.maxX - visible.maxX) < 20 && abs(self.window.frame.width - visible.width / 2) < 30 }
        check("a trigger running “Right half” moves the window", right, "window \(window.frame), screen \(visible)")
        window.setFrame(homeFrame, display: true)
    }

    func mouseTests() async {
        say("— Mouse")
        await focus()
        let middle = windowMiddle
        mouse(.otherMouseDown, at: middle, button: .center, number: 3)
        await pause(0.05)
        mouse(.otherMouseUp, at: middle, button: .center, number: 3)
        check("mouse button 4", await waitUntil(3) { self.count("button4") == 1 }, "ran \(count("button4")) times")

        mouse(.rightMouseDown, at: middle, button: .right)
        for step in 1...15 {
            await pause(0.015)
            mouse(.rightMouseDragged, at: CGPoint(x: middle.x - CGFloat(step) * 16, y: middle.y), button: .right)
        }
        mouse(.rightMouseUp, at: CGPoint(x: middle.x - 240, y: middle.y), button: .right)
        check("drawing ← with the right button held", await waitUntil(3) { self.count("strokeL") == 1 }, "ran \(count("strokeL")) times")
    }

    func touchTests() async {
        say("— Trackpad (pretend touches)")
        await focus()
        await pause(0.5)
        await touch([(0.4, 0.5), (0.5, 0.5), (0.6, 0.5)], duration: 0.12)
        check("three-finger tap", await waitUntil(3) { self.count("tap3") == 1 }, "ran \(count("tap3")) times")
        await touch([(0.62, 0.5), (0.70, 0.5), (0.78, 0.5), (0.86, 0.5)], duration: 0.2, move: (-0.4, 0))
        check("four-finger swipe left", await waitUntil(3) { self.count("swipe4") == 1 }, "ran \(count("swipe4")) times")
        await touch([(0.45, 0.4), (0.55, 0.4)], duration: 1.0)
        check("two-finger long touch", await waitUntil(3) { self.count("long2") == 1 }, "ran \(count("long2")) times")
        check("“when the fingers lift” action", await waitUntil(3) { self.count("lift2") == 1 }, "ran \(count("lift2")) times")
    }

    func typingTests() async {
        say("— Typing")
        await focus()
        await type("hello qqz")
        check("typed sequence “qqz”", await waitUntil(3) { self.count("typed") == 1 }, "ran \(count("typed")) times")
        check("typing reaches the app in front", textView.string.contains("hello"), "text box has “\(textView.string)”")

        await focus()
        await type("note ;e2snip")
        let expanded = await waitUntil(5) { self.textView.string.contains("Expanded by Toolbelt") }
        check("snippet ;e2snip expands while typing", expanded && !textView.string.contains(";e2snip"), "text box has “\(textView.string)”")

        await focus()
        await press(CGKeyCode(kVK_ANSI_8), Self.testMods)
        let then = await waitUntil(5) { self.count("macro-then") == 1 }
        check("macro: variable and if/then", then && count("macro-else") == 0,
              "then \(count("macro-then")), otherwise \(count("macro-else"))")
        check("macro: types text into the app in front", await waitUntil(5) { self.textView.string.contains("Typed by a macro") },
              "text box has “\(textView.string)”")
    }

    func moduleTests() async {
        say("— Clipboard, launcher, web server, screenshots")
        await focus()
        let copied = "Copied in the real-use test \(Int.random(in: 1000...9999))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
        let history = data.appendingPathComponent("history.json")
        check("clipboard history keeps a copy", await waitUntil(6) { (try? String(contentsOf: history, encoding: .utf8))?.contains(copied) ?? false })
        // Right after the macro typed (which pastes and then puts the old clipboard back): the copy stays.
        check("a copy made just after typing isn't overwritten", NSPasteboard.general.string(forType: .string) == copied,
              "clipboard now has “\(NSPasteboard.general.string(forType: .string) ?? "")”")

        await panelTest("⌘⇧V opens the clipboard history", key: CGKeyCode(kVK_ANSI_V), mods: [.leftShift, .leftCommand])
        await panelTest("⌥Space opens the launcher", key: CGKeyCode(kVK_Space), mods: [.leftOption])

        // The web server: run a macro by name, with and without the secret.
        let base = "http://127.0.0.1:\(Self.webPort)/run_macro?name=Test%20web"
        let wrong = await get(base + "&secret=wrong")
        check("web server refuses a wrong secret", wrong == 401, "answered \(wrong.map(String.init) ?? "nothing")")
        let right = await get(base + "&secret=\(Self.webSecret)")
        let ran = await waitUntil(3) { self.count("web") == 1 }
        check("web server runs a macro", right == 200 && ran, "answered \(right.map(String.init) ?? "nothing"), ran \(count("web")) times")

        // Screenshot of the whole screen, saved to the folder set in Settings.
        await focus()
        await press(CGKeyCode(kVK_ANSI_3), [.leftOption, .leftShift, .leftCommand])
        let saved = await waitUntil(8) {
            ((try? FileManager.default.contentsOfDirectory(atPath: self.shotsFolder.path)) ?? []).contains { $0.hasSuffix(".png") }
        }
        check("⌥⇧⌘3 saves a screenshot", saved, "Screen Recording for Toolbelt: \(toolbeltStatus()["screenRecording"] ?? "?")")
    }

    /// A shortcut opens one of Toolbelt's panels, and Escape closes it again.
    func panelTest(_ name: String, key: CGKeyCode, mods: [Mod]) async {
        await focus()
        let before = toolbeltWindows()
        await press(key, mods)
        let opened = await waitUntil(4) { self.toolbeltWindows() > before }
        check(name, opened, "Toolbelt had \(before) windows before and \(toolbeltWindows()) after")
        guard opened else { return }
        await pause(0.4)
        keyEvent(CGKeyCode(kVK_Escape), down: true, flags: 0)
        keyEvent(CGKeyCode(kVK_Escape), down: false, flags: 0)
        check("… and Escape closes it", await waitUntil(4) { self.toolbeltWindows() <= before }, "still \(toolbeltWindows()) windows")
    }

    func get(_ address: String) async -> Int? {
        guard let url = URL(string: address) else { return nil }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    // MARK: - Stability

    /// Uses Toolbelt nonstop for `minutes`: shortcuts, held keys, typing, touches, clicks, copies and
    /// panels, over and over. Fails if Toolbelt crashes, misses triggers, or keeps using more memory.
    func stability() async {
        say("— Stability: \(Int(minutes)) minutes of nonstop use")
        let end = Date().addingTimeInterval(minutes * 60)
        let warmUp = Date().addingTimeInterval(min(120, minutes * 60 / 4))
        var rounds = 0
        var samples: [(Date, Int)] = []
        var lastSample = Date.distantPast
        var crashed = false
        while Date() < end {
            guard let toolbelt, !toolbelt.isTerminated else { crashed = true; break }
            rounds += 1
            await focus(clear: rounds % 10 == 0)
            await press(CGKeyCode(kVK_ANSI_1), Self.testMods)
            await pause(0.35)
            await press(CGKeyCode(kVK_ANSI_2), Self.testMods, hold: 0.1)
            await type("abc qqz ")
            await touch([(0.4, 0.5), (0.5, 0.5), (0.6, 0.5)], duration: 0.12)
            let middle = windowMiddle
            mouse(.otherMouseDown, at: middle, button: .center, number: 3)
            mouse(.otherMouseUp, at: middle, button: .center, number: 3)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Stability copy \(rounds) " + String(repeating: "x", count: 200), forType: .string)
            if rounds % 5 == 0 {
                await press(CGKeyCode(kVK_Space), [.leftOption])
                await pause(0.5)
                keyEvent(CGKeyCode(kVK_Escape), down: true, flags: 0)
                keyEvent(CGKeyCode(kVK_Escape), down: false, flags: 0)
            }
            await pause(0.6)
            if Date().timeIntervalSince(lastSample) >= 30, let rss = toolbeltRSS {
                lastSample = Date()
                samples.append((Date(), rss))
                say("  after \(rounds) rounds: \(rss / 1024) MB in use, \(count("plain")) shortcuts run")
            }
        }
        await pause(2)
        check("Toolbelt didn't crash in \(Int(minutes)) minutes", !crashed && !(toolbelt?.isTerminated ?? true), "stopped after \(rounds) rounds")
        let plain = count("plain")
        check("every shortcut press ran (\(rounds) presses)", plain >= rounds - max(1, rounds / 100), "ran \(plain) of \(rounds)")
        check("every held shortcut ran", count("b-down") >= rounds - max(1, rounds / 100), "ran \(count("b-down")) of \(rounds)")
        check("every pretend tap ran", count("tap3") >= rounds - max(1, rounds / 100), "ran \(count("tap3")) of \(rounds)")
        check("every mouse-button press ran", count("button4") >= rounds - max(1, rounds / 100), "ran \(count("button4")) of \(rounds)")
        check("every typed sequence ran", count("typed") >= rounds - max(1, rounds / 100), "ran \(count("typed")) of \(rounds)")
        let afterWarmUp = samples.filter { $0.0 >= warmUp }.map(\.1)
        if let first = afterWarmUp.first, let last = afterWarmUp.suffix(3).max(), afterWarmUp.count >= 3 {
            let growth = last - first
            check("memory stays level (\(first / 1024) MB → \(last / 1024) MB)", growth < 80 * 1024 || Double(last) < Double(first) * 1.5,
                  "grew by \(growth / 1024) MB")
        } else {
            check("memory measured", false, "only \(samples.count) samples")
        }
    }
}

/// A brown-orange square (#C86432, well inside what any screen shows), for the “colour at a point” condition.
final class SolidView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 200.0 / 255, green: 100.0 / 255, blue: 50.0 / 255, alpha: 1).setFill()
        bounds.fill()
    }
}

/// Blocks of different greys, for the “screen shows a picture” condition and clicking on a picture.
final class PatternView: NSView {
    var seed: UInt32 = 3
    /// Where it was clicked (in its own coordinates).
    var clicks: [CGPoint] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks.append(convert(event.locationInWindow, from: nil)) }

    override func draw(_ dirtyRect: NSRect) {
        var seed = self.seed
        let size: CGFloat = 10
        for row in 0..<Int(bounds.height / size) {
            for column in 0..<Int(bounds.width / size) {
                seed = seed &* 1_103_515_245 &+ 12345
                NSColor(white: CGFloat((seed >> 16) & 0xFF) / 255, alpha: 1).setFill()
                NSRect(x: CGFloat(column) * size, y: CGFloat(row) * size, width: size, height: size).fill()
            }
        }
    }
}

/// Notes every click, scroll and drag it gets, for checking the mouse actions.
final class InputPad: NSView {
    var log: [String] = []
    var dragStart: NSPoint?
    var dragDistance: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.withAlphaComponent(0.25).setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) {
        log.append("left \(event.clickCount)")
        dragStart = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        if log.last != "drag" { log.append("drag") }
        if let start = dragStart { dragDistance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) }
    }
    override func mouseUp(with event: NSEvent) {
        if log.last == "drag" { log.append("drop") }
    }
    override func rightMouseDown(with event: NSEvent) { log.append("right") }
    override func otherMouseDown(with event: NSEvent) { log.append("middle") }
    override func scrollWheel(with event: NSEvent) { log.append(event.scrollingDeltaY < 0 ? "scroll down" : "scroll up") }
}
