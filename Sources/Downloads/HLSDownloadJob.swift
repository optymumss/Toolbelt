import CommonCrypto
import Foundation

/// Downloads a streamed video (HLS): its playlist, then every piece, several at a time, into a
/// folder next to the other partial downloads. Pieces already on disk are kept, so pausing,
/// quitting or losing the connection carries on where it stopped. When every piece is in, they're
/// joined into one .mp4 (VideoRemuxer). Copy-protected (DRM) streams are refused.
final class HLSDownloadJob: DownloadWorker, @unchecked Sendable {
    let playlistURL: URL
    let audioURL: URL?
    let folder: URL
    let tempURL: URL
    var onEvent: ((DownloadEvent) -> Void)?

    private let headers: [String: String]
    private let connections: Int
    private let retries: Int
    private let throttle: DownloadThrottle
    private let lock = NSLock()
    private var session: URLSession?
    private var stopped = true
    private var finished = false
    /// Each start gets its own; pausing marks it, so work left over from before a pause never mixes with the next run.
    private var current: RunState?

    // Progress
    private var pieceCount = 0
    private var piecesDone = 0
    private var bytesDone: Int64 = 0
    private var running = 0
    private var joining = false

    init(playlist: URL, audio: URL?, folder: URL, tempURL: URL, headers: [String: String], connections: Int, retries: Int,
         throttle: DownloadThrottle = .shared) {
        playlistURL = playlist
        audioURL = audio
        self.folder = folder
        self.tempURL = tempURL
        self.headers = headers
        self.connections = max(1, min(connections, 8))
        self.retries = retries
        self.throttle = throttle
    }

