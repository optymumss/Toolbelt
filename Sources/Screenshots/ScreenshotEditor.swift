import AppKit
import SwiftUI

/// The marks on one screenshot, and what the editor's buttons do with them.
@MainActor
final class ScreenshotEditorModel: ObservableObject {
    let base: CGImage
    @Published var annotations: [Annotation] = [] { didSet { rerender() } }
    @Published var crop: CGRect?
    @Published var tool: AnnotationTool = .arrow
    @Published var color: AnnotationColor = .red
    @Published var text = "Note"
    /// The mark being dragged out right now (drawn on top until you let go).
    @Published var draft: Annotation?
    @Published private(set) var preview: CGImage
    @Published var message: String?
    private var undone: [[Annotation]] = []

    init(image: CGImage) {
        base = image
        preview = image
    }

    var size: CGSize { CGSize(width: base.width, height: base.height) }

    private func rerender() {
        preview = ScreenshotRenderer.render(base, annotations: annotations) ?? base
    }

    // MARK: Drawing with the mouse (points are in the image's pixels)

    func dragChanged(from start: CGPoint, to point: CGPoint) {
        guard tool != .text else { return }
        if tool == .crop {
            crop = Annotation(tool: .crop, start: start, end: point).rect
        } else {
            draft = Annotation(tool: tool, start: start, end: point, color: color)
        }
    }

    func dragEnded(from start: CGPoint, to point: CGPoint) {
        draft = nil
        switch tool {
        case .crop:
            let area = Annotation(tool: .crop, start: start, end: point)
            crop = area.isTiny ? nil : area.rect
        case .text:
            add(Annotation(tool: .text, start: point, end: point, color: color, text: text))
        default:
            let mark = Annotation(tool: tool, start: start, end: point, color: color)
            if !mark.isTiny { add(mark) }
        }
    }

    func add(_ mark: Annotation) {
        undone = []
        annotations.append(mark)
    }

    func undo() {
        if crop != nil, annotations.isEmpty || tool == .crop {
            crop = nil
            return
        }
        guard let last = annotations.popLast() else { return }
        undone.append([last])
    }

    func redo() {
        guard let marks = undone.popLast() else { return }
        annotations.append(contentsOf: marks)
    }

    /// The finished picture: marks drawn in, then cropped.
    func finalImage() -> CGImage {
        ScreenshotRenderer.render(base, annotations: annotations, crop: crop) ?? base
    }

    // MARK: Buttons

    func copyImage() {
        let image = NSImage(cgImage: finalImage(), size: .zero)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @discardableResult
    func save(to chosenFolder: URL? = nil) -> URL? {
        let folder = chosenFolder ?? Prefs.screenshotFolder
        guard let data = ScreenshotRenderer.pngData(finalImage()) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ShelfStore.unusedURL(for: ScreenshotRenderer.fileName(), in: folder)
        do {
            try data.write(to: url)
            return url
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
            return nil
        }
    }

    /// Reads the text in the (cropped) screenshot and copies it.
    func copyText() async {
        message = "Reading text…"
        let text = await ScreenshotText.read(finalImage())
        if text.isEmpty {
            message = "No text found"
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let lines = text.components(separatedBy: "\n").count
            message = "Copied \(lines) line\(lines == 1 ? "" : "s") of text"
        }
    }
}

enum ScreenshotText {
    /// Text recognition on this Mac (Vision), as for images in the clipboard history.
    static func read(_ image: CGImage) async -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = ScreenshotRenderer.pngData(image), (try? data.write(to: file)) != nil else { return "" }
        return await ImageText.recognize(at: file)
    }
}

/// A window with the screenshot and the marking-up tools.
@MainActor
final class ScreenshotEditorWindow: NSObject, NSWindowDelegate {
    let model: ScreenshotEditorModel
    let window: NSWindow
    var onClose: (() -> Void)?

