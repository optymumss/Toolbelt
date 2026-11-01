import Foundation

// 0.34: download everything on a page. The pure parts live here (tested in Tests.swift):
// - `CategoryRule` / `DownloadCategories`: which folder each kind of file goes into (editable per category);
// - `LinkExtractor`: the links, pictures, videos and files on a web page;
// - `FoundLink` / `LinkSelection`: the list you tick links in, with filters by type;
// - `ClipboardLinks`: download links in copied text, and which ones to offer to download;
// - `GrabTemplate` / `SiteGrabber`: explores a site and finds files, or saves the whole site for offline use;
// - `OfflinePaths`: where each page and file of an offline copy goes, and its links rewritten to those copies.

// MARK: - Category folders

/// A kind of file, the extensions that make it that kind, and where it's saved.
struct CategoryRule: Codable, Equatable, Identifiable {
    var name: String
    var extensions: [String]
    /// A folder of its own; nil: a folder named after the category inside the downloads folder
    /// (or the downloads folder itself when sorting by type is off).
    var folder: String? = nil

    var id: String { name }
    var extensionsText: String { extensions.joined(separator: ", ") }
}

enum DownloadCategories {
    static let otherName = DownloadCategory.other.rawValue

    /// The usual categories, in the order they're shown. "Other" has no extensions: it takes everything else.
    static var defaults: [CategoryRule] {
        let order: [DownloadCategory] = [.video, .music, .documents, .programs, .archives, .images]
        return order.map { CategoryRule(name: $0.rawValue, extensions: (DownloadCategory.extensions[$0] ?? []).sorted()) }
            + [CategoryRule(name: otherName, extensions: [])]
    }

    /// "mp4, .MOV  mkv;webm" → ["mp4", "mov", "mkv", "webm"]
    static func parseExtensions(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".*")) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The category a file belongs to: the first whose extensions include its own, else "Other".
    static func rule(for fileName: String, in rules: [CategoryRule]) -> CategoryRule {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let match = rules.first(where: { $0.name != otherName && $0.extensions.contains(ext) }) { return match }
        return rules.first { $0.name == otherName } ?? CategoryRule(name: otherName, extensions: [])
    }

    static func name(for fileName: String, in rules: [CategoryRule]) -> String { rule(for: fileName, in: rules).name }

    /// Where a finished file goes. A category's own folder always wins; otherwise the downloads folder,
    /// with a folder per category when sorting is on.
    static func folder(for fileName: String, base: URL, sortByType: Bool, rules: [CategoryRule]) -> URL {
        let rule = rule(for: fileName, in: rules)
        if let custom = rule.folder, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return sortByType ? base.appendingPathComponent(rule.name, isDirectory: true) : base
    }

    /// Saved categories, with any of the usual ones that are missing added back (so "Other" always exists).
    static func merged(_ saved: [CategoryRule]) -> [CategoryRule] {
        var result = saved.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        for rule in defaults where !result.contains(where: { $0.name == rule.name }) {
            result.append(rule)
        }
        // "Other" goes last: it's what's left.
        if let index = result.firstIndex(where: { $0.name == otherName }) { result.append(result.remove(at: index)) }
        return result
    }
}

// MARK: - Links on a page

/// A link found on a page, in copied text, or by the site grabber.
struct FoundLink: Identifiable, Hashable, Codable {
    var url: URL
    /// The link's words, or a picture's description.
    var text: String = ""
    /// Found as a picture or a video/sound on the page (whatever its address looks like).
    var media: MediaKind? = nil

    enum MediaKind: String, Codable { case picture, video, sound }

    var id: URL { url }

    /// The file name it will get.
    var name: String {
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return url.host ?? "download" }
        return last.removingPercentEncoding ?? last
    }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    static let pageExtensions: Set<String> = ["html", "htm", "php", "asp", "aspx", "jsp", "cgi", "shtml", "xhtml", "cfm", "pl"]

    /// A web page rather than a file (no extension, or one of the page ones), unless it's shown on the page as media.
    var isPage: Bool { media == nil && (fileExtension.isEmpty || Self.pageExtensions.contains(fileExtension)) }
}

