import AppKit
import SwiftUI

/// The Macros window: macros by group on the left (with search), the chosen macro on the right.
struct MacrosView: View {
    @ObservedObject var store: MacroStore
    let module: AutomationModule
    @State private var selection: UUID?
    @State private var search = ""
    @State private var history = UndoHistory<[Macro]>()
    @State private var applyingHistory = false
    @State private var showUsed = false
    @State private var recording = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.macros) { macro in
                            HStack {
                                Image(systemName: macro.enabled ? "gearshape.2" : "pause.circle").foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(macro.name.isEmpty ? "Untitled" : macro.name)
                                    Text(macro.triggers.first?.summary ?? "No trigger").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(macro.id)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search macros")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button { newMacro() } label: { Label("New Macro", systemImage: "plus") }
                        .help("New macro")
                }
            }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!history.canUndo).keyboardShortcut("z", modifiers: .command).help("Undo the last change (⌘Z)")
                Button { redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!history.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo (⇧⌘Z)")
                Button { record() } label: { Label(recording ? "Stop Recording" : "Record", systemImage: recording ? "stop.circle" : "record.circle") }
                    .help(recording ? "Stop recording (or press \(MacroRecorder.stopKeys))"
                                    : "Do a task yourself and Toolbelt writes the steps into this macro. Press \(MacroRecorder.stopKeys) to stop.")
                Button { showUsed = true } label: { Label("Used Shortcuts", systemImage: "command") }
                    .help("Every shortcut Toolbelt uses, and the ones that clash")
                Menu {
                    Button("Export This Macro…") { export(all: false) }.disabled(selection == nil)
                    Button("Export All Macros…") { export(all: true) }
                    Divider()
                    Button("Import Macros…", action: importMacros)
                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .help("Save macros to a file, or bring them in from one")
            }
        }
        .onChange(of: store.macros) { old, _ in
            if applyingHistory { applyingHistory = false } else { history.record(old) }
        }
        .sheet(isPresented: $showUsed) { UsedShortcutsView(entries: module.usedShortcuts()) { showUsed = false } }
    }

    @ViewBuilder
    private var detail: some View {
            if let index = store.macros.firstIndex(where: { $0.id == selection }) {
                let id = store.macros[index].id
                MacroDetail(macro: $store.macros[index], groups: store.groups,
                            run: { if let macro = store.macros.first(where: { $0.id == id }) { module.run(macro) } },
                            remove: {
                                // Leave the editor first, then delete, so nothing still shows the deleted macro.
                                selection = nil
                                DispatchQueue.main.async { MainActor.assumeIsolated { store.macros.removeAll { $0.id == id } } }
                            })
                    .environment(\.tryStep, { step in module.tryStep(step) })
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "gearshape.2").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(store.macros.isEmpty ? "No macros yet" : "Choose a macro").foregroundStyle(.secondary)
                    Button("New Macro", action: newMacro)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private func undo() {
        guard let previous = history.undo(from: store.macros) else { return }
        applyingHistory = true
        store.macros = previous
    }

    private func redo() {
        guard let next = history.redo(from: store.macros) else { return }
        applyingHistory = true
        store.macros = next
    }

    /// Records into the chosen macro (or a new one), adding the steps at the end.
    private func record() {
        if recording {
            module.recorder.stop()
            return
        }
        if selection == nil { newMacro() }
        guard let id = selection else { return }
        recording = module.recorder.start { steps in
            recording = false
            guard let index = store.macros.firstIndex(where: { $0.id == id }) else { return }
            // A new macro's empty first step goes; recorded steps replace it.
            if store.macros[index].steps.count == 1, store.macros[index].steps[0] == MacroStep(id: store.macros[index].steps[0].id, kind: .action) {
                store.macros[index].steps = []
            }
            store.macros[index].steps += steps
        }
    }

    private func export(all: Bool) {
        let macros = all ? store.macros : store.macros.filter { $0.id == selection }
        guard let data = MacroTransfer.export(macros, groups: store.groups) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (all ? "Toolbelt macros" : macros.first?.name ?? "Macro") + "." + MacroTransfer.fileExtension
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url, options: .atomic) }
    }

    private func importMacros() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        var added = 0
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url), let found = MacroTransfer.importing(data, existingGroups: store.groups) else { continue }
            store.groups += found.newGroups
            store.macros += found.macros
            added += found.macros.count
        }
        HUD.show(added == 0 ? "No macros found in that file" : "Imported \(added) macro\(added == 1 ? "" : "s")", symbol: "square.and.arrow.down")
    }

    struct MacroSection: Identifiable {
        var id: String { title }
        let title: String
        let macros: [Macro]
    }

    private var sections: [MacroSection] {
        let found = store.search(search)
        var result: [MacroSection] = []
        let loose = found.filter { store.group(of: $0) == nil }
        if !loose.isEmpty { result.append(MacroSection(title: "Macros", macros: loose)) }
        for group in store.groups {
            let inGroup = found.filter { $0.groupID == group.id }
            if !inGroup.isEmpty { result.append(MacroSection(title: group.name + (group.enabled ? "" : " (off)"), macros: inGroup)) }
        }
        return result
    }

    private func newMacro() {
        var macro = Macro(name: "New Macro \(store.macros.count + 1)")
        macro.triggers = [MacroTrigger(kind: .hotKey)]
        macro.steps = [MacroStep(kind: .action)]
        store.macros.append(macro)
        selection = macro.id
        search = ""
    }
}


