import AppKit
import CoreAudio
import ImageIO
import UniformTypeIdentifiers

// 0.37: macros that talk to the web, work with JSON and pictures, and new triggers.
// - `WebRequest`: a request's headers and body from the step, and the answer (status, body).
// - `JSONTool`: a value at a path ("items[0].name"), how many things are in a list, and JSON made from Name=value lines.
// - `ScreenGrab`: screenshots of the screen, the front window or an area, to a file or the clipboard.
// - `PictureFile` / `PictureEdit`: open a picture file, change it (flip, rotate, resize, crop, trim, convert) and save it.
// - `FolderSnapshot` + `FolderChangeWatcher`: files added, changed or removed in a folder.
// - `ThemeWatcher` (dark mode) and `SoundOutputWatcher` (the Mac's sound output).

// MARK: - Web requests

enum WebRequest {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    /// "Name: value" lines → headers (blank lines and lines without a colon are left out).
    static func headers(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
        }
        return result
    }

    static func request(url: URL, method: String, headers: [String: String], body: String, timeout: Double?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: max(1, timeout ?? 30))
        request.httpMethod = methods.contains(method.uppercased()) ? method.uppercased() : "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil { request.setValue("Toolbelt", forHTTPHeaderField: "User-Agent") }
        if !body.isEmpty, request.httpMethod != "GET", request.httpMethod != "HEAD" {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let isJSON = (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
                request.setValue(isJSON ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    struct Answer {
        var status: Int
        var body: String
        var headers: [String: String]
        var error: String?
    }

    /// Sends it through the downloads' proxy. A network error gives status 0 and the error.
    static func send(_ request: URLRequest) async -> Answer {
        do {
            let (data, response) = try await NetworkSettings.sharedSession.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] { headers["\(key)"] = "\(value)" }
            let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            return Answer(status: http?.statusCode ?? 0, body: body, headers: headers)
        } catch {
            return Answer(status: 0, body: "", headers: [:], error: error.localizedDescription)
        }
    }
}

// MARK: - JSON

enum JSONMode: String, Codable, CaseIterable, Identifiable {
    case get, count, keys, make

    var id: String { rawValue }
    var title: String {
        switch self {
        case .get: return "Get a value"
        case .count: return "Count the items in a list"
        case .keys: return "List the names in an object"
        case .make: return "Make JSON from Name=value lines"
        }
    }
}

enum JSONTool {
    /// "items[0].name", "items.0.name", "['odd key'].x" → ["items", 0, "name"] as path parts.
    enum Part: Equatable { case key(String), index(Int) }

    static func parts(_ path: String) -> [Part] {
        var parts: [Part] = []
        var current = ""
        var index = path.startIndex
        func flush() {
            if !current.isEmpty { parts.append(Int(current).map { .index($0) } ?? .key(current)) }
            current = ""
        }
        while index < path.endIndex {
            let character = path[index]
            if character == "." {
                flush()
            } else if character == "[" {
                flush()
                guard let close = path[index...].firstIndex(of: "]") else { break }
                var inside = String(path[path.index(after: index)..<close]).trimmingCharacters(in: .whitespaces)
                if inside.count >= 2, let first = inside.first, first == "'" || first == "\"", inside.last == first {
                    inside = String(inside.dropFirst().dropLast())
                    parts.append(.key(inside))
                } else if let number = Int(inside) {
                    parts.append(.index(number))
                } else if !inside.isEmpty {
                    parts.append(.key(inside))
                }
                index = close
            } else {
                current.append(character)
            }
            index = path.index(after: index)
        }
        flush()
        return parts
    }

    static func parse(_ text: String) -> Any? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The thing at `path` (an empty path: the whole thing). A negative index counts from the end.
    static func find(_ root: Any, _ path: String) -> Any? {
        var current: Any? = root
        for part in parts(path) {
            switch part {
            case .key(let key):
                current = (current as? [String: Any])?[key]
            case .index(let index):
                if let list = current as? [Any] {
                    let position = index < 0 ? list.count + index : index
                    current = list.indices.contains(position) ? list[position] : nil
                } else {
                    current = (current as? [String: Any])?[String(index)]
                }
            }
            if current == nil { return nil }
        }
        return current
    }

    /// As text for a variable: strings as they are, numbers and true/false as written, the rest as compact JSON.
    static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The answer for a mode, or nil when the JSON can't be read or the path isn't there.
    static func run(_ mode: JSONMode, json: String, path: String) -> String? {
        if mode == .make { return make(path) }
        guard let root = parse(json), let found = find(root, path) else { return nil }
        switch mode {
        case .get: return text(found)
        case .count:
            if let list = found as? [Any] { return String(list.count) }
            if let object = found as? [String: Any] { return String(object.count) }
            return nil
        case .keys:
            guard let object = found as? [String: Any] else { return nil }
            return object.keys.sorted().joined(separator: "\n")
        case .make: return nil
        }
    }

    /// Name=value lines → a JSON object. Numbers, true/false/null and JSON lists or objects keep their type;
    /// "a.b=1" makes nested objects.
    static func make(_ lines: String) -> String {
        var object: [String: Any] = [:]
        for (name, value) in MacroInputs.parse(lines) {
            let typed: Any
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let number = Double(trimmed), !trimmed.isEmpty, trimmed.first != "+" {
                typed = number.rounded() == number && abs(number) < 1e15 ? NSNumber(value: Int64(number)) : NSNumber(value: number)
            } else if trimmed == "true" || trimmed == "false" {
                typed = trimmed == "true"
            } else if trimmed == "null" {
                typed = NSNull()
            } else if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")), let parsed = parse(trimmed) {
                typed = parsed
            } else {
                typed = value
            }
            insert(typed, at: name.split(separator: ".").map(String.init), into: &object)
        }
        return text(object)
    }

    private static func insert(_ value: Any, at path: [String], into object: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object[first] = value
        } else {
            var inner = object[first] as? [String: Any] ?? [:]
            insert(value, at: Array(path.dropFirst()), into: &inner)
            object[first] = inner
        }
    }
}

