import AppKit
import SwiftUI
import IOKit

// 0.39: brightness for separate monitors, like BetterTouchTool's (and MonitorControl's). macOS only
// changes the built-in screen; a monitor's own brightness is set over its cable with DDC/CI, the same
// commands its buttons send. On Apple silicon Macs that goes through IOAVService (a private part of
// macOS that MonitorControl and BetterDisplay use too), looked up at run time so nothing breaks if
// it's missing. Monitors that don't understand DDC (some TVs, DisplayLink docks) just stay as they are.

/// The DDC/CI messages, pure so they can be tested without a monitor.
enum DDC {
    /// The monitor listens at I²C address 0x37; messages start with the host's address (0x51).
    static let chipAddress: UInt32 = 0x37
    static let dataAddress: UInt32 = 0x51
    /// The brightness control ("luminance", VCP code 0x10).
    static let brightness: UInt8 = 0x10

    /// Every message ends with an XOR of the destination (0x6E), the source (0x51) and its own bytes.
    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E ^ 0x51) { $0 ^ $1 }
    }

    /// "Set this control to this value" (after the 0x51 source address IOAVService adds itself).
    static func setMessage(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    /// "What is this control at, and its most?"
    static func getMessage(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(body)]
    }

    /// Reads the monitor's answer: …, 0x02 (reply), 0x00 (no error), code, type, max (2 bytes), current (2 bytes).
    static func parseReply(_ bytes: [UInt8], code: UInt8) -> (current: Int, maximum: Int)? {
        guard bytes.count >= 8 else { return nil }
        for start in 0...(bytes.count - 8) where bytes[start] == 0x02 && bytes[start + 1] == 0x00 && bytes[start + 2] == code {
            let maximum = Int(bytes[start + 4]) << 8 | Int(bytes[start + 5])
            let current = Int(bytes[start + 6]) << 8 | Int(bytes[start + 7])
            guard maximum > 0, current <= maximum else { return nil }
            return (current, maximum)
        }
        return nil
    }

    /// A change like "+10", "-6.25" or "70" applied to a level from 0 to 100.
    static func level(_ text: String, from current: Double) -> Double? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " %"))
        guard let number = Double(trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed) else { return nil }
        let relative = trimmed.hasPrefix("+") || trimmed.hasPrefix("-")
        return min(100, max(0, relative ? current + number : number))
    }
}

/// A separate monitor that answers DDC.
final class ExternalDisplay {
    let service: CFTypeRef
    let name: String
    /// The last brightness Toolbelt knows of, 0–100, and the monitor's own top value.
    var level: Double
    var maximum: Int

    init(service: CFTypeRef, name: String, level: Double, maximum: Int) {
        self.service = service
        self.name = name
        self.level = level
        self.maximum = maximum
    }
}

enum ExternalDisplays {
    private typealias CreateFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create: CreateFunction? = symbol("IOAVServiceCreateWithService")
    private static let write: I2CFunction? = symbol("IOAVServiceWriteI2C")
    private static let read: I2CFunction? = symbol("IOAVServiceReadI2C")

    private static func symbol<T>(_ name: String) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var isSupported: Bool { create != nil && write != nil && read != nil }

    /// The monitors plugged in right now (their brightness is read once, here).
    static func find() -> [ExternalDisplay] {
        guard let create else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [ExternalDisplay] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            let reading = get(service, code: DDC.brightness)
            let level = reading.map { Double($0.current) * 100 / Double($0.maximum) } ?? 50
            found.append(ExternalDisplay(service: service, name: "Monitor \(found.count + 1)", level: level, maximum: reading?.maximum ?? 100))
        }
        return found
    }

    @discardableResult
    static func set(_ service: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        guard let write else { return false }
        var message = DDC.setMessage(code: code, value: value)
        // Some monitors miss the first message: send it twice, as MonitorControl does.
        var ok = false
        for _ in 0..<2 {
            ok = write(service, DDC.chipAddress, DDC.dataAddress, &message, UInt32(message.count)) == KERN_SUCCESS || ok
            usleep(10_000)
        }
        return ok
    }

    static func get(_ service: CFTypeRef, code: UInt8) -> (current: Int, maximum: Int)? {
        guard let write, let read else { return nil }
        for _ in 0..<3 {
            var message = DDC.getMessage(code: code)
            guard write(service, DDC.chipAddress, DDC.dataAddress, &message, UInt32(message.count)) == KERN_SUCCESS else { continue }
            usleep(40_000) // the monitor needs a moment to answer
            var reply = [UInt8](repeating: 0, count: 12)
            guard read(service, DDC.chipAddress, 0, &reply, UInt32(reply.count)) == KERN_SUCCESS else { continue }
            if let answer = DDC.parseReply(reply, code: code) { return answer }
        }
        return nil
    }
}

/// Changes the brightness of every separate monitor, from actions, macros and (if chosen) the brightness keys.
@MainActor
final class MonitorBrightness {
    static let shared = MonitorBrightness()

