import AppKit
import Carbon

// MARK: - Shortcut

/// A key plus modifier keys, stored the way the Carbon hot key API wants them.
struct Shortcut: Hashable {
    var keyCode: UInt32
    /// Carbon modifier flags: cmdKey, optionKey, controlKey, shiftKey.
    var modifiers: UInt32

    private static let command = UInt32(cmdKey)
    private static let option = UInt32(optionKey)
    private static let control = UInt32(controlKey)
    private static let shift = UInt32(shiftKey)

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= Self.command }
        if flags.contains(.option) { mods |= Self.option }
        if flags.contains(.control) { mods |= Self.control }
        if flags.contains(.shift) { mods |= Self.shift }
        keyCode = UInt32(event.keyCode)
        modifiers = mods
    }

    init?(plist: [String: Int]) {
        guard let key = plist["keyCode"], let mods = plist["modifiers"] else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }

    var plist: [String: Int] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers)]
    }

    /// Global shortcuts need ⌘, ⌥ or ⌃ so they don't swallow normal typing.
    /// Function keys (F1–F20) are fine on their own.
    var isUsable: Bool {
        modifiers & (Self.command | Self.option | Self.control) != 0 || KeyNames.isFunctionKey(keyCode)
    }

    /// For example "⌘⇧V".
    var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    /// Lets a menu item show this shortcut next to its title.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let key = KeyNames.menuKey(for: keyCode) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & Self.command != 0 { flags.insert(.command) }
        if modifiers & Self.option != 0 { flags.insert(.option) }
        if modifiers & Self.control != 0 { flags.insert(.control) }
        if modifiers & Self.shift != 0 { flags.insert(.shift) }
        return (key, flags)
    }
}

// MARK: - Actions that can have a shortcut

/// Every global shortcut in Toolbelt. Each module adds its own here.
enum ShortcutAction: Hashable, CaseIterable, Identifiable {
    case clipboardHistory
    case pasteNextFromStack
    case openLauncher
    case appSwitcher
    case newNote
    case window(WindowAction)
    /// Puts saved layout 1–9 back.
    case layout(Int)
    case newShelf
    case snippetPicker

    static var allCases: [ShortcutAction] {
        [.clipboardHistory, .pasteNextFromStack, .openLauncher, .appSwitcher, .newNote] + WindowAction.allCases.map { .window($0) } + (1...9).map { .layout($0) } + [.newShelf, .snippetPicker]
    }

    /// Stable name used to save the shortcut.
    var rawValue: String {
        switch self {
        case .clipboardHistory: return "clipboardHistory"
        case .pasteNextFromStack: return "pasteNextFromStack"
        case .openLauncher: return "openLauncher"
        case .appSwitcher: return "appSwitcher"
        case .newNote: return "newNote"
        case .window(let action): return "window.\(action.rawValue)"
        case .layout(let n): return "layout.\(n)"
        case .newShelf: return "newShelf"
        case .snippetPicker: return "snippetPicker"
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboardHistory: return "Open clipboard history"
        case .pasteNextFromStack: return "Paste next from paste stack"
        case .openLauncher: return "Open launcher"
        case .appSwitcher: return "Switch apps and windows"
        case .newNote: return "New floating note"
        case .window(let action): return action.title
        case .layout(let n): return "Apply saved layout \(n)"
        case .newShelf: return "New shelf"
        case .snippetPicker: return "Find and insert a snippet"
        }
    }

    var module: ModuleID {
        switch self {
        case .clipboardHistory, .pasteNextFromStack: return .clipboard
        case .openLauncher, .appSwitcher, .newNote: return .launcher
        case .window, .layout: return .windows
        case .newShelf: return .shelf
        case .snippetPicker: return .snippets
        }
    }

