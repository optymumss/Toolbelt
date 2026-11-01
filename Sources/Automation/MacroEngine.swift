import AppKit

/// Runs a macro's steps one after another. Variables are written %Name% in any text; a few are
/// built in: %Clipboard% (reading and setting it uses the real clipboard), %FrontApp%, %Date%,
/// %Time% and %Trigger% (what started the macro, such as the file that was added).
@MainActor
final class MacroRun {
    private(set) var variables: [String: String] = [:]
    let runner: ActionRunner
    /// Asks for text or a choice; the tests answer instead of a person.
    var ask: (_ prompt: String, _ options: [String]?) -> String? = MacroRun.askPerson
    var notify: (_ title: String, _ message: String) -> Void = MacroRun.postNotification
    /// An alert with buttons: gives back the button clicked.
    var alert: (_ message: String, _ buttons: [String]) -> String = MacroRun.showAlert
    /// Choosing a folder (true) or a file: its path, or nil if cancelled.
    var choosePath: (_ prompt: String, _ folder: Bool) -> String? = MacroRun.askForPath
    /// Several questions in one window: the answers in order, or nil if cancelled.
    var askMany: (_ prompt: String, _ fields: [String]) -> [String]? = MacroRun.askSeveral
    /// What conditions ask about the Mac; the tests give their own answers.
    var world: ConditionWorld = .live
    /// How often "Pause until" looks again (screen tests look less often: each look takes a screenshot).
    var pauseCheckEvery: Double = 0.25
    private var stopped = false
    /// Every step that ran, in order (switched-off steps are skipped), and the ones that failed.
    private(set) var log: [String] = []
    private(set) var failures: [String] = []
    /// Loops can't run forever by mistake.
    static let loopLimit = 1000

    init(runner: ActionRunner, trigger: String = "") {
        self.runner = runner
        variables["Trigger"] = trigger
    }

    // MARK: Variables

    func value(of name: String) -> String {
        switch name.lowercased() {
        case "clipboard": return NSPasteboard.general.string(forType: .string) ?? ""
        case "frontapp": return NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        case "date": return Date().formatted(date: .abbreviated, time: .omitted)
        case "time": return Date().formatted(date: .omitted, time: .shortened)
        default: return variables[name] ?? ""
        }
    }

