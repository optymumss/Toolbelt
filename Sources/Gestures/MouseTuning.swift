import AppKit
import SwiftUI

// 0.39: an ordinary mouse's wheel, like BetterTouchTool's "normal mouse" settings:
// - smooth scrolling: each notch of the wheel glides instead of jumping;
// - its own direction: reverse the mouse while the trackpad keeps macOS's "natural" setting;
// - its own speed.
// Only wheel notches are changed (macOS marks trackpad and Magic Mouse scrolls as "continuous", and
// those are left alone). Toolbelt only listens while one of these is switched on.

/// The settings, kept together so "all off" is easy to tell.
struct MouseTuning: Equatable {
    var smooth = false
    var reverse = false
    /// 0.5 (slower) … 3 (faster); 1 is macOS's own speed.
    var speed = 1.0

    var isNeutral: Bool { !smooth && !reverse && abs(speed - 1) < 0.01 }

    /// "smooth,reverse,speed" (the test command's format), e.g. "1,0,1.5".
    init(smooth: Bool = false, reverse: Bool = false, speed: Double = 1) {
        self.smooth = smooth
        self.reverse = reverse
        self.speed = speed
    }

    init?(text: String) {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, let speed = Double(parts[2]) else { return nil }
        self.init(smooth: parts[0] == "1", reverse: parts[1] == "1", speed: min(3, max(0.5, speed)))
    }

    @MainActor static var saved: MouseTuning {
        get {
            let store = SettingsStore.shared
            return MouseTuning(smooth: store.value("mouse.smooth", default: false), reverse: store.value("mouse.reverse", default: false),
                               speed: store.value("mouse.speed", default: 1.0))
        }
        set {
            let store = SettingsStore.shared
            store.set(newValue.smooth, for: "mouse.smooth")
            store.set(newValue.reverse, for: "mouse.reverse")
            store.set(newValue.speed, for: "mouse.speed")
        }
    }

    /// One notch, changed for direction and speed (when not smooth): lines and points, per axis.
    func adjusted(lines: Int64, points: Double) -> (lines: Int64, points: Double) {
        let sign: Double = reverse ? -1 : 1
        var newLines = Double(lines) * speed * sign
        // A notch always moves at least one line, so slow speeds never swallow it.
        if lines != 0, abs(newLines) < 1 { newLines = newLines < 0 ? -1 : 1 }
        return (Int64(newLines.rounded()), points * speed * sign)
    }

    /// How far one notch glides when smooth, in pixels (macOS's own amount, or 40 pixels a line).
    func glide(lines: Int64, points: Double) -> Double {
        let base = abs(points) >= 1 ? points : Double(lines) * 40
        return base * speed * (reverse ? -1 : 1)
    }
}

/// Turns notches into a glide: each one adds to the distance still to go, and every frame covers part
/// of what's left, so the scroll eases out. Pure: the frames are timed by the caller.
struct ScrollSmoother: Equatable {
    /// Pixels still to scroll, down/up and left/right.
    private(set) var remainingY = 0.0
    private(set) var remainingX = 0.0
    /// Fractions of a pixel carried over to the next frame.
    private var carryY = 0.0
    private var carryX = 0.0
    /// How quickly the glide settles (seconds); smaller is snappier.
    var settle = 0.07

    var isIdle: Bool { remainingY == 0 && remainingX == 0 }

    mutating func add(vertical: Double, horizontal: Double) {
        remainingY += vertical
        remainingX += horizontal
    }

    /// The whole pixels to scroll this frame (`dt` seconds since the last one).
    mutating func step(dt: Double) -> (dy: Int32, dx: Int32) {
        let part = 1 - exp(-max(0, dt) / settle)
        func take(_ remaining: inout Double, _ carry: inout Double) -> Int32 {
            guard remaining != 0 else { return 0 }
            var move = remaining * part
            // The last bit goes all at once, so a glide always ends.
            if abs(remaining - move) < 0.5 { move = remaining }
            remaining -= move
            if abs(remaining) < 0.000_1 { remaining = 0 }
            let total = move + carry
            let whole = total.rounded(.towardZero)
            carry = total - whole
            if remaining == 0 { carry = 0 }
            return Int32(whole)
        }
        return (take(&remainingY, &carryY), take(&remainingX, &carryX))
    }

    mutating func stop() { self = ScrollSmoother(settle: settle) }

    init(settle: Double = 0.07) { self.settle = settle }
}