enum LinkExtractor {
    struct Found: Equatable {
        enum Tag: String { case anchor, picture, video, sound, stylesheet, script, frame }
        var url: URL
        var text: String
        var tag: Tag
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed and tested, so this never fails.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let tagPattern = regex(#"<(a|img|source|video|audio|link|script|iframe|frame|embed|track)\b([^>]*)>"#)
    private static let attributePattern = regex(#"([a-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))"#)
    private static let anchorPattern = regex(#"<a\b([^>]*)>(.*?)</a\s*>"#)
    private static let basePattern = regex(#"<base\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))"#)
    private static let commentPattern = regex(#"<!--.*?-->"#)
    private static let cssURLPattern = regex(#"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)|@import\s+(?:"([^"]*)"|'([^']*)')"#)

    /// The value of each attribute of one tag (names in lower case).
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in attributePattern.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = text[nameRange].lowercased()
            for group in 2...4 {
                if let valueRange = Range(match.range(at: group), in: text) {
                    result[name] = decodeEntities(String(text[valueRange]))
                    break
                }
            }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&nbsp;", " "), ("&#x2F;", "/"), ("&#47;", "/"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return result
    }

    /// Text without its tags and extra spaces.
    static func plainText(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A link's address made absolute; nil for links that aren't to the web (mailto:, javascript:, #top, data:).
    static func resolve(_ value: String, base: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let lower = trimmed.lowercased()
        for scheme in ["javascript:", "mailto:", "data:", "tel:", "blob:", "about:"] where lower.hasPrefix(scheme) { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#"))) ?? trimmed
        guard let url = URL(string: trimmed, relativeTo: base) ?? URL(string: encoded, relativeTo: base),
              let absolute = URL(string: url.absoluteString),
              let scheme = absolute.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme), absolute.host != nil else { return nil }
        return withoutFragment(absolute)
    }

    static func withoutFragment(_ url: URL) -> URL {
        guard url.fragment != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = nil
        return parts.url ?? url
    }

    /// The page's own idea of where its links start from (<base href>), else its address.
    static func baseURL(of html: String, page: URL) -> URL {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = basePattern.firstMatch(in: html, range: range) else { return page }
        for group in 1...3 {
            if let valueRange = Range(match.range(at: group), in: html),
               let url = URL(string: decodeEntities(String(html[valueRange])), relativeTo: page) {
                return url.absoluteURL
            }
        }
        return page
    }

    /// Every link, picture, video, sound, stylesheet, script and frame on a page, once each, in page order.
    static func links(in html: String, page: URL) -> [Found] {
        let html = html.replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
        let base = baseURL(of: html, page: page)
        let range = NSRange(html.startIndex..., in: html)
        var anchorTexts: [Int: String] = [:]
        for match in anchorPattern.matches(in: html, range: range) {
            if let inner = Range(match.range(at: 2), in: html) { anchorTexts[match.range.location] = plainText(String(html[inner])) }
        }
        var found: [Found] = []
        var seen = Set<URL>()
        func add(_ value: String?, _ tag: Found.Tag, _ text: String) {
            guard let value, let url = resolve(value, base: base), seen.insert(url).inserted else { return }
            found.append(Found(url: url, text: text, tag: tag))
        }
        for match in tagPattern.matches(in: html, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: html), let attributeRange = Range(match.range(at: 2), in: html) else { continue }
            let name = html[nameRange].lowercased()
            let attributes = attributes(String(html[attributeRange]))
            switch name {
            case "a":
                add(attributes["href"], .anchor, anchorTexts[match.range.location] ?? attributes["title"] ?? "")
            case "img":
                let text = attributes["alt"] ?? attributes["title"] ?? ""
                add(attributes["src"], .picture, text)
                add(attributes["data-src"], .picture, text)
                for candidate in srcset(attributes["srcset"]) { add(candidate, .picture, text) }
            case "video", "audio", "source", "embed", "track":
                let tag: Found.Tag = name == "audio" || (attributes["type"] ?? "").lowercased().hasPrefix("audio") ? .sound : .video
                if name == "source", attributes["srcset"] != nil {
                    for candidate in srcset(attributes["srcset"]) { add(candidate, .picture, "") }
                }
                if name != "track" { add(attributes["src"], tag, attributes["title"] ?? "") }
                if name == "video" { add(attributes["poster"], .picture, "") }
            case "link":
                let rel = (attributes["rel"] ?? "").lowercased()
                if rel.contains("stylesheet") { add(attributes["href"], .stylesheet, "") }
                else if rel.contains("icon") { add(attributes["href"], .picture, "") }
            case "script":
                add(attributes["src"], .script, "")
            case "iframe", "frame":
                add(attributes["src"], .frame, "")
            default:
                break
            }
        }
        return found
    }

    /// "a.jpg 1x, b.jpg 2x" → ["a.jpg", "b.jpg"]
    static func srcset(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").compactMap { part in
            part.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        }
    }

    /// Pictures and fonts a stylesheet uses, and other stylesheets it imports.
    static func cssLinks(in css: String, base: URL) -> [URL] {
        let range = NSRange(css.startIndex..., in: css)
        var seen = Set<URL>()
        var result: [URL] = []
        for match in cssURLPattern.matches(in: css, range: range) {
            for group in 1...5 {
                if let valueRange = Range(match.range(at: group), in: css),
                   let url = resolve(String(css[valueRange]), base: base), seen.insert(url).inserted {
                    result.append(url)
                    break
                }
            }
        }
        return result
    }

    /// What was found, as links you can tick (stylesheets and scripts aren't offered).
    static func downloadable(_ found: [Found]) -> [FoundLink] {
        found.compactMap { item in
            switch item.tag {
            case .anchor: return FoundLink(url: item.url, text: item.text)
            case .picture: return FoundLink(url: item.url, text: item.text, media: .picture)
            case .video: return FoundLink(url: item.url, text: item.text, media: .video)
            case .sound: return FoundLink(url: item.url, text: item.text, media: .sound)
            case .stylesheet, .script, .frame: return nil
            }
        }
    }
}

// MARK: - Choosing links

/// The kinds shown as buttons above the list of links: the download categories, plus web pages.
enum LinkSelection {
    static let pagesKind = "Web pages"

    static func kind(of link: FoundLink, rules: [CategoryRule]) -> String {
        if link.isPage { return pagesKind }
        switch link.media {
        case .picture?:
            let name = DownloadCategories.name(for: link.name, in: rules)
            return name == DownloadCategories.otherName ? DownloadCategory.images.rawValue : name
        case .video?, .sound?:
            let name = DownloadCategories.name(for: link.name, in: rules)
            if name != DownloadCategories.otherName { return name }
            return link.media == .sound ? DownloadCategory.music.rawValue : DownloadCategory.video.rawValue
        case nil:
            return DownloadCategories.name(for: link.name, in: rules)
        }
    }

    /// Ticked to begin with: every file, no web pages.
    static func initiallyTicked(_ links: [FoundLink]) -> Set<URL> {
        Set(links.filter { !$0.isPage }.map(\.url))
    }

    /// The kinds present, in the categories' order, with how many of each.
    static func counts(_ links: [FoundLink], rules: [CategoryRule]) -> [(kind: String, count: Int)] {
        var counts: [String: Int] = [:]
        for link in links { counts[kind(of: link, rules: rules), default: 0] += 1 }
        let order = rules.map(\.name) + [pagesKind]
        return order.compactMap { name in counts[name].map { (name, $0) } }
    }

    /// The links shown: of the kinds switched on (all when none are), matching the search words
    /// (in the name, the address or the link's text; ".pdf" style words match the extension).
    static func visible(_ links: [FoundLink], kinds: Set<String>, search: String, rules: [CategoryRule]) -> [FoundLink] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return links.filter { link in
            if !kinds.isEmpty, !kinds.contains(kind(of: link, rules: rules)) { return false }
            let haystack = (link.name + " " + link.url.absoluteString + " " + link.text).lowercased()
            return words.allSatisfy { word in
                word.hasPrefix(".") && word.count > 1 ? link.fileExtension == String(word.dropFirst()) : haystack.contains(word)
            }
        }
    }

    /// Links from several places, once each, keeping the first one's text.
    static func unique(_ links: [FoundLink]) -> [FoundLink] {
        var seen = Set<URL>()
        return links.filter { seen.insert($0.url).inserted }
    }
}

// MARK: - Links in copied text

enum ClipboardLinks {
    /// Download links in copied text (one per word or line), once each, at most 1000.
    static func links(in text: String) -> [URL] {
        guard text.count < 2_000_000 else { return [] }
        var seen = Set<URL>()
        var result: [URL] = []
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "<" || $0 == ">" }) {
            let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{},;'"))
            guard let url = DownloadManager.downloadableURL(from: cleaned), seen.insert(url).inserted else { continue }
            result.append(url)
            if result.count >= 1000 { break }
        }
        return result
    }

    /// The extensions offered for download when a link to one is copied: everything but pictures and web pages.
    static var defaultExtensions: [String] {
        let kinds: [DownloadCategory] = [.video, .music, .documents, .programs, .archives]
        return kinds.flatMap { (DownloadCategory.extensions[$0] ?? []).sorted() }.filter { $0 != "txt" && $0 != "md" && $0 != "csv" }
    }

    /// What to offer for something copied: nothing, one file, or several links to choose from.
    enum Offer: Equatable {
        case none
        case one(URL)
        case several([URL])
    }

    static func offer(for text: String, extensions: Set<String>) -> Offer {
        let links = links(in: text)
        let wanted = links.filter { extensions.contains(FoundLink(url: $0).fileExtension) }
        if wanted.isEmpty { return .none }
        if links.count == 1 { return .one(links[0]) }
        return .several(links)
    }
}

// MARK: - Site grabber

enum GrabTemplate: String, CaseIterable, Codable, Identifiable {
    case pictures, videos, files, site

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pictures: return "All pictures on a site"
        case .videos: return "All videos and sound on a site"
        case .files: return "All files on a page and the pages it links to"
        case .site: return "The whole site, to read offline"
        }
    }

