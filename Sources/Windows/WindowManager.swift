import AppKit
import ApplicationServices

/// A window of another app, reached through the Accessibility API.
struct AXWindow {
    let element: AXUIElement

    /// Position and size in top-left origin screen coordinates.
    var frame: CGRect? {
        guard let position: CGPoint = value(kAXPositionAttribute, type: .cgPoint),
              let size: CGSize = value(kAXSizeAttribute, type: .cgSize) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func setFrame(_ frame: CGRect) {
        // Size, then position, then size again: some apps refuse a size that
        // doesn't fit where the window currently is.
        set(kAXSizeAttribute, frame.size, type: .cgSize)
        set(kAXPositionAttribute, frame.origin, type: .cgPoint)
        set(kAXSizeAttribute, frame.size, type: .cgSize)
    }

    var isStandardWindow: Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) == kAXWindowRole
    }

    private func value<T>(_ attribute: String, type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(axValue, type, pointer) else { return nil }
        return pointer.pointee
    }

    private func set<T>(_ attribute: String, _ value: T, type: AXValueType) {
        var copy = value
        guard let axValue = AXValueCreate(type, &copy) else { return }
        AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
    }

    /// The window you're working in: the focused window of the frontmost app.
    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focused(in: app.processIdentifier)
    }

    static func focused(in pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: window as! AXUIElement)
    }

    /// The window under a point (top-left origin coordinates), for drag-to-snap.
    static func at(_ point: CGPoint) -> AXWindow? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            return AXWindow(element: window as! AXUIElement)
        }
        let candidate = AXWindow(element: element)
        return candidate.isStandardWindow ? candidate : nil
    }

    func isSameWindow(as other: AXWindow) -> Bool {
        CFEqual(element, other.element)
    }
}

/// Screens in top-left origin coordinates, the way the Accessibility API sees them.
@MainActor
enum Screens {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Full frame and usable area (without menu bar and Dock) of each screen.
    static var all: [(frame: CGRect, area: CGRect)] {
        NSScreen.screens.map {
            (WindowLayout.flip($0.frame, primaryHeight: primaryHeight),
             WindowLayout.flip($0.visibleFrame, primaryHeight: primaryHeight))
        }
    }

    /// The screen holding most of a window.
    static func index(containing rect: CGRect) -> Int {
        let screens = all
        var best = 0, bestArea: CGFloat = -1
        for (i, screen) in screens.enumerated() {
            let overlap = screen.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { best = i; bestArea = area }
        }
        return best
    }

    static func index(containing point: CGPoint) -> Int? {
        all.firstIndex { $0.frame.contains(point) }
    }
}

/// Moves and resizes the front window.
@MainActor
final class WindowManager {
    /// Where each window was before Toolbelt moved it, for Restore.
    private var previousFrames: [(window: AXWindow, frame: CGRect)] = []

    /// Runs an action on the focused window. Returns false if there was nothing to move.
    @discardableResult
    func perform(_ action: WindowAction, on target: AXWindow? = nil) -> Bool {
        guard PermissionGate.ensure(.accessibility, to: "move and resize windows") else { return false }
        guard let window = target ?? AXWindow.focused(), let current = window.frame else {
            NSSound.beep()
            return false
        }
        guard let newFrame = frame(for: action, window: window, current: current) else {
            NSSound.beep()
            return false
        }
        if action != .restore { remember(window, current) }
        window.setFrame(newFrame)
        return true
    }

    func frame(for action: WindowAction, window: AXWindow, current: CGRect) -> CGRect? {
        let screens = Screens.all
        guard !screens.isEmpty else { return nil }
        let index = Screens.index(containing: current)
        let gap = CGFloat(Prefs.windowGap)

        switch action {
        case .restore:
            return previousFrames.last { $0.window.isSameWindow(as: window) }?.frame
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return nil }
            let step = action == .nextDisplay ? 1 : -1
            let target = (index + step + screens.count) % screens.count
            return WindowLayout.move(current, from: screens[index].area, to: screens[target].area)
        default:
            return WindowLayout.frame(for: action, in: screens[index].area, current: current, gap: gap)
        }
    }

    /// Puts a window somewhere, remembering where it was for Restore (used by drag-to-snap).
    func place(_ window: AXWindow, at frame: CGRect, rememberingFrom previous: CGRect) {
        remember(window, previous)
        window.setFrame(frame)
    }

    private func remember(_ window: AXWindow, _ frame: CGRect) {
        previousFrames.removeAll { $0.window.isSameWindow(as: window) }
        previousFrames.append((window, frame))
        if previousFrames.count > 50 { previousFrames.removeFirst() }
    }
}