    private var displays: [ExternalDisplay]?
    private var observer: NSObjectProtocol?
    private var keyTap: (port: CFMachPort, source: CFRunLoopSource)?
    private let queue = DispatchQueue(label: "Toolbelt.ddc")

    /// Brightness actions also change monitors (on unless switched off).
    static var withActions: Bool {
        get { SettingsStore.shared.value("display.externalWithActions", default: true) }
        set { SettingsStore.shared.set(newValue, for: "display.externalWithActions") }
    }

    /// The keyboard's brightness keys also change monitors.
    static var withKeys: Bool {
        get { SettingsStore.shared.value("display.externalKeys", default: false) }
        set { SettingsStore.shared.set(newValue, for: "display.externalKeys") }
    }

    private var current: [ExternalDisplay] {
        if let displays { return displays }
        let found = ExternalDisplays.find()
        displays = found
        if observer == nil {
            // Plugging a monitor in or out: look again next time.
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MonitorBrightness.shared.displays = nil }
            }
        }
        return found
    }

    var count: Int { current.count }

    /// "+6.25", "-10" or "70" (percent). Returns false when there's no monitor to change.
    @discardableResult
    func change(_ text: String, showLevel: Bool = true) -> Bool {
        let displays = current
        guard !displays.isEmpty else { return false }
        for display in displays {
            guard let level = DDC.level(text, from: display.level) else { return false }
            display.level = level
            let value = UInt16((level / 100 * Double(display.maximum)).rounded())
            let service = display.service
            queue.async { ExternalDisplays.set(service, code: DDC.brightness, value: value) }
        }
        if showLevel, let first = displays.first {
            HUD.show("Monitor brightness \(Int(first.level.rounded()))%", symbol: "sun.max")
        }
        return true
    }

    /// From the brightness actions (a key's worth is a 16th; "a little" is a quarter of that).
    func step(up: Bool, small: Bool) {
        guard Self.withActions else { return }
        let amount = small ? 100.0 / 64 : 100.0 / 16
        change(String(format: "%+.3f", up ? amount : -amount))
    }

    func refreshKeys() {
        let wants = Self.withKeys
        if wants, keyTap == nil {
            guard PermissionGate.ensure(.accessibility, to: "use the brightness keys for your monitor") else { return }
            // System-defined events (14) carry the brightness, volume and media keys. Listen only: the
            // built-in screen still reacts as usual.
            let mask: UInt64 = 1 << 14
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                               eventsOfInterest: CGEventMask(mask), callback: brightnessKeyCallback, userInfo: nil),
                  let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            keyTap = (port, source)
        } else if !wants, let tap = keyTap {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
            keyTap = nil
        }
    }

    fileprivate func reenableKeys() {
        if let keyTap { CGEvent.tapEnable(tap: keyTap.port, enable: true) }
    }

    /// The brightness key in a system-defined event, if it's one going down: true for up, false for down.
    nonisolated static func brightnessKey(subtype: Int16, data1: Int) -> Bool? {
        guard subtype == 8 else { return nil }
        let key = (data1 & 0xFFFF_0000) >> 16
        let down = ((data1 & 0xFF00) >> 8) == 0x0A
        guard down else { return nil }
        switch key {
        case 2: return true // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: return false // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: return nil
        }
    }
}

private func brightnessKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MonitorBrightness.shared.reenableKeys()
        } else if type.rawValue == 14, let ns = NSEvent(cgEvent: event),
                  let up = MonitorBrightness.brightnessKey(subtype: ns.subtype.rawValue, data1: ns.data1) {
            // Our own presses (from the brightness actions) are handled there already.
            if event.getIntegerValueField(.eventSourceUserData) != GestureEventTap.ownEventMarker {
                let small = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
                MonitorBrightness.shared.change(String(format: "%+.3f", (small ? 100.0 / 64 : 100.0 / 16) * (up ? 1 : -1)))
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Settings

struct MonitorBrightnessSettings: View {
    @State private var withActions = MonitorBrightness.withActions
    @State private var withKeys = MonitorBrightness.withKeys
    @State private var found: Int?

    var body: some View {
        Section {
            Toggle("Brightness actions and gestures also change separate monitors", isOn: $withActions)
                .onChange(of: withActions) { _, value in MonitorBrightness.withActions = value }
            Toggle("The keyboard's brightness keys also change separate monitors", isOn: $withKeys)
                .onChange(of: withKeys) { _, value in
                    MonitorBrightness.withKeys = value
                    MonitorBrightness.shared.refreshKeys()
                }
            LabeledContent("Monitors found") {
                HStack {
                    Text(found.map { $0 == 0 ? "None that answer" : "\($0)" } ?? "—")
                    Button("Look Now") { found = MonitorBrightness.shared.count }
                }
            }
        } header: {
            Text("Separate monitors")
        } footer: {
            Text(ExternalDisplays.isSupported
                 ? "macOS only changes the built-in screen. Toolbelt sets a monitor's own brightness over its cable (DDC), like its buttons do. Most monitors understand it; some TVs and docks (DisplayLink) don't. The keys need Accessibility."
                 : "This Mac doesn't offer the way Toolbelt talks to monitors (it needs an Apple silicon Mac).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