    init(image: CGImage) {
        model = ScreenshotEditorModel(image: image)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Shown at its real size where it fits, otherwise as big as fits in most of the screen.
        let natural = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, screen.width * 0.85 / natural.width, (screen.height * 0.85 - 90) / natural.height)
        let content = NSSize(width: max(560, natural.width * fit), height: natural.height * fit + 90)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ScreenshotEditorView(model: model, close: { [weak self] in self?.window.close() }))
        window.setContentSize(content)
        window.center()
        window.delegate = self
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
                .padding(12)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 10) {
                Text(model.message ?? "Drag on the picture to draw. ⌘Z undoes, ⌘C copies, ⌘S saves.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Copy Text") { Task { await model.copyText() } }
                Button("Save") {
                    if let url = model.save() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        close()
                    }
                }
                .keyboardShortcut("s")
                Button("Copy") {
                    model.copyImage()
                    close()
                }
                .keyboardShortcut("c")
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.allCases) { tool in
                Button { model.tool = tool } label: {
                    Label(tool.title, systemImage: tool.symbol)
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 22)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.borderless)
                .help(tool.title)
            }
            Divider().frame(height: 18)
            ForEach(AnnotationColor.allCases) { color in
                Button { model.color = color } label: {
                    Circle().fill(Color(cgColor: color.cgColor))
                        .overlay(Circle().stroke(Color.primary.opacity(model.color == color ? 0.8 : 0.2), lineWidth: model.color == color ? 2 : 1))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help(color.rawValue.capitalized)
            }
            if model.tool == .text {
                Divider().frame(height: 18)
                TextField("Text to place", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .help("Type the text, then click on the picture where it goes")
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z")
                .help("Undo")
                .buttonStyle(.borderless)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo")
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let fit = min(geometry.size.width / model.size.width, geometry.size.height / model.size.height)
            let shown = CGSize(width: model.size.width * fit, height: model.size.height * fit)
            let origin = CGPoint(x: (geometry.size.width - shown.width) / 2, y: (geometry.size.height - shown.height) / 2)
            let toImage = { (p: CGPoint) in
                CGPoint(x: min(max(0, (p.x - origin.x) / fit), model.size.width), y: min(max(0, (p.y - origin.y) / fit), model.size.height))
            }
            ZStack(alignment: .topLeading) {
                Image(decorative: model.preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: shown.width, height: shown.height)
                    .shadow(radius: 4)
                    .offset(x: origin.x, y: origin.y)
                if let draft = model.draft {
                    DraftShape(mark: draft, scale: fit)
                        .offset(x: origin.x, y: origin.y)
                        .allowsHitTesting(false)
                }
                if let crop = model.crop {
                    CropShade(crop: crop, size: model.size, scale: fit)
                        .frame(width: shown.width, height: shown.height)
                        .offset(x: origin.x, y: origin.y)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in model.dragChanged(from: toImage(value.startLocation), to: toImage(value.location)) }
                .onEnded { value in model.dragEnded(from: toImage(value.startLocation), to: toImage(value.location)) })
        }
    }
}

/// The mark being drawn, before it's added to the picture.
private struct DraftShape: View {
    let mark: Annotation
    let scale: CGFloat

    var body: some View {
        let rect = CGRect(x: mark.rect.minX * scale, y: mark.rect.minY * scale, width: mark.rect.width * scale, height: mark.rect.height * scale)
        let color = Color(cgColor: mark.color.cgColor)
        switch mark.tool {
        case .arrow:
            Path { path in
                path.move(to: CGPoint(x: mark.start.x * scale, y: mark.start.y * scale))
                path.addLine(to: CGPoint(x: mark.end.x * scale, y: mark.end.y * scale))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case .box:
            Path { $0.addRect(rect) }.stroke(color, lineWidth: 3)
        case .highlight:
            Path { $0.addRect(rect) }.fill(color.opacity(0.4))
        case .blur:
            Path { $0.addRect(rect) }.fill(Color.gray.opacity(0.6))
        case .text, .crop:
            EmptyView()
        }
    }
}

/// Darkens everything outside the crop.
private struct CropShade: View {
    let crop: CGRect
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        let inner = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
        Path { path in
            path.addRect(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            path.addRect(inner)
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .overlay(Path { $0.addRect(inner) }.stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }
}
