import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A tile in the drop-target grid, like Dropzone.
struct DropTarget: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case folder, app, website, zipToDesktop, copyPaths, newShelf
    }

    var id = UUID()
    var kind: Kind
    var name: String
    /// Folder or app location, or the website address.
    var target: String = ""
    /// For folders: copy (true) or move (false) dropped files.
    var copies = true

    var symbol: String {
        switch kind {
        case .folder: return copies ? "folder.badge.plus" : "folder"
        case .app: return "app"
        case .website: return "globe"
        case .zipToDesktop: return "doc.zipper"
        case .copyPaths: return "doc.on.doc"
        case .newShelf: return "tray.and.arrow.down"
        }
    }

    var detail: String {
        switch kind {
        case .folder: return (copies ? "Copy to " : "Move to ") + (target as NSString).abbreviatingWithTildeInPath
        case .app: return "Open with " + ((target as NSString).lastPathComponent as NSString).deletingPathExtension
        case .website: return target
        case .zipToDesktop: return "Zip onto the Desktop"
        case .copyPaths: return "Copy the files' paths"
        case .newShelf: return "Put on a new shelf"
        }
    }

    static let defaults: [DropTarget] = [
        DropTarget(kind: .folder, name: "Documents", target: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path),
        DropTarget(kind: .zipToDesktop, name: "Zip"),
        DropTarget(kind: .copyPaths, name: "Copy Paths"),
        DropTarget(kind: .newShelf, name: "Shelf"),
    ]
}

@MainActor
final class DropTargetStore: ObservableObject {
    @Published var targets: [DropTarget] {
        didSet { if targets != oldValue { save() } }
    }
    private let file = SettingsStore.folder.appendingPathComponent("droptargets.json")

    init() {
        targets = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([DropTarget].self, from: $0) } ?? DropTarget.defaults
    }

    private func save() {
        try? JSONEncoder().encode(targets).write(to: file, options: .atomic)
    }
}

/// What dropping files on a target (or using its shortcut) does.
@MainActor
enum DropTargetRunner {
    /// Returns the files that were made or moved (for checking), or nil if nothing happened.
    @discardableResult
    static func run(_ target: DropTarget, files: [URL], newShelf: ([URL]) -> Void = { _ in }) -> [URL]? {
        let fm = FileManager.default
        switch target.kind {
        case .folder:
            let folder = URL(fileURLWithPath: target.target, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let results = files.compactMap { file -> URL? in
                let destination = ShelfStore.unusedURL(for: file.lastPathComponent, in: folder)
                do {
                    if target.copies { try fm.copyItem(at: file, to: destination) } else { try fm.moveItem(at: file, to: destination) }
                    return destination
                } catch {
                    return nil
                }
            }
            return results.isEmpty ? nil : results
        case .app:
            let app = URL(fileURLWithPath: target.target)
            if files.isEmpty {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            } else {
                NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            return files
        case .website:
            if let url = URL(string: target.target) { NSWorkspace.shared.open(url) }
            return []
        case .zipToDesktop:
            let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "Archive"
            return ShelfActions.zip(files, into: desktop, name: name).map { [$0] }
        case .copyPaths:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            return files
        case .newShelf:
            newShelf(files)
            return files
        }
    }

    /// The files selected in Finder (for a target's keyboard shortcut). Asks Finder, which macOS
    /// may ask you to allow the first time.
    static func finderSelection() -> [URL] {
        let script = """
        tell application "Finder" to set theSelection to selection as alias list
        set thePaths to {}
        repeat with anItem in theSelection
            set end of thePaths to POSIX path of anItem
        end repeat
        set AppleScript's text item delimiters to linefeed
        return thePaths as text
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard error == nil, let text = result?.stringValue, !text.isEmpty else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// The floating grid of drop targets.
@MainActor
final class DropGridController {
    private let store: DropTargetStore
    private var panel: NSPanel?
    var newShelf: ([URL]) -> Void = { _ in }

    init(store: DropTargetStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 30, y: screen.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let view = DropGridView(store: store, run: { [weak self] target, files in
            DropTargetRunner.run(target, files: files, newShelf: self?.newShelf ?? { _ in })
        }, close: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Drop Targets"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        return panel
    }
}

struct DropGridView: View {
    @ObservedObject var store: DropTargetStore
    var run: (DropTarget, [URL]) -> Void
    var close: () -> Void
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drop files on a target").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 10), count: 3), spacing: 10) {
                ForEach(store.targets) { target in
                    VStack(spacing: 6) {
                        Image(systemName: target.symbol).font(.system(size: 26))
                        Text(target.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(target.detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(width: 104, height: 96)
                    .background(RoundedRectangle(cornerRadius: 10).fill(hovered == target.id ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06)))
                    .onTapGesture { run(target, []) }
                    .onDrop(of: [.fileURL], isTargeted: Binding(
                        get: { hovered == target.id },
                        set: { hovered = $0 ? target.id : (hovered == target.id ? nil : hovered) }
                    )) { providers in
                        load(providers) { files in run(target, files) }
                        return true
                    }
                    .help(target.detail)
                }
            }
        }
        .padding(14)
        .padding(.top, 18)
    }

    private final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var files: [URL] = []
    }

    private func load(_ providers: [NSItemProvider], then: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let collected = Collected()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                if let url = url as? URL {
                    collected.lock.lock()
                    collected.files.append(url)
                    collected.lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { then(collected.files) }
    }
}
