import AppKit
import SwiftUI

/// Macros: triggers (keys, typed text, gestures, other keyboards, apps, folders, Wi-Fi, displays,
/// Spaces, times, the menu bar, the launcher, Terminal) start steps with actions, variables,
/// conditions and loops. Each kind of trigger is only watched while some macro uses it.
@MainActor
final class AutomationModule: ToolbeltModule {
    let id = ModuleID.automation
    let openTitle = "Macros…"

    let store = MacroStore()
    let runner: ActionRunner
    weak var gestures: GesturesModule?
    let deviceKeys = DeviceKeyWatcher()
    let network = NetworkWatcher()
    /// Names of the macros that ran, most recent last (shown in the editor, used by the tests).
    private(set) var history: [String] = []
    var lastRun: MacroRun?

    private var running = false
    private var hotKeys: [HotKey] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var folderWatchers: [FolderWatcher] = []
    private var timers: [Timer] = []
    private var terminalInbox: FolderWatcher?
    private var screenCount = NSScreen.screens.count
    private var editor: NSWindow?

    static var terminalFolder: URL { SettingsStore.folder.appendingPathComponent("inbox-macros", isDirectory: true) }

    init(shortcuts: ShortcutCenter, gestures: GesturesModule? = nil) {
        runner = ActionRunner(shortcuts: shortcuts)
        self.gestures = gestures
        store.onChange = { [weak self] in self?.arm() }
        gestures?.extraRules = { [weak self] in self?.gestureRules() ?? [] }
    }

    func start() {
        running = true
        ActionRunner.runMacro = { [weak self] name in self?.run(named: name) }
        arm()
    }

    func stop() {
        running = false
        disarm()
        gestures?.updateListening()
    }

