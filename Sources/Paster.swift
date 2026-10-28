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
        guard Accessibility.isTrusted(prompt: false) else {
            // The item is on the clipboard; ask for permission so next time it pastes itself.
            _ = Accessibility.isTrusted(prompt: true)
            return
        }

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
            if let image = store.image(for: item) {
                pb.writeObjects([image])
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

enum Accessibility {
    /// Accessibility permission is what lets Toolbelt press ⌘V for you.
    static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