    var summary: String {
        switch self {
        case .pictures: return "Looks through the site's pages and lists every picture, to download the ones you tick."
        case .videos: return "Looks through the site's pages and lists every video and sound file."
        case .files: return "Lists every file (documents, programs, archives, music, videos, pictures) linked from the start page and the pages one level down."
        case .site: return "Saves the site's pages with their pictures, styles and files into a folder, with the links between them working offline."
        }
    }

    var defaultDepth: Int { self == .site ? 3 : 1 }

    /// Whether a found link belongs in this template's list.
    func wants(_ link: FoundLink, rules: [CategoryRule]) -> Bool {
        let kind = LinkSelection.kind(of: link, rules: rules)
        switch self {
        case .pictures: return kind == DownloadCategory.images.rawValue
        case .videos: return kind == DownloadCategory.video.rawValue || kind == DownloadCategory.music.rawValue
        case .files, .site: return kind != LinkSelection.pagesKind
        }
    }
}

struct GrabSettings: Equatable {
    var start: URL
    var template: GrabTemplate
    /// How many clicks away from the start page to look (0: only the start page).
    var depth: Int
    var maxPages = 300
    var maxFiles = 2000
    /// Only pages (and, for offline copies, files) on the start page's site.
    var sameSite = true

    init(start: URL, template: GrabTemplate, depth: Int? = nil) {
        self.start = start
        self.template = template
        self.depth = depth ?? template.defaultDepth
    }

