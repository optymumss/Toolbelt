import AppKit
import ApplicationServices

// What macro conditions and the newer triggers need to know about the Mac: the front window, running
// apps, files, keys held down, the screen's colours and pictures, the clipboard and the login time.
// The deciding parts are plain logic (tested in Tests.swift); the reading parts talk to macOS.

/// Everything a condition can ask about the Mac. `live` asks macOS; the tests pass their own answers.
struct ConditionWorld {
    var frontApp: () -> String? = { nil }
    var windowTitle: () -> String? = { nil }
    /// Bundle IDs and names of the running apps.
    var runningApps: () -> [String] = { [] }
    var fileExists: (String) -> Bool = { _ in false }
    var modifiers: () -> NSEvent.ModifierFlags = { [] }
    /// The colour at a point (top-left based screen points).
    var pixel: (CGPoint) async -> RGBColor? = { _ in nil }
    /// Where a picture (a PNG's path) is on screen, in points from the top left; nil if it isn't.
    var findOnScreen: (String) async -> CGPoint? = { _ in nil }

    static var live: ConditionWorld {
        ConditionWorld(
            frontApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            windowTitle: { FrontWindow.title() },
            runningApps: { NSWorkspace.shared.runningApplications.flatMap { [$0.bundleIdentifier, $0.localizedName].compactMap { $0 } } },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            modifiers: { NSEvent.modifierFlags },
            pixel: { point in await ScreenReader.color(at: point) },
            findOnScreen: { path in await ScreenReader.find(path) }
        )
    }
}

// MARK: - Keys held down

enum ModifierNames {
    static let all: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    /// "⌘⌥", "cmd+opt", "command option", "control, shift", "fn" …
    static func parse(_ text: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let symbols: [(Character, NSEvent.ModifierFlags)] = [("⌘", .command), ("⌥", .option), ("⌃", .control), ("⇧", .shift)]
        for (symbol, flag) in symbols where text.contains(symbol) { flags.insert(flag) }
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        for word in words {
            switch word {
            case "cmd", "command": flags.insert(.command)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control", "ctl": flags.insert(.control)
            case "shift": flags.insert(.shift)
            case "fn", "function": flags.insert(.function)
            default: break
            }
        }
        return flags
    }

    static func display(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.function) { text += "fn" }
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text.isEmpty ? "no keys" : text
    }
}

// MARK: - Colours and points

/// A point written "x,y" (screen points from the top left of the main screen).
enum ScreenPoint {
    static func parse(_ text: String) -> CGPoint? {
        let parts = text.split { $0 == "," || $0 == " " }.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }
}

struct RGBColor: Equatable {
    var red: Int
    var green: Int
    var blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#FF8800", "ff8800" or "F80".
    init?(hex text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(red: (value >> 16) & 0xFF, green: (value >> 8) & 0xFF, blue: value & 0xFF)
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Screens, colour profiles and smoothing shift colours a little, so "the same" allows some difference.
    func isClose(to other: RGBColor, tolerance: Int = 32) -> Bool {
        abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance && abs(blue - other.blue) <= tolerance
    }
}

// MARK: - Finding a picture on the screen

/// A picture in shades of grey, one byte per pixel, rows from the top.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(cgImage: CGImage) {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }
}

enum ImageFinder {
    /// The top-left pixel where `needle` appears in `haystack`, or nil. `tolerance` is the average
    /// difference allowed per pixel (0–255), for small changes from colour profiles and smoothing.
    static func find(_ needle: GrayImage, in haystack: GrayImage, tolerance: Int = 12) -> (x: Int, y: Int)? {
        guard needle.width > 0, needle.height > 0, needle.width <= haystack.width, needle.height <= haystack.height else { return nil }
        // A quick look at about 150 spread-out pixels first; only places that pass get the full comparison.
        let stepX = max(1, needle.width / 12), stepY = max(1, needle.height / 12)
        var samples: [(dx: Int, dy: Int, value: Int)] = []
        var y = stepY / 2
        while y < needle.height {
            var x = stepX / 2
            while x < needle.width {
                samples.append((x, y, Int(needle[x, y])))
                x += stepX
            }
            y += stepY
        }
        let quickLimit = tolerance * samples.count
        let fullLimit = tolerance * needle.width * needle.height
        let hay = haystack.pixels, hayWidth = haystack.width
        for top in 0...(haystack.height - needle.height) {
            for left in 0...(haystack.width - needle.width) {
                var sum = 0
                for sample in samples {
                    sum += abs(Int(hay[(top + sample.dy) * hayWidth + left + sample.dx]) - sample.value)
                    if sum > quickLimit { break }
                }
                guard sum <= quickLimit else { continue }
                if matchesFully(needle, hay, hayWidth, left, top, limit: fullLimit) { return (left, top) }
            }
        }
        return nil
    }

    private static func matchesFully(_ needle: GrayImage, _ hay: [UInt8], _ hayWidth: Int, _ left: Int, _ top: Int, limit: Int) -> Bool {
        var sum = 0
        for y in 0..<needle.height {
            let row = (top + y) * hayWidth + left
            for x in 0..<needle.width {
                sum += abs(Int(hay[row + x]) - Int(needle.pixels[y * needle.width + x]))
            }
            if sum > limit { return false }
        }
        return true
    }
}

