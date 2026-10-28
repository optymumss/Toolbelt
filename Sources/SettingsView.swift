import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var onClear: () -> Void

    @AppStorage("pasteAfterSelect") private var pasteAfterSelect = true
    @AppStorage("historyLimit") private var historyLimit = 1000

    @State private var ignored: [String] = Prefs.ignoredBundleIDs
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityOK = Accessibility.isTrusted(prompt: false)
    @State private var loginError: String?

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Toolbelt when you log in", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { setOpenAtLogin(openAtLogin) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Color.orange)
                }
                Toggle("Paste automatically after choosing an item", isOn: $pasteAfterSelect)
                Picker("Keep up to", selection: $historyLimit) {
                    Text("200 items").tag(200)
                    Text("1,000 items").tag(1000)
                    Text("5,000 items").tag(5000)
                    Text("Unlimited").tag(0)
                }
                LabeledContent("Open history") {
                    Text("⌘⇧V").font(.system(.body, design: .rounded))
                }
            }

            Section {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(accessibilityOK ? "Allowed" : "Not allowed")
                            .foregroundStyle(accessibilityOK ? Color.green : Color.orange)
                        if !accessibilityOK {
                            Button("Open Settings") { Accessibility.openSettings() }
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Needed only for automatic pasting. Without it, choosing an item copies it and you press ⌘V yourself.")
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
        .frame(width: 480, height: 600)
        .onReceive(refresh) { _ in
            accessibilityOK = Accessibility.isTrusted(prompt: false)
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != openAtLogin { openAtLogin = actual }
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
