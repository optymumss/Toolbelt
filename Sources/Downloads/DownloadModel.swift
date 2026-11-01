import AppKit

/// One part of a file, downloaded over its own connection.
struct Segment: Codable, Equatable {
    var start: Int64
    /// Last byte (inclusive), or -1 when the file's size isn't known.
    var end: Int64
    var received: Int64 = 0

    var next: Int64 { start + received }
    var isComplete: Bool { end >= 0 && next > end }
    var remaining: Int64 { end >= 0 ? max(0, end - next + 1) : .max }
}

enum DownloadState: String, Codable {
    /// `queued`: waiting for its queue to start or for a free place in it.
    case queued, downloading, paused, completed, failed
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var name: String
    var state: DownloadState = .downloading
    var received: Int64 = 0
    var total: Int64? = nil
    var segments: [Segment] = []
    var acceptsRanges = false
    /// Where the finished file ended up.
    var finalPath: String? = nil
    var error: String? = nil
    var added = Date()
    var finished: Date? = nil
    /// Which queue it's in (nil: the first queue).
    var queueID: UUID? = nil
    /// Sent with every request, for links handed over by the browser: Cookie, Referer, User-Agent.
    var headers: [String: String]? = nil
    /// The name was chosen (by the browser), so the server's name doesn't replace it.
    var nameIsFixed: Bool? = nil
    /// "hls" for a streamed video (`url` is its playlist); nil for an ordinary file.
    var kind: String? = nil
    /// A streamed video's separate sound playlist, when it has one.
    var audioURL: URL? = nil
    /// The web page it was started from, to start it again there if its link stops working.
    var pageURL: URL? = nil
    /// 0.34: a folder chosen for this download (the site grabber's), instead of its category's.
    var folder: String? = nil

    var isStream: Bool { kind == "hls" }

    // Shown while downloading; not saved.
    var speed: Double = 0
    var connections = 0

    enum CodingKeys: String, CodingKey {
        case id, url, name, state, received, total, segments, acceptsRanges, finalPath, error, added, finished, queueID, headers, nameIsFixed
        case kind, audioURL, pageURL, folder
    }

    var progress: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    var secondsLeft: Double? {
        guard let total, speed > 1 else { return nil }
        return Double(total - received) / speed
    }
}

/// Plans and re-plans how a file is split into parts.
enum SegmentPlanner {
    /// Parts smaller than this aren't worth their own connection.
    static let minimumPart: Int64 = 512 * 1024

    /// Splits a file of `total` bytes into up to `connections` equal parts.
    static func plan(total: Int64, connections: Int) -> [Segment] {
        guard total > 0 else { return [Segment(start: 0, end: -1)] }
        let count = Int(max(1, min(Int64(connections), total / minimumPart)))
        let size = total / Int64(count)
        return (0..<count).map { i in
            let start = Int64(i) * size
            let end = i == count - 1 ? total - 1 : start + size - 1
            return Segment(start: start, end: end)
        }
    }

    /// When a connection frees up, the part with the most left is split in two:
    /// the original connection keeps the first half, a new one takes the second.
    /// Returns the index of the part that was shortened, and the new part.
    static func split(_ segments: [Segment], busy: Set<Int>) -> (shortened: Int, new: Segment)? {
        let candidates = segments.indices.filter { busy.contains($0) && segments[$0].end >= 0 && !segments[$0].isComplete }
        guard let index = candidates.max(by: { segments[$0].remaining < segments[$1].remaining }) else { return nil }
        let segment = segments[index]
        guard segment.remaining >= 2 * minimumPart else { return nil }
        let middle = segment.next + segment.remaining / 2
        return (index, Segment(start: middle, end: segment.end))
    }
}

/// Which folder a finished download goes into.
enum DownloadCategory: String, CaseIterable {
    case video = "Video"
    case music = "Music"
    case documents = "Documents"
    case programs = "Programs"
    case archives = "Archives"
    case images = "Images"
    case other = "Other"

    static let extensions: [DownloadCategory: Set<String>] = [
        .video: ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "pages", "numbers", "key", "csv", "epub", "odt", "ods"],
        .programs: ["dmg", "pkg", "app", "exe", "msi", "mpkg"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"],
        .images: ["jpg", "jpeg", "png", "gif", "heic", "webp", "svg", "tif", "tiff", "bmp", "raw"],
    ]

    static func of(_ fileName: String) -> DownloadCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return extensions.first { $0.value.contains(ext) }?.key ?? .other
    }
}

enum ByteFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        size(Int64(bytesPerSecond)) + "/s"
    }

    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded(.up))) s left" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.up))) min left" }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds - Double(hours) * 3600) / 60)
        return "\(hours) h \(minutes) min left"
    }
}
