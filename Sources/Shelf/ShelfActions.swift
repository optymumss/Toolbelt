import AppKit

// MARK: - Opening a shelf by dragging to an edge

/// Where dragging something opens a shelf.
enum ShelfEdge: String, CaseIterable, Identifiable {
    case off, notch, left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .notch: return "Top centre (the notch)"
        case .left: return "Left edge"
        case .right: return "Right edge"
        }
    }

    /// Whether a pointer (AppKit coordinates, bottom-left origin) is in this edge zone of a screen.
    func contains(_ point: NSPoint, screen: NSRect) -> Bool {
        let margin: CGFloat = 3
        switch self {
        case .off:
            return false
        case .notch:
            return point.y >= screen.maxY - margin && abs(point.x - screen.midX) <= screen.width * 0.15
        case .left:
            return point.x <= screen.minX + margin && point.y > screen.minY + screen.height * 0.2 && point.y < screen.maxY - screen.height * 0.2
        case .right:
            return point.x >= screen.maxX - margin && point.y > screen.minY + screen.height * 0.2 && point.y < screen.maxY - screen.height * 0.2
        }
    }
}

// MARK: - Watching folders

/// Calls back when files appear in a folder. Uses the kernel's file events (no polling), so it
/// costs nothing while nothing changes.
@MainActor
final class FolderWatcher {
    let folder: URL
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private let onNewFiles: ([URL]) -> Void

    init(folder: URL, onNewFiles: @escaping ([URL]) -> Void) {
        self.folder = folder
        self.onNewFiles = onNewFiles
    }

    func start() {
        guard source == nil else { return }
        known = Set(currentFiles())
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func currentFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    private func scan() {
        // Files are often written in steps (screenshots appear as a hidden file, then get renamed);
        // wait a moment so they're complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Set(self.currentFiles())
                let added = now.subtracting(self.known)
                self.known = now
                let urls = added.sorted().map { self.folder.appendingPathComponent($0) }
                if !urls.isEmpty { self.onNewFiles(urls) }
            }
        }
    }
}

enum ScreenshotFolder {
    /// Where macOS saves screenshots (set in the Screenshot app's Options), or the Desktop.
    static var url: URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// macOS names them "Screenshot 2026-10-30 at 09.41.12.png" (in English).
    static func isScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        let images = ["png", "jpg", "jpeg", "heic", "tiff", "pdf", "mov"]
        return (lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") || lower.hasPrefix("screen recording"))
            && images.contains((lower as NSString).pathExtension)
    }
}

// MARK: - Shelf actions

/// Things you can do with the files on a shelf. Each makes new files on the shelf, except rename
/// (which renames in place) and copy paths.
enum ShelfAction: String, CaseIterable, Identifiable {
    case zip, resizeHalf, resize1024, convertJPEG, convertPNG, convertHEIC, renameInBulk, copyPaths

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip: return "Zip Files"
        case .resizeHalf: return "Resize Images to Half Size"
        case .resize1024: return "Resize Images to 1024 Pixels"
        case .convertJPEG: return "Convert Images to JPEG"
        case .convertPNG: return "Convert Images to PNG"
        case .convertHEIC: return "Convert Images to HEIC"
        case .renameInBulk: return "Rename in Bulk…"
        case .copyPaths: return "Copy File Paths"
        }
    }

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp"]

    static func isImage(_ url: URL) -> Bool {
        imageTypes.contains(url.pathExtension.lowercased())
    }
}

enum ShelfActions {
    /// Runs a command-line tool that comes with macOS and waits for it.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// One zip archive of all the files, in `folder`.
    static func zip(_ files: [URL], into folder: URL, name: String) -> URL? {
        guard !files.isEmpty else { return nil }
        let archive = ShelfStore.unusedURL(for: name + ".zip", in: folder)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-zip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in files {
            try? FileManager.default.copyItem(at: file, to: ShelfStore.unusedURL(for: file.lastPathComponent, in: staging))
        }
        guard run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, archive.path]) else { return nil }
        return archive
    }

    /// Resized copies (longest side `maxSize` pixels, or half size when nil), in `folder`.
    static func resize(_ files: [URL], into folder: URL, maxSize: Int?) -> [URL] {
        files.filter(ShelfAction.isImage).compactMap { file in
            let base = file.deletingPathExtension().lastPathComponent
            let output = ShelfStore.unusedURL(for: "\(base) (resized).\(file.pathExtension)", in: folder)
            let current = NSImageRep(contentsOf: file).map { max($0.pixelsWide, $0.pixelsHigh) } ?? 0
            var size = maxSize
            if size == nil { size = current / 2 }
            // Never make an image bigger than it is.
            if let wanted = size, current > 0, wanted >= current { return nil }
            guard let size, size > 0, run("/usr/bin/sips", ["-Z", String(size), file.path, "--out", output.path]) else { return nil }
            return output
        }
    }

    /// Converted copies in another image format, in `folder`.
    static func convert(_ files: [URL], into folder: URL, format: String, fileExtension: String) -> [URL] {
        files.filter(ShelfAction.isImage).compactMap { file in
            let base = file.deletingPathExtension().lastPathComponent
            let output = ShelfStore.unusedURL(for: "\(base).\(fileExtension)", in: folder)
            guard run("/usr/bin/sips", ["-s", "format", format, file.path, "--out", output.path]) else { return nil }
            return output
        }
    }

    /// New names for bulk renaming: "Base 1.ext", "Base 2.ext"… in the files' order.
    static func bulkNames(for files: [URL], base: String) -> [URL] {
        let width = String(files.count).count
        return files.enumerated().map { index, file in
            let number = String(index + 1)
            let padded = String(repeating: "0", count: max(0, width - number.count)) + number
            let ext = file.pathExtension
            let name = ext.isEmpty ? "\(base) \(padded)" : "\(base) \(padded).\(ext)"
            return file.deletingLastPathComponent().appendingPathComponent(name)
        }
    }
}
