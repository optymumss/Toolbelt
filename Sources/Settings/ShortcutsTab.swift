import AppKit
import Carbon
import SwiftUI

struct ShortcutsTab: View {
    @ObservedObject var modules: ModuleManager
    @ObservedObject var shortcuts: ShortcutCenter

    var body: some View {
        Form {
            ForEach(ModuleID.allCases) { module in
                Section {
                    ForEach(ShortcutAction.allCases.filter { $0.module == module }) { action in
                        LabeledContent(action.title) {
                            ShortcutRecorder(action: action, shortcuts: shortcuts)
                        }
                    }
                } header: {
                    HStack {
                        Text(module.title)
                        if !modules.isEnabled(module) {
                            Text("(turned off)").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
            } footer: {
                Text("Click a shortcut, then press the new keys. Include ⌘, ⌥ or ⌃. Press esc to cancel. Toolbelt tells you if the keys are already used by macOS, another app, or another Toolbelt shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Listens for the next key press while recording a shortcut.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var recording = false
    @Published var message: String?

    private let action: ShortcutAction
    private let shortcuts: ShortcutCenter
    private var monitor: Any?

    init(action: ShortcutAction, shortcuts: ShortcutCenter) {
        self.action = action
        self.shortcuts = shortcuts
    }

    func start() {
        guard !recording else { return }
        message = nil
        recording = true
        shortcuts.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func cancel() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        shortcuts.resume()
    }

    func clear() {
        cancel()
        message = shortcuts.assign(nil, to: action)
    }

    func reset() {
        cancel()
        message = shortcuts.resetToDefault(action)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let shortcut = Shortcut(event: event)
        if Int(shortcut.keyCode) == kVK_Escape, shortcut.modifiers == 0 {
            cancel()
            return true
        }
        guard shortcut.isUsable else {
            message = "Include ⌘, ⌥ or ⌃, for example ⌘⇧V."
            return true
        }
        cancel()
        message = shortcuts.assign(shortcut, to: action)
        return true
    }
}

struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject var shortcuts: ShortcutCenter
    @StateObject private var model: ShortcutRecorderModel

    init(action: ShortcutAction, shortcuts: ShortcutCenter) {
        self.action = action
        self.shortcuts = shortcuts
        _model = StateObject(wrappedValue: ShortcutRecorderModel(action: action, shortcuts: shortcuts))
    }

    var body: some View {
        let current = shortcuts.shortcut(for: action)

        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    model.recording ? model.cancel() : model.start()
                } label: {
                    Text(model.recording ? "Press new shortcut…" : (current?.display ?? "None"))
                        .font(.system(.body, design: .rounded))
                        .frame(minWidth: 130)
                }
                .help("Click, then press the keys you want")

                if current != nil {
                    Button { model.clear() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this shortcut")
                }
                if current != action.defaultShortcut {
                    Button { model.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Go back to \(action.defaultShortcut?.display ?? "no shortcut")")
                }
            }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 300, alignment: .trailing)
            } else if shortcuts.failed.contains(action) {
                Text("Not working: another app already uses these keys. Pick a different shortcut.")
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
        }
        .onDisappear { model.cancel() }
    }
}
