import AppKit

// The gestures Toolbelt recognises, and the pure logic that recognises them. Kept free of any
// device code so it can be tested with made-up touches, strokes and key presses.

// MARK: - What happened

enum TouchSource: String, Codable, CaseIterable, Identifiable {
    case trackpad, magicMouse

    var id: String { rawValue }
    var title: String { self == .trackpad ? "Trackpad" : "Magic Mouse" }
}

enum TouchKind: String, Codable, CaseIterable, Identifiable {
    case tap, click, swipeLeft, swipeRight, swipeUp, swipeDown, pinchIn, pinchOut
    case cornerTopLeft, cornerTopRight, cornerBottomLeft, cornerBottomRight
    case doubleTap, scrollLeft, scrollRight, scrollUp, scrollDown
    /// One-finger taps near an edge or corner of the trackpad.
    case tapTopLeft, tapTopMiddle, tapTopRight, tapLeftMiddle, tapRightMiddle, tapBottomLeft, tapBottomMiddle, tapBottomRight
    /// One-finger taps on the left, right or middle of the Magic Mouse, and clicking with a finger in the middle.
    case tapLeft, tapRight, tapMiddle, clickMiddle
    /// Rest one or more fingers and tap another to their left or right ("fingers" counts them all).
    case tipTapLeft, tipTapRight
    /// The moment that many fingers touch; holding them still for a while; a tap high or low on the
    /// trackpad; and a Force Click (pressing harder until the second click).
    case touchStart, longTouch, tapTop, tapBottom, forceClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap: return "Tap"
        case .click: return "Click"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .pinchIn: return "Pinch in"
        case .pinchOut: return "Pinch out"
        case .cornerTopLeft: return "Click top-left corner"
        case .cornerTopRight: return "Click top-right corner"
        case .cornerBottomLeft: return "Click bottom-left corner"
        case .cornerBottomRight: return "Click bottom-right corner"
        case .doubleTap: return "Double tap"
        case .scrollLeft: return "Scroll left (repeats while sliding)"
        case .scrollRight: return "Scroll right (repeats while sliding)"
        case .scrollUp: return "Scroll up (repeats while sliding)"
        case .scrollDown: return "Scroll down (repeats while sliding)"
        case .tapTopLeft: return "Tap top-left corner"
        case .tapTopMiddle: return "Tap top middle"
        case .tapTopRight: return "Tap top-right corner"
        case .tapLeftMiddle: return "Tap left side, middle"
        case .tapRightMiddle: return "Tap right side, middle"
        case .tapBottomLeft: return "Tap bottom-left corner"
        case .tapBottomMiddle: return "Tap bottom middle"
        case .tapBottomRight: return "Tap bottom-right corner"
        case .tapLeft: return "Tap on the left"
        case .tapRight: return "Tap on the right"
        case .tapMiddle: return "Tap in the middle"
        case .clickMiddle: return "Click in the middle"
        case .tipTapLeft: return "TipTap left"
        case .tipTapRight: return "TipTap right"
        case .touchStart: return "Touch start"
        case .longTouch: return "Long touch (hold still)"
        case .tapTop: return "Tap near the top"
        case .tapBottom: return "Tap near the bottom"
        case .forceClick: return "Force Click (experimental)"
        }
    }

    var isCorner: Bool { rawValue.hasPrefix("corner") }
    /// Gestures always made with one finger in a particular place: the finger count isn't asked for.
    var isPlaced: Bool {
        switch self {
        case .cornerTopLeft, .cornerTopRight, .cornerBottomLeft, .cornerBottomRight,
             .tapTopLeft, .tapTopMiddle, .tapTopRight, .tapLeftMiddle, .tapRightMiddle, .tapBottomLeft, .tapBottomMiddle, .tapBottomRight,
             .tapLeft, .tapRight, .tapMiddle, .clickMiddle:
            return true
        default:
            return false
        }
    }
    var isTipTap: Bool { self == .tipTapLeft || self == .tipTapRight }

    /// What can be done with each number of fingers on a device, for the gesture picker.
    static func choices(for source: TouchSource) -> [(fingers: Int, kinds: [TouchKind])] {
        let swipes: [TouchKind] = [.swipeUp, .swipeDown, .swipeLeft, .swipeRight]
        let scrolls: [TouchKind] = [.scrollUp, .scrollDown, .scrollLeft, .scrollRight]
        switch source {
        case .trackpad:
            let held: [TouchKind] = [.touchStart, .longTouch]
            return [
                (1, [.tap, .doubleTap, .tapTopLeft, .tapTopMiddle, .tapTopRight, .tapLeftMiddle, .tapRightMiddle,
                     .tapBottomLeft, .tapBottomMiddle, .tapBottomRight, .cornerTopLeft, .cornerTopRight, .cornerBottomLeft, .cornerBottomRight,
                     .forceClick] + held),
                (2, [.tap, .doubleTap, .tapTop, .tapBottom, .tipTapLeft, .tipTapRight] + swipes + [.pinchIn, .pinchOut] + held),
                (3, [.tap, .doubleTap, .tapTop, .tapBottom, .click, .forceClick, .tipTapLeft, .tipTapRight] + swipes + scrolls + [.pinchIn, .pinchOut] + held),
                (4, [.tap, .doubleTap, .tapTop, .tapBottom, .click, .tipTapLeft, .tipTapRight] + swipes + scrolls + [.pinchIn, .pinchOut] + held),
                (5, [.tap, .doubleTap, .tapTop, .tapBottom, .click] + swipes + scrolls + [.pinchIn, .pinchOut] + held),
            ]
        case .magicMouse:
            return [
                (1, [.tap, .doubleTap, .tapLeft, .tapRight, .tapMiddle, .clickMiddle, .longTouch]),
                (2, [.tap, .doubleTap, .click, .tipTapLeft, .tipTapRight] + swipes + scrolls + [.pinchIn, .pinchOut]),
                (3, [.tap, .doubleTap, .click, .tipTapLeft, .tipTapRight] + swipes + scrolls),
                (4, [.tap, .click] + swipes),
            ]
        }
    }
    /// Fires again and again while the fingers keep sliding, rather than once per touch.
    var isScroll: Bool { rawValue.hasPrefix("scroll") }
}

