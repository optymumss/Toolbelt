import AppKit

/// Everything the window manager can do to the front window.
enum WindowAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, center, restore
    case nextDisplay, previousDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left Quarter"
        case .topRight: return "Top Right Quarter"
        case .bottomLeft: return "Bottom Left Quarter"
        case .bottomRight: return "Bottom Right Quarter"
        case .firstThird: return "First Third"
        case .centerThird: return "Centre Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .maximize: return "Maximise"
        case .center: return "Centre"
        case .restore: return "Restore"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: return "rectangle.split.3x1"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .center: return "rectangle.center.inset.filled"
        case .restore: return "arrow.uturn.backward"
        case .nextDisplay: return "arrow.right.to.line"
        case .previousDisplay: return "arrow.left.to.line"
        }
    }
}

/// The maths for where a window goes. Rectangles here use top-left origin
/// coordinates (y grows downwards), the same as the Accessibility API.
enum WindowLayout {
    /// Where a window should go on a screen's usable area (menu bar and Dock excluded).
    /// Returns nil for actions that don't depend only on the screen (restore, displays).
    static func frame(for action: WindowAction, in area: CGRect, current: CGRect, gap: CGFloat = 0) -> CGRect? {
        let a = area.insetBy(dx: gap / 2, dy: gap / 2)
        let halfW = a.width / 2, halfH = a.height / 2
        let third = a.width / 3
        let rect: CGRect
        switch action {
        case .leftHalf: rect = CGRect(x: a.minX, y: a.minY, width: halfW, height: a.height)
        case .rightHalf: rect = CGRect(x: a.minX + halfW, y: a.minY, width: halfW, height: a.height)
        case .topHalf: rect = CGRect(x: a.minX, y: a.minY, width: a.width, height: halfH)
        case .bottomHalf: rect = CGRect(x: a.minX, y: a.minY + halfH, width: a.width, height: halfH)
        case .topLeft: rect = CGRect(x: a.minX, y: a.minY, width: halfW, height: halfH)
        case .topRight: rect = CGRect(x: a.minX + halfW, y: a.minY, width: halfW, height: halfH)
        case .bottomLeft: rect = CGRect(x: a.minX, y: a.minY + halfH, width: halfW, height: halfH)
        case .bottomRight: rect = CGRect(x: a.minX + halfW, y: a.minY + halfH, width: halfW, height: halfH)
        case .firstThird: rect = CGRect(x: a.minX, y: a.minY, width: third, height: a.height)
        case .centerThird: rect = CGRect(x: a.minX + third, y: a.minY, width: third, height: a.height)
        case .lastThird: rect = CGRect(x: a.minX + 2 * third, y: a.minY, width: third, height: a.height)
        case .firstTwoThirds: rect = CGRect(x: a.minX, y: a.minY, width: 2 * third, height: a.height)
        case .lastTwoThirds: rect = CGRect(x: a.minX + third, y: a.minY, width: 2 * third, height: a.height)
        case .maximize: rect = a
        case .center:
            let width = min(current.width, a.width), height = min(current.height, a.height)
            return CGRect(x: (a.midX - width / 2).rounded(), y: (a.midY - height / 2).rounded(), width: width, height: height)
        case .restore, .nextDisplay, .previousDisplay:
            return nil
        }
        // Each window keeps half the gap on every side, so neighbours end up a full gap apart.
        return rect.insetBy(dx: gap / 2, dy: gap / 2).integral
    }

    /// Moves a window to another screen, keeping its place and size relative to the screen.
    static func move(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        var width = window.width, height = window.height
        if width > target.width || height > target.height {
            width = min(width * scaleX, target.width)
            height = min(height * scaleY, target.height)
        }
        var x = target.minX + (window.minX - source.minX) * scaleX
        var y = target.minY + (window.minY - source.minY) * scaleY
        x = max(target.minX, min(x, target.maxX - width))
        y = max(target.minY, min(y, target.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    /// Converts a rectangle from AppKit's bottom-left origin to top-left origin.
    /// `primaryHeight` is the height of the main (menu bar) screen.
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Where dropping a dragged window snaps it.
enum SnapZone {
    static let edge: CGFloat = 6
    static let corner: CGFloat = 40

    /// `point` and `screen` use top-left origin coordinates; `screen` is the full screen frame.
    static func action(for point: CGPoint, in screen: CGRect) -> WindowAction? {
        let nearLeft = point.x <= screen.minX + edge
        let nearRight = point.x >= screen.maxX - edge - 1
        let nearTop = point.y <= screen.minY + edge
        let nearBottom = point.y >= screen.maxY - edge - 1
        let cornerTop = point.y <= screen.minY + corner
        let cornerBottom = point.y >= screen.maxY - corner
        let cornerLeft = point.x <= screen.minX + corner
        let cornerRight = point.x >= screen.maxX - corner

        if nearLeft, cornerTop { return .topLeft }
        if nearLeft, cornerBottom { return .bottomLeft }
        if nearRight, cornerTop { return .topRight }
        if nearRight, cornerBottom { return .bottomRight }
        if nearTop, cornerLeft { return .topLeft }
        if nearTop, cornerRight { return .topRight }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        if nearTop { return .maximize }
        if nearBottom, cornerLeft { return .bottomLeft }
        if nearBottom, cornerRight { return .bottomRight }
        return nil
    }
}
