import AppKit
import ApplicationServices
import SwiftUI

// 0.39: move and resize windows with keys held, like BetterTouchTool's "window moving & resizing":
// hold the keys you chose (for example ⌃⌥) and just move the mouse — no click needed — and the window
// under the pointer follows. Hold the resize keys instead and its size follows the mouse (from its
// bottom-right corner). Uses macOS's mouse-moved and modifier events (no event tap), and only while a
// set of keys is chosen.

/// Which keys do what. Modifier flags are kept as their raw value (0 = off).
struct WindowDragKeys: Equatable {
    var move: UInt64 = 0
    var resize: UInt64 = 0
    var raise = true

    var isOff: Bool { move == 0 && resize == 0 }

    /// The modifier combinations offered in Settings.
    static let choices: [(name: String, flags: UInt64)] = {
        let control = WindowDragKeys.raw(.control), option = WindowDragKeys.raw(.option)
        let command = WindowDragKeys.raw(.command), shift = WindowDragKeys.raw(.shift)
        return [("Off", 0), ("⌃⌥", control | option), ("⌃⌘", control | command), ("⌥⌘", option | command),
                ("⌃⌥⌘", control | option | command), ("⌃⌥⇧", control | option | shift), ("⌃⇧", control | shift),
                ("⌥⇧", option | shift), ("⌃⌥⇧⌘ (Hyper key)", control | option | shift | command)]
    }()

    /// A modifier's flag as a 64-bit number (macOS gives NSEvent's as UInt).
    static func raw(_ flag: NSEvent.ModifierFlags) -> UInt64 { UInt64(flag.rawValue) }

    static func name(_ flags: UInt64) -> String { choices.first { $0.flags == flags }?.name ?? "Custom" }

    @MainActor static var saved: WindowDragKeys {
        get {
            let store = SettingsStore.shared
            return WindowDragKeys(move: UInt64(store.value("windows.dragMove", default: 0)),
                                  resize: UInt64(store.value("windows.dragResize", default: 0)),
                                  raise: store.value("windows.dragRaise", default: true))
        }
        set {
            let store = SettingsStore.shared
            store.set(Int(newValue.move), for: "windows.dragMove")
            store.set(Int(newValue.resize), for: "windows.dragResize")
            store.set(newValue.raise, for: "windows.dragRaise")
        }
    }

    enum Mode: Equatable { case move, resize }

    /// What the keys held right now do (exactly these keys: holding more or fewer does nothing).
    func mode(for flags: UInt64) -> Mode? {
        let relevant = flags & (Self.raw(.control) | Self.raw(.option) | Self.raw(.command) | Self.raw(.shift))
        guard relevant != 0 else { return nil }
        if relevant == move { return .move }
        if relevant == resize { return .resize }
        return nil
    }
}

/// Where the window goes as the mouse moves (top-left screen points). Pure.
enum WindowDragMath {
    static let minimumSize = CGSize(width: 120, height: 80)

    static func frame(start: CGRect, mouseStart: CGPoint, mouse: CGPoint, mode: WindowDragKeys.Mode) -> CGRect {
        let dx = mouse.x - mouseStart.x, dy = mouse.y - mouseStart.y
        switch mode {
        case .move:
            return CGRect(x: start.minX + dx, y: start.minY + dy, width: start.width, height: start.height)
        case .resize:
            return CGRect(x: start.minX, y: start.minY, width: max(minimumSize.width, start.width + dx),
                          height: max(minimumSize.height, start.height + dy))
        }
    }
}

@MainActor
final class WindowDragger {
    static let shared = WindowDragger()

    private(set) var keys = WindowDragKeys()
    private var monitors: [Any] = []
    private var running = false
    /// The window being moved, where it and the mouse started, and how.
    private var current: (window: AXWindow, start: CGRect, mouse: CGPoint, mode: WindowDragKeys.Mode)?
    private var lastFlags: UInt64 = 0
    /// Times a window was moved or resized (for the real-use test).
    private(set) var moves = 0

