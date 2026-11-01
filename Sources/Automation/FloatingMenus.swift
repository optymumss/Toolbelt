import AppKit
import SwiftUI

// Floating menus and menu-bar items, like BetterTouchTool's:
// - a floating menu is a small panel of buttons that stays above other windows, anywhere on screen;
//   each button runs actions. Any trigger can show or hide it ("Show / hide a floating menu").
// - a menu-bar item is your own item in the menu bar: a fixed title, or the output of a shell script
//   run every so often (a temperature, a stock price, a to-do count). Clicking it runs actions.
// Both are saved in ~/Library/Application Support/Toolbelt/panels.json.

struct FloatingButton: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// An SF Symbol name, shown above the title (optional).
    var symbol: String = ""
    var actions: [MacroAction] = []
}

struct FloatingMenu: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var buttons: [FloatingButton] = []
    /// Its top-left corner, in screen points from the top left of the main display.
    var x: Double = 200
    var y: Double = 200
    var columns: Int = 3
    /// Hide it after a button is clicked.
    var closeAfterClick = false
    /// Show it at the pointer rather than at its own place.
    var atPointer = false
    /// Show it whenever Toolbelt starts.
    var showAtStart = false
}

struct MenuBarItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// A shell script whose first line of output is shown instead of the title (empty for none).
    var script: String = ""
    /// Seconds between runs of the script.
    var every: Int = 60
    var actions: [MacroAction] = []

    /// What the menu bar shows for a script's output: its first line, at most 40 characters.
    static func shown(_ output: String, fallback: String) -> String {
        let line = output.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? fallback : String(line.prefix(40))
    }
}

@MainActor
final class PanelStore: ObservableObject {
    @Published var menus: [FloatingMenu] = [] { didSet { if menus != oldValue { save() } } }
    @Published var menuBarItems: [MenuBarItem] = [] { didSet { if menuBarItems != oldValue { save(); onMenuBarChange?() } } }
    var onMenuBarChange: (() -> Void)?
    private let file = SettingsStore.folder.appendingPathComponent("panels.json")

    struct Saved: Codable {
        var menus: [FloatingMenu]
        var menuBarItems: [MenuBarItem]
    }

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            menus = saved.menus
            menuBarItems = saved.menuBarItems
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(Saved(menus: menus, menuBarItems: menuBarItems)).write(to: file, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save floating menus: \(error)")
        }
    }
}

/// Shows floating menus and menu-bar items, and runs their actions.
@MainActor
final class PanelController {
    let store = PanelStore()
    private var runner: ActionRunner?
    private var panels: [UUID: NSPanel] = [:]
    private var statusItems: [UUID: NSStatusItem] = [:]
    private var timers: [UUID: Timer] = [:]
    private var titles: [UUID: String] = [:]

    func start(runner: ActionRunner) {
        self.runner = runner
        store.onMenuBarChange = { [weak self] in self?.updateMenuBar() }
        updateMenuBar()
        for menu in store.menus where menu.showAtStart { show(menu) }
    }

    func stop() {
        for panel in panels.values { panel.orderOut(nil) }
        panels = [:]
        for item in statusItems.values { NSStatusBar.system.removeStatusItem(item) }
        statusItems = [:]
        timers.values.forEach { $0.invalidate() }
        timers = [:]
        runner = nil
        RealUseHooks.writeStatus()
    }

    // MARK: Floating menus

    func isShowing(_ name: String) -> Bool {
        guard let menu = store.menus.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        return panels[menu.id]?.isVisible == true
    }

