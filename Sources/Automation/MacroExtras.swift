import AppKit
import SwiftUI

// 0.32: calculations, picture filters for the clipboard, sub-macro inputs, question windows that don't
// block other macros, and running a macro on a clipboard-history item. The deciding parts are plain
// logic, tested in Tests.swift.

// MARK: - Calculations

/// Works out sums like "12.5 * (3 + 1) / 2", "2 ^ 10" or "17 % 5". Only numbers, + − × ÷ % ^ and brackets:
/// nothing else is ever run.
enum Calculator {
    static func evaluate(_ text: String) -> Double? {
        var parser = Parser(Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")))
        guard let value = parser.sum(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// 42 rather than 42.0; otherwise up to 10 significant digits.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) {
            self.characters = characters.filter { !$0.isWhitespace && $0 != "," }
        }

        var atEnd: Bool { index == characters.count }

        private mutating func take(_ character: Character) -> Bool {
            guard index < characters.count, characters[index] == character else { return false }
            index += 1
            return true
        }

        mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while true {
                if take("+") { guard let next = product() else { return nil }; value += next }
                else if take("-") { guard let next = product() else { return nil }; value -= next }
                else { return value }
            }
        }

        mutating func product() -> Double? {
            guard var value = power() else { return nil }
            while true {
                if take("*") { guard let next = power() else { return nil }; value *= next }
                else if take("/") { guard let next = power(), next != 0 else { return nil }; value /= next }
                else if take("%") { guard let next = power(), next != 0 else { return nil }; value = value.truncatingRemainder(dividingBy: next) }
                else { return value }
            }
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if take("^") {
                guard let exponent = power() else { return nil } // right to left: 2^3^2 = 2^9
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if take("-") { return unary().map { -$0 } }
            if take("+") { return unary() }
            if take("(") {
                guard let value = sum(), take(")") else { return nil }
                return value
            }
            return number()
        }

        mutating func number() -> Double? {
            let start = index
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }
    }
}

// MARK: - Sub-macros

enum MacroInputs {
    /// "Name=value" lines → pairs (blank lines and lines without = are left out).
    static func parse(_ text: String) -> [(name: String, value: String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }
}

// MARK: - Picture filters

enum PictureFilter: String, Codable, CaseIterable, Identifiable {
    case flipHorizontal, flipVertical, rotateLeft, rotateRight, halfSize, trim, readText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flipHorizontal: return "Flip left to right"
        case .flipVertical: return "Flip upside down"
        case .rotateLeft: return "Rotate left (90°)"
        case .rotateRight: return "Rotate right (90°)"
        case .halfSize: return "Half the size"
        case .trim: return "Trim the plain edges"
        case .readText: return "Read the text in it (OCR)"
        }
    }

