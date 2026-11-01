import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject private var settings = SettingsStore.shared
    @State private var link = ""
    @State private var problem: String?
    @State private var dropTargeted = false
    /// nil shows every queue.
    @State private var queueFilter: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste or drop a link to download", text: $link)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
                Button("Paste") {
                    link = NSPasteboard.general.string(forType: .string) ?? ""
                    add()
                }
                Button("Download", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Color.orange).padding(.bottom, 6)
            }
            Divider()
            queueBar
            Divider()

            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(manager.items.isEmpty ? "No downloads yet" : "Nothing in this queue").foregroundStyle(.secondary)
                    Text("Paste a link above, drop one here, or choose “Download Link from Clipboard” in the menu bar.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shown) { item in
                        DownloadRow(item: item, manager: manager,
                                    columns: Prefs.downloadColumns, buttons: Prefs.downloadButtons)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 10) {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Picker("When done", selection: $manager.whenDone) {
                    ForEach(WhenDone.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help("What to do once every download has finished (once)")
                Menu {
                    Section("Show") {
                        ForEach(DownloadColumn.allCases) { column in
                            Toggle(column.title, isOn: columnBinding(column))
                        }
                    }
                    Section("Buttons") {
                        ForEach(DownloadButton.allCases) { button in
                            Toggle(button.title, isOn: buttonBinding(button))
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose what the list shows")
                Button("Clear Finished") { manager.clearFinished() }
                    .disabled(!manager.items.contains { $0.state == .completed })
                Button("Open Folder") { NSWorkspace.shared.open(Prefs.downloadFolder) }
            }
            .padding(10)
        }
        .frame(minWidth: 620, minHeight: 340)
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .onDrop(of: [.url, .plainText], isTargeted: $dropTargeted) { providers in
            let queue = queueFilter
            for provider in providers {
                let add: @Sendable (String) -> Void = { text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { _ = manager.add(text, queue: queue) }
                    }
                }
                if provider.canLoadObject(ofClass: NSURL.self) {
                    _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                        if let url = url as? URL { add(url.absoluteString) }
                    }
                } else {
                    _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                        if let text = text as? String { add(text) }
                    }
                }
            }
            return true
        }
    }

    /// Queue tabs, with a start/stop button for the chosen queue.
    private var queueBar: some View {
        HStack(spacing: 8) {
            Picker("Queue", selection: $queueFilter) {
                Text("All").tag(UUID?.none)
                ForEach(manager.queues) { queue in
                    Text(queue.name).tag(UUID?.some(queue.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let id = queueFilter, let queue = manager.queues.first(where: { $0.id == id }) {
                Button {
                    if queue.isRunning { manager.stopQueue(id) } else { manager.startQueue(id) }
                } label: {
                    Label(queue.isRunning ? "Stop Queue" : "Start Queue", systemImage: queue.isRunning ? "stop.fill" : "play.fill")
                }
                Text(queueStatus(queue)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let until = manager.cappedUntil {
                Label("Hourly limit reached · carries on at \(until.formatted(date: .omitted, time: .shortened))", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(Color.orange)
            } else if Prefs.downloadSpeedLimitKB > 0 {
                Label("Limited to \(ByteFormat.speed(Double(Prefs.downloadSpeedLimitKB) * 1024))", systemImage: "tortoise")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func queueStatus(_ queue: DownloadQueue) -> String {
        var parts = [queue.isRunning ? "Running" : "Stopped", queue.limitText]
        if let schedule = queue.scheduleText { parts.append(schedule) }
        return parts.joined(separator: " · ")
    }

    private var shown: [DownloadItem] {
        guard let queueFilter else { return manager.items }
        return manager.items.filter { manager.queue(of: $0).id == queueFilter }
    }

    private var summary: String {
        let active = manager.items.filter { $0.state == .downloading }
        let waiting = manager.items.filter { $0.state == .queued }.count
        guard !active.isEmpty || waiting > 0 else { return "\(manager.items.count) downloads" }
        var parts = ["\(active.count) downloading"]
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if !active.isEmpty { parts.append(ByteFormat.speed(active.reduce(0) { $0 + $1.speed })) }
        return parts.joined(separator: " · ")
    }

    private func columnBinding(_ column: DownloadColumn) -> Binding<Bool> {
        Binding(
            get: { MainActor.assumeIsolated { Prefs.downloadColumns.contains(column) } },
            set: { on in
                MainActor.assumeIsolated {
                    var columns = Prefs.downloadColumns.filter { $0 != column }
                    if on { columns.append(column) }
                    Prefs.downloadColumns = DownloadColumn.allCases.filter(columns.contains)
                }
            }
        )
    }

    private func buttonBinding(_ button: DownloadButton) -> Binding<Bool> {
        Binding(
            get: { MainActor.assumeIsolated { Prefs.downloadButtons.contains(button) } },
            set: { on in
                MainActor.assumeIsolated {
                    var buttons = Prefs.downloadButtons.filter { $0 != button }
                    if on { buttons.append(button) }
                    Prefs.downloadButtons = DownloadButton.allCases.filter(buttons.contains)
                }
            }
        )
    }

    private func add() {
        if manager.add(link, queue: queueFilter) != nil {
            link = ""
            problem = nil
        } else {
            problem = "That isn't a web (http/https) or FTP link."
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var manager: DownloadManager
    let columns: [DownloadColumn]
    let buttons: [DownloadButton]

    var body: some View {
        HStack(spacing: 10) {
            fileIcon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if [.downloading, .paused, .queued].contains(item.state) {
                    if let progress = item.progress {
                        ProgressView(value: progress).progressViewStyle(.linear)
                    } else if item.state == .downloading {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(Self.details(for: item, columns: columns, queue: manager.queues.count > 1 ? manager.queue(of: item).name : nil))
                    .font(.system(size: 11))
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            buttonRow
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
            if manager.queues.count > 1 {
                Menu("Move to Queue") {
                    ForEach(manager.queues) { queue in
                        Button(queue.name) { manager.move(item.id, to: queue.id) }
                            .disabled(manager.queue(of: item).id == queue.id)
                    }
                }
            }
            Button("Remove", role: .destructive) { manager.remove(item.id) }
        }
    }

    @ViewBuilder
    private var fileIcon: some View {
        if item.state == .completed, let path = item.finalPath {
            // Finished files can be dragged straight out of the list.
            DragOut(items: { [ShelfItem(kind: .file, path: path)] }) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            }
            .help("Drag the file out")
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data))
                .resizable()
        }
    }

    /// The line under the name, made of the columns chosen in the list's menu.
    static func details(for item: DownloadItem, columns: [DownloadColumn], queue: String?) -> String {
        var parts: [String] = []
        let show = Set(columns)
        switch item.state {
        case .downloading, .queued, .paused:
            if item.state == .queued { parts.append("Waiting") }
            if item.state == .paused { parts.append("Paused") }
            if show.contains(.size) {
                if let total = item.total {
                    parts.append("\(ByteFormat.size(item.received)) of \(ByteFormat.size(total))")
                } else if item.received > 0 {
                    parts.append(ByteFormat.size(item.received))
                }
            }
            if item.state == .downloading {
                if show.contains(.speed), item.speed > 0 { parts.append(ByteFormat.speed(item.speed)) }
                if show.contains(.timeLeft), let left = item.secondsLeft { parts.append(ByteFormat.timeLeft(left)) }
                if show.contains(.connections), item.connections > 1 { parts.append("\(item.connections) connections") }
            }
        case .completed:
            if show.contains(.size) { parts.append(ByteFormat.size(item.total ?? item.received)) }
            if let path = item.finalPath {
                parts.append((path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
        case .failed:
            parts.append(item.error ?? "Failed")
        }
        if show.contains(.queue), let queue { parts.append(queue) }
        if show.contains(.added) { parts.append(item.added.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var buttonRow: some View {
        HStack(spacing: 6) {
            if buttons.contains(.pauseResume) {
                switch item.state {
                case .downloading, .queued:
                    Button { manager.pause(item.id) } label: { Image(systemName: "pause.circle") }.help("Pause")
                case .paused, .failed:
                    Button { manager.resume(item.id) } label: { Image(systemName: "arrow.clockwise.circle") }.help("Resume")
                    if item.state == .failed, let page = item.pageURL {
                        // The video's link may have expired: open its page to start it again from there.
                        Button { DownloadsModule.openInChrome(page) } label: { Image(systemName: "safari") }
                            .help("Retry from the page (opens it in Chrome)")
                    }
                case .completed:
                    EmptyView()
                }
            }
            if item.state == .completed, let path = item.finalPath {
                if buttons.contains(.open) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Open")
                }
                if buttons.contains(.reveal) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .help("Show in Finder")
                }
            }
            if buttons.contains(.remove) {
                Button { manager.remove(item.id) } label: { Image(systemName: "xmark.circle") }
                    .help(item.state == .completed ? "Remove from list (the file stays)" : "Cancel and delete the partial file")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 17))
    }
}

struct DownloadsSettingsTab: View {
    @ObservedObject var manager: DownloadManager
    weak var module: DownloadsModule?
    @ObservedObject private var settings = SettingsStore.shared
    @State private var chromeReady = ChromeSetup.isInstalled
    @State private var catchExtensions = Prefs.downloadCatchExtensions.joined(separator: ", ")

    var body: some View {
        Group {
            Section {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text(Prefs.downloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                if !manager.queues.isEmpty {
                    LabeledContent("Downloads at once") {
                        AtOnceControl(limit: $manager.queues[0].maxAtOnce)
                    }
                }
                Toggle("Sort into a folder per type (see Categories below)",
                       isOn: settings.binding("downloads.sort", default: true))
                Picker("Connections per download", selection: settings.binding("downloads.connections", default: 8)) {
                    ForEach([1, 2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Retry when a connection fails", selection: settings.binding("downloads.retries", default: 5)) {
                    ForEach([0, 3, 5, 10], id: \.self) { Text($0 == 0 ? "Never" : "Up to \($0) times").tag($0) }
                }
                Toggle("Notify me when a download finishes", isOn: settings.binding("downloads.notify", default: true))
            } header: {
                Text("Downloads")
            } footer: {
                Text("No limit starts every download straight away, like IDM; with a number, the rest wait their turn. With many at once, Toolbelt shares connections out so all keep moving, joins at most two videos at a time, and pauses downloads if your Mac gets nearly full (they carry on once there's room). Big files are split into parts that download at the same time. Downloads carry on after a lost connection, sleep, a restart or a power cut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Speed limit", selection: settings.binding("downloads.speedLimitKB", default: 0)) {
                    Text("No limit").tag(0)
                    ForEach([256, 512, 1024, 2048, 5120, 10240], id: \.self) { kb in
                        Text(ByteFormat.speed(Double(kb) * 1024)).tag(kb)
                    }
                }
                Picker("Download at most", selection: settings.binding("downloads.hourlyCapMB", default: 0)) {
                    Text("No cap").tag(0)
                    ForEach([100, 500, 1024, 2048, 5120], id: \.self) { mb in
                        Text("\(ByteFormat.size(Int64(mb) * 1024 * 1024)) an hour").tag(mb)
                    }
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("Limits apply to all downloads together, so the rest of your internet stays quick. When the hourly amount is used up, downloads wait until the next hour.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            CategoriesSection()

            Section {
                Toggle("Offer to download links to files when I copy them", isOn: Binding(
                    get: { Prefs.downloadCatchClipboard },
                    set: { on in
                        Prefs.downloadCatchClipboard = on
                        module?.refreshClipboardCatching()
                    }))
                LabeledContent("For files ending in") {
                    TextField("", text: $catchExtensions, axis: .vertical)
                        .lineLimit(1...3)
                        .onSubmit { Prefs.downloadCatchExtensions = DownloadCategories.parseExtensions(catchExtensions) }
                }
                Button("Usual Extensions") {
                    Prefs.downloadCatchExtensions = ClipboardLinks.defaultExtensions
                    catchExtensions = Prefs.downloadCatchExtensions.joined(separator: ", ")
                }
            } header: {
                Text("Copied links")
            } footer: {
                Text("Copy a link to a file (a video, a PDF, a zip…) anywhere and a small “Download?” box appears in the top-right corner for 15 seconds. Copy several links at once and it offers the list to tick. “Download Link from Clipboard” in the menu-bar menu does the same whenever you like.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Site Grabber") {
                    Button("Open Site Grabber…") { module?.openGrabber() }
                }
            } footer: {
                Text("Downloads all the pictures, videos or files of a site, or saves the whole site to read offline. Also in the menu-bar menu, and in the launcher: paste a web address and pick “Grab Files from…”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($manager.queues) { $queue in
                    QueueRow(queue: $queue, isFirst: queue.id == manager.queues.first?.id) {
                        manager.removeQueue(queue.id)
                    }
                }
                Button("Add Queue") { _ = manager.addQueue(named: "Queue \(manager.queues.count + 1)") }
            } header: {
                Text("Queues")
            } footer: {
                Text("Each queue downloads a few files at a time and can start and stop by itself at set times, for example overnight. Right-click a download to move it to another queue. “When done” at the bottom of the Downloads window can sleep or shut down the Mac when everything has finished.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Google Chrome") {
                    HStack {
                        Text(chromeReady ? "Set up" : "Not set up").foregroundStyle(.secondary)
                        Button(chromeReady ? "Set Up Again…" : "Set Up Chrome…") {
                            ChromeSetup.setUpInteractively()
                            chromeReady = ChromeSetup.isInstalled
                        }
                    }
                }
            } header: {
                Text("Browser")
            } footer: {
                Text("The Toolbelt extension sends Chrome's downloads here, adds “Download with Toolbelt” and “Download All Links with Toolbelt” to the right-click menu, and puts a Download button on videos that can be downloaded (not on streamed or copy-protected ones). Its button in Chrome's toolbar can switch it off or skip small files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.downloadFolder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.downloadFolder = url
        }
    }
}

/// How many downloads run at once: "No limit" (like IDM), or a number from 1 to 50 on the slider.
struct AtOnceControl: View {
    @Binding var limit: Int
    @State private var lastNumber = 10

    var body: some View {
        HStack(spacing: 8) {
            Toggle("No limit", isOn: Binding(get: { limit <= 0 }, set: { limit = $0 ? 0 : lastNumber }))
                .toggleStyle(.checkbox)
            Slider(value: Binding(get: { Double(limit <= 0 ? lastNumber : limit) },
                                  set: { lastNumber = Int($0.rounded()); limit = lastNumber }),
                   in: 1...50, step: 1)
                .frame(minWidth: 120, maxWidth: 200)
                .disabled(limit <= 0)
            Text(limit <= 0 ? "All at once" : "\(limit) at a time")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
        }
        .onAppear { if limit > 0 { lastNumber = limit } }
    }
}

/// One queue in Settings: name, how many at once, and optional start and stop times.
struct QueueRow: View {
    @Binding var queue: DownloadQueue
    let isFirst: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $queue.name).labelsHidden().frame(maxWidth: 160)
                AtOnceControl(limit: $queue.maxAtOnce)
                Spacer()
                if !isFirst {
                    Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        .help("Delete this queue (its downloads move to the first queue)")
                }
            }
            HStack(spacing: 14) {
                timeToggle("Start at", minutes: $queue.startAt, fallback: 60)
                timeToggle("Stop at", minutes: $queue.stopAt, fallback: 7 * 60)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private func timeToggle(_ title: String, minutes: Binding<Int?>, fallback: Int) -> some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: Binding(
                get: { minutes.wrappedValue != nil },
                set: { minutes.wrappedValue = $0 ? fallback : nil }
            ))
            if minutes.wrappedValue != nil {
                DatePicker(title, selection: Binding(
                    get: { Calendar.current.date(bySettingHour: (minutes.wrappedValue ?? 0) / 60, minute: (minutes.wrappedValue ?? 0) % 60, second: 0, of: Date()) ?? Date() },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// 0.34: the file types, the extensions that make each one, and a folder of its own for any of them.
struct CategoriesSection: View {
    @State private var rules = Prefs.downloadCategories
    @State private var texts: [String: String] = [:]

    var body: some View {
        Section {
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(rule.name, systemImage: LinkPickerModel.symbol(for: rule.name)).font(.body.weight(.medium))
                        Spacer()
                        Text(folderText(rule)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Folder…") { chooseFolder(for: rule.name) }
                        if rule.folder != nil {
                            Button("Usual") { change(rule.name) { $0.folder = nil } }
                        }
                        if !DownloadCategories.defaults.contains(where: { $0.name == rule.name }) {
                            Button { rules.removeAll { $0.name == rule.name }; save() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if rule.name != DownloadCategories.otherName {
                        TextField("Extensions", text: Binding(
                            get: { texts[rule.name] ?? rule.extensionsText },
                            set: { texts[rule.name] = $0 }))
                            .font(.caption)
                            .onSubmit { commit(rule.name) }
                    } else {
                        Text("Everything that isn't in another category.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button("Add Category") {
                    var name = "New Category"
                    var n = 2
                    while rules.contains(where: { $0.name == name }) { name = "New Category \(n)"; n += 1 }
                    rules.insert(CategoryRule(name: name, extensions: []), at: max(0, rules.count - 1))
                    save()
                }
                Spacer()
                Button("Usual Categories") {
                    rules = DownloadCategories.defaults
                    texts = [:]
                    save()
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("A finished download goes to its category's own folder if it has one; otherwise into the downloads folder (inside a folder named after the category when sorting is on). Press Return after changing extensions. The first category with a file's extension wins.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func folderText(_ rule: CategoryRule) -> String {
        let folder = DownloadCategories.folder(for: "x." + (rule.extensions.first ?? "unknownext"), base: Prefs.downloadFolder,
                                               sortByType: Prefs.downloadSortByType, rules: rules)
        return folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func change(_ name: String, _ edit: (inout CategoryRule) -> Void) {
        guard let index = rules.firstIndex(where: { $0.name == name }) else { return }
        edit(&rules[index])
        save()
    }

    private func commit(_ name: String) {
        guard let text = texts[name] else { return }
        change(name) { $0.extensions = DownloadCategories.parseExtensions(text) }
        texts[name] = nil
    }

    private func save() {
        Prefs.downloadCategories = rules
        rules = Prefs.downloadCategories
    }

    private func chooseFolder(for name: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.downloadFolder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            change(name) { $0.folder = url.path }
        }
    }
}
