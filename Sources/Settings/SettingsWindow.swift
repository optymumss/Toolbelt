import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general, shortcuts, permissions
    case module(ModuleID)
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController {
    private let modules: ModuleManager
    private let shortcuts: ShortcutCenter
    private let model = SettingsModel()
    private var window: NSWindow?

    init(modules: ModuleManager, shortcuts: ShortcutCenter) {
        self.modules = modules
        self.shortcuts = shortcuts
    }

    /// Opens Settings, optionally on a particular tab.
    func show(tab: SettingsTab?) {
        if let tab { model.tab = tab }
        if window == nil {
            let view = SettingsRootView(model: model, modules: modules, shortcuts: shortcuts)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Toolbelt Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Size the window before centring it; otherwise it's centred while
            // still tiny and then grows off the right edge of the screen.
            window.setContentSize(SettingsRootView.size)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    let modules: ModuleManager
    let shortcuts: ShortcutCenter

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(modules: modules)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ShortcutsTab(modules: modules, shortcuts: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(SettingsTab.shortcuts)

            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)

            ForEach(ModuleID.allCases) { id in
                if let module = modules.module(id) {
                    ModuleTab(module: module, modules: modules)
                        .tabItem { Label(id.title, systemImage: id.symbol) }
                        .tag(SettingsTab.module(id))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    static let size = NSSize(width: 600, height: 620)
}

/// A module's settings tab: its on/off switch, then the module's own settings.
struct ModuleTab: View {
    let module: ToolbeltModule
    @ObservedObject var modules: ModuleManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: modules.enabledBinding(module.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn on \(module.id.title)")
                        Text(module.id.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if modules.appPaused {
                    Text("Toolbelt is paused, so nothing runs until you resume it from the menu bar or the General tab.")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }

            module.settingsView()
                .disabled(!modules.isEnabled(module.id))
                .opacity(modules.isEnabled(module.id) ? 1 : 0.5)
        }
        .formStyle(.grouped)
    }
}
