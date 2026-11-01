import AppKit
import SwiftUI

// Changing what keys do, like BetterTouchTool's and Karabiner's key remapping:
// - the Hyper key: Caps Lock becomes ⌃⌥⇧⌘ all at once (a set of shortcuts no app uses), and on its
//   own can type Escape;
// - one key into another (for example § into Esc, or Right ⌥ into Right ⌘).
// Both use macOS's own key remapping (hidutil's UserKeyMapping), which works in every app, needs no
// permission, and is undone when Toolbelt quits (and by restarting the Mac). For the Hyper key, Caps
// Lock is remapped to F18, which an event tap turns into the four modifier keys.

/// A key as macOS's keyboard driver numbers it (USB HID usage page 7).
struct HIDKey: Identifiable, Hashable {
    let usage: Int
    let name: String
    var id: Int { usage }
}

enum HIDKeys {
    static let capsLock = 0x39
    static let f18 = 0x6D
    /// F18's macOS key code (what the event tap sees).
    static let f18KeyCode: Int64 = 79

    static let all: [HIDKey] = {
        var keys: [HIDKey] = []
        for (index, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { keys.append(HIDKey(usage: 0x04 + index, name: String(letter))) }
        for (index, digit) in "1234567890".enumerated() { keys.append(HIDKey(usage: 0x1E + index, name: String(digit))) }
        let named: [(Int, String)] = [
            (0x28, "Return"), (0x29, "Esc"), (0x2A, "Delete (backspace)"), (0x2B, "Tab"), (0x2C, "Space"),
            (0x2D, "- (minus)"), (0x2E, "= (equals)"), (0x2F, "["), (0x30, "]"), (0x31, "\\"), (0x33, ";"), (0x34, "'"),
            (0x35, "` (backtick)"), (0x36, ","), (0x37, "."), (0x38, "/"), (0x64, "§ (next to 1, or next to left ⇧)"),
            (0x39, "Caps Lock"), (0x4C, "Forward Delete"), (0x4A, "Home"), (0x4D, "End"), (0x4B, "Page Up"), (0x4E, "Page Down"),
            (0x4F, "→"), (0x50, "←"), (0x51, "↓"), (0x52, "↑"),
            (0xE0, "Left ⌃ Control"), (0xE1, "Left ⇧ Shift"), (0xE2, "Left ⌥ Option"), (0xE3, "Left ⌘ Command"),
            (0xE4, "Right ⌃ Control"), (0xE5, "Right ⇧ Shift"), (0xE6, "Right ⌥ Option"), (0xE7, "Right ⌘ Command"),
        ]
        keys += named.map { HIDKey(usage: $0.0, name: $0.1) }
        for n in 1...12 { keys.append(HIDKey(usage: 0x3A + n - 1, name: "F\(n)")) }
        for n in 13...20 { keys.append(HIDKey(usage: 0x68 + n - 13, name: "F\(n)")) }
        return keys
    }()

    static func name(_ usage: Int) -> String { all.first { $0.usage == usage }?.name ?? String(format: "Key 0x%02X", usage) }
}

struct KeyRemap: Codable, Equatable, Identifiable {
    var id = UUID()
    var from: Int
    var to: Int
}

enum KeyMapping {
    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    /// The UserKeyMapping list for these settings: one entry per key (the first change of a key wins), with
    /// Caps Lock going to F18 for the Hyper key.
    static func userKeyMapping(remaps: [KeyRemap], hyper: Bool) -> [[String: Int]] {
        var seen = Set<Int>()
        var list: [[String: Int]] = []
        func add(_ from: Int, _ to: Int) {
            guard from != to, seen.insert(from).inserted else { return }
            list.append([srcKey: 0x7_0000_0000 | from, dstKey: 0x7_0000_0000 | to])
        }
        if hyper { add(HIDKeys.capsLock, HIDKeys.f18) }
        for remap in remaps { add(remap.from, remap.to) }
        return list
    }

    /// What hidutil is given: {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":…,"HIDKeyboardModifierMappingDst":…}]}
    static func json(_ mapping: [[String: Int]]) -> String {
        let entries = mapping.map { "{\"\(srcKey)\":\($0[srcKey] ?? 0),\"\(dstKey)\":\($0[dstKey] ?? 0)}" }
        return "{\"UserKeyMapping\":[" + entries.joined(separator: ",") + "]}"
    }
}

/// Applies the key changes and runs the Hyper key.
@MainActor
final class KeyRemapper {
    static let shared = KeyRemapper()

