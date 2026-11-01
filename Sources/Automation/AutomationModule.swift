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
    let power = PowerWatcher()
    let usb = USBWatcher()
    let bluetooth = BluetoothWatcher()
    let clipboard = ClipboardWatcher()
    let frontWindow = FrontWindowWatcher()
    /// Macros started by a clipboard change that are still running: their own copies don't start them again.
    private var clipboardRuns = 0
    private var announcedStart = false
    private var powerState: (onAC: Bool, percent: Int?)?
    private var batteryChecks: [UUID: BatteryThreshold] = [:]
    private var idleTrackers: [UUID: IdleTracker] = [:]
    private var idleTimer: Timer?
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

    let web = WebServer()
    let panels = PanelController()
    let recorder = MacroRecorder()

    /// Starts, restarts or stops the web server to match Settings.
    func updateWebServer() {
        guard running, Prefs.webServerOn else { web.stop(); return }
        web.start(port: UInt16(clamping: Prefs.webServerPort), everyone: Prefs.webServerEveryone, api: webAPI)
    }

    var webAPI: WebAPI {
        WebAPI(secret: Prefs.webServerSecret,
               macroNames: { [weak self] in self?.store.macros.filter(\.enabled).map(\.name) ?? [] },
               runMacro: { [weak self] name, input in self?.run(named: name, trigger: input) },
               runAction: { [weak self] action in self?.runner.run(action) })
    }

    init(shortcuts: ShortcutCenter, gestures: GesturesModule? = nil) {
        runner = ActionRunner(shortcuts: shortcuts)
        self.gestures = gestures
        store.onChange = { [weak self] in self?.arm() }
        gestures?.extraRules = { [weak self] in self?.gestureRules() ?? [] }
    }

    func start() {
        running = true
        ActionRunner.runMacro = { [weak self] name in self?.run(named: name) }
        ActionRunner.toggleFloatingMenu = { [weak self] name in self?.panels.toggle(named: name) }
        panels.start(runner: runner)
        RealUseHooks.commands["record-start"] = { [weak self] name in self?.startTestRecording(into: name) }
        RealUseHooks.commands["record-stop"] = { [weak self] _ in self?.recorder.stop() }
        RealUseHooks.extraStatus["recorded"] = { [weak self] in
            self?.store.macro(named: "Recorded")?.steps.map(\.summary) ?? []
        }
        RealUseHooks.extraStatus["floatingMenus"] = { [weak self] in self?.panels.showingFrames ?? [:] }
        RealUseHooks.extraStatus["menuBarItems"] = { [weak self] in self?.panels.menuBarStatus ?? [] }
        arm()
        updateWebServer()
        if !announcedStart {
            announcedStart = true
            let atLogin = LoginTime.isAtLogin(started: Date(), loggedIn: LoginTime.current())
            // A moment later, so every module is ready for what the macro does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    self?.simpleEvent(.toolbeltStarts)
                    if atLogin { self?.simpleEvent(.atLogin) }
                }
            }
        }
    }

    func stop() {
        running = false
        web.stop()
        panels.stop()
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

    /// Runs one step on its own (the ⋯ → Try This Step button).
    func tryStep(_ step: MacroStep) {
        let run = MacroRun(runner: runner)
        Task { await run.run([step]) }
    }

    /// Every shortcut in use: Toolbelt's commands, triggers and macros.
    func usedShortcuts() -> [UsedShortcuts.Entry] {
        let commands = ShortcutAction.allCases.compactMap { action in
            runner.shortcuts.shortcut(for: action).map { (title: action.title, shortcut: $0) }
        }
        return UsedShortcuts.collect(commands: commands, rules: gestures?.store.rules ?? [], macros: store.macros)
    }

    /// For the real-use tests: record into the macro with this name (made if it doesn't exist), and stop.
    func startTestRecording(into name: String) {
        if store.macro(named: name) == nil { store.macros.append(Macro(name: name)) }
        recorder.start { [weak self] steps in
            guard let self, let index = self.store.macros.firstIndex(where: { $0.name == name }) else { return }
            self.store.macros[index].steps += steps
            RealUseHooks.writeStatus()
        }
    }

    func run(named name: String, trigger: String = "") {
        guard let macro = store.macro(named: name) else { return }
        run(macro, trigger: trigger)
    }

    func run(_ macro: Macro, trigger: String = "", done: (() -> Void)? = nil) {
        history.append(macro.name)
        if history.count > 50 { history.removeFirst() }
        let run = MacroRun(runner: runner, trigger: trigger)
        lastRun = run
        Task {
            await run.run(macro.steps)
            done?()
        }
    }

    /// A trigger happened: run the macro if it (and its group) apply in the app in front.
    /// `app` is the app the trigger is about when it's the one coming to the front (otherwise the app in front).
    @discardableResult
    private func fire(_ macro: Macro, value: String = "", app: String? = nil, done: (() -> Void)? = nil) -> Bool {
        guard running, store.isActive(macro, in: app ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return false }
        run(macro, trigger: value, done: done)
        return true
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

        armSystemEvents()

        if !triggers([.clipboardChanged]).isEmpty {
            clipboard.onChange = { [weak self] text in self?.clipboardChanged(text) }
            clipboard.start()
        }
        if !triggers([.windowChanged, .windowTitleChanged]).isEmpty {
            frontWindow.onChange = { [weak self] change, title in self?.frontWindowChanged(change, title: title) }
            frontWindow.start()
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
        power.stop()
        usb.stop()
        bluetooth.stop()
        clipboard.stop()
        frontWindow.stop()
        idleTimer?.invalidate()
        idleTimer = nil
        terminalInbox?.stop()
        terminalInbox = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, observer))
    }

    // MARK: The Mac's own events

    private func armSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let simple: [(MacroTrigger.Kind, NotificationCenter, Notification.Name)] = [
            (.macWakes, workspace, NSWorkspace.didWakeNotification),
            (.macSleeps, workspace, NSWorkspace.willSleepNotification),
            (.screenLocked, DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
            (.screenUnlocked, DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (kind, center, name) in simple where !triggers([kind]).isEmpty {
            observe(center, name) { [weak self] _ in self?.simpleEvent(kind) }
        }
        for (kind, name) in [(MacroTrigger.Kind.diskMounted, NSWorkspace.didMountNotification),
                             (.diskUnmounted, NSWorkspace.didUnmountNotification)] where !triggers([kind]).isEmpty {
            observe(workspace, name) { [weak self] note in
                let disk = note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
                    ?? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.lastPathComponent ?? ""
                self?.namedEvent(kind, disk)
            }
        }
        if !triggers([.powerConnected, .powerDisconnected, .batteryBelow]).isEmpty {
            powerState = PowerWatcher.state()
            batteryChecks = [:]
            for (_, trigger) in triggers([.batteryBelow]) {
                var check = BatteryThreshold(below: trigger.number)
                _ = check.update(percent: powerState?.percent, onBattery: !(powerState?.onAC ?? true))
                batteryChecks[trigger.id] = check
            }
            power.onChange = { [weak self] onAC, percent in self?.powerChanged(onAC: onAC, percent: percent) }
            power.start()
        }
        if !triggers([.usbConnected, .usbDisconnected]).isEmpty {
            usb.onChange = { [weak self] name, connected in self?.namedEvent(connected ? .usbConnected : .usbDisconnected, name) }
            usb.start()
        }
        if !triggers([.bluetoothConnected, .bluetoothDisconnected]).isEmpty {
            bluetooth.onChange = { [weak self] name, connected in
                self?.namedEvent(connected ? .bluetoothConnected : .bluetoothDisconnected, name)
            }
            bluetooth.start()
        }
        let idle = triggers([.idle, .activeAgain])
        if !idle.isEmpty {
            idleTrackers = Dictionary(idle.map { ($0.1.id, IdleTracker(idleAfter: Double(max(1, $0.1.number)) * 60)) }, uniquingKeysWith: { a, _ in a })
            scheduleIdleCheck()
        }
    }

    /// Checks how long the Mac has been idle: every 30 seconds, and every 2 while idle (to notice it being used again quickly).
    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        let anyIdle = idleTrackers.values.contains { $0.isIdle }
        let timer = Timer(timeInterval: anyIdle ? 2 : 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdle(InputIdle.seconds)
                self?.scheduleIdleCheck()
            }
        }
        timer.tolerance = anyIdle ? 0.5 : 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func checkIdle(_ seconds: Double) {
        for (macro, trigger) in triggers([.idle, .activeAgain]) {
            guard var tracker = idleTrackers[trigger.id] else { continue }
            let change = tracker.update(secondsSinceInput: seconds)
            idleTrackers[trigger.id] = tracker
            if change == .becameIdle, trigger.kind == .idle { fire(macro) }
            if change == .activeAgain, trigger.kind == .activeAgain { fire(macro) }
        }
    }

    func powerChanged(onAC: Bool, percent: Int?) {
        let before = powerState
        powerState = (onAC, percent)
        if let before, before.onAC != onAC { simpleEvent(onAC ? .powerConnected : .powerDisconnected) }
        for (macro, trigger) in triggers([.batteryBelow]) {
            var check = batteryChecks[trigger.id] ?? BatteryThreshold(below: trigger.number)
            if check.update(percent: percent, onBattery: !onAC) { fire(macro, value: percent.map(String.init) ?? "") }
            batteryChecks[trigger.id] = check
        }
    }

    func namedEvent(_ kind: MacroTrigger.Kind, _ name: String) {
        for (macro, trigger) in triggers([kind]) where NameFilter.matches(name, trigger.text) {
            fire(macro, value: name)
        }
    }

    func appEvent(_ kind: MacroTrigger.Kind, bundleID: String?, name: String?) {
        for (macro, trigger) in triggers([kind]) where trigger.text.isEmpty || trigger.text == bundleID {
            fire(macro, value: name ?? bundleID ?? "", app: kind == .appActivated ? bundleID : nil)
        }
    }

    /// Something was copied. Copies made by a macro this started don't start it again (that would never end).
    func clipboardChanged(_ text: String) {
        guard clipboardRuns == 0 else { return }
        for (macro, trigger) in triggers([.clipboardChanged]) where trigger.text.isEmpty || text.localizedCaseInsensitiveContains(trigger.text) {
            let started = fire(macro, value: text) { [weak self] in
                // The last copy a macro makes is noticed up to half a second later: wait that out before listening again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { self?.clipboardRuns -= 1 } }
            }
            if started { clipboardRuns += 1 }
        }
    }

    func frontWindowChanged(_ change: WindowChangeTracker.Change, title: String) {
        let kind: MacroTrigger.Kind = change == .window ? .windowChanged : .windowTitleChanged
        for (macro, trigger) in triggers([kind]) where trigger.text.isEmpty || title.localizedCaseInsensitiveContains(trigger.text) {
            fire(macro, value: title)
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
        AnyView(Group {
            AutomationSettingsTab(store: store, web: self) { [weak self] in self?.open() }
            PanelSettings(store: panels.store, controller: panels)
        })
    }

    func willTerminate() {
        web.stop()
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
