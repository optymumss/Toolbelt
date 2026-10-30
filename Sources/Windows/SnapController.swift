import AppKit

/// Drag a window to a screen edge or corner and it snaps there when you let go.
/// While dragging over a snap area, a translucent preview shows where it will go.
@MainActor
final class SnapController {
    private let manager: WindowManager
    private let overlay = SnapOverlay()
    /// Lets the screenshot check show the snap preview without a real drag.
    var overlayForScreenshot: SnapOverlay { overlay }
    private var monitors: [Any] = []

    private var window: AXWindow?
    private var startFrame: CGRect?
    /// Where the button went down; the window under it is only looked up once a drag starts.
    private var downPoint: CGPoint?
    private var isMovingWindow = false
    private var lastCheck: TimeInterval = 0
    private var target: (action: WindowAction, frame: CGRect)?

    init(manager: WindowManager) {
        self.manager = manager
    }

    func start() {
        guard monitors.isEmpty else { return }
        let types: [NSEvent.EventTypeMask] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        for type in types {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: type, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }) {
                monitors.append(monitor)
            }
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        reset()
    }

    /// The pointer in top-left origin coordinates.
    private var pointer: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: Screens.primaryHeight - p.y)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: mouseDown()
        case .leftMouseDragged: mouseDragged(event)
        case .leftMouseUp: mouseUp()
        default: break
        }
    }

    private func mouseDown() {
        reset()
        // Snapping needs Accessibility; don't nag about it on every click.
        guard Prefs.windowSnapping, AXIsProcessTrusted() else { return }
        downPoint = pointer
    }

    private func mouseDragged(_ event: NSEvent) {
        // Ordinary clicks cost nothing: the window is looked up only when a drag really starts.
        if window == nil, let downPoint {
            let p = pointer
            guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 3 else { return }
            self.downPoint = nil
            window = AXWindow.at(downPoint)
            startFrame = window?.frame
        }
        guard let window, let startFrame else { return }

        if !isMovingWindow {
            // Only count it as a window drag once the window itself moves (not a resize or text selection).
            guard event.timestamp - lastCheck > 0.05 else { return }
            lastCheck = event.timestamp
            guard let now = window.frame, now.size == startFrame.size,
                  abs(now.minX - startFrame.minX) + abs(now.minY - startFrame.minY) > 2 else { return }
            isMovingWindow = true
        }

        let point = pointer
        guard let screenIndex = Screens.index(containing: point) else {
            clearTarget()
            return
        }
        let screen = Screens.all[screenIndex]
        guard let action = SnapZone.action(for: point, in: screen.frame),
              let frame = WindowLayout.frame(for: action, in: screen.area, current: startFrame, gap: CGFloat(Prefs.windowGap)) else {
            clearTarget()
            return
        }
        if target?.frame != frame {
            target = (action, frame)
            overlay.show(frame)
        }
    }

    private func mouseUp() {
        if isMovingWindow, let window, let startFrame, let target {
            manager.place(window, at: target.frame, rememberingFrom: startFrame)
        }
        reset()
    }

    private func clearTarget() {
        target = nil
        overlay.hide()
    }

    private func reset() {
        downPoint = nil
        window = nil
        startFrame = nil
        isMovingWindow = false
        clearTarget()
    }
}

/// The translucent rectangle that previews where a window will snap.
@MainActor
final class SnapOverlay {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// `frame` uses top-left origin coordinates.
    func show(_ frame: CGRect) {
        let window = self.window ?? makeWindow()
        self.window = window
        let cocoaFrame = WindowLayout.flip(frame, primaryHeight: Screens.primaryHeight)
        window.setFrame(cocoaFrame.insetBy(dx: 4, dy: 4), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        view.layer?.borderWidth = 2
        window.contentView = view
        return window
    }
}
