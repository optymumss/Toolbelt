import AppKit
import Combine
import SwiftUI

/// Saved text that expands when you type its keyword, like ";addr" → your address.
@MainActor
final class SnippetsModule: ToolbeltModule {
    let id = ModuleID.snippets
    let openTitle = "Snippets…"

    let store = SnippetStore()
    private(set) lazy var expander = SnippetExpander(store: store)
    let form = SnippetFormController()
    private(set) lazy var pickerProvider = SnippetsLauncherProvider(store: store, listAll: true) { [weak self] snippet in
        self?.insertSoon(snippet)
    }
    private(set) lazy var picker: LauncherPanelController = {
        let model = LauncherModel { [weak self] in self.map { [$0.pickerProvider] } ?? [] }
        model.prompt = "Find a snippet…"
        return LauncherPanelController(model: model)
    }()
    private let openSettings: () -> Void
    private let shortcuts: ShortcutCenter
    private var running = false
    private var watcher: AnyCancellable?
    private var askedThisLaunch = false

    init(shortcuts: ShortcutCenter, openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        self.shortcuts = shortcuts
        shortcuts.setHandler(for: .snippetPicker) { [weak self] in self?.openPicker() }
        // Start listening as soon as there's a snippet to expand.
        watcher = store.$snippets.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateListening() } }
        }
    }

    func start() {
        running = true
        updateListening()
    }

    func stop() {
        running = false
        expander.stop()
        picker.hide()
    }

    /// The searchable snippet picker (⌃⌥;).
    func openPicker() {
        if picker.isVisible { picker.hide() } else { picker.show(switcher: pickerProvider) }
    }

    /// Types a snippet into the app in front, after deleting `count` typed characters.
    /// Fill-in snippets ask for their blanks first.
    func insert(_ snippet: Snippet, deleting count: Int) {
        guard PermissionGate.ensure(.accessibility, to: "type your snippets") else { return }
        let fields = Placeholders.fields(in: snippet.text)
        guard !fields.isEmpty else {
            TextInserter.replace(typed: count, with: Placeholders.render(snippet.text))
            return
        }
        for _ in 0..<count { TextInserter.press(CGKeyCode(51)) } // ⌫ the keyword
        let previous = NSWorkspace.shared.frontmostApplication
        form.ask(title: snippet.name.isEmpty ? snippet.keyword : snippet.name, fields: fields) { values in
            guard let values else { return }
            previous?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    TextInserter.paste(Placeholders.render(snippet.text, inputs: values))
                }
            }
        }
    }

    /// From the launcher or picker: wait for the panel to close, then insert.
    func insertSoon(_ snippet: Snippet) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated { [weak self] in self?.insert(snippet, deleting: 0) }
        }
    }

    /// Listens only when it's needed: the module is on, typing expansion is on,
    /// and there's at least one snippet. That's also when the permission is asked for.
    func updateListening() {
        let wanted = running && Prefs.snippetsExpandWhileTyping && store.snippets.contains { !$0.keyword.isEmpty }
        guard wanted else {
            expander.stop()
            return
        }
        guard !expander.isRunning else { return }
        expander.onMatch = { [weak self] snippet, count in self?.insert(snippet, deleting: count) }
        if !expander.start(), !askedThisLaunch {
            askedThisLaunch = true
            _ = PermissionGate.ensure(.inputMonitoring, to: "expand snippets as you type")
        }
    }

    func open() {
        openSettings()
    }

    func menuItems() -> [NSMenuItem] { [] }

    func settingsView() -> AnyView {
        AnyView(SnippetsSettingsTab(store: store) { [weak self] in self?.updateListening() })
    }

    func willTerminate() {}

    private(set) lazy var launcherProvider: LauncherProvider? = SnippetsLauncherProvider(store: store) { [weak self] snippet in
        self?.insertSoon(snippet)
    }
}

/// Snippets can be searched in the launcher; ↩ types the snippet into the app you were using.
@MainActor
final class SnippetsLauncherProvider: LauncherProvider {
    private let store: SnippetStore
    /// The picker lists every snippet before you type; the launcher waits for two letters.
    private let listAll: Bool
    private let insert: (Snippet) -> Void

    init(store: SnippetStore, listAll: Bool = false, insert: @escaping (Snippet) -> Void = { _ in }) {
        self.store = store
        self.listAll = listAll
        self.insert = insert
    }

