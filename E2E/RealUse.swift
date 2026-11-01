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
            rule(shortcut(kVK_ANSI_C), .system(.emptyTrash)),
        ]
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
        try JSONEncoder().encode(SavedMacros(macros: [macro, webMacro] + eventMacros, groups: []))
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
        await press(CGKeyCode(kVK_ANSI_C), Self.testMods)
        let emptied = trashed ? await waitUntil(25) { !FileManager.default.fileExists(atPath: (inTrash as URL?)?.path ?? "") } : false
        check("empty the Trash", emptied,
              "put in the Trash: \(trashed); still asking Finder: \(output("/usr/bin/pgrep", ["-lf", "empty trash"]).isEmpty ? "no" : "yes")")
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
