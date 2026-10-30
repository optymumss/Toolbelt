import Foundation

/// What a running download reports back.
enum DownloadEvent {
    case named(String)
    case finished
    case failed(String)
}

/// A point-in-time view of a running download, for the list.
struct DownloadSnapshot {
    var received: Int64
    var total: Int64?
    var segments: [Segment]
    var acceptsRanges: Bool
    var connections: Int
}

protocol DownloadWorker: AnyObject {
    var onEvent: ((DownloadEvent) -> Void)? { get set }
    func start()
    func pause()
    func snapshot() -> DownloadSnapshot
}

/// Downloads one file over HTTP or HTTPS, in several parts at once when the server allows it.
/// Parts are written straight into place in a temporary file, so the download can stop at any
/// moment (pause, lost connection, sleep, power cut) and carry on from where each part got to.
final class HTTPDownloadJob: NSObject, DownloadWorker, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL
    let tempURL: URL
    var onEvent: ((DownloadEvent) -> Void)?

    private let maxConnections: Int
    private let maxRetries: Int
    private let lock = NSLock()
    private let queue: OperationQueue
    private var session: URLSession?
    private var handle: FileHandle?

    private var segments: [Segment]
    private var total: Int64?
    private var acceptsRanges: Bool
    /// Running requests: task identifier → part index.
    private var running: [Int: Int] = [:]
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var attempts: [Int: Int] = [:]
    private var stopped = true
    private var finished = false

    init(url: URL, tempURL: URL, segments: [Segment], total: Int64?, acceptsRanges: Bool, connections: Int, retries: Int) {
        self.url = url
        self.tempURL = tempURL
        self.segments = segments
        self.total = total
        self.acceptsRanges = acceptsRanges
        maxConnections = max(1, connections)
        maxRetries = retries
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Toolbelt download"
    }

    // MARK: Control

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stopped, !finished else { return }
        stopped = false

        let fm = FileManager.default
        try? fm.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: tempURL.path) {
            fm.createFile(atPath: tempURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: tempURL)

        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConnections + 1
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)

        let partial = segments.contains { $0.received > 0 }
        if segments.isEmpty || (partial && !acceptsRanges) {
            // New download, or one that can't be resumed part-way: start from the beginning.
            try? handle?.truncate(atOffset: 0)
            segments = [Segment(start: 0, end: -1)]
            total = nil
        }
        fill()
    }

    func pause() {
        lock.lock()
        stopped = true
        let session = self.session
        self.session = nil
        running = [:]
        tasks = [:]
        lock.unlock()
        session?.invalidateAndCancel()
        try? handle?.synchronize()
    }

    func snapshot() -> DownloadSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DownloadSnapshot(
            received: segments.reduce(0) { $0 + $1.received },
            total: total, segments: segments, acceptsRanges: acceptsRanges, connections: running.count
        )
    }

    // MARK: Scheduling (call with the lock held)

    /// Keeps as many connections busy as allowed: unfinished parts first, then by splitting big ones.
    private func fill() {
        guard !stopped, let session else { return }
        let busy = Set(running.values)
        for index in segments.indices where running.count < maxConnections {
            if !busy.contains(index), !segments[index].isComplete {
                request(index, in: session)
            }
        }
        guard acceptsRanges, total != nil else { return }
        while running.count < maxConnections, let split = SegmentPlanner.split(segments, busy: Set(running.values)) {
            segments[split.shortened].end = split.new.start - 1
            segments.append(split.new)
            request(segments.count - 1, in: session)
        }
    }

    private func request(_ index: Int, in session: URLSession) {
        var request = URLRequest(url: url)
        let segment = segments[index]
        if segment.end >= 0 {
            request.setValue("bytes=\(segment.next)-\(segment.end)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(segment.next)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        running[task.taskIdentifier] = index
        tasks[task.taskIdentifier] = task
        task.resume()
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = running[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            failLocked("The server answered \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))).")
            return
        }

        if http.statusCode == 206 {
            if total == nil, let range = http.value(forHTTPHeaderField: "Content-Range"),
               let size = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                // The first answer tells us the size and that parts are possible.
                total = size
                acceptsRanges = true
                segments[index].end = size - 1
                if let name = response.suggestedFilename { onEvent?(.named(name)) }
                fill()
            }
        } else {
            // 200: the whole file, from the start. Parts aren't possible.
            acceptsRanges = false
            if segments[index].next > 0 || segments.count > 1 {
                // The server ignored the request for a part: start again with this one connection.
                for (taskID, task) in tasks where taskID != dataTask.taskIdentifier {
                    task.cancel()
                }
                segments = [Segment(start: 0, end: -1)]
                running = [dataTask.taskIdentifier: 0]
                tasks = [dataTask.taskIdentifier: dataTask]
                try? handle?.truncate(atOffset: 0)
                total = nil
            }
            if total == nil, http.expectedContentLength > 0 {
                total = http.expectedContentLength
                segments[0].end = http.expectedContentLength - 1
            }
            if let name = response.suggestedFilename { onEvent?(.named(name)) }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let index = running[dataTask.taskIdentifier] else { return }
        var chunk = data
        let segment = segments[index]
        if segment.end >= 0 {
            let room = segment.end - segment.next + 1
            if room <= 0 {
                dataTask.cancel()
                return
            }
            if Int64(chunk.count) > room { chunk = chunk.prefix(Int(room)) }
        }
        do {
            try handle?.seek(toOffset: UInt64(segment.next))
            try handle?.write(contentsOf: chunk)
        } catch {
            failLocked("Couldn't write the file: \(error.localizedDescription)")
            return
        }
        segments[index].received += Int64(chunk.count)
        attempts[index] = 0
        if segments[index].isComplete {
            // This part is done (perhaps because another connection took its second half).
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        tasks[task.taskIdentifier] = nil
        guard !stopped, let index = running.removeValue(forKey: task.taskIdentifier) else { return }

        if segments[index].end < 0, error == nil {
            // Unknown size: the server closing the connection means the end.
            segments[index].end = segments[index].next - 1
            total = segments[index].next
        }

        if !segments[index].isComplete {
            let tries = (attempts[index] ?? 0) + 1
            attempts[index] = tries
            guard tries <= maxRetries else {
                failLocked(error?.localizedDescription ?? "The connection kept closing early.")
                return
            }
            // Try this part again after a short wait (1, 2, 4, 8… seconds).
            let delay = min(30, pow(2, Double(tries - 1)))
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                if !self.stopped, let session = self.session, !self.running.values.contains(index) {
                    self.request(index, in: session)
                }
            }
            return
        }

        if segments.allSatisfy(\.isComplete) {
            finished = true
            stopped = true
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            onEvent?(.finished)
        } else {
            fill()
        }
    }

    private func failLocked(_ message: String) {
        stopped = true
        session?.invalidateAndCancel()
        session = nil
        running = [:]
        tasks = [:]
        try? handle?.synchronize()
        onEvent?(.failed(message))
    }
}

/// FTP downloads, which macOS's networking no longer supports, go through the built-in curl tool.
/// One connection; pausing stops it and resuming carries on from the end of the partial file.
final class FTPDownloadJob: DownloadWorker, @unchecked Sendable {
    let url: URL
    let tempURL: URL
    var onEvent: ((DownloadEvent) -> Void)?
    private var process: Process?
    private var total: Int64?
    private let lock = NSLock()
    private let retries: Int

    init(url: URL, tempURL: URL, total: Int64?, retries: Int) {
        self.url = url
        self.tempURL = tempURL
        self.total = total
        self.retries = retries
    }

    static func arguments(url: URL, output: URL, retries: Int) -> [String] {
        ["--silent", "--show-error", "--fail", "--location", "--retry", String(retries), "--retry-delay", "2",
         "--continue-at", "-", "--output", output.path, url.absoluteString]
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }
        onEvent?(.named(url.lastPathComponent))
        if total == nil { fetchSize() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = Self.arguments(url: url, output: tempURL, retries: retries)
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            let wasPaused = self.process == nil
            self.process = nil
            self.lock.unlock()
            guard !wasPaused else { return }
            if finished.terminationStatus == 0 {
                self.onEvent?(.finished)
            } else {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                self.onEvent?(.failed(message.isEmpty ? "The FTP download stopped (curl error \(finished.terminationStatus))." : message))
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            onEvent?(.failed("Couldn't start the FTP download: \(error.localizedDescription)"))
        }
    }

    private func fetchSize() {
        let head = Process()
        head.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        head.arguments = ["--silent", "--head", url.absoluteString]
        let out = Pipe()
        head.standardOutput = out
        guard (try? head.run()) != nil else { return }
        head.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("content-length:") {
            total = Int64(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
    }

    func pause() {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()
        process?.terminate()
    }

    func snapshot() -> DownloadSnapshot {
        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        lock.lock()
        defer { lock.unlock() }
        let segment = Segment(start: 0, end: (total ?? 0) - 1, received: size)
        return DownloadSnapshot(received: size, total: total, segments: [segment], acceptsRanges: true, connections: process == nil ? 0 : 1)
    }
}