enum ModifierKey: String, Codable, CaseIterable, Identifiable {
    case shift, leftShift, rightShift, command, leftCommand, rightCommand
    case option, leftOption, rightOption, control, leftControl, rightControl, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: return "⇧ Shift (either)"
        case .leftShift: return "Left ⇧ Shift"
        case .rightShift: return "Right ⇧ Shift"
        case .command: return "⌘ Command (either)"
        case .leftCommand: return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .option: return "⌥ Option (either)"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .control: return "⌃ Control (either)"
        case .leftControl: return "Left ⌃ Control"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "fn / 🌐"
        }
    }

    /// The physical key, from a key code (flagsChanged events).
    static func side(forKeyCode code: Int) -> ModifierKey? {
        switch code {
        case 56: return .leftShift
        case 60: return .rightShift
        case 55: return .leftCommand
        case 54: return .rightCommand
        case 58: return .leftOption
        case 61: return .rightOption
        case 59: return .leftControl
        case 62: return .rightControl
        case 63: return .fn
        default: return nil
        }
    }

    /// Whether a rule for this key is met by pressing `pressed` (a specific side).
    func accepts(_ pressed: ModifierKey) -> Bool {
        switch self {
        case .shift: return pressed == .leftShift || pressed == .rightShift
        case .command: return pressed == .leftCommand || pressed == .rightCommand
        case .option: return pressed == .leftOption || pressed == .rightOption
        case .control: return pressed == .leftControl || pressed == .rightControl
        default: return self == pressed
        }
    }

    /// The flag macOS sets while the key is down.
    var flag: CGEventFlags {
        switch self {
        case .shift, .leftShift, .rightShift: return .maskShift
        case .command, .leftCommand, .rightCommand: return .maskCommand
        case .option, .leftOption, .rightOption: return .maskAlternate
        case .control, .leftControl, .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }
}

