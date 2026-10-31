import AppKit

// ToolbeltBridge: the small program Chrome starts when the Toolbelt extension sends a message
// ("native messaging"). It lives inside Toolbelt.app and is only allowed to talk to the Toolbelt
// extension (see the allowed_origins in Chrome's NativeMessagingHosts/local.personal.toolbelt.json).
//
// Each message is a 4-byte length followed by JSON. A download request is written as a .json file
// into ~/Library/Application Support/Toolbelt/inbox/, which Toolbelt watches; if Toolbelt isn't
// running it's opened in the background first.

let bundleID = "local.personal.toolbelt"

func dataFolder() -> URL {
    if let custom = ProcessInfo.processInfo.environment["TOOLBELT_DATA_DIR"], !custom.isEmpty {
        return URL(fileURLWithPath: custom, isDirectory: true)
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Toolbelt", isDirectory: true)
}

func readMessage() -> [String: Any]? {
    let input = FileHandle.standardInput
    let header = input.readData(ofLength: 4)
    guard header.count == 4 else { return nil }
    let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    guard length > 0, length < 1_000_000 else { return nil }
    let body = input.readData(ofLength: length)
    return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
}

func send(_ reply: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: reply) else { return }
    var length = UInt32(body.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4) + body)
}

/// Opens Toolbelt in the background if it isn't running (not during the automated tests).
func openToolbeltIfNeeded() {
    guard ProcessInfo.processInfo.environment["TOOLBELT_BRIDGE_NO_LAUNCH"] == nil,
          NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
    // This program is at Toolbelt.app/Contents/MacOS/ToolbeltBridge.
    let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + 10)
}

func handOver(_ message: [String: Any]) -> [String: Any] {
    guard let url = message["url"] as? String, let scheme = URL(string: url)?.scheme?.lowercased(),
          ["http", "https", "ftp"].contains(scheme) else {
        return ["ok": false, "error": "Not a web or FTP link"]
    }
    var request: [String: String] = ["url": url]
    for key in ["name", "referrer", "cookies", "userAgent"] {
        if let value = message[key] as? String, !value.isEmpty { request[key] = value }
    }
    let inbox = dataFolder().appendingPathComponent("inbox", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = UUID().uuidString
        // Written under a hidden name, then renamed, so Toolbelt never reads half a file.
        let hidden = inbox.appendingPathComponent(".\(id).json")
        try JSONSerialization.data(withJSONObject: request).write(to: hidden)
        try FileManager.default.moveItem(at: hidden, to: inbox.appendingPathComponent("\(id).json"))
    } catch {
        return ["ok": false, "error": error.localizedDescription]
    }
    openToolbeltIfNeeded()
    return ["ok": true]
}

// From Terminal: ToolbeltBridge run "Macro name" [text for %Trigger%]
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "run" {
    let inbox = dataFolder().appendingPathComponent("inbox-macros", isDirectory: true)
    var request = ["macro": CommandLine.arguments[2]]
    if CommandLine.arguments.count >= 4 { request["input"] = CommandLine.arguments[3...].joined(separator: " ") }
    do {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let hidden = inbox.appendingPathComponent(".\(id).json")
        try JSONSerialization.data(withJSONObject: request).write(to: hidden)
        try FileManager.default.moveItem(at: hidden, to: inbox.appendingPathComponent("\(id).json"))
        openToolbeltIfNeeded()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Couldn't hand the macro to Toolbelt: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

while let message = readMessage() {
    switch message["type"] as? String {
    case "ping": send(["ok": true, "version": 1])
    case "download": send(handOver(message))
    default: send(["ok": false, "error": "Unknown message"])
    }
}
