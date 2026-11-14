import Foundation

// 0.40: trigger plugins, like BetterTouchTool's: a small shell script decides when a macro starts.
// Two ways:
// - looked at every so often: the macro starts whenever what the script prints changes (for example
//   `curl -s https://example.com/status`, or `ls ~/Inbox | wc -l`);
// - kept running: the macro starts for every line the script prints (for example
//   `tail -F /var/log/app.log | grep --line-buffered ERROR`).
// What it printed is in %Trigger%. Scripts only run while a macro uses this.

/// Pure parts, so they can be tested.
enum ScriptTriggerLogic {
    /// The first look only learns the starting output; after that any change counts.
    static func fires(previous: String?, output: String) -> Bool {
        guard let previous else { return false }
        return previous != output
    }

    /// Seconds between looks: at least 5, so a script can't keep the Mac busy.
    static func interval(_ number: Int) -> Double { Double(max(5, number)) }
}

/// Collects a running script's output and hands back complete lines.
struct LineSplitter {
    private var pending = ""

    mutating func add(_ text: String) -> [String] {
        pending += text
        var lines: [String] = []
        // Swift counts "\r\n" as one character, so look for any line ending, not just "\n".
        while let newline = pending.firstIndex(where: \.isNewline) {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        // A runaway line without an end is cut off rather than growing forever.
        if pending.count > 64_000 {
            lines.append(pending)
            pending = ""
        }
        return lines
    }
}

/// Runs one trigger's script and calls `fire` when it says so.
@MainActor
final class ScriptTriggerWatcher {
    let script: String
    let every: Int
    private let fire: (String) -> Void
    private var timer: Timer?
    private var previous: String?
    private var process: Process?
    private var splitter = LineSplitter()
    private var looking = false
    private var stopped = false
    private var restarts = 0

    init(script: String, every: Int, fire: @escaping (String) -> Void) {
        self.script = script
        self.every = every
        self.fire = fire
    }

    func start() {
        stopped = false
        if every > 0 {
            look()
            let timer = Timer(timeInterval: ScriptTriggerLogic.interval(every), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            launch()
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func look() {
        guard !looking else { return }
        looking = true
        let script = self.script
        Task { [weak self] in
            let result = await MacroRun.runProcess("/bin/zsh", ["-lc", script], environment: [:], timeout: 60)
            guard let self, !self.stopped else { return }
            self.looking = false
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if ScriptTriggerLogic.fires(previous: self.previous, output: output) { self.fire(output) }
            self.previous = output
        }
    }

    private func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    for line in self.splitter.add(text) { self.fire(line) }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A script that ends is started again (waiting longer each time, up to a minute).
                    guard let self, !self.stopped else { return }
                    self.restarts += 1
                    let wait = min(60, Double(self.restarts) * 5)
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, !self.stopped else { return }
                            self.launch()
                        }
                    }
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Toolbelt: couldn't start a trigger script: \(error)")
        }
    }
}
