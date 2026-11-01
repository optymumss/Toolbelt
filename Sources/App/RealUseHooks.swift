import AppKit

/// Only for the real-use tests on GitHub's Mac (`.github/scripts/real-use.sh`), and only when Toolbelt is
/// started with TOOLBELT_E2E=1. Otherwise nothing here runs.
///
/// - Writes `e2e-status.json` into the data folder: which permissions Toolbelt has, so the test can
///   tell "a feature is broken" apart from "macOS didn't give Toolbelt the permission".
/// - Accepts pretend trackpad touches (GitHub's Macs have no trackpad): the test app sends finger
///   positions, and they go through exactly the same recognizer and rules as real ones.
@MainActor
enum RealUseHooks {
    static let touchNotification = Notification.Name("local.personal.toolbelt.e2e.touches")

    static var isOn: Bool { ProcessInfo.processInfo.environment["TOOLBELT_E2E"] == "1" }

    private static var observer: NSObjectProtocol?
    /// Toolbelt's shortcuts that couldn't be registered because something else has them.
    private static var takenShortcuts: () -> [String] = { [] }
    /// More things for the status file, from the modules (floating menus, menu-bar items, the preset in use).
    static var extraStatus: [String: () -> Any] = [:]

    static func start(takenShortcuts: @escaping () -> [String] = { [] }) {
        guard isOn else { return }
        self.takenShortcuts = takenShortcuts
        writeStatus()
        observer = DistributedNotificationCenter.default().addObserver(forName: touchNotification, object: nil, queue: .main) { note in
            guard let text = note.object as? String, let frames = parseFrames(text) else { return }
            MultitouchReader.shared.injectForTesting(frames)
        }
        // Permissions can arrive a moment after launch: write the status again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { writeStatus() }
    }

    static func writeStatus() {
        guard isOn else { return }
        var status: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "accessibility": Permission.accessibility.isGranted,
            "inputMonitoring": Permission.inputMonitoring.isGranted,
            "screenRecording": Permission.screenRecording.isGranted,
            "takenShortcuts": takenShortcuts(),
        ]
        for (key, value) in extraStatus { status[key] = value() }
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
            try? data.write(to: SettingsStore.folder.appendingPathComponent("e2e-status.json"), options: .atomic)
        }
    }

    /// Frames as JSON: [{"t": seconds, "p": [[id, x, y], …]}, …]; an empty "p" is every finger lifted.
    nonisolated static func parseFrames(_ text: String) -> [(time: Double, touches: [TouchPoint])]? {
        guard let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.map { frame in
            let time = (frame["t"] as? NSNumber)?.doubleValue ?? 0
            let points = (frame["p"] as? [[NSNumber]] ?? []).compactMap { values -> TouchPoint? in
                guard values.count == 3 else { return nil }
                return TouchPoint(id: values[0].intValue, x: values[1].doubleValue, y: values[2].doubleValue)
            }
            return (time, points)
        }
    }

    /// The same frames written out, for the test app.
    nonisolated static func framesText(_ frames: [(time: Double, touches: [TouchPoint])]) -> String {
        let list: [[String: Any]] = frames.map { frame in
            ["t": frame.time, "p": frame.touches.map { [$0.id, $0.x, $0.y] as [Any] }]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
