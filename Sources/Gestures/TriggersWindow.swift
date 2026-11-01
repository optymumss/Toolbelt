import AppKit
import Combine
import SwiftUI

// The Triggers window: one place for every gesture, shortcut and key trigger, laid out in four columns
// like BetterTouchTool's: where it applies (all apps, an app, an activation group) · the triggers of a
// kind · the selected trigger's actions · its settings (notes, on-screen message, conditions…).

/// What the window is showing; also lets the screenshot check open it on a particular trigger or group.
@MainActor
final class TriggersState: ObservableObject {
    enum Scope: Hashable {
        case all, app(String), group(UUID)
    }

    @Published var scope: Scope = .all
    @Published var category: TriggerCategory = .all
    @Published var selected: UUID?
    /// The activation group being edited in a sheet.
    @Published var editingGroup: UUID?
    /// The selected trigger's own conditions are being edited in a sheet.
    @Published var editingCondition = false
    /// Apps added to the sidebar that have no triggers yet.
    @Published var extraApps: [String] = []
}

enum TriggerCategory: String, CaseIterable, Identifiable {
    case all, trackpad, magicMouse, mouseButtons, drawings, screenSpots, shortcuts, keyTaps, typed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All triggers"
        case .trackpad: return "Trackpad"
        case .magicMouse: return "Magic Mouse"
        case .mouseButtons: return "Mouse buttons"
        case .drawings: return "Drawings (mouse gestures)"
        case .screenSpots: return "Screen corners and edges"
        case .shortcuts: return "Keyboard shortcuts"
        case .keyTaps: return "Modifier key taps"
        case .typed: return "Typed sequences"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .magicMouse: return "magicmouse"
        case .mouseButtons: return "computermouse"
        case .drawings: return "scribble"
        case .screenSpots: return "rectangle.dashed"
        case .shortcuts: return "command"
        case .keyTaps: return "shift"
        case .typed: return "character.cursor.ibeam"
        }
    }

    func contains(_ gesture: Gesture) -> Bool {
        switch (self, gesture) {
        case (.all, _): return true
        case let (.trackpad, .touch(source, _, _)): return source == .trackpad
        case let (.magicMouse, .touch(source, _, _)): return source == .magicMouse
        case (.mouseButtons, .mouseButton), (.mouseButtons, .wheel), (.drawings, .stroke), (.screenSpots, .screenSpot), (.shortcuts, .shortcut), (.keyTaps, .modifierTap), (.typed, .keySequence):
            return true
        default: return false
        }
    }

    /// What a new trigger of this kind starts as.
    var template: Gesture {
        switch self {
        case .all, .trackpad: return .touch(.trackpad, .tap, fingers: 3)
        case .magicMouse: return .touch(.magicMouse, .tap, fingers: 2)
        case .mouseButtons: return .mouseButton(3)
        case .drawings: return .stroke(button: 1, path: "L")
        case .screenSpots: return .screenSpot(.topLeft)
        case .shortcuts: return .shortcut(keyCode: 0, modifiers: 0)
        case .keyTaps: return .modifierTap(.rightCommand, taps: 2)
        case .typed: return .keySequence(";;")
        }
    }
}

@MainActor
final class TriggersWindowController {
    /// Lets Settings → Gestures open the window.
    static var openFromSettings: (() -> Void)?
    /// Stops the trackpad reader again if no gesture needs it (after the Live View closes).
    static var stopLiveView: (() -> Void)?

    let window: NSWindow
    let state = TriggersState()

