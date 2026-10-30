import AppKit
import SwiftUI

/// Keyboard shortcuts and drag-to-edge snapping for moving windows.
@MainActor
final class WindowsModule: ToolbeltModule {
    let id = ModuleID.windows
    let openTitle = "Window Management…"

    let manager = WindowManager()
    let layouts = LayoutStore()
    let areas = SnapAreaStore()
    private(set) lazy var editor = SnapAreaEditor(store: areas)
    private(set) lazy var snapping: SnapController = {
        let controller = SnapController(manager: manager)
        controller.areas = areas
        return controller
    }()
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
        for slot in 1...9 {
            shortcuts.setHandler(for: .layout(slot)) { [weak self] in
                self?.applyLayout(slot: slot)
            }
        }
    }

    func start() {
        snapping.start()
    }

    func stop() {
        snapping.stop()
        editor.close()
    }

    /// Layout 1 is the first in the list, and so on.
    func applyLayout(slot: Int) {
        guard layouts.layouts.indices.contains(slot - 1) else {
            NSSound.beep()
            return
        }
        LayoutRunner.apply(layouts.layouts[slot - 1], manager: manager)
    }

    /// Saves where every visible app's window is now, asking for a name.
    func saveCurrentLayout() {
        guard PermissionGate.ensure(.accessibility, to: "remember where your windows are") else { return }
        let entries = LayoutRunner.capture()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Save this window layout"
        alert.informativeText = "\(entries.count) app\(entries.count == 1 ? "" : "s"): " + entries.map(\.appName).joined(separator: ", ")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "Layout \(layouts.layouts.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        layouts.layouts.append(SavedLayout(name: field.stringValue.isEmpty ? "Layout" : field.stringValue, entries: entries))
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
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem("Save Current Layout…") { [weak self] in self?.saveCurrentLayout() })
        for (index, layout) in layouts.layouts.enumerated() {
            let entry = ActionMenuItem("Apply “\(layout.name)”") { [weak self] in self?.applyLayout(slot: index + 1) }
            if index < 9, let key = shortcuts.shortcut(for: .layout(index + 1))?.menuKeyEquivalent {
                entry.keyEquivalent = key.key
                entry.keyEquivalentModifierMask = key.modifiers
            }
            submenu.addItem(entry)
        }
        submenu.addItem(ActionMenuItem("Edit Snap Areas…") { [weak self] in self?.editor.open() })
        item.submenu = submenu
        return [item]
    }

    func settingsView() -> AnyView {
        AnyView(WindowsSettingsTab(shortcuts: shortcuts, layouts: layouts, areas: areas, module: self))
    }

    func willTerminate() {}

    private(set) lazy var launcherProvider: LauncherProvider? = WindowsLauncherProvider(manager: manager, module: self)
}

/// "left half", "maximise"… from the launcher move the window you were using.
@MainActor
final class WindowsLauncherProvider: LauncherProvider {
    private let manager: WindowManager
    private weak var module: WindowsModule?

    init(manager: WindowManager, module: WindowsModule? = nil) {
        self.manager = manager
        self.module = module
    }

    func results(for query: String) -> [LauncherResult] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 3 else { return [] }
        var extra: [LauncherResult] = []
        if let module {
            for (index, layout) in module.layouts.layouts.enumerated() {
                let score = max(FuzzyMatch.score(query, layout.name), FuzzyMatch.score(query, "layout") * 0.7)
                guard score > 0 else { continue }
                extra.append(LauncherResult(id: "layout:" + layout.id.uuidString, title: "Apply “\(layout.name)”",
                                            subtitle: layout.entries.map(\.appName).joined(separator: ", "),
                                            kind: "Layout", icon: .symbol("rectangle.3.group"), score: score) { [weak module] in
                    module?.applyLayout(slot: index + 1)
                })
            }
            for (title, run) in [("Save Current Layout", { [weak module] in module?.saveCurrentLayout() }),
                                 ("Edit Snap Areas", { [weak module] in module?.editor.open() })] as [(String, @MainActor () -> Void)] {
                let score = FuzzyMatch.score(query, title)
                if score > 0 {
                    extra.append(LauncherResult(id: "windows:" + title, title: title, kind: "Window", icon: .symbol("rectangle.3.group"),
                                                score: score, action: run))
                }
            }
        }
        return extra + WindowAction.allCases.compactMap { action in
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
    @ObservedObject var layouts: LayoutStore
    @ObservedObject var areas: SnapAreaStore
    let module: WindowsModule
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

            Section {
                ForEach(Array(layouts.layouts.enumerated()), id: \.element.id) { index, layout in
                    HStack {
                        TextField("Name", text: Binding(
                            get: { layout.name },
                            set: { name in if let i = layouts.layouts.firstIndex(where: { $0.id == layout.id }) { layouts.layouts[i].name = name } }
                        ))
                        .labelsHidden()
                        Text(layout.entries.map(\.appName).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if index < 9 {
                            Text(shortcuts.shortcut(for: .layout(index + 1))?.display ?? "").font(.system(.caption, design: .rounded))
                        }
                        Button("Apply") { module.applyLayout(slot: index + 1) }
                        Button { layouts.layouts.removeAll { $0.id == layout.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Save Current Layout…") { module.saveCurrentLayout() }
            } header: {
                Text("Saved layouts")
            } footer: {
                Text("Saves where every visible app's window is. Applying a layout opens any of its apps that aren't running and puts each window back. The first nine have shortcuts (⌃⌥⌘1–9).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Your snap areas") {
                    HStack {
                        Text("\(areas.areas.count)")
                        Button("Edit Snap Areas…") { module.editor.open() }
                    }
                }
            } header: {
                Text("Custom snap areas")
            } footer: {
                Text("Draw your own areas on each display. While dragging a window, hold ⌥ (Option) over an area and the window snaps into it when you let go.")
                    .font(.caption).foregroundStyle(.secondary)
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