    var defaultShortcut: Shortcut? {
        let ctrlOpt = controlKey | optionKey
        switch self {
        case .clipboardHistory: return Shortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)
        case .pasteNextFromStack: return Shortcut(keyCode: kVK_ANSI_V, modifiers: ctrlOpt)
        case .openLauncher: return Shortcut(keyCode: kVK_Space, modifiers: optionKey)
        case .appSwitcher: return Shortcut(keyCode: kVK_Tab, modifiers: optionKey)
        case .newNote: return Shortcut(keyCode: kVK_ANSI_N, modifiers: ctrlOpt)
        case .newShelf: return Shortcut(keyCode: kVK_ANSI_S, modifiers: ctrlOpt)
        case .snippetPicker: return Shortcut(keyCode: kVK_ANSI_Semicolon, modifiers: ctrlOpt)
        case .layout(let n):
            return Shortcut(keyCode: [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9][n - 1], modifiers: ctrlOpt | cmdKey)
        case .window(let action):
            switch action {
            case .leftHalf: return Shortcut(keyCode: kVK_LeftArrow, modifiers: ctrlOpt)
            case .rightHalf: return Shortcut(keyCode: kVK_RightArrow, modifiers: ctrlOpt)
            case .topHalf: return Shortcut(keyCode: kVK_UpArrow, modifiers: ctrlOpt)
            case .bottomHalf: return Shortcut(keyCode: kVK_DownArrow, modifiers: ctrlOpt)
            case .topLeft: return Shortcut(keyCode: kVK_ANSI_U, modifiers: ctrlOpt)
            case .topRight: return Shortcut(keyCode: kVK_ANSI_I, modifiers: ctrlOpt)
            case .bottomLeft: return Shortcut(keyCode: kVK_ANSI_J, modifiers: ctrlOpt)
            case .bottomRight: return Shortcut(keyCode: kVK_ANSI_K, modifiers: ctrlOpt)
            case .firstThird: return Shortcut(keyCode: kVK_ANSI_D, modifiers: ctrlOpt)
            case .centerThird: return Shortcut(keyCode: kVK_ANSI_F, modifiers: ctrlOpt)
            case .lastThird: return Shortcut(keyCode: kVK_ANSI_G, modifiers: ctrlOpt)
            case .firstTwoThirds: return Shortcut(keyCode: kVK_ANSI_E, modifiers: ctrlOpt)
            case .lastTwoThirds: return Shortcut(keyCode: kVK_ANSI_T, modifiers: ctrlOpt)
            case .maximize: return Shortcut(keyCode: kVK_Return, modifiers: ctrlOpt)
            case .center: return Shortcut(keyCode: kVK_ANSI_C, modifiers: ctrlOpt)
            case .restore: return Shortcut(keyCode: kVK_Delete, modifiers: ctrlOpt)
            case .nextDisplay: return Shortcut(keyCode: kVK_RightArrow, modifiers: ctrlOpt | cmdKey)
            case .previousDisplay: return Shortcut(keyCode: kVK_LeftArrow, modifiers: ctrlOpt | cmdKey)
            }
        }
    }

    fileprivate var settingsKey: String { "shortcut.\(rawValue)" }
}

// MARK: - Shortcut center

/// Owns every global shortcut: which keys each action uses,
/// registering them with macOS, and spotting clashes.
@MainActor
final class ShortcutCenter: ObservableObject {
    /// Actions whose shortcut couldn't be registered because something else has it.
    @Published private(set) var failed: Set<ShortcutAction> = []

    private var handlers: [ShortcutAction: () -> Void] = [:]
    private var hotKeys: [ShortcutAction: HotKey] = [:]
    private var active: Set<ShortcutAction> = []
    private var suspended = false

    /// The shortcut an action uses now, or nil if the user removed it.
    func shortcut(for action: ShortcutAction) -> Shortcut? {
        if let stored = SettingsStore.shared.raw(action.settingsKey) as? [String: Int] {
            return Shortcut(plist: stored) // an empty dictionary means "no shortcut"
        }
        return action.defaultShortcut
    }

    func setHandler(for action: ShortcutAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// Registers the shortcuts of running modules and drops the rest.
    func setActive(_ actions: Set<ShortcutAction>) {
        active = actions
        reregister()
    }

    /// Turns all shortcuts off while the user records a new one,
    /// so pressing an existing shortcut doesn't trigger it.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        reregister()
    }