/// One gesture that happened (or that a rule waits for).
enum Gesture: Codable, Hashable {
    case touch(TouchSource, TouchKind, fingers: Int)
    /// 2 = middle button, 3 = back, 4 = forward, and so on.
    case mouseButton(Int)
    /// Hold a mouse button (1 = right, 2 = middle) and draw, e.g. "L" or "DR" (up, down, left, right).
    case stroke(button: Int, path: String)
    case modifierTap(ModifierKey, taps: Int)
    case keySequence(String)
    /// A keyboard shortcut: a key with ⌘ ⌥ ⌃ ⇧ (Carbon modifier flags).
    case shortcut(keyCode: Int, modifiers: Int)

    var title: String {
        switch self {
        case let .touch(source, kind, fingers):
            if kind.isPlaced { return "\(source.title): \(kind.title)" }
            if kind.isTipTap { return "\(source.title): \(kind.title) (\(fingers - 1) resting, tap with one more)" }
            return "\(source.title): \(kind.title) with \(fingers) finger\(fingers == 1 ? "" : "s")"
        case .mouseButton(let button): return "Mouse button \(button + 1)"
        case let .stroke(button, path):
            let arrows = path.map { ["U": "↑", "D": "↓", "L": "←", "R": "→"][String($0)] ?? "" }.joined()
            return "Hold \(button == 2 ? "middle" : "right") button and draw \(arrows)"
        case let .modifierTap(key, taps): return "\(taps == 2 ? "Double-tap" : "Tap") \(key.title)"
        case .keySequence(let keys): return "Type “\(keys)”"
        case let .shortcut(keyCode, modifiers):
            return keyCode == 0 && modifiers == 0 ? "Keyboard shortcut (not set)" : Shortcut(keyCode: keyCode, modifiers: modifiers).display
        }
    }

    /// For a tap or a double tap: the double-tap gesture with the same key or fingers.
    var doubleTapVersion: Gesture? {
        switch self {
        case let .modifierTap(key, _): return .modifierTap(key, taps: 2)
        case let .touch(source, .tap, fingers), let .touch(source, .doubleTap, fingers): return .touch(source, .doubleTap, fingers: fingers)
        default: return nil
        }
    }

    /// Whether this rule's gesture is met by what happened.
    func accepts(_ event: Gesture) -> Bool {
        switch (self, event) {
        case let (.modifierTap(rule, ruleTaps), .modifierTap(pressed, taps)):
            return ruleTaps == taps && rule.accepts(pressed)
        case let (.touch(source, kind, fingers), .touch(eventSource, eventKind, eventFingers)):
            return source == eventSource && kind == eventKind && (kind.isPlaced || fingers == eventFingers)
        default:
            return self == event
        }
    }
}

// MARK: - Trackpad and Magic Mouse

/// One finger on the surface, at a position from 0 to 1 (x to the right, y up).
struct TouchPoint: Equatable {
    var id: Int
    var x: Double
    var y: Double
}

/// Turns the stream of touches from one trackpad or Magic Mouse into taps, swipes and pinches.
/// Taps, swipes and pinches fire once per touch: from the first finger down to the last finger up.
/// Scrolls (when `scrolls` is on) fire once for every `scrollStep` the fingers slide, for as long
/// as they keep sliding, and in the other direction when they slide back.
struct TouchRecognizer {
    let source: TouchSource
    /// How far (0–1 of the surface) the fingers must move together for a swipe.
    var swipeDistance = 0.14
    /// A tap is shorter than this and barely moves.
    var tapTime = 0.3
    var tapMovement = 0.035
    /// A second tap with the same fingers starting this soon after the first one ends is a double tap.
    var doubleTapGap = 0.35
    /// Whether to report scrolls. Off, the recognizer behaves exactly as before scrolls existed.
    var scrolls = false
    /// How far the fingers slide for each scroll step (about 22 steps across the whole trackpad).
    var scrollStep = 0.045
    /// Movement before a scroll picks its direction (across or up and down) for the rest of the touch.
    var scrollLock = 0.025

