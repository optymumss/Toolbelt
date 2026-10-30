import AppKit
import SwiftUI

/// Keyboard shortcuts and drag-to-edge snapping for moving windows.
@MainActor
final class WindowsModule: ToolbeltModule {
    let id = ModuleID.windows
    let openTitle = "Window Management…"

    let manager = WindowManager()
    private(set) lazy var snapping = SnapController(manager: manager)
    private let shortcuts: ShortcutCenter
    private let openSettings: () -> Void

    init(shortcuts: ShortcutCenter, openSettings: @escaping () -> Void) {
        self.shortcuts = shortcuts
        self.openSettings = openSettings
        for action in WindowAction.allCases {
            shortcuts.setHandler(for: .window(action)) { [weak self] in
                self?.manager.perform(action)
            }
        }
    }

    func start() {
        snapping.start()
    }

    func stop() {
        snapping.stop()
    }

    func open() {
        openSettings()
    }

    /// The common moves, in a submenu of the menu bar icon.
    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Move Front Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let common: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .center, .restore, .nextDisplay]
        for action in common {
            let entry = ActionMenuItem(action.title) { [weak self] in self?.manager.perform(action) }
            entry.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if let key = shortcuts.shortcut(for: .window(action))?.menuKeyEquivalent {
                entry.keyEquivalent = key.key
                entry.keyEquivalentModifierMask = key.modifiers
            }
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return [item]
    }

    func settingsView() -> AnyView {
        AnyView(WindowsSettingsTab(shortcuts: shortcuts))
    }

    func willTerminate() {}

    private(set) lazy var launcherProvider: LauncherProvider? = WindowsLauncherProvider(manager: manager)
}

/// "left half", "maximise"… from the launcher move the window you were using.
@MainActor
final class WindowsLauncherProvider: LauncherProvider {
    private let manager: WindowManager

    init(manager: WindowManager) {
        self.manager = manager
    }

    func results(for query: String) -> [LauncherResult] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 3 else { return [] }
        return WindowAction.allCases.compactMap { action in
            let score = max(FuzzyMatch.score(query, action.title), FuzzyMatch.score(query, "window " + action.title))
            guard score > 0 else { return nil }
            return LauncherResult(
                id: "window:" + action.rawValue, title: action.title, subtitle: "Move the front window",
                kind: "Window", icon: .symbol(action.symbol), score: score
            ) { [manager] in
                manager.perform(action)
            }
        }
    }
}

struct WindowsSettingsTab: View {
    @ObservedObject var shortcuts: ShortcutCenter
    @ObservedObject private var settings = SettingsStore.shared
    @State private var accessibilityOK = Permission.accessibility.isGranted
    /// Re-checks permissions when a window comes to the front (for example after you return from
    /// System Settings), instead of a timer that would keep waking the Mac while Settings is closed.
    private let refresh = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)

    var body: some View {
        Group {
            Section {
                Toggle("Snap windows dragged to a screen edge or corner", isOn: settings.binding("windows.snap", default: true))
                Picker("Gap between windows", selection: settings.binding("windows.gap", default: 0)) {
                    Text("None").tag(0)
                    Text("Small").tag(6)
                    Text("Medium").tag(12)
                    Text("Large").tag(20)
                }
                LabeledContent("Accessibility") {
                    HStack {
                        Text(accessibilityOK ? "Allowed" : "Not allowed yet")
                            .foregroundStyle(accessibilityOK ? Color.green : Color.orange)
                        if !accessibilityOK {
                            Button("Allow…") { Permission.accessibility.openSettings() }
                        }
                    }
                }
            } header: {
                Text("Windows")
            } footer: {
                Text("Drag a window's title bar to the left or right edge for half the screen, a corner for a quarter, or the top edge to fill the screen. Moving windows needs the Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ForEach(WindowAction.allCases) { action in
                    LabeledContent {
                        Text(shortcuts.shortcut(for: .window(action))?.display ?? "—")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
                Text("Change these in the Shortcuts tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(refresh) { _ in accessibilityOK = Permission.accessibility.isGranted }
    }
}
