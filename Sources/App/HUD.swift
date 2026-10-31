import AppKit
import SwiftUI

/// A small message in the middle of the screen, like the one macOS shows for volume or brightness.
/// It never takes the focus and fades by itself.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    /// The latest message, for the tests.
    private(set) static var lastMessage: String?

    static var isShowing: Bool { panel?.isVisible == true && (panel?.alphaValue ?? 0) > 0 }

    static func show(_ message: String, detail: String = "", symbol: String = "checkmark.circle", seconds: Double = 1.2) {
        lastMessage = message
        let view = NSHostingView(rootView: HUDView(message: message, detail: detail, symbol: symbol))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: detail.isEmpty ? 150 : 175)
        let panel = self.panel ?? {
            let made = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.level = .statusBar
            made.hasShadow = false
            made.ignoresMouseEvents = true
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            made.isReleasedWhenClosed = false
            return made
        }()
        self.panel = panel
        panel.setContentSize(view.frame.size)
        panel.contentView = view
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - view.frame.width / 2, y: screen.minY + screen.height * 0.2))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { panel.orderOut(nil) }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

private struct HUDView: View {
    let message: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 44, weight: .regular))
            Text(message).font(.headline).multilineTextAlignment(.center).lineLimit(2)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