    /// The changed picture (all but readText).
    func apply(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        func draw(_ size: (Int, Int), _ transform: (CGContext) -> Void) -> CGImage? {
            guard let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            transform(context)
            return context.makeImage()
        }
        switch self {
        case .flipHorizontal:
            return draw((width, height)) { $0.translateBy(x: CGFloat(width), y: 0); $0.scaleBy(x: -1, y: 1); $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        case .flipVertical:
            return draw((width, height)) { $0.translateBy(x: 0, y: CGFloat(height)); $0.scaleBy(x: 1, y: -1); $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        case .rotateLeft:
            // A quarter turn anticlockwise: the right edge becomes the top.
            return draw((height, width)) { $0.translateBy(x: CGFloat(height), y: 0); $0.rotate(by: .pi / 2); $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        case .rotateRight:
            return draw((height, width)) { $0.translateBy(x: 0, y: CGFloat(width)); $0.rotate(by: -.pi / 2); $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        case .halfSize:
            let size = (max(1, width / 2), max(1, height / 2))
            return draw(size) { $0.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1)) }
        case .trim:
            guard let box = Self.contentBox(image) else { return image }
            return image.cropping(to: box)
        case .readText:
            return nil
        }
    }

    /// The part that isn't the plain colour of the top-left corner (rows from the top), or nil if it's all plain.
    static func contentBox(_ image: CGImage, tolerance: Int = 12) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The context's memory starts with the top row.
        let corner = Array(pixels[0..<4])
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let differs = (0..<4).contains { abs(Int(pixels[offset + $0]) - Int(corner[$0])) > tolerance }
                if differs {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // The clipboard's picture, as macros see it.

    @MainActor static func clipboardImage() -> CGImage? {
        guard let image = NSImage(pasteboard: .general) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    @MainActor static func setClipboard(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) { pasteboard.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    /// The text in a picture (Live Text's reader, on this Mac).
    static func readText(_ image: CGImage) async -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: file)) != nil else { return "" }
        return await ImageText.recognize(at: file)
    }
}

// MARK: - Running a macro on a clipboard-history item

/// Set by the Automation module; the clipboard history's menu offers these macros for an item.
@MainActor
enum ClipboardFilterHooks {
    static var names: () -> [String] = { [] }
    static var run: (_ macro: String, _ text: String) -> Void = { _, _ in }
}

// MARK: - Question windows that don't hold everything up

/// An ordinary window (not a modal alert), so other macros and shortcuts keep working while it waits.
@MainActor
final class PromptPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    struct Answer {
        var button: String
        var texts: [String]
        var choice: String?
    }

    /// Windows waiting for an answer (for the tests and so they stay alive).
    private(set) static var open: [PromptPanel] = []

    private let panel: NSPanel
    private var boxes: [NSTextField] = []
    private var popup: NSPopUpButton?
    private var buttons: [String]
    private var continuation: CheckedContinuation<Answer?, Never>?

    /// Shows the window and waits. nil if it's closed or Cancel / Esc is pressed.
    static func ask(_ message: String, fields: [String] = [], options: [String]? = nil, buttons: [String] = ["OK", "Cancel"]) async -> Answer? {
        let prompt = PromptPanel(message: message, fields: fields, options: options, buttons: buttons)
        open.append(prompt)
        defer { open.removeAll { $0 === prompt } }
        return await withCheckedContinuation { continuation in
            prompt.continuation = continuation
            prompt.present()
        }
    }

    private init(message: String, fields: [String], options: [String]?, buttons: [String]) {
        self.buttons = buttons.isEmpty ? ["OK"] : buttons
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Toolbelt"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let label = NSTextField(wrappingLabelWithString: message.isEmpty ? "Toolbelt" : message)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(label)

        if let options {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: options)
            stack.addArrangedSubview(popup)
            self.popup = popup
        } else if !fields.isEmpty {
            boxes = fields.map { _ in
                let box = NSTextField(string: "")
                box.widthAnchor.constraint(equalToConstant: 260).isActive = true
                box.delegate = self
                return box
            }
            let rows: [[NSView]] = zip(fields, boxes).map { name, box in
                name.isEmpty ? [NSView(), box] : [NSTextField(labelWithString: name + ":"), box]
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 8
            grid.column(at: 0).xPlacement = .trailing
            stack.addArrangedSubview(grid)
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        // macOS order: the default (first) button on the right.
        for (index, title) in self.buttons.enumerated().reversed() {
            let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            if index == 0 { button.keyEquivalent = "\r" }
            if title == "Cancel" { button.keyEquivalent = "\u{1b}" }
            row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)

        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        if let first = boxes.first { panel.initialFirstResponder = first }
    }

    private func present() {
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if let first = boxes.first { panel.makeFirstResponder(first) }
        RealUseHooks.writeStatus()
    }

    @objc private func pressed(_ sender: NSButton) {
        let title = buttons[sender.tag]
        finish(title == "Cancel" ? nil : Answer(button: title, texts: boxes.map(\.stringValue), choice: popup?.titleOfSelectedItem))
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ answer: Answer?) {
        guard let continuation else { return }
        self.continuation = nil
        panel.delegate = nil
        panel.orderOut(nil)
        continuation.resume(returning: answer)
        DispatchQueue.main.async { MainActor.assumeIsolated { RealUseHooks.writeStatus() } }
    }

    /// Tab and ⇧Tab go from box to box; Esc cancels.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finish(nil)
            return true
        }
        guard selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)),
              let index = boxes.firstIndex(where: { $0 === control }), boxes.count > 1 else { return false }
        let step = selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
        panel.makeFirstResponder(boxes[(index + step + boxes.count) % boxes.count])
        return true
    }

    /// For the tests: the message of each window that's waiting.
    static var waitingMessages: [String] { open.map { ($0.panel.contentView?.subviews.first as? NSTextField)?.stringValue ?? "" } }
}
