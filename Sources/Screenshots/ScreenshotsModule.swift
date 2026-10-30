import AppKit
import SwiftUI

/// What happens straight after a screenshot is taken.
enum AfterCapture: String, CaseIterable, Identifiable {
    case edit, copy, save

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: return "Open it to mark up"
        case .copy: return "Copy it"
        case .save: return "Save it to the folder"
        }
    }
}

/// Screenshots of an area, a window or the whole screen, a mark-up editor, and reading text off the screen.
@MainActor
final class ScreenshotsModule: ToolbeltModule {
    let id = ModuleID.screenshots
    let openTitle = "Take Screenshot of Area…"

    private var editors: [ScreenshotEditorWindow] = []
    private var capturing = false

    init(shortcuts: ShortcutCenter) {
        shortcuts.setHandler(for: .captureArea) { [weak self] in self?.capture(.area) }
        shortcuts.setHandler(for: .captureWindow) { [weak self] in self?.capture(.window) }
        shortcuts.setHandler(for: .captureScreen) { [weak self] in self?.capture(.screen) }
        shortcuts.setHandler(for: .captureText) { [weak self] in self?.captureText() }
    }

    // Nothing runs in the background: the module only does something when you ask.
    func start() {}

    func stop() {
        for editor in editors { editor.window.close() }
        editors = []
    }

    func open() {
        capture(.area)
    }

    func capture(_ mode: CaptureMode) {
        guard !capturing, PermissionGate.ensure(.screenRecording, to: "take screenshots") else { return }
        capturing = true
        Task {
            let file = await ScreenshotCapture.capture(mode)
            capturing = false
            guard let file else { return } // cancelled with Esc
            defer { try? FileManager.default.removeItem(at: file) }
            guard let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            handle(image)
        }
    }

    /// Takes the screenshot through the editor model, so copy and save work the same everywhere.
    func handle(_ image: CGImage) {
        switch Prefs.screenshotAfterCapture {
        case .edit:
            edit(image)
        case .copy:
            ScreenshotEditorModel(image: image).copyImage()
            NSSound(named: "Pop")?.play()
        case .save:
            ScreenshotEditorModel(image: image).save()
            NSSound(named: "Pop")?.play()
        }
    }

    @discardableResult
    func edit(_ image: CGImage) -> ScreenshotEditorWindow {
        let editor = ScreenshotEditorWindow(image: image)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.show()
        return editor
    }

    /// Drag out an area; its text is copied straight away (no editor).
    func captureText() {
        guard !capturing, PermissionGate.ensure(.screenRecording, to: "read text on the screen") else { return }
        capturing = true
        Task {
            let file = await ScreenshotCapture.capture(.area)
            capturing = false
            guard let file else { return }
            defer { try? FileManager.default.removeItem(at: file) }
            let text = await ImageText.recognize(at: file)
            if text.isEmpty {
                NSSound.beep()
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                NSSound(named: "Pop")?.play()
            }
        }
    }

    func menuItems() -> [NSMenuItem] {
        [
            ActionMenuItem("Take Screenshot of Window…") { [weak self] in self?.capture(.window) },
            ActionMenuItem("Take Screenshot of Screen") { [weak self] in self?.capture(.screen) },
            ActionMenuItem("Copy Text from Screen…") { [weak self] in self?.captureText() },
        ]
    }

    func settingsView() -> AnyView {
        AnyView(ScreenshotsSettingsTab())
    }

    func willTerminate() {}

    private(set) lazy var launcherProvider: LauncherProvider? = ScreenshotsLauncherProvider(module: self)
}

@MainActor
final class ScreenshotsLauncherProvider: LauncherProvider {
    private weak var module: ScreenshotsModule?

    init(module: ScreenshotsModule) {
        self.module = module
    }

    func results(for query: String) -> [LauncherResult] {
        guard let module, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let commands: [(String, String, String, () -> Void)] = [
            ("Screenshot of Area", "screenshot capture area region", "camera.viewfinder", { [weak module] in module?.capture(.area) }),
            ("Screenshot of Window", "screenshot capture window", "macwindow", { [weak module] in module?.capture(.window) }),
            ("Screenshot of Screen", "screenshot capture screen full", "display", { [weak module] in module?.capture(.screen) }),
            ("Copy Text from Screen", "ocr text copy screen read", "text.viewfinder", { [weak module] in module?.captureText() }),
        ]
        return commands.compactMap { title, words, symbol, action in
            let score = max(FuzzyMatch.score(query, title), FuzzyMatch.score(query, words) * 0.8)
            guard score > 0 else { return nil }
            // The launcher closes first, so it isn't in the picture.
            return LauncherResult(id: "screenshot:" + title, title: title, kind: "Screenshot", icon: .symbol(symbol), score: score) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { action() }
            }
        }
    }
}

struct ScreenshotsSettingsTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Group {
            Section {
                Picker("After taking a screenshot", selection: settings.binding("screenshots.after", default: AfterCapture.edit.rawValue)) {
                    ForEach(AfterCapture.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Save screenshots to") {
                    HStack {
                        Text(Prefs.screenshotFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            } header: {
                Text("Screenshots")
            } footer: {
                Text("⌥⇧⌘4 an area, ⌥⇧⌘5 a window, ⌥⇧⌘3 the whole screen, ⌥⇧⌘2 copies the text in an area. (Change them in the Shortcuts tab.) In the editor: arrows, boxes, text, highlight, blur and crop, then Copy, Save or Copy Text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.screenshotFolder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.screenshotFolder = url
        }
    }
}
