import AppKit
import Carbon

/// Listens to typing everywhere and replaces snippet keywords with their text.
/// Listening needs Input Monitoring; typing the replacement needs Accessibility.
@MainActor
final class SnippetExpander {
    private let store: SnippetStore
    /// What to do when a keyword is typed: the snippet, and how many characters to delete first.
    var onMatch: ((Snippet, Int) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var buffer = TypingBuffer()

    /// Marks the key presses Toolbelt itself sends, so it doesn't read them back.
    static let marker: Int64 = 0x54424C54 // 'TBLT'

    init(store: SnippetStore) {
        self.store = store
    }

    var isRunning: Bool { tap != nil }

    /// Starts listening. Returns false if macOS hasn't allowed Input Monitoring yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: snippetTapCallback, userInfo: me
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        buffer.reset()
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(_ event: CGEvent, type: CGEventType) {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return }
        guard type == .keyDown else {
            buffer.reset() // a click moves the cursor somewhere else
            return
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer.reset()
            return
        }
        switch keyCode {
        case kVK_Delete:
            buffer.deleteBackward()
            return
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            buffer.reset()
            return
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        buffer.type(String(utf16CodeUnits: chars, count: length))

        if let snippet = buffer.match(in: store.snippets) {
            buffer.reset()
            let keywordLength = snippet.keyword.count
            // Let the last key of the keyword reach the app before replacing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                MainActor.assumeIsolated { [weak self] in
                    if let onMatch = self?.onMatch {
                        onMatch(snippet, keywordLength)
                    } else {
                        TextInserter.replace(typed: keywordLength, with: Placeholders.render(snippet.text))
                    }
                }
            }
        }
    }
}

private let snippetTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let expander = Unmanaged<SnippetExpander>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            expander.reenable()
        } else {
            expander.handle(event, type: type)
        }
    }
    return Unmanaged.passUnretained(event)
}

/// Types text into the app in front by pasting it, then puts your clipboard back.
@MainActor
enum TextInserter {
    /// Deletes what was just typed and pastes the replacement.
    static func replace(typed count: Int, with result: Placeholders.Result) {
        guard PermissionGate.ensure(.accessibility, to: "type your snippets") else { return }
        for _ in 0..<count {
            press(CGKeyCode(kVK_Delete))
        }
        paste(result)
    }

    /// Pastes text into the app in front without leaving it in the clipboard history.
    static func paste(_ result: Placeholders.Result) {
        let pb = NSPasteboard.general
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            // Putting your clipboard back isn't a new copy, so the history skips it.
            copy.setString("", forType: transient)
            return copy
        } ?? []

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(result.text, forType: .string)
        // Tells clipboard managers (including Toolbelt's own) not to record this.
        item.setString("", forType: transient)
        pb.writeObjects([item])

        press(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        for _ in 0..<result.cursorFromEnd {
            press(CGKeyCode(kVK_LeftArrow))
        }

        // Give the app time to read the clipboard, then put back what was there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: SnippetExpander.marker)
            event.post(tap: .cghidEventTap)
        }
    }
}
