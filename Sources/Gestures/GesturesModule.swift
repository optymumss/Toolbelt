import AppKit
import SwiftUI

/// Gesture rules, saved in ~/Library/Application Support/Toolbelt/gestures.json.
@MainActor
final class GestureStore: ObservableObject {
    @Published var rules: [GestureRule] = [] {
        didSet { if rules != oldValue { save(); onChange?() } }
    }
    /// Conditional activation groups ("Browsers", "Not in a private window"…).
    @Published var groups: [ActivationGroup] = [] {
        didSet { if groups != oldValue { saveGroups(); onChange?() } }
    }
    /// Presets ("Work", "Home"…), and the one in use (nil: none, so only triggers in no preset work).
    @Published var presets: [TriggerPreset] = [] {
        didSet { if presets != oldValue { savePresets(); onChange?() } }
    }
    @Published var activePreset: UUID? = Prefs.activePreset {
        didSet { if activePreset != oldValue { Prefs.activePreset = activePreset; onChange?() } }
    }
    private let presetsFile = SettingsStore.folder.appendingPathComponent("presets.json")

    private func savePresets() {
        do {
            try JSONEncoder().encode(presets).write(to: presetsFile, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save presets: \(error)")
        }
    }

    /// Switches to the preset with this name ("" or no match: the next one, in turn).
    func switchPreset(named name: String) {
        if let preset = presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            activePreset = preset.id
        } else if !presets.isEmpty {
            let index = presets.firstIndex { $0.id == activePreset }.map { ($0 + 1) % presets.count } ?? 0
            activePreset = presets[index].id
        }
        HUD.show("Preset: \(presets.first { $0.id == activePreset }?.name ?? "none")", symbol: "square.stack")
        RealUseHooks.writeStatus()
    }
    var onChange: (() -> Void)?
    private let file = SettingsStore.folder.appendingPathComponent("gestures.json")
    private let groupsFile = SettingsStore.folder.appendingPathComponent("trigger-groups.json")

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([GestureRule].self, from: data) {
            rules = saved
        }
        if let data = try? Data(contentsOf: groupsFile), let saved = try? JSONDecoder().decode([ActivationGroup].self, from: data) {
            groups = saved
        }
        if let data = try? Data(contentsOf: presetsFile), let saved = try? JSONDecoder().decode([TriggerPreset].self, from: data) {
            presets = saved
        }
    }

    private func saveGroups() {
        do {
            try JSONEncoder().encode(groups).write(to: groupsFile, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save activation groups: \(error)")
        }
    }

    /// Brightness and volume on the trackpad, and sleep, as asked for in place of BetterTouchTool.
    /// Gestures that already have a rule are left as they are.
    static let controlSet: [GestureRule] = [
        GestureRule(gesture: .touch(.trackpad, .doubleTap, fingers: 4), action: .system(.brightnessUp)),
        GestureRule(gesture: .touch(.trackpad, .scrollDown, fingers: 4), action: .system(.brightnessDown)),
        GestureRule(gesture: .touch(.trackpad, .scrollLeft, fingers: 3), action: .system(.volumeDown)),
        GestureRule(gesture: .touch(.trackpad, .scrollRight, fingers: 3), action: .system(.volumeUp)),
        GestureRule(gesture: .touch(.trackpad, .swipeUp, fingers: 4), action: .system(.sleep)),
    ]

    func addControlSet() {
        let new = Self.controlSet.filter { preset in !rules.contains { $0.gesture == preset.gesture } }
        rules += new.map { var rule = $0; rule.id = UUID(); return rule }
    }

    private func save() {
        do {
            try JSONEncoder().encode(rules).write(to: file, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save gestures: \(error)")
        }
    }
}

/// Trackpad, Magic Mouse, mouse-button, mouse-stroke and keyboard gestures, each running an action.
@MainActor
final class GesturesModule: ToolbeltModule {
    let id = ModuleID.gestures
    let openTitle = "Triggers…"

    let store = GestureStore()
    let tap = GestureEventTap()
    let screenSpots = ScreenSpotWatcher()
    let runner: ActionRunner
    private let openSettings: () -> Void
    private var running = false
    private var typed = TypingBuffer()
    private var pendingSingleTap: DispatchWorkItem?
    private var shortcutKeys: [HotKey] = []
    private var lastRun: [UUID: Date] = [:]
    /// A watched shortcut being held: its timers (long hold, repeat) and whether it's been held long.
    private var heldKey: (rule: GestureRule, keyCode: Int, long: Bool, timers: [Timer])?
    /// After a watched shortcut is let go: waiting for every modifier key to be released.
    private var waitingForModifiers: GestureRule?
    /// Touch triggers waiting for the fingers to lift (release actions, repeats), per device.
    private var heldTouch: [TouchSource: (rules: [GestureRule], timer: Timer?)] = [:]
    /// For tests: every action run, in order.
    private(set) var actionLog: [MacroAction] = []
    private var triggersWindow: TriggersWindowController?
    /// For tests: what ran, most recent last.
    private(set) var log: [Gesture] = []
    /// More rules from other modules (macros started by a gesture or typed text).
    var extraRules: () -> [GestureRule] = { [] }
    /// Every rule that works now: this module's and other modules', in no preset or in the one in use.
    private var allRules: [GestureRule] {
        let active = store.activePreset
        return (store.rules + extraRules()).filter { TriggerPreset.allows($0, active: active) }
    }

    init(shortcuts: ShortcutCenter, openSettings: @escaping () -> Void = {}) {
        runner = ActionRunner(shortcuts: shortcuts)
        self.openSettings = openSettings
        store.onChange = { [weak self] in self?.updateListening() }
        tap.handle = { [weak self] gesture in self?.handle(gesture) ?? false }
        tap.onTyped = { [weak self] text in self?.typedText(text) }
        tap.onBackspace = { [weak self] in self?.typed.deleteBackward() }
        tap.onClick = { [weak self] in self?.typed.reset() }
        MultitouchReader.shared.onGesture = { [weak self] gesture in self?.handle(gesture) ?? false }
        MultitouchReader.shared.onLift = { [weak self] source in self?.fingersLifted(source) }
        tap.onKey = { [weak self] press in self?.keyEvent(press) ?? false }
        TriggersWindowController.openFromSettings = { [weak self] in self?.open() }
        ActionRunner.switchPreset = { [weak self] name in self?.store.switchPreset(named: name) }
        RealUseHooks.extraStatus["activePreset"] = { [weak self] in
            guard let store = self?.store else { return "" }
            return store.presets.first { $0.id == store.activePreset }?.name ?? ""
        }
        TriggersWindowController.stopLiveView = { [weak self] in self?.updateListening() }
    }

    func start() {
        running = true
        updateListening()
        KeyRemapper.shared.update(running: true)
    }

    func stop() {
        running = false
        updateListening()
        KeyRemapper.shared.update(running: false)
    }

    /// The Triggers window: every gesture, shortcut and key trigger, with its actions and conditions.
    func open() {
        if triggersWindow == nil { triggersWindow = TriggersWindowController(module: self) }
        triggersWindow?.show()
    }

    var triggersWindowController: TriggersWindowController? { triggersWindow }

    /// Listens only to the devices the enabled rules use, and asks for permission only then.
    func updateListening() {
        let rules = running ? allRules.filter(\.enabled) : []
        var needs = GestureEventTap.Needs()
        var touches = false
        var scrolls = false
        var holds = false
        var spots = false
        for rule in rules {
            switch rule.gesture {
            case let .touch(_, kind, _):
                touches = true
                if kind.isScroll { scrolls = true }
                if kind == .touchStart || kind == .longTouch { holds = true }
                if kind == .forceClick { needs.forceClick = true }
                if kind == .click || kind.isCorner || kind == .clickMiddle { needs.clicks = true }
            case .mouseButton(let button): needs.buttons.insert(button)
            case .stroke(let button, _): needs.strokeButtons.insert(button)
            case .modifierTap, .keySequence: needs.keyboard = true
            case .shortcut: if rule.needsKeyWatching { needs.watchedKeys = true } // others: registered below, no permission needed
            case .wheel(let button, _): if button == 0 { needs.wheelTilt = true } else { needs.wheelButtons.insert(button) }
            case .screenSpot: spots = true
            }
        }
        // Keyboard shortcuts, through macOS's own hot keys.
        shortcutKeys.forEach { $0.unregister() }
        shortcutKeys = []
        var registered = Set<Gesture>()
        for rule in rules {
            guard case let .shortcut(keyCode, modifiers) = rule.gesture, keyCode != 0 || modifiers != 0, !rule.needsKeyWatching,
                  registered.insert(rule.gesture).inserted else { continue }
            let gesture = rule.gesture
            let key = HotKey(shortcut: Shortcut(keyCode: keyCode, modifiers: modifiers)) { [weak self] in _ = self?.handle(gesture) }
            if key.isRegistered { shortcutKeys.append(key) }
        }
        MultitouchReader.shared.setScrolls(scrolls)
        MultitouchReader.shared.setHolds(holds)
        MultitouchReader.shared.setSensitivity(Prefs.gestureSensitivity)
        if touches { MultitouchReader.shared.start() } else { MultitouchReader.shared.stop() }
        screenSpots.watch(spots) { [weak self] spot in _ = self?.handle(.screenSpot(spot)) }
        let mouse = !needs.buttons.isEmpty || !needs.strokeButtons.isEmpty || needs.clicks || needs.forceClick
            || needs.wheelTilt || !needs.wheelButtons.isEmpty
        if mouse, !PermissionGate.ensure(.accessibility, to: "use mouse gestures") {
            needs.buttons = []
            needs.strokeButtons = []
            needs.clicks = false
            needs.forceClick = false
            needs.wheelTilt = false
            needs.wheelButtons = []
        }
        if needs.watchedKeys, !(PermissionGate.ensure(.inputMonitoring, to: "notice keys being held and let go")
                                && PermissionGate.ensure(.accessibility, to: "keep a shortcut's keys from the app in front")) {
            needs.watchedKeys = false
        }
        if needs.keyboard, !PermissionGate.ensure(.inputMonitoring, to: "notice key taps and typed sequences") {
            needs.keyboard = false
        }
        tap.update(needs)
    }

    /// The rules that apply to a gesture right now (app in front, activation groups, conditions).
    func matches(for gesture: Gesture, app: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier) -> [GestureRule] {
        GestureRule.matches(gesture, app: app, in: allRules, groups: store.groups, context: { ConditionContext.current() })
    }

    /// Runs the rules for a gesture, if any apply. Returns whether one ran.
    @discardableResult
    func handle(_ gesture: Gesture) -> Bool {
        // A single tap waits a moment when the same key or fingers also have a double-tap rule.
        if let double = gesture.doubleTapVersion {
            if double == gesture {
                pendingSingleTap?.cancel()
                pendingSingleTap = nil
            } else if !matches(for: double).isEmpty {
                let rules = matches(for: gesture)
                guard !rules.isEmpty else { return false }
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.runAll(rules, for: gesture) }
                }
                pendingSingleTap = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                return true
            }
        }
        let rules = matches(for: gesture)
        guard !rules.isEmpty else { return false }
        // Typing just now: a palm brushing the trackpad isn't a gesture.
        if case .touch = gesture, Self.typedRecently() { return false }
        // Run after the event has been dealt with, so the tap is never held up.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.runAll(rules, for: gesture) }
        }
        return true
    }

    private func runAll(_ rules: [GestureRule], for gesture: Gesture) {
        for rule in rules { run(rule, for: gesture) }
    }

    /// Runs one rule's actions (also used by the ▶︎ button in the Triggers window).
    func run(_ rule: GestureRule, for gesture: Gesture) {
        // A keyboard trigger whose action presses its own keys mustn't set itself off again and again.
        if rule.isKeyboard, rule.preventRecursion != false, let last = lastRun[rule.id], Date().timeIntervalSince(last) < 0.3 { return }
        lastRun[rule.id] = Date()
        log.append(gesture)
        if log.count > 50 { log.removeFirst() }
        if rule.showHUD == true {
            HUD.show(rule.hasNotes ? rule.notes ?? "" : rule.gesture.title, detail: rule.summary, symbol: "hand.tap")
        }
        perform(rule.actions)
        // Touch triggers with release actions or repeats wait for the fingers to lift.
        if case let .touch(source, kind, _) = gesture, !kind.isScroll,
           rule.repeatWhileHeld == true || !rule.actions(for: .release).isEmpty {
            var held = heldTouch[source] ?? ([], nil)
            held.rules.append(rule)
            if rule.repeatWhileHeld == true, held.timer == nil {
                held.timer = repeatTimer(for: rule)
            }
            heldTouch[source] = held
        }
    }

    private func perform(_ actions: [MacroAction]) {
        for action in actions {
            actionLog.append(action)
            if actionLog.count > 200 { actionLog.removeFirst() }
            runner.run(action)
        }
    }

    /// Runs a trigger's actions again and again (after a short wait) until stopped.
    private func repeatTimer(for rule: GestureRule) -> Timer {
        let interval = 1 / max(1, min(60, rule.repeatRate ?? 10))
        let delay = max(0.05, rule.repeatDelay ?? 0.4)
        let timer = Timer(fire: Date().addingTimeInterval(delay), interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(rule.actions) }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Every finger left the device: stop repeats and run "when the fingers lift" actions.
    func fingersLifted(_ source: TouchSource) {
        guard let held = heldTouch.removeValue(forKey: source) else { return }
        held.timer?.invalidate()
        for rule in held.rules { perform(rule.actions(for: .release)) }
    }

    // MARK: Watched keyboard shortcuts (key up, long hold, repeat, sides, layout)

    /// The watched shortcut a key press matches, if any applies right now.
    private func watchedRule(for press: KeyPress) -> GestureRule? {
        let candidates = allRules.filter {
            $0.enabled && $0.needsKeyWatching && ShortcutMatch.matches($0, keyCode: press.keyCode, flags: press.flags, character: press.character)
        }
        for rule in candidates {
            if let chosen = matches(for: rule.gesture).first(where: { $0.id == rule.id }) { return chosen }
        }
        return nil
    }

    /// Handles a key going down or up. Returns true when the key belongs to a watched shortcut (kept from apps).
    @discardableResult
    func keyEvent(_ press: KeyPress) -> Bool {
        switch press.kind {
        case .down:
            if let held = heldKey, held.keyCode == press.keyCode { return true } // the key repeating while held
            guard !press.isRepeat, let rule = watchedRule(for: press) else { return false }
            run(rule, for: rule.gesture)
            var timers: [Timer] = []
            let longHold = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, var held = self.heldKey, held.rule.id == rule.id else { return }
                    held.long = true
                    self.heldKey = held
                    self.perform(rule.actions(for: .longHold))
                }
            }
            RunLoop.main.add(longHold, forMode: .common)
            timers.append(longHold)
            if rule.repeatWhileHeld == true { timers.append(repeatTimer(for: rule)) }
            heldKey = (rule, press.keyCode, false, timers)
            return true
        case .up:
            guard let held = heldKey, held.keyCode == press.keyCode else { return false }
            heldKey = nil
            held.timers.forEach { $0.invalidate() }
            perform(held.rule.actions(for: .release))
            perform(held.rule.actions(for: held.long ? .releaseAfterLongHold : .quickRelease))
            if ShortcutMatch.carbonModifiers(press.flags) == 0 {
                perform(held.rule.actions(for: .modifiersReleased))
            } else {
                waitingForModifiers = held.rule
            }
            return true
        case .flags:
            if let rule = waitingForModifiers, ShortcutMatch.carbonModifiers(press.flags) == 0 {
                waitingForModifiers = nil
                perform(rule.actions(for: .modifiersReleased))
            }
            return false
        }
    }

    /// Whether a key was pressed within the "ignore the trackpad after typing" time. Asks macOS when the
    /// last key went down, which needs no permission and costs nothing while no gesture happens.
    static func typedRecently(pause: Double? = nil) -> Bool {
        let pause = pause ?? Prefs.gestureTypingPause
        guard pause > 0 else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < pause
    }

    private func typedText(_ text: String) {
        typed.type(text)
        for rule in allRules where rule.enabled {
            guard case .keySequence(let sequence) = rule.gesture, !sequence.isEmpty, typed.text.hasSuffix(sequence) else { continue }
            let chosen = matches(for: rule.gesture)
            guard let first = chosen.first else { continue }
            typed.reset()
            let count = first.deleteTyped ? sequence.count : 0
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    for _ in 0..<count { TextInserter.press(CGKeyCode(51)) }
                    self?.runAll(chosen, for: rule.gesture)
                }
            }
            return
        }
    }

    func menuItems() -> [NSMenuItem] { [] }

    func settingsView() -> AnyView {
        AnyView(GesturesSettingsTab(store: store))
    }

    func willTerminate() {
        shortcutKeys.forEach { $0.unregister() }
        tap.stop()
        KeyRemapper.shared.update(running: false) // puts the keys back
        MultitouchReader.shared.stop()
    }
}

