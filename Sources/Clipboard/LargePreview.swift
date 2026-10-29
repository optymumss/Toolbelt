import AppKit
import Quartz
import SwiftUI

/// Tells a quick tap of Space (preview stays open) from holding it (closes on release).
enum SpaceKey {
    static let holdThreshold: TimeInterval = 0.35

    static func isHold(pressedAt: TimeInterval, releasedAt: TimeInterval) -> Bool {
        releasedAt - pressedAt >= holdThreshold
    }
}

/// A preview panel that never takes keyboard focus,
/// so the history panel keeps handling the keys.
private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The large preview shown over the history panel (Space or ⌘Y).
@MainActor
final class LargePreviewController {
    private let store: ClipboardStore
    private var panel: PreviewPanel?
    private(set) var item: ClipItem?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: ClipboardStore) {
        self.store = store
    }

    func show(_ item: ClipItem, over parent: NSWindow) {
        self.item = item
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: LargePreviewView(item: item, store: store))

        let screen = parent.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = NSSize(width: (frame.width * 0.72).rounded(), height: (frame.height * 0.8).rounded())
            let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    /// Shows a different item if the preview is open (the selection moved).
    func update(_ item: ClipItem?, over parent: NSWindow) {
        guard isVisible else { return }
        guard let item else { hide(); return }
        if item != self.item { show(item, over: parent) }
    }

    func hide() {
        panel?.orderOut(nil)
        item = nil
    }

    private func makePanel() -> PreviewPanel {
        let panel = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        return panel
    }
}

struct LargePreviewView: View {
    let item: ClipItem
    let store: ClipboardStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: item.fromOtherDevice == true ? "iphone" : item.kind.symbol)
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("· \(item.sourceAppName ?? item.kind.label) · \(Formatters.ago(item.created))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            KeyHint(keys: "space", label: "Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        switch item.kind {
        case .link: return item.linkTitle ?? "Link"
        case .text: return "Text"
        case .image: return item.title
        case .file: return item.title
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            RichTextView(text: item.text ?? "", rtf: item.rtf)
        case .link:
            linkContent
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: CGFloat(item.imageWidth ?? 10_000), maxHeight: CGFloat(item.imageHeight ?? 10_000))
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Image file missing").foregroundStyle(.secondary)
            }
        case .file:
            if let path = item.filePaths?.first {
                QuickLookView(url: URL(fileURLWithPath: path))
            }
        }
    }

    private var linkContent: some View {
        let address = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: address)
        return VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            if let title = item.linkTitle {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            Text(url?.host ?? "")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(address)
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .lineLimit(6)
            if let url {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: 700)
    }
}

/// Shows text with its original formatting (fonts, colours, bold) when there is any.
private struct RichTextView: NSViewRepresentable {
    let text: String
    let rtf: Data?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 24, height: 20)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if let rtf, let styled = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(styled)
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: String(text.prefix(500_000)),
                attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor]
            ))
        }
    }
}

/// macOS's own Quick Look, which previews PDFs, images, documents, video and more.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL {
            view.previewItem = url as NSURL
        }
    }
}
