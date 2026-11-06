import AppKit
import SwiftUI

// 0.35: download projects — a site grab that runs again by itself (every few hours, daily or weekly) and
// keeps a folder in step with the site: new files are downloaded, changed ones replaced, unchanged ones
// skipped (the server is asked "has it changed since?" with ETag / Last-Modified, so nothing is fetched twice).
// - `ProjectRepeat`: when a project runs next (pure).
// - `FileValidator` / `SyncEngine`: what's known about each file, the "changed since?" headers, and one run.
// - `ProjectStore` (projects.json) and `ProjectScheduler` (one timer for the next due project).
// - `ProjectsView` / `ProjectsWindow`: the list of projects and the editor.

enum ProjectRepeat: Codable, Equatable, Hashable {
    /// Only when you click Run Now.
    case manual
    case everyHours(Int)
    /// Minutes after midnight.
    case daily(Int)
    /// Weekday (1 = Sunday … 7 = Saturday) and minutes after midnight.
    case weekly(Int, Int)

    var title: String {
        switch self {
        case .manual: return "Only when I click Run Now"
        case .everyHours(let hours): return hours == 1 ? "Every hour" : "Every \(hours) hours"
        case .daily(let minute): return "Every day at \(DownloadQueue.clock(minute))"
        case .weekly(let day, let minute):
            let name = Calendar.current.weekdaySymbols[max(0, min(6, day - 1))]
            return "Every \(name) at \(DownloadQueue.clock(minute))"
        }
    }

    /// The next run: the first time slot after the last run (or after now, for a project that never ran).
    /// A slot missed while the Mac was off or asleep becomes "now", so it runs once, straight away.
    func next(last: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        let base = last ?? now
        let slot: Date?
        switch self {
        case .manual:
            return nil
        case .everyHours(let hours):
            slot = base.addingTimeInterval(TimeInterval(max(1, hours)) * 3600)
        case .daily(let minute):
            slot = Self.first(after: base, calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: base)) {
                calendar.date(byAdding: .day, value: 1, to: $0)
            }
        case .weekly(let day, let minute):
            var parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: base)
            parts.weekday = day
            parts.hour = minute / 60
            parts.minute = minute % 60
            slot = Self.first(after: base, calendar.date(from: parts)) { calendar.date(byAdding: .weekOfYear, value: 1, to: $0) }
        }
        return slot.map { max($0, now) }
    }

    private static func first(after base: Date, _ start: Date?, step: (Date) -> Date?) -> Date? {
        guard var candidate = start else { return nil }
        var tries = 0
        while candidate <= base {
            guard let next = step(candidate), tries < 1000 else { return nil }
            candidate = next
            tries += 1
        }
        return candidate
    }
}

/// What's known about one downloaded file, to ask the server whether it has changed.
struct FileValidator: Codable, Equatable {
    var etag: String?
    var lastModified: String?
    var length: Int64?
    /// Where it's saved, inside the project's folder.
    var path: String
}

struct DownloadProject: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var start: String
    var template: GrabTemplate = .files
    var depth = 1
    var maxFiles = 500
    var sameSite = true
    var folder: String
    var repeats: ProjectRepeat = .daily(3 * 60)
    var enabled = true
    var lastRun: Date?
    var lastResult: String?
    var files: [String: FileValidator] = [:]

    var startURL: URL? { DownloadManager.downloadableURL(from: start) }
    var folderURL: URL { URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true) }

    func nextRun(now: Date = Date()) -> Date? { enabled ? repeats.next(last: lastRun, now: now) : nil }
}

enum SyncEngine {
    /// One answer from the server.
    struct Response {
        var status: Int
        var etag: String?
        var lastModified: String?
        var length: Int64?
        /// The downloaded body (for a 2xx answer), in a temporary file.
        var file: URL?
    }

    typealias Fetch = @Sendable (URL, [String: String]) async -> Response?

    struct Summary: Equatable {
        var new = 0
        var changed = 0
        var unchanged = 0
        var failed = 0

        var text: String {
            var parts = ["\(new) new", "\(changed) changed", "\(unchanged) unchanged"]
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.joined(separator: ", ")
        }
    }

    /// "Send it only if it changed": If-None-Match for an ETag, If-Modified-Since for a date.
    static func conditionalHeaders(_ validator: FileValidator?) -> [String: String] {
        var headers: [String: String] = [:]
        if let etag = validator?.etag, !etag.isEmpty { headers["If-None-Match"] = etag }
        if let date = validator?.lastModified, !date.isEmpty { headers["If-Modified-Since"] = date }
        return headers
    }

