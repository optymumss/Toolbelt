import Foundation

// Takes apart MPEG-TS video (the .ts pieces of most HLS streams) into video frames and sound
// frames with their timings, ready to be put into an .mp4 by VideoRemuxer. Pure logic, no
// AVFoundation, so it can be checked on its own.

enum VideoCodec: Equatable {
    case h264, hevc
}

/// One video frame (an access unit) or one AAC sound frame.
struct MediaFrame: Equatable {
    /// Video: NAL units, each with a 4-byte length in front (as MP4 stores them). Sound: one raw AAC frame.
    var data: Data
    /// In 90 kHz ticks.
    var pts: Int64
    var dts: Int64
    var isKey: Bool
}

/// What's needed to describe the sound: from the first ADTS header.
struct AACConfig: Equatable {
    /// 2 is AAC-LC, by far the most common.
    var objectType: Int
    var frequencyIndex: Int
    var channels: Int

    static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    var sampleRate: Int { frequencyIndex < Self.rates.count ? Self.rates[frequencyIndex] : 44100 }

    /// The 2-byte AudioSpecificConfig MP4 files carry for AAC.
    var audioSpecificConfig: Data {
        let value = (objectType << 11) | (frequencyIndex << 7) | (max(1, channels) << 3)
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }
}

struct TSDemuxer {
    private(set) var videoCodec: VideoCodec?
    /// Parameter sets (SPS, PPS, and for HEVC VPS), the last seen of each.
    private(set) var vps: Data?
    private(set) var sps: Data?
    private(set) var pps: Data?
    private(set) var aac: AACConfig?

    /// Frames found so far; take them with `takeVideo()` / `takeAudio()`.
    private(set) var video: [MediaFrame] = []
    private(set) var audio: [MediaFrame] = []

    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var pes: [Int: Data] = [:]
    private var leftover = Data()
    /// Undoes the 33-bit wrap of timestamps (every 26.5 hours) and joins discontinuities.
    private var lastRaw: Int64?
    private var wraps: Int64 = 0
    private var offset: Int64 = 0
    private var pendingDiscontinuity = false
    private(set) var latest: Int64 = 0

    init() {}

    var hasVideoFormat: Bool { videoCodec != nil && sps != nil && pps != nil && (videoCodec != .hevc || vps != nil) }
    var hasStreams: Bool { videoPID != nil || audioPID != nil }

    mutating func takeVideo() -> [MediaFrame] { defer { video = [] }; return video }
    mutating func takeAudio() -> [MediaFrame] { defer { audio = [] }; return audio }

    /// The next piece follows a jump in the stream (EXT-X-DISCONTINUITY): carry on from where the last ended.
    mutating func discontinuity() {
        pendingDiscontinuity = true
    }

    /// Feeds one whole piece (a .ts file). Each piece is complete in HLS, so frames still open at its end are finished.
    mutating func feed(_ data: Data) {
        var bytes = leftover + data
        leftover = Data()
        // Find the first sync byte (some files have junk in front).
        var start = bytes.startIndex
        while start + 188 <= bytes.endIndex, !(bytes[start] == 0x47 && (start + 188 == bytes.endIndex || bytes[start + 188] == 0x47)) {
            start += 1
        }
        bytes = bytes[start...]
        var index = bytes.startIndex
        while index + 188 <= bytes.endIndex {
            if bytes[index] == 0x47 {
                packet(bytes[index..<(index + 188)])
                index += 188
            } else {
                index += 1 // lost sync: look for the next packet
            }
        }
        flush()
    }

    /// Feeds one piece of "packed audio": raw ADTS frames, usually after an ID3 tag giving the start time.
    mutating func feedPackedAudio(_ data: Data) {
        var bytes = data
        var timestamp: Int64 = latest
        if bytes.count > 10, bytes[bytes.startIndex] == 0x49, bytes[bytes.startIndex + 1] == 0x44, bytes[bytes.startIndex + 2] == 0x33 {
            let base = bytes.startIndex
            let size = (Int(bytes[base + 6]) << 21) | (Int(bytes[base + 7]) << 14) | (Int(bytes[base + 8]) << 7) | Int(bytes[base + 9])
            let tag = bytes[base..<min(bytes.endIndex, base + 10 + size)]
            if let found = Self.id3Timestamp(tag) { timestamp = found }
            bytes = bytes[min(bytes.endIndex, base + 10 + size)...]
        }
        adts(Data(bytes), pts: adjust(timestamp))
    }

