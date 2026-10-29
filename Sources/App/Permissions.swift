import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid

/// The macOS privacy permissions Toolbelt can use.
/// Each one is asked for only when a feature first needs it.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring, screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    /// What the permission lets Toolbelt do, in plain words.
    var explanation: String {
        switch self {
        case .accessibility:
            return "Lets Toolbelt press keys and move windows for you, such as pasting with ⌘V after you pick a clipboard item."
        case .inputMonitoring:
            return "Lets Toolbelt notice what you type, so typing a snippet keyword like ;addr can expand it."
        case .screenRecording:
            return "Lets Toolbelt take screenshots and read text on screen."
        }
    }

    /// Which features need it. Features not built yet are marked as coming later.
    var usedBy: String {
        switch self {
        case .accessibility: return "Clipboard auto-paste · later: window management, snippets, macros"
        case .inputMonitoring: return "Later: snippets, gestures, macros"
        case .screenRecording: return "Later: screenshots"
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        }
    }

    /// Adds Toolbelt to the permission's list in System Settings
    /// (switched off until you turn it on), then opens that page.
    @MainActor
    func openSettings() {
        switch self {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }
}

/// Asks for a permission at the moment a feature needs it.
@MainActor
enum PermissionGate {
    private static var askedThisLaunch: Set<Permission> = []

    /// Returns true if the permission is already granted. If it isn't, explains
    /// why it's needed (once per launch) and offers to open System Settings.
    static func ensure(_ permission: Permission, to feature: String) -> Bool {
        if permission.isGranted { return true }
        guard !askedThisLaunch.contains(permission) else { return false }
        askedThisLaunch.insert(permission)

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow Toolbelt to \(feature)?"
        alert.informativeText = """
        This needs the \(permission.title) permission. \(permission.explanation)

        Click Open System Settings, then switch Toolbelt on in the list. \
        If Toolbelt is already on but this still appears, select it, click –, and add it again: \
        macOS forgets the permission each time Toolbelt is updated.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            permission.openSettings()
        }
        return false
    }
}
