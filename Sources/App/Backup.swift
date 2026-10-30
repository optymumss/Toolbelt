import AppKit
import UniformTypeIdentifiers

/// Exports and imports all of Toolbelt's settings as one file, to keep a backup
/// or move to a new Mac. Clipboard history and downloads aren't included.
enum Backup {
    /// The files in the data folder that hold settings (not history or downloaded data).
    static let files = ["settings.plist", "snippets.json", "shelves.json", "macros.json", "notes.json",
                        "pinboards.json", "namedclipboards.json", "launcher-usage.json", "layouts.json", "gestures.json", "droptargets.json"]
    static let fileExtension = "toolbelt"

    /// Everything in one property list: the format version and each file's contents.
    static func export(from folder: URL = SettingsStore.folder) throws -> Data {
        var contents: [String: Data] = [:]
        for name in files {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
                contents[name] = data
            }
        }
        let backup: [String: Any] = ["format": 1, "created": Date(), "files": contents]
        return try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
    }

    enum ImportError: LocalizedError {
        case notABackup
        var errorDescription: String? { "That file isn't a Toolbelt settings backup." }
    }

    /// Writes a backup's files into the data folder. Returns the names of the files restored.
    @discardableResult
    static func restore(_ data: Data, into folder: URL = SettingsStore.folder) throws -> [String] {
        guard let backup = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              backup["format"] as? Int == 1,
              let contents = backup["files"] as? [String: Data] else { throw ImportError.notABackup }
        var restored: [String] = []
        for (name, fileData) in contents where files.contains(name) {
            try fileData.write(to: folder.appendingPathComponent(name), options: .atomic)
            restored.append(name)
        }
        return restored.sorted()
    }

    // MARK: With the user

    @MainActor
    static func exportInteractively() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Toolbelt Settings.\(fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
        panel.message = "Save all of Toolbelt's settings, snippets, quicklinks and shelves in one file."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export().write(to: url, options: .atomic)
        } catch {
            SystemActions.showProblem("Couldn't save the settings", error.localizedDescription)
        }
    }

    @MainActor
    static func importInteractively() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
        panel.message = "Choose a Toolbelt settings file. Your current settings will be replaced."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let confirm = NSAlert()
        confirm.messageText = "Replace your settings with this backup?"
        confirm.informativeText = "Toolbelt will restart to use them. Your clipboard history and downloads aren't affected."
        confirm.addButton(withTitle: "Replace and Restart")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try restore(Data(contentsOf: url))
            relaunch()
        } catch {
            SystemActions.showProblem("Couldn't import the settings", error.localizedDescription)
        }
    }

    /// Starts a fresh copy of Toolbelt and quits this one, so it reads the restored files.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