    func open() {
        if editor == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MacrosView(store: store, module: self)))
            window.title = "Macros"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 600))
            window.center()
            window.setFrameAutosaveName("ToolbeltMacros")
            editor = window
        }
        NSApp.activate()
        editor?.makeKeyAndOrderFront(nil)
    }

    // MARK: Running

    func run(named name: String, trigger: String = "") {
        guard let macro = store.macro(named: name) else { return }
        run(macro, trigger: trigger)
    }

    func run(_ macro: Macro, trigger: String = "") {
        history.append(macro.name)
        if history.count > 50 { history.removeFirst() }
        let run = MacroRun(runner: runner, trigger: trigger)
        lastRun = run
        Task { await run.run(macro.steps) }
    }

    /// A trigger happened: run the macro if it (and its group) apply in the app in front.
    private func fire(_ macro: Macro, value: String = "") {
        guard running, store.isActive(macro, in: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        run(macro, trigger: value)
    }

    /// Macros, and their triggers of one kind, that can currently run.
    private func triggers(_ kinds: Set<MacroTrigger.Kind>) -> [(Macro, MacroTrigger)] {
        store.macros.filter { macro in
            macro.enabled && (store.group(of: macro)?.enabled ?? true)
        }.flatMap { macro in macro.triggers.filter { kinds.contains($0.kind) }.map { (macro, $0) } }
    }

    // MARK: Watching for triggers

    func arm() {
        disarm()
        guard running else { return }

        for (macro, trigger) in triggers([.hotKey]) where trigger.keyCode != 0 || trigger.modifiers != 0 {
            let key = HotKey(shortcut: Shortcut(keyCode: trigger.keyCode, modifiers: trigger.modifiers)) { [weak self] in
                self?.fire(macro)
            }
            if key.isRegistered { hotKeys.append(key) }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let appKinds: [(MacroTrigger.Kind, Notification.Name)] = [
            (.appLaunched, NSWorkspace.didLaunchApplicationNotification),
            (.appQuit, NSWorkspace.didTerminateApplicationNotification),
            (.appActivated, NSWorkspace.didActivateApplicationNotification),
        ]
        for (kind, name) in appKinds where !triggers([kind]).isEmpty {
            observe(workspace, name) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.appEvent(kind, bundleID: app?.bundleIdentifier, name: app?.localizedName)
            }
        }
        if !triggers([.spaceChanged]).isEmpty {
            observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.simpleEvent(.spaceChanged) }
        }
        if !triggers([.displayConnected, .displayDisconnected]).isEmpty {
            screenCount = NSScreen.screens.count
            observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.screensChanged() }
        }

        for (macro, trigger) in triggers([.fileAdded]) where !trigger.text.isEmpty {
            let folder = URL(fileURLWithPath: (trigger.text as NSString).expandingTildeInPath, isDirectory: true)
            let watcher = FolderWatcher(folder: folder) { [weak self] files in
                for file in files { self?.fire(macro, value: file.path) }
            }
            watcher.start()
            folderWatchers.append(watcher)
        }

        for (macro, trigger) in triggers([.timeOfDay, .every]) {
            schedule(macro, trigger)
        }

        let deviceTriggers = triggers([.deviceKey])
        if !deviceTriggers.isEmpty, PermissionGate.ensure(.inputMonitoring, to: "notice keys on your other keyboards") {
            deviceKeys.onKey = { [weak self] device, usage in self?.deviceKey(device, usage) }
            deviceKeys.start(exclusiveDevices: Set(deviceTriggers.filter { $0.1.exclusive }.map { $0.1.text }))
        }

        let wifi = !triggers([.wifiChanged]).isEmpty, net = !triggers([.networkChanged]).isEmpty
        if wifi || net {
            network.onWiFiChange = { [weak self] name in self?.wifiChanged(name) }
            network.onNetworkChange = { [weak self] in self?.simpleEvent(.networkChanged) }
            network.start(wifi: wifi, network: net)
        }

        // `ToolbeltBridge run "Name"` in Terminal drops a request here.
        let inbox = Self.terminalFolder
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        processTerminal((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
        let watcher = FolderWatcher(folder: inbox) { [weak self] files in self?.processTerminal(files) }
        watcher.start()
        terminalInbox = watcher

        gestures?.updateListening()
    }

    private func disarm() {
        for key in hotKeys { key.unregister() }
        hotKeys = []
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        for watcher in folderWatchers { watcher.stop() }
        folderWatchers = []
        for timer in timers { timer.invalidate() }
        timers = []
        deviceKeys.stop()
        network.stop()
        terminalInbox?.stop()
        terminalInbox = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, observer))
    }

    func appEvent(_ kind: MacroTrigger.Kind, bundleID: String?, name: String?) {
        for (macro, trigger) in triggers([kind]) where trigger.text.isEmpty || trigger.text == bundleID {
            fire(macro, value: name ?? bundleID ?? "")
        }
    }

    func simpleEvent(_ kind: MacroTrigger.Kind, value: String = "") {
        for (macro, _) in triggers([kind]) { fire(macro, value: value) }
    }

    func screensChanged() {
        let count = NSScreen.screens.count
        defer { screenCount = count }
        if count > screenCount { simpleEvent(.displayConnected) }
        if count < screenCount { simpleEvent(.displayDisconnected) }
    }

    func wifiChanged(_ name: String?) {
        for (macro, trigger) in triggers([.wifiChanged]) where trigger.text.isEmpty || trigger.text == name {
            fire(macro, value: name ?? "")
        }
    }

    func deviceKey(_ device: String, _ usage: Int) {
        for (macro, trigger) in triggers([.deviceKey]) where trigger.text == device && trigger.number == usage {
            fire(macro, value: device)
        }
    }

    /// One timer per timed trigger, set for its next time; nothing runs in between.
    private func schedule(_ macro: Macro, _ trigger: MacroTrigger) {
        guard let date = MacroSchedule.next(trigger, after: Date()) else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timers.removeAll { $0 === timer }
                self.fire(macro)
                self.schedule(macro, trigger)
            }
        }
        // A little leeway lets macOS group wake-ups together, which saves battery.
        timer.tolerance = trigger.kind == .every ? min(60, Double(trigger.number) * 6) : 10
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func processTerminal(_ files: [URL]) {
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let name = request["macro"], let macro = store.macro(named: name),
                  macro.triggers.contains(where: { $0.kind == .terminal }) else { continue }
            fire(macro, value: request["input"] ?? "")
        }
    }

    /// Typed-text and gesture triggers, handed to the Gestures module, which listens for them.
    func gestureRules() -> [GestureRule] {
        guard running else { return [] }
        return triggers([.typedText, .gesture]).compactMap { macro, trigger in
            let gesture: Gesture? = trigger.kind == .typedText ? (trigger.text.isEmpty ? nil : .keySequence(trigger.text)) : trigger.gesture
            guard let gesture else { return nil }
            let group = store.group(of: macro)
            return GestureRule(gesture: gesture, action: MacroAction(kind: .macro, value: macro.name),
                               scope: group?.scope ?? .everywhere, apps: group?.apps ?? [])
        }
    }

    // MARK: Menu bar, launcher, settings

    func menuItems() -> [NSMenuItem] {
        triggers([.menuBar]).map { macro, _ in
            ActionMenuItem("▸ \(macro.name)") { [weak self] in self?.fire(macro) }
        }
    }

    func settingsView() -> AnyView {
        AnyView(AutomationSettingsTab(store: store) { [weak self] in self?.open() })
    }

    func willTerminate() {
        disarm()
    }

    private(set) lazy var launcherProvider: LauncherProvider? = MacrosLauncherProvider(module: self)

    var launcherMacros: [Macro] { triggers([.launcher]).map(\.0) }
}

@MainActor
final class MacrosLauncherProvider: LauncherProvider {
    private weak var module: AutomationModule?

    init(module: AutomationModule) {
        self.module = module
    }

    func results(for query: String) -> [LauncherResult] {
        guard let module, query.count >= 2 else { return [] }
        return module.launcherMacros.compactMap { macro in
            let score = max(FuzzyMatch.score(query, macro.name), FuzzyMatch.score(query, "macro") * 0.5)
            guard score > 0 else { return nil }
            return LauncherResult(id: "macro:" + macro.id.uuidString, title: macro.name, subtitle: "\(macro.steps.count) steps",
                                  kind: "Macro", icon: .symbol("gearshape.2"), score: score) { [weak module] in
                // The launcher closes first, so the macro works on the app you were in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated { module?.run(macro) }
                }
            }
        }
    }
}