    init(module: GesturesModule) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 720),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Triggers"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 980, height: 560)
        window.contentViewController = NSHostingController(rootView: TriggersView(module: module, store: module.store, state: state))
        // As big as fits: smaller screens get a smaller window rather than one running off the edge.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        window.setContentSize(NSSize(width: min(1240, screen.width - 40), height: min(720, screen.height - 40)))
        window.center()
        window.setFrameAutosaveName("ToolbeltTriggers")
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct TriggersView: View {
    let module: GesturesModule
    @ObservedObject var store: GestureStore
    @ObservedObject var state: TriggersState

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                categoryBar
                Divider()
                triggerList
            }
            .frame(minWidth: 280)
            Divider()
            actionsColumn.frame(minWidth: 240)
            Divider()
            settingsColumn.frame(width: 280)
        }
        .sheet(isPresented: Binding(get: { state.editingGroup != nil }, set: { if !$0 { state.editingGroup = nil } })) {
            if let id = state.editingGroup, let index = store.groups.firstIndex(where: { $0.id == id }) {
                ConditionEditorSheet(title: "Activation group", name: store.groups[index].name, condition: store.groups[index].condition) { name, condition in
                    if let index = store.groups.firstIndex(where: { $0.id == id }) {
                        store.groups[index].name = name.isEmpty ? "Group" : name
                        store.groups[index].condition = condition
                    }
                }
            }
        }
        .sheet(isPresented: $state.editingCondition) {
            if let id = state.selected, let rule = store.rules.first(where: { $0.id == id }) {
                ConditionEditorSheet(title: "Conditions for “\(rule.gesture.title)”", name: nil, condition: rule.condition ?? ConditionGroup()) { _, condition in
                    if let index = store.rules.firstIndex(where: { $0.id == id }) {
                        store.rules[index].condition = condition.isEmpty ? nil : condition
                    }
                }
            }
        }
    }

    // MARK: Column 1: where triggers apply

    private var apps: [String] {
        let used = store.rules.filter { $0.scope == .only }.flatMap(\.apps)
        var seen = Set<String>()
        return (used + state.extraApps).filter { seen.insert($0).inserted }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<TriggersState.Scope?>(get: { state.scope }, set: { if let new = $0 { state.scope = new; state.selected = nil } })) {
                Label("For All Apps", systemImage: "globe").tag(TriggersState.Scope.all)
                if !store.groups.isEmpty {
                    Section("Activation groups") {
                        ForEach(store.groups) { group in
                            Label(group.name, systemImage: group.enabled ? "square.stack.3d.up" : "square.stack.3d.up.slash")
                                .tag(TriggersState.Scope.group(group.id))
                                .contextMenu {
                                    Button("Edit Conditions…") { state.editingGroup = group.id }
                                    Button(group.enabled ? "Switch Off" : "Switch On") {
                                        if let index = store.groups.firstIndex(where: { $0.id == group.id }) { store.groups[index].enabled.toggle() }
                                    }
                                    Button("Delete Group") { deleteGroup(group.id) }
                                }
                        }
                    }
                }
                if !apps.isEmpty {
                    Section("Apps") {
                        ForEach(apps, id: \.self) { app in
                            Label(AppNames.name(of: app), systemImage: "app").tag(TriggersState.Scope.app(app))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Menu {
                    Button("Choose App…") {
                        if let url = ActionEditor.chooseApp(), let id = Bundle(url: url)?.bundleIdentifier { addApp(id) }
                    }
                    Menu("Running Apps") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "App") { if let id = app.bundleIdentifier { addApp(id) } }
                        }
                    }
                    Divider()
                    Button("New Activation Group…") {
                        let group = ActivationGroup(name: "Group \(store.groups.count + 1)")
                        store.groups.append(group)
                        state.scope = .group(group.id)
                        state.editingGroup = group.id
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add an app, or an activation group (conditions like “Safari, Chrome or Firefox, not in a private window”)")
                Button {
                    switch state.scope {
                    case .group(let id): deleteGroup(id)
                    case .app(let id): state.extraApps.removeAll { $0 == id }; state.scope = .all
                    case .all: break
                    }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(state.scope == .all)
                .help("Remove this app or group from the list (its triggers move to For All Apps)")
                Spacer()
                if case .group(let id) = state.scope {
                    Button("Conditions…") { state.editingGroup = id }.controlSize(.small)
                }
            }
            .padding(8)
        }
    }

    private func addApp(_ id: String) {
        if !state.extraApps.contains(id) { state.extraApps.append(id) }
        state.scope = .app(id)
        state.selected = nil
    }

    private func deleteGroup(_ id: UUID) {
        for index in store.rules.indices where store.rules[index].groupID == id { store.rules[index].groupID = nil }
        store.groups.removeAll { $0.id == id }
        if state.scope == .group(id) { state.scope = .all }
    }

    // MARK: Column 2: the triggers

    @ViewBuilder
    private var categoryBar: some View {
        HStack(spacing: 2) {
            ForEach(TriggerCategory.allCases) { category in
                Button { state.category = category } label: {
                    Image(systemName: category.symbol)
                        .frame(width: 28, height: 24)
                        .background(state.category == category ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.borderless)
                .help(category.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        Text(state.category.title).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    private var shownRules: [GestureRule] {
        store.rules.filter { rule in
            guard state.category.contains(rule.gesture) else { return false }
            switch state.scope {
            case .all: return rule.groupID == nil && rule.scope != .only
            case .app(let id): return rule.groupID == nil && rule.scope == .only && rule.apps.contains(id)
            case .group(let id): return rule.groupID == id
            }
        }
    }

    private var triggerList: some View {
        VStack(spacing: 0) {
            List(selection: $state.selected) {
                ForEach(shownRules) { rule in
                    TriggerRow(rule: rule).tag(rule.id)
                }
            }
            if shownRules.isEmpty {
                Text("No triggers here yet. Click + to add one.").font(.caption).foregroundStyle(.secondary).padding()
            }
            Divider()
            HStack {
                Spacer()
                Button { addTrigger() } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).help("Add a trigger of the kind chosen above")
                Button {
                    if let id = state.selected { store.rules.removeAll { $0.id == id }; state.selected = nil }
                } label: { Image(systemName: "trash").font(.title3) }
                .buttonStyle(.borderless).disabled(state.selected == nil).help("Delete the selected trigger")
            }
            .padding(8)
        }
    }

    private func addTrigger() {
        var rule = GestureRule(gesture: state.category.template, action: MacroAction(kind: .system))
        switch state.scope {
        case .all: break
        case .app(let id): rule.scope = .only; rule.apps = [id]
        case .group(let id): rule.groupID = id
        }
        store.rules.append(rule)
        state.selected = rule.id
    }

    // MARK: Column 3: actions

    private var selectedIndex: Int? {
        state.selected.flatMap { id in store.rules.firstIndex { $0.id == id } }
    }

    @ViewBuilder
    private var actionsColumn: some View {
        if let index = selectedIndex {
            let rule = $store.rules[index]
            VStack(alignment: .leading, spacing: 0) {
                Label("Actions run when it's triggered, in order", systemImage: "list.number")
                    .font(.headline).padding(12)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(rule.wrappedValue.actions.indices), id: \.self) { position in
                            HStack(alignment: .top) {
                                Text("\(position + 1)").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 16)
                                ActionEditor(action: actionBinding(rule, position))
                                Button { removeAction(rule, position) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).disabled(rule.wrappedValue.actions.count < 2)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Button { rule.wrappedValue.moreActions = (rule.wrappedValue.moreActions ?? []) + [MacroAction(kind: .system)] } label: {
                            Label("Add Action", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        PhaseActionsEditor(rule: rule)
                    }
                    .padding(.horizontal, 12)
                }
                Divider()
                HStack {
                    Button { module.run(rule.wrappedValue, for: rule.wrappedValue.gesture) } label: {
                        Label("Try It", systemImage: "play.circle.fill")
                    }
                    .help("Run its actions now")
                    Spacer()
                }
                .padding(8)
            }
        } else {
            placeholder("Choose a trigger to see its actions.")
        }
    }

    private func actionBinding(_ rule: Binding<GestureRule>, _ position: Int) -> Binding<MacroAction> {
        Binding(
            get: { rule.wrappedValue.actions.indices.contains(position) ? rule.wrappedValue.actions[position] : MacroAction(kind: .system) },
            set: { value in
                if position == 0 { rule.wrappedValue.action = value }
                else if rule.wrappedValue.moreActions?.indices.contains(position - 1) == true { rule.wrappedValue.moreActions?[position - 1] = value }
            })
    }

    private func removeAction(_ rule: Binding<GestureRule>, _ position: Int) {
        var more = rule.wrappedValue.moreActions ?? []
        guard !more.isEmpty else { return }
        if position == 0 {
            rule.wrappedValue.action = more.removeFirst()
        } else if more.indices.contains(position - 1) {
            more.remove(at: position - 1)
        }
        rule.wrappedValue.moreActions = more.isEmpty ? nil : more
    }

    // MARK: Column 4: settings

    @ViewBuilder
    private var settingsColumn: some View {
        if let index = selectedIndex {
            TriggerSettings(rule: $store.rules[index], groups: store.groups,
                            inUse: Set(store.rules.filter { $0.id != store.rules[index].id }.map(\.gesture)),
                            editConditions: { state.editingCondition = true })
        } else {
            placeholder("Choose a trigger to change its settings.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
    }
}

/// One trigger in the list: what sets it off, what it does, its notes and conditions.
struct TriggerRow: View {
    let rule: GestureRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.gesture.title).font(.body.weight(.medium))
            Text(rule.listDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if rule.hasNotes, rule.showNotes != true {
                Text("Notes: " + (rule.notes ?? "")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let condition = rule.condition, !condition.isEmpty {
                Text("Condition: " + condition.text).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 3)
        .opacity(rule.enabled ? 1 : 0.45)
    }
}

/// The settings column for one trigger.
struct TriggerSettings: View {
    @Binding var rule: GestureRule
    let groups: [ActivationGroup]
    let inUse: Set<Gesture>
    let editConditions: () -> Void
    @State private var advanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(rule.gesture.title).font(.headline)
                if case .shortcut = rule.gesture {
                    TriggerKeysRecorder(rule: $rule)
                } else {
                    GestureEditor(gesture: $rule.gesture, deleteTyped: $rule.deleteTyped, inUse: inUse)
                }
                if case let .touch(source, _, _) = rule.gesture, source == .trackpad {
                    LiveTrackpadView()
                }
                Toggle("Trigger is enabled", isOn: $rule.enabled)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes").font(.subheadline.bold())
                    TextField("What it's for", text: Binding(get: { rule.notes ?? "" }, set: { rule.notes = $0.isEmpty ? nil : $0 }))
                    Toggle("Show notes instead of the description", isOn: flag(\.showNotes))
                }
                Picker("", selection: $advanced) {
                    Text("Basic").tag(false)
                    Text("Advanced").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if advanced {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conditions").font(.subheadline.bold())
                        Text(rule.condition.map { $0.isEmpty ? "None: it works everywhere it applies." : $0.text } ?? "None: it works everywhere it applies.")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Advanced Conditions…", action: editConditions)
                        Divider()
                        Picker("Activation group", selection: $rule.groupID) {
                            Text("None").tag(UUID?.none)
                            ForEach(groups) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        AppScopeEditor(scope: $rule.scope, apps: $rule.apps)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show an on-screen message when it runs", isOn: flag(\.showHUD))
                        Toggle("Run alongside other matching triggers", isOn: flag(\.parallel))
                            .help("Normally only the best match runs (one with conditions beats one for an app, which beats one for every app).")
                        if rule.isKeyboard {
                            Toggle("Prevent recursive triggers", isOn: Binding(get: { rule.preventRecursion != false },
                                                                               set: { rule.preventRecursion = $0 ? nil : false }))
                                .help("Ignore this trigger for a moment after it runs, so an action pressing its own keys can't set it off again and again.")
                        }
                        if case .shortcut = rule.gesture {
                            Toggle("Tell left and right modifier keys apart", isOn: flag(\.distinguishSides))
                                .help("Right ⌘ + Space and left ⌘ + Space become different shortcuts. Record the shortcut with the side you want.")
                            Toggle("Follow the keyboard layout", isOn: flag(\.followLayout))
                                .help("Match the letter typed rather than the key's place, so the shortcut stays on the same letter in another layout.")
                        }
                        if repeatable {
                            Divider()
                            Toggle(isKeyboardShortcut ? "Repeat while the keys are held" : "Repeat while the fingers stay down", isOn: flag(\.repeatWhileHeld))
                            if rule.repeatWhileHeld == true {
                                LabeledContent("Repeats a second") {
                                    HStack {
                                        Slider(value: Binding(get: { rule.repeatRate ?? 10 }, set: { rule.repeatRate = $0 }), in: 1...30, step: 1)
                                        Text("\(Int(rule.repeatRate ?? 10))").monospacedDigit().frame(width: 26)
                                    }
                                }
                                LabeledContent("First repeat after") {
                                    HStack {
                                        Slider(value: Binding(get: { rule.repeatDelay ?? 0.4 }, set: { rule.repeatDelay = $0 }), in: 0.1...1.5, step: 0.05)
                                        Text(String(format: "%.2f s", rule.repeatDelay ?? 0.4)).monospacedDigit().frame(width: 52)
                                    }
                                }
                            }
                        }
                        if rule.needsKeyWatching {
                            Text("Toolbelt watches the keyboard for this shortcut (Input Monitoring and Accessibility).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var isKeyboardShortcut: Bool {
        if case .shortcut = rule.gesture { return true }
        return false
    }

    /// Keyboard shortcuts, and trackpad or Magic Mouse gestures that aren't already repeating scrolls.
    private var repeatable: Bool {
        switch rule.gesture {
        case .shortcut: return true
        case let .touch(_, kind, _): return !kind.isScroll
        default: return false
        }
    }

    private func flag(_ path: WritableKeyPath<GestureRule, Bool?>) -> Binding<Bool> {
        Binding(get: { rule[keyPath: path] == true }, set: { rule[keyPath: path] = $0 ? true : nil })
    }
}

// MARK: - Conditions editor

/// Edits conditions in a sheet: "All / Any / None of the following are true", rules and groups inside
/// groups, the written-out form, and whether it's true right now (checked every second).
struct ConditionEditorSheet: View {
    let title: String
    @State var name: String?
    @State var condition: ConditionGroup
    let save: (String, ConditionGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isTrueNow = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(title: String, name: String?, condition: ConditionGroup, save: @escaping (String, ConditionGroup) -> Void) {
        self.title = title
        _name = State(initialValue: name)
        _condition = State(initialValue: condition)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                if name != nil {
                    TextField("Name", text: Binding(get: { name ?? "" }, set: { name = $0 })).frame(maxWidth: 260)
                }
            }
            ScrollView {
                ConditionGroupEditor(group: $condition, onRemove: nil).padding(.vertical, 4)
            }
            .frame(minHeight: 220)
            VStack(alignment: .leading, spacing: 4) {
                Text("Written out").font(.caption.bold()).foregroundStyle(.secondary)
                Text(condition.text.isEmpty ? "(no conditions: always true)" : condition.text)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Text(isTrueNow ? "Currently true" : "Currently false")
                    .font(.callout.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(isTrueNow ? Color.green : Color.red, in: Capsule())
                Text("Window titles need Accessibility.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(name ?? "", condition); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 820, height: 560)
        .onAppear(perform: check)
        .onReceive(clock) { _ in check() }
    }

    private func check() {
        isTrueNow = condition.isTrue(in: ConditionContext.current())
    }
}

struct ConditionGroupEditor: View {
    @Binding var group: ConditionGroup
    let onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $group.mode) {
                    ForEach(ConditionGroup.Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following are true").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Add Condition") { group.items.append(.rule(ConditionRule())) }
                    Button("Add Group") { group.items.append(.group(ConditionGroup(mode: .any, items: [.rule(ConditionRule())]))) }
                } label: { Image(systemName: "plus.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            ForEach($group.items) { $item in
                if item.group != nil {
                    // A group inside the group (AnyView: a view can't contain its own type directly).
                    AnyView(ConditionGroupEditor(group: Binding(get: { item.group ?? ConditionGroup() }, set: { item.group = $0 }),
                                                 onRemove: { group.items.removeAll { $0.id == item.id } }))
                        .padding(.leading, 18)
                } else {
                    ConditionRuleRow(rule: Binding(get: { item.rule ?? ConditionRule() }, set: { item.rule = $0 }),
                                     onRemove: { group.items.removeAll { $0.id == item.id } })
                        .padding(.leading, 18)
                }
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 3)
        }
    }
}

struct ConditionRuleRow: View {
    @Binding var rule: ConditionRule
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { rule.field }, set: { field in
                rule.field = field
                if !field.operators.contains(rule.op) { rule.op = field.operators[0] }
            })) {
                ForEach(ConditionField.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 230)
            Picker("", selection: $rule.op) {
                ForEach(rule.field.operators) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            TextField(rule.field.isNumber ? "Number" : "Text", text: $rule.value)
            Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
    }
}

/// Actions for the other moments: when the keys or fingers are let go, a long hold, and so on.
struct PhaseActionsEditor: View {
    @Binding var rule: GestureRule

    private var keyboard: Bool {
        if case .shortcut = rule.gesture { return true }
        return false
    }

    private var supported: Bool {
        switch rule.gesture {
        case .shortcut: return true
        case let .touch(_, kind, _): return !kind.isScroll
        default: return false
        }
    }

    var body: some View {
        if supported {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(TriggerPhase.available(keyboard: keyboard)) { phase in
                    let list = rule.actions(for: phase)
                    if !list.isEmpty {
                        Divider()
                        Text(phase.title(keyboard: keyboard)).font(.subheadline.bold())
                        ForEach(Array(list.indices), id: \.self) { position in
                            HStack(alignment: .top) {
                                ActionEditor(action: Binding(
                                    get: { rule.actions(for: phase).indices.contains(position) ? rule.actions(for: phase)[position] : MacroAction(kind: .system) },
                                    set: { value in
                                        var changed = rule.actions(for: phase)
                                        guard changed.indices.contains(position) else { return }
                                        changed[position] = value
                                        set(phase, changed)
                                    }))
                                Button {
                                    var changed = rule.actions(for: phase)
                                    if changed.indices.contains(position) { changed.remove(at: position) }
                                    set(phase, changed)
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                Menu {
                    ForEach(TriggerPhase.available(keyboard: keyboard)) { phase in
                        Button(phase.title(keyboard: keyboard)) { set(phase, rule.actions(for: phase) + [MacroAction(kind: .system)]) }
                    }
                } label: {
                    Label("Add Action For Another Moment", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(keyboard ? "Actions on key release, a long hold, a quick release, release after a long hold, or once all modifier keys are let go."
                               : "Actions for when the fingers lift.")
            }
        }
    }

    private func set(_ phase: TriggerPhase, _ actions: [MacroAction]) {
        var all = rule.phaseActions ?? [:]
        all[phase] = actions.isEmpty ? nil : actions
        rule.phaseActions = all.isEmpty ? nil : all
    }
}

/// Records a keyboard shortcut, including which side's modifier keys were used and the letter it types.
struct TriggerKeysRecorder: View {
    @Binding var rule: GestureRule
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Shortcut")
            Button(recording ? "Press the keys…" : label) { recording ? stop() : start() }
                .onDisappear(perform: stop)
            if rule.distinguishSides == true, let sides = rule.sideFlags, sides & ShortcutMatch.sideMask != 0 {
                Text(Self.sideNames(sides)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        if case let .shortcut(key, modifiers) = rule.gesture, key != 0 || modifiers != 0 {
            return Shortcut(keyCode: key, modifiers: modifiers).display
        }
        return "Click to record"
    }

    static func sideNames(_ sides: Int) -> String {
        let names: [(Int, String)] = [(ShortcutMatch.leftCommand, "left ⌘"), (ShortcutMatch.rightCommand, "right ⌘"),
                                      (ShortcutMatch.leftOption, "left ⌥"), (ShortcutMatch.rightOption, "right ⌥"),
                                      (ShortcutMatch.leftControl, "left ⌃"), (ShortcutMatch.rightControl, "right ⌃"),
                                      (ShortcutMatch.leftShift, "left ⇧"), (ShortcutMatch.rightShift, "right ⇧")]
        return names.filter { sides & $0.0 != 0 }.map(\.1).joined(separator: ", ")
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let shortcut = Shortcut(event: event)
            rule.gesture = .shortcut(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers))
            rule.sideFlags = Int(event.modifierFlags.rawValue) & ShortcutMatch.sideMask
            rule.keyCharacter = event.charactersIgnoringModifiers
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The fingers on the trackpad right now, drawn as dots: handy for checking a gesture.
struct LiveTrackpadView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                Canvas { context, size in
                    let pad = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                    context.stroke(Path(roundedRect: pad, cornerRadius: 10), with: .color(.secondary), lineWidth: 1)
                    for finger in MultitouchReader.shared.liveTouches() {
                        let point = CGPoint(x: pad.minX + finger.x * pad.width, y: pad.maxY - finger.y * pad.height)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)), with: .color(.accentColor))
                    }
                }
            }
            .frame(width: 200, height: 130)
            Text("Live View: your fingers on the trackpad").font(.caption2).foregroundStyle(.secondary)
        }
        // The reader runs while this is on screen, even if no trackpad gesture is switched on yet.
        .onAppear { MultitouchReader.shared.start() }
        .onDisappear { TriggersWindowController.stopLiveView?() }
    }
}
