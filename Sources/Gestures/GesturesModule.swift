import AppKit
import SwiftUI

/// Gesture rules, saved in ~/Library/Application Support/Toolbelt/gestures.json.
@MainActor
final class GestureStore: ObservableObject {
    @Published var rules: [GestureRule] = [] {
        didSet { if rules != oldValue { save(); onChange?() } }
    }
    var onChange: (() -> Void)?
    private let file = SettingsStore.folder.appendingPathComponent("gestures.json")

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([GestureRule].self, from: data) {
            rules = saved
        }
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
    let openTitle = "Gestures…"

    let store = GestureStore()
    let tap = GestureEventTap()
    let runner: ActionRunner
    private let openSettings: () -> Void
    private var running = false
    private var typed = TypingBuffer()
    private var pendingSingleTap: DispatchWorkItem?
    /// For tests: what ran, most recent last.
    private(set) var log: [Gesture] = []
    /// More rules from other modules (macros started by a gesture or typed text).
    var extraRules: () -> [GestureRule] = { [] }
    private var allRules: [GestureRule] { store.rules + extraRules() }

    init(shortcuts: ShortcutCenter, openSettings: @escaping () -> Void = {}) {
        runner = ActionRunner(shortcuts: shortcuts)
        self.openSettings = openSettings
        store.onChange = { [weak self] in self?.updateListening() }
        tap.handle = { [weak self] gesture in self?.handle(gesture) ?? false }
        tap.onTyped = { [weak self] text in self?.typedText(text) }
        tap.onBackspace = { [weak self] in self?.typed.deleteBackward() }
        tap.onClick = { [weak self] in self?.typed.reset() }
        MultitouchReader.shared.onGesture = { [weak self] gesture in _ = self?.handle(gesture) }
    }

    func start() {
        running = true
        updateListening()
    }

    func stop() {
        running = false
        updateListening()
    }

    func open() {
        openSettings()
    }

    /// Listens only to the devices the enabled rules use, and asks for permission only then.
    func updateListening() {
        let rules = running ? allRules.filter(\.enabled) : []
        var needs = GestureEventTap.Needs()
        var touches = false
        for rule in rules {
            switch rule.gesture {
            case let .touch(_, kind, _):
                touches = true
                if kind == .click || kind.isCorner { needs.clicks = true }
            case .mouseButton(let button): needs.buttons.insert(button)
            case .stroke(let button, _): needs.strokeButtons.insert(button)
            case .modifierTap, .keySequence: needs.keyboard = true
            }
        }
        if touches { MultitouchReader.shared.start() } else { MultitouchReader.shared.stop() }
        let mouse = !needs.buttons.isEmpty || !needs.strokeButtons.isEmpty || needs.clicks
        if mouse, !PermissionGate.ensure(.accessibility, to: "use mouse gestures") {
            needs.buttons = []
            needs.strokeButtons = []
            needs.clicks = false
        }
        if needs.keyboard, !PermissionGate.ensure(.inputMonitoring, to: "notice key taps and typed sequences") {
            needs.keyboard = false
        }
        tap.update(needs)
    }

    /// Runs the rule for a gesture, if there's one for the app in front. Returns whether one ran.
    @discardableResult
    func handle(_ gesture: Gesture) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // A single tap waits a moment when the same key also has a double-tap rule.
        if case let .modifierTap(key, taps) = gesture {
            if taps == 2 {
                pendingSingleTap?.cancel()
                pendingSingleTap = nil
            } else if GestureRule.match(.modifierTap(key, taps: 2), app: app, in: allRules) != nil {
                guard let rule = GestureRule.match(gesture, app: app, in: allRules) else { return false }
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.run(rule, for: gesture) }
                }
                pendingSingleTap = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                return true
            }
        }
        guard let rule = GestureRule.match(gesture, app: app, in: allRules) else { return false }
        // Run after the event has been dealt with, so the tap is never held up.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.run(rule, for: gesture) }
        }
        return true
    }

    private func run(_ rule: GestureRule, for gesture: Gesture) {
        log.append(gesture)
        if log.count > 50 { log.removeFirst() }
        runner.run(rule.action)
    }

    private func typedText(_ text: String) {
        typed.type(text)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for rule in allRules where rule.enabled && rule.applies(in: app) {
            guard case .keySequence(let sequence) = rule.gesture, !sequence.isEmpty, typed.text.hasSuffix(sequence) else { continue }
            typed.reset()
            let count = rule.deleteTyped ? sequence.count : 0
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    for _ in 0..<count { TextInserter.press(CGKeyCode(51)) }
                    self?.run(rule, for: rule.gesture)
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
        tap.stop()
        MultitouchReader.shared.stop()
    }
}

