import AppKit
import CoreText

// MARK: - Capturing

enum CaptureMode: String {
    case area, window, screen

    /// Options for macOS's own screencapture tool, which draws the crosshair and window highlight.
    func arguments(output: URL) -> [String] {
        switch self {
        case .area: return ["-i", "-s", "-x", output.path]       // drag out an area (Space switches to windows)
        case .window: return ["-i", "-w", "-o", "-x", output.path] // click a window, without its shadow
        case .screen: return ["-m", "-x", output.path]            // the main display, straight away
        }
    }
}

enum ScreenshotCapture {
    /// Takes a screenshot into a temporary PNG and returns it, or nil if it was cancelled (Esc).
    /// Runs off the main thread: area and window capture wait for you to choose.
    static func capture(_ mode: CaptureMode) async -> URL? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-capture-\(UUID().uuidString).png")
        return await run(mode.arguments(output: output), output: output)
    }

    /// A given rectangle of the screen (in points, top-left origin), without asking. Used by the tests.
    static func capture(rect: CGRect) async -> URL? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-capture-\(UUID().uuidString).png")
        let r = rect.integral
        return await run(["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", output.path], output: output)
    }

    private static func run(_ arguments: [String], output: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                ShelfActions.run("/usr/sbin/screencapture", arguments)
                continuation.resume(returning: FileManager.default.fileExists(atPath: output.path) ? output : nil)
            }
        }
    }
}

// MARK: - Marking up

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow, box, text, highlight, blur, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .text: return "Text"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .blur: return "eye.slash"
        case .crop: return "crop"
        }
    }
}

enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, black, white

    var id: String { rawValue }

    var cgColor: CGColor {
        switch self {
        case .red: return CGColor(srgbRed: 0.93, green: 0.19, blue: 0.16, alpha: 1)
        case .orange: return CGColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)
        case .yellow: return CGColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)
        case .green: return CGColor(srgbRed: 0.2, green: 0.75, blue: 0.3, alpha: 1)
        case .blue: return CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 1)
        case .black: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .white: return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

/// One mark on a screenshot, in the image's pixels with the origin at the top left.
struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var color: AnnotationColor = .red
    var text = ""

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Too small to keep (a click rather than a drag), except text, which is placed with a click.
    var isTiny: Bool { tool != .text && hypot(end.x - start.x, end.y - start.y) < 4 }
}

/// Draws the marks onto a screenshot. The same drawing is used for the editor's preview and
/// for the copied or saved picture.
enum ScreenshotRenderer {
    /// Thickness of lines, in pixels, for an image this wide.
    static func lineWidth(for width: Int) -> CGFloat { max(3, CGFloat(width) / 320) }
    static func fontSize(for width: Int) -> CGFloat { max(16, CGFloat(width) / 55) }

    static func render(_ base: CGImage, annotations: [Annotation], crop: CGRect? = nil) -> CGImage? {
        let width = base.width, height = base.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        // From here on, y goes down from the top, like the marks' coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let line = lineWidth(for: width)

        for mark in annotations {
            let rect = mark.rect
            switch mark.tool {
            case .blur:
                pixelate(base, rect: rect, in: context)
            case .highlight:
                context.saveGState()
                context.setBlendMode(.multiply)
                context.setFillColor(mark.color.cgColor.copy(alpha: 0.45) ?? mark.color.cgColor)
                context.fill(rect)
                context.restoreGState()
            case .box:
                context.saveGState()
                context.setStrokeColor(mark.color.cgColor)
                context.setLineWidth(line)
                context.setLineJoin(.round)
                context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
                context.restoreGState()
            case .arrow:
                drawArrow(from: mark.start, to: mark.end, color: mark.color.cgColor, width: line, in: context)
            case .text:
                drawText(mark.text, at: mark.start, color: mark.color, size: fontSize(for: width), in: context)
            case .crop:
                break
            }
        }
        guard let image = context.makeImage() else { return nil }
        if let crop {
            let area = crop.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard area.width >= 1, area.height >= 1 else { return image }
            return image.cropping(to: area)
        }
        return image
    }

    /// Big blocks of colour, so whatever was there can't be read.
    private static func pixelate(_ base: CGImage, rect: CGRect, in context: CGContext) {
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard area.width >= 2, area.height >= 2, let piece = base.cropping(to: area) else { return }
        let block = max(8, min(area.width, area.height) / 6)
        let smallWidth = max(1, Int(area.width / block)), smallHeight = max(1, Int(area.height / block))
        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(piece, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let blocks = small.makeImage() else { return }
        context.saveGState()
        context.interpolationQuality = .none
        // Images are drawn bottom-up, so flip back for this one.
        context.translateBy(x: 0, y: area.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(blocks, in: CGRect(x: area.minX, y: 0, width: area.width, height: area.height))
        context.restoreGState()
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, color: CGColor, width: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = width * 4.5
        let base = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 7) * head, y: end.y - sin(angle - .pi / 7) * head))
        context.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 7) * head, y: end.y - sin(angle + .pi / 7) * head))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    /// Text with a thin outline in the opposite shade, so it can be read on any background.
    private static func drawText(_ text: String, at origin: CGPoint, color: AnnotationColor, size: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let outline = color == .white || color == .yellow ? AnnotationColor.black.cgColor : AnnotationColor.white.cgColor
        let lineHeight = size * 1.25
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let baseline = CGPoint(x: origin.x, y: origin.y + size + CGFloat(index) * lineHeight)
            for (stroke, fill) in [(size / 9, outline), (0, color.cgColor)] {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
                    NSAttributedString.Key(kCTStrokeWidthAttributeName as String): stroke > 0 ? stroke / size * 100 : 0,
                    NSAttributedString.Key(kCTStrokeColorAttributeName as String): fill,
                ]
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
                context.textPosition = baseline
                CTLineDraw(ctLine, context)
            }
        }
        context.restoreGState()
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// "Screenshot 2026-10-30 at 09.41.12.png", like macOS's own.
    static func fileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).png"
    }
}