/// "Try" for a single step, handed down from the Macros window.
private struct TryStepKey: EnvironmentKey {
    static let defaultValue: ((MacroStep) -> Void)? = nil
}

extension EnvironmentValues {
    var tryStep: ((MacroStep) -> Void)? {
        get { self[TryStepKey.self] }
        set { self[TryStepKey.self] = newValue }
    }
}

struct UsedShortcutsView: View {
    let entries: [UsedShortcuts.Entry]
    let close: () -> Void

    var body: some View {
        let clashes = UsedShortcuts.clashes(entries)
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts in use").font(.headline)
            Text(clashes.isEmpty ? "No two things use the same keys." : "Orange: more than one thing uses these keys; only one of them will work.")
                .font(.caption).foregroundStyle(clashes.isEmpty ? Color.secondary : Color.orange)
            Table(entries) {
                TableColumn("Keys") { entry in
                    Text(entry.keys).foregroundStyle(clashes.contains(entry.keys) ? Color.orange : Color.primary)
                }
                .width(min: 90, ideal: 110)
                TableColumn("What it does", value: \.owner)
                TableColumn("Where", value: \.place).width(min: 90, ideal: 120)
            }
            .frame(minHeight: 280)
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 560, height: 420)
    }
}

struct MacroDetail: View {
    @Binding var macro: Macro
    let groups: [MacroGroup]
    let run: () -> Void
    let remove: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $macro.name)
                Toggle("On", isOn: $macro.enabled)
                Picker("Group", selection: $macro.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(groups) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                HStack {
                    Button("Run Now", action: run)
                    Spacer()
                    Button("Delete Macro", role: .destructive, action: remove)
                }
            }
            Section("Starts when") {
                ForEach($macro.triggers) { $trigger in
                    TriggerEditor(trigger: $trigger) { macro.triggers.removeAll { $0.id == trigger.id } }
                }
                Menu("Add Trigger") {
                    ForEach(MacroTrigger.Kind.allCases) { kind in
                        Button(kind.title) {
                            var trigger = MacroTrigger(kind: kind, gesture: kind == .gesture ? .touch(.trackpad, .tap, fingers: 3) : nil)
                            if kind == .batteryBelow { trigger.number = 20 }
                            if kind == .idle || kind == .activeAgain { trigger.number = 5 }
                            macro.triggers.append(trigger)
                        }
                    }
                }
                .fixedSize()
            }
            Section("Steps") {
                StepListEditor(steps: $macro.steps)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Triggers

struct TriggerEditor: View {
    @Binding var trigger: MacroTrigger
    let remove: () -> Void
    @State private var recorder: DeviceKeyWatcher?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trigger.kind.title).font(.headline)
                Spacer()
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            fields
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch trigger.kind {
        case .hotKey:
            KeyCapture(keyCode: $trigger.keyCode, modifiers: $trigger.modifiers)
        case .typedText:
            TextField("Text to type, e.g. ;;mail", text: $trigger.text)
            Text("Uses the Gestures module, which needs to be on.").font(.caption).foregroundStyle(.secondary)
        case .gesture:
            GestureEditor(gesture: Binding(get: { trigger.gesture ?? .touch(.trackpad, .tap, fingers: 3) }, set: { trigger.gesture = $0 }),
                          deleteTyped: .constant(true))
            Text("Uses the Gestures module, which needs to be on.").font(.caption).foregroundStyle(.secondary)
        case .deviceKey:
            HStack {
                Text(trigger.text.isEmpty ? "No key chosen" : "Key \(trigger.number) on \(trigger.text)").foregroundStyle(.secondary)
                Button(recorder == nil ? "Record Key…" : "Press a key on the other keyboard…", action: record)
            }
            Toggle("Keep that keyboard's keys from other apps (if macOS allows it)", isOn: $trigger.exclusive)
        case .appLaunched, .appQuit, .appActivated:
            HStack {
                Text(trigger.text.isEmpty ? "Any app" : AppNames.name(of: trigger.text)).foregroundStyle(.secondary)
                Button("Choose App…") {
                    if let url = ActionEditor.chooseApp(), let id = Bundle(url: url)?.bundleIdentifier { trigger.text = id }
                }
                if !trigger.text.isEmpty { Button("Any App") { trigger.text = "" } }
            }
        case .fileAdded:
            HStack {
                Text(trigger.text.isEmpty ? "No folder chosen" : (trigger.text as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    NSApp.activate()
                    if panel.runModal() == .OK, let url = panel.url { trigger.text = url.path }
                }
            }
            Text("The new file's path is in %Trigger%.").font(.caption).foregroundStyle(.secondary)
        case .wifiChanged:
            HStack {
                TextField("Network name (empty for any change)", text: $trigger.text)
                Button("Use Current") { trigger.text = NetworkWatcher.currentWiFi ?? "" }
            }
            Text("macOS shares the network's name only with apps allowed Location Services; it asks the first time.").font(.caption).foregroundStyle(.secondary)
        case .timeOfDay:
            DatePicker("Time", selection: Binding(
                get: { Calendar.current.date(bySettingHour: trigger.number / 60, minute: trigger.number % 60, second: 0, of: Date()) ?? Date() },
                set: { let p = Calendar.current.dateComponents([.hour, .minute], from: $0); trigger.number = (p.hour ?? 0) * 60 + (p.minute ?? 0) }
            ), displayedComponents: .hourAndMinute)
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    let on = trigger.weekdays.contains(day)
                    Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                        if on { trigger.weekdays.removeAll { $0 == day } } else { trigger.weekdays.append(day) }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                }
                Text(trigger.weekdays.isEmpty ? "every day" : "").font(.caption).foregroundStyle(.secondary)
            }
        case .every:
            Stepper("Every \(trigger.number) minute\(trigger.number == 1 ? "" : "s")", value: $trigger.number, in: 1...1440)
        case .terminal:
            Text("In Terminal: \(ChromeSetup.bridgeURL.path.replacingOccurrences(of: " ", with: "\\ ")) run \"Macro name\"")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        case .menuBar:
            Text("Shown in Toolbelt's menu bar menu.").font(.caption).foregroundStyle(.secondary)
        case .launcher:
            Text("Type its name in the launcher (⌥Space).").font(.caption).foregroundStyle(.secondary)
        case .networkChanged, .displayConnected, .displayDisconnected, .spaceChanged,
             .macWakes, .macSleeps, .screenLocked, .screenUnlocked, .powerConnected, .powerDisconnected:
            EmptyView()
        case .batteryBelow:
            Stepper("Below \(trigger.number)%", value: $trigger.number, in: 5...95, step: 5)
            Text("Only while running on battery; once until it's back above that level.").font(.caption).foregroundStyle(.secondary)
        case .usbConnected, .usbDisconnected, .bluetoothConnected, .bluetoothDisconnected, .diskMounted, .diskUnmounted:
            TextField("Name contains (empty for any)", text: $trigger.text)
            Text("The device's or disk's name is in %Trigger%.\(trigger.kind == .bluetoothConnected || trigger.kind == .bluetoothDisconnected ? " macOS asks once for the Bluetooth permission." : "")")
                .font(.caption).foregroundStyle(.secondary)
        case .idle, .activeAgain:
            Stepper("After \(trigger.number) minute\(trigger.number == 1 ? "" : "s") without a key press, click or mouse move",
                    value: $trigger.number, in: 1...240)
        }
    }

    /// Listens for the next key on any keyboard and remembers which device it came from.
    private func record() {
        guard recorder == nil, PermissionGate.ensure(.inputMonitoring, to: "notice keys on your other keyboards") else { return }
        let watcher = DeviceKeyWatcher()
        watcher.onKey = { device, usage in
            trigger.text = device
            trigger.number = usage
            watcher.stop()
            recorder = nil
        }
        watcher.start()
        recorder = watcher
    }
}