    func isSameSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let startHost = start.host?.lowercased() else { return false }
        func bare(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return bare(host) == bare(startHost)
    }
}

/// Where each page and file of an offline copy goes, relative to the copy's folder, and how a saved page's
/// links are changed to point at the saved copies.
enum OfflinePaths {
    /// "https://example.com/docs/" → "docs/index.html"; "/about" → "about.html"; "/a.php?id=2" → "a.php_id=2.html";
    /// "/img/logo.png" → "img/logo.png". Pages from another site go into a folder named after it.
    static func path(for url: URL, isPage: Bool, home: URL) -> String {
        // URLComponents keeps a folder's last "/" (URL.path drops it).
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        var parts = path.split(separator: "/").map { safe(String($0)) }
        if parts.isEmpty { parts = ["index.html"] }
        var last = parts.removeLast()
        if let query = url.query, !query.isEmpty {
            let ext = (last as NSString).pathExtension
            let stem = ext.isEmpty || isPage ? last : (last as NSString).deletingPathExtension
            last = stem + "_" + safe(query) + (ext.isEmpty || isPage ? "" : "." + ext)
        }
        if isPage {
            let ext = (last as NSString).pathExtension.lowercased()
            if ext != "html" && ext != "htm" { last += ".html" }
        }
        parts.append(last)
        var result = parts.joined(separator: "/")
        let sameSite = url.host?.lowercased() == home.host?.lowercased() && url.port == home.port
        if !sameSite { result = "_other/" + safe(url.host ?? "site") + "/" + result }
        return result
    }