    /// Shows the menu with this name, or hides it if it's showing.
    func toggle(named name: String) {
        guard let menu = store.menus.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            HUD.show("There's no floating menu called “\(name)”", symbol: "exclamationmark.triangle")
            return
        }
        if panels[menu.id]?.isVisible == true { hide(menu.id) } else { show(menu) }
    }

    func show(_ menu: FloatingMenu) {
        hide(menu.id)
        let columns = max(1, min(menu.columns, max(1, menu.buttons.count)))
        let rows = max(1, Int(ceil(Double(max(1, menu.buttons.count)) / Double(columns))))
        let size = NSSize(width: CGFloat(columns) * 88 + 16, height: CGFloat(rows) * 64 + 16)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 900
        let topLeft = menu.atPointer ? MouseDriver.pointer : CGPoint(x: menu.x, y: menu.y)
        let origin = NSPoint(x: topLeft.x, y: screenHeight - topLeft.y - size.height)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = menu.name
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = FirstClickHostingView(rootView: FloatingMenuView(menu: menu, columns: columns) { [weak self] button in
            self?.clicked(button, in: menu)
        })
        panel.orderFrontRegardless()
        panels[menu.id] = panel
        RealUseHooks.writeStatus()
    }

    func hide(_ id: UUID) {
        panels.removeValue(forKey: id)?.orderOut(nil)
        RealUseHooks.writeStatus()
    }

    private func clicked(_ button: FloatingButton, in menu: FloatingMenu) {
        if menu.closeAfterClick { hide(menu.id) }
        for action in button.actions { runner?.run(action) }
    }

    /// Where each showing menu is (top-left screen points), for the real-use tests.
    var showingFrames: [String: [Double]] {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 900
        var frames: [String: [Double]] = [:]
        for menu in store.menus {
            guard let panel = panels[menu.id], panel.isVisible else { continue }
            let frame = panel.frame
            frames[menu.name] = [frame.minX, screenHeight - frame.maxY, frame.width, frame.height]
        }
        return frames
    }

    // MARK: Menu-bar items

    func updateMenuBar() {
        guard runner != nil else { return }
        let wanted = Set(store.menuBarItems.map(\.id))
        for (id, item) in statusItems where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            statusItems[id] = nil
            timers.removeValue(forKey: id)?.invalidate()
        }
        for item in store.menuBarItems {
            let status = statusItems[item.id] ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItems[item.id] = status
            status.button?.title = titles[item.id] ?? item.title
            status.button?.target = self
            status.button?.action = #selector(menuBarClicked(_:))
            status.button?.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            timers.removeValue(forKey: item.id)?.invalidate()
            guard !item.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                titles[item.id] = item.title
                status.button?.title = item.title
                continue
            }
            refresh(item)
            let timer = Timer(timeInterval: Double(max(5, item.every)), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(item) }
            }
            timer.tolerance = Double(max(5, item.every)) * 0.2
            RunLoop.main.add(timer, forMode: .common)
            timers[item.id] = timer
        }
        RealUseHooks.writeStatus()
    }

    private func refresh(_ item: MenuBarItem) {
        ActionRunner.runScript("/bin/zsh", ["-c", item.script]) { [weak self] output in
            Task { @MainActor in
                guard let self, let status = self.statusItems[item.id] else { return }
                let shown = MenuBarItem.shown(output, fallback: item.title)
                self.titles[item.id] = shown
                status.button?.title = shown
                RealUseHooks.writeStatus()
            }
        }
    }

    @objc private func menuBarClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let item = store.menuBarItems.first(where: { $0.id == id }) else { return }
        for action in item.actions { runner?.run(action) }
    }

    /// What each item shows and where (top-left screen points), for the real-use tests.
    var menuBarStatus: [[String: Any]] {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 900
        return store.menuBarItems.compactMap { item in
            guard let window = statusItems[item.id]?.button?.window else { return nil }
            let frame = window.frame
            return ["title": titles[item.id] ?? item.title, "frame": [frame.minX, screenHeight - frame.maxY, frame.width, frame.height]]
        }
    }
}