    private var tap: (port: CFMachPort, source: CFRunLoopSource)?
    fileprivate var hyperDown = false
    fileprivate var hyperUsed = false
    private(set) var applied: [[String: Int]] = []
    private var running = false

    /// After a setting changed.
    func refresh() { update(running: running) }

    /// Sets macOS's key mapping to match the settings (when `running`), or takes Toolbelt's changes away.
    func update(running: Bool) {
        self.running = running
        let mapping = running ? KeyMapping.userKeyMapping(remaps: Prefs.keyRemaps, hyper: Prefs.hyperKey) : []
        // Only touch macOS's mapping if Toolbelt set it, or wants to now (so someone's own hidutil setup is left alone).
        if mapping != applied || (mapping.isEmpty && Prefs.keyMappingApplied) {
            Self.hidutil(KeyMapping.json(mapping))
            applied = mapping
            Prefs.keyMappingApplied = !mapping.isEmpty
        }
        let wantsTap = running && Prefs.hyperKey
        if wantsTap, tap == nil {
            guard PermissionGate.ensure(.accessibility, to: "turn Caps Lock into the Hyper key") else { return }
            tap = makeTap()
        } else if !wantsTap, let current = tap {
            CGEvent.tapEnable(tap: current.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), current.source, .commonModes)
            tap = nil
            hyperDown = false
        }
    }

    var isHyperRunning: Bool { tap != nil }

    static func hidutil(_ json: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Toolbelt: could not change the key mapping: \(error)")
        }
    }

    private func makeTap() -> (port: CFMachPort, source: CFRunLoopSource)? {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: hyperCallback, userInfo: me),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, source)
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap.port, enable: true) }
    }

    static let hyperFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Returns the event to pass on (nil to keep it from apps).
    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == .keyDown || type == .keyUp else { return event }
        if event.getIntegerValueField(.eventSourceUserData) == GestureEventTap.ownEventMarker { return event }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == HIDKeys.f18KeyCode {
            if type == .keyDown {
                if !hyperDown { hyperUsed = false }
                hyperDown = true
            } else {
                hyperDown = false
                if !hyperUsed, Prefs.hyperEscape { Self.pressEscape() }
            }
            return nil
        }
        guard hyperDown else { return event }
        hyperUsed = true
        event.flags.formUnion(Self.hyperFlags)
        return event
    }

    private static func pressEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: GestureEventTap.ownEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

private func hyperCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let remapper = Unmanaged<KeyRemapper>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            remapper.reenable()
            return Unmanaged.passUnretained(event)
        }
        return remapper.process(type, event).map { Unmanaged.passUnretained($0) }
    }
}

// MARK: - Settings

struct KeyRemapSettings: View {
    @State private var hyper = Prefs.hyperKey
    @State private var escape = Prefs.hyperEscape
    @State private var remaps = Prefs.keyRemaps
    var changed: () -> Void = { KeyRemapper.shared.refresh() }

    var body: some View {
        Section {
            Toggle("Caps Lock is the Hyper key (⌃⌥⇧⌘)", isOn: $hyper)
                .onChange(of: hyper) { _, value in Prefs.hyperKey = value; changed() }
            Toggle("Caps Lock on its own types Esc", isOn: $escape)
                .disabled(!hyper)
                .onChange(of: escape) { _, value in Prefs.hyperEscape = value }
            ForEach($remaps) { $remap in
                HStack {
                    Picker("Key", selection: $remap.from) { ForEach(HIDKeys.all) { Text($0.name).tag($0.usage) } }
                    Image(systemName: "arrow.right")
                    Picker("becomes", selection: $remap.to) { ForEach(HIDKeys.all) { Text($0.name).tag($0.usage) } }
                    Button { remaps.removeAll { $0.id == remap.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            .onChange(of: remaps) { _, value in Prefs.keyRemaps = value; changed() }
            Button("Change a Key") { remaps.append(KeyRemap(from: 0x64, to: 0x29)) }
        } header: {
            Text("Keys")
        } footer: {
            Text("The Hyper key gives you a set of shortcuts no app uses: record a shortcut while holding Caps Lock. Changed keys work in every app, on every keyboard. Toolbelt puts the keys back when it quits; restarting the Mac does too. The Hyper key needs Accessibility.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