// MARK: - Screenshots in macros

enum CaptureArea: String, Codable, CaseIterable, Identifiable {
    case screen, frontWindow, area

    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: return "The whole screen"
        case .frontWindow: return "The front window"
        case .area: return "An area (x, y, width, height)"
        }
    }
}

enum ScreenGrab {
    /// "x,y,w,h" (or with spaces) → a rectangle in screen points from the top left.
    static func rect(_ text: String) -> CGRect? {
        let numbers = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// The front app's frontmost normal window (for screencapture -l).
    static func frontWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// screencapture's arguments: no sound, to the clipboard (empty path) or a file.
    static func arguments(_ area: CaptureArea, rect: CGRect?, window: CGWindowID?, to path: String) -> [String]? {
        var arguments = ["-x"]
        switch area {
        case .screen: arguments.append("-m")
        case .frontWindow:
            guard let window else { return nil }
            arguments += ["-o", "-l", String(window)]
        case .area:
            guard let rect else { return nil }
            arguments.append("-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
        }
        if path.isEmpty {
            arguments.append("-c")
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "tiff", "pdf", "heic"].contains(ext) { arguments += ["-t", ext == "jpeg" ? "jpg" : ext] }
            arguments.append(path)
        }
        return arguments
    }
}

// MARK: - Picture files

enum PictureEdit: String, Codable, CaseIterable, Identifiable {
    case convert, flipHorizontal, flipVertical, rotateLeft, rotateRight, halfSize, resize, crop, trim, readText

    var id: String { rawValue }
    var title: String {
        switch self {
        case .convert: return "Save as another type (the new name's ending: .png, .jpg…)"
        case .resize: return "Resize to a width (keeping its shape)"
        case .crop: return "Crop to an area (x, y, width, height)"
        default: return filter?.title ?? rawValue
        }
    }