    /// Brings one file up to date in `folder`. Returns the new validator and what happened.
    static func sync(_ url: URL, home: URL, folder: URL, known: FileValidator?, headers: [String: String],
                     fetch: Fetch) async -> (FileValidator?, Outcome) {
        let path = known?.path ?? OfflinePaths.path(for: url, isPage: false, home: home)
        let destination = folder.appendingPathComponent(path)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let ask = exists ? conditionalHeaders(known) : [:]
        guard let response = await fetch(url, headers.merging(ask) { _, new in new }) else { return (known, .failed) }
        if response.status == 304, exists { return (known, .unchanged) }
        guard (200..<300).contains(response.status), let body = response.file else { return (known, .failed) }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if exists { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: body, to: destination)
        } catch {
            return (known, .failed)
        }
        let validator = FileValidator(etag: response.etag, lastModified: response.lastModified, length: response.length, path: path)
        return (validator, exists ? .changed : .new)
    }

    enum Outcome { case new, changed, unchanged, failed }

    static func count(_ outcome: Outcome, into summary: inout Summary) {
        switch outcome {
        case .new: summary.new += 1
        case .changed: summary.changed += 1
        case .unchanged: summary.unchanged += 1
        case .failed: summary.failed += 1
        }
    }

    /// Runs a project: finds its files (or saves the whole site) and keeps its folder in step.
    static func run(_ project: DownloadProject, rules: [CategoryRule], headers: @escaping @Sendable (URL) -> [String: String],
                    page: @escaping SiteGrabber.Fetch, fetch: @escaping Fetch) async -> (DownloadProject, Summary) {
        var project = project
        guard let home = project.startURL else {
            project.lastResult = "That start page isn't a web address"
            return (project, Summary(failed: 1))
        }
        var settings = GrabSettings(start: home, template: project.template, depth: project.depth)
        settings.maxFiles = max(1, project.maxFiles)
        settings.sameSite = project.sameSite
        let grabber = SiteGrabber(settings: settings, rules: rules, fetch: page)
        let folder = project.folderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let box = SyncBox(files: project.files)

        if project.template == .site {
            _ = await grabber.mirror(into: folder, save: { url, destination in
                let path = destination.path.hasPrefix(folder.path + "/") ? String(destination.path.dropFirst(folder.path.count + 1)) : destination.lastPathComponent
                let known = box.files[url.absoluteString].map { FileValidator(etag: $0.etag, lastModified: $0.lastModified, length: $0.length, path: path) }
                    ?? FileValidator(path: path)
                let (validator, outcome) = await sync(url, home: home, folder: folder, known: known, headers: headers(url), fetch: fetch)
                box.record(url, validator, outcome)
                return outcome == .failed ? nil : (url.pathExtension.lowercased() == "css" ? "text/css" : "")
            })
        } else {
            let found = await grabber.explore()
            if found.pages.isEmpty {
                project.lastResult = "Couldn't open \(home.absoluteString)"
                project.lastRun = Date()
                return (project, Summary(failed: 1))
            }
            for link in found.files {
                let (validator, outcome) = await sync(link.url, home: home, folder: folder, known: box.files[link.url.absoluteString],
                                                      headers: headers(link.url), fetch: fetch)
                box.record(link.url, validator, outcome)
            }
        }
        project.files = box.files
        project.lastRun = Date()
        project.lastResult = box.summary.text
        return (project, box.summary)
    }

    /// The real network: a GET into a temporary file, through the download proxy.
    static func liveFetch(session: URLSession) -> Fetch {
        { url, headers in
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue(GrabberModel.userAgent, forHTTPHeaderField: "User-Agent")
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            guard let (file, response) = try? await session.download(for: request), let http = response as? HTTPURLResponse else { return nil }
            var kept: URL?
            if (200..<300).contains(http.statusCode) {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-sync-\(UUID().uuidString)")
                if (try? FileManager.default.moveItem(at: file, to: copy)) != nil { kept = copy }
            }
            let length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            return Response(status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"),
                            lastModified: http.value(forHTTPHeaderField: "Last-Modified"), length: length, file: kept)
        }
    }
}