    private var started: Double?
    private var maxFingers = 0
    private var firstPositions: [Int: TouchPoint] = [:]
    private var moved = 0.0
    private var fired = false
    private var countStart: (count: Int, centre: (Double, Double), spread: Double)?
    private var countSince: Double = 0
    private var previousCount = 0
    private var longTouched = false
    /// Fingers held this still for this long are a long touch.
    var longTouchTime = 0.6
    /// Whether to report touch starts and long touches (only while a rule uses them).
    var holds = false
    /// Where the last scroll step was counted from, and whether scrolling goes across (true) or up and down.
    private var scrollAnchor: (Double, Double)?
    private var scrollAcross: Bool?
    private var scrolled = false
    private var lastTap: (fingers: Int, ended: Double)?
    /// When each finger touched down (for TipTaps), and the fingers of the last frame.
    private var firstSeen: [Int: Double] = [:]
    private var previous: [TouchPoint] = []
    /// A finger rests this long before another one tapping beside it is a TipTap.
    var tipTapRest = 0.12
    /// The latest touches, for working out clicks with several fingers or in a corner.
    private(set) var current: [TouchPoint] = []

    init(source: TouchSource) {
        self.source = source
    }

    /// Sensitivity: 1 is normal; above 1 needs longer slides and quicker, stiller taps; below 1 the opposite.
    mutating func tune(_ sensitivity: Double) {
        let s = min(max(sensitivity, 0.5), 2)
        swipeDistance = 0.14 * s
        scrollStep = 0.045 * s
        tapMovement = 0.035 / s
        tapTime = 0.3 / s.squareRoot()
    }

    /// Feeds one frame of touches; returns a gesture if one was just completed (the first, if several were).
    mutating func feed(_ touches: [TouchPoint], at time: Double) -> Gesture? {
        feedAll(touches, at: time).first
    }

    /// Feeds one frame of touches; returns every gesture it completed, in order. A second tap
    /// gives both a tap and a double tap; a quick slide can give several scroll steps.
    mutating func feedAll(_ touches: [TouchPoint], at time: Double) -> [Gesture] {
        current = touches
        if touches.isEmpty {
            defer { reset() }
            guard let started, !fired, !scrolled, maxFingers >= 1 else { return [] }
            let short = time - started <= tapTime
            guard short, moved <= tapMovement else { return [] }
            var gestures: [Gesture] = [.touch(source, .tap, fingers: maxFingers)]
            if maxFingers == 1, let finger = firstPositions.values.first, let placed = placedTap(finger) {
                gestures.append(.touch(source, placed, fingers: 1))
            }
            if maxFingers >= 2, source == .trackpad {
                let height = firstPositions.values.reduce(0) { $0 + $1.y } / Double(firstPositions.count)
                if height > 0.66 { gestures.append(.touch(source, .tapTop, fingers: maxFingers)) }
                if height < 0.33 { gestures.append(.touch(source, .tapBottom, fingers: maxFingers)) }
            }
            if let previous = lastTap, previous.fingers == maxFingers, started - previous.ended <= doubleTapGap {
                gestures.append(.touch(source, .doubleTap, fingers: maxFingers))
                lastTap = nil
            } else {
                lastTap = (maxFingers, time)
            }
            return gestures
        }
        if started == nil { started = time }
        let tipTap = tipTapCheck(touches, at: time)
        maxFingers = max(maxFingers, touches.count)
        for touch in touches {
            if let first = firstPositions[touch.id] {
                moved = max(moved, hypot(touch.x - first.x, touch.y - first.y))
            } else {
                firstPositions[touch.id] = touch
            }
        }

        // Measure movement from when the number of fingers last changed.
        let centre = Self.centre(of: touches)
        let spread = Self.spread(of: touches, around: centre)
        guard let start = countStart, start.count == touches.count else {
            // More fingers than a moment ago: "touch start" for that many.
            let added = touches.count > previousCount
            previousCount = touches.count
            countStart = (touches.count, centre, spread)
            countSince = time
            longTouched = false
            scrollAnchor = centre
            scrollAcross = nil
            var gestures = tipTap.map { [$0] } ?? []
            if added, holds { gestures.append(.touch(source, .touchStart, fingers: touches.count)) }
            return gestures
        }
        let count = touches.count
        var gestures = scrolls ? scrollSteps(at: centre, from: start.centre, fingers: count) : []
        if let tipTap { gestures.insert(tipTap, at: 0) }
        guard !fired else { return gestures }
        // Held still: a long touch (once), and nothing else for this touch.
        if holds, !longTouched, time - countSince >= longTouchTime,
           hypot(centre.0 - start.centre.0, centre.1 - start.centre.1) < tapMovement, moved < tapMovement * 2 {
            longTouched = true
            fired = true
            return gestures + [.touch(source, .longTouch, fingers: count)]
        }

        if count >= 2, start.spread > 0.02 {
            let ratio = spread / start.spread
            let travel = hypot(centre.0 - start.centre.0, centre.1 - start.centre.1)
            if travel < swipeDistance * 0.6 {
                if ratio < 0.6 { fired = true; return gestures + [.touch(source, .pinchIn, fingers: count)] }
                if ratio > 1.6 { fired = true; return gestures + [.touch(source, .pinchOut, fingers: count)] }
            }
        }
        let dx = centre.0 - start.centre.0, dy = centre.1 - start.centre.1
        guard max(abs(dx), abs(dy)) >= swipeDistance else { return gestures }
        fired = true
        let kind: TouchKind = abs(dx) > abs(dy) ? (dx < 0 ? .swipeLeft : .swipeRight) : (dy > 0 ? .swipeUp : .swipeDown)
        return gestures + [.touch(source, kind, fingers: count)]
    }

