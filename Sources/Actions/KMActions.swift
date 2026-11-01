import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import UniformTypeIdentifiers

// Actions added in 0.31, like Keyboard Maestro's: apps, windows, files, the browser, downloads, speech,
// sounds, large text, the exact volume, the desktop picture and the keyboard layout.
// MacroAction keeps `value` for the main text; `option` names what to do (for example which app
// command) and `value2` holds a second text (a destination, the browser, a voice).
// The parts that decide things are plain logic (tested in Tests.swift); `MoreMacroActions.perform`
// does them, and reports whether it worked so a macro can treat a failure as one.

enum AppCommand: String, CaseIterable, Identifiable {
    case activateLast, quit, hide, hideOthers, showAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activateLast: return "Switch back to the app used before"
        case .quit: return "Quit an app"
        case .hide: return "Hide an app"
        case .hideOthers: return "Hide every other app"
        case .showAll: return "Show all hidden apps"
        }
    }

    var needsApp: Bool { self == .quit || self == .hide }
}

enum WindowCommand: String, CaseIterable, Identifiable {
    case setFrame, minimize, closeAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setFrame: return "Move and resize the front window to…"
        case .minimize: return "Minimise the front window"
        case .closeAll: return "Close all the front app's windows"
        }
    }
}

enum FileCommand: String, CaseIterable, Identifiable {
    case copy, move, rename, trash, write, append

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return "Copy a file into a folder"
        case .move: return "Move a file into a folder"
        case .rename: return "Rename a file"
        case .trash: return "Move a file to the Trash"
        case .write: return "Write text to a file (replacing it)"
        case .append: return "Add text to the end of a file"
        }
    }

    var secondField: String? {
        switch self {
        case .copy, .move: return "Into folder"
        case .rename: return "New name"
        case .write, .append: return "Text (variables: %Name%)"
        case .trash: return nil
        }
    }
}

enum BrowserCommand: String, CaseIterable, Identifiable {
    case openTab, clickLink, fillField, clickButton, runJS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openTab: return "Open a web address in a new tab"
        case .clickLink: return "Click a link (by its text)"
        case .fillField: return "Fill in a form field"
        case .clickButton: return "Click a button (by its text)"
        case .runJS: return "Run JavaScript in the page"
        }
    }

    var placeholder: String {
        switch self {
        case .openTab: return "https://…"
        case .clickLink: return "Link text, e.g. Sign in"
        case .fillField: return "field=value, e.g. email=me@example.com (field: its name, id, label or placeholder)"
        case .clickButton: return "Button text, e.g. Submit"
        case .runJS: return "document.title"
        }
    }
}

// MARK: - The browser

/// Talks to Safari or a Chrome-like browser with AppleScript. Running JavaScript needs the browser's own
/// switch: Safari → Settings → Advanced → "Show features for web developers", then Develop → "Allow
/// JavaScript from Apple Events"; Chrome → View → Developer → "Allow JavaScript from Apple Events".
enum BrowserScript {
    static let chromeLike = ["Google Chrome", "Brave Browser", "Microsoft Edge", "Vivaldi", "Chromium"]
    static let known = ["Safari"] + chromeLike

    /// The browser to use: the one named, else the one in front, else the first one running, else Safari.
    static func browser(named name: String?, front: String?, running: [String]) -> String {
        if let name, !name.isEmpty { return name }
        if let front, known.contains(front) { return front }
        return known.first { running.contains($0) } ?? "Safari"
    }

    /// Text inside an AppleScript string.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Text inside a JavaScript string.
    static func jsQuoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    /// Runs `js` in the front tab and gives back its result.
    static func run(js: String, in browser: String) -> String {
        if chromeLike.contains(browser) {
            return "tell application \(quoted(browser)) to execute active tab of front window javascript \(quoted(js))"
        }
        return "tell application \(quoted(browser)) to do JavaScript \(quoted(js)) in current tab of front window"
    }