    static func safe(_ part: String) -> String {
        let decoded = part.removingPercentEncoding ?? part
        let cleaned = decoded.map { ":/\\?*|\"<>".contains($0) ? "_" : $0 }
        return String(String(cleaned).prefix(120))
    }

    /// The way from one saved file to another: "docs/a.html" to "img/b.png" is "../img/b.png".
    static func relative(from: String, to: String) -> String {
        var fromParts = from.split(separator: "/").dropLast().map(String.init)
        var toParts = to.split(separator: "/").map(String.init)
        while let first = fromParts.first, let other = toParts.first, toParts.count > 1, first == other {
            fromParts.removeFirst()
            toParts.removeFirst()
        }
        return (Array(repeating: "..", count: fromParts.count) + toParts).map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? $0
        }.joined(separator: "/")
    }

    private static let attributePattern = try! NSRegularExpression(
        pattern: #"(\s(?:href|src|poster|data-src)\s*=\s*)("[^"]*"|'[^']*')"#, options: [.caseInsensitive])
    private static let cssPattern = try! NSRegularExpression(pattern: #"url\(\s*(["']?)([^"')]*)\1\s*\)"#, options: [.caseInsensitive])

    /// A saved page with its links to saved pages and files pointing at the copies (anything not saved keeps
    /// its full web address, so it still works online).
    static func rewrite(html: String, page: URL, savedAt pagePath: String, saved: [URL: String]) -> String {
        let base = LinkExtractor.baseURL(of: html, page: page)
        var result = html.replacingOccurrences(of: #"<base\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = replace(attributePattern, in: result) { match, text in
            guard let prefix = Range(match.range(at: 1), in: text), let quoted = Range(match.range(at: 2), in: text) else { return nil }
            let value = String(text[quoted])
            let quote = value.first.map(String.init) ?? "\""
            let inner = LinkExtractor.decodeEntities(String(value.dropFirst().dropLast()))
            guard let target = link(inner, base: base, pagePath: pagePath, saved: saved) else { return nil }
            return String(text[prefix]) + quote + target + quote
        }
        result = rewriteCSS(result, base: base, path: pagePath, saved: saved)
        return result
    }

    static func rewriteCSS(_ css: String, base: URL, path: String, saved: [URL: String]) -> String {
        replace(cssPattern, in: css) { match, text in
            guard let value = Range(match.range(at: 2), in: text),
                  let target = link(String(text[value]), base: base, pagePath: path, saved: saved) else { return nil }
            // No quotes: it may sit inside a style="…" attribute (the path has no spaces or brackets left).
            return "url(\(target))"
        }
    }

    /// Where a link should point in the offline copy, or nil to leave it as it is.
    static func link(_ value: String, base: URL, pagePath: String, saved: [URL: String]) -> String? {
        guard let url = LinkExtractor.resolve(value, base: base) else { return nil }
        let fragment = value.firstIndex(of: "#").map { String(value[$0...]) } ?? ""
        if let local = saved[url] { return relative(from: pagePath, to: local) + fragment }
        // Not saved: the full address, so it still works (a relative one would break in the copy).
        return value.hasPrefix("http") ? nil : url.absoluteString + fragment
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String,
                                _ change: (NSTextCheckingResult, String) -> String?) -> String {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var last = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            result += change(match, text) ?? String(text[range])
            last = range.upperBound
        }
        result += text[last...]
        return result
    }
}

/// Explores a site page by page (breadth first, up to the depth and limits in `GrabSettings`).
/// Fetching is passed in, so the tests can use a pretend site.
final class SiteGrabber: @unchecked Sendable {
    struct Page {
        var data: Data
        var mimeType: String
        /// Where it ended up after redirects.
        var url: URL
    }