/// Reads the screen with macOS's screencapture tool (needs Screen Recording).
enum ScreenReader {
    static func image(at url: URL?) -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func color(at point: CGPoint) async -> RGBColor? {
        // A small square around the point (a single point is too small for screencapture to be reliable); its middle pixel.
        let file = await ScreenshotCapture.capture(rect: CGRect(x: point.x - 2, y: point.y - 2, width: 5, height: 5))
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        guard let image = image(at: file) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return nil }
        return RGBColor(red: Int((color.redComponent * 255).rounded()), green: Int((color.greenComponent * 255).rounded()),
                        blue: Int((color.blueComponent * 255).rounded()))
    }

    static func find(_ picture: String) async -> CGPoint? {
        guard let needleImage = image(at: URL(fileURLWithPath: picture)), let needle = GrayImage(cgImage: needleImage) else { return nil }
        let screen = await MainActor.run { NSScreen.screens.first?.frame.size ?? .zero }
        let file = await ScreenshotCapture.capture(rect: CGRect(origin: .zero, size: screen))
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        guard let shot = image(at: file), let haystack = GrayImage(cgImage: shot), screen.width > 0 else { return nil }
        let scale = Double(shot.width) / screen.width // pixels per point (2 on Retina screens)
        return await Task.detached(priority: .userInitiated) { () -> CGPoint? in
            guard let spot = ImageFinder.find(needle, in: haystack) else { return nil }
            return CGPoint(x: Double(spot.x) / scale, y: Double(spot.y) / scale)
        }.value
    }
}

// MARK: - The front window

enum FrontWindow {
    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement) // swiftlint:disable:this force_cast
    }

    static func title(of window: AXUIElement) -> String? {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    /// The title of the front app's focused window (needs Accessibility).
    static func title() -> String? {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = focusedWindow(of: pid) else { return nil }
        return title(of: window)
    }
}

/// Decides, from what the front window is now, whether a different window came to the front or the same
/// one changed its title. The first look only remembers.
struct WindowChangeTracker {
    enum Change: Equatable { case none, window, title }

    private(set) var window: String?
    private(set) var title: String?
    private var started = false

    mutating func update(window: String?, title: String?) -> Change {
        defer {
            self.window = window
            self.title = title
            started = true
        }
        guard started, let window else { return .none }
        if window != self.window { return .window }
        if title != self.title { return .title }
        return .none
    }
}

/// Watches the front window with Accessibility notifications (no polling): a different window in front,
/// or the front window's title changing.
@MainActor
final class FrontWindowWatcher {
    var onChange: ((WindowChangeTracker.Change, String) -> Void)?
    private var tracker = WindowChangeTracker()
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedWindow: AXUIElement?
    private var activation: NSObjectProtocol?

    func start() {
        guard activation == nil, PermissionGate.ensure(.accessibility, to: "notice when the front window changes") else { return }
        tracker = WindowChangeTracker()
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToFrontApp() }
        }
        attachToFrontApp()
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        detach()
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observedWindow = nil
        observedPID = 0
    }

    private func attachToFrontApp() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        if pid != observedPID {
            detach()
            var created: AXObserver?
            guard AXObserverCreate(pid, frontWindowCallback, &created) == .success, let created else { return }
            let me = Unmanaged.passUnretained(self).toOpaque()
            let app = AXUIElementCreateApplication(pid)
            AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString, me)
            AXObserverAddNotification(created, app, kAXMainWindowChangedNotification as CFString, me)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            observer = created
            observedPID = pid
        }
        refresh()
    }

    fileprivate func refresh() {
        guard let observer else { return }
        let window = FrontWindow.focusedWindow(of: observedPID)
        if let window, observedWindow.map({ !CFEqual($0, window) }) ?? true {
            let me = Unmanaged.passUnretained(self).toOpaque()
            if let old = observedWindow { AXObserverRemoveNotification(observer, old, kAXTitleChangedNotification as CFString) }
            AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, me)
            observedWindow = window
        }
        let title = window.flatMap { FrontWindow.title(of: $0) } ?? ""
        let key = window.map { "\(observedPID):\(CFHash($0))" }
        let change = tracker.update(window: key, title: title)
        if change != .none { onChange?(change, title) }
    }
}

private func frontWindowCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<FrontWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.refresh() }
}

// MARK: - The clipboard

/// Notices copies by checking the clipboard's change counter twice a second (macOS has no notification).
@MainActor
final class ClipboardWatcher {
    var onChange: ((String) -> Void)?
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount

    func start() {
        guard timer == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastCount else { return }
        lastCount = pasteboard.changeCount
        // Password managers mark what they copy; it shouldn't start anything.
        if pasteboard.types?.contains(where: { $0.rawValue == "org.nspasteboard.ConcealedType" }) == true { return }
        onChange?(pasteboard.string(forType: .string) ?? "")
    }
}

// MARK: - Login

enum LoginTime {
    /// Toolbelt counts as started "at login" when it started within three minutes of logging in.
    static func isAtLogin(started: Date, loggedIn: Date?) -> Bool {
        guard let loggedIn else { return false }
        let gap = started.timeIntervalSince(loggedIn)
        return gap >= -5 && gap <= 180
    }

    /// When this person logged in at the Mac's screen (the system's login records).
    static func current() -> Date? {
        var latest: Date?
        setutxent()
        defer { endutxent() }
        let user = NSUserName()
        while let entry = getutxent() {
            guard Int(entry.pointee.ut_type) == Int(USER_PROCESS) else { continue }
            let name = withUnsafeBytes(of: entry.pointee.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let time = Date(timeIntervalSince1970: Double(entry.pointee.ut_tv.tv_sec))
            if latest.map({ time > $0 }) ?? true { latest = time }
        }
        return latest
    }
}