/// Buttons in a floating menu work on the first click, even while another app is in front.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct FloatingMenuView: View {
    let menu: FloatingMenu
    let columns: Int
    let clicked: (FloatingButton) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: 8), count: columns), spacing: 8) {
            ForEach(menu.buttons) { button in
                Button { clicked(button) } label: {
                    VStack(spacing: 4) {
                        if !button.symbol.isEmpty { Image(systemName: button.symbol).font(.title2) }
                        Text(button.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(width: 80, height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
            }
            if menu.buttons.isEmpty { Text("No buttons yet").font(.caption).frame(width: 80, height: 56) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }
}

// MARK: - Settings

struct PanelSettings: View {
    @ObservedObject var store: PanelStore
    let controller: PanelController
    @State private var editingMenu: UUID?
    @State private var editingItem: UUID?

    var body: some View {
        Section {
            ForEach($store.menus) { $menu in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $menu.name)
                        Button("Show / Hide") { controller.toggle(named: menu.name) }
                        Button(editingMenu == menu.id ? "Done" : "Edit") { editingMenu = editingMenu == menu.id ? nil : menu.id }
                        Button { store.menus.removeAll { $0.id == menu.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    if editingMenu == menu.id {
                        HStack {
                            Stepper("\(menu.columns) across", value: $menu.columns, in: 1...8)
                            Toggle("Close after a click", isOn: $menu.closeAfterClick)
                            Toggle("At the pointer", isOn: $menu.atPointer)
                            Toggle("Show when Toolbelt starts", isOn: $menu.showAtStart)
                        }
                        if !menu.atPointer {
                            HStack {
                                TextField("Left", value: $menu.x, format: .number).frame(width: 70)
                                TextField("Top", value: $menu.y, format: .number).frame(width: 70)
                                Text("points from the top left of the main display").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach($menu.buttons) { $button in
                            VStack(alignment: .leading) {
                                HStack {
                                    TextField("Button title", text: $button.title)
                                    TextField("Symbol (e.g. star)", text: $button.symbol).frame(width: 140)
                                    Button { menu.buttons.removeAll { $0.id == button.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                }
                                ActionEditor(action: Binding(get: { button.actions.first ?? MacroAction(kind: .system) },
                                                             set: { button.actions = [$0] }))
                            }
                            .padding(.leading, 12)
                        }
                        Button("Add Button") { menu.buttons.append(FloatingButton(title: "Button", actions: [MacroAction(kind: .system)])) }
                    }
                }
            }
            Button("New Floating Menu") {
                let menu = FloatingMenu(name: "Menu \(store.menus.count + 1)", buttons: [FloatingButton(title: "Launcher", symbol: "magnifyingglass",
                                                                                                         actions: [.toolbelt(.openLauncher)])])
                store.menus.append(menu)
                editingMenu = menu.id
            }
        } header: {
            Text("Floating menus")
        } footer: {
            Text("Panels of buttons that stay above other windows. Drag one by its background to move it. Show or hide one from any trigger with the action “Show / hide a floating menu”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            ForEach($store.menuBarItems) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Title", text: $item.title)
                        Button(editingItem == item.id ? "Done" : "Edit") { editingItem = editingItem == item.id ? nil : item.id }
                        Button { store.menuBarItems.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    if editingItem == item.id {
                        TextField("Shell script whose output is shown (optional), e.g. date +%H:%M", text: $item.script)
                            .font(.system(.body, design: .monospaced))
                        Stepper("Run it every \(item.every) seconds", value: $item.every, in: 5...3600, step: 5)
                        ActionEditor(action: Binding(get: { item.actions.first ?? MacroAction(kind: .system) }, set: { item.actions = [$0] }))
                    }
                }
            }
            Button("New Menu-Bar Item") {
                let item = MenuBarItem(title: "★", actions: [.toolbelt(.openLauncher)])
                store.menuBarItems.append(item)
                editingItem = item.id
            }
        } header: {
            Text("Menu-bar items")
        } footer: {
            Text("Your own items in the menu bar. With a script, its first line of output is shown and refreshed. Clicking the item runs its action.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
