import AppKit
import Carbon

/// Puts a history item back on the clipboard and, if allowed,
/// presses ⌘V in the app you were using.
@MainActor
final class Paster {
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor

    init(store: ClipboardStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    func paste(_ item: ClipItem, plainText: Bool) {
        write(item, plainText: plainText)
        store.touch(item.id)

        guard Prefs.pasteAfterSelect else { return }
        // Without permission the item is still on the clipboard, ready for ⌘V.
        guard PermissionGate.ensure(.accessibility, to: "paste for you") else { return }

        // Give the history panel a moment to close so the
        // previous app is receiving keystrokes again.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            Paster.pressCommandV()
        }
    }

    func write(_ item: ClipItem, plainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text, .link:
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.text ?? "", forType: .string)
            if !plainText, let rtf = item.rtf {
                pbItem.setData(rtf, forType: .rtf)
            }
            pb.writeObjects([pbItem])

        case .image:
            // PNG plus TIFF, so both modern apps and older ones accept the paste.
            if let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) {
                let pbItem = NSPasteboardItem()
                pbItem.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation {
                    pbItem.setData(tiff, forType: .tiff)
                }
                pb.writeObjects([pbItem])
            }

        case .file:
            let paths = item.filePaths ?? []
            if plainText {
                pb.setString(paths.joined(separator: "\n"), forType: .string)
            } else {
                pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
            }
        }

        monitor.ignoreCurrentContents()
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