    static func openTab(_ url: String, in browser: String) -> String {
        if chromeLike.contains(browser) {
            return """
            tell application \(quoted(browser))
                activate
                if (count of windows) = 0 then make new window
                tell front window to make new tab with properties {URL:\(quoted(url))}
            end tell
            """
        }
        return """
        tell application \(quoted(browser))
            activate
            if (count of windows) = 0 then make new document
            tell front window to set current tab to (make new tab with properties {URL:\(quoted(url))})
        end tell
        """
    }

    /// The JavaScript for a command; nil for opening a tab (that's AppleScript only).
    static func javaScript(_ command: BrowserCommand, _ value: String) -> String? {
        switch command {
        case .openTab: return nil
        case .runJS: return value
        case .clickLink:
            return """
            (function(){var t=\(jsQuoted(value.lowercased()));var a=Array.from(document.querySelectorAll('a')).find(function(e){return (e.textContent||'').trim().toLowerCase().indexOf(t)>=0;});if(!a)return 'not found';a.click();return 'clicked';})()
            """
        case .clickButton:
            return """
            (function(){var t=\(jsQuoted(value.lowercased()));var b=Array.from(document.querySelectorAll('button,input[type=submit],input[type=button],[role=button]')).find(function(e){return ((e.textContent||'')+' '+(e.value||'')).trim().toLowerCase().indexOf(t)>=0;});if(!b)return 'not found';b.click();return 'clicked';})()
            """
        case .fillField:
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            let field = parts.first ?? "", text = parts.count > 1 ? parts[1] : ""
            return """
            (function(){var n=\(jsQuoted(field));var v=\(jsQuoted(text));var l=n.toLowerCase();var f=document.getElementsByName(n)[0]||document.getElementById(n)||Array.from(document.querySelectorAll('input,textarea,select')).find(function(e){var lab=e.labels&&e.labels[0]?e.labels[0].textContent:'';return (e.placeholder||'').toLowerCase().indexOf(l)>=0||lab.trim().toLowerCase().indexOf(l)>=0;});if(!f)return 'not found';f.focus();f.value=v;f.dispatchEvent(new Event('input',{bubbles:true}));f.dispatchEvent(new Event('change',{bubbles:true}));return 'filled';})()
            """
        }
    }

    @MainActor static func current(_ name: String?) -> String {
        browser(named: name, front: NSWorkspace.shared.frontmostApplication?.localizedName,
                running: NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
    }
}

// MARK: - Apps

/// Remembers the app used before the one in front, for "Switch back to the app used before".
@MainActor
final class AppHistory {
    static let shared = AppHistory()
    private(set) var previous: NSRunningApplication?
    private var current: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        current = NSWorkspace.shared.frontmostApplication
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { AppHistory.shared.activated(app) }
        }
    }

    func activated(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier, app != current else { return }
        previous = current
        current = app
    }
}

enum AppMatch {
    /// Running apps matching a name or bundle ID (empty: the app in front).
    @MainActor static func running(_ wanted: String) -> [NSRunningApplication] {
        if wanted.isEmpty { return NSWorkspace.shared.frontmostApplication.map { [$0] } ?? [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            [app.bundleIdentifier, app.localizedName].compactMap { $0 }.contains { MacroCondition.sameApp($0, wanted) }
        }
    }
}

// MARK: - Windows

enum WindowFrame {
    /// "x,y,w,h" in points from the top left of the main screen.
    static func parse(_ text: String) -> CGRect? {
        let numbers = text.split { $0 == "," || $0 == " " }.compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point) // swiftlint:disable:this force_cast
        return point
    }

