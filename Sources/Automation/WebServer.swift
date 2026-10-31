import AppKit
import Network

// A small web server, like BetterTouchTool's: other programs, scripts, Stream Deck-style apps or
// a browser on your phone can run Toolbelt's macros and Mac actions by opening a web address.
// Off until switched on in Settings → Automation. Every request must carry the shared secret.
// By default only this Mac can reach it; letting other devices on your network in is a separate switch.

/// One request, as far as Toolbelt needs it.
struct WebRequest: Equatable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]

    /// Reads the start of an HTTP request ("GET /path?x=1 HTTP/1.1" and its headers).
    static func parse(_ data: Data) -> WebRequest? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let headEnd = text.range(of: "\r\n\r\n")?.lowerBound ?? text.range(of: "\n\n")?.lowerBound else { return nil }
        let lines = text[..<headEnd].components(separatedBy: "\n").map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var path = components?.path ?? target
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return WebRequest(method: String(parts[0]).uppercased(), path: path.isEmpty ? "/" : path, query: query, headers: headers)
    }

    /// The secret, from ?shared_secret= (BetterTouchTool's name), ?secret= or the X-Toolbelt-Secret header.
    var secret: String? { query["shared_secret"] ?? query["secret"] ?? headers["x-toolbelt-secret"] }
}

struct WebResponse: Equatable {
    var status: Int
    var contentType = "application/json; charset=utf-8"
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> WebResponse {
        WebResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String) -> WebResponse { json(["ok": false, "error": message], status: status) }

    var data: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 429: "Too Many Requests"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// What the web server can do, kept apart from the networking so it can be tested.
@MainActor
struct WebAPI {
    var secret: String
    var macroNames: () -> [String]
    var runMacro: (String, String) -> Void
    var runAction: (MacroAction) -> Void

    func respond(to request: WebRequest) -> WebResponse {
        guard request.method == "GET" || request.method == "POST" else { return .error(405, "Use GET or POST.") }
        // The page itself holds no secrets; it asks for the secret and keeps it in the browser.
        if request.path == "/" || request.path == "/remote" {
            return WebResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(WebPage.html.utf8))
        }
        guard let given = request.secret, Self.same(given, secret) else {
            return .error(401, "The shared secret is missing or wrong. Find it in Toolbelt: Settings → Automation → Web server.")
        }
        switch request.path {
        case "/list":
            return .json([
                "ok": true,
                "macros": macroNames(),
                "actions": SystemControl.allCases.map { ["id": $0.rawValue, "title": $0.title] },
                "commands": ShortcutAction.allCases.map { ["id": $0.rawValue, "title": $0.title.capitalizedFirst] },
            ])
        case "/trigger_named", "/run_macro", "/macro":
            // /trigger_named/?trigger_name=… is BetterTouchTool's address for the same thing.
            guard let name = request.query["trigger_name"] ?? request.query["name"], !name.isEmpty else {
                return .error(400, "Say which macro: ?name=Macro name")
            }
            guard let macro = macroNames().first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                return .error(404, "There's no macro called “\(name)”.")
            }
            runMacro(macro, request.query["input"] ?? "")
            return .json(["ok": true, "ran": macro])
        case "/action":
            if let id = request.query["do"] ?? request.query["action"], let control = SystemControl(rawValue: id) {
                runAction(.system(control))
                return .json(["ok": true, "ran": control.title])
            }
            if let id = request.query["command"], let command = ShortcutAction.named(id) {
                runAction(.toolbelt(command))
                return .json(["ok": true, "ran": command.title])
            }
            return .error(404, "Unknown action. /list shows them all.")
        default:
            return .error(404, "Nothing here. Try /list, /trigger_named/?trigger_name=…, or /action?do=volumeUp.")
        }
    }

    /// Compares secrets in the same time whatever they hold, so they can't be guessed a letter at a time.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { difference |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return difference == 0 && !b.isEmpty
    }

    static func newSecret() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in letters[Int(generator.next(upperBound: UInt64(letters.count)))] })
    }
}

/// Listens for requests. Nothing runs, and no port is open, while it's switched off.
@MainActor
final class WebServer {
    private var listener: NWListener?
    private var api: WebAPI?
    private var failures: [Date] = []
    private(set) var port: UInt16 = 0
    private(set) var problem: String?

    var isRunning: Bool { listener != nil }

