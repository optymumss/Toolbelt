import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A download manager: fast downloads in several parts at once, that pause, resume and survive restarts.
@MainActor
final class DownloadsModule: ToolbeltModule {
    let id = ModuleID.downloads
    let openTitle = "Downloads…"

    let manager = DownloadManager()
    private var window: NSWindow?

    func start() {
        manager.resumeInterrupted()
    }

    func stop() {
        manager.stopAll()
        window?.orderOut(nil)
    }

    func open() {
        if window == nil {
            let view = DownloadsView(manager: manager)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Downloads"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 440))
            window.center()
            window.setFrameAutosaveName("ToolbeltDownloads")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Starts a download from the link on the clipboard, if there is one.
    func downloadFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), manager.add(text) != nil {
            open()
        } else {
            NSSound.beep()
        }
    }

    func menuItems() -> [NSMenuItem] {
        var list: [NSMenuItem] = [ActionMenuItem("Download Link from Clipboard") { [weak self] in self?.downloadFromClipboard() }]
        let active = manager.items.filter { $0.state == .downloading }
        if !active.isEmpty {
            let total = active.reduce(0.0) { $0 + $1.speed }
            let status = NSMenuItem(title: "\(active.count) downloading · \(ByteFormat.speed(total))", action: nil, keyEquivalent: "")
            status.isEnabled = false
            list.append(status)
        }
        return list
    }

    func settingsView() -> AnyView {
        AnyView(DownloadsSettingsTab())
    }

    func willTerminate() {
        manager.stopAll()
    }

    private(set) lazy var launcherProvider: LauncherProvider? = DownloadsLauncherProvider(module: self)
}

/// Paste a link in the launcher to download it; search finished downloads by name.
@MainActor
final class DownloadsLauncherProvider: LauncherProvider {
    private weak var module: DownloadsModule?

    init(module: DownloadsModule) {
        self.module = module
    }

    func results(for query: String) -> [LauncherResult] {
        guard let module else { return [] }
        var results: [LauncherResult] = []
        if let url = DownloadManager.downloadableURL(from: query) {
            results.append(LauncherResult(
                id: "download:new", title: "Download \(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)",
                subtitle: url.absoluteString, kind: "Download", icon: .symbol("arrow.down.circle"), score: 300
            ) { [weak module] in
                module?.manager.add(url.absoluteString)
                module?.open()
            })
        }
        guard query.count >= 2 else { return results }
        for item in module.manager.items {
            let score = FuzzyMatch.score(query, item.name)
            guard score > 0 else { continue }
            let path = item.finalPath
            results.append(LauncherResult(
                id: "download:" + item.id.uuidString, title: item.name,
                subtitle: item.state == .completed ? (path ?? "") : "Downloading…",
                kind: "Download", icon: path.map { .image(NSWorkspace.shared.icon(forFile: $0)) } ?? .symbol("arrow.down.circle"),
                score: score * 0.9, revealURL: path.map { URL(fileURLWithPath: $0) }
            ) { [weak module] in
                if let path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } else { module?.open() }
            })
        }
        return results
    }
}

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @State private var link = ""
    @State private var problem: String?
    @State private var dropTargeted = false

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

            if manager.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No downloads yet").foregroundStyle(.secondary)
                    Text("Paste a link above, drop one here, or choose “Download Link from Clipboard” in the menu bar.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.items) { item in
                        DownloadRow(item: item, manager: manager)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { manager.clearFinished() }
                    .disabled(!manager.items.contains { $0.state == .completed })
                Button("Open Folder") { NSWorkspace.shared.open(Prefs.downloadFolder) }
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 320)
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .onDrop(of: [.url, .plainText], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                let add: @Sendable (String) -> Void = { text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { _ = manager.add(text) }
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

    private var summary: String {
        let active = manager.items.filter { $0.state == .downloading }
        guard !active.isEmpty else { return "\(manager.items.count) downloads" }
        return "\(active.count) downloading · \(ByteFormat.speed(active.reduce(0) { $0 + $1.speed }))"
    }

    private func add() {
        if manager.add(link) != nil {
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

    var body: some View {
        HStack(spacing: 10) {
            fileIcon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if item.state == .downloading || item.state == .paused {
                    if let progress = item.progress {
                        ProgressView(value: progress).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(status).font(.system(size: 11)).foregroundStyle(item.state == .failed ? Color.red : Color.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            buttons
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
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

    private var status: String {
        switch item.state {
        case .downloading:
            var parts: [String] = []
            if let total = item.total {
                parts.append("\(ByteFormat.size(item.received)) of \(ByteFormat.size(total))")
            } else {
                parts.append(ByteFormat.size(item.received))
            }
            if item.speed > 0 { parts.append(ByteFormat.speed(item.speed)) }
            if let left = item.secondsLeft { parts.append(ByteFormat.timeLeft(left)) }
            if item.connections > 1 { parts.append("\(item.connections) connections") }
            return parts.joined(separator: " · ")
        case .paused:
            return "Paused · \(ByteFormat.size(item.received))" + (item.total.map { " of \(ByteFormat.size($0))" } ?? "")
        case .completed:
            return "\(ByteFormat.size(item.total ?? item.received)) · \(item.finalPath.map { ($0 as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "")"
        case .failed:
            return item.error ?? "Failed"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            switch item.state {
            case .downloading:
                Button { manager.pause(item.id) } label: { Image(systemName: "pause.circle") }.help("Pause")
            case .paused, .failed:
                Button { manager.resume(item.id) } label: { Image(systemName: "arrow.clockwise.circle") }.help("Resume")
            case .completed:
                if let path = item.finalPath {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .help("Show in Finder")
                }
            }
            Button { manager.remove(item.id) } label: { Image(systemName: "xmark.circle") }
                .help(item.state == .completed ? "Remove from list (the file stays)" : "Cancel and delete the partial file")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 17))
    }
}

struct DownloadsSettingsTab: View {
    @ObservedObject private var settings = SettingsStore.shared

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
                Toggle("Sort into folders by type (Video, Music, Documents, Programs, Archives, Images)",
                       isOn: settings.binding("downloads.sort", default: true))
                Picker("Connections per download", selection: settings.binding("downloads.connections", default: 8)) {
                    ForEach([1, 2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Retry when a connection fails", selection: settings.binding("downloads.retries", default: 5)) {
                    ForEach([0, 3, 5, 10], id: \.self) { Text($0 == 0 ? "Never" : "Up to \($0) times").tag($0) }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Big files are split into parts that download at the same time; when a part finishes, its connection helps with the biggest part left. Downloads carry on after a lost connection, sleep, a restart or a power cut. FTP links use one connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