    func results(for query: String) -> [LauncherResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 || (listAll && q.isEmpty) else { return [] }
        return store.snippets.enumerated().compactMap { order, snippet in
            let score = q.isEmpty ? 100 - Double(order) * 0.01 : max(
                FuzzyMatch.score(q, snippet.name),
                FuzzyMatch.score(q, snippet.keyword),
                FuzzyMatch.score(q, snippet.folderName) * 0.8,
                snippet.text.localizedCaseInsensitiveContains(q) ? 45 : 0
            )
            guard score > 0 else { return nil }
            let preview = Placeholders.render(snippet.text).text.replacingOccurrences(of: "\n", with: " ")
            let folder = snippet.folder?.nilIfEmpty.map { "\($0) · " } ?? ""
            return LauncherResult(
                id: "snippet:" + snippet.id.uuidString,
                title: snippet.name.isEmpty ? snippet.keyword : snippet.name,
                subtitle: "\(folder)\(snippet.keyword) · \(preview)",
                kind: "Snippet", icon: .symbol("text.badge.plus"), score: score
            ) { [insert] in
                insert(snippet)
            }
        }
    }
}

struct SnippetsSettingsTab: View {
    @ObservedObject var store: SnippetStore
    var onChange: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @State private var inputMonitoringOK = Permission.inputMonitoring.isGranted
    @State private var accessibilityOK = Permission.accessibility.isGranted
    /// Re-checks permissions when a window comes to the front (for example after you return from
    /// System Settings), instead of a timer that would keep waking the Mac while Settings is closed.
    private let refresh = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)

    var body: some View {
        Group {
            Section {
                Toggle("Expand snippets as I type", isOn: Binding(
                    get: { MainActor.assumeIsolated { Prefs.snippetsExpandWhileTyping } },
                    set: { on in
                        MainActor.assumeIsolated {
                            Prefs.snippetsExpandWhileTyping = on
                            onChange()
                        }
                    }
                ))
                permissionRow(.inputMonitoring, granted: inputMonitoringOK, purpose: "to notice keywords as you type")
                permissionRow(.accessibility, granted: accessibilityOK, purpose: "to type the snippet for you")
            } header: {
                Text("Typing")
            } footer: {
                Text("Snippets never expand in password fields — macOS hides those keystrokes from every app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.snippets.isEmpty {
                    Text("No snippets yet. Add one, give it a keyword like ;addr, and type the keyword anywhere.")
                        .foregroundStyle(.secondary)
                }
                ForEach($store.snippets) { $snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Keyword", text: $snippet.keyword, prompt: Text(";keyword"))
                                .frame(width: 110)
                                .font(.system(.body, design: .monospaced))
                            TextField("Name", text: $snippet.name, prompt: Text("Name"))
                            TextField("Folder", text: Binding(
                                get: { snippet.folder ?? "" },
                                set: { snippet.folder = $0.isEmpty ? nil : $0 }
                            ), prompt: Text("Folder"))
                            .frame(width: 100)
                            Button {
                                store.snippets.removeAll { $0.id == snippet.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this snippet")
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        TextEditor(text: $snippet.text)
                            .font(.system(size: 12))
                            .frame(minHeight: 54, maxHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        if let clash = clash(for: snippet) {
                            Text(clash).font(.caption).foregroundStyle(Color.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Add Snippet") {
                    store.snippets.append(Snippet(keyword: ";", name: "", text: ""))
                }
            } header: {
                Text("Snippets")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Placeholders you can put in a snippet:")
                    ForEach(Placeholders.help, id: \.0) { placeholder, meaning in
                        Text("\(placeholder) — \(meaning)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onReceive(refresh) { _ in
            inputMonitoringOK = Permission.inputMonitoring.isGranted
            accessibilityOK = Permission.accessibility.isGranted
        }
    }

    private func permissionRow(_ permission: Permission, granted: Bool, purpose: String) -> some View {
        LabeledContent {
            HStack {
                Text(granted ? "Allowed" : "Not allowed yet")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                if !granted {
                    Button("Allow…") { permission.openSettings() }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title)
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Warns when one keyword is the end of another, so typing it would never reach the longer one.
    private func clash(for snippet: Snippet) -> String? {
        guard !snippet.keyword.isEmpty else { return "Give it a keyword so it can expand." }
        if store.snippets.contains(where: { $0.id != snippet.id && $0.keyword == snippet.keyword }) {
            return "Another snippet already uses \(snippet.keyword)."
        }
        if let other = store.snippets.first(where: { $0.id != snippet.id && !$0.keyword.isEmpty && snippet.keyword.count > $0.keyword.count && snippet.keyword.hasPrefix($0.keyword) }) {
            return "\(other.keyword) expands before you finish typing \(snippet.keyword)."
        }
        return nil
    }
}
