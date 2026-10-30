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
    private let openSettings: () -> Void
    private var running = false
    private var watcher: AnyCancellable?
    private var askedThisLaunch = false

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
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

    private(set) lazy var launcherProvider: LauncherProvider? = SnippetsLauncherProvider(store: store)
}

/// Snippets can be searched in the launcher; ↩ types the snippet into the app you were using.
@MainActor
final class SnippetsLauncherProvider: LauncherProvider {
    private let store: SnippetStore

    init(store: SnippetStore) {
        self.store = store
    }

    func results(for query: String) -> [LauncherResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return store.snippets.compactMap { snippet in
            let score = max(
                FuzzyMatch.score(q, snippet.name),
                FuzzyMatch.score(q, snippet.keyword),
                snippet.text.localizedCaseInsensitiveContains(q) ? 45 : 0
            )
            guard score > 0 else { return nil }
            let preview = Placeholders.render(snippet.text).text.replacingOccurrences(of: "\n", with: " ")
            return LauncherResult(
                id: "snippet:" + snippet.id.uuidString,
                title: snippet.name.isEmpty ? snippet.keyword : snippet.name,
                subtitle: "\(snippet.keyword) · \(preview)",
                kind: "Snippet", icon: .symbol("text.badge.plus"), score: score
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        guard PermissionGate.ensure(.accessibility, to: "type your snippets") else { return }
                        TextInserter.paste(Placeholders.render(snippet.text))
                    }
                }
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