// MARK: - Settings

struct GesturesSettingsTab: View {
    @ObservedObject var store: GestureStore
    @State private var expanded: UUID?

    var body: some View {
        Group {
            Section {
                if store.rules.isEmpty {
                    Text("No gestures yet. Add one below: for example a three-finger tap that opens the launcher, or tapping Right ⌘ twice for the clipboard.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($store.rules) { $rule in
                    GestureRuleRow(rule: $rule, expanded: expanded == rule.id,
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
            } header: {
                Text("Gestures")
            } footer: {
                let reader = MultitouchReader.shared.status
                Label(reader.text, systemImage: reader.isProblem ? "exclamationmark.triangle" : "hand.point.up.left")
                    .font(.caption)
                    .foregroundStyle(reader.isProblem ? Color.orange : Color.secondary)
                Text("Trackpad and Magic Mouse gestures work alongside macOS's own; switch off any of macOS's you replace in System Settings → Trackpad. Mouse buttons and strokes need Accessibility; key taps and typed sequences need Input Monitoring. Toolbelt only listens while a gesture needs it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static let templates: [(String, Gesture)] = [
        ("Trackpad: tap with three fingers", .touch(.trackpad, .tap, fingers: 3)),
        ("Trackpad: swipe with four fingers", .touch(.trackpad, .swipeUp, fingers: 4)),
        ("Trackpad: pinch", .touch(.trackpad, .pinchIn, fingers: 4)),
        ("Trackpad: click with three fingers", .touch(.trackpad, .click, fingers: 3)),
        ("Trackpad: click a corner", .touch(.trackpad, .cornerBottomRight, fingers: 1)),
        ("Magic Mouse: swipe", .touch(.magicMouse, .swipeLeft, fingers: 2)),
        ("Magic Mouse: tap", .touch(.magicMouse, .tap, fingers: 2)),
        ("Mouse: extra button", .mouseButton(3)),
        ("Mouse: hold the right button and draw", .stroke(button: 1, path: "L")),
        ("Keyboard: tap a modifier key twice", .modifierTap(.rightCommand, taps: 2)),
        ("Keyboard: type a sequence", .keySequence(";;")),
    ]
}

struct GestureRuleRow: View {
    @Binding var rule: GestureRule
    let expanded: Bool
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.gesture.title)
                    Text(rule.action.summary + (rule.scope == .everywhere ? "" : " · \(rule.scope.title.lowercased()) \(rule.apps.count) app\(rule.apps.count == 1 ? "" : "s")"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? "Done" : "Edit", action: toggle)
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            if expanded {
                GestureEditor(gesture: $rule.gesture, deleteTyped: $rule.deleteTyped)
                ActionEditor(action: $rule.action)
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

    var body: some View {
        switch gesture {
        case let .touch(source, kind, fingers):
            HStack {
                Picker("Device", selection: Binding(get: { source }, set: { gesture = .touch($0, kind, fingers: fingers) })) {
                    ForEach(TouchSource.allCases) { Text($0.title).tag($0) }
                }
                Picker("Gesture", selection: Binding(get: { kind }, set: { gesture = .touch(source, $0, fingers: $0.isCorner ? 1 : max(fingers, 2)) })) {
                    ForEach(TouchKind.allCases) { Text($0.title).tag($0) }
                }
                if !kind.isCorner {
                    Picker("Fingers", selection: Binding(get: { fingers }, set: { gesture = .touch(source, kind, fingers: $0) })) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .fixedSize()
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
        case .keySequence(let keys):
            HStack {
                TextField("Typed sequence, e.g. ;;", text: Binding(get: { keys }, set: { gesture = .keySequence($0) }))
                Toggle("Delete what I typed", isOn: $deleteTyped)
            }
        }
    }
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