    // MARK: Packets

    private mutating func packet(_ p: Data.SubSequence) {
        let b = p.startIndex
        let unitStart = p[b + 1] & 0x40 != 0
        let pid = (Int(p[b + 1] & 0x1F) << 8) | Int(p[b + 2])
        let adaptation = (p[b + 3] >> 4) & 0x3
        var payload = b + 4
        if adaptation == 2 { return } // no payload
        if adaptation == 3 { payload += 1 + Int(p[b + 4]) }
        guard payload < p.endIndex else { return }
        let body = p[payload...]

        if pid == 0 {
            if unitStart { parsePAT(body) }
        } else if pid == pmtPID {
            if unitStart { parsePMT(body) }
        } else if pid == videoPID || pid == audioPID {
            if unitStart, let previous = pes[pid] {
                finishPES(previous, pid: pid)
                pes[pid] = nil
            }
            if unitStart { pes[pid] = Data(body) } else if pes[pid] != nil { pes[pid]!.append(contentsOf: body) }
        }
    }

    private mutating func flush() {
        for (pid, data) in pes.sorted(by: { $0.key < $1.key }) { finishPES(data, pid: pid) }
        pes = [:]
    }

    /// The section after a pointer field, from table id to the end of the payload.
    private func section(_ body: Data.SubSequence) -> Data.SubSequence? {
        guard let pointer = body.first else { return nil }
        let start = body.startIndex + 1 + Int(pointer)
        guard start + 3 <= body.endIndex else { return nil }
        let length = (Int(body[start + 1] & 0x0F) << 8) | Int(body[start + 2])
        return body[start..<min(body.endIndex, start + 3 + length)]
    }

    private mutating func parsePAT(_ body: Data.SubSequence) {
        guard let s = section(body), s.count >= 12 else { return }
        var index = s.startIndex + 8
        while index + 4 <= s.endIndex - 4 { // the last 4 bytes are the CRC
            let program = (Int(s[index]) << 8) | Int(s[index + 1])
            let pid = (Int(s[index + 2] & 0x1F) << 8) | Int(s[index + 3])
            if program != 0 { pmtPID = pid; return }
            index += 4
        }
    }

    private mutating func parsePMT(_ body: Data.SubSequence) {
        guard let s = section(body), s.count >= 16 else { return }
        let infoLength = (Int(s[s.startIndex + 10] & 0x0F) << 8) | Int(s[s.startIndex + 11])
        var index = s.startIndex + 12 + infoLength
        while index + 5 <= s.endIndex - 4 {
            let type = s[index]
            let pid = (Int(s[index + 1] & 0x1F) << 8) | Int(s[index + 2])
            let esInfo = (Int(s[index + 3] & 0x0F) << 8) | Int(s[index + 4])
            switch type {
            case 0x1B where videoPID == nil: videoPID = pid; videoCodec = .h264
            case 0x24 where videoPID == nil: videoPID = pid; videoCodec = .hevc
            case 0x0F where audioPID == nil: audioPID = pid
            default: break
            }
            index += 5 + esInfo
        }
    }

    // MARK: PES

    private mutating func finishPES(_ data: Data, pid: Int) {
        let d = data
        let b = d.startIndex
        guard d.count >= 9, d[b] == 0, d[b + 1] == 0, d[b + 2] == 1 else { return }
        let flags = d[b + 7] >> 6
        let headerLength = Int(d[b + 8])
        let payloadStart = b + 9 + headerLength
        guard payloadStart <= d.endIndex else { return }
        var pts: Int64?
        var dts: Int64?
        if flags & 0x2 != 0, d.count >= 14 { pts = Self.timestamp(d, at: b + 9) }
        if flags == 0x3, d.count >= 19 { dts = Self.timestamp(d, at: b + 14) }
        guard let rawPTS = pts else { return }
        let presentation = adjust(rawPTS)
        let decode = dts.map { presentation - (rawPTS - $0) } ?? presentation
        let payload = Data(d[payloadStart...])
        if pid == videoPID {
            videoFrame(payload, pts: presentation, dts: decode)
        } else {
            adts(payload, pts: presentation)
        }
    }

