import AppKit

enum LauncherIcon {
    case image(NSImage)
    case symbol(String)
}

/// One row in the launcher.
struct LauncherResult: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    /// Shown on the right, for example "Application" or "Command".
    var kind: String
    var icon: LauncherIcon
    /// Higher scores are listed first.
    var score: Double
    /// Files and apps can also be shown in Finder with ⌘↩.
    var revealURL: URL? = nil
    let action: @MainActor () -> Void
}

/// Something the launcher can search: apps, commands, a module's own items…
@MainActor
protocol LauncherProvider: AnyObject {
    func results(for query: String) -> [LauncherResult]
}

/// How well a typed query matches a name. 0 means no match; higher is better.
enum FuzzyMatch {
    static func score(_ query: String, _ candidate: String) -> Double {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let c = candidate.lowercased()
        guard !q.isEmpty, !c.isEmpty else { return 0 }

        if c == q { return 100 }
        if c.hasPrefix(q) { return 90 - min(Double(c.count - q.count) * 0.1, 5) }

        let words = c.split(whereSeparator: { " -_.".contains($0) })
        if words.contains(where: { $0.hasPrefix(q) }) { return 75 }

        // "vsc" finds "Visual Studio Code"
        let initials = String(words.compactMap(\.first))
        if q.count >= 2, initials.hasPrefix(q) { return 70 }

        if c.contains(q) { return 55 }

        // Letters in the right order, with gaps: "sfri" finds "Safari"
        guard q.count >= 3 else { return 0 }
        var index = c.startIndex
        for ch in q where ch != " " {
            guard let found = c[index...].firstIndex(of: ch) else { return 0 }
            index = c.index(after: found)
        }
        return 30
    }
}