    /// `everyone`: other devices on the network may connect (otherwise only this Mac).
    func start(port: UInt16, everyone: Bool, api: WebAPI) {
        stop()
        self.api = api
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { problem = "Port \(port) isn't a valid port."; return }
            if !everyone {
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            }
            let listener = everyone ? try NWListener(using: parameters, on: nwPort) : try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .failed(let error) = state {
                        self?.problem = "Couldn't open port \(port): \(error.localizedDescription)"
                        self?.stop()
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.port = port
            problem = nil
        } catch {
            problem = "Couldn't start the web server: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let response = self.response(for: data)
                connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func response(for data: Data?) -> WebResponse {
        guard let data, let request = WebRequest.parse(data), let api else { return .error(400, "That wasn't a web request.") }
        // Ten wrong secrets in a minute: wait a minute before trying again.
        failures.removeAll { $0 < Date().addingTimeInterval(-60) }
        if failures.count >= 10 { return .error(429, "Too many wrong secrets. Wait a minute.") }
        let response = api.respond(to: request)
        if response.status == 401 { failures.append(Date()) }
        return response
    }

    /// This Mac's addresses on the local network, for the Settings page.
    static func localAddresses() -> [String] {
        var addresses: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: host))
            }
        }
        return addresses
    }
}

/// The page the server shows at its address: buttons for every macro and the common Mac controls.
/// It asks for the shared secret once and keeps it in that browser only.
enum WebPage {
    static let html = """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Toolbelt">
    <title>Toolbelt</title>
    <style>
      :root { color-scheme: light dark; --bg: #f2f2f7; --card: #fff; --text: #111; --muted: #666; --accent: #0a84ff; }
      @media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --muted: #999; } }
      body { margin: 0; padding: 16px; font: 16px -apple-system, system-ui, sans-serif; background: var(--bg); color: var(--text); }
      h1 { font-size: 22px; margin: 4px 0 12px; } h2 { font-size: 13px; text-transform: uppercase; color: var(--muted); margin: 20px 0 8px; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 10px; }
      button { font: inherit; padding: 14px 10px; border: 0; border-radius: 12px; background: var(--card); color: var(--text); }
      button:active { background: var(--accent); color: #fff; }
      input { font: inherit; padding: 10px; border-radius: 10px; border: 1px solid #8884; width: 100%; box-sizing: border-box; }
      #status { color: var(--muted); font-size: 13px; min-height: 18px; margin-top: 8px; }
    </style></head><body>
    <h1>Toolbelt</h1>
    <div id="login" hidden><p>Enter the shared secret from Toolbelt → Settings → Automation → Web server.</p>
      <input id="secret" autocomplete="off" autocapitalize="off"><p><button id="save">Connect</button></p></div>
    <div id="panel" hidden><h2>Macros</h2><div class="grid" id="macros"></div><h2>Mac</h2><div class="grid" id="actions"></div></div>
    <div id="status"></div>
    <script>
      const common = ["playPause","previousTrack","nextTrack","volumeDown","volumeUp","mute","muteMicrophone","brightnessDown",
        "brightnessUp","missionControl","showDesktop","spotlight","lockScreen","sleepDisplay","sleep"];
      const query = new URLSearchParams(location.search);
      let secret = query.get("secret") || localStorage.getItem("toolbelt-secret") || "";
      const status = (text) => (document.getElementById("status").textContent = text);
      async function call(path) {
        const response = await fetch(path + (path.includes("?") ? "&" : "?") + "secret=" + encodeURIComponent(secret));
        const reply = await response.json();
        if (response.status === 401) { localStorage.removeItem("toolbelt-secret"); show(false); }
        return reply;
      }
      function button(title, path) {
        const b = document.createElement("button");
        b.textContent = title;
        b.onclick = async () => { const r = await call(path); status(r.ok ? "✓ " + r.ran : r.error); };
        return b;
      }
      function show(connected) { document.getElementById("login").hidden = connected; document.getElementById("panel").hidden = !connected; }
      async function load() {
        if (!secret) { show(false); return; }
        const list = await call("/list");
        if (!list.ok) { status(list.error); show(false); return; }
        localStorage.setItem("toolbelt-secret", secret);
        show(true);
        const macros = document.getElementById("macros"), actions = document.getElementById("actions");
        macros.replaceChildren(...list.macros.map((name) => button(name, "/trigger_named?trigger_name=" + encodeURIComponent(name))));
        if (!list.macros.length) macros.textContent = "No macros yet.";
        const titles = Object.fromEntries(list.actions.map((a) => [a.id, a.title]));
        actions.replaceChildren(...common.filter((id) => titles[id]).map((id) => button(titles[id], "/action?do=" + id)));
      }
      document.getElementById("save").onclick = () => { secret = document.getElementById("secret").value.trim(); load(); };
      load();
    </script></body></html>
    """
}