    static func set(_ window: AXUIElement, frame: CGRect) {
        var origin = frame.origin, size = frame.size
        if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
        if let sizeValue = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
        // Some apps only take the size once the window has moved: set both again.
        if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}

// MARK: - Files

enum FileActions {
    static func path(_ text: String) -> URL { URL(fileURLWithPath: (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath) }

    /// A free name in `folder` for `name`: "report.pdf", then "report 2.pdf", "report 3.pdf"…
    static func freeURL(for name: String, in folder: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 2
        while exists(candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Does it; returns false if it couldn't (no such file, no permission…).
    static func perform(_ command: FileCommand, path: String, second: String) -> Bool {
        let manager = FileManager.default
        let source = self.path(path)
        do {
            switch command {
            case .copy, .move:
                let folder = self.path(second)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = freeURL(for: source.lastPathComponent, in: folder)
                if command == .copy { try manager.copyItem(at: source, to: target) } else { try manager.moveItem(at: source, to: target) }
            case .rename:
                let name = second.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains("/") else { return false }
                try manager.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent(name))
            case .trash:
                try manager.trashItem(at: source, resultingItemURL: nil)
            case .write:
                try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(second.utf8).write(to: source, options: .atomic)
            case .append:
                if !manager.fileExists(atPath: source.path) { return perform(.write, path: path, second: second) }
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(second.utf8))
            }
            return true
        } catch {
            NSLog("Toolbelt: \(command.rawValue) \(path) didn't work: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Keyboard layouts

enum KeyboardLayouts {
    /// The best match for `wanted` among layout names: the same name, else one containing it.
    static func best(_ wanted: String, in names: [String]) -> String? {
        let text = wanted.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return names.first { $0.localizedCaseInsensitiveCompare(text) == .orderedSame }
            ?? names.first { $0.localizedCaseInsensitiveContains(text) }
    }

    private static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    static func name(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// The keyboard layouts you've added in System Settings → Keyboard → Text Input.
    static var names: [String] { sources().map(name) }

    static var currentName: String {
        TISCopyCurrentKeyboardInputSource().map { name($0.takeRetainedValue()) } ?? ""
    }

    static func select(_ wanted: String) -> Bool {
        let all = sources()
        guard let match = best(wanted, in: all.map(name)), let source = all.first(where: { name($0) == match }) else { return false }
        return TISSelectInputSource(source) == noErr
    }
}

// MARK: - Sounds

enum SystemSounds {
    static let folder = URL(fileURLWithPath: "/System/Library/Sounds")

    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    /// A sound's file: a path, or the name of one of macOS's sounds ("Glass").
    static func url(for value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains("/") { return FileActions.path(text) }
        return folder.appendingPathComponent(text + ".aiff")
    }
}

// MARK: - Large text

/// Text shown big in the middle of the screen until you click it or press a key.
@MainActor
enum LargeText {
    private static var panel: NSPanel?
    private static var monitors: [Any] = []

    static func show(_ text: String) {
        hide()
        guard let screen = NSScreen.main else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: min(120, max(36, 1400 / CGFloat(max(8, text.count)))), weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.preferredMaxLayoutWidth = screen.frame.width * 0.8
        let size = label.fittingSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2 - 40, y: screen.frame.midY - size.height / 2 - 30,
                           width: size.width + 80, height: size.height + 60)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = "Toolbelt large text"
        let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 24
        label.frame = NSRect(x: 40, y: 30, width: size.width, height: size.height)
        box.addSubview(label)
        window.contentView = box
        window.orderFrontRegardless()
        panel = window
        let close: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { hide() } }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: { event in close(event); return event }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: close) { monitors.append(global) }
        // Never left up for ever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak window] in
            MainActor.assumeIsolated { if let window, panel === window { hide() } }
        }
    }

    static func hide() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }

    static var isShowing: Bool { panel != nil }
}

// MARK: - Doing them

enum MoreMacroActions {
    static let kinds: Set<MacroAction.Kind> = [.app, .window, .file, .browser, .download, .speak, .playSound, .largeText,
                                               .setVolume, .desktopPicture, .keyboardLayout]

    /// Restart, shut down and log out show macOS's own "Are you sure?" window.
    static func loginWindowScript(_ control: SystemControl) -> String? {
        switch control {
        case .restart: return "tell application \"loginwindow\" to «event aevtrrst»"
        case .shutDown: return "tell application \"loginwindow\" to «event aevtrsdn»"
        case .logOut: return "tell application \"loginwindow\" to «event aevtlogo»"
        default: return nil
        }
    }

