import AppKit
import CryptoKit

enum ClipKind: String, Codable {
    case text, link, image, file

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

struct ClipItem: Identifiable, Codable, Equatable {
    static let otherDeviceName = "iPhone or iPad"

    var id = UUID()
    var kind: ClipKind
    var text: String? = nil
    var rtf: Data? = nil
    var imageFile: String? = nil
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
    var filePaths: [String]? = nil
    var hash: String
    var sourceAppName: String? = nil
    var sourceBundleID: String? = nil
    var created = Date()
    var lastUsed = Date()
    var pinned = false
    /// Arrived from an iPhone or iPad through Universal Clipboard.
    var fromOtherDevice: Bool? = nil
    /// Page title that browsers put on the clipboard next to a copied link.
    var linkTitle: String? = nil

    /// One-line label shown in the list.
    var title: String {
        switch kind {
        case .text, .link:
            let raw = text ?? ""
            let line = raw
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? raw
            return String(line.replacingOccurrences(of: "\t", with: " ").prefix(300))
        case .image:
            if let w = imageWidth, let h = imageHeight { return "Image  \(w) × \(h)" }
            return "Image"
        case .file:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            guard let first = names.first else { return "File" }
            return names.count == 1 ? first : "\(first) + \(names.count - 1) more"
        }
    }

    /// Text used for search matching.
    var searchText: String {
        switch kind {
        case .text: return text ?? ""
        case .link: return (text ?? "") + " " + (linkTitle ?? "")
        case .image: return "image picture screenshot " + (sourceAppName ?? "") + " " + (text ?? "")
        case .file: return (filePaths ?? []).joined(separator: " ")
        }
    }
}

enum Hashing {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func of(_ string: String) -> String {
        of(Data(string.utf8))
    }
}