    /// Saves a new shortcut for an action (nil removes it).
    /// Returns a message explaining the problem if the keys are already taken.
    func assign(_ shortcut: Shortcut?, to action: ShortcutAction) -> String? {
        let wasSuspended = suspended
        suspend()
        defer { if !wasSuspended { resume() } }

        if let shortcut, let problem = conflict(for: shortcut, action: action) {
            return problem
        }
        objectWillChange.send()
        SettingsStore.shared.set(shortcut?.plist ?? [String: Int](), for: action.settingsKey)
        return nil
    }

    func resetToDefault(_ action: ShortcutAction) -> String? {
        let wasSuspended = suspended
        suspend()
        defer { if !wasSuspended { resume() } }

        if let shortcut = action.defaultShortcut, let problem = conflict(for: shortcut, action: action) {
            return problem
        }
        objectWillChange.send()
        SettingsStore.shared.set(nil, for: action.settingsKey)
        return nil
    }

    /// Checks Toolbelt's other shortcuts, macOS's own shortcuts, and other apps.
    /// Call only while suspended, so Toolbelt's own registrations don't get in the way.
    private func conflict(for shortcut: Shortcut, action: ShortcutAction) -> String? {
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
            return "Toolbelt already uses \(shortcut.display) for “\(other.title)”."
        }
        if SystemShortcuts.contains(shortcut) {
            return "macOS already uses \(shortcut.display). Pick another, or turn it off in System Settings › Keyboard › Keyboard Shortcuts."
        }
        // Another app holding the same keys makes registration fail.
        let probe = HotKey(shortcut: shortcut) {}
        defer { probe.unregister() }
        if !probe.isRegistered {
            return "Another app already uses \(shortcut.display). Pick a different shortcut."
        }
        return nil
    }

    private func unregisterAll() {
        for hotKey in hotKeys.values { hotKey.unregister() }
        hotKeys = [:]
    }

    private func reregister() {
        unregisterAll()
        guard !suspended else { return }

        var newFailed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases where active.contains(action) {
            guard let shortcut = shortcut(for: action) else { continue }
            let hotKey = HotKey(shortcut: shortcut) { [weak self] in
                self?.handlers[action]?()
            }
            if hotKey.isRegistered {
                hotKeys[action] = hotKey
            } else {
                newFailed.insert(action)
            }
        }
        if newFailed != failed { failed = newFailed }
    }
}

// MARK: - macOS's own shortcuts

enum SystemShortcuts {
    /// True if the shortcut is one of macOS's enabled keyboard shortcuts
    /// (Spotlight, screenshots, Mission Control and so on).
    static func contains(_ shortcut: Shortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }

        let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        for entry in list {
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let mods = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { continue }
            if code == shortcut.keyCode, mods & relevant == shortcut.modifiers & relevant {
                return true
            }
        }
        return false
    }
}

// MARK: - Key names

enum KeyNames {
    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func name(for keyCode: UInt32) -> String {
        names[Int(keyCode)] ?? "Key \(keyCode)"
    }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys.contains(Int(keyCode))
    }

    /// Single characters can be shown in menus; named keys can't.
    static func menuKey(for keyCode: UInt32) -> String? {
        guard let name = names[Int(keyCode)], name.count == 1 else { return nil }
        return name.lowercased()
    }
}

// MARK: - Global hot key

/// A system-wide shortcut (works in every app) using the Carbon hot key API,
/// which needs no special permission.
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    var isRegistered: Bool { ref != nil }

    init(shortcut: Shortcut, handler: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.installHandlerIfNeeded()
        HotKey.handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x54424C54), id: id) // 'TBLT'
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        if status == noErr {
            ref = newRef
        } else {
            HotKey.handlers[id] = nil
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.handlers[id] = nil
    }

    fileprivate static func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

/// Called by macOS whenever one of our shortcuts is pressed.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if status == noErr {
        let id = hotKeyID.id
        DispatchQueue.main.async {
            MainActor.assumeIsolated { HotKey.fire(id) }
        }
    }
    return noErr
}
