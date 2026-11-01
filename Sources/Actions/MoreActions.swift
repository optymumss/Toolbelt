import AppKit
import Carbon
import CoreWLAN
import SwiftUI
import UniformTypeIdentifiers

// More actions, like BetterTouchTool's: using the mouse, searching the web for the selected text,
// and controls for Bluetooth, Wi-Fi, the Dock, the Trash, disks, the screen saver and emoji.

// MARK: - Mouse

/// A mouse action, saved as text in MacroAction.value: "click", "rightClick 300,200",
/// "scrollDown 5", "drag 100,100 400,300". Places are screen points from the top left of the main
/// display (where macOS's mouse events count from); no place means where the pointer is.
struct MouseCommand: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case click, doubleClick, rightClick, middleClick, moveTo, scrollUp, scrollDown, scrollLeft, scrollRight, drag

        var id: String { rawValue }

        var title: String {
            switch self {
            case .click: return "Click"
            case .doubleClick: return "Double-click"
            case .rightClick: return "Right-click"
            case .middleClick: return "Middle-click"
            case .moveTo: return "Move the pointer"
            case .scrollUp: return "Scroll up"
            case .scrollDown: return "Scroll down"
            case .scrollLeft: return "Scroll left"
            case .scrollRight: return "Scroll right"
            case .drag: return "Drag"
            }
        }

        var isScroll: Bool { rawValue.hasPrefix("scroll") }
    }

    /// Where `at` counts from: the main screen's top left, the front window's top left, or a picture
    /// found on screen (its middle, moved by `at` if given).
    enum Origin: String { case screen, window, image }

    var kind: Kind = .click
    var origin: Origin = .screen
    /// For `.image`: the picture's file.
    var image: String?
    /// Where to do it; nil is where the pointer is.
    var at: CGPoint?
    /// Drag: where to let go.
    var to: CGPoint?
    /// Scrolls: how many lines.
    var lines = 5

    init(kind: Kind = .click, at: CGPoint? = nil, to: CGPoint? = nil, lines: Int = 5) {
        self.kind = kind
        self.at = at
        self.to = to
        self.lines = lines
    }

    init(text: String) {
        var text = text
        // "click image /path/with spaces.png": the rest of the text is the picture's path.
        if let range = text.range(of: " image ") {
            image = String(text[range.upperBound...])
            origin = .image
            text = String(text[..<range.lowerBound])
        }
        let parts = text.split(separator: " ").map(String.init)
        if parts.contains("window") { origin = .window }
        kind = parts.first.flatMap(Kind.init(rawValue:)) ?? .click
        var points: [CGPoint] = []
        for part in parts.dropFirst() {
            let numbers = part.split(separator: ",").compactMap { Double($0) }
            if numbers.count == 2 {
                points.append(CGPoint(x: numbers[0], y: numbers[1]))
            } else if let count = Int(part) {
                lines = max(1, min(100, count))
            }
        }
        at = points.first
        to = points.count > 1 ? points[1] : nil
    }

    var text: String {
        func place(_ point: CGPoint) -> String { "\(Int(point.x.rounded())),\(Int(point.y.rounded()))" }
        var parts = [kind.rawValue]
        if origin == .window { parts.append("window") }
        if let at { parts.append(place(at)) }
        if kind == .drag, let to { parts.append(place(to)) }
        if kind.isScroll { parts.append(String(lines)) }
        if origin == .image, let image { parts.append("image " + image) }
        return parts.joined(separator: " ")
    }

    var summary: String {
        func place(_ point: CGPoint) -> String { "\(Int(point.x)), \(Int(point.y))" }
        if origin == .image {
            return kind.title + " on the picture \(((image ?? "") as NSString).lastPathComponent)"
        }
        let corner = origin == .window ? " from the front window's corner" : ""
        let whereText = at.map { " at \(place($0))\(corner)" } ?? (kind == .moveTo ? "" : " where the pointer is")
        switch kind {
        case .drag: return "Drag" + (at.map { " from \(place($0))" } ?? "") + (to.map { " to \(place($0))" } ?? "")
        case .moveTo: return "Move the pointer" + (at.map { " to \(place($0))" } ?? "")
        default:
            return kind.title + (kind.isScroll ? " \(lines) lines" : "") + whereText
        }
    }
}

