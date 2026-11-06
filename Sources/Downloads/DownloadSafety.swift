import AppKit
import Security

// 0.35: what every download goes through.
// - `ProxySettings` / `NetworkSettings`: an optional proxy for downloads, and the saved site logins' headers.
// - `SiteLogins` + `PasswordStore`: usernames in the settings, passwords in the Mac's Keychain.
// - `DownloadSafety`: marks finished downloads as "from the internet" so macOS checks them when opened
//   (the same quarantine mark browsers set), and runs an optional virus scanner on them.

// MARK: - Proxy

struct ProxySettings: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case none, http, socks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "No proxy"
            case .http: return "HTTP/HTTPS proxy"
            case .socks: return "SOCKS proxy"
            }
        }
    }

    var kind: Kind = .none
    var host = ""
    var port = 8080

    var isOn: Bool { kind != .none && !host.trimmingCharacters(in: .whitespaces).isEmpty && port > 0 }

    /// What URLSession takes as its `connectionProxyDictionary` (nil: no proxy, the Mac's own settings apply).
    var dictionary: [AnyHashable: Any]? {
        guard isOn else { return nil }
        let host = host.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .none:
            return nil
        case .http:
            return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                    "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port, "ExceptionsList": [String]()]
        case .socks:
            return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port, "ExceptionsList": [String]()]
        }
    }

    var summary: String { isOn ? "\(kind == .socks ? "SOCKS" : "HTTP") \(host):\(port)" : "none" }
}

/// The proxy every download session uses, kept here so download jobs (on their own threads) can read it.
enum NetworkSettings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var proxy = ProxySettings()

    static var currentProxy: ProxySettings {
        get { lock.lock(); defer { lock.unlock() }; return proxy }
        set { lock.lock(); proxy = newValue; lock.unlock() }
    }

    /// Sets up a download session: the proxy, if there is one.
    static func apply(to configuration: URLSessionConfiguration) {
        if let dictionary = currentProxy.dictionary { configuration.connectionProxyDictionary = dictionary }
    }

    /// A plain session for the site grabber and projects, with the proxy and no cache.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        apply(to: configuration)
        return URLSession(configuration: configuration)
    }

    nonisolated(unsafe) private static var cached: (proxy: ProxySettings, session: URLSession)?

    /// One shared session (with the current proxy) for the site grabber; made again when the proxy changes.
    static var sharedSession: URLSession {
        let proxy = currentProxy
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.proxy == proxy { return cached.session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        if let dictionary = proxy.dictionary { configuration.connectionProxyDictionary = dictionary }
        let session = URLSession(configuration: configuration)
        cached = (proxy, session)
        return session
    }

    /// "Authorization: Basic …" for a user name and password.
    static func basicAuthorization(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    /// A download's headers with a saved login added for its site (unless it already has one).
    @MainActor
    static func headers(_ headers: [String: String], for url: URL) -> [String: String] {
        guard headers.keys.contains(where: { $0.lowercased() == "authorization" }) == false,
              let login = SiteLogins.login(for: url), let password = SiteLogins.password(for: login) else { return headers }
        var result = headers
        result["Authorization"] = basicAuthorization(user: login.user, password: password)
        return result
    }
}

// MARK: - Site logins

struct SiteLogin: Codable, Equatable, Identifiable, Hashable {
    /// The site, like "files.example.com".
    var host: String
    var user: String
    var id: String { host + "\u{1}" + user }

    /// "https://Files.Example.com/x" → "files.example.com"; a bare name stays as it is.
    static func cleanHost(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: text), let host = url.host, url.scheme != nil { text = host }
        return text.split(separator: "/").first.map(String.init) ?? text
    }

    func matches(_ url: URL) -> Bool { url.host?.lowercased() == host }
}

/// Where passwords are kept: the Keychain in the app, a dictionary in the tests.
protocol PasswordStore {
    func password(service: String, account: String) -> String?
    @discardableResult func setPassword(_ password: String, service: String, account: String) -> Bool
    func removePassword(service: String, account: String)
}

