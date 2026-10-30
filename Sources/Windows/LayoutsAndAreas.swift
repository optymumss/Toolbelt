import AppKit
import ApplicationServices

// MARK: - Placing rectangles relative to a screen

/// A rectangle stored as fractions of a screen's area, so it fits any screen size.
struct RelativeRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// `frame` and `area` use the same (top-left origin) coordinates.
    init(_ frame: CGRect, in area: CGRect) {
        x = (frame.minX - area.minX) / area.width
        y = (frame.minY - area.minY) / area.height
        width = frame.width / area.width
        height = frame.height / area.height
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func frame(in area: CGRect) -> CGRect {
        CGRect(x: area.minX + x * area.width, y: area.minY + y * area.height,
               width: width * area.width, height: height * area.height).integral
    }
}

/// A name for a display that stays the same between restarts.
@MainActor
enum DisplayID {
    static func name(of screen: NSScreen) -> String {
        "\(screen.localizedName) \(Int(screen.frame.width))×\(Int(screen.frame.height))"
    }

    /// The index in `Screens.all` of the display with this name, if it's connected.
    static func index(named name: String) -> Int? {
        NSScreen.screens.firstIndex { Self.name(of: $0) == name }
    }
}

// MARK: - Saved layouts

/// A set of apps and where their windows go, put back with one shortcut.
struct SavedLayout: Identifiable, Codable, Equatable {
    struct Entry: Codable, Equatable {
        var bundleID: String
        var appName: String
        var display: String
        var place: RelativeRect
    }

    var id = UUID()
    var name: String
    var entries: [Entry]
}

@MainActor
final class LayoutStore: ObservableObject {
    @Published var layouts: [SavedLayout] {
        didSet { if layouts != oldValue { save() } }
    }
    private let file = SettingsStore.folder.appendingPathComponent("layouts.json")

    init() {
        layouts = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SavedLayout].self, from: $0) } ?? []
    }

    private func save() {
        try? JSONEncoder().encode(layouts).write(to: file, options: .atomic)
    }
}

@MainActor
enum LayoutRunner {
    /// Where every visible app's main window is now.
    static func capture() -> [SavedLayout.Entry] {
        guard AXIsProcessTrusted() else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let screens = Screens.all
        var entries: [SavedLayout.Entry] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app.processIdentifier != me {
            guard let bundleID = app.bundleIdentifier, let window = mainWindow(of: app.processIdentifier),
                  let frame = window.frame, !screens.isEmpty else { continue }
            let index = Screens.index(containing: frame)
            entries.append(SavedLayout.Entry(
                bundleID: bundleID, appName: app.localizedName ?? bundleID,
                display: DisplayID.name(of: NSScreen.screens[index]),
                place: RelativeRect(frame, in: screens[index].area)
            ))
        }
        return entries
    }

    static func mainWindow(of pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return AXWindow(element: value as! AXUIElement)
        }
        return AXWindow.focused(in: pid)
    }

    /// Opens any apps that aren't running, then puts each window in its place.
    static func apply(_ layout: SavedLayout, manager: WindowManager) {
        guard PermissionGate.ensure(.accessibility, to: "arrange your windows") else { return }
        for entry in layout.entries {
            Task { @MainActor in
                if NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).isEmpty,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
                // Wait (up to 6 seconds) for the app to have a window.
                for _ in 0..<30 {
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first,
                       let window = mainWindow(of: app.processIdentifier), let current = window.frame {
                        let screens = Screens.all
                        let index = DisplayID.index(named: entry.display) ?? 0
                        guard screens.indices.contains(index) else { return }
                        manager.place(window, at: entry.place.frame(in: screens[index].area), rememberingFrom: current)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }
}

// MARK: - Custom snap areas

/// An area you drew on a display; holding ⌥ while dragging a window over it snaps the window to it.
struct SnapArea: Identifiable, Codable, Equatable {
    var id = UUID()
    var display: String
    /// Relative to the display's usable area (menu bar and Dock excluded).
    var place: RelativeRect
}

@MainActor
final class SnapAreaStore: ObservableObject {
    @Published var areas: [SnapArea] {
        didSet { if areas != oldValue { save() } }
    }
    private let file = SettingsStore.folder.appendingPathComponent("snapareas.json")

    init() {
        areas = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SnapArea].self, from: $0) } ?? []
    }

    func areas(on display: String) -> [SnapArea] {
        areas.filter { $0.display == display }
    }

    /// The area under a point on a display (top-left coordinates), smallest first when areas overlap.
    static func area(at point: CGPoint, among areas: [SnapArea], in screenArea: CGRect) -> CGRect? {
        areas.map { $0.place.frame(in: screenArea) }
            .filter { $0.contains(point) }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    private func save() {
        try? JSONEncoder().encode(areas).write(to: file, options: .atomic)
    }
}