    typealias Fetch = @Sendable (URL) async -> Page?

    struct Progress: Equatable {
        var pagesChecked = 0
        var filesFound = 0
        var saved = 0
        var current = ""
    }

    struct Result {
        var pages: [URL] = []
        var files: [FoundLink] = []
        /// Offline copies: the start page's file, and every page and file saved.
        var startFile: String? = nil
        var saved: [URL: String] = [:]
        var stopped = false
    }

    let settings: GrabSettings
    let rules: [CategoryRule]
    private let fetch: Fetch
    private let lock = NSLock()
    private var cancelled = false

    init(settings: GrabSettings, rules: [CategoryRule], fetch: @escaping Fetch) {
        self.settings = settings
        self.rules = rules
        self.fetch = fetch
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    static func isHTML(_ page: Page) -> Bool {
        let type = page.mimeType.lowercased()
        if type.contains("html") { return true }
        if !type.isEmpty && type != "application/octet-stream" { return false }
        let head = String(decoding: page.data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<html") || head.contains("<!doctype html")
    }

    static func text(of page: Page) -> String {
        String(data: page.data, encoding: .utf8) ?? String(data: page.data, encoding: .isoLatin1) ?? ""
    }

    /// Finds the files the template wants. Pages are followed only on the start page's site (when `sameSite`).
    func explore(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Result {
        var result = Result()
        var state = Progress()
        var visited = Set<URL>()
        var files = Set<URL>()
        var level: [URL] = [settings.start]
        visited.insert(LinkExtractor.withoutFragment(settings.start))
        for depth in 0...max(0, settings.depth) {
            var next: [URL] = []
            for pageURL in level {
                if isCancelled || result.pages.count >= settings.maxPages || result.files.count >= settings.maxFiles {
                    result.stopped = isCancelled
                    return result
                }
                state.current = pageURL.absoluteString
                progress(state)
                guard let page = await fetch(pageURL), Self.isHTML(page) else { continue }
                result.pages.append(pageURL)
                state.pagesChecked += 1
                let found = LinkExtractor.links(in: Self.text(of: page), page: page.url)
                for link in LinkExtractor.downloadable(found) {
                    if link.isPage {
                        guard depth < settings.depth, !settings.sameSite || settings.isSameSite(link.url),
                              visited.insert(link.url).inserted else { continue }
                        next.append(link.url)
                    } else if settings.template.wants(link, rules: rules), files.insert(link.url).inserted,
                              result.files.count < settings.maxFiles {
                        result.files.append(link)
                    }
                }
                // Frames are pages too.
                for frame in found where frame.tag == .frame && depth < settings.depth
                    && (!settings.sameSite || settings.isSameSite(frame.url)) && visited.insert(frame.url).inserted {
                    next.append(frame.url)
                }
                state.filesFound = result.files.count
                progress(state)
            }
            level = next
            if level.isEmpty { break }
        }
        return result
    }

    /// Saves the site for offline reading into `folder`: pages (links rewritten), and the pictures, styles,
    /// scripts and files they use. `save` writes one download to a file and returns its type, or nil if it failed.
    func mirror(into folder: URL, save: @escaping @Sendable (URL, URL) async -> String?,
                progress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Result {
        var result = Result()
        var state = Progress()
        let home = settings.start
        var visited: Set<URL> = [LinkExtractor.withoutFragment(home)]
        var pagesToWrite: [(url: URL, path: String, html: String)] = []
        var resources: [URL] = []
        var resourceSet = Set<URL>()
        var level: [URL] = [home]

        func addResource(_ url: URL) {
            guard !settings.sameSite || settings.isSameSite(url), resourceSet.insert(url).inserted,
                  resources.count < settings.maxFiles else { return }
            resources.append(url)
        }

        for depth in 0...max(0, settings.depth) {
            var next: [URL] = []
            for pageURL in level {
                if isCancelled || pagesToWrite.count >= settings.maxPages { break }
                state.current = pageURL.absoluteString
                progress(state)
                guard let page = await fetch(pageURL) else { continue }
                guard Self.isHTML(page) else {
                    // A link that looked like a page but is a file.
                    addResource(pageURL)
                    continue
                }
                let html = Self.text(of: page)
                let path = OfflinePaths.path(for: pageURL, isPage: true, home: home)
                pagesToWrite.append((pageURL, path, html))
                result.saved[pageURL] = path
                if page.url != pageURL { result.saved[page.url] = path }
                result.pages.append(pageURL)
                state.pagesChecked += 1
                for item in LinkExtractor.links(in: html, page: page.url) {
                    let link = FoundLink(url: item.url)
                    switch item.tag {
                    case .anchor, .frame:
                        if link.isPage || item.tag == .frame {
                            if depth < settings.depth, settings.isSameSite(item.url), visited.insert(item.url).inserted {
                                next.append(item.url)
                            }
                        } else {
                            addResource(item.url)
                        }
                    case .picture, .video, .sound, .stylesheet, .script:
                        addResource(item.url)
                    }
                }
                progress(state)
            }
            level = next
            if level.isEmpty || isCancelled { break }
        }

        // Files, then the pictures and fonts stylesheets use.
        var index = 0
        while index < resources.count, !isCancelled {
            let url = resources[index]
            index += 1
            let path = OfflinePaths.path(for: url, isPage: false, home: home)
            let destination = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            state.current = url.absoluteString
            progress(state)
            guard let type = await save(url, destination) else { continue }
            result.saved[url] = path
            state.saved += 1
            if type.lowercased().contains("css") || url.pathExtension.lowercased() == "css",
               let css = try? String(contentsOf: destination, encoding: .utf8) {
                for inner in LinkExtractor.cssLinks(in: css, base: url) { addResource(inner) }
            }
            progress(state)
        }
        // Stylesheets point at their pictures' copies too.
        for (url, path) in result.saved where url.pathExtension.lowercased() == "css" {
            let file = folder.appendingPathComponent(path)
            if let css = try? String(contentsOf: file, encoding: .utf8) {
                try? OfflinePaths.rewriteCSS(css, base: url, path: path, saved: result.saved).write(to: file, atomically: true, encoding: .utf8)
            }
        }
        for page in pagesToWrite {
            let file = folder.appendingPathComponent(page.path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let html = OfflinePaths.rewrite(html: page.html, page: page.url, savedAt: page.path, saved: result.saved)
            try? html.write(to: file, atomically: true, encoding: .utf8)
            state.saved += 1
        }
        progress(state)
        result.startFile = result.saved[home] ?? pagesToWrite.first?.path
        result.stopped = isCancelled
        return result
    }
}
