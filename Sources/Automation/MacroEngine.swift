import AppKit

/// Runs a macro's steps one after another. Variables are written %Name% in any text; a few are
/// built in: %Clipboard% (reading and setting it uses the real clipboard), %FrontApp%, %Date%,
/// %Time% and %Trigger% (what started the macro, such as the file that was added).
@MainActor
final class MacroRun {
    private(set) var variables: [String: String] = [:]
    let runner: ActionRunner
    /// Asks for text or a choice; the tests answer instead of a person.
    var ask: (_ prompt: String, _ options: [String]?) async -> String? = MacroRun.askPerson
    var notify: (_ title: String, _ message: String) -> Void = MacroRun.postNotification
    /// An alert with buttons: gives back the button clicked.
    var alert: (_ message: String, _ buttons: [String]) async -> String = MacroRun.showAlert
    /// Choosing a folder (true) or a file: its path, or nil if cancelled.
    var choosePath: (_ prompt: String, _ folder: Bool) async -> String? = MacroRun.askForPath
    /// Several questions in one window: the answers in order, or nil if cancelled.
    var askMany: (_ prompt: String, _ fields: [String]) async -> [String]? = MacroRun.askSeveral
    /// Runs another macro by name with these variables and gives back its %Result% (nil: no such macro).
    var runMacro: (_ name: String, _ inputs: [String: String], _ depth: Int) async -> String? = { _, _, _ in nil }
    /// How many macros deep this run is (a macro running itself stops at 10).
    var depth = 0
    static let depthLimit = 10
    /// What conditions ask about the Mac; the tests give their own answers.
    var world: ConditionWorld = .live
    /// How often "Pause until" looks again (screen tests look less often: each look takes a screenshot).
    var pauseCheckEvery: Double = 0.25
    private var stopped = false
    /// 0.36: "Leave the loop" / "Next round" were reached, and how many loops deep the run is.
    private var breakRequested = false
    private var continueRequested = false
    private var loopDepth = 0
    /// 0.36: inside "Try…": a failing step jumps to the "if a step fails" steps (the reason is kept here).
    private var tryDepth = 0
    private var caught: String?
    /// The rest of the current steps are skipped (stopping, a caught failure, or leaving/skipping a loop round).
    private var interrupted: Bool { stopped || caught != nil || breakRequested || continueRequested }
    /// Things to go through in "For each" (a folder can hold more than a loop's usual limit).
    static let itemLimit = 10_000
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
        case "frontappid": return NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        case "frontwindow": return FrontWindow.title() ?? ""
        case "pointer": return "\(Int(MouseDriver.pointer.x)),\(Int(MouseDriver.pointer.y))"
        case "pointerx": return String(Int(MouseDriver.pointer.x))
        case "pointery": return String(Int(MouseDriver.pointer.y))
        default:
            if GlobalVariables.isGlobal(name) { return GlobalVariables.shared.value(name) }
            return variables[name] ?? ""
        }
    }

    func set(_ name: String, _ value: String) {
        if name.lowercased() == "clipboard" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } else if GlobalVariables.isGlobal(name) {
            // 0.36: Global_ variables are kept between runs and shared by every macro.
            GlobalVariables.shared.set(name, value)
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
            if interrupted { return }
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
            for (name, value) in GlobalVariables.shared.values { environment["TB_" + name] = value }
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
            guard let answer = await ask(expand(step.text), nil) else { stopped = true; return }
            set(step.name, answer)
        case .pickFromList:
            let options = expand(step.text2).components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard let choice = await ask(expand(step.text), options) else { stopped = true; return }
            set(step.name, choice)
        case .notify:
            notify(expand(step.text2.isEmpty ? "Toolbelt" : step.text2), expand(step.text))
        case .ifThen:
            let yes = await isTrue(step.condition)
            await run(yes ? step.steps : step.elseSteps)
        case .repeatTimes:
            loopDepth += 1
            defer { loopDepth -= 1 }
            for index in 0..<min(Int(step.number), Self.loopLimit) {
                variables["Index"] = String(index + 1)
                await run(step.steps)
                if endOfRound() { break }
            }
        case .repeatWhile:
            // Each loop counts from the start, whatever an earlier loop left in %Index%.
            loopDepth += 1
            defer { loopDepth -= 1 }
            variables["Index"] = "0"
            var count = 0
            while count < Self.loopLimit, !interrupted, await isTrue(step.condition) {
                count += 1
                variables["Index"] = String(count)
                await run(step.steps)
                if endOfRound() { break }
            }
        case .forEach:
            let source = step.source ?? .lines
            let items = source.items(in: expand(step.text))
            if source.isFolder, items.isEmpty, !FileManager.default.fileExists(atPath: (expand(step.text) as NSString).expandingTildeInPath) {
                failed(step, "there's no folder “\(expand(step.text))”")
                return
            }
            loopDepth += 1
            defer { loopDepth -= 1 }
            let name = step.name.isEmpty ? "Item" : step.name
            for (index, item) in items.prefix(Self.itemLimit).enumerated() {
                set(name, item)
                variables["Index"] = String(index + 1)
                await run(step.steps)
                if endOfRound() { break }
            }
        case .switchCase:
            let value = expand(step.text)
            if let match = (step.cases ?? []).first(where: { $0.matches(value, value: expand($0.value)) }) {
                await run(match.steps)
            } else {
                await run(step.elseSteps)
            }
        case .breakLoop:
            if loopDepth > 0 { breakRequested = true }
        case .continueLoop:
            if loopDepth > 0 { continueRequested = true }
        case .tryCatch:
            tryDepth += 1
            await run(step.steps)
            tryDepth -= 1
            if let reason = caught {
                caught = nil
                variables["FailureReason"] = reason
                await run(step.elseSteps)
            }
        case .runTogether:
            let children = step.steps.filter(\.isOn)
            if step.number == 0 {
                // Don't wait: they carry on in the background while the macro goes on.
                for child in children { Task { @MainActor in await self.run([child]) } }
            } else {
                await withTaskGroup(of: Void.self) { group in
                    for child in children { group.addTask { @MainActor in await self.run([child]) } }
                }
            }
        case .splitText:
            let text = expand(step.text)
            let separator = expand(step.text2)
            let parts = separator.isEmpty ? text.components(separatedBy: .newlines) : text.components(separatedBy: separator)
            let name = step.name.isEmpty ? "List" : step.name
            let kept = parts.prefix(Self.itemLimit)
            set(name, kept.joined(separator: "\n"))
            variables[name + "_count"] = String(kept.count)
            for (index, part) in kept.enumerated() { variables["\(name)_\(index + 1)"] = part }
        case .webRequest:
            let address = expand(step.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = DownloadManager.downloadableURL(from: address), url.scheme?.lowercased() != "ftp" else {
                failed(step, "“\(address)” isn't a web address")
                return
            }
            var headers = HTTPCall.headers(expand(step.headers ?? ""))
            headers = NetworkSettings.headers(headers, for: url) // a saved site login, if there is one
            let request = HTTPCall.request(url: url, method: step.method ?? "GET", headers: headers, body: expand(step.text2), timeout: step.timeout)
            let answer = await HTTPCall.send(request)
            let name = step.name.isEmpty ? "Response" : step.name
            set(name, answer.body)
            variables[name + "_status"] = String(answer.status)
            if let error = answer.error {
                failed(step, error)
            } else if !(200..<300).contains(answer.status) {
                failed(step, "the server answered \(answer.status)")
            }
        case .json:
            let mode = step.jsonMode ?? .get
            let name = step.name.isEmpty ? (mode == .make ? "JSON" : "Value") : step.name
            guard let result = JSONTool.run(mode, json: expand(step.text), path: mode == .make ? expand(step.text2) : expand(step.text2)) else {
                set(name, "")
                failed(step, JSONTool.parse(expand(step.text)) == nil ? "that isn't JSON" : "there's nothing at “\(expand(step.text2))”")
                return
            }
            set(name, result)
        case .screenshot:
            let path = (expand(step.text) as NSString).expandingTildeInPath
            let area = step.capture ?? .screen
            guard let arguments = ScreenGrab.arguments(area, rect: ScreenGrab.rect(expand(step.area ?? "")),
                                                       window: area == .frontWindow ? ScreenGrab.frontWindowID() : nil, to: path) else {
                failed(step, area == .area ? "the area isn't four numbers (x, y, width, height)" : "there's no front window")
                return
            }
            if !path.isEmpty { try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
            let result = await Self.runProcess("/usr/sbin/screencapture", arguments, environment: [:], timeout: 30)
            if result.status != 0 || (!path.isEmpty && !FileManager.default.fileExists(atPath: path)) {
                failed(step, "the screenshot wasn't taken (Toolbelt needs Screen Recording)")
            } else if !step.name.isEmpty {
                set(step.name, path.isEmpty ? "clipboard" : path)
            }
        case .pictureFile:
            let source = (expand(step.text) as NSString).expandingTildeInPath
            guard let image = PictureFile.load(source) else {
                failed(step, "“\(source)” isn't a picture Toolbelt can open")
                return
            }
            let edit = step.pictureEdit ?? .convert
            if edit == .readText {
                set(step.name.isEmpty ? "Text" : step.name, await PictureFilter.readText(image))
                return
            }
            let destination = step.text2.isEmpty ? source : (expand(step.text2) as NSString).expandingTildeInPath
            guard let changed = PictureFile.apply(edit, to: image, width: step.number, area: expand(step.area ?? "")),
                  PictureFile.save(changed, to: destination) else {
                failed(step, edit == .crop ? "the area isn't inside the picture" : "the picture couldn't be changed or saved")
                return
            }
            if !step.name.isEmpty { set(step.name, destination) }
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
            set(step.name, await alert(expand(step.text), buttons.isEmpty ? ["OK"] : buttons))
        case .askFolder, .askFile:
            guard let path = await choosePath(expand(step.text), step.kind == .askFolder) else { stopped = true; return }
            set(step.name, path)
        case .askSeveral:
            let fields = Self.fields(step.text2)
            guard let answers = await askMany(expand(step.text), fields) else { stopped = true; return }
            for (field, answer) in zip(fields, answers) { set(Self.variableName(for: field), answer) }
        case .calculate:
            let sum = expand(step.text)
            guard let value = MacroCalculator.evaluate(sum) else {
                failed(step, "“\(sum)” isn't a sum Toolbelt can work out")
                return
            }
            set(step.name.isEmpty ? "Result" : step.name, MacroCalculator.format(value))
        case .pictureFilter:
            guard let image = PictureFilter.clipboardImage() else {
                failed(step, "there's no picture on the clipboard")
                return
            }
            let filter = step.picture ?? .flipHorizontal
            if filter == .readText {
                set(step.name.isEmpty ? "Text" : step.name, await PictureFilter.readText(image))
            } else if let changed = filter.apply(image) {
                PictureFilter.setClipboard(changed)
            } else {
                failed(step, "the picture couldn't be changed")
            }
        case .runMacro:
            guard depth < Self.depthLimit else {
                failed(step, "macros ran each other more than \(Self.depthLimit) deep")
                return
            }
            var inputs: [String: String] = [:]
            for (name, value) in MacroInputs.parse(step.text2) { inputs[name] = expand(value) }
            guard let result = await runMacro(expand(step.text), inputs, depth + 1) else {
                failed(step, "there's no macro called “\(expand(step.text))”")
                return
            }
            if !step.name.isEmpty { set(step.name, result) }
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

    /// After a loop's round: true when the loop should end (leave the loop, stop, or a caught failure).
    private func endOfRound() -> Bool {
        continueRequested = false
        if breakRequested {
            breakRequested = false
            return true
        }
        return stopped || caught != nil
    }

    /// A step failed: inside "Try…" it jumps to the "if a step fails" steps; otherwise carry on, stop, or stop
    /// and say so, as the step asks.
    private func failed(_ step: MacroStep, _ reason: String) {
        failures.append("\(step.summary): \(reason)")
        if tryDepth > 0 {
            if caught == nil { caught = "\(step.summary): \(reason)" }
            return
        }
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
    /// These windows don't hold other macros up while they wait.
    static func askPerson(_ prompt: String, _ options: [String]?) async -> String? {
        guard let answer = await PromptPanel.ask(prompt, fields: options == nil ? [""] : [], options: options) else { return nil }
        return options == nil ? answer.texts.first : answer.choice
    }

    static func showAlert(_ message: String, _ buttons: [String]) async -> String {
        await PromptPanel.ask(message, buttons: buttons)?.button ?? ""
    }

    static func askForPath(_ prompt: String, _ folder: Bool) async -> String? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.canCreateDirectories = folder
        // begin, not runModal: other macros keep working while it's open.
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        return response == .OK ? panel.url?.path : nil
    }

    static func askSeveral(_ prompt: String, _ fields: [String]) async -> [String]? {
        await PromptPanel.ask(prompt, fields: fields)?.texts
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