/// Sends mouse events, marked as Toolbelt's own so its gestures ignore them.
enum MouseDriver {
    /// Turns places counted from the front window or a found picture into screen places; nil if the
    /// window or picture isn't there.
    @MainActor static func resolved(_ command: MouseCommand) async -> MouseCommand? {
        var result = command
        let base: CGPoint
        switch command.origin {
        case .screen: return command
        case .window:
            guard PermissionGate.ensure(.accessibility, to: "click in the front window"),
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let window = FrontWindow.focusedWindow(of: pid), let corner = WindowFrame.position(of: window) else { return nil }
            base = corner
        case .image:
            guard let path = command.image, let middle = await ScreenReader.find((path as NSString).expandingTildeInPath) else { return nil }
            base = middle
        }
        let offset = command.at ?? .zero
        result.at = CGPoint(x: base.x + offset.x, y: base.y + offset.y)
        if let to = command.to { result.to = CGPoint(x: base.x + to.x, y: base.y + to.y) }
        result.origin = .screen
        return result
    }

    /// Does it, working out the place first; false if the window or picture wasn't found.
    @MainActor static func run(_ command: MouseCommand, flags: CGEventFlags) async -> Bool {
        guard let place = await resolved(command) else { return false }
        perform(place, flags: flags)
        return true
    }

    /// Where the pointer is now (top-left based, like mouse events).
    static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func perform(_ command: MouseCommand, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let point = command.at ?? pointer
        func send(_ type: CGEventType, _ at: CGPoint, _ button: CGMouseButton, clicks: Int64 = 1, number: Int64? = nil) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: button) else { return }
            event.flags = flags
            event.setIntegerValueField(.mouseEventClickState, value: clicks)
            if let number { event.setIntegerValueField(.mouseEventButtonNumber, value: number) }
            event.setIntegerValueField(.eventSourceUserData, value: GestureEventTap.ownEventMarker)
            event.post(tap: .cghidEventTap)
        }
        if command.at != nil { send(.mouseMoved, point, .left) }
        switch command.kind {
        case .moveTo:
            send(.mouseMoved, point, .left)
        case .click:
            send(.leftMouseDown, point, .left)
            send(.leftMouseUp, point, .left)
        case .doubleClick:
            send(.leftMouseDown, point, .left, clicks: 1)
            send(.leftMouseUp, point, .left, clicks: 1)
            send(.leftMouseDown, point, .left, clicks: 2)
            send(.leftMouseUp, point, .left, clicks: 2)
        case .rightClick:
            send(.rightMouseDown, point, .right)
            send(.rightMouseUp, point, .right)
        case .middleClick:
            send(.otherMouseDown, point, .center, number: 2)
            send(.otherMouseUp, point, .center, number: 2)
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            let amount = Int32(command.lines)
            let vertical: Int32 = command.kind == .scrollUp ? amount : command.kind == .scrollDown ? -amount : 0
            let horizontal: Int32 = command.kind == .scrollLeft ? amount : command.kind == .scrollRight ? -amount : 0
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
            event.location = point
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: GestureEventTap.ownEventMarker)
            event.post(tap: .cghidEventTap)
        case .drag:
            let end = command.to ?? CGPoint(x: point.x + 100, y: point.y)
            send(.leftMouseDown, point, .left)
            for step in 1...10 {
                let progress = CGFloat(step) / 10
                send(.leftMouseDragged, CGPoint(x: point.x + (end.x - point.x) * progress, y: point.y + (end.y - point.y) * progress), .left)
                usleep(10_000)
            }
            send(.leftMouseUp, end, .left)
        }
    }
}

struct MouseActionEditor: View {
    @Binding var action: MacroAction
    @State private var picking: String?