// MARK: - Drawing snap areas

/// A see-through window over a whole display where you draw, select and delete snap areas.
@MainActor
final class SnapAreaEditor {
    private let store: SnapAreaStore
    private var windows: [NSWindow] = []

    init(store: SnapAreaStore) {
        self.store = store
    }

    var isOpen: Bool { !windows.isEmpty }

    func open() {
        close()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: false)
            let view = SnapAreaCanvas(store: store, screen: screen) { [weak self] in self?.close() }
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate()
        windows.first?.makeKey()
    }

    func close() {
        for window in windows { window.orderOut(nil) }
        windows = []
    }
}

final class SnapAreaCanvas: NSView {
    private let store: SnapAreaStore
    private let screen: NSScreen
    private let onDone: () -> Void
    private var dragStart: NSPoint?
    private var dragNow: NSPoint?
    private var selected: UUID?

    init(store: SnapAreaStore, screen: NSScreen, onDone: @escaping () -> Void) {
        self.store = store
        self.screen = screen
        self.onDone = onDone
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var display: String { MainActor.assumeIsolated { DisplayID.name(of: screen) } }

    /// The usable area in this view's coordinates (bottom-left origin).
    private var usable: NSRect {
        let visible = screen.visibleFrame
        return NSRect(x: visible.minX - screen.frame.minX, y: visible.minY - screen.frame.minY,
                      width: visible.width, height: visible.height)
    }

    /// Converts between this view's rectangles and the stored, top-left-based fractions.
    private func viewRect(_ place: RelativeRect) -> NSRect {
        let u = usable
        return NSRect(x: u.minX + place.x * u.width, y: u.maxY - (place.y + place.height) * u.height,
                      width: place.width * u.width, height: place.height * u.height)
    }

    private func place(_ rect: NSRect) -> RelativeRect {
        let u = usable
        return RelativeRect(x: (rect.minX - u.minX) / u.width, y: (u.maxY - rect.maxY) / u.height,
                            width: rect.width / u.width, height: rect.height / u.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        let areas = MainActor.assumeIsolated { store.areas(on: display) }
        for (number, area) in areas.enumerated() {
            let rect = viewRect(area.place).insetBy(dx: 3, dy: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            (area.id == selected ? NSColor.systemOrange : NSColor.controlAccentColor).withAlphaComponent(0.35).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
            drawText("\(number + 1)", in: rect, size: 42)
        }
        if let start = dragStart, let now = dragNow {
            let rect = NSRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        }
        let help = "Drag to draw a snap area · click one and press ⌫ to delete it · esc or ↩ when done\nWhile dragging a window, hold ⌥ over an area to snap the window into it."
        drawText(help, in: NSRect(x: 0, y: bounds.maxY - 120, width: bounds.width, height: 80), size: 16)
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]
        let height = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], attributes: attributes).height
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let areas = MainActor.assumeIsolated { store.areas(on: display) }
        if let hit = areas.last(where: { viewRect($0.place).contains(point) }) {
            selected = hit.id
            dragStart = nil
        } else {
            selected = nil
            dragStart = point
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragNow = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragNow = nil; needsDisplay = true }
        guard let start = dragStart, let now = dragNow else { return }
        let rect = NSRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
            .intersection(usable)
        guard rect.width > 40, rect.height > 40 else { return }
        let area = SnapArea(display: display, place: place(rect))
        MainActor.assumeIsolated { store.areas.append(area) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // ⌫, ⌦
            if let selected {
                MainActor.assumeIsolated { store.areas.removeAll { $0.id == selected } }
                self.selected = nil
                needsDisplay = true
            }
        case 53, 36: // esc, return
            MainActor.assumeIsolated { onDone() }
        default:
            super.keyDown(with: event)
        }
    }
}