    var isWatching: Bool { !monitors.isEmpty }

    func refresh() { update(running: running) }

    func update(running: Bool) {
        self.running = running
        keys = WindowDragKeys.saved
        let wants = running && !keys.isOff
        if wants, monitors.isEmpty {
            guard PermissionGate.ensure(.accessibility, to: "move windows while you hold keys") else { return }
            if let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.flagsChanged(UInt64(event.modifierFlags.rawValue)) }
            }) { monitors.append(flags) }
            if let moved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }) { monitors.append(moved) }
        } else if !wants {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            current = nil
        }
        RealUseHooks.writeStatus()
    }

    static func registerTestHooks() {
        // "move,resize" as raw modifier flags, e.g. "786432,917504".
        RealUseHooks.commands["window-drag"] = { text in
            let parts = text.split(separator: ",").compactMap { UInt64($0) }
            guard parts.count == 2 else { return }
            var keys = WindowDragKeys.saved
            keys.move = parts[0]
            keys.resize = parts[1]
            WindowDragKeys.saved = keys
            shared.refresh()
        }
        RealUseHooks.extraStatus["windowDrag"] = { shared.isWatching ? "on" : "off" }
        RealUseHooks.extraStatus["windowDragMoves"] = { shared.moves }
    }

    /// The pointer in top-left screen points.
    private static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func flagsChanged(_ flags: UInt64) {
        lastFlags = flags
        guard let mode = keys.mode(for: flags) else {
            current = nil
            return
        }
        // Holding the same keys again keeps going; switching between move and resize starts afresh.
        if let current, current.mode == mode { return }
        begin(mode)
    }

    private func begin(_ mode: WindowDragKeys.Mode) {
        let mouse = Self.pointer
        guard let window = AXWindow.at(mouse), window.isStandardWindow, let frame = window.frame else {
            current = nil
            return
        }
        if keys.raise { AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) }
        current = (window, frame, mouse, mode)
    }

    private func mouseMoved() {
        guard let drag = current else {
            // Keys held before the pointer reached a window: start once it's over one.
            if let mode = keys.mode(for: lastFlags) { begin(mode) }
            return
        }
        let frame = WindowDragMath.frame(start: drag.start, mouseStart: drag.mouse, mouse: Self.pointer, mode: drag.mode)
        switch drag.mode {
        case .move: Self.set(drag.window, kAXPositionAttribute, frame.origin)
        case .resize: Self.set(drag.window, kAXSizeAttribute, frame.size)
        }
        moves += 1
        if moves % 10 == 1 { RealUseHooks.writeStatus() }
    }

    private static func set(_ window: AXWindow, _ attribute: String, _ point: CGPoint) {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(window.element, attribute as CFString, axValue)
    }

    private static func set(_ window: AXWindow, _ attribute: String, _ size: CGSize) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(window.element, attribute as CFString, axValue)
    }
}

// MARK: - Settings

struct WindowDragSettings: View {
    @State private var keys = WindowDragKeys.saved

    var body: some View {
        Section {
            Picker("Move the window under the pointer while holding", selection: $keys.move) {
                ForEach(WindowDragKeys.choices, id: \.flags) { Text($0.name).tag($0.flags) }
            }
            Picker("Resize it while holding", selection: $keys.resize) {
                ForEach(WindowDragKeys.choices, id: \.flags) { Text($0.name).tag($0.flags) }
            }
            Toggle("Bring the window to the front", isOn: $keys.raise)
            if keys.move != 0, keys.move == keys.resize {
                Label("Pick different keys for moving and resizing.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Move and resize with keys held")
        } footer: {
            Text("Hold the keys and simply move the mouse (no click needed): the window under the pointer follows. Resizing moves its bottom-right corner. Exactly those keys must be held, so a shortcut using more keys isn't affected. Needs Accessibility.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: keys) { _, value in
            WindowDragKeys.saved = value
            WindowDragger.shared.refresh()
        }
    }
}
