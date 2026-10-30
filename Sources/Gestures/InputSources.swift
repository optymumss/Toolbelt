import AppKit

// The devices: touches from trackpads and Magic Mice, mouse buttons and strokes, and the keyboard.
// Each runs only while a gesture rule needs it, and does very little per event, to save battery.

// MARK: - Trackpad and Magic Mouse touches

/// Reads raw touches with MultitouchSupport, the private framework macOS's own gestures use
/// (also used by BetterTouchTool). Loaded when needed; if it's ever missing, touch gestures
/// simply don't work and nothing else is affected.
final class MultitouchReader: @unchecked Sendable {
    typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void
    typealias Register = @convention(c) (UnsafeMutableRawPointer?, FrameCallback) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FamilyID = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32

    static let shared = MultitouchReader()

    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var recognizers: [UnsafeMutableRawPointer: TouchRecognizer] = [:]
    /// Called on the main thread when a touch gesture completes.
    var onGesture: ((Gesture) -> Void)?

    /// Whether the framework could be loaded on this Mac.
    var isAvailable: Bool { load() }
    var deviceCount: Int { lock.lock(); defer { lock.unlock() }; return devices.count }

    private func load() -> Bool {
        if handle != nil { return true }
        handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
        return handle != nil
    }

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard devices.isEmpty, load(),
              let list = symbol("MTDeviceCreateList", as: DeviceList.self),
              let register = symbol("MTRegisterContactFrameCallback", as: Register.self),
              let startDevice = symbol("MTDeviceStart", as: Start.self),
              let array = list()?.takeRetainedValue() as? [AnyObject] else { return }
        let family = symbol("MTDeviceGetFamilyID", as: FamilyID.self)
        for object in array {
            let device = Unmanaged.passRetained(object).toOpaque()
            var id: Int32 = 0
            _ = family?(device, &id)
            // Magic Mouse family IDs are 112 and 113; everything else here is a trackpad.
            let source: TouchSource = (id == 112 || id == 113) ? .magicMouse : .trackpad
            recognizers[device] = TouchRecognizer(source: source)
            register(device, multitouchFrame)
            startDevice(device, 0)
            devices.append(device)
        }
    }

    func stop() {
        lock.lock()
        let stopping = devices
        devices = []
        recognizers = [:]
        lock.unlock()
        guard let stopDevice = symbol("MTDeviceStop", as: Stop.self) else { return }
        for device in stopping {
            stopDevice(device)
            Unmanaged<AnyObject>.fromOpaque(device).release()
        }
    }

    /// Touches from one device (the framework's own thread).
    fileprivate func frame(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, count: Int32, time: Double) {
        guard let device else { return }
        var points: [TouchPoint] = []
        if let touches, count > 0 {
            // Each touch record is 96 bytes; its state is at byte 20, its id at 16, and its
            // position (0–1) at bytes 32 and 36.
            for index in 0..<Int(min(count, 11)) {
                let record = touches + index * 96
                let state = record.load(fromByteOffset: 20, as: Int32.self)
                guard state >= 3, state <= 5 else { continue } // in contact (not hovering or lifting)
                points.append(TouchPoint(id: Int(record.load(fromByteOffset: 16, as: Int32.self)),
                                         x: Double(record.load(fromByteOffset: 32, as: Float.self)),
                                         y: Double(record.load(fromByteOffset: 36, as: Float.self))))
            }
        }
        lock.lock()
        let gesture = recognizers[device]?.feed(points, at: time)
        lock.unlock()
        if let gesture {
            DispatchQueue.main.async { [weak self] in self?.onGesture?(gesture) }
        }
    }

    /// The gesture for a click happening now (several fingers, or one finger in a corner).
    func clickGesture() -> Gesture? {
        lock.lock()
        defer { lock.unlock() }
        for recognizer in recognizers.values where recognizer.source == .trackpad {
            if let gesture = recognizer.click() { return gesture }
        }
        return nil
    }
}

private func multitouchFrame(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, count: Int32, time: Double, frame: Int32) {
    MultitouchReader.shared.frame(device: device, touches: touches, count: count, time: time)
}

// MARK: - Mouse buttons, strokes, clicks and the keyboard

/// One event tap that watches only the event types current rules need. Mouse buttons, strokes and
/// clicks that match a rule are kept from the app underneath (so "back" doesn't also go back);
/// everything else passes straight through.
@MainActor
final class GestureEventTap {
    struct Needs: Equatable {
        var buttons: Set<Int> = []
        var strokeButtons: Set<Int> = []
        var clicks = false
        var keyboard = false

        var isEmpty: Bool { buttons.isEmpty && strokeButtons.isEmpty && !clicks && !keyboard }
    }

    /// Marks the clicks Toolbelt itself sends, so the tap lets them through.
    static let ownEventMarker: Int64 = 0x544F4F4C

    var needs = Needs()
    /// Asks whether a gesture has a rule here; if so, runs it and returns true (the event is kept).
    var handle: ((Gesture) -> Bool)?
    /// Typed characters, for key sequences.
    var onTyped: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    /// A click: whatever was being typed is finished.
    var onClick: (() -> Void)?

    /// Mouse events go through an active tap (so matching ones can be kept from apps); the keyboard
    /// only through a listen-only tap, so typing is never held up by Toolbelt.
    private var mouseTap: (port: CFMachPort, source: CFRunLoopSource)?
    private var keyTap: (port: CFMachPort, source: CFRunLoopSource)?
    private var modifiers = ModifierTapDetector()
    private var stroke: (button: Int, points: [CGPoint])?
    private var swallowedUp: Set<Int> = []