    func set(_ name: String, _ value: String) {
        if name.lowercased() == "clipboard" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } else {
            variables[name] = value
        }
    }

    /// Fills in %Name% with the variable's value. %% is a plain percent sign.
    func expand(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: "%") {
            result += rest[..<start]
            let after = rest.index(after: start)
            guard let end = rest[after...].firstIndex(of: "%") else {
                result += rest[start...]
                return result
            }
            let name = String(rest[after..<end])
            if name.isEmpty {
                result += "%"
            } else if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                result += value(of: name)
            } else {
                // Not a variable (for example "50% off, 20% more"): keep the text as it is.
                result += rest[start..<end]
                rest = rest[end...]
                continue
            }
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    // MARK: Running

    func run(_ steps: [MacroStep]) async {
        for step in steps where step.isOn {
            if stopped { return }
            log.append(step.summary)
            if log.count > 500 { log.removeFirst() }
            await run(step)
        }
    }

    private func run(_ step: MacroStep) async {
        switch step.kind {
        case .action:
            var action = step.action
            action.value = expand(action.value)
            action.value2 = action.value2.map(expand)
            if MoreMacroActions.kinds.contains(action.kind) {
                // Waited for, so the next step starts after it (a page has opened, a file is there…).
                if !(await MoreMacroActions.perform(action)) { failed(step, "it didn't work") }
            } else if action.kind == .mouse, MouseCommand(text: action.value).origin != .screen {
                if !(await MouseDriver.run(MouseCommand(text: action.value), flags: ActionRunner.flags(fromCarbon: action.modifiers))) {
                    failed(step, "the window or picture wasn't found")
                }
            } else {
                runner.run(action)
            }
        case .script:
            let tool: String
            let arguments: [String]
            switch step.action.kind {
            case .appleScript: (tool, arguments) = ("/usr/bin/osascript", ["-e", step.action.value])
            case .javaScript: (tool, arguments) = ("/usr/bin/osascript", ["-l", "JavaScript", "-e", step.action.value])
            default: (tool, arguments) = ("/bin/zsh", ["-c", step.action.value])
            }
            // Variables are passed to scripts as TB_Name environment variables.
            var environment: [String: String] = [:]
            for (name, value) in variables { environment["TB_" + name] = value }
            environment["TB_Clipboard"] = value(of: "Clipboard")
            let result = await Self.runProcess(tool, arguments, environment: environment, timeout: step.timeout)
            if !step.name.isEmpty { set(step.name, result.output) }
            if result.timedOut {
                failed(step, "it took longer than \(Self.seconds(step.timeout ?? 0))")
            } else if result.status != 0 {
                failed(step, "it ended with error \(result.status)")
            }
        case .pause:
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(step.number, 3600)) * 1_000_000_000))
        case .setVariable:
            set(step.name, expand(step.text))
        case .setClipboard:
            set("Clipboard", expand(step.text))
        case .textFilter:
            let name = step.name.isEmpty ? "Clipboard" : step.name
            let result = step.filter.apply(value(of: name), find: expand(step.text), replace: expand(step.text2))
            if step.filter.rawValue.hasPrefix("count"), !step.text2.isEmpty {
                set(step.text2, result) // counts can go into another variable
            } else if step.filter == .removeFormatting, name.lowercased() == "clipboard" {
                set(name, value(of: name)) // writing it back as plain text drops the formatting
            } else {
                set(name, result)
            }
        case .askInput:
            guard let answer = ask(expand(step.text), nil) else { stopped = true; return }
            set(step.name, answer)
        case .pickFromList:
            let options = expand(step.text2).components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard let choice = ask(expand(step.text), options) else { stopped = true; return }
            set(step.name, choice)
        case .notify:
            notify(expand(step.text2.isEmpty ? "Toolbelt" : step.text2), expand(step.text))
        case .ifThen:
            let yes = await isTrue(step.condition)
            await run(yes ? step.steps : step.elseSteps)
        case .repeatTimes:
            for index in 0..<min(Int(step.number), Self.loopLimit) {
                if stopped { return }
                variables["Index"] = String(index + 1)
                await run(step.steps)
            }
        case .repeatWhile:
            // Each loop counts from the start, whatever an earlier loop left in %Index%.
            variables["Index"] = "0"
            var count = 0
            while count < Self.loopLimit, !stopped, await isTrue(step.condition) {
                count += 1
                variables["Index"] = String(count)
                await run(step.steps)
            }
        case .stop:
            stopped = true
        case .readFile:
            let path = (expand(step.text) as NSString).expandingTildeInPath
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                set(step.name, text)
            } else {
                failed(step, "the file couldn't be read")
            }
        case .browserGet:
            let part = BrowserPart(rawValue: step.text2) ?? .url
            let script = BrowserScript.run(js: part.javaScript(expand(step.text)), in: BrowserScript.current(nil))
            let result = await Self.runProcess("/usr/bin/osascript", ["-e", script], environment: [:], timeout: 30)
            set(step.name, result.output)
            if result.status != 0 { failed(step, "the browser didn't answer (is “Allow JavaScript from Apple Events” on?)") }
        case .alert:
            let buttons = Self.fields(expand(step.text2))
            set(step.name, alert(expand(step.text), buttons.isEmpty ? ["OK"] : buttons))
        case .askFolder, .askFile:
            guard let path = choosePath(expand(step.text), step.kind == .askFolder) else { stopped = true; return }
            set(step.name, path)
        case .askSeveral:
            let fields = Self.fields(step.text2)
            guard let answers = askMany(expand(step.text), fields) else { stopped = true; return }
            for (field, answer) in zip(fields, answers) { set(Self.variableName(for: field), answer) }
        case .pauseUntil:
            let limit = step.timeout ?? 60
            let start = Date()
            let every = step.condition.test.readsScreen ? max(1, pauseCheckEvery) : pauseCheckEvery
            while !stopped, !(await isTrue(step.condition)) {
                if Date().timeIntervalSince(start) >= limit {
                    failed(step, "it waited \(Self.seconds(limit)) and it didn't happen")
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
        }
    }

    /// A step failed: carry on, stop, or stop and say so, as the step asks.
    private func failed(_ step: MacroStep, _ reason: String) {
        failures.append("\(step.summary): \(reason)")
        switch step.onFailure ?? .carryOn {
        case .carryOn: break
        case .stop: stopped = true
        case .stopAndNotify:
            stopped = true
            notify("Macro stopped", "“\(step.summary)” failed: \(reason).")
        }
    }

    /// One per line, blank lines left out.
    nonisolated static func fields(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A question's variable: "Meeting time" → Meeting_time.
    nonisolated static func variableName(for field: String) -> String {
        let cleaned = String(field.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_")).isEmpty ? "Answer" : cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func seconds(_ value: Double) -> String { value == 1 ? "1 second" : "\(value.formatted()) seconds" }

    /// Runs a script in the background; gives up after `timeout` seconds (nil: no limit).
    nonisolated static func runProcess(_ tool: String, _ arguments: [String], environment extra: [String: String],
                                       timeout: Double?) async -> (output: String, status: Int32, timedOut: Bool) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["TOOLBELT_DATA_DIR"] = SettingsStore.folder.path
            for (key, value) in extra { environment[key] = value }
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            final class Flag: @unchecked Sendable { var timedOut = false }
            let flag = Flag()
            process.terminationHandler = { finished in
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (text.trimmingCharacters(in: .whitespacesAndNewlines), finished.terminationStatus, flag.timedOut))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("", -1, false))
                return
            }
            if let timeout, timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    flag.timedOut = true
                    process.terminate()
                }
            }
        }
    }

    func isTrue(_ condition: MacroCondition) async -> Bool {
        await condition.isTrue(left: expand(condition.left), right: expand(condition.right), world: world)
    }

    // MARK: Asking and telling

    /// A small window asking for text, or offering a list to pick from. nil if cancelled (which stops the macro).
    static func askPerson(_ prompt: String, _ options: [String]?) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = prompt.isEmpty ? "Toolbelt" : prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let options {
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            popup.addItems(withTitles: options)
            alert.accessoryView = popup
            return alert.runModal() == .alertFirstButtonReturn ? popup.titleOfSelectedItem : nil
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return Self.run(alert, focusing: field) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func showAlert(_ message: String, _ buttons: [String]) -> String {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message.isEmpty ? "Toolbelt" : message
        for button in buttons { alert.addButton(withTitle: button) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(index) ? buttons[index] : (buttons.first ?? "OK")
    }

    /// Runs an alert with the cursor in `field`: the alert chooses its own first responder whenever its window
    /// becomes key (as it opens, and again when you switch to it), so it's put back each time.
    private static func run(_ alert: NSAlert, focusing field: NSTextField) -> NSApplication.ModalResponse {
        // Laid out first, so the box is in the window and can be its starting point.
        alert.layout()
        let window = alert.window
        window.initialFirstResponder = field
        // Moved there a moment after AppKit's own changes (as it opens, and whenever it becomes key again).
        let focusSoon = {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                MainActor.assumeIsolated { _ = window.makeFirstResponder(field) }
            }
            RunLoop.current.add(timer, forMode: .modalPanel)
        }
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { _ in
            focusSoon()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        focusSoon()
        return alert.runModal()
    }

    static func askForPath(_ prompt: String, _ folder: Bool) -> String? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.canCreateDirectories = folder
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func askSeveral(_ prompt: String, _ fields: [String]) -> [String]? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = prompt.isEmpty ? "Toolbelt" : prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let boxes = fields.map { _ in NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)) }
        let grid = NSGridView(views: zip(fields, boxes).map { [NSTextField(labelWithString: $0 + ":"), $1] as [NSView] })
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        for (box, next) in zip(boxes, boxes.dropFirst()) { box.nextKeyView = next }
        alert.window.initialFirstResponder = boxes.first
        // The alert picks its own first responder as it opens: put the cursor in the first box once it's showing.
        guard let first = boxes.first else { return alert.runModal() == .alertFirstButtonReturn ? [] : nil }
        return Self.run(alert, focusing: first) == .alertFirstButtonReturn ? boxes.map(\.stringValue) : nil
    }

    static func postNotification(_ title: String, _ message: String) {
        // Notifications need the installed app; elsewhere (tests) they're written to the log.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSLog("Toolbelt notification: \(title): \(message)")
            return
        }
        DownloadNotifier.post(id: UUID().uuidString, title: title, body: message, path: nil)
    }
}
