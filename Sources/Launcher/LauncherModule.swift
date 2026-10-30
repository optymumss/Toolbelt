import AppKit
import SwiftUI

/// ⌥Space search bar: apps, files, sums, unit conversions, quicklinks,
/// system commands, and anything other modules can be searched for.
@MainActor
final class LauncherModule: ToolbeltModule {
    let id = ModuleID.launcher
    let openTitle = "Launcher"

    let calculator = CalculatorProvider()
    let apps = AppsProvider()
    let quicklinks = QuicklinksProvider()
    let commands = SystemCommandsProvider()
    private(set) var panel: LauncherPanelController!
    private weak var modules: ModuleManager?
    private let shortcuts: ShortcutCenter

    init(shortcuts: ShortcutCenter, modules: ModuleManager, openSettings: @escaping () -> Void) {
        self.shortcuts = shortcuts
        self.modules = modules
        commands.extraCommands = [
            SystemCommand(name: "Toolbelt Settings", keywords: ["preferences", "settings"], symbol: "gearshape", run: openSettings),
            SystemCommand(name: "Quit Toolbelt", keywords: ["quit"], symbol: "xmark.circle") { NSApp.terminate(nil) },
        ]
        let model = LauncherModel { [weak self] in self?.providers() ?? [] }
        panel = LauncherPanelController(model: model)

        shortcuts.setHandler(for: .openLauncher) { [weak self] in
            self?.panel.toggle()
        }
    }

    /// Everything one search reaches. Other modules join through `launcherProvider`.
    func providers() -> [LauncherProvider] {
        var list: [LauncherProvider] = [calculator, quicklinks, commands, apps]
        if let modules {
            for module in modules.modules where module.id != .launcher && modules.isRunning(module.id) {
                if module.id == .clipboard, !Prefs.launcherSearchClipboard { continue }
                if let provider = module.launcherProvider { list.append(provider) }
            }
        }
        return list
    }

    func start() {
        apps.refreshIfNeeded()
    }

    func stop() {
        panel.hide()
    }

    func open() {
        panel.show()
    }

    func open(query: String) {
        panel.show(query: query)
    }

    func menuItems() -> [NSMenuItem] { [] }

    func settingsView() -> AnyView {
        AnyView(LauncherSettingsTab(shortcuts: shortcuts))
    }

    func willTerminate() {}
}

struct LauncherSettingsTab: View {
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject private var settings = SettingsStore.shared
    @State private var links: [Quicklink] = Prefs.quicklinks

    var body: some View {
        Group {
            Section("Search") {
                LabeledContent("Open launcher") {
                    Text(shortcuts.shortcut(for: .openLauncher)?.display ?? "No shortcut")
                        .font(.system(.body, design: .rounded))
                }
                Toggle("Include files and folders", isOn: settings.binding("launcher.files", default: true))
                Toggle("Include clipboard history", isOn: settings.binding("launcher.clipboard", default: true))
            }

            Section {
                ForEach($links) { $link in
                    HStack(spacing: 8) {
                        TextField("Keyword", text: $link.keyword)
                            .frame(width: 60)
                        TextField("Name", text: $link.name)
                            .frame(width: 110)
                        TextField("Address", text: $link.url)
                        Button {
                            links.removeAll { $0.id == link.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Add Quicklink") {
                        links.append(Quicklink(keyword: "", name: "", url: "https://"))
                    }
                    Spacer()
                    Button("Restore Defaults") { links = Quicklink.defaults }
                }
            } header: {
                Text("Quicklinks")
            } footer: {
                Text("Type the keyword, a space and your search words — for example “g cats”. In the address, put {query} where the search words go.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: links) { Prefs.quicklinks = links }
    }
}