struct KeychainPasswords: PasswordStore {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func password(service: String, account: String) -> String? {
        var query = query(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String, service: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var item = query(service, account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Toolbelt: \(account)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func removePassword(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

final class MemoryPasswords: PasswordStore {
    private var values: [String: String] = [:]
    func password(service: String, account: String) -> String? { values[service + "/" + account] }
    func setPassword(_ password: String, service: String, account: String) -> Bool { values[service + "/" + account] = password; return true }
    func removePassword(service: String, account: String) { values[service + "/" + account] = nil }
}

/// Logins for sites that ask for a user name and password (HTTP sign-in). Usernames are in the settings;
/// passwords only in the Keychain.
@MainActor
enum SiteLogins {
    static let service = "Toolbelt download login"
    static var store: PasswordStore = KeychainPasswords()

    static var all: [SiteLogin] { Prefs.downloadLogins }

    static func account(_ login: SiteLogin) -> String { login.user + "@" + login.host }

    static func login(for url: URL) -> SiteLogin? { all.first { $0.matches(url) } }

    static func password(for login: SiteLogin) -> String? { store.password(service: service, account: account(login)) }

    /// Saves a login. Returns false if the Keychain refused the password.
    @discardableResult
    static func add(host: String, user: String, password: String) -> Bool {
        let login = SiteLogin(host: SiteLogin.cleanHost(host), user: user.trimmingCharacters(in: .whitespaces))
        guard !login.host.isEmpty, !login.user.isEmpty, store.setPassword(password, service: service, account: account(login)) else { return false }
        Prefs.downloadLogins = all.filter { $0.host != login.host } + [login]
        return true
    }

    static func remove(_ login: SiteLogin) {
        store.removePassword(service: service, account: account(login))
        Prefs.downloadLogins = all.filter { $0 != login }
    }
}

// MARK: - Checking finished downloads

enum DownloadSafety {
    /// Marks a file as downloaded from the internet, as browsers do: macOS then checks it (Gatekeeper,
    /// XProtect) when it's opened, and shows where it came from in Get Info.
    @discardableResult
    static func markQuarantined(_ file: URL, from source: URL?, page: URL?, date: Date = Date()) -> Bool {
        let value = String(format: "0083;%08x;Toolbelt;%@", UInt32(max(0, date.timeIntervalSince1970)), UUID().uuidString)
        let ok = file.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) == 0 }
        }
        let sources = [source, page].compactMap { $0?.absoluteString }
        if !sources.isEmpty, let plist = try? PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0) {
            file.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                _ = plist.withUnsafeBytes { setxattr(path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0) }
            }
        }
        return ok
    }

    /// The quarantine mark on a file, if it has one.
    static func quarantine(of file: URL) -> String? {
        file.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            var buffer = [CChar](repeating: 0, count: 512)
            let length = getxattr(path, "com.apple.quarantine", &buffer, buffer.count - 1, 0, 0)
            guard length > 0 else { return nil }
            return String(cString: Array(buffer[0..<length]) + [0])
        }
    }

    /// The scanner command for a file: %file% replaced by its (quoted) path, or the path added at the end.
    static func scanCommand(_ template: String, file: URL) -> String {
        let quoted = UpdateSwap.quoted(file.path)
        return template.contains("%file%") ? template.replacingOccurrences(of: "%file%", with: quoted) : template + " " + quoted
    }

    struct ScanResult: Equatable {
        /// The scanner said the file is infected (it exited with an error).
        var flagged: Bool
        /// What it printed (last lines).
        var message: String
    }

    /// Runs the scanner (a shell command) on a file. Exit status 0 means clean; anything else means flagged.
    /// Returns nil when there's no scanner set or it couldn't be started.
    static func scan(_ file: URL, command template: String, timeout: TimeInterval = 300) -> ScanResult? {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", scanCommand(template, file: file)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return ScanResult(flagged: false, message: "The virus scanner took too long") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = output.split(separator: "\n").suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return ScanResult(flagged: process.terminationStatus != 0, message: message)
    }
}