    private var command: Binding<MouseCommand> {
        Binding(get: { MouseCommand(text: action.value) }, set: { action.value = $0.text })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mouse", selection: command.kind) {
                ForEach(MouseCommand.Kind.allCases) { Text($0.title).tag($0) }
            }
            Picker("Counted from", selection: command.origin) {
                Text("The screen's top left").tag(MouseCommand.Origin.screen)
                Text("The front window's top left").tag(MouseCommand.Origin.window)
                Text("A picture on screen (its middle)").tag(MouseCommand.Origin.image)
            }
            if command.wrappedValue.origin == .image {
                HStack {
                    TextField("Picture file (PNG)", text: Binding(get: { command.wrappedValue.image ?? "" }, set: { command.wrappedValue.image = $0 }))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.png, .jpeg, .tiff]
                        NSApp.activate()
                        if panel.runModal() == .OK, let url = panel.url { command.wrappedValue.image = url.path }
                    }
                }
                Text("Needs Screen Recording. Take the picture with Toolbelt's screenshot (area).").font(.caption).foregroundStyle(.secondary)
            }
            if command.wrappedValue.origin != .screen {
                TextField("Move by x,y from there (empty: exactly there)", text: Binding(
                    get: { command.wrappedValue.at.map { "\(Int($0.x)),\(Int($0.y))" } ?? "" },
                    set: { command.wrappedValue.at = ScreenPoint.parse($0) }))
            }
            HStack {
                Text("Holding").foregroundStyle(.secondary)
                ForEach(Self.modifierKeys, id: \.bit) { key in
                    Toggle(key.symbol, isOn: Binding(get: { action.modifiers & key.bit != 0 },
                                                     set: { action.modifiers = $0 ? action.modifiers | key.bit : action.modifiers & ~key.bit }))
                        .toggleStyle(.button)
                }
            }
            HStack {
                Picker(command.wrappedValue.kind == .drag ? "From" : "Where", selection: Binding(
                    get: { command.wrappedValue.at == nil ? 0 : 1 },
                    set: { command.wrappedValue.at = $0 == 0 ? nil : (command.wrappedValue.at ?? MouseDriver.pointer) })) {
                    Text("Where the pointer is").tag(0)
                    Text("At a place on the screen").tag(1)
                }
                .fixedSize()
                if let at = command.wrappedValue.at {
                    Text("\(Int(at.x)), \(Int(at.y))").monospacedDigit().foregroundStyle(.secondary)
                    Button(picking == "at" ? "Move the pointer there…" : "Pick") { pick("at") }
                }
            }
            if command.wrappedValue.kind == .drag {
                HStack {
                    Text("To").foregroundStyle(.secondary)
                    Text(command.wrappedValue.to.map { "\(Int($0.x)), \(Int($0.y))" } ?? "100 points to the right").monospacedDigit()
                    Button(picking == "to" ? "Move the pointer there…" : "Pick") { pick("to") }
                }
            }
            if command.wrappedValue.kind.isScroll {
                Stepper("\(command.wrappedValue.lines) lines", value: command.lines, in: 1...100)
            }
            Text("Pick: move the pointer to the place within 3 seconds. Places count from the top left of the main display.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Carbon modifier bits, as saved in MacroAction.modifiers.
    static let modifierKeys: [(symbol: String, bit: Int)] = [("⌃", 0x1000), ("⌥", 0x0800), ("⇧", 0x0200), ("⌘", 0x0100)]

    /// Waits three seconds, then takes wherever the pointer is.
    private func pick(_ which: String) {
        picking = which
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var updated = command.wrappedValue
            if which == "at" { updated.at = MouseDriver.pointer } else { updated.to = MouseDriver.pointer }
            command.wrappedValue = updated
            picking = nil
        }
    }
}

// MARK: - Searching the web

@MainActor
enum WebSearch {
    static let google = "https://www.google.com/search?q=%s"