    /// Which place a one-finger tap was in, if it was near an edge (trackpad) or to one side (Magic Mouse).
    func placedTap(_ finger: TouchPoint) -> TouchKind? {
        if source == .magicMouse {
            return finger.x < 0.4 ? .tapLeft : finger.x > 0.6 ? .tapRight : .tapMiddle
        }
        let left = finger.x < 0.2, right = finger.x > 0.8, top = finger.y > 0.8, bottom = finger.y < 0.2
        let across = finger.x > 0.35 && finger.x < 0.65, upDown = finger.y > 0.35 && finger.y < 0.65
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .tapTopLeft
        case (_, true, true, _): return .tapTopRight
        case (true, _, _, true): return .tapBottomLeft
        case (_, true, _, true): return .tapBottomRight
        case (_, _, true, _) where across: return .tapTopMiddle
        case (_, _, _, true) where across: return .tapBottomMiddle
        case (true, _, _, _) where upDown: return .tapLeftMiddle
        case (_, true, _, _) where upDown: return .tapRightMiddle
        default: return nil
        }
    }

    /// A finger that came and went quickly while others rested: a TipTap to their left or right.
    private mutating func tipTapCheck(_ touches: [TouchPoint], at time: Double) -> Gesture? {
        defer { previous = touches }
        for touch in touches where firstSeen[touch.id] == nil { firstSeen[touch.id] = time }
        let ids = Set(touches.map(\.id))
        guard !touches.isEmpty, let gone = previous.first(where: { !ids.contains($0.id) }),
              let landed = firstSeen[gone.id], time - landed <= tapTime else { return nil }
        firstSeen[gone.id] = nil
        let start = firstPositions[gone.id] ?? gone
        guard hypot(gone.x - start.x, gone.y - start.y) <= tapMovement else { return nil }
        // Every remaining finger was down (and still) well before the tapping one.
        for finger in touches {
            guard let since = firstSeen[finger.id], landed - since >= tipTapRest,
                  let first = firstPositions[finger.id], hypot(finger.x - first.x, finger.y - first.y) <= tapMovement * 2 else { return nil }
        }
        fired = true // not also a swipe or a pinch
        let resting = touches.reduce(0) { $0 + $1.x } / Double(touches.count)
        return .touch(source, start.x < resting ? .tipTapLeft : .tipTapRight, fingers: touches.count + 1)
    }

    private mutating func scrollSteps(at centre: (Double, Double), from start: (Double, Double), fingers: Int) -> [Gesture] {
        if scrollAcross == nil {
            let dx = centre.0 - start.0, dy = centre.1 - start.1
            guard max(abs(dx), abs(dy)) >= scrollLock else { return [] }
            scrollAcross = abs(dx) > abs(dy)
        }
        guard let across = scrollAcross, var anchor = scrollAnchor else { return [] }
        var gestures: [Gesture] = []
        // At most a trackpad's width of steps in one frame, so a glitch can't run away.
        for _ in 0..<30 {
            let delta = across ? centre.0 - anchor.0 : centre.1 - anchor.1
            guard abs(delta) >= scrollStep else { break }
            let step = delta > 0 ? scrollStep : -scrollStep
            if across { anchor.0 += step } else { anchor.1 += step }
            let kind: TouchKind = across ? (step < 0 ? .scrollLeft : .scrollRight) : (step > 0 ? .scrollUp : .scrollDown)
            gestures.append(.touch(source, kind, fingers: fingers))
        }
        scrollAnchor = anchor
        if !gestures.isEmpty { scrolled = true }
        return gestures
    }

    /// The gesture for a physical click right now: several fingers, or one finger in a corner.
    func click() -> Gesture? {
        guard !current.isEmpty else { return nil }
        if source == .magicMouse {
            // One finger on the left or right is an ordinary click; in the middle, or with more fingers, it's a gesture.
            if current.count == 1, let finger = current.first, finger.x > 0.35, finger.x < 0.65 {
                return .touch(source, .clickMiddle, fingers: 1)
            }
            return current.count >= 2 ? .touch(source, .click, fingers: current.count) : nil
        }
        if current.count == 1, let finger = current.first {
            let left = finger.x < 0.2, right = finger.x > 0.8, top = finger.y > 0.8, bottom = finger.y < 0.2
            switch (left, right, top, bottom) {
            case (true, _, true, _): return .touch(source, .cornerTopLeft, fingers: 1)
            case (_, true, true, _): return .touch(source, .cornerTopRight, fingers: 1)
            case (true, _, _, true): return .touch(source, .cornerBottomLeft, fingers: 1)
            case (_, true, _, true): return .touch(source, .cornerBottomRight, fingers: 1)
            default: return nil
            }
        }
        return current.count >= 3 ? .touch(source, .click, fingers: current.count) : nil
    }

    private mutating func reset() {
        started = nil
        maxFingers = 0
        firstPositions = [:]
        moved = 0
        fired = false
        countStart = nil
        scrollAnchor = nil
        scrollAcross = nil
        scrolled = false
        firstSeen = [:]
        previous = []
        previousCount = 0
        longTouched = false
    }

    static func centre(of touches: [TouchPoint]) -> (Double, Double) {
        let n = Double(touches.count)
        return (touches.reduce(0) { $0 + $1.x } / n, touches.reduce(0) { $0 + $1.y } / n)
    }

    static func spread(of touches: [TouchPoint], around centre: (Double, Double)) -> Double {
        touches.reduce(0) { $0 + hypot($1.x - centre.0, $1.y - centre.1) } / Double(touches.count)
    }
}