// MARK: - Steps

struct StepListEditor: View {
    @Binding var steps: [MacroStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($steps) { $step in
                StepEditor(step: $step,
                           remove: { steps.removeAll { $0.id == step.id } },
                           move: { offset in move(step.id, by: offset) },
                           duplicate: { insert([step.renewingIDs()], after: step.id) },
                           pasteBelow: { if let pasted = StepClipboard.paste() { insert(pasted, after: step.id) } })
            }
            Menu("Add Step") {
                ForEach(MacroStep.Kind.allCases) { kind in
                    Button(kind.title) { steps.append(Self.newStep(kind)) }
                }
            }
            .fixedSize()
        }
    }

    static func newStep(_ kind: MacroStep.Kind) -> MacroStep {
        var step = MacroStep(kind: kind)
        switch kind {
        case .script: step.action = MacroAction(kind: .shell, value: "echo \"Hello $TB_Name\""); step.name = "Output"
        case .setVariable: step.name = "Name"
        case .textFilter: step.name = "Clipboard"
        case .askInput: step.text = "What should it say?"; step.name = "Answer"
        case .pickFromList: step.text = "Pick one"; step.text2 = "First\nSecond"; step.name = "Choice"
        case .notify: step.text = "Done"
        case .repeatTimes: step.number = 3
        default: break
        }
        return step
    }

    private func insert(_ new: [MacroStep], after id: UUID) {
        let index = steps.firstIndex { $0.id == id }.map { $0 + 1 } ?? steps.count
        steps.insert(contentsOf: new, at: index)
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }
}