    /// The search address for some text: %s in the template is replaced by the text, made safe for a web address.
    nonisolated static func url(for text: String, template: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        let pattern = template.trimmingCharacters(in: .whitespaces).isEmpty ? google : template
        return URL(string: pattern.contains("%s") ? pattern.replacingOccurrences(of: "%s", with: encoded) : pattern + encoded)
    }

    /// Copies the selection with ⌘C, opens the search, and puts the clipboard back.
    static func searchSelection(template: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            copy.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            return copy
        } ?? []
        let before = pasteboard.changeCount
        TextInserter.press(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated {
            let copied = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
            guard let copied, let address = Self.url(for: copied, template: template) else {
                HUD.show("Select some text first", symbol: "magnifyingglass")
                return
            }
            NSWorkspace.shared.open(address)
        } }
    }
}

// MARK: - Bluetooth and Wi-Fi

/// Bluetooth on and off, through the same call macOS's Bluetooth menu uses.
@MainActor
enum BluetoothPower {
    private typealias Get = @convention(c) () -> Int32
    private typealias Set = @convention(c) (Int32) -> Void

    private nonisolated(unsafe) static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

    static var isOn: Bool? {
        guard let handle, let symbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: Get.self)() != 0
    }

    static func toggle() {
        guard let on = isOn, let handle, let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else {
            HUD.show("Bluetooth can't be switched from Toolbelt on this Mac", symbol: "exclamationmark.triangle")
            return
        }
        unsafeBitCast(symbol, to: Set.self)(on ? 0 : 1)
        HUD.show(on ? "Bluetooth off" : "Bluetooth on", symbol: "dot.radiowaves.left.and.right")
    }
}

@MainActor
enum WiFiPower {
    static func toggle() {
        guard let interface = CWWiFiClient.shared().interface() else {
            HUD.show("This Mac has no Wi-Fi", symbol: "wifi.slash")
            return
        }
        let on = interface.powerOn()
        do {
            try interface.setPower(!on)
            HUD.show(on ? "Wi-Fi off" : "Wi-Fi on", symbol: on ? "wifi.slash" : "wifi")
        } catch {
            HUD.show("Couldn't switch Wi-Fi", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }
}

// MARK: - Trash and disks

enum Trash {
    /// Through Finder, so it's the same as Finder → Empty Trash. macOS asks once to let Toolbelt control Finder.
    /// Runs in the background: Finder may need to start, and macOS may be asking for permission.
    static func empty() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Waits for Finder to start if it isn't running, and for it to finish.
        process.arguments = ["-e", "with timeout of 120 seconds", "-e", "tell application \"Finder\" to empty trash", "-e", "end timeout"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if finished.terminationStatus != 0 {
                NSLog("Toolbelt: couldn't empty the Trash: \(text)")
            } else {
                NSLog("Toolbelt: Finder emptied the Trash")
            }
        }
        NSLog("Toolbelt: asking Finder to empty the Trash")
        do { try process.run() } catch { NSLog("Toolbelt: couldn't empty the Trash: \(error)") }
    }
}

@MainActor
enum Disks {
    /// Disks that can be ejected: USB drives, SD cards, disk images and network disks (not the Mac's own).
    nonisolated static var ejectable: [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true else { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true || url.path.hasPrefix("/Volumes/") && values.volumeIsInternal != true
        }
    }

    static func ejectAll() {
        let disks = ejectable
        guard !disks.isEmpty else {
            HUD.show("No disks to eject", symbol: "eject")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for disk in disks {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: disk) } catch { failed.append(disk.lastPathComponent) }
            }
            let couldNot = failed
            Task { @MainActor in
                if couldNot.isEmpty {
                    HUD.show(disks.count == 1 ? "Ejected \(disks[0].lastPathComponent)" : "Ejected \(disks.count) disks", symbol: "eject")
                } else {
                    HUD.show("Couldn't eject \(couldNot.joined(separator: ", "))", detail: "Something is still using it.", symbol: "exclamationmark.triangle")
                }
            }
        }
    }
}