// MARK: - Settings

struct GesturesSettingsTab: View {
    @ObservedObject var store: GestureStore
    @ObservedObject private var settings = GestureSettings.shared
    @State private var expanded: UUID?

    var body: some View {
        Group {
            Section {
                if store.rules.isEmpty {
                    Text("No gestures yet. Add one below: for example a three-finger tap that opens the launcher, or tapping Right ⌘ twice for the clipboard.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($store.rules) { $rule in
                    GestureRuleRow(rule: $rule, inUse: Set(store.rules.filter { $0.id != rule.id }.map(\.gesture)), expanded: expanded == rule.id,
                                   toggle: { expanded = expanded == rule.id ? nil : rule.id },
                                   remove: { store.rules.removeAll { $0.id == rule.id } })
                }
                Menu("Add Gesture") {
                    ForEach(Self.templates.indices, id: \.self) { index in
                        Button(Self.templates[index].0) {
                            let rule = GestureRule(gesture: Self.templates[index].1, action: .toolbelt(.openLauncher))
                            store.rules.append(rule)
                            expanded = rule.id
                        }
                    }
                }
                .fixedSize()
                Button("Open the Triggers Window…") { TriggersWindowController.openFromSettings?() }
                Button("Add Brightness, Volume and Sleep Gestures") { store.addControlSet() }
                    .help("Four-finger double tap: brightness up · four-finger scroll down: brightness down · three-finger scroll left / right: volume down / up · four-finger swipe up: sleep")
            } header: {
                Text("Gestures")
            } footer: {
                let reader = MultitouchReader.shared.status
                Label(reader.text, systemImage: reader.isProblem ? "exclamationmark.triangle" : "hand.point.up.left")
                    .font(.caption)
                    .foregroundStyle(reader.isProblem ? Color.orange : Color.secondary)
                Text("Trackpad and Magic Mouse gestures work alongside macOS's own; switch off any of macOS's you replace in System Settings → Trackpad (for the four-finger set above: More Gestures → Mission Control and App Exposé off). A double tap makes a single tap with the same fingers wait a moment. Scrolls repeat while your fingers keep sliding; swipes happen once. Mouse buttons and strokes need Accessibility; key taps and typed sequences need Input Monitoring. Toolbelt only listens while a gesture needs it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            KeyRemapSettings()
            Section {
                LabeledContent("Sensitivity") {
                    HStack {
                        Text("Easier to trigger").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.gestureSensitivity, in: 0.6...1.6, step: 0.1)
                            .frame(maxWidth: 220)
                            .onChange(of: settings.gestureSensitivity) { _, value in MultitouchReader.shared.setSensitivity(value) }
                        Text("Harder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("After typing, ignore the trackpad for", selection: $settings.gestureTypingPause) {
                    Text("No time (off)").tag(0.0)
                    Text("0.3 seconds").tag(0.3)
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                }
            } header: {
                Text("Trackpad and Magic Mouse")
            } footer: {
                Text("Harder to trigger means swipes and scrolls need longer slides, and taps must be quicker and stiller. Ignoring the trackpad after typing stops a resting palm from setting off gestures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static let templates: [(String, Gesture)] = [
        ("Trackpad: tap with three fingers", .touch(.trackpad, .tap, fingers: 3)),
        ("Trackpad: double tap with four fingers", .touch(.trackpad, .doubleTap, fingers: 4)),
        ("Trackpad: scroll with three fingers (repeats)", .touch(.trackpad, .scrollRight, fingers: 3)),
        ("Trackpad: swipe with four fingers", .touch(.trackpad, .swipeUp, fingers: 4)),
        ("Trackpad: pinch", .touch(.trackpad, .pinchIn, fingers: 4)),
        ("Trackpad: click with three fingers", .touch(.trackpad, .click, fingers: 3)),
        ("Trackpad: click a corner", .touch(.trackpad, .cornerBottomRight, fingers: 1)),
        ("Magic Mouse: swipe", .touch(.magicMouse, .swipeLeft, fingers: 2)),
        ("Magic Mouse: tap", .touch(.magicMouse, .tap, fingers: 2)),
        ("Mouse: extra button", .mouseButton(3)),
        ("Mouse: hold the right button and draw", .stroke(button: 1, path: "L")),
        ("Mouse: tilt the wheel", .wheel(button: 0, direction: "L")),
        ("Mouse: hold a button and scroll", .wheel(button: 2, direction: "U")),
        ("Screen: pointer to a corner or edge", .screenSpot(.topLeft)),
        ("Trackpad: rotate two fingers", .touch(.trackpad, .rotateRight, fingers: 2)),
        ("Trackpad: swipe in from an edge", .touch(.trackpad, .edgeSwipeFromRight, fingers: 2)),
        ("Trackpad: TipSwipe (one finger resting)", .touch(.trackpad, .tipSwipeLeft, fingers: 3)),
        ("Keyboard: tap a modifier key twice", .modifierTap(.rightCommand, taps: 2)),
        ("Keyboard: type a sequence", .keySequence(";;")),
        ("Keyboard: shortcut", .shortcut(keyCode: 0, modifiers: 0)),
    ]
}

struct GestureRuleRow: View {
    @Binding var rule: GestureRule
    /// Gestures other rules already use, marked in the picker.
    var inUse: Set<Gesture> = []
    let expanded: Bool
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.gesture.title)
                    Text(rule.summary + (rule.scope == .everywhere ? "" : " · \(rule.scope.title.lowercased()) \(rule.apps.count) app\(rule.apps.count == 1 ? "" : "s")"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? "Done" : "Edit", action: toggle)
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            if expanded {
                GestureEditor(gesture: $rule.gesture, deleteTyped: $rule.deleteTyped, inUse: inUse)
                ActionEditor(action: $rule.action)
                // More actions, run one after another (like BetterTouchTool's action list).
                ForEach(Array((rule.moreActions ?? []).indices), id: \.self) { index in
                    HStack(alignment: .top) {
                        Text("then").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        ActionEditor(action: Binding(
                            get: { (rule.moreActions ?? [])[safe: index] ?? MacroAction(kind: .system) },
                            set: { if rule.moreActions?.indices.contains(index) == true { rule.moreActions?[index] = $0 } }))
                        Button { rule.moreActions?.remove(at: index); if rule.moreActions?.isEmpty == true { rule.moreActions = nil } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Another Action") { rule.moreActions = (rule.moreActions ?? []) + [MacroAction(kind: .system)] }
                AppScopeEditor(scope: $rule.scope, apps: $rule.apps)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Pickers for the parts of a gesture.
struct GestureEditor: View {
    @Binding var gesture: Gesture
    @Binding var deleteTyped: Bool
    var inUse: Set<Gesture> = []

    var body: some View {
        switch gesture {
        case let .touch(source, kind, fingers):
            HStack {
                Picker("Device", selection: Binding(get: { source }, set: { newSource in
                    // Keep the same gesture if the other device has it, otherwise its first one-finger gesture.
                    let choices = TouchKind.choices(for: newSource)
                    let keeps = choices.first { $0.fingers == fingers }?.kinds.contains(kind) == true
                    gesture = keeps ? .touch(newSource, kind, fingers: fingers) : .touch(newSource, .tap, fingers: choices[0].fingers)
                })) {
                    ForEach(TouchSource.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                // Grouped by the number of fingers, like BetterTouchTool's list; gestures other rules use are marked.
                Menu(gesture.title.replacingOccurrences(of: "\(source.title): ", with: "")) {
                    ForEach(TouchKind.choices(for: source), id: \.fingers) { group in
                        Section(group.fingers == 1 ? "One finger" : "\(Self.number(group.fingers)) fingers") {
                            ForEach(group.kinds) { choice in
                                let option = Gesture.touch(source, choice, fingers: group.fingers)
                                Button {
                                    gesture = option
                                } label: {
                                    let mark = option == gesture ? "✓ " : ""
                                    Text(mark + choice.title + (inUse.contains(option) ? "  · in use" : ""))
                                }
                            }
                        }
                    }
                }
                .help("Choose a gesture. “In use” ones already have a rule.")
                if inUse.contains(gesture) {
                    Text("Another rule uses this gesture").font(.caption).foregroundStyle(.orange)
                }
            }
        case .mouseButton(let button):
            Picker("Button", selection: Binding(get: { button }, set: { gesture = .mouseButton($0) })) {
                Text("Middle (3)").tag(2)
                ForEach(3...9, id: \.self) { Text("Button \($0 + 1)\($0 == 3 ? " (usually Back)" : $0 == 4 ? " (usually Forward)" : "")").tag($0) }
            }
        case let .stroke(button, path):
            HStack {
                Picker("Hold", selection: Binding(get: { button }, set: { gesture = .stroke(button: $0, path: path) })) {
                    Text("Right button").tag(1)
                    Text("Middle button").tag(2)
                }
                TextField("Directions, e.g. L or DR", text: Binding(
                    get: { path },
                    set: { gesture = .stroke(button: button, path: String($0.uppercased().filter { "UDLR".contains($0) }.prefix(4))) }))
                    .help("U up, D down, L left, R right — for example DR draws down then right")
            }
        case let .modifierTap(key, taps):
            HStack {
                Picker("Key", selection: Binding(get: { key }, set: { gesture = .modifierTap($0, taps: taps) })) {
                    ForEach(ModifierKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Taps", selection: Binding(get: { taps }, set: { gesture = .modifierTap(key, taps: $0) })) {
                    Text("Once").tag(1)
                    Text("Twice").tag(2)
                }
                .fixedSize()
            }
        case .shortcut:
            // Read the gesture afresh each time: the recorder sets the key, then the modifiers.
            KeyCapture(keyCode: Binding(get: { shortcutParts.key }, set: { gesture = .shortcut(keyCode: $0, modifiers: shortcutParts.modifiers) }),
                       modifiers: Binding(get: { shortcutParts.modifiers }, set: { gesture = .shortcut(keyCode: shortcutParts.key, modifiers: $0) }))
        case .keySequence(let keys):
            HStack {
                TextField("Typed sequence, e.g. ;;", text: Binding(get: { keys }, set: { gesture = .keySequence($0) }))
                Toggle("Delete what I typed", isOn: $deleteTyped)
            }
        case let .wheel(button, direction):
            HStack {
                Picker("Wheel", selection: Binding(get: { button }, set: { newButton in
                    // Tilting goes only left or right.
                    gesture = .wheel(button: newButton, direction: newButton == 0 && !"LR".contains(direction) ? "L" : direction)
                })) {
                    Text("Tilt it (no button)").tag(0)
                    Text("Hold the middle button and scroll").tag(2)
                    Text("Hold button 4 and scroll").tag(3)
                    Text("Hold button 5 and scroll").tag(4)
                }
                Picker("Direction", selection: Binding(get: { direction }, set: { gesture = .wheel(button: button, direction: $0) })) {
                    if button != 0 {
                        Text("Up").tag("U")
                        Text("Down").tag("D")
                    }
                    Text("Left").tag("L")
                    Text("Right").tag("R")
                }
                .fixedSize()
            }
        case .screenSpot(let spot):
            Picker("Move the pointer to the", selection: Binding(get: { spot }, set: { gesture = .screenSpot($0) })) {
                ForEach(ScreenSpot.allCases) { Text($0.title).tag($0) }
            }
            Text("Push the pointer into it and hold it there a moment. Runs once until the pointer leaves.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension GestureEditor {
    var shortcutParts: (key: Int, modifiers: Int) {
        if case let .shortcut(key, modifiers) = gesture { return (key, modifiers) }
        return (0, 0)
    }

    static func number(_ count: Int) -> String {
        ["Zero", "One", "Two", "Three", "Four", "Five"][min(max(count, 0), 5)]
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// "In every app", "Only in" or "Everywhere except", and the apps.
struct AppScopeEditor: View {
    @Binding var scope: GestureRule.AppScope
    @Binding var apps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Where", selection: $scope) {
                ForEach(GestureRule.AppScope.allCases) { Text($0.title).tag($0) }
            }
            if scope != .everywhere {
                ForEach(apps, id: \.self) { bundleID in
                    HStack {
                        Text(Self.name(of: bundleID))
                        Spacer()
                        Button { apps.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                Button("Add App…") {
                    if let url = ActionEditor.chooseApp(), let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) {
                        apps.append(id)
                    }
                }
            }
        }
    }

    static func name(of bundleID: String) -> String { AppNames.name(of: bundleID) }
}

enum AppNames {
    /// "Safari" for com.apple.Safari, or the identifier itself if the app isn't installed.
    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// The trackpad settings, observable for the Settings tab (stored in Prefs).
@MainActor
final class GestureSettings: ObservableObject {
    static let shared = GestureSettings()
    @Published var gestureSensitivity = Prefs.gestureSensitivity { didSet { Prefs.gestureSensitivity = gestureSensitivity } }
    @Published var gestureTypingPause = Prefs.gestureTypingPause { didSet { Prefs.gestureTypingPause = gestureTypingPause } }
}
