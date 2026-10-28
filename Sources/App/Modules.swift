import AppKit
import SwiftUI

/// Every module Toolbelt has. New modules are added here as they're built.
enum ModuleID: String, CaseIterable, Identifiable {
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        }
    }

    var summary: String {
        switch self {
        case .clipboard: return "Keeps everything you copy and pastes it back with ⌘⇧V."
        }
    }
}

/// What each module provides to the app shell.
@MainActor
protocol ToolbeltModule: AnyObject {
    var id: ModuleID { get }
    /// Title of the menu-bar item that opens the module's main window or panel.
    var openTitle: String { get }

    /// Called when the module is turned on (and Toolbelt isn't paused).
    func start()
    /// Called when the module is turned off or Toolbelt is paused.
    func stop()
    /// Shows the module's main window or panel.
    func open()
    /// Extra menu-bar items shown under the module while it's running.
    func menuItems() -> [NSMenuItem]
    /// The module's tab in Settings, below its on/off switch.
    func settingsView() -> AnyView
    func willTerminate()
}

/// Starts and stops modules as they're turned on and off, or Toolbelt is paused.
@MainActor
final class ModuleManager: ObservableObject {
    let shortcuts: ShortcutCenter
    private(set) var modules: [ToolbeltModule] = []
    private var running: Set<ModuleID> = []

    @Published private(set) var appPaused = Prefs.appPaused

    init(shortcuts: ShortcutCenter) {
        self.shortcuts = shortcuts
    }

    func register(_ module: ToolbeltModule) {
        modules.append(module)
    }

    func module(_ id: ModuleID) -> ToolbeltModule? {
        modules.first { $0.id == id }
    }

    func isEnabled(_ id: ModuleID) -> Bool {
        Prefs.isEnabled(id)
    }

    func isRunning(_ id: ModuleID) -> Bool {
        running.contains(id)
    }

    func setEnabled(_ enabled: Bool, _ id: ModuleID) {
        objectWillChange.send()
        Prefs.setEnabled(enabled, id)
        refresh()
    }

    func setPaused(_ paused: Bool) {
        appPaused = paused
        Prefs.appPaused = paused
        refresh()
    }

    func enabledBinding(_ id: ModuleID) -> Binding<Bool> {
        Binding(
            get: { MainActor.assumeIsolated { self.isEnabled(id) } },
            set: { on in MainActor.assumeIsolated { self.setEnabled(on, id) } }
        )
    }

    var pausedBinding: Binding<Bool> {
        Binding(
            get: { MainActor.assumeIsolated { self.appPaused } },
            set: { on in MainActor.assumeIsolated { self.setPaused(on) } }
        )
    }

    /// Brings every module (and its shortcuts) in line with the current settings.
    func refresh() {
        var activeShortcuts: Set<ShortcutAction> = []
        for module in modules {
            let shouldRun = !appPaused && Prefs.isEnabled(module.id)
            if shouldRun, !running.contains(module.id) {
                module.start()
                running.insert(module.id)
            } else if !shouldRun, running.contains(module.id) {
                module.stop()
                running.remove(module.id)
            }
            if shouldRun {
                activeShortcuts.formUnion(ShortcutAction.allCases.filter { $0.module == module.id })
            }
        }
        shortcuts.setActive(activeShortcuts)
    }
}
