import AppKit
import Combine

/// Keeps the list of downloads, runs them, and saves their progress so they survive restarts.
/// Saved in ~/Library/Application Support/Toolbelt/downloads.json; partial files in …/Toolbelt/downloads/.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    @Published var queues: [DownloadQueue] = [] {
        didSet { if queues != oldValue { saveQueues(); schedule(); armScheduleTimer() } }
    }
    /// What to do when everything has finished; goes back to nothing once done.
    @Published var whenDone: WhenDone = .nothing
    /// Set while the hourly data cap is used up: downloads carry on at this time.
    @Published private(set) var cappedUntil: Date?

    /// Called when a download finishes (for the notification).
    var onFinished: ((DownloadItem) -> Void)?
    /// Set while downloads wait because the disk is nearly full; they carry on when there's room again.
    @Published private(set) var waitingForSpace = false
    /// Called when downloads pause for lack of space (with the space left).
    var onLowSpace: ((Int64) -> Void)?
    /// Free space where downloads are kept (the tests pretend the disk is full).
    var freeSpace: () -> Int64? = { nil }
    static let minimumFreeSpace: Int64 = 2_000_000_000
    private var spaceTimer: Timer?
    private var ticks = 0

    /// Called when every download has finished and `whenDone` is set.
    var onAllDone: ((WhenDone) -> Void)?

    let throttle: DownloadThrottle
    private var workers: [UUID: DownloadWorker] = [:]
    private var lastReceived: [UUID: (bytes: Int64, time: Date)] = [:]
    private var timer: Timer?
    private var lastSave = Date.distantPast
    private let file: URL
    private let queuesFile: URL
    let partsFolder: URL
    private var wakeObserver: NSObjectProtocol?
    private var scheduleTimer: Timer?
    private var capTimer: Timer?
    private var started = false

    init(throttle: DownloadThrottle = .shared) {
        self.throttle = throttle
        let partsFolderForSpace = SettingsStore.folder.appendingPathComponent("downloads", isDirectory: true)
        freeSpace = { Self.freeSpace(at: partsFolderForSpace) }
        file = SettingsStore.folder.appendingPathComponent("downloads.json")
        queuesFile = SettingsStore.folder.appendingPathComponent("download-queues.json")
        partsFolder = SettingsStore.folder.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: partsFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved
        }
        if let data = try? Data(contentsOf: queuesFile),
           var saved = try? JSONDecoder().decode([DownloadQueue].self, from: data), !saved.isEmpty {
            // 0.22: like IDM, everything downloads at once unless you set a limit. Queues still on the
            // old default of 3 move to "No limit" (once).
            if !Prefs.downloadsUnlimitedByDefault {
                for index in saved.indices where saved[index].maxAtOnce == 3 { saved[index].maxAtOnce = 0 }
                Prefs.downloadsUnlimitedByDefault = true
            }
            queues = saved
        } else {
            queues = [.main()]
            Prefs.downloadsUnlimitedByDefault = true
        }
        Self.raiseOpenFileLimit()
    }

    static func freeSpace(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The disk is nearly full: running downloads wait (keeping what they have), and carry on by
    /// themselves once there's room again, rather than leaving broken half-written files.
    func checkSpace() {
        guard !waitingForSpace, let free = freeSpace(), free < Self.minimumFreeSpace else { return }
        waitingForSpace = true
        for item in items where item.state == .downloading {
            stopWorker(item.id, state: .queued)
        }
        save()
        onLowSpace?(free)
        spaceTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckSpace() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        spaceTimer = timer
    }

    /// Carries on once there's half a gigabyte more than the minimum free.
    func recheckSpace() {
        guard waitingForSpace, let free = freeSpace(), free >= Self.minimumFreeSpace + 500_000_000 else { return }
        waitingForSpace = false
        spaceTimer?.invalidate()
        spaceTimer = nil
        schedule()
    }

    /// macOS lets an app keep about 256 files and connections open at once; a hundred downloads need
    /// more. Raises Toolbelt's own limit (as far as macOS allows) once, at start.
    static func raiseOpenFileLimit(to wanted: rlim_t = 8192) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < wanted else { return }
        limit.rlim_cur = min(wanted, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    static var openFileLimit: Int {
        var limit = rlimit()
        return getrlimit(RLIMIT_NOFILE, &limit) == 0 ? Int(limit.rlim_cur) : 0
    }

    // MARK: Starting and stopping

    /// Carries on with downloads that were running when Toolbelt quit, the Mac slept or the power went.
    func resumeInterrupted() {
        started = true
        // Queues with set times start or stop as they would have while Toolbelt was closed.
        let now = Date()
        for index in queues.indices {
            if let run = DownloadSchedule.shouldRun(queues[index], at: now) { queues[index].isRunning = run }
        }
        // Those that were running wait their turn again, oldest first.
        for index in items.indices where items[index].state == .downloading {
            items[index].state = .queued
        }
        schedule()
        armScheduleTimer()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.afterWake() }
            }
        }
    }

    func stopAll() {
        for (id, worker) in workers {
            refresh(id) // save exactly how far each part got
            worker.pause()
            // The state stays .downloading, so it carries on next time.
        }
        workers = [:]
        timer?.invalidate()
        timer = nil
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        capTimer?.invalidate()
        capTimer = nil
        spaceTimer?.invalidate()
        spaceTimer = nil
        started = false
        save()
    }

    /// After sleep the old connections are dead; reconnect.
    private func afterWake() {
        for item in items where item.state == .downloading {
            workers[item.id]?.pause()
            workers[item.id] = nil
            run(item.id)
        }
    }

    // MARK: Adding

    /// Starts downloading a link. Returns nil if the text isn't a link Toolbelt can download.
    @discardableResult
    func add(_ text: String, name: String? = nil, headers: [String: String] = [:], queue: UUID? = nil,
             stream: Bool = false, audio: String? = nil, page: String? = nil, folder: URL? = nil) -> DownloadItem? {
        guard let url = Self.downloadableURL(from: text) else { return nil }
        let fromURL = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? (url.host ?? "download") : url.lastPathComponent
        let chosen = name.map(Self.safeFileName).flatMap { $0.isEmpty ? nil : $0 }
        var item = DownloadItem(url: url, name: chosen ?? fromURL.removingPercentEncoding ?? fromURL, state: .queued)
        item.queueID = queue
        item.headers = headers.isEmpty ? nil : headers
        if chosen != nil { item.nameIsFixed = true }
        item.pageURL = page.flatMap(Self.downloadableURL)
        item.folder = folder?.path
        if stream {
            item.kind = "hls"
            item.audioURL = audio.flatMap(Self.downloadableURL)
            if (item.name as NSString).pathExtension.lowercased() != "mp4" {
                item.name = ((item.name as NSString).deletingPathExtension) + ".mp4"
            }
        }
        items.insert(item, at: 0)
        started = true
        schedule()
        save()
        return self.item(item.id)
    }

    /// Connections for a new file download: the usual number, shared out when many run at once
    /// (the same budget streamed videos share).
    static func connections(running: Int, preferred: Int? = nil) -> Int {
        let preferred = preferred ?? Prefs.downloadConnections
        return max(1, min(preferred, ConnectionBudget.shared.total / max(1, running)))
    }

    /// File names can't contain "/" or ":" on a Mac.
    static func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func downloadableURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    // MARK: Controls

    func pause(_ id: UUID) {
        refresh(id)
        workers[id]?.pause()
        refresh(id)
        workers[id] = nil
        update(id) { $0.state = .paused; $0.speed = 0; $0.connections = 0 }
        schedule()
        save()
    }

    func resume(_ id: UUID) {
        update(id) { $0.state = .queued; $0.error = nil }
        started = true
        schedule()
        save()
    }

    func move(_ id: UUID, to queue: UUID) {
        stopWorker(id, state: .queued)
        update(id) { $0.queueID = queue }
        schedule()
        save()
    }

    /// Stops a download and deletes its partial file. Finished files are kept.
    func remove(_ id: UUID) {
        workers[id]?.pause()
        workers[id] = nil
        try? FileManager.default.removeItem(at: tempURL(for: id))
        try? FileManager.default.removeItem(at: streamFolder(for: id))
        items.removeAll { $0.id == id }
        schedule()
        save()
    }

    // MARK: Queues

    /// The queue a download is in (the first queue if its own was deleted).
    func queue(of item: DownloadItem) -> DownloadQueue {
        queues.first { $0.id == item.queueID } ?? queues[0]
    }

    func startQueue(_ id: UUID) {
        guard let index = queues.firstIndex(where: { $0.id == id }) else { return }
        queues[index].isRunning = true
        started = true
        schedule()
    }

    /// Stops a queue: its running downloads go back to waiting and carry on when it starts again.
    func stopQueue(_ id: UUID) {
        guard let index = queues.firstIndex(where: { $0.id == id }) else { return }
        for item in items where item.state == .downloading && queue(of: item).id == id {
            stopWorker(item.id, state: .queued)
        }
        queues[index].isRunning = false
        save()
    }

    func addQueue(named name: String) -> DownloadQueue {
        let queue = DownloadQueue(name: name)
        queues.append(queue)
        return queue
    }

    /// Deletes a queue; its downloads move to the first queue. The first queue can't be deleted.
    func removeQueue(_ id: UUID) {
        guard queues.count > 1, queues[0].id != id else { return }
        for index in items.indices where items[index].queueID == id { items[index].queueID = nil }
        queues.removeAll { $0.id == id }
        save()
    }

    /// Starts waiting downloads wherever a running queue has room, oldest first.
    func schedule() {
        guard started, cappedUntil == nil, !waitingForSpace, !queues.isEmpty else { return }
        for queue in queues where queue.isRunning {
            var running = items.filter { $0.state == .downloading && self.queue(of: $0).id == queue.id }.count
            let waiting = items.filter { $0.state == .queued && self.queue(of: $0).id == queue.id }.sorted { $0.added < $1.added }
            let limit = queue.hasNoLimit ? Int.max : queue.maxAtOnce
            for item in waiting where running < limit {
                update(item.id) { $0.state = .downloading }
                run(item.id)
                running += 1
            }
        }
        startTimer()
    }

    private func stopWorker(_ id: UUID, state: DownloadState) {
        refresh(id)
        workers[id]?.pause()
        refresh(id)
        workers[id] = nil
        update(id) { $0.state = state; $0.speed = 0; $0.connections = 0 }
    }

    /// One timer, set for the next scheduled start or stop; nothing runs in between.
    private func armScheduleTimer() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard started, let event = DownloadSchedule.next(after: Date(), queues: queues) else { return }
        let timer = Timer(fire: event.date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.start { self.startQueue(event.queueID) } else { self.stopQueue(event.queueID) }
                self.armScheduleTimer()
            }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    private func saveQueues() {
        do {
            try JSONEncoder().encode(queues).write(to: queuesFile, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save download queues: \(error)")
        }
    }

    // MARK: Limits

    /// Reads the speed limit and hourly cap from Settings.
    func applyLimits() {
        throttle.configure(bytesPerSecond: Double(Prefs.downloadSpeedLimitKB) * 1024,
                           hourlyCap: Int64(Prefs.downloadHourlyCapMB) * 1024 * 1024)
    }

    /// The hourly cap is used up: everything waits until the next hour.
    private func pauseForCap(until date: Date) {
        cappedUntil = date
        for item in items where item.state == .downloading {
            stopWorker(item.id, state: .queued)
        }
        save()
        capTimer?.invalidate()
        let timer = Timer(fire: date.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cappedUntil = nil
                self?.schedule()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        capTimer = timer
    }

    /// Whether anything is still downloading or waiting in a running queue.
    var hasWork: Bool {
        items.contains { $0.state == .downloading || ($0.state == .queued && queue(of: $0).isRunning) }
    }

    private func checkAllDone() {
        guard whenDone != .nothing, !hasWork, cappedUntil == nil else { return }
        let action = whenDone
        whenDone = .nothing
        onAllDone?(action)
    }

    func clearFinished() {
        items.removeAll { $0.state == .completed }
        save()
    }

    func item(_ id: UUID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    func tempURL(for id: UUID) -> URL {
        partsFolder.appendingPathComponent(id.uuidString + ".part")
    }

    /// Where a streamed video's pieces wait until they're joined.
    func streamFolder(for id: UUID) -> URL {
        partsFolder.appendingPathComponent(id.uuidString + ".hls", isDirectory: true)
    }

    // MARK: Running

    private func run(_ id: UUID) {
        guard workers[id] == nil, let item = item(id) else { return }
        applyLimits()
        let worker: DownloadWorker
        if item.isStream {
            worker = HLSDownloadJob(playlist: item.url, audio: item.audioURL, folder: streamFolder(for: id), tempURL: tempURL(for: id),
                                    headers: item.headers ?? [:], connections: Prefs.downloadConnections, retries: Prefs.downloadRetries,
                                    throttle: throttle)
        } else if item.url.scheme?.lowercased() == "ftp" {
            let ftp = FTPDownloadJob(url: item.url, tempURL: tempURL(for: id), total: item.total, retries: Prefs.downloadRetries)
            ftp.speedLimit = Prefs.downloadSpeedLimitKB * 1024
            worker = ftp
        } else {
            worker = HTTPDownloadJob(url: item.url, tempURL: tempURL(for: id), segments: item.segments, total: item.total,
                                     acceptsRanges: item.acceptsRanges, connections: Self.connections(running: workers.count + 1),
                                     retries: Prefs.downloadRetries, headers: item.headers ?? [:], throttle: throttle)
        }
        worker.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, for: id) }
            }
        }
        workers[id] = worker
        lastReceived[id] = (item.received, Date())
        worker.start()
    }

    private func handle(_ event: DownloadEvent, for id: UUID) {
        switch event {
        case .named(let name):
            update(id) { if $0.nameIsFixed != true { $0.name = name } }
        case .finished:
            guard workers[id] != nil else { return }
            refresh(id)
            workers[id] = nil
            finish(id)
            if let item = item(id), item.state == .completed { onFinished?(item) }
            schedule()
            checkAllDone()
        case .failed(let message):
            guard workers[id] != nil else { return }
            refresh(id)
            workers[id] = nil
            update(id) { $0.state = .failed; $0.error = message; $0.speed = 0; $0.connections = 0 }
            save()
            schedule()
            checkAllDone()
        }
    }

    /// Moves the finished file to its category's folder: its own folder if it has one, else the downloads
    /// folder (sorted by type if that's switched on). A download given a folder of its own goes there.
    private func finish(_ id: UUID) {
        guard let item = item(id) else { return }
        let folder = item.folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? DownloadCategories.folder(for: item.name, base: Prefs.downloadFolder, sortByType: Prefs.downloadSortByType,
                                         rules: Prefs.downloadCategories)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = ShelfStore.unusedURL(for: item.name, in: folder)
            try FileManager.default.moveItem(at: tempURL(for: id), to: destination)
            update(id) {
                $0.state = .completed
                $0.finalPath = destination.path
                $0.finished = Date()
                $0.speed = 0
                $0.connections = 0
                if let total = $0.total { $0.received = total }
            }
        } catch {
            update(id) { $0.state = .failed; $0.error = "Downloaded, but couldn't move it to \(folder.path): \(error.localizedDescription)" }
        }
        save()
    }

    // MARK: Progress

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        for id in workers.keys { refresh(id) }
        ticks += 1
        if ticks % 10 == 0, !workers.isEmpty { checkSpace() } // every 5 seconds while downloading
        applyLimits()
        if cappedUntil == nil, !workers.isEmpty, let wait = throttle.capWait {
            pauseForCap(until: Date().addingTimeInterval(wait))
        }
        if Date().timeIntervalSince(lastSave) > 2, !workers.isEmpty { save() }
        if workers.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refresh(_ id: UUID) {
        guard let worker = workers[id] else { return }
        let snapshot = worker.snapshot()
        let now = Date()
        var speed = item(id)?.speed ?? 0
        if let last = lastReceived[id] {
            let elapsed = now.timeIntervalSince(last.time)
            if elapsed > 0.2 {
                let current = Double(snapshot.received - last.bytes) / elapsed
                speed = speed == 0 ? current : speed * 0.7 + current * 0.3 // smoothed
                lastReceived[id] = (snapshot.received, now)
            }
        }
        update(id) {
            $0.received = snapshot.received
            $0.total = snapshot.total
            $0.segments = snapshot.segments
            $0.acceptsRanges = snapshot.acceptsRanges
            $0.connections = snapshot.connections
            $0.speed = max(0, speed)
        }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    func save() {
        lastSave = Date()
        do {
            try JSONEncoder().encode(items).write(to: file, options: .atomic)
        } catch {
            NSLog("Toolbelt: could not save downloads: \(error)")
        }
    }
}
