import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsTab: View {
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var named: NamedClipboardStore
    var onClear: () -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @State private var ignored: [String] = Prefs.ignoredBundleIDs
    @State private var accessibilityOK = Permission.accessibility.isGranted

    /// Re-checks permissions when a window comes to the front (for example after you return from
    /// System Settings), instead of a timer that would keep waking the Mac while Settings is closed.
    private let refresh = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)

    /// Sections only: the module tab puts them in a form below the on/off switch.
    var body: some View {
        Group {
            Section("History") {
                Toggle("Pause recording", isOn: settings.binding("paused", default: false))
                Picker("Keep up to", selection: settings.binding("historyLimit", default: 1000)) {
                    Text("200 items").tag(200)
                    Text("1,000 items").tag(1000)
                    Text("5,000 items").tag(5000)
                    Text("Unlimited").tag(0)
                }
                Picker("Delete items older than", selection: settings.binding("clipboard.autoDeleteDays", default: 0)) {
                    ForEach(ClipboardAge.choices, id: \.days) { choice in
                        Text(choice.title).tag(choice.days)
                    }
                }
                Picker("Panel layout", selection: settings.binding("clipboard.layout", default: ClipboardLayout.list.rawValue)) {
                    ForEach(ClipboardLayout.allCases) { layout in
                        Text(layout.title).tag(layout.rawValue)
                    }
                }
                Toggle("Find images by the text in them", isOn: settings.binding("clipboard.readImageText", default: true))
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
                if pinboards.pinboards.isEmpty {
                    Text("Right-click an item in the clipboard panel and choose Pinboards › New Pinboard…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($pinboards.pinboards) { $board in
                    HStack {
                        TextField("Name", text: $board.name).labelsHidden()
                        Text("\(board.itemIDs.count) items").foregroundStyle(.secondary).font(.caption)
                        Button { pinboards.pinboards.removeAll { $0.id == board.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Pinboards")
            } footer: {
                Text("Named collections, like “Email replies”. Items on a pinboard are never deleted automatically. They appear as filters at the top of the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if named.clips.isEmpty {
                    Text("Right-click an item in the clipboard panel and choose Save as Named Clipboard…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(named.clips) { clip in
                    HStack {
                        Text(clip.name)
                        Text(clip.item.title).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { named.remove(named: clip.name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Named clipboards")
            } footer: {
                Text("Fixed slots you paste by name: type the name in the launcher (⌥Space) and press Return.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Paste stack") {
                    Text("⌘K adds items in the panel, ⌘↩ starts, \(shortcuts.shortcut(for: .pasteNextFromStack)?.display ?? "the shortcut") pastes the next one")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Button("Clear History…", role: .destructive) { onClear() }
            }
        }
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
