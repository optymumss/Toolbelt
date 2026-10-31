import Foundation

// Reads HLS playlists (.m3u8): the format most video sites stream in. A "master" playlist lists
// the same video at several sizes; a "media" playlist lists the pieces (segments) of one of them.

/// One size of a video in a master playlist.
struct HLSVariant: Equatable {
    var url: URL
    var bandwidth: Int
    var width: Int?
    var height: Int?
    var codecs: String?
    /// When the sound is a separate stream (EXT-X-MEDIA), its playlist.
    var audioURL: URL?

    /// "1080p", or a speed when the playlist doesn't say the size.
    var label: String {
        if let height { return "\(height)p" }
        return "\(max(1, bandwidth / 1000)) kb/s"
    }
}

struct HLSKey: Equatable {
    enum Method: Equatable {
        case none, aes128
        /// SAMPLE-AES, FairPlay and other copy protection (DRM): never downloaded.
        case protected
    }

    var method: Method
    var url: URL?
    /// The IV given in the playlist; nil means "the segment's sequence number".
    var iv: Data?
}

struct HLSSegment: Equatable {
    var url: URL
    var duration: Double
    /// Part of the file (EXT-X-BYTERANGE), as offset and length.
    var byteRange: (offset: Int64, length: Int64)?
    var sequence: Int
    var key: HLSKey
    var discontinuity: Bool
    /// The init section (EXT-X-MAP) for fragmented-MP4 streams.
    var map: HLSMap?

    static func == (a: HLSSegment, b: HLSSegment) -> Bool {
        a.url == b.url && a.duration == b.duration && a.byteRange?.offset == b.byteRange?.offset
            && a.byteRange?.length == b.byteRange?.length && a.sequence == b.sequence && a.key == b.key
            && a.discontinuity == b.discontinuity && a.map == b.map
    }
}

struct HLSMap: Equatable {
    var url: URL
    var byteRange: (offset: Int64, length: Int64)?

    static func == (a: HLSMap, b: HLSMap) -> Bool {
        a.url == b.url && a.byteRange?.offset == b.byteRange?.offset && a.byteRange?.length == b.byteRange?.length
    }
}

struct HLSMediaPlaylist: Equatable {
    var segments: [HLSSegment]
    /// Whether any piece is copy-protected (DRM).
    var isProtected: Bool { segments.contains { $0.key.method == .protected } }
    /// Fragmented MP4 (.m4s pieces with an init section) rather than MPEG-TS (.ts pieces).
    var isFragmentedMP4: Bool { segments.first?.map != nil }
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

enum HLSPlaylist: Equatable {
    case master([HLSVariant])
    case media(HLSMediaPlaylist)

    /// Reads a playlist; `base` is where it came from (pieces are often given relative to it).
    static func parse(_ text: String, base: URL) -> HLSPlaylist? {
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(parseMaster(lines, base: base))
        }
        return .media(parseMedia(lines, base: base))
    }

    private static func parseMaster(_ lines: [String], base: URL) -> [HLSVariant] {
        var audioGroups: [String: URL] = [:]
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attributes = attributeList(line)
            guard attributes["TYPE"] == "AUDIO", let group = attributes["GROUP-ID"], let uri = attributes["URI"],
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            // The default track of each group wins; otherwise the first.
            if audioGroups[group] == nil || attributes["DEFAULT"] == "YES" { audioGroups[group] = url }
        }
        var variants: [HLSVariant] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributeList(line)
            } else if let attributes = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                let size = attributes["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                variants.append(HLSVariant(
                    url: url,
                    bandwidth: Int(attributes["AVERAGE-BANDWIDTH"] ?? attributes["BANDWIDTH"] ?? "") ?? 0,
                    width: size?.count == 2 ? size?[0] : nil,
                    height: size?.count == 2 ? size?[1] : nil,
                    codecs: attributes["CODECS"],
                    audioURL: attributes["AUDIO"].flatMap { audioGroups[$0] }))
            }
        }
        return variants
    }

    private static func parseMedia(_ lines: [String], base: URL) -> HLSMediaPlaylist {
        var segments: [HLSSegment] = []
        var sequence = 0
        var key = HLSKey(method: .none)
        var map: HLSMap?
        var duration: Double?
        var range: (Int64, Int64?)?
        var discontinuity = false
        var nextOffset: [URL: Int64] = [:]

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                duration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                range = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY"), !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                discontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                key = parseKey(attributeList(line), base: base)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = attributeList(line)
                if let uri = attributes["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    let mapRange = attributes["BYTERANGE"].flatMap(byteRange)
                    map = HLSMap(url: url, byteRange: mapRange.map { ($0.1 ?? 0, $0.0) })
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL {
                var segmentRange: (offset: Int64, length: Int64)?
                if let (length, offset) = range {
                    let start = offset ?? nextOffset[url] ?? 0
                    segmentRange = (start, length)
                    nextOffset[url] = start + length
                }
                segments.append(HLSSegment(url: url, duration: duration ?? 0, byteRange: segmentRange, sequence: sequence,
                                           key: key, discontinuity: discontinuity, map: map))
                sequence += 1
                duration = nil
                range = nil
                discontinuity = false
            }
        }
        return HLSMediaPlaylist(segments: segments)
    }

    private static func parseKey(_ attributes: [String: String], base: URL) -> HLSKey {
        let method = attributes["METHOD"] ?? "NONE"
        let format = attributes["KEYFORMAT"] ?? "identity"
        if method == "NONE" { return HLSKey(method: .none) }
        guard method == "AES-128", format == "identity" else { return HLSKey(method: .protected) }
        var iv: Data?
        if var hex = attributes["IV"] {
            if hex.lowercased().hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
            iv = Data(hexString: hex.count < 32 ? String(repeating: "0", count: 32 - hex.count) + hex : hex)
        }
        return HLSKey(method: .aes128, url: attributes["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }, iv: iv)
    }

    /// "1000@200" → length 1000 from byte 200; "1000" → length 1000 straight after the previous one.
    private static func byteRange(_ text: String) -> (Int64, Int64?)? {
        let parts = text.split(separator: "@").map { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard let length = parts.first ?? nil else { return nil }
        return (length, parts.count > 1 ? parts[1] : nil)
    }

    /// The attributes after a tag's colon: KEY=value,KEY="quoted, value",…
    static func attributeList(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", readingKey = true, quoted = false
        func store() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""; value = ""; readingKey = true
        }
        for character in line[line.index(after: colon)...] {
            if readingKey {
                if character == "=" { readingKey = false } else if character == "," { store() } else { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                store()
            } else {
                value.append(character)
            }
        }
        store()
        return result
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
