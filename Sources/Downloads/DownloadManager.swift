import AppKit
import Combine

/// Keeps the list of downloads, runs them, and saves their progress so they survive restarts.
/// Saved in ~/Library/Application Support/Toolbelt/downloads.json; partial files in …/Toolbelt/downloads/.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    private var workers: [UUID: DownloadWorker] = [:]
    private var lastReceived: [UUID: (bytes: Int64, time: Date)] = [:]
    private var timer: Timer?
    private var lastSave = Date.distantPast
    private let file: URL
    let partsFolder: URL
    private var wakeObserver: NSObjectProtocol?

    init() {
        file = SettingsStore.folder.appendingPathComponent("downloads.json")
        partsFolder = SettingsStore.folder.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: partsFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved
        }
    }

    // MARK: Starting and stopping

    /// Carries on with downloads that were running when Toolbelt quit, the Mac slept or the power went.
    func resumeInterrupted() {
        for item in items where item.state == .downloading {
            run(item.id)
        }
        startTimer()
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
    func add(_ text: String) -> DownloadItem? {
        guard let url = Self.downloadableURL(from: text) else { return nil }
        let name = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? (url.host ?? "download") : url.lastPathComponent
        let item = DownloadItem(url: url, name: name.removingPercentEncoding ?? name)
        items.insert(item, at: 0)
        save()
        run(item.id)
        startTimer()
        return item
    }

    static func downloadableURL(from text: String) -> URL? {
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
        save()
    }

    func resume(_ id: UUID) {
        update(id) { $0.state = .downloading; $0.error = nil }
        run(id)
        startTimer()
        save()
    }

    /// Stops a download and deletes its partial file. Finished files are kept.
    func remove(_ id: UUID) {
        workers[id]?.pause()
        workers[id] = nil
        try? FileManager.default.removeItem(at: tempURL(for: id))
        items.removeAll { $0.id == id }
        save()
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

    // MARK: Running

    private func run(_ id: UUID) {
        guard workers[id] == nil, let item = item(id) else { return }
        let worker: DownloadWorker
        if item.url.scheme?.lowercased() == "ftp" {
            worker = FTPDownloadJob(url: item.url, tempURL: tempURL(for: id), total: item.total, retries: Prefs.downloadRetries)
        } else {
            worker = HTTPDownloadJob(url: item.url, tempURL: tempURL(for: id), segments: item.segments, total: item.total,
                                     acceptsRanges: item.acceptsRanges, connections: Prefs.downloadConnections,
                                     retries: Prefs.downloadRetries)
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
            update(id) { $0.name = name }
        case .finished:
            refresh(id)
            workers[id] = nil
            finish(id)
        case .failed(let message):
            refresh(id)
            workers[id] = nil
            update(id) { $0.state = .failed; $0.error = message; $0.speed = 0; $0.connections = 0 }
            save()
        }
    }

    /// Moves the finished file to the downloads folder, sorted by type if that's switched on.
    private func finish(_ id: UUID) {
        guard let item = item(id) else { return }
        var folder = Prefs.downloadFolder
        if Prefs.downloadSortByType {
            folder = folder.appendingPathComponent(DownloadCategory.of(item.name).rawValue, isDirectory: true)
        }
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