    static func timestamp(_ d: Data, at i: Int) -> Int64 {
        (Int64(d[i] >> 1) & 0x07) << 30 | Int64(d[i + 1]) << 22 | (Int64(d[i + 2]) >> 1) << 15 | Int64(d[i + 3]) << 7 | Int64(d[i + 4]) >> 1
    }

    /// Unwraps the 33-bit clock, and after a discontinuity shifts timestamps to carry on from the last.
    private mutating func adjust(_ raw: Int64) -> Int64 {
        var unwrapped = raw + wraps
        if let last = lastRaw {
            if raw < last - (1 << 32) {
                wraps += 1 << 33 // the clock went past its top and started again
                unwrapped = raw + wraps
                lastRaw = raw
            } else if raw > last + (1 << 32) {
                unwrapped = raw + wraps - (1 << 33) // a late frame from before the wrap
            } else {
                lastRaw = max(last, raw)
            }
        } else {
            lastRaw = raw
        }
        var value = unwrapped + offset
        if pendingDiscontinuity {
            pendingDiscontinuity = false
            offset += latest + 3000 - value // carry on a frame (1/30 s) after the last
            value = latest + 3000
        }
        latest = max(latest, value)
        return value
    }

    private mutating func videoFrame(_ payload: Data, pts: Int64, dts: Int64) {
        var units = Data()
        var key = false
        for nal in Self.nalUnits(payload) {
            guard let header = nal.first else { continue }
            switch videoCodec {
            case .hevc:
                let type = (header >> 1) & 0x3F
                switch type {
                case 32: vps = nal; continue
                case 33: sps = nal; continue
                case 34: pps = nal; continue
                case 35: continue // access unit delimiter
                case 16...21: key = true
                default: break
                }
            default:
                let type = header & 0x1F
                switch type {
                case 7: sps = nal; continue
                case 8: pps = nal; continue
                case 9: continue
                case 5: key = true
                default: break
                }
            }
            var length = UInt32(nal.count).bigEndian
            units.append(Data(bytes: &length, count: 4))
            units.append(nal)
        }
        guard !units.isEmpty else { return }
        video.append(MediaFrame(data: units, pts: pts, dts: dts, isKey: key))
    }

    /// Splits Annex B data (00 00 01 or 00 00 00 01 before each unit) into NAL units.
    static func nalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0, start = -1
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, bytes[end - 1] == 0 { end -= 1 } // the zero of a 4-byte start code, and trailing zeros
                    if end > start { units.append(Data(bytes[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    private mutating func adts(_ payload: Data, pts: Int64) {
        let bytes = [UInt8](payload)
        var i = 0, count: Int64 = 0
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xFF, bytes[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let noCRC = bytes[i + 1] & 0x01 == 1
            let config = AACConfig(objectType: Int(bytes[i + 2] >> 6) + 1, frequencyIndex: Int((bytes[i + 2] >> 2) & 0x0F),
                                   channels: Int((bytes[i + 2] & 0x01) << 2) | Int(bytes[i + 3] >> 6))
            let length = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | Int(bytes[i + 5] >> 5)
            let header = noCRC ? 7 : 9
            guard length > header, i + length <= bytes.count else { break }
            if aac == nil { aac = config }
            let rate = Int64(config.sampleRate)
            let time = pts + count * 1024 * 90000 / rate
            audio.append(MediaFrame(data: Data(bytes[(i + header)..<(i + length)]), pts: time, dts: time, isKey: true))
            latest = max(latest, time)
            count += 1
            i += length
        }
    }

    /// The start time Apple's packed-audio format keeps in an ID3 PRIV frame.
    static func id3Timestamp(_ tag: Data.SubSequence) -> Int64? {
        let owner = Data("com.apple.streaming.transportStreamTimestamp".utf8)
        guard let range = tag.range(of: owner) else { return nil }
        let start = range.upperBound + 1 // after the name's zero byte
        guard start + 8 <= tag.endIndex else { return nil }
        var value: Int64 = 0
        for byte in tag[start..<(start + 8)] { value = value << 8 | Int64(byte) }
        return value & ((1 << 33) - 1)
    }
}