/// Collects a run's results from the grabber's callbacks.
final class SyncBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var files: [String: FileValidator]
    private(set) var summary = SyncEngine.Summary()

    init(files: [String: FileValidator]) { self.files = files }

    func record(_ url: URL, _ validator: FileValidator?, _ outcome: SyncEngine.Outcome) {
        lock.lock()
        defer { lock.unlock() }
        if let validator { files[url.absoluteString] = validator }
        SyncEngine.count(outcome, into: &summary)
    }
}

// MARK: - Saving and running projects

@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()
    @Published var projects: [DownloadProject] = [] { didSet { save() } }
    /// Projects running now.
    @Published private(set) var running: Set<UUID> = []
    private var timer: Timer?
    private var loading = false

    static var file: URL { SettingsStore.folder.appendingPathComponent("projects.json") }

    init() {
        reload()
    }

    func reload() {
        loading = true
        projects = ((try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([DownloadProject].self, from: $0) }) ?? []
        loading = false
    }

    private func save() {
        guard !loading, let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: Self.file, options: .atomic)
        armTimer()
        RealUseHooks.writeStatus()
    }

    func update(_ project: DownloadProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
    }

    func remove(_ id: UUID) { projects.removeAll { $0.id == id } }

    /// Starts the timer for the next due project (one timer for all of them).
    func start() {
        armTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        let now = Date()
        guard let next = projects.compactMap({ $0.nextRun(now: now) }).min() else { return }
        let timer = Timer(fire: max(next, now.addingTimeInterval(5)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func runDue() {
        let now = Date()
        for project in projects where !running.contains(project.id) {
            if let next = project.nextRun(now: now), next <= now.addingTimeInterval(1) { run(project.id) }
        }
        armTimer()
    }

    /// Runs a project now (in the background); the list shows it as running until it's done.
    func run(_ id: UUID, notify: Bool = true) {
        guard let project = projects.first(where: { $0.id == id }), !running.contains(id) else { return }
        running.insert(id)
        RealUseHooks.writeStatus()
        let rules = Prefs.downloadCategories
        let logins = Dictionary(SiteLogins.all.compactMap { login in SiteLogins.password(for: login).map { (login.host, NetworkSettings.basicAuthorization(user: login.user, password: $0)) } },
                                uniquingKeysWith: { first, _ in first })
        Task { @MainActor in
            let session = NetworkSettings.session()
            let (updated, summary) = await SyncEngine.run(project, rules: rules, headers: { url in
                url.host.flatMap { logins[$0.lowercased()] }.map { ["Authorization": $0] } ?? [:]
            }, page: GrabberModel.fetch, fetch: SyncEngine.liveFetch(session: session))
            running.remove(id)
            if let index = projects.firstIndex(where: { $0.id == id }) {
                var kept = updated
                // Changes made in the editor while it ran win, except what the run found out.
                let current = projects[index]
                kept.name = current.name
                kept.enabled = current.enabled
                kept.repeats = current.repeats
                projects[index] = kept
            }
            if notify, summary.new + summary.changed + summary.failed > 0 {
                DownloadNotifier.post(id: "toolbelt-project-\(id.uuidString)", title: "\(project.name): \(summary.text)",
                                      body: project.folderURL.path, path: project.folderURL.path)
            }
            RealUseHooks.writeStatus()
        }
    }

    var statusText: [String] {
        projects.map { "\($0.name): " + (running.contains($0.id) ? "running" : ($0.lastResult ?? "never run")) }
    }

    func registerTestHooks() {
        RealUseHooks.extraStatus["projects"] = { [weak self] in self?.statusText ?? [] }
        RealUseHooks.commands["project-run"] = { [weak self] name in
            guard let self, let project = projects.first(where: { $0.name == name }) else { return }
            run(project.id, notify: false)
        }
        RealUseHooks.commands["projects-reload"] = { [weak self] _ in self?.reload(); self?.armTimer() }
    }
}

// MARK: - The Projects window

struct ProjectsView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var selectionHolder: ProjectSelection
    private var selection: Binding<UUID?> { $selectionHolder.id }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: selection) {
                    ForEach(store.projects) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(project.name).fontWeight(.medium)
                                if store.running.contains(project.id) { ProgressView().controlSize(.mini) }
                            }
                            Text(project.enabled ? project.repeats.title : "Off").font(.caption).foregroundStyle(.secondary)
                            if let result = project.lastResult {
                                Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(project.id)
                    }
                }
                Divider()
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection.wrappedValue { store.remove(id) }
                        selection.wrappedValue = store.projects.first?.id
                    } label: { Image(systemName: "minus") }
                    .disabled(selection.wrappedValue == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            Group {
                if let index = store.projects.firstIndex(where: { $0.id == selection.wrappedValue }) {
                    ProjectEditor(project: $store.projects[index], running: store.running.contains(store.projects[index].id)) {
                        store.run(store.projects[index].id)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("A project keeps a folder in step with a site").font(.headline)
                        Text("Pick what to grab and how often. Each run downloads only new and changed files.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("New Project") { add() }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { if selection.wrappedValue == nil { selection.wrappedValue = store.projects.first?.id } }
    }

    private func add() {
        let project = DownloadProject(name: "Project \(store.projects.count + 1)", start: "https://",
                                      folder: Prefs.downloadFolder.appendingPathComponent("Projects/Project \(store.projects.count + 1)").path)
        store.update(project)
        selection.wrappedValue = project.id
    }
}

struct ProjectEditor: View {
    @Binding var project: DownloadProject
    let running: Bool
    let runNow: () -> Void

    private enum Often: String, CaseIterable, Identifiable {
        case manual, hours, daily, weekly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .manual: return "Only when I click Run Now"
            case .hours: return "Every few hours"
            case .daily: return "Every day"
            case .weekly: return "Every week"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $project.name)
                TextField("Start page", text: $project.start, prompt: Text("https://example.com"))
                Picker("Grab", selection: $project.template) {
                    ForEach(GrabTemplate.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Pages to follow: \(project.depth == 0 ? "only the start page" : "\(project.depth) level\(project.depth == 1 ? "" : "s") of links")",
                        value: $project.depth, in: 0...6)
                Toggle("Only this site", isOn: $project.sameSite)
                LabeledContent("Keep in step with") {
                    HStack {
                        Text(project.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
            Section {
                Picker("Run", selection: often) { ForEach(Often.allCases) { Text($0.title).tag($0) } }
                switch project.repeats {
                case .everyHours(let hours):
                    Stepper("Every \(hours) hour\(hours == 1 ? "" : "s")", value: Binding(get: { hours }, set: { project.repeats = .everyHours(max(1, $0)) }), in: 1...48)
                case .daily(let minute):
                    DatePicker("At", selection: time(minute) { project.repeats = .daily($0) }, displayedComponents: .hourAndMinute)
                case .weekly(let day, let minute):
                    Picker("On", selection: Binding(get: { day }, set: { project.repeats = .weekly($0, minute) })) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }
                    DatePicker("At", selection: time(minute) { project.repeats = .weekly(day, $0) }, displayedComponents: .hourAndMinute)
                case .manual:
                    EmptyView()
                }
                Toggle("On", isOn: $project.enabled)
            } header: {
                Text("How often")
            } footer: {
                Text("Each run asks the site whether each file has changed since last time, and downloads only new and changed ones. A run missed while the Mac was off or asleep happens once, when Toolbelt is next running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    if running {
                        ProgressView().controlSize(.small)
                        Text("Running…")
                    } else {
                        Text(project.lastRun.map { "Last run \($0.formatted(date: .abbreviated, time: .shortened)): \(project.lastResult ?? "")" } ?? "Not run yet")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Folder") { NSWorkspace.shared.open(project.folderURL) }
                    Button("Run Now", action: runNow).disabled(running || project.startURL == nil)
                }
                if let next = project.nextRun() {
                    Text("Next run \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var often: Binding<Often> {
        Binding(get: {
            switch project.repeats {
            case .manual: return .manual
            case .everyHours: return .hours
            case .daily: return .daily
            case .weekly: return .weekly
            }
        }, set: { choice in
            switch choice {
            case .manual: project.repeats = .manual
            case .hours: project.repeats = .everyHours(6)
            case .daily: project.repeats = .daily(3 * 60)
            case .weekly: project.repeats = .weekly(1, 3 * 60)
            }
        })
    }

    private func time(_ minute: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = project.folderURL.deletingLastPathComponent()
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { project.folder = url.path }
    }
}

/// Which project the window shows, so "Save as Project…" can open it at the new one.
@MainActor
final class ProjectSelection: ObservableObject {
    @Published var id: UUID?
}

@MainActor
enum ProjectsWindow {
    private static var window: NSWindow?
    private static let selection = ProjectSelection()

    static func show(select id: UUID? = nil) {
        if let id { selection.id = id }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Download Projects"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ProjectsView(store: ProjectStore.shared, selectionHolder: selection))
            window.setContentSize(NSSize(width: 760, height: 520))
            window.center()
            window.setFrameAutosaveName("ToolbeltProjects")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
