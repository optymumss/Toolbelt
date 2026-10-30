import AppKit
import CoreAudio
import CoreWLAN
import CoreLocation
import IOKit.hid
import Network

// MARK: - Clicking menu items by name

/// Clicks a menu item in the app in front, by its path: "File > Export…" or "View > Show Sidebar".
@MainActor
enum MenuClicker {
    @discardableResult
    static func click(_ path: String, in pid: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier) -> Bool {
        guard let pid, PermissionGate.ensure(.accessibility, to: "choose menu items for you") else { return false }
        let names = path.components(separatedBy: ">").map { normalise($0) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        var element: AXUIElement? = attribute(app, kAXMenuBarAttribute)
        for (index, name) in names.enumerated() {
            guard let parent = element else { return false }
            // A menu bar item's children are its menu; a menu's children are its items.
            let items = children(of: parent).flatMap { child -> [AXUIElement] in
                role(of: child) == kAXMenuRole ? children(of: child) : [child]
            }
            guard let match = items.first(where: { normalise(title(of: $0)) == name }) else { return false }
            if index == names.count - 1 {
                return AXUIElementPerformAction(match, kAXPressAction as CFString) == .success
            }
            element = match
        }
        return false
    }

    /// Ignores case, extra spaces and "…" versus "...".
    static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func title(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String ?? ""
    }

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String ?? ""
    }
}

// MARK: - Screen resolution

enum DisplayModes {
    /// "1920 × 1080" style sizes (in points, as System Settings shows them) for the main display.
    static func available(for display: CGDirectDisplayID = CGMainDisplayID()) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
    }

    /// Parses "1920x1080" (or "1920 × 1080").
    static func size(from text: String) -> (Int, Int)? {
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        return numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
    }

    /// Switches the main display to that size, preferring the sharpest (Retina) mode. Returns whether it worked.
    @discardableResult
    static func set(_ text: String, display: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
        guard let (width, height) = size(from: text) else { return false }
        let matches = available(for: display).filter { $0.width == width && $0.height == height }
        guard let mode = matches.max(by: { $0.pixelWidth < $1.pixelWidth }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}

// MARK: - Sound output

enum AudioOutputs {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let name = name(of: id) else { return nil }
            return Device(id: id, name: name)
        }
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Sends sound to the device whose name contains `name` (for example "AirPods"). Returns whether it worked.
    @discardableResult
    static func setDefault(_ name: String) -> Bool {
        guard let device = all().first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else { return false }
        var id = device.id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }
}

// MARK: - Keys on another keyboard or device

/// Watches key presses device by device (IOKit), so a key on a second keyboard or a macro pad can
/// start a macro. Runs only while a macro uses it. "Exclusive" asks macOS for the device to
/// itself, so its keys don't also type; macOS only allows that for some devices.
@MainActor
final class DeviceKeyWatcher {
    private var manager: IOHIDManager?
    var onKey: ((_ device: String, _ usage: Int) -> Void)?
    private(set) var exclusive = false

    var isRunning: Bool { manager != nil }

    func start(exclusiveDevices: Set<String> = []) {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
        ] as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, deviceKeyCallback, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        exclusive = !exclusiveDevices.isEmpty
            && IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess
        if !exclusive {
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        // Key presses only (not releases), from keyboards and media keys.
        guard IOHIDValueGetIntegerValue(value) == 1, page == kHIDPage_KeyboardOrKeypad || page == kHIDPage_Consumer,
              usage >= 4, usage < 0xFFFF else { return }
        let device = IOHIDElementGetDevice(element)
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown device"
        onKey?(name, page == kHIDPage_Consumer ? 0x10000 + usage : usage)
    }
}

private func deviceKeyCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context else { return }
    let watcher = Unmanaged<DeviceKeyWatcher>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.received(value) }
}

// MARK: - Wi-Fi and network

/// Tells when the Wi-Fi network or the connection changes. Reading the Wi-Fi network's name
/// needs Location Services permission on current macOS; without it, "any Wi-Fi change" still works.
@MainActor
final class NetworkWatcher: NSObject, CWEventDelegate, CLLocationManagerDelegate {
    var onWiFiChange: ((String?) -> Void)?
    var onNetworkChange: (() -> Void)?
    private var path: NWPathMonitor?
    private var lastStatus: String?
    private var watchingWiFi = false
    private var location: CLLocationManager?

    func start(wifi: Bool, network: Bool) {
        stop()
        if network {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let status = "\(path.status) \(path.availableInterfaces.map(\.name).sorted())"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // The first report is just the current state, not a change.
                        if let last = self.lastStatus, last != status { self.onNetworkChange?() }
                        self.lastStatus = status
                    }
                }
            }
            monitor.start(queue: DispatchQueue(label: "Toolbelt network"))
            path = monitor
        }
        if wifi {
            CWWiFiClient.shared().delegate = self
            try? CWWiFiClient.shared().startMonitoringEvent(with: .ssidDidChange)
            watchingWiFi = true
            // macOS only shares the network's name with apps allowed to use Location Services.
            if CLLocationManager().authorizationStatus == .notDetermined {
                let manager = CLLocationManager()
                manager.delegate = self
                manager.requestWhenInUseAuthorization()
                location = manager
            }
        }
    }

    func stop() {
        path?.cancel()
        path = nil
        lastStatus = nil
        if watchingWiFi {
            try? CWWiFiClient.shared().stopMonitoringAllEvents()
            watchingWiFi = false
        }
    }

    static var currentWiFi: String? { CWWiFiClient.shared().interface()?.ssid() }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        let name = Self.currentWiFi
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onWiFiChange?(name) }
        }
    }
}

// MARK: - Time

enum MacroSchedule {
    /// The next time a time-of-day trigger fires after `date`.
    static func next(_ trigger: MacroTrigger, after date: Date, calendar: Calendar = .current) -> Date? {
        switch trigger.kind {
        case .timeOfDay:
            let days = trigger.weekdays.isEmpty ? Array(1...7) : trigger.weekdays
            return days.compactMap { day in
                calendar.nextDate(after: date, matching: DateComponents(hour: trigger.number / 60, minute: trigger.number % 60, second: 0, weekday: day),
                                  matchingPolicy: .nextTime)
            }.min()
        case .every:
            return trigger.number > 0 ? date.addingTimeInterval(Double(trigger.number) * 60) : nil
        default:
            return nil
        }
    }
}
