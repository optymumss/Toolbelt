import AppKit

// MARK: - Queues

/// A named queue of downloads. Only `maxAtOnce` of its downloads run at a time (0: no limit, like IDM); the rest wait.
/// A queue can be started and stopped by hand or at set times.
struct DownloadQueue: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var maxAtOnce = 0
    var isRunning = true
    /// Minutes after midnight to start or stop it each day (nil: not scheduled).
    var startAt: Int? = nil
    var stopAt: Int? = nil

    static func main() -> DownloadQueue { DownloadQueue(name: "Main") }

    var hasNoLimit: Bool { maxAtOnce <= 0 }
    var limitText: String { hasNoLimit ? "No limit" : "\(maxAtOnce) at a time" }

    var scheduleText: String? {
        switch (startAt, stopAt) {
        case let (start?, stop?): return "Runs \(Self.clock(start))–\(Self.clock(stop))"
        case let (start?, nil): return "Starts at \(Self.clock(start))"
        case let (nil, stop?): return "Stops at \(Self.clock(stop))"
        default: return nil
        }
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// Works out when queues start and stop.
enum DownloadSchedule {
    struct Event: Equatable {
        var date: Date
        var queueID: UUID
        var start: Bool
    }

    /// The next time any queue is due to start or stop, after `date`.
    static func next(after date: Date, queues: [DownloadQueue], calendar: Calendar = .current) -> Event? {
        events(around: date, queues: queues, calendar: calendar, direction: .forward).min { $0.date < $1.date }
    }

    /// Whether a scheduled queue should be running at `date` (from its most recent start or stop).
    /// nil when the queue has no schedule.
    static func shouldRun(_ queue: DownloadQueue, at date: Date, calendar: Calendar = .current) -> Bool? {
        events(around: date, queues: [queue], calendar: calendar, direction: .backward).max { $0.date < $1.date }?.start
    }

    private static func events(around date: Date, queues: [DownloadQueue], calendar: Calendar,
                               direction: Calendar.SearchDirection) -> [Event] {
        var events: [Event] = []
        for queue in queues {
            for (minutes, start) in [(queue.startAt, true), (queue.stopAt, false)] {
                guard let minutes else { continue }
                let parts = DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0)
                if let when = calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime, direction: direction) {
                    events.append(Event(date: when, queueID: queue.id, start: start))
                }
            }
        }
        return events
    }
}

/// What to do once every download has finished. Chosen per session, then switches back to nothing.
enum WhenDone: String, CaseIterable, Identifiable {
    case nothing, sleep, shutDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: return "Do Nothing"
        case .sleep: return "Sleep the Mac"
        case .shutDown: return "Shut Down the Mac"
        }
    }

    /// Puts the Mac to sleep or shuts it down.
    @MainActor
    func perform() {
        switch self {
        case .nothing:
            break
        case .sleep:
            ShelfActions.run("/usr/bin/pmset", ["sleepnow"])
        case .shutDown:
            // Asks the login window to shut down, like choosing Shut Down from the Apple menu.
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"loginwindow\" to «event aevtrsdn»")?.executeAndReturnError(&error)
        }
    }
}

// MARK: - Speed limit and hourly cap

/// Shared by every download, so the limits apply to all of them together. Thread-safe.
/// A download that's over the limit is asked to wait; its connection simply stops reading for a
/// moment, which slows the server down without wasting any data.
final class DownloadThrottle: @unchecked Sendable {
    static let shared = DownloadThrottle()

    private let lock = NSLock()
    private let now: () -> Date
    private var bytesPerSecond: Double = 0
    private var hourlyCap: Int64 = 0
    private var tokens: Double = 0
    private var lastRefill: Date
    private var hour = 0
    private var bytesThisHour: Int64 = 0

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        lastRefill = now()
    }

    /// 0 means no limit.
    func configure(bytesPerSecond: Double, hourlyCap: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if bytesPerSecond != self.bytesPerSecond {
            self.bytesPerSecond = bytesPerSecond
            tokens = burst
            lastRefill = now()
        }
        self.hourlyCap = hourlyCap
    }

    private var burst: Double { max(bytesPerSecond / 2, 64 * 1024) }

    /// Records `bytes` just received; returns how many seconds that connection should pause.
    func take(_ bytes: Int64) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let date = now()
        rollHour(date)
        bytesThisHour += bytes
        if hourlyCap > 0, bytesThisHour >= hourlyCap {
            return secondsToNextHour(date)
        }
        guard bytesPerSecond > 0 else { return 0 }
        tokens = min(burst, tokens + date.timeIntervalSince(lastRefill) * bytesPerSecond)
        lastRefill = date
        tokens -= Double(bytes)
        return tokens < 0 ? -tokens / bytesPerSecond : 0
    }

    /// When the hourly cap has been used up, how many seconds until downloads can carry on.
    var capWait: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        let date = now()
        rollHour(date)
        guard hourlyCap > 0, bytesThisHour >= hourlyCap else { return nil }
        return secondsToNextHour(date)
    }

    private func rollHour(_ date: Date) {
        let current = Int(date.timeIntervalSince1970 / 3600)
        if current != hour {
            hour = current
            bytesThisHour = 0
        }
    }

    private func secondsToNextHour(_ date: Date) -> TimeInterval {
        let seconds = date.timeIntervalSince1970
        return (floor(seconds / 3600) + 1) * 3600 - seconds
    }
}

// MARK: - What the list shows

enum DownloadColumn: String, CaseIterable, Identifiable {
    case size, speed, timeLeft, connections, queue, added

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: return "Size"
        case .speed: return "Speed"
        case .timeLeft: return "Time Left"
        case .connections: return "Connections"
        case .queue: return "Queue"
        case .added: return "Date Added"
        }
    }

    static let defaults: [DownloadColumn] = [.size, .speed, .timeLeft, .connections]
}

enum DownloadButton: String, CaseIterable, Identifiable {
    case pauseResume, open, reveal, remove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pauseResume: return "Pause and Resume"
        case .open: return "Open"
        case .reveal: return "Show in Finder"
        case .remove: return "Remove"
        }
    }

    static let defaults: [DownloadButton] = [.pauseResume, .reveal, .remove]
}

// MARK: - Links handed over by the browser

/// A download request from the Chrome extension, written by ToolbeltBridge into
/// ~/Library/Application Support/Toolbelt/inbox/ as a .json file.
struct DownloadRequest: Codable {
    var url: String
    var name: String?
    var referrer: String?
    var cookies: String?
    var userAgent: String?
    /// "hls" for a streamed video picked from the video button's list of sizes.
    var kind: String?
    var audioUrl: String?
    /// From the video button: download quietly (progress shows in the menu bar) instead of showing the list.
    var quiet: Bool?

    var headers: [String: String] {
        var headers: [String: String] = [:]
        if let cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        if let referrer, !referrer.isEmpty {
            headers["Referer"] = referrer
            // Video servers often check where the request comes from.
            if kind == "hls", let url = URL(string: referrer), let scheme = url.scheme, let host = url.host {
                headers["Origin"] = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
            }
        }
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        return headers
    }
}
