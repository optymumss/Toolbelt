import AVFoundation
import CoreMedia
import Foundation

// Puts downloaded stream pieces back together as one ordinary .mp4 that QuickTime plays.
// The video and sound are copied as they are (never re-encoded), so it's quick and loses nothing.

enum RemuxError: LocalizedError {
    case noMedia, format(String), writer(String)

    var errorDescription: String? {
        switch self {
        case .noMedia: return "The downloaded pieces didn't contain any video or sound Toolbelt can read."
        case .format(let detail): return "Couldn't read the video's format (\(detail))."
        case .writer(let detail): return "Couldn't put the video together: \(detail)"
        }
    }
}

enum VideoRemuxer {
    /// Joins MPEG-TS pieces into an .mp4. `audioFiles` is a separate sound stream, if the site sends one.
    /// Packed-audio pieces (.aac) are recognised by their content.
    ///
    /// The video and the sound are each written to a file of their own (a writer with a single
    /// track never waits for another one), then copied together into the finished file.
    static func remuxTS(video videoFiles: [URL], audio audioFiles: [URL] = [], discontinuities: Set<Int> = [],
                        to output: URL, isCancelled: () -> Bool = { false }) throws {
        let soundFiles = audioFiles.isEmpty ? videoFiles : audioFiles
        let soundJumps = audioFiles.isEmpty ? discontinuities : []
        // Both tracks start their timeline at the same moment, so they stay in step when combined.
        let start = min(firstTime(of: videoFiles, video: true) ?? .max, firstTime(of: soundFiles, video: false) ?? .max)
        guard start != .max else { throw RemuxError.noMedia }

        let folder = output.deletingLastPathComponent()
        let videoOnly = folder.appendingPathComponent(output.lastPathComponent + ".video.mp4")
        let soundOnly = folder.appendingPathComponent(output.lastPathComponent + ".sound.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoOnly)
            try? FileManager.default.removeItem(at: soundOnly)
        }
        let hasVideo = try writeTrack(video: true, files: videoFiles, discontinuities: discontinuities, start: start, to: videoOnly, isCancelled: isCancelled)
        let hasSound = try writeTrack(video: false, files: soundFiles, discontinuities: soundJumps, start: start, to: soundOnly, isCancelled: isCancelled)
        try? FileManager.default.removeItem(at: output)
        switch (hasVideo, hasSound) {
        case (true, true): try combine(video: videoOnly, audio: soundOnly, to: output)
        case (true, false): try FileManager.default.moveItem(at: videoOnly, to: output)
        case (false, true): try FileManager.default.moveItem(at: soundOnly, to: output)
        case (false, false): throw RemuxError.noMedia
        }
    }

    /// When the first video frame (or sound frame) is shown, from the first pieces.
    private static func firstTime(of files: [URL], video: Bool) -> Int64? {
        let feeder = Feeder(files: Array(files.prefix(3)))
        while feeder.refill() {
            let frames = video ? feeder.demuxer.takeVideo() : feeder.demuxer.takeAudio()
            if let first = (video ? frames.first(where: \.isKey) : frames.first) { return first.pts }
        }
        return nil
    }

