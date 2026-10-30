import AppKit

/// Toolbelt's entries in the Services menu, which also appear when you right-click
/// files or selected text (in Finder under Quick Actions / Services).
/// Each method name matches an NSMessage entry under NSServices in Info.plist.
@MainActor
final class ServicesProvider: NSObject {
    private weak var modules: ModuleManager?

    init(modules: ModuleManager) {
        self.modules = modules
    }

    private var shelf: ShelfModule? { modules?.module(.shelf) as? ShelfModule }
    private var downloads: DownloadsModule? { modules?.module(.downloads) as? DownloadsModule }
    private var snippets: SnippetsModule? { modules?.module(.snippets) as? SnippetsModule }
    private var clipboard: ClipboardModule? { modules?.module(.clipboard) as? ClipboardModule }

    /// "Add to Toolbelt Shelf": files or text go onto a new shelf.
    @objc func addToShelf(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let shelf else { return fail("The Shelf module is turned off.", error) }
        let id = shelf.newShelf()
        if shelf.store.add(from: pasteboard, to: id) == 0 {
            fail("There was nothing Toolbelt could put on a shelf.", error)
        }
    }

    /// "Download with Toolbelt": a selected link starts downloading.
    @objc func downloadLink(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let downloads else { return fail("The Downloads module is turned off.", error) }
        let text = pasteboard.string(forType: .string)
            ?? (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString ?? ""
        if downloads.manager.add(text) == nil {
            fail("The selection isn't a web or FTP link.", error)
        } else {
            downloads.open()
        }
    }

    /// "Save as Toolbelt Snippet": selected text becomes a new snippet, then Settings opens to name it.
    @objc func saveSnippet(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let snippets else { return fail("The Snippets module is turned off.", error) }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return fail("No text was selected.", error)
        }
        let name = String(text.split(whereSeparator: \.isNewline).first?.prefix(40) ?? "New snippet")
        snippets.store.snippets.append(Snippet(keyword: ";", name: name, text: text))
        snippets.open()
    }

    /// "Pin in Toolbelt Clipboard": selected text or files are saved and pinned in the history.
    @objc func pinInClipboard(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let clipboard else { return fail("The Clipboard module is turned off.", error) }
        if !clipboard.pin(from: pasteboard) {
            fail("There was nothing Toolbelt could keep.", error)
        }
    }

    private func fail(_ message: String, _ error: AutoreleasingUnsafeMutablePointer<NSString>) {
        error.pointee = message as NSString
    }
}
