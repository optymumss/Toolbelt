import AppKit
import Carbon
import SwiftUI

/// Something Toolbelt can do when a gesture or a macro's trigger happens.
/// Shared by Gestures and Automation, so every trigger can run every action.
struct MacroAction: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case toolbelt, openApp, open, pressKeys, typeText, system, shell, appleScript, javaScript

        var id: String { rawValue }

        var title: String {
            switch self {
            case .toolbelt: return "Toolbelt command"
            case .openApp: return "Open an app"
            case .open: return "Open a website or file"
            case .pressKeys: return "Press keys"
            case .typeText: return "Type text"
            case .system: return "Mac control"
            case .shell: return "Run a shell script"
            case .appleScript: return "Run an AppleScript"
            case .javaScript: return "Run a JavaScript (for Automation)"
            }
        }
    }

    var kind: Kind
    /// What it acts on: a command's name, an app's path, a web address, the text or script…
    var value: String = ""
    /// For pressKeys.
    var keyCode: Int = 0
    var modifiers: Int = 0

    static func toolbelt(_ action: ShortcutAction) -> MacroAction { MacroAction(kind: .toolbelt, value: action.rawValue) }
    static func system(_ command: SystemControl) -> MacroAction { MacroAction(kind: .system, value: command.rawValue) }

    /// In plain words, for lists.
    var summary: String {
        switch kind {
        case .toolbelt: return ShortcutAction.named(value)?.title.capitalizedFirst ?? "Toolbelt command"
        case .openApp: return "Open \(URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent)"
        case .open: return "Open \(value)"
        case .pressKeys: return "Press \(Shortcut(keyCode: keyCode, modifiers: modifiers).display)"
        case .typeText: return "Type “\(value.prefix(30))”"
        case .system: return SystemControl(rawValue: value)?.title ?? "Mac control"
        case .shell: return "Shell: \(value.split(separator: "\n").first ?? "")"
        case .appleScript: return "AppleScript"
        case .javaScript: return "JavaScript"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension ShortcutAction {
    static func named(_ rawValue: String) -> ShortcutAction? {
        allCases.first { $0.rawValue == rawValue }
    }
}

/// Controls for the Mac itself.
enum SystemControl: String, CaseIterable, Identifiable, Codable {
    case missionControl, appWindows, showDesktop, notificationCentre
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown, lockScreen, sleepDisplay, sleep, toggleDarkMode
    case closeWindow, quitApp, hideApp, fullScreen, newTab, closeTab, back, forward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows (App Exposé)"
        case .showDesktop: return "Show desktop"
        case .notificationCentre: return "Notification Centre"
        case .playPause: return "Play / pause"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute / unmute"
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .lockScreen: return "Lock screen"
        case .sleepDisplay: return "Turn the display off"
        case .sleep: return "Sleep"
        case .toggleDarkMode: return "Switch dark mode"
        case .closeWindow: return "Close window (⌘W)"
        case .quitApp: return "Quit app (⌘Q)"
        case .hideApp: return "Hide app (⌘H)"
        case .fullScreen: return "Full screen (⌃⌘F)"
        case .newTab: return "New tab (⌘T)"
        case .closeTab: return "Close tab (⌘W)"
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        }
    }
}

/// Runs actions. Every action that touches other apps checks for the permission it needs first.
@MainActor
final class ActionRunner {
    static var shared: ActionRunner?
    let shortcuts: ShortcutCenter

    init(shortcuts: ShortcutCenter) {
        self.shortcuts = shortcuts
    }

