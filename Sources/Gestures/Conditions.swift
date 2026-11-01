import AppKit

// Conditions decide when a trigger (or a whole activation group of triggers) applies: "all / any /
// none of the following are true", with rules about the app in front, the window's title, where the
// pointer is, the time and more, and groups inside groups. The same model serves activation groups
// ("Browsers": Safari, Chrome or Firefox, but not a private window) and a single trigger's own
// conditions ("a 3-finger tap on the window's top-left quarter").

enum ConditionField: String, Codable, CaseIterable, Identifiable {
    case appName, appID, windowTitle, hoveredAppName
    case pointerXInWindow, pointerYInWindow, pointerXOnScreen, pointerYOnScreen
    case hour, weekday, darkMode, displayCount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appName: return "App name"
        case .appID: return "App identifier"
        case .windowTitle: return "Window title"
        case .hoveredAppName: return "App under the pointer"
        case .pointerXInWindow: return "Pointer across the window (%)"
        case .pointerYInWindow: return "Pointer up the window (%)"
        case .pointerXOnScreen: return "Pointer across the screen (%)"
        case .pointerYOnScreen: return "Pointer up the screen (%)"
        case .hour: return "Hour (0–23)"
        case .weekday: return "Weekday (1 = Sunday)"
        case .darkMode: return "Dark mode (1 = on)"
        case .displayCount: return "Number of displays"
        }
    }

    /// The name used in the written-out form, like BetterTouchTool's predicate text.
    var key: String {
        switch self {
        case .pointerXInWindow: return "percent_x_hovered_win_btm_left"
        case .pointerYInWindow: return "percent_y_hovered_win_btm_left"
        case .pointerXOnScreen: return "percent_x_screen_btm_left"
        case .pointerYOnScreen: return "percent_y_screen_btm_left"
        default: return rawValue
        }
    }

    var isNumber: Bool {
        switch self {
        case .appName, .appID, .windowTitle, .hoveredAppName: return false
        default: return true
        }
    }

    var operators: [ConditionOperator] {
        isNumber ? [.equals, .notEquals, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual]
                 : [.contains, .notContains, .is, .isNot, .startsWith, .endsWith, .matches]
    }
}

enum ConditionOperator: String, Codable, CaseIterable, Identifiable {
    case contains, notContains, `is`, isNot, startsWith, endsWith, matches
    case equals, notEquals, lessThan, lessOrEqual, greaterThan, greaterOrEqual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: return "contains"
        case .notContains: return "doesn't contain"
        case .is: return "is"
        case .isNot: return "isn't"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .matches: return "matches pattern"
        case .equals: return "="
        case .notEquals: return "≠"
        case .lessThan: return "<"
        case .lessOrEqual: return "≤"
        case .greaterThan: return ">"
        case .greaterOrEqual: return "≥"
        }
    }

    var symbol: String {
        switch self {
        case .contains: return "CONTAINS"
        case .notContains: return "NOT CONTAINS"
        case .is: return "=="
        case .isNot: return "!="
        case .startsWith: return "BEGINSWITH"
        case .endsWith: return "ENDSWITH"
        case .matches: return "MATCHES"
        case .equals: return "=="
        case .notEquals: return "!="
        case .lessThan: return "<"
        case .lessOrEqual: return "<="
        case .greaterThan: return ">"
        case .greaterOrEqual: return ">="
        }
    }
}

struct ConditionRule: Codable, Equatable {
    var field: ConditionField = .appName
    var op: ConditionOperator = .contains
    var value: String = ""

    func isTrue(in context: ConditionContext) -> Bool {
        let actual = context.values[field] ?? ""
        if field.isNumber {
            guard let left = Double(actual), let right = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
            switch op {
            case .equals, .is: return left == right
            case .notEquals, .isNot: return left != right
            case .lessThan: return left < right
            case .lessOrEqual: return left <= right
            case .greaterThan: return left > right
            case .greaterOrEqual: return left >= right
            default: return false
            }
        }
        let text = actual.lowercased(), wanted = value.lowercased()
        switch op {
        case .contains: return text.contains(wanted)
        case .notContains: return !text.contains(wanted)
        case .is, .equals: return text == wanted
        case .isNot, .notEquals: return text != wanted
        case .startsWith: return text.hasPrefix(wanted)
        case .endsWith: return text.hasSuffix(wanted)
        case .matches: return actual.range(of: value, options: [.regularExpression, .caseInsensitive]) != nil
        default: return false
        }
    }

    var text: String {
        let shown = field.isNumber ? value : "\"\(value)\""
        return "\(field.key) \(op.symbol) \(shown)"
    }
}

/// One line of a condition: a rule, or a group of its own.
struct ConditionNode: Codable, Equatable, Identifiable {
    var id = UUID()
    var rule: ConditionRule?
    var group: ConditionGroup?

