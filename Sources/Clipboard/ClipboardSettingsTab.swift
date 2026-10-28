import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsTab: View {
    @ObservedObject var shortcuts: ShortcutCenter
    var onClear: () -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @State private var ignored: [String] = Prefs.ignoredBundleIDs
    @State private var accessibilityOK = Permission.accessibility.isGranted

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("History") {
                Toggle("Pause recording", isOn: settings.binding("paused", default: false))
                Picker("Keep up to", selection: settings.binding("historyLimit", default: 1000)) {
                    Text("200 items").tag(200)
                    Text("1,000 items").tag(1000)
                    Text("5,000 items").tag(5000)
                    Text("Unlimited").tag(0)
                }
                LabeledContent("Open history") {
                    Text(shortcuts.shortcut(for: .clipboardHistory)?.display ?? "No shortcut")
                        .font(.system(.body, design: .rounded))
                }
            }

            Section {
                Toggle("Paste automatically after choosing an item", isOn: settings.binding("pasteAfterSelect", default: true))
                LabeledContent("Accessibility") {
                    Text(accessibilityOK ? "Allowed" : "Not allowed yet")
                        .foregroundStyle(accessibilityOK ? Color.green : Color.orange)
                }
            } header: {
                Text("Pasting")
            } footer: {
                Text("Automatic pasting needs the Accessibility permission. Toolbelt asks for it the first time you paste. Without it, choosing an item copies it and you press ⌘V yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ignored, id: \.self) { bundleID in
                    HStack {
                        if let icon = AppIcons.icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(AppIcons.name(for: bundleID))
                        Spacer()
                        Button {
                            ignored.removeAll { $0 == bundleID }
                            Prefs.ignoredBundleIDs = ignored
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { addApp() }
            } header: {
                Text("Never record copies from")
            } footer: {
                Text("Password managers that mark copied passwords as private are skipped automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear History…", role: .destructive) { onClear() }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            accessibilityOK = Permission.accessibility.isGranted
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ignored.contains(id) {
                ignored.append(id)
            }
        }
        Prefs.ignoredBundleIDs = ignored
    }
}