    var isRunning: Bool { mouseTap != nil || keyTap != nil }

    /// Starts or stops listening to match `needs`. Returns false if macOS refused (no permission).
    @discardableResult
    func update(_ needs: Needs) -> Bool {
        if needs != self.needs { stop() }
        self.needs = needs
        var ok = true
        var mouse: UInt64 = 0
        func add(_ type: CGEventType) { mouse |= 1 << type.rawValue }
        if !needs.buttons.isEmpty || needs.strokeButtons.contains(2) { add(.otherMouseDown); add(.otherMouseUp) }
        if needs.strokeButtons.contains(2) { add(.otherMouseDragged) }
        if needs.strokeButtons.contains(1) { add(.rightMouseDown); add(.rightMouseUp); add(.rightMouseDragged) }
        if needs.clicks { add(.leftMouseDown); add(.leftMouseUp) }
        if mouse != 0, mouseTap == nil {
            mouseTap = makeTap(mouse, options: .defaultTap)
            ok = ok && mouseTap != nil
        }
        if needs.keyboard, keyTap == nil {
            // Clicks also end a typed sequence or a modifier tap (unless the mouse tap already sees them).
            var keys: UInt64 = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            if !needs.clicks { keys |= 1 << CGEventType.leftMouseDown.rawValue }
            if !needs.strokeButtons.contains(1) { keys |= 1 << CGEventType.rightMouseDown.rawValue }
            keyTap = makeTap(keys, options: .listenOnly)
            ok = ok && keyTap != nil
        }
        return ok
    }

    private func makeTap(_ mask: UInt64, options: CGEventTapOptions) -> (port: CFMachPort, source: CFRunLoopSource)? {
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                           eventsOfInterest: CGEventMask(mask), callback: gestureTapCallback, userInfo: me),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, source)
    }

    func stop() {
        for tap in [mouseTap, keyTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
        }
        mouseTap = nil
        keyTap = nil
        stroke = nil
        swallowedUp = []
    }

    /// Returns false to keep the event from the app underneath (only possible for mouse events).
    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for tap in [mouseTap, keyTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap.port, enable: true) }
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMarker { return true }
        let time = Double(event.timestamp) / 1_000_000_000

        switch type {
        case .flagsChanged:
            guard let key = ModifierKey.side(forKeyCode: Int(event.getIntegerValueField(.keyboardEventKeycode))),
                  let gesture = modifiers.modifierChanged(key, flags: event.flags, at: time) else { return true }
            _ = handle?(gesture)
            return true

        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            // Some tools send modifier keys as key presses rather than modifier changes.
            if let key = ModifierKey.side(forKeyCode: code) {
                let flags = type == .keyDown ? event.flags.union(key.flag) : event.flags.subtracting(key.flag)
                if let gesture = modifiers.modifierChanged(key, flags: flags, at: time) { _ = handle?(gesture) }
                return true
            }
            guard type == .keyDown else { return true }
            modifiers.interrupted()
            let flags = event.flags.intersection([.maskCommand, .maskControl])
            if code == 51 { onBackspace?() } else if flags.isEmpty, let text = Self.characters(of: event) { onTyped?(text) }
            return true

        case .otherMouseDown:
            modifiers.interrupted()
            onClick?()
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if needs.strokeButtons.contains(button) {
                stroke = (button, [event.location])
                return false
            }
            if needs.buttons.contains(button), handle?(.mouseButton(button)) == true {
                swallowedUp.insert(button)
                return false
            }
            return true

        case .rightMouseDown:
            modifiers.interrupted()
            onClick?()
            guard needs.strokeButtons.contains(1) else { return true }
            stroke = (1, [event.location])
            return false

        case .rightMouseDragged, .otherMouseDragged:
            guard stroke != nil else { return true }
            stroke?.points.append(event.location)
            return false

        case .rightMouseUp, .otherMouseUp:
            let button = type == .rightMouseUp ? 1 : Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if swallowedUp.remove(button) != nil { return false }
            guard let current = stroke, current.button == button else { return true }
            stroke = nil
            let path = StrokeRecognizer.path(of: current.points)
            if path.isEmpty || handle?(.stroke(button: button, path: path)) != true {
                // Not a stroke after all: send the click it would have been.
                replayClick(button: button, at: current.points[0])
            }
            return false

        case .leftMouseDown:
            modifiers.interrupted()
            onClick?()
            guard needs.clicks, let gesture = MultitouchReader.shared.clickGesture(), handle?(gesture) == true else { return true }
            swallowedUp.insert(0)
            return false

        case .leftMouseUp:
            return swallowedUp.remove(0) == nil

        default:
            return true
        }
    }

    private func replayClick(button: Int, at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let (downType, upType, mouseButton): (CGEventType, CGEventType, CGMouseButton) = button == 1
            ? (.rightMouseDown, .rightMouseUp, .right) : (.otherMouseDown, .otherMouseUp, .center)
        for type in [downType, upType] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton) else { continue }
            if button > 1 { event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
            event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func characters(of event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: buffer, count: length)
        return text.unicodeScalars.allSatisfy({ $0.value >= 32 }) ? text : nil
    }
}

private func gestureTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<GestureEventTap>.fromOpaque(refcon).takeUnretainedValue()
    let pass = MainActor.assumeIsolated { tap.process(type, event) }
    return pass ? Unmanaged.passUnretained(event) : nil
}
