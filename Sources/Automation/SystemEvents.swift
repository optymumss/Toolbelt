import AppKit
import IOBluetooth
import IOKit
import IOKit.ps

// Watchers for the Mac's own events, for macro triggers like BetterTouchTool's "other triggers":
// the charger and battery, USB and Bluetooth devices, and being idle. Each runs only while a macro
// uses it. Sleep, wake, locking and disks come straight from macOS notifications (AutomationModule).

/// Whether a device or disk name matches a trigger's text: empty matches anything, otherwise "contains".
enum NameFilter {
    static func matches(_ name: String, _ filter: String) -> Bool {
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        return wanted.isEmpty || name.localizedCaseInsensitiveContains(wanted)
    }
}

/// Idle for a while, and active again afterwards.
struct IdleTracker {
    enum Change: Equatable { case becameIdle, activeAgain }
    var idleAfter: Double
    private(set) var isIdle = false

    init(idleAfter: Double) { self.idleAfter = idleAfter }

    mutating func update(secondsSinceInput: Double) -> Change? {
        if !isIdle, secondsSinceInput >= idleAfter {
            isIdle = true
            return .becameIdle
        }
        if isIdle, secondsSinceInput < min(idleAfter, 30) {
            isIdle = false
            return .activeAgain
        }
        return nil
    }
}

/// The battery going below a level while running on battery (once, until it's back above it).
struct BatteryThreshold {
    var below: Int
    private var last: Int?

    init(below: Int) { self.below = below }

    mutating func update(percent: Int?, onBattery: Bool) -> Bool {
        guard let percent else { return false }
        defer { last = percent }
        guard onBattery, percent < below, let last else { return false }
        return last >= below
    }
}

/// Seconds since the last key press, click, scroll or mouse move (needs no permission).
enum InputIdle {
    static var seconds: Double {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}

/// The charger and battery (IOKit's power-source notifications).
@MainActor
final class PowerWatcher {
    var onChange: ((_ onAC: Bool, _ percent: Int?) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let made = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                let state = PowerWatcher.state()
                watcher.onChange?(state.onAC, state.percent)
            }
        }, me)?.takeRetainedValue() else { return }
        source = made
        CFRunLoopAddSource(CFRunLoopGetMain(), made, .defaultMode)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    /// On the charger (or a desktop Mac), and the battery's level if there is one.
    nonisolated static func state() -> (onAC: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? ?? "AC Power"
        var percent: Int?
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            percent = current * 100 / maximum
        }
        return (providing != "Battery Power", percent)
    }
}

/// USB devices plugged in and out (IOKit matching notifications). Devices already plugged in when it
/// starts don't count.
@MainActor
final class USBWatcher {
    var onChange: ((_ name: String, _ connected: Bool) -> Void)?
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0

    func start() {
        guard port == nil, let made = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = made
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(made).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(made, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, connected: true, report: true) }
        }, me, &added)
        drain(added, connected: true, report: false)
        IOServiceAddMatchingNotification(made, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, connected: false, report: true) }
        }, me, &removed)
        drain(removed, connected: false, report: false)
    }

    func stop() {
        if added != 0 { IOObjectRelease(added) }
        if removed != 0 { IOObjectRelease(removed) }
        added = 0
        removed = 0
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    fileprivate func drain(_ iterator: io_iterator_t, connected: Bool, report: Bool) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if report { onChange?(Self.name(of: service), connected) }
            IOObjectRelease(service)
        }
    }

    private static func name(of service: io_object_t) -> String {
        if let product = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            return product
        }
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &buffer)
        let name = String(cString: buffer)
        return name.isEmpty ? "USB device" : name
    }
}

/// Bluetooth devices connecting and disconnecting. macOS asks once for the Bluetooth permission.
@MainActor
final class BluetoothWatcher: NSObject {
    var onChange: ((_ name: String, _ connected: Bool) -> Void)?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [IOBluetoothUserNotification] = []
    private var ready = false

    func start() {
        guard connectNote == nil else { return }
        ready = false
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        // Devices already connected are reported straight away: those don't count.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.ready = true }
    }

    func stop() {
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.forEach { $0.unregister() }
        disconnectNotes = []
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let disconnect = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) {
            disconnectNotes.append(disconnect)
        }
        if ready { onChange?(device.name ?? "Bluetooth device", true) }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotes.removeAll { $0 === note }
        onChange?(device.name ?? "Bluetooth device", false)
    }
}