    /// The volume to set, 0–100, from text like "40" or "40%".
    static func volume(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: CharacterSet(charactersIn: " %"))).map { max(0, min(100, $0)) }
    }

    /// Does the action; false if it didn't work (a macro can stop on that).
    @MainActor static func perform(_ action: MacroAction) async -> Bool {
        let second = action.value2 ?? ""
        switch action.kind {
        case .app:
            switch AppCommand(rawValue: action.option ?? "") ?? .activateLast {
            case .activateLast:
                guard let previous = AppHistory.shared.previous, !previous.isTerminated else { return false }
                return previous.activate()
            case .quit:
                let apps = AppMatch.running(action.value)
                apps.forEach { $0.terminate() }
                return !apps.isEmpty
            case .hide:
                let apps = AppMatch.running(action.value)
                apps.forEach { $0.hide() }
                return !apps.isEmpty
            case .hideOthers:
                let front = NSWorkspace.shared.frontmostApplication
                for app in NSWorkspace.shared.runningApplications where app != front && app.activationPolicy == .regular { app.hide() }
                return true
            case .showAll:
                for app in NSWorkspace.shared.runningApplications where app.isHidden { app.unhide() }
                return true
            }
        case .window:
            guard PermissionGate.ensure(.accessibility, to: "move and close windows"),
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
            switch WindowCommand(rawValue: action.option ?? "") ?? .setFrame {
            case .setFrame:
                guard let frame = WindowFrame.parse(action.value), let window = FrontWindow.focusedWindow(of: pid) else { return false }
                WindowFrame.set(window, frame: frame)
            case .minimize:
                guard let window = FrontWindow.focusedWindow(of: pid) else { return false }
                return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
            case .closeAll:
                for window in WindowFrame.windows(of: pid) {
                    var button: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
                        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) // swiftlint:disable:this force_cast
                    }
                }
            }
            return true
        case .file:
            let command = FileCommand(rawValue: action.option ?? "") ?? .copy
            return await Task.detached { FileActions.perform(command, path: action.value, second: second) }.value
        case .browser:
            let browser = BrowserScript.current(second)
            let command = BrowserCommand(rawValue: action.option ?? "") ?? .openTab
            let script = BrowserScript.javaScript(command, action.value).map { BrowserScript.run(js: $0, in: browser) }
                ?? BrowserScript.openTab(action.value, in: browser)
            let result = await MacroRun.runProcess("/usr/bin/osascript", ["-e", script], environment: [:], timeout: 30)
            return result.status == 0 && result.output != "not found"
        case .download:
            return await Downloader.download(action.value, into: second).map { _ in true } ?? false
        case .speak:
            let arguments = (second.isEmpty ? [] : ["-v", second]) + [action.value]
            return await MacroRun.runProcess("/usr/bin/say", arguments, environment: [:], timeout: 600).status == 0
        case .playSound:
            guard let url = SystemSounds.url(for: action.value), let sound = NSSound(contentsOf: url, byReference: true) else { return false }
            return sound.play()
        case .largeText:
            LargeText.show(action.value)
            return true
        case .setVolume:
            guard let level = volume(action.value) else { return false }
            return await MacroRun.runProcess("/usr/bin/osascript", ["-e", "set volume output volume \(level)"], environment: [:], timeout: 10).status == 0
        case .desktopPicture:
            let url = FileActions.path(action.value)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            for screen in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
            return true
        case .keyboardLayout:
            return KeyboardLayouts.select(action.value)
        default:
            return false
        }
    }
}