// MARK: - Mouse strokes

/// Turns the path of the mouse (screen points, y down) into directions like "L" or "DR".
enum StrokeRecognizer {
    /// Moves shorter than this don't count as a direction.
    static let step: CGFloat = 40

    static func path(of points: [CGPoint]) -> String {
        guard var anchor = points.first else { return "" }
        var directions = ""
        for point in points.dropFirst() {
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            guard max(abs(dx), abs(dy)) >= step else { continue }
            let direction: Character = abs(dx) > abs(dy) ? (dx < 0 ? "L" : "R") : (dy < 0 ? "U" : "D")
            if directions.last != direction { directions.append(direction) }
            anchor = point
        }
        return directions
    }
}

// MARK: - Tapping modifier keys

/// Spots a modifier key pressed and let go on its own, quickly, and two such taps in a row.
struct ModifierTapDetector {
    var tapTime = 0.35
    var doubleTapGap = 0.4

    private var down: (key: ModifierKey, time: Double)?
    private var lastTap: (key: ModifierKey, time: Double)?

    /// A modifier key went down or up (`flags` is every modifier held afterwards).
    mutating func modifierChanged(_ key: ModifierKey, flags: CGEventFlags, at time: Double) -> Gesture? {
        let isDown = flags.contains(key.flag)
        let others: CGEventFlags = [.maskShift, .maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn]
        let otherHeld = !flags.intersection(others.subtracting(key.flag)).isEmpty
        if isDown {
            down = otherHeld ? nil : (key, time)
            return nil
        }
        guard let pressed = down, pressed.key == key, time - pressed.time <= tapTime else {
            down = nil
            return nil
        }
        down = nil
        if let previous = lastTap, previous.key == key, time - previous.time <= doubleTapGap {
            lastTap = nil
            return .modifierTap(key, taps: 2)
        }
        lastTap = (key, time)
        return .modifierTap(key, taps: 1)
    }