    func start() {
        lock.lock()
        guard stopped, !finished else { lock.unlock(); return }
        stopped = false
        let run = RunState()
        current = run
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = connections + 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if headers["Cookie"] != nil { configuration.httpShouldSetCookies = false }
        session = URLSession(configuration: configuration)
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.work(run) }
    }

    func pause() {
        lock.lock()
        stopped = true
        current?.cancel()
        current = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
    }

    func snapshot() -> DownloadSnapshot {
        lock.lock()
        defer { lock.unlock() }
        // The total is a guess from the pieces so far, until they're all in.
        var total: Int64?
        if pieceCount > 0, piecesDone > 0 {
            total = piecesDone == pieceCount ? bytesDone : bytesDone * Int64(pieceCount) / Int64(piecesDone)
        }
        return DownloadSnapshot(received: bytesDone, total: total, segments: [], acceptsRanges: true, connections: joining ? 1 : running)
    }


    // MARK: The work

    private struct Piece {
        var source: HLSSegment?
        var map: HLSMap?
        var file: URL
    }

    private func work(_ run: RunState) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let video = try mediaPlaylist(playlistURL, run)
            let audio = try audioURL.map { try mediaPlaylist($0, run) }
            if video.isProtected || audio?.isProtected == true {
                throw DownloadFailure("This video is copy-protected (DRM), so it can't be downloaded.")
            }
            guard !video.segments.isEmpty else { throw DownloadFailure("The video's playlist lists no pieces.") }

            let videoPieces = pieces(of: video, prefix: "v")
            let audioPieces = audio.map { pieces(of: $0, prefix: "a") } ?? []
            let all = videoPieces + audioPieces
            lock.lock()
            pieceCount = all.count
            piecesDone = 0
            bytesDone = 0
            lock.unlock()
            for piece in all where FileManager.default.fileExists(atPath: piece.file.path) { counted(piece.file) }

            try fetch(all.filter { !FileManager.default.fileExists(atPath: $0.file.path) }, run)
            guard !run.isCancelled else { return }

            lock.lock()
            joining = true
            lock.unlock()
            defer { lock.lock(); joining = false; lock.unlock() }
            try join(video: video, videoPieces: videoPieces, audio: audio, audioPieces: audioPieces, run)
            guard !run.isCancelled else { return }
            try? FileManager.default.removeItem(at: folder)
            lock.lock()
            let isCurrent = run === current
            if isCurrent { finished = true; stopped = true; current = nil }
            lock.unlock()
            if isCurrent { onEvent?(.finished) }
        } catch is CancellationError {
            return
        } catch {
            lock.lock()
            let isCurrent = run === current && !run.isCancelled
            if isCurrent { stopped = true; current = nil }
            lock.unlock()
            if isCurrent { onEvent?(.failed(error.localizedDescription)) }
        }
    }

    /// Loads a playlist; a master playlist is narrowed down to its biggest size.
    private func mediaPlaylist(_ url: URL, _ run: RunState) throws -> HLSMediaPlaylist {
        let data = try get(url, range: nil, run)
        guard let text = String(data: data, encoding: .utf8), let playlist = HLSPlaylist.parse(text, base: url) else {
            throw DownloadFailure("The link isn't a video playlist Toolbelt can read.")
        }
        switch playlist {
        case .media(let media): return media
        case .master(let variants):
            guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else { throw DownloadFailure("The playlist lists no videos.") }
            return try mediaPlaylist(best.url, run)
        }
    }

    private func pieces(of playlist: HLSMediaPlaylist, prefix: String) -> [Piece] {
        var list: [Piece] = []
        if let map = playlist.segments.first?.map {
            list.append(Piece(source: nil, map: map, file: folder.appendingPathComponent("\(prefix)-init.mp4")))
        }
        let ext = playlist.isFragmentedMP4 ? "m4s" : "ts"
        for (index, segment) in playlist.segments.enumerated() {
            list.append(Piece(source: segment, map: nil, file: folder.appendingPathComponent(String(format: "%@%06d.%@", prefix, index, ext))))
        }
        return list
    }

    private func counted(_ file: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        lock.lock()
        piecesDone += 1
        bytesDone += size
        lock.unlock()
    }

    /// Fetches the pieces, `connections` at a time.
    private func fetch(_ pieces: [Piece], _ run: RunState) throws {
        guard !pieces.isEmpty else { return }
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: connections)
        let failure = FailureBox()
        var keys: [URL: Data] = [:]
        let keysLock = NSLock()
        func key(for url: URL) throws -> Data {
            keysLock.lock()
            if let known = keys[url] { keysLock.unlock(); return known }
            keysLock.unlock()
            let data = try get(url, range: nil, run)
            guard data.count == 16 else { throw DownloadFailure("The video's decryption key couldn't be read.") }
            keysLock.lock()
            keys[url] = data
            keysLock.unlock()
            return data
        }

        for piece in pieces {
            slots.wait()
            if run.isCancelled || failure.error != nil { slots.signal(); break }
            group.enter()
            lock.lock(); running += 1; lock.unlock()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer {
                    lock.lock(); running -= 1; lock.unlock()
                    slots.signal()
                    group.leave()
                }
                do {
                    var data: Data
                    if let map = piece.map {
                        data = try get(map.url, range: map.byteRange, run)
                    } else if let segment = piece.source {
                        data = try get(segment.url, range: segment.byteRange, run)
                        if segment.key.method == .aes128, let keyURL = segment.key.url {
                            let iv = segment.key.iv ?? Self.sequenceIV(segment.sequence)
                            data = try Self.decrypt(data, key: try key(for: keyURL), iv: iv)
                        }
                    } else {
                        return
                    }
                    if run.isCancelled { return }
                    // Written under a temporary name, so a half-written piece is never mistaken for a whole one.
                    let partial = piece.file.appendingPathExtension("partial")
                    try data.write(to: partial)
                    try? FileManager.default.removeItem(at: piece.file)
                    try FileManager.default.moveItem(at: partial, to: piece.file)
                    counted(piece.file)
                    let wait = throttle.take(Int64(data.count))
                    if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 2)) }
                } catch {
                    if !run.isCancelled { failure.set(error) }
                }
            }
        }
        group.wait()
        if run.isCancelled { throw CancellationError() }
        if let error = failure.error { throw error }
    }

    private func join(video: HLSMediaPlaylist, videoPieces: [Piece], audio: HLSMediaPlaylist?, audioPieces: [Piece], _ run: RunState) throws {
        let videoInit = videoPieces.first { $0.map != nil }?.file
        let videoFiles = videoPieces.filter { $0.source != nil }.map(\.file)
        let audioInit = audioPieces.first { $0.map != nil }?.file
        let audioFiles = audioPieces.filter { $0.source != nil }.map(\.file)
        let discontinuities = Set(video.segments.enumerated().filter { $0.element.discontinuity }.map(\.offset))

        if video.isFragmentedMP4 {
            if audio == nil {
                try VideoRemuxer.joinFragments(initSection: videoInit, pieces: videoFiles, to: tempURL)
                return
            }
            // Separate sound: join each, then copy both into one file.
            let videoOnly = folder.appendingPathComponent("video.mp4")
            let soundOnly = folder.appendingPathComponent("sound.mp4")
            try VideoRemuxer.joinFragments(initSection: videoInit, pieces: videoFiles, to: videoOnly)
            if audio?.isFragmentedMP4 == true {
                try VideoRemuxer.joinFragments(initSection: audioInit, pieces: audioFiles, to: soundOnly)
            } else {
                try VideoRemuxer.remuxTS(video: [], audio: audioFiles, to: soundOnly)
            }
            try VideoRemuxer.combine(video: videoOnly, audio: soundOnly, to: tempURL.appendingPathExtension("mp4"))
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.moveItem(at: tempURL.appendingPathExtension("mp4"), to: tempURL)
            return
        }
        // MPEG-TS: AVAssetWriter wants a file name ending in .mp4, so write beside the temporary file and move it.
        let output = tempURL.appendingPathExtension("mp4")
        try VideoRemuxer.remuxTS(video: videoFiles, audio: audioFiles, discontinuities: discontinuities, to: output,
                                 isCancelled: { run.isCancelled })
        try? FileManager.default.removeItem(at: tempURL)
        try FileManager.default.moveItem(at: output, to: tempURL)
    }

    // MARK: Network

    /// Fetches a whole file (or part of one), trying again after short waits if the connection drops.
    private func get(_ url: URL, range: (offset: Int64, length: Int64)?, _ run: RunState) throws -> Data {
        var attempt = 0
        while true {
            if run.isCancelled { throw CancellationError() }
            lock.lock()
            let session = self.session
            lock.unlock()
            guard let session else { throw CancellationError() }
            var request = URLRequest(url: url)
            for (field, value) in headers where field != "Cookie" || sameSite(url) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if let range { request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range") }
            let done = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            let task = session.dataTask(with: request) { data, response, error in
                box.data = data
                box.response = response as? HTTPURLResponse
                box.error = error
                done.signal()
            }
            task.resume()
            done.wait()
            if run.isCancelled { throw CancellationError() }
            if let response = box.response, (200..<300).contains(response.statusCode), let data = box.data {
                return data
            }
            attempt += 1
            if let response = box.response, [401, 403, 404, 410].contains(response.statusCode) {
                throw DownloadFailure("The site answered \(response.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))). The video link may have expired: start it again from the page.")
            }
            guard attempt <= retries else {
                throw DownloadFailure(box.error?.localizedDescription ?? "The site kept failing to send a piece of the video.")
            }
            Thread.sleep(forTimeInterval: min(30, pow(2, Double(attempt - 1))))
        }
    }

    /// Cookies are only sent to the site they came from (the playlist's), not to other servers.
    private func sameSite(_ url: URL) -> Bool {
        url.host == playlistURL.host
    }

    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    /// AES-128 in CBC mode with PKCS7 padding: HLS's standard (non-DRM) encryption.
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputSize = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, outputSize, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DownloadFailure("A piece of the video couldn't be decrypted.") }
        output.removeSubrange(moved...)
        return output
    }
}

struct DownloadFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
}

private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var response: HTTPURLResponse?
    var error: Error?
}