struct StepEditor: View {
    @Binding var step: MacroStep
    let remove: () -> Void
    let move: (Int) -> Void
    var duplicate: () -> Void = {}
    var pasteBelow: () -> Void = {}
    @Environment(\.tryStep) private var tryStep

    static func color(_ color: StepColor?) -> Color {
        switch color {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        case nil: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if step.color != nil { Circle().fill(Self.color(step.color)).frame(width: 9, height: 9) }
                Text(step.kind.title).font(.subheadline.weight(.semibold))
                if !step.isOn { Text("Off").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                if let failure = step.onFailure, failure != .carryOn {
                    Image(systemName: "exclamationmark.octagon").font(.caption).foregroundStyle(.secondary).help("If it fails: \(failure.title)")
                }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                Menu {
                    if let tryStep { Button("Try This Step") { tryStep(step) } }
                    Button(step.isOn ? "Turn Off" : "Turn On") { step.disabled = step.isOn ? true : nil }
                    Divider()
                    Button("Duplicate", action: duplicate)
                    Button("Copy") { StepClipboard.copy([step]) }
                    Button("Paste Below", action: pasteBelow)
                    Divider()
                    Button(step.note == nil ? "Add Note" : "Remove Note") { step.note = step.note == nil ? "" : nil }
                    Menu("Colour") {
                        Button("None") { step.color = nil }
                        ForEach(StepColor.allCases) { color in Button(color.title) { step.color = color } }
                    }
                    Menu("If It Fails") {
                        ForEach(FailureMode.allCases) { mode in
                            Button((step.onFailure ?? .carryOn) == mode ? "✓ " + mode.title : mode.title) { step.onFailure = mode == .carryOn ? nil : mode }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Try, turn off, duplicate, copy, note, colour, and what happens if it fails")
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            if step.note != nil {
                TextField("Note", text: Binding(get: { step.note ?? "" }, set: { step.note = $0 }), axis: .vertical)
                    .font(.caption).lineLimit(1...4)
            }
            fields
                .disabled(!step.isOn)
                .opacity(step.isOn ? 1 : 0.5)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(step.color == nil ? Color.secondary.opacity(0.08) : Self.color(step.color).opacity(0.12)))
        .overlay(alignment: .leading) {
            if step.color != nil { RoundedRectangle(cornerRadius: 2).fill(Self.color(step.color)).frame(width: 3).padding(.vertical, 4) }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch step.kind {
        case .action:
            ActionEditor(action: $step.action)
        case .script:
            Picker("Language", selection: $step.action.kind) {
                Text("Shell (zsh)").tag(MacroAction.Kind.shell)
                Text("AppleScript").tag(MacroAction.Kind.appleScript)
                Text("JavaScript").tag(MacroAction.Kind.javaScript)
            }
            TextEditor(text: $step.action.value)
                .font(.system(.caption, design: .monospaced)).frame(minHeight: 50, maxHeight: 120)
            TextField("Keep the output in variable", text: $step.name)
            HStack {
                Toggle("Give up after", isOn: Binding(get: { step.timeout != nil }, set: { step.timeout = $0 ? 10 : nil }))
                if let timeout = step.timeout {
                    Stepper(MacroRun.seconds(timeout), value: Binding(get: { timeout }, set: { step.timeout = $0 }), in: 1...3600, step: 1)
                }
            }
            Text("Variables reach shell scripts as $TB_Name. A script that ends with an error, or runs out of time, has failed: choose what happens then in ⋯ → If It Fails.")
                .font(.caption).foregroundStyle(.secondary)
        case .pause:
            Stepper("Pause for \(step.number.formatted()) s", value: $step.number, in: 0.1...3600, step: 0.5)
        case .setVariable:
            TextField("Variable", text: $step.name)
            TextField("Value (other variables: %Name%)", text: $step.text)
        case .setClipboard:
            TextField("Text (variables: %Name%)", text: $step.text)
        case .textFilter:
            TextField("Variable to change (Clipboard for the clipboard)", text: $step.name)
            Picker("Change", selection: $step.filter) {
                ForEach(TextFilter.allCases) { Text($0.title).tag($0) }
            }
            if step.filter.usesFind { TextField(step.filter == .findReplace ? "Find" : "Pattern", text: $step.text) }
            if step.filter.usesReplace { TextField("Replace with", text: $step.text2) }
            if step.filter.rawValue.hasPrefix("count") { TextField("Put the count in variable (empty: replace the text)", text: $step.text2) }
        case .askInput:
            TextField("Question", text: $step.text)
            TextField("Keep the answer in variable", text: $step.name)
        case .pickFromList:
            TextField("Question", text: $step.text)
            TextEditor(text: $step.text2).frame(minHeight: 40, maxHeight: 90)
            TextField("Keep the choice in variable", text: $step.name)
        case .notify:
            TextField("Title", text: $step.text2)
            TextField("Message (variables: %Name%)", text: $step.text)
        case .ifThen:
            ConditionEditor(condition: $step.condition)
            Text("Then").font(.caption.weight(.semibold))
            AnyView(StepListEditor(steps: $step.steps)).padding(.leading, 12)
            Text("Otherwise").font(.caption.weight(.semibold))
            AnyView(StepListEditor(steps: $step.elseSteps)).padding(.leading, 12)
        case .repeatTimes:
            Stepper("\(Int(step.number)) times (%Index% counts)", value: $step.number, in: 1...1000)
            AnyView(StepListEditor(steps: $step.steps)).padding(.leading, 12)
        case .repeatWhile:
            ConditionEditor(condition: $step.condition)
            AnyView(StepListEditor(steps: $step.steps)).padding(.leading, 12)
        case .stop:
            EmptyView()
        }
    }
}

struct ConditionEditor: View {
    @Binding var condition: MacroCondition

    var body: some View {
        HStack {
            if condition.test != .frontAppIs {
                TextField("Text or %Variable%", text: $condition.left)
            }
            Picker("", selection: $condition.test) {
                ForEach(MacroCondition.Test.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if condition.test.needsValue {
                TextField(condition.test == .frontAppIs ? "App name" : "Value", text: $condition.right)
            }
        }
    }
}

// MARK: - Settings

struct AutomationSettingsTab: View {
    @ObservedObject var store: MacroStore
    var web: AutomationModule? = nil
    let openEditor: () -> Void

    var body: some View {
        Group {
            Section {
                LabeledContent("Macros") {
                    HStack {
                        Text("\(store.macros.count)").foregroundStyle(.secondary)
                        Button("Open Macros…", action: openEditor)
                    }
                }
            } footer: {
                Text("A macro starts from a trigger (keys, typed text, a gesture, another keyboard, an app, a folder, Wi-Fi, a display, a Space, a time, the menu bar, the launcher or Terminal) and runs its steps: actions, scripts, questions, notifications, variables, if/otherwise and repeats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($store.groups) { $group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle("", isOn: $group.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            TextField("Name", text: $group.name)
                            Button { store.groups.removeAll { $0.id == group.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        AppScopeEditor(scope: $group.scope, apps: $group.apps)
                    }
                }
                Button("Add Group") { store.groups.append(MacroGroup(name: "Group \(store.groups.count + 1)")) }
            } header: {
                Text("Groups")
            } footer: {
                Text("Switch a whole group of macros on or off, or let them work only in certain apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let web { WebServerSettings(module: web) }
        }
    }
}

/// Settings → Automation → Web server.
struct WebServerSettings: View {
    let module: AutomationModule
    @ObservedObject private var settings = SettingsStore.shared
    @State private var copied = false

    private var addresses: [String] {
        let port = Prefs.webServerPort
        let local = ["http://127.0.0.1:\(port)"]
        return Prefs.webServerEveryone ? local + WebServer.localAddresses().map { "http://\($0):\(port)" } : local
    }

    var body: some View {
        Section {
            Toggle("Web server", isOn: binding(settings.binding("web.on", default: false)))
            if Prefs.webServerOn {
                TextField("Port", value: binding(settings.binding("web.port", default: 12345)), format: .number.grouping(.never))
                Toggle("Let other devices on my network use it (for your phone)", isOn: binding(settings.binding("web.everyone", default: false)))
                LabeledContent("Shared secret") {
                    HStack {
                        Text(Prefs.webServerSecret).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Prefs.webServerSecret, forType: .string)
                            copied = true
                        }
                        Button("New Secret") {
                            Prefs.webServerSecret = WebAPI.newSecret()
                            module.updateWebServer()
                        }
                    }
                }
                ForEach(addresses, id: \.self) { address in
                    LabeledContent("Address") {
                        Link(address, destination: URL(string: "\(address)/?secret=\(Prefs.webServerSecret)")!)
                    }
                }
                if let problem = module.web.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Web server")
        } footer: {
            Text("Run macros and Mac controls from a web address, like BetterTouchTool's web server: /trigger_named/?trigger_name=Macro name, /action?do=volumeUp, or /list for everything; add &shared_secret=… to each. Open the address on your phone for a page of buttons (Share → Add to Home Screen makes it an app). Off, nothing listens.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Saves the setting, then restarts the server to match.
    private func binding<T>(_ inner: Binding<T>) -> Binding<T> {
        Binding(get: { inner.wrappedValue }, set: { inner.wrappedValue = $0; module.updateWebServer() })
    }
}
