import AppKit
import SwiftUI

/// The Macros window: macros by group on the left (with search), the chosen macro on the right.
struct MacrosView: View {
    @ObservedObject var store: MacroStore
    let module: AutomationModule
    @State private var selection: UUID?
    @State private var search = ""

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
            if let index = store.macros.firstIndex(where: { $0.id == selection }) {
                let id = store.macros[index].id
                MacroDetail(macro: $store.macros[index], groups: store.groups,
                            run: { if let macro = store.macros.first(where: { $0.id == id }) { module.run(macro) } },
                            remove: {
                                // Leave the editor first, then delete, so nothing still shows the deleted macro.
                                selection = nil
                                DispatchQueue.main.async { MainActor.assumeIsolated { store.macros.removeAll { $0.id == id } } }
                            })
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "gearshape.2").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(store.macros.isEmpty ? "No macros yet" : "Choose a macro").foregroundStyle(.secondary)
                    Button("New Macro", action: newMacro)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
                        Button(kind.title) { macro.triggers.append(MacroTrigger(kind: kind, gesture: kind == .gesture ? .touch(.trackpad, .tap, fingers: 3) : nil)) }
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
        case .networkChanged, .displayConnected, .displayDisconnected, .spaceChanged:
            EmptyView()
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
                           move: { offset in move(step.id, by: offset) })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(step.kind.title).font(.subheadline.weight(.semibold))
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            fields
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
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
            Text("Variables reach shell scripts as $TB_Name.").font(.caption).foregroundStyle(.secondary)
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
        }
    }
}