    /// Any other key or click cancels a tap in progress.
    mutating func interrupted() {
        down = nil
        lastTap = nil
    }
}

// MARK: - Which rule applies

/// The moments a trigger can run actions at, besides when it's first triggered.
enum TriggerPhase: String, Codable, CaseIterable, Identifiable {
    case release, longHold, quickRelease, releaseAfterLongHold, modifiersReleased

    var id: String { rawValue }

    func title(keyboard: Bool) -> String {
        switch self {
        case .release: return keyboard ? "On key release" : "When the fingers lift"
        case .longHold: return keyboard ? "On long key hold" : "On long hold"
        case .quickRelease: return "On quick release"
        case .releaseAfterLongHold: return "On release after a long hold"
        case .modifiersReleased: return "After all modifier keys are released"
        }
    }

    static func available(keyboard: Bool) -> [TriggerPhase] { keyboard ? allCases : [.release] }
}

/// Matching a key press against a keyboard-shortcut trigger that watches the keyboard itself.
enum ShortcutMatch {
    /// The device-specific bits macOS sets for each side's modifier key.
    static let leftControl = 0x01, leftShift = 0x02, rightShift = 0x04, leftCommand = 0x08, rightCommand = 0x10
    static let leftOption = 0x20, rightOption = 0x40, rightControl = 0x2000
    static let sideMask = 0x207F

    /// ⌘ ⌥ ⌃ ⇧ from event flags, as Carbon modifier bits (what shortcuts are stored with).
    static func carbonModifiers(_ flags: UInt64) -> Int {
        var modifiers = 0
        if flags & CGEventFlags.maskCommand.rawValue != 0 { modifiers |= 256 }
        if flags & CGEventFlags.maskShift.rawValue != 0 { modifiers |= 512 }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { modifiers |= 2048 }
        if flags & CGEventFlags.maskControl.rawValue != 0 { modifiers |= 4096 }
        return modifiers
    }

    static func matches(_ rule: GestureRule, keyCode: Int, flags: UInt64, character: String?) -> Bool {
        guard case let .shortcut(ruleKey, ruleModifiers) = rule.gesture, ruleKey != 0 || ruleModifiers != 0 else { return false }
        guard carbonModifiers(flags) == ruleModifiers else { return false }
        if rule.followLayout == true, let wanted = rule.keyCharacter, !wanted.isEmpty {
            guard let character, character.lowercased() == wanted.lowercased() else { return false }
        } else if keyCode != ruleKey {
            return false
        }
        if rule.distinguishSides == true, let sides = rule.sideFlags, sides & sideMask != 0 {
            // Each side recorded must be the one held now.
            guard Int(flags) & sides & sideMask == sides & sideMask else { return false }
        }
        return true
    }
}

/// One gesture and what it does, optionally only in (or except in) certain apps.
struct GestureRule: Identifiable, Codable, Equatable {
    enum AppScope: String, Codable, CaseIterable, Identifiable {
        case everywhere, only, except

        var id: String { rawValue }
        var title: String {
            switch self {
            case .everywhere: return "In every app"
            case .only: return "Only in"
            case .except: return "Everywhere except"
            }
        }
    }

    var id = UUID()
    var gesture: Gesture
    var action: MacroAction
    var enabled = true
    var scope: AppScope = .everywhere
    /// Bundle identifiers, such as com.apple.Safari.
    var apps: [String] = []
    /// For typed sequences: delete what was typed before running the action.
    var deleteTyped = true
    /// Further actions, run after `action` in order. Optional so rules saved before it existed still load.
    var moreActions: [MacroAction]? = nil
    /// Your own note about what it's for; shown instead of the description when `showNotes` is on.
    var notes: String? = nil
    var showNotes: Bool? = nil
    /// Show a small on-screen message when it runs.
    var showHUD: Bool? = nil
    /// When other triggers match at the same time, run alongside them instead of only the best match.
    var parallel: Bool? = nil
    /// Keyboard triggers ignore themselves for a moment after running, so an action that presses their
    /// own keys can't set them off again and again. On unless switched off.
    var preventRecursion: Bool? = nil
    /// Only while this activation group's conditions are true.
    var groupID: UUID? = nil
    /// Its own conditions ("Advanced conditions"), checked when it's triggered.
    var condition: ConditionGroup? = nil
    /// Actions for other moments: when the keys or fingers are let go, held a while, and so on.
    var phaseActions: [TriggerPhase: [MacroAction]]? = nil
    /// Run the actions again and again while the keys are held or the fingers stay down.
    var repeatWhileHeld: Bool? = nil
    /// Repeats a second, and the wait before the first repeat (seconds).
    var repeatRate: Double? = nil
    var repeatDelay: Double? = nil
    /// Keyboard shortcuts: tell the left and right modifier keys apart (`sideFlags` are the ones recorded).
    var distinguishSides: Bool? = nil
    var sideFlags: Int? = nil
    /// Keyboard shortcuts: match the character typed rather than the key's place, so the shortcut follows
    /// a change of keyboard layout (`keyCharacter` is what the key typed when it was recorded).
    var followLayout: Bool? = nil
    var keyCharacter: String? = nil