    /// Writes one track (the video or the sound) of the pieces into its own .mp4. Returns false if there's none.
    private static func writeTrack(video: Bool, files: [URL], discontinuities: Set<Int>, start: Int64, to output: URL,
                                   isCancelled: () -> Bool) throws -> Bool {
        let feeder = Feeder(files: files, discontinuities: discontinuities)
        var queue: [MediaFrame] = []
        func topUp() {
            while queue.count < 2 {
                queue += video ? feeder.demuxer.takeVideo() : feeder.demuxer.takeAudio()
                _ = video ? feeder.demuxer.takeAudio() : feeder.demuxer.takeVideo() // the other track: not wanted here
                if queue.count >= 2 || !feeder.refill() {
                    queue += video ? feeder.demuxer.takeVideo() : feeder.demuxer.takeAudio()
                    return
                }
            }
        }
        topUp()
        if video {
            // Video must start on a key frame.
            while let first = queue.first, !first.isKey { queue.removeFirst(); topUp() }
        }
        guard !queue.isEmpty else { return false }
        let format: CMFormatDescription
        if video {
            guard feeder.demuxer.hasVideoFormat else { return false }
            format = try videoDescription(feeder.demuxer)
        } else {
            guard let config = feeder.demuxer.aac else { return false }
            format = try audioDescription(config)
        }

        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: .mp4) } catch { throw RemuxError.writer(error.localizedDescription) }
        writer.shouldOptimizeForNetworkUse = false
        let input = AVAssetWriterInput(mediaType: video ? .video : .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw RemuxError.writer("the \(video ? "video" : "sound") track was refused") }
        writer.add(input)
        guard writer.startWriting() else { throw RemuxError.writer(writer.error?.localizedDescription ?? "it wouldn't start") }
        writer.startSession(atSourceTime: CMTime(value: start, timescale: 90000))

        var lastDuration: Int64 = 3000
        let soundDuration = CMTime(value: 1024, timescale: CMTimeScale(feeder.demuxer.aac?.sampleRate ?? 44100))
        while !isCancelled() {
            topUp()
            guard !queue.isEmpty else { break }
            let frame = queue.removeFirst()
            if frame.pts < start, !video { continue } // sound from before the first picture
            let timing: CMSampleTimingInfo
            if video {
                if let next = queue.first, next.dts > frame.dts { lastDuration = next.dts - frame.dts }
                timing = CMSampleTimingInfo(duration: CMTime(value: lastDuration, timescale: 90000),
                                            presentationTimeStamp: CMTime(value: frame.pts, timescale: 90000),
                                            decodeTimeStamp: CMTime(value: frame.dts, timescale: 90000))
            } else {
                timing = CMSampleTimingInfo(duration: soundDuration, presentationTimeStamp: CMTime(value: frame.pts, timescale: 90000),
                                            decodeTimeStamp: .invalid)
            }
            try append(frame, timing: timing, format: format, to: input, writer: writer, sync: !video || frame.isKey)
        }
        if isCancelled() {
            writer.cancelWriting()
            throw CancellationError()
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw RemuxError.writer(writer.error?.localizedDescription ?? "it didn't finish") }
        return true
    }

    /// Fragmented-MP4 streams: the init section followed by every piece is already a playable file.
    static func joinFragments(initSection: URL?, pieces: [URL], to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        for file in (initSection.map { [$0] } ?? []) + pieces {
            try autoreleasepool {
                try handle.write(contentsOf: try Data(contentsOf: file, options: .mappedIfSafe))
            }
        }
    }

    /// A video-only file and a sound-only file, copied together into one .mp4.
    static func combine(video: URL, audio: URL, to output: URL) throws {
        let result = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let composition = AVMutableComposition()
                let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
                let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
                let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
                let duration = try await videoAsset.load(.duration)
                if let track = videoTracks.first,
                   let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                }
                if let track = audioTracks.first,
                   let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let audioDuration = try await audioAsset.load(.duration)
                    try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)), of: track, at: .zero)
                }
                guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    throw RemuxError.writer("passthrough export isn't available")
                }
                try? FileManager.default.removeItem(at: output)
                export.outputURL = output
                export.outputFileType = .mp4
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    export.exportAsynchronously { continuation.resume() }
                }
                if export.status != .completed {
                    throw RemuxError.writer(export.error?.localizedDescription ?? "the export didn't finish")
                }
            } catch {
                result.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure = result.error { throw RemuxError.writer(failure.localizedDescription) }
    }

    private final class ResultBox: @unchecked Sendable {
        var error: Error?
    }

    // MARK: Building samples

    private static func append(_ frame: MediaFrame, timing: CMSampleTimingInfo, format: CMFormatDescription,
                               to input: AVAssetWriterInput, writer: AVAssetWriter, sync: Bool) throws {
        var timing = timing
        var block: CMBlockBuffer?
        let length = frame.data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { throw RemuxError.writer("out of memory") }
        _ = frame.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
            throw RemuxError.writer("a frame couldn't be prepared")
        }
        if !sync, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        // Wait while the writer catches up.
        var waited = 0
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, waited < 6000 else {
                throw RemuxError.writer(writer.error?.localizedDescription
                    ?? "it stopped taking frames (status \(writer.status.rawValue), at \(String(format: "%.2f", timing.presentationTimeStamp.seconds)) s)")
            }
            Thread.sleep(forTimeInterval: 0.005)
            waited += 1
        }
        guard input.append(sample) else { throw RemuxError.writer(writer.error?.localizedDescription ?? "a frame was refused") }
    }

    private static func videoDescription(_ demuxer: TSDemuxer) throws -> CMFormatDescription {
        guard let sps = demuxer.sps, let pps = demuxer.pps else { throw RemuxError.format("no parameter sets") }
        let sets = demuxer.videoCodec == .hevc ? [demuxer.vps ?? Data(), sps, pps] : [sps, pps]
        var description: CMFormatDescription?
        let status: OSStatus = {
            let buffers = sets.map { [UInt8]($0) }
            let pointers = buffers.map { UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, $0.count)) }
            defer { pointers.forEach { $0.deallocate() } }
            for (pointer, bytes) in zip(pointers, buffers) { pointer.initialize(from: bytes, count: bytes.count) }
            let constPointers = pointers.map { UnsafePointer($0) }
            let sizes = buffers.map(\.count)
            if demuxer.videoCodec == .hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                           parameterSetPointers: constPointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                       parameterSetPointers: constPointers, parameterSetSizes: sizes,
                                                                       nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }()
        guard status == noErr, let description else { throw RemuxError.format("video \(status)") }
        return description
    }

    private static func audioDescription(_ config: AACConfig) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(config.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: AudioFormatFlags(config.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, config.channels)), mBitsPerChannel: 0, mReserved: 0)
        let cookie = esDescriptor(config)
        var description: CMFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: bytes.baseAddress, extensions: nil,
                                           formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw RemuxError.format("sound \(status)") }
        return description
    }

    /// The MPEG-4 ES descriptor (what an MP4 "esds" box holds), Core Audio's magic cookie for AAC.
    static func esDescriptor(_ config: AACConfig) -> Data {
        let specific = config.audioSpecificConfig
        let decoderSpecific = Data([0x05, UInt8(specific.count)]) + specific
        var decoderConfig = Data([0x40, 0x15, 0, 0, 0]) // MPEG-4 audio, audio stream, buffer size
        decoderConfig += Data([0, 0, 0, 0, 0, 0, 0, 0]) // max and average bit rate: unknown
        decoderConfig += decoderSpecific
        let decoder = Data([0x04, UInt8(decoderConfig.count)]) + decoderConfig
        let sl = Data([0x06, 0x01, 0x02])
        let body = Data([0x00, 0x00, 0x00]) + decoder + sl // ES id, flags
        return Data([0x03, UInt8(body.count)]) + body
    }
}

/// Reads the pieces of one stream in order, a file at a time.
private final class Feeder {
    var demuxer = TSDemuxer()
    private let files: [URL]
    private let discontinuities: Set<Int>
    private var index = 0

    init(files: [URL], discontinuities: Set<Int> = []) {
        self.files = files
        self.discontinuities = discontinuities
    }

    /// Reads the next file. Returns false when there are none left.
    func refill() -> Bool {
        guard index < files.count else { return false }
        defer { index += 1 }
        guard let data = try? Data(contentsOf: files[index], options: .mappedIfSafe) else { return true }
        if discontinuities.contains(index) { demuxer.discontinuity() }
        if data.first == 0x47 || data.count >= 189 && data[data.startIndex + 188] == 0x47 {
            demuxer.feed(data)
        } else {
            demuxer.feedPackedAudio(data) // .aac pieces: ADTS, often after an ID3 tag
        }
        return true
    }
}
