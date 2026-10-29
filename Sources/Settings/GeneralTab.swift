import AppKit
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @ObservedObject var modules: ModuleManager
    @ObservedObject private var settings = SettingsStore.shared

    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Toolbelt when you log in", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { setOpenAtLogin(openAtLogin) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Color.orange)
                }
            }

            Section("Appearance") {
                Picker("Look", selection: appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Pause Toolbelt", isOn: modules.pausedBinding)
                ForEach(ModuleID.allCases) { id in
                    Toggle(isOn: modules.enabledBinding(id)) {
                        Label(id.title, systemImage: id.symbol)
                    }
                }
            } header: {
                Text("Modules")
            } footer: {
                Text("Pausing stops every module and its shortcuts until you resume. Turning a module off keeps its data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Your data") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.folder])
                    }
                }
                LabeledContent("Version", value: Self.version)
            } footer: {
                Text("Everything Toolbelt keeps, including settings and clipboard history, stays on this Mac in ~/Library/Application Support/Toolbelt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: Binding<AppearanceMode> {
        Binding(
            get: { MainActor.assumeIsolated { Prefs.appearance } },
            set: { mode in
                MainActor.assumeIsolated {
                    Prefs.appearance = mode
                    mode.apply()
                }
            }
        )
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
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
}