    func actions(for phase: TriggerPhase) -> [MacroAction] { phaseActions?[phase] ?? [] }
    var hasPhaseActions: Bool { phaseActions?.values.contains { !$0.isEmpty } ?? false }

    /// A keyboard shortcut that needs Toolbelt to watch the keyboard itself (key up, holding, sides,
    /// layout), rather than macOS's ordinary hot keys.
    var needsKeyWatching: Bool {
        guard case .shortcut = gesture else { return false }
        return hasPhaseActions || repeatWhileHeld == true || distinguishSides == true || followLayout == true
    }

    var hasNotes: Bool { !(notes ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var hasCondition: Bool { !(condition?.isEmpty ?? true) }

    /// The line under the trigger in lists: its notes if asked for, otherwise its actions.
    var listDescription: String { showNotes == true && hasNotes ? notes ?? "" : "Action: " + summary }

    /// How specific it is: conditions and groups beat app lists, which beat "everywhere".
    var specificity: Int { (hasCondition ? 4 : 0) + (groupID != nil ? 2 : 0) + (scope == .only ? 1 : 0) }

    var isKeyboard: Bool {
        switch gesture {
        case .shortcut, .keySequence, .modifierTap: return true
        default: return false
        }
    }

    var actions: [MacroAction] { [action] + (moreActions ?? []) }
    var summary: String {
        let more = moreActions?.count ?? 0
        return action.summary + (more > 0 ? " + \(more) more" : "")
    }

    func applies(in app: String?) -> Bool {
        switch scope {
        case .everywhere: return true
        case .only: return app.map(apps.contains) ?? false
        case .except: return !(app.map(apps.contains) ?? false)
        }
    }

    /// The first enabled rule for this gesture in this app. App-specific rules win over general ones.
    static func match(_ event: Gesture, app: String?, in rules: [GestureRule]) -> GestureRule? {
        matches(event, app: app, in: rules).first
    }

    /// The rules to run for what happened: the most specific match (conditions, then activation groups,
    /// then app lists, then everywhere), plus any others that allow running alongside it.
    /// `context` is only worked out when a matching rule has conditions.
    static func matches(_ event: Gesture, app: String?, in rules: [GestureRule], groups: [ActivationGroup] = [],
                        context: () -> ConditionContext = { ConditionContext() }) -> [GestureRule] {
        var cached: ConditionContext?
        func now() -> ConditionContext {
            if let cached { return cached }
            let made = context()
            cached = made
            return made
        }
        let candidates = rules.filter { rule in
            guard rule.enabled, rule.gesture.accepts(event), rule.applies(in: app) else { return false }
            if let groupID = rule.groupID {
                guard let group = groups.first(where: { $0.id == groupID }), group.enabled,
                      group.condition.isTrue(in: now()) else { return false }
            }
            if rule.hasCondition, !(rule.condition?.isTrue(in: now()) ?? true) { return false }
            return true
        }
        guard let best = candidates.enumerated().max(by: { a, b in
            a.element.specificity != b.element.specificity ? a.element.specificity < b.element.specificity : a.offset > b.offset
        })?.element else { return [] }
        guard best.parallel == true else { return [best] }
        return [best] + candidates.filter { $0.id != best.id && $0.parallel == true }
    }
}