/// Watches the mouse wheel while a setting needs it and changes or smooths its notches.
@MainActor
final class MouseTuner {
    static let shared = MouseTuner()

    private(set) var tuning = MouseTuning()
    private var tap: (port: CFMachPort, source: CFRunLoopSource)?
    private var running = false
    private var smoother = ScrollSmoother()
    private var timer: Timer?
    private var lastFrame = 0.0
    private var lastLocation = CGPoint.zero
    /// Glide frames sent so far (for the real-use test).
    private(set) var glideEvents = 0

    var isListening: Bool { tap != nil }

    func refresh() { update(running: running) }

    func update(running: Bool) {
        self.running = running
        tuning = MouseTuning.saved
        let wants = running && !tuning.isNeutral
        if wants, tap == nil {
            guard PermissionGate.ensure(.accessibility, to: "change how the mouse wheel scrolls") else { return }
            tap = makeTap()
        } else if !wants, let current = tap {
            CGEvent.tapEnable(tap: current.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), current.source, .commonModes)
            tap = nil
            stopGlide()
        }
        if !tuning.smooth { stopGlide() }
        RealUseHooks.writeStatus()
    }

    static func registerTestHooks() {
        RealUseHooks.commands["mouse-tuning"] = { text in
            guard let tuning = MouseTuning(text: text) else { return }
            MouseTuning.saved = tuning
            shared.refresh()
        }
        RealUseHooks.extraStatus["mouseTuning"] = { shared.isListening ? "on" : "off" }
        RealUseHooks.extraStatus["mouseGlideEvents"] = { shared.glideEvents }
    }

    private func makeTap() -> (port: CFMachPort, source: CFRunLoopSource)? {
        let mask: UInt64 = 1 << CGEventType.scrollWheel.rawValue
        let me = Unmanaged.passUnretained(self).toOpaque()
        // At the end of the line, so wheel triggers (tilt, hold and scroll) still see the real notch first.
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: mouseTuningCallback, userInfo: me),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, source)
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap.port, enable: true) }
    }

    /// Returns the event to pass on (nil to keep it back).
    fileprivate func process(_ event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != GestureEventTap.ownEventMarker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return event }
        let linesY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let linesX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let pointsY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let pointsX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        if tuning.smooth {
            smoother.add(vertical: tuning.glide(lines: linesY, points: pointsY), horizontal: tuning.glide(lines: linesX, points: pointsX))
            lastLocation = event.location
            startGlide()
            return nil
        }
        let y = tuning.adjusted(lines: linesY, points: pointsY)
        let x = tuning.adjusted(lines: linesX, points: pointsX)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: y.lines)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: x.lines)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y.points)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x.points)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(y.lines))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(x.lines))
        return event
    }

    private func startGlide() {
        guard timer == nil else { return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopGlide() {
        timer?.invalidate()
        timer = nil
        smoother.stop()
    }

    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        let (dy, dx) = smoother.step(dt: now - lastFrame)
        lastFrame = now
        if dy != 0 || dx != 0,
           let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: GestureEventTap.ownEventMarker)
            event.location = lastLocation
            event.post(tap: .cgSessionEventTap)
            glideEvents += 1
        }
        if smoother.isIdle {
            timer?.invalidate()
            timer = nil
            RealUseHooks.writeStatus()
        }
    }
}

private func mouseTuningCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tuner = Unmanaged<MouseTuner>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tuner.reenable()
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        return tuner.process(event).map { Unmanaged.passUnretained($0) }
    }
}

// MARK: - Settings

struct MouseTuningSettings: View {
    @State private var tuning = MouseTuning.saved

    var body: some View {
        Section {
            Toggle("Smooth scrolling", isOn: $tuning.smooth)
            Toggle("Scroll the other way from the trackpad", isOn: $tuning.reverse)
            LabeledContent("Scrolling speed") {
                HStack {
                    Text("Slower").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $tuning.speed, in: 0.5...3, step: 0.25).frame(maxWidth: 220)
                    Text("Faster").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2g×", tuning.speed)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
        } header: {
            Text("Ordinary mouse")
        } footer: {
            Text("For a mouse with a wheel that clicks as it turns (including most Logitech mice). The trackpad and Magic Mouse aren't changed. “The other way” lets the trackpad keep macOS's natural scrolling while the wheel scrolls the classic way. Needs Accessibility.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: tuning) { _, value in
            MouseTuning.saved = value
            MouseTuner.shared.refresh()
        }
    }
}