    /// The clipboard-picture change that does the same.
    var filter: PictureFilter? { PictureFilter(rawValue: rawValue) }
}

enum PictureFile {
    static func load(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Writes a picture; the type comes from the name's ending (PNG when it has none it knows).
    @discardableResult
    static func save(_ image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": type = .jpeg
        case "tif", "tiff": type = .tiff
        case "heic": type = .heic
        case "gif": type = .gif
        case "bmp": type = .bmp
        default: type = .png
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The changed picture (all but readText). `width` for resize, `area` ("x,y,w,h" in pixels from the top left) for crop.
    static func apply(_ edit: PictureEdit, to image: CGImage, width: Double, area: String) -> CGImage? {
        switch edit {
        case .convert: return image
        case .resize:
            let newWidth = max(1, Int(width.rounded()))
            let newHeight = max(1, Int((Double(image.height) * Double(newWidth) / Double(max(1, image.width))).rounded()))
            guard let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            return context.makeImage()
        case .crop:
            guard let rect = ScreenGrab.rect(area) else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let clipped = rect.intersection(bounds)
            return clipped.isEmpty ? nil : image.cropping(to: clipped)
        default:
            return edit.filter?.apply(image)
        }
    }
}

// MARK: - Folder changes

/// What's in a folder: each visible file's name with its size and modification date.
struct FolderSnapshot: Equatable {
    struct Entry: Equatable { var size: Int64; var modified: Date }
    var entries: [String: Entry] = [:]

    static func take(_ folder: URL) -> FolderSnapshot {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        var snapshot = FolderSnapshot()
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            snapshot.entries[url.lastPathComponent] = Entry(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
        return snapshot
    }

    /// Names added, changed (new size or date) and removed since `old`, each sorted.
    func changes(since old: FolderSnapshot) -> (added: [String], changed: [String], removed: [String]) {
        let added = entries.keys.filter { old.entries[$0] == nil }.sorted()
        let removed = old.entries.keys.filter { entries[$0] == nil }.sorted()
        let changed = entries.keys.filter { name in old.entries[name].map { $0 != entries[name] } ?? false }.sorted()
        return (added, changed, removed)
    }
}

/// Notices files changed or removed in a folder: the folder's own events (files added, removed, renamed, or
/// saved by replacing them), plus a look every few seconds for files written in place.
@MainActor
final class FolderChangeWatcher {
    let folder: URL
    private var snapshot = FolderSnapshot()
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private let onChange: (_ changed: [URL], _ removed: [URL]) -> Void

    init(folder: URL, onChange: @escaping (_ changed: [URL], _ removed: [URL]) -> Void) {
        self.folder = folder
        self.onChange = onChange
    }

    func start(lookEvery seconds: TimeInterval = 3) {
        guard source == nil else { return }
        snapshot = FolderSnapshot.take(folder)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.look() } }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.look() } }
        timer.tolerance = seconds / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    func look() {
        let now = FolderSnapshot.take(folder)
        let changes = now.changes(since: snapshot)
        snapshot = now
        guard !changes.changed.isEmpty || !changes.removed.isEmpty else { return }
        onChange(changes.changed.map { folder.appendingPathComponent($0) }, changes.removed.map { folder.appendingPathComponent($0) })
    }
}

// MARK: - Dark mode and sound output

/// Dark mode switched on or off (macOS tells every app with a distributed notification).
@MainActor
final class ThemeWatcher {
    private var observer: NSObjectProtocol?
    var onChange: ((_ dark: Bool) -> Void)?

    /// The system's own setting (not Toolbelt's Look, which can differ), read fresh.
    static var isDark: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
    }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                                       object: nil, queue: .main) { [weak self] _ in
            // The setting is written just before the notification; read it a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    self?.onChange?(Self.isDark)
                }
            }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }
}

/// The Mac's sound output switching to another device (AirPods connecting, a display's speakers…).
@MainActor
final class SoundOutputWatcher {
    var onChange: ((_ name: String) -> Void)?
    private var listening = false
    private var block: AudioObjectPropertyListenerBlock?
    private var last: String?
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !listening else { return }
        last = AudioOutputs.currentName()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let name = AudioOutputs.currentName(), name != self.last else { return }
                    self.last = name
                    self.onChange?(name)
                }
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            self.block = block
            listening = true
        }
    }

    func stop() {
        if let block { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) }
        block = nil
        listening = false
    }
}