    static func rule(_ rule: ConditionRule) -> ConditionNode { ConditionNode(rule: rule) }
    static func group(_ group: ConditionGroup) -> ConditionNode { ConditionNode(group: group) }
}

struct ConditionGroup: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case all, any, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .any: return "Any"
            case .none: return "None"
            }
        }
    }

    var mode: Mode = .all
    var items: [ConditionNode] = []

    var isEmpty: Bool { items.allSatisfy { $0.rule == nil && ($0.group?.isEmpty ?? true) } }

    /// An empty group is always true (it doesn't limit anything).
    func isTrue(in context: ConditionContext) -> Bool {
        let results = items.compactMap { item -> Bool? in
            if let rule = item.rule { return rule.isTrue(in: context) }
            if let group = item.group, !group.isEmpty { return group.isTrue(in: context) }
            return nil
        }
        guard !results.isEmpty else { return true }
        switch mode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        case .none: return !results.contains(true)
        }
    }

    /// Written out, e.g. (appName CONTAINS "Safari" OR appName CONTAINS "Chrome") AND NOT (windowTitle CONTAINS "Private").
    var text: String {
        let parts = items.compactMap { item -> String? in
            if let rule = item.rule { return rule.text }
            if let group = item.group, !group.isEmpty { return group.wrapped }
            return nil
        }
        switch mode {
        case .all: return parts.joined(separator: " AND ")
        case .any: return parts.joined(separator: " OR ")
        case .none: return parts.isEmpty ? "" : "NOT (" + parts.joined(separator: " OR ") + ")"
        }
    }

    private var wrapped: String {
        let inner = text
        return mode == .none || items.count < 2 ? inner : "(\(inner))"
    }
}

/// A named set of conditions, like BetterTouchTool's conditional activation groups. Triggers put in a
/// group only work while its conditions are true.
struct ActivationGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var condition = ConditionGroup()
    var enabled = true
}

/// A named set of triggers, like BetterTouchTool's presets ("Work", "Home"). Triggers put in a preset
/// only work while it's the one in use; triggers in no preset always work.
struct TriggerPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String

    /// Whether a rule works while `active` is the preset in use.
    static func allows(_ rule: GestureRule, active: UUID?) -> Bool {
        rule.presetID == nil || rule.presetID == active
    }
}

/// What's true right now, for checking conditions. Built only when a trigger with conditions fires.
struct ConditionContext: Equatable {
    var values: [ConditionField: String] = [:]

    /// Reads the Mac's current state: the app in front and its window's title (needs Accessibility;
    /// empty without it), the window and app under the pointer, the pointer's place, time and display.
    @MainActor
    static func current() -> ConditionContext {
        var context = ConditionContext()
        let front = NSWorkspace.shared.frontmostApplication
        context.values[.appName] = front?.localizedName ?? ""
        context.values[.appID] = front?.bundleIdentifier ?? ""
        context.values[.windowTitle] = front.flatMap { focusedWindowTitle(of: $0.processIdentifier) } ?? ""

        let pointer = NSEvent.mouseLocation // bottom-left origin
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.frame
            context.values[.pointerXOnScreen] = percent(pointer.x - frame.minX, of: frame.width)
            context.values[.pointerYOnScreen] = percent(pointer.y - frame.minY, of: frame.height)
        }
        if let window = windowUnderPointer(pointer) {
            context.values[.hoveredAppName] = window.owner
            // Window bounds are top-left based; the percentages count from the bottom-left, as in BetterTouchTool.
            let topLeftY = (NSScreen.screens.first?.frame.height ?? 0) - pointer.y
            context.values[.pointerXInWindow] = percent(pointer.x - window.bounds.minX, of: window.bounds.width)
            context.values[.pointerYInWindow] = percent(window.bounds.maxY - topLeftY, of: window.bounds.height)
        }
        let now = Calendar.current.dateComponents([.hour, .weekday], from: Date())
        context.values[.hour] = String(now.hour ?? 0)
        context.values[.weekday] = String(now.weekday ?? 1)
        context.values[.darkMode] = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "1" : "0"
        context.values[.displayCount] = String(NSScreen.screens.count)
        return context
    }

    private static func percent(_ value: CGFloat, of total: CGFloat) -> String {
        guard total > 0 else { return "0" }
        return String(format: "%.1f", Double(max(0, min(1, value / total))) * 100)
    }

    private static func focusedWindowTitle(of pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    /// The front-most ordinary window under the pointer: its app and its bounds (top-left based).
    /// Window positions and owners are readable without any permission.
    private static func windowUnderPointer(_ pointer: NSPoint) -> (owner: String, bounds: CGRect)? {
        let topLeftY = (NSScreen.screens.first?.frame.height ?? 0) - pointer.y
        let point = CGPoint(x: pointer.x, y: topLeftY)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.contains(point) else { continue }
            return ((info[kCGWindowOwnerName as String] as? String) ?? "", bounds)
        }
        return nil
    }
}