    func run(_ action: MacroAction) {
        switch action.kind {
        case .toolbelt:
            if let command = ShortcutAction.named(action.value) { shortcuts.perform(command) }
        case .openApp:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: action.value), configuration: NSWorkspace.OpenConfiguration())
        case .open:
            if let url = Self.url(from: action.value) { NSWorkspace.shared.open(url) }
        case .pressKeys:
            guard PermissionGate.ensure(.accessibility, to: "press keys for you") else { return }
            KeyPresser.press(keyCode: CGKeyCode(action.keyCode), flags: Self.flags(fromCarbon: action.modifiers))
        case .typeText:
            guard PermissionGate.ensure(.accessibility, to: "type text for you") else { return }
            TextInserter.paste(Placeholders.render(action.value))
        case .system:
            if let control = SystemControl(rawValue: action.value) { perform(control) }
        case .shell:
            Self.runScript("/bin/zsh", ["-c", action.value])
        case .appleScript:
            Self.runScript("/usr/bin/osascript", ["-e", action.value])
        case .javaScript:
            Self.runScript("/usr/bin/osascript", ["-l", "JavaScript", "-e", action.value])
        }
    }

    /// A web address (https:// added if missing) or a file path (~ allowed).
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://" + trimmed)
    }

    static func flags(fromCarbon modifiers: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.maskCommand) }
        if modifiers & optionKey != 0 { flags.insert(.maskAlternate) }
        if modifiers & controlKey != 0 { flags.insert(.maskControl) }
        if modifiers & shiftKey != 0 { flags.insert(.maskShift) }
        return flags
    }

    /// Scripts run in the background, so a slow one never holds up Toolbelt.
    /// Toolbelt's own data folder is passed in as TOOLBELT_DATA_DIR.
    @discardableResult
    static func runScript(_ tool: String, _ arguments: [String], environment extra: [String: String] = [:],
                          completion: (@Sendable (String) -> Void)? = nil) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TOOLBELT_DATA_DIR"] = SettingsStore.folder.path
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            completion?(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? process.run()
        return process
    }

    func perform(_ control: SystemControl) {
        switch control {
        case .missionControl: Self.missionControl(nil)
        case .appWindows: Self.missionControl("2")
        case .showDesktop: Self.missionControl("1")
        case .notificationCentre:
            SystemActions.appleScript(#"tell application "System Events" to click menu bar item "Clock" of menu bar 1 of application process "ControlCenter""#)
        case .playPause: MediaKeys.press(MediaKeys.play)
        case .nextTrack: MediaKeys.press(MediaKeys.next)
        case .previousTrack: MediaKeys.press(MediaKeys.previous)
        case .volumeUp: MediaKeys.press(MediaKeys.soundUp)
        case .volumeDown: MediaKeys.press(MediaKeys.soundDown)
        case .mute: MediaKeys.press(MediaKeys.mute)
        case .brightnessUp: MediaKeys.press(MediaKeys.brightnessUp)
        case .brightnessDown: MediaKeys.press(MediaKeys.brightnessDown)
        case .lockScreen: SystemActions.lockScreen()
        case .sleepDisplay: SystemActions.run("/usr/bin/pmset", ["displaysleepnow"])
        case .sleep: SystemActions.sleep()
        case .toggleDarkMode: SystemActions.toggleDarkMode()
        case .closeWindow, .closeTab: keys(kVK_ANSI_W, [.maskCommand])
        case .quitApp: keys(kVK_ANSI_Q, [.maskCommand])
        case .hideApp: keys(kVK_ANSI_H, [.maskCommand])
        case .fullScreen: keys(kVK_ANSI_F, [.maskCommand, .maskControl])
        case .newTab: keys(kVK_ANSI_T, [.maskCommand])
        case .back: keys(kVK_ANSI_LeftBracket, [.maskCommand])
        case .forward: keys(kVK_ANSI_RightBracket, [.maskCommand])
        }
    }

    private func keys(_ code: Int, _ flags: CGEventFlags) {
        guard PermissionGate.ensure(.accessibility, to: "press keys for you") else { return }
        KeyPresser.press(keyCode: CGKeyCode(code), flags: flags)
    }

    /// Mission Control's own app: no argument for Mission Control, "1" shows the desktop, "2" the app's windows.
    private static func missionControl(_ argument: String?) {
        SystemActions.run("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", argument.map { [$0] } ?? [])
    }
}

/// The keyboard's media and brightness keys, pressed the way the keyboard does.
enum MediaKeys {
    static let soundUp: Int32 = 0, soundDown: Int32 = 1, brightnessUp: Int32 = 2, brightnessDown: Int32 = 3
    static let mute: Int32 = 7, play: Int32 = 16, next: Int32 = 17, previous: Int32 = 18

    static func press(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Choosing an action in Settings

/// Lets you pick what an action does. Used by gesture rules and macros.
struct ActionEditor: View {
    @Binding var action: MacroAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Do", selection: $action.kind) {
                ForEach(MacroAction.Kind.allCases) { Text($0.title).tag($0) }
            }
            switch action.kind {
            case .toolbelt:
                Picker("Command", selection: $action.value) {
                    Text("Choose…").tag("")
                    ForEach(ShortcutAction.allCases, id: \.rawValue) { Text($0.title.capitalizedFirst).tag($0.rawValue) }
                }
            case .openApp:
                HStack {
                    Text(action.value.isEmpty ? "No app chosen" : URL(fileURLWithPath: action.value).deletingPathExtension().lastPathComponent)
                        .foregroundStyle(.secondary)
                    Button("Choose App…") {
                        if let url = Self.chooseApp() { action.value = url.path }
                    }
                }
            case .open:
                TextField("Web address or file path", text: $action.value)
            case .pressKeys:
                KeyCapture(keyCode: $action.keyCode, modifiers: $action.modifiers)
            case .typeText:
                TextField("Text (placeholders like {date} and {clipboard} work)", text: $action.value, axis: .vertical)
                    .lineLimit(2...5)
            case .system:
                Picker("Control", selection: $action.value) {
                    Text("Choose…").tag("")
                    ForEach(SystemControl.allCases) { Text($0.title).tag($0.rawValue) }
                }
            case .shell, .appleScript, .javaScript:
                TextEditor(text: $action.value)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 50, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        }
    }

    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Click, then press keys: records a key combination.
struct KeyCapture: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : (keyCode == 0 && modifiers == 0 ? "Click to record keys" : Shortcut(keyCode: keyCode, modifiers: modifiers).display)) {
            recording ? stop() : start()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let shortcut = Shortcut(event: event)
            keyCode = Int(shortcut.keyCode)
            modifiers = Int(shortcut.modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
