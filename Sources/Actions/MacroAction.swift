import AppKit
import Carbon
import CoreAudio
import SwiftUI

/// Something Toolbelt can do when a gesture or a macro's trigger happens.
/// Shared by Gestures and Automation, so every trigger can run every action.
struct MacroAction: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case toolbelt, openApp, open, pressKeys, typeText, system, menuItem, resolution, audioOutput
        case setClipboard, pasteNamed, macro, shell, appleScript, javaScript

        var id: String { rawValue }

        var title: String {
            switch self {
            case .toolbelt: return "Toolbelt command"
            case .openApp: return "Open an app"
            case .open: return "Open a website or file"
            case .pressKeys: return "Press keys"
            case .typeText: return "Type text"
            case .system: return "Mac control"
            case .menuItem: return "Choose a menu item"
            case .resolution: return "Change screen resolution"
            case .audioOutput: return "Switch sound output"
            case .setClipboard: return "Set the clipboard"
            case .pasteNamed: return "Paste a named clipboard"
            case .macro: return "Run a macro"
            case .shell: return "Run a shell script"
            case .appleScript: return "Run an AppleScript"
            case .javaScript: return "Run a JavaScript"
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
        case .menuItem: return "Choose \(value)"
        case .resolution: return "Resolution \(value)"
        case .audioOutput: return "Sound to \(value)"
        case .setClipboard: return "Clipboard = \(value.prefix(30))"
        case .pasteNamed: return "Paste named clipboard “\(value)”"
        case .macro: return "Run macro “\(value)”"
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
    case muteMicrophone, spotlight, launchpad, siri, keyboardBrightnessUp, keyboardBrightnessDown

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
        case .muteMicrophone: return "Mute / unmute the microphone"
        case .spotlight: return "Spotlight search"
        case .launchpad: return "Launchpad / Apps"
        case .siri: return "Siri"
        case .keyboardBrightnessUp: return "Keyboard light up"
        case .keyboardBrightnessDown: return "Keyboard light down"
        }
    }
}

/// Runs actions. Every action that touches other apps checks for the permission it needs first.
@MainActor
final class ActionRunner {
    let shortcuts: ShortcutCenter
    /// Set by the modules that own these things.
    static var pasteNamedClipboard: ((String) -> Void)?
    static var runMacro: ((String) -> Void)?

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
        case .menuItem:
            MenuClicker.click(action.value)
        case .resolution:
            DisplayModes.set(action.value)
        case .audioOutput:
            AudioOutputs.setDefault(action.value)
        case .setClipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Placeholders.render(action.value).text, forType: .string)
        case .pasteNamed:
            Self.pasteNamedClipboard?(action.value)
        case .macro:
            Self.runMacro?(action.value)
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
        case .muteMicrophone: Microphone.toggleMute()
        case .spotlight: keys(kVK_Space, [.maskCommand])
        case .launchpad:
            // macOS 26 replaced Launchpad with the Apps view; older versions still have Launchpad.
            let apps = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
            if let path = apps.first(where: FileManager.default.fileExists) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            }
        case .siri:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Siri.app"), configuration: NSWorkspace.OpenConfiguration())
        case .keyboardBrightnessUp: KeyboardLight.change(by: 1.0 / 16)
        case .keyboardBrightnessDown: KeyboardLight.change(by: -1.0 / 16)
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

/// The default microphone's mute switch (Core Audio). Microphones without one are turned right down instead.
enum Microphone {
    private static var savedVolume: Float32 = 0.75

    private static func defaultInput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Whether the microphone is muted now (nil if there's no microphone).
    static var isMuted: Bool? {
        guard let id = defaultInput() else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(id, &address), AudioObjectGetPropertyData(id, &address, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return volume(of: id).map { $0 < 0.01 }
    }

    @discardableResult
    static func toggleMute() -> Bool {
        guard let id = defaultInput(), let muted = isMuted else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &address), AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue {
            var value: UInt32 = muted ? 0 : 1
            return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        }
        // No mute switch: turn the input volume to nothing, and back to where it was.
        if !muted, let current = volume(of: id) { savedVolume = max(current, 0.1) }
        return setVolume(muted ? savedVolume : 0, of: id)
    }

    private static func volume(of id: AudioObjectID) -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(id, &address), AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setVolume(_ volume: Float32, of id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = volume
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}

/// The keyboard's backlight, through macOS's own brightness service (the one Control Centre uses).
enum KeyboardLight {
    private typealias Getter = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Setter = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let client: NSObject? = {
        guard Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return type.init()
    }()

    /// The keyboards that have a light (the built-in one, and Magic Keyboards that do).
    static var keyboards: [UInt64] {
        guard let client, client.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")),
              let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else { return [] }
        return ids.map(\.uint64Value)
    }

    /// The light's level from 0 to 1, or nil if there's no keyboard light.
    static var level: Float? {
        guard let client, let keyboard = keyboards.first else { return nil }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: selector) else { return nil }
        let get = unsafeBitCast(client.method(for: selector), to: Getter.self)
        return get(client, selector, keyboard)
    }

    static func change(by delta: Float) {
        let get = NSSelectorFromString("brightnessForKeyboard:"), set = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, client.responds(to: get), client.responds(to: set), !keyboards.isEmpty else {
            MediaKeys.press(delta > 0 ? MediaKeys.illuminationUp : MediaKeys.illuminationDown) // older Macs
            return
        }
        let read = unsafeBitCast(client.method(for: get), to: Getter.self)
        let write = unsafeBitCast(client.method(for: set), to: Setter.self)
        for keyboard in keyboards {
            _ = write(client, set, min(1, max(0, read(client, get, keyboard) + delta)), keyboard)
        }
    }
}

/// The keyboard's media and brightness keys, pressed the way the keyboard does.
enum MediaKeys {
    static let soundUp: Int32 = 0, soundDown: Int32 = 1, brightnessUp: Int32 = 2, brightnessDown: Int32 = 3
    static let mute: Int32 = 7, play: Int32 = 16, next: Int32 = 17, previous: Int32 = 18
    static let illuminationUp: Int32 = 21, illuminationDown: Int32 = 22

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
            case .menuItem:
                TextField("Menu path, e.g. File > Export as PDF", text: $action.value)
            case .resolution:
                Picker("Size", selection: $action.value) {
                    Text("Choose…").tag("")
                    ForEach(Self.resolutions, id: \.self) { Text($0).tag($0) }
                }
            case .audioOutput:
                Picker("Device", selection: $action.value) {
                    Text("Choose…").tag("")
                    ForEach(AudioOutputs.all().map(\.name), id: \.self) { Text($0).tag($0) }
                }
            case .setClipboard:
                TextField("Text (placeholders like {date} work)", text: $action.value)
            case .pasteNamed:
                TextField("Named clipboard", text: $action.value)
            case .macro:
                TextField("Macro name", text: $action.value)
            case .shell, .appleScript, .javaScript:
                TextEditor(text: $action.value)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 50, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        }
    }

    static var resolutions: [String] {
        var seen: [String] = []
        for mode in DisplayModes.available() {
            let text = "\(mode.width) × \(mode.height)"
            if !seen.contains(text) { seen.append(text) }
        }
        return seen
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