/// Downloads one file into a folder (for the "Download a file" action; the Downloads module is for big ones).
enum Downloader {
    static func download(_ address: String, into folderText: String) async -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return nil }
        let folder = folderText.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads") : FileActions.path(folderText)
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = response.suggestedFilename ?? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
            let target = FileActions.freeURL(for: name, in: folder)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        } catch {
            NSLog("Toolbelt: download of \(address) didn't work: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Choosing them in Settings

struct MoreActionFields: View {
    @Binding var action: MacroAction

    private var option: Binding<String> { Binding(get: { action.option ?? "" }, set: { action.option = $0 }) }
    private var second: Binding<String> { Binding(get: { action.value2 ?? "" }, set: { action.value2 = $0.isEmpty ? nil : $0 }) }

    var body: some View {
        switch action.kind {
        case .app:
            Picker("What", selection: option) { ForEach(AppCommand.allCases) { Text($0.title).tag($0.rawValue) } }
            if AppCommand(rawValue: action.option ?? "")?.needsApp == true {
                TextField("App name (empty: the app in front)", text: $action.value)
            }
        case .window:
            Picker("What", selection: option) { ForEach(WindowCommand.allCases) { Text($0.title).tag($0.rawValue) } }
            if (WindowCommand(rawValue: action.option ?? "") ?? .setFrame) == .setFrame {
                TextField("x, y, width, height (points from the top left), e.g. 0,25,960,1000", text: $action.value)
            }
            Text("Needs Accessibility.").font(.caption).foregroundStyle(.secondary)
        case .file:
            let command = FileCommand(rawValue: action.option ?? "") ?? .copy
            Picker("What", selection: option) { ForEach(FileCommand.allCases) { Text($0.title).tag($0.rawValue) } }
            TextField("File, e.g. ~/Desktop/report.pdf or %Trigger%", text: $action.value)
            if let label = command.secondField { TextField(label, text: second) }
        case .browser:
            let command = BrowserCommand(rawValue: action.option ?? "") ?? .openTab
            Picker("What", selection: option) { ForEach(BrowserCommand.allCases) { Text($0.title).tag($0.rawValue) } }
            TextField(command.placeholder, text: $action.value)
            Picker("Browser", selection: second) {
                Text("The one in front (or open)").tag("")
                ForEach(BrowserScript.known, id: \.self) { Text($0).tag($0) }
            }
            Text("Clicking, filling in and JavaScript need the browser's “Allow JavaScript from Apple Events” (Safari: Develop menu; Chrome: View → Developer). macOS asks once to let Toolbelt control the browser.")
                .font(.caption).foregroundStyle(.secondary)
        case .download:
            TextField("Web address of the file", text: $action.value)
            TextField("Into folder (empty: Downloads)", text: second)
        case .speak:
            TextField("Text to say (variables: %Name%)", text: $action.value)
            TextField("Voice (empty: the Mac's own)", text: second)
        case .playSound:
            Picker("Sound", selection: $action.value) {
                Text("Choose…").tag("")
                ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
            }
        case .largeText:
            TextField("Text (variables: %Name%)", text: $action.value)
            Text("Shown big in the middle of the screen until you click or press a key.").font(.caption).foregroundStyle(.secondary)
        case .setVolume:
            Stepper("Volume \(MoreMacroActions.volume(action.value) ?? 50)%",
                    value: Binding(get: { MoreMacroActions.volume(action.value) ?? 50 }, set: { action.value = String($0) }), in: 0...100, step: 5)
        case .desktopPicture:
            HStack {
                TextField("Picture file", text: $action.value)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    NSApp.activate()
                    if panel.runModal() == .OK, let url = panel.url { action.value = url.path }
                }
            }
        case .keyboardLayout:
            Picker("Layout", selection: $action.value) {
                Text("Choose…").tag("")
                ForEach(KeyboardLayouts.names, id: \.self) { Text($0).tag($0) }
            }
        default:
            EmptyView()
        }
    }
}

/// What "Get the page's …" reads.
enum BrowserPart: String, CaseIterable, Identifiable {
    case url, title, selection, text, js

    var id: String { rawValue }

    var title: String {
        switch self {
        case .url: return "address"
        case .title: return "title"
        case .selection: return "selected text"
        case .text: return "text"
        case .js: return "JavaScript result"
        }
    }

    func javaScript(_ custom: String) -> String {
        switch self {
        case .url: return "location.href"
        case .title: return "document.title"
        case .selection: return "String(window.getSelection())"
        case .text: return "document.body.innerText"
        case .js: return custom
        }
    }
}
