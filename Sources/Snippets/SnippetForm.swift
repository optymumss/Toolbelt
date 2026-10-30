import AppKit
import SwiftUI

/// Asks for the blanks in a fill-in snippet ({input:Name}) before it's typed.
@MainActor
final class SnippetFormController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var completion: (([String: String]?) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func ask(title: String, fields: [(name: String, defaultValue: String)], completion: @escaping ([String: String]?) -> Void) {
        finish(nil) // only one form at a time
        self.completion = completion
        let view = SnippetFormView(title: title, fields: fields) { [weak self] values in self?.finish(values) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Fill in the blanks"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 380, height: 160))
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ values: [String: String]?) {
        let completion = self.completion
        self.completion = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        completion?(values)
    }
}

struct SnippetFormView: View {
    let title: String
    let fields: [(name: String, defaultValue: String)]
    var onDone: ([String: String]?) -> Void
    @State private var values: [String] = []
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.name).font(.caption).foregroundStyle(.secondary)
                    TextField(field.name, text: binding(index))
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: index)
                        .onSubmit { index == fields.count - 1 ? submit() : (focused = index + 1) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            values = fields.map(\.defaultValue)
            focused = 0
        }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: { values.indices.contains(index) ? values[index] : "" },
            set: { if values.indices.contains(index) { values[index] = $0 } }
        )
    }

    private func submit() {
        var result: [String: String] = [:]
        for (index, field) in fields.enumerated() {
            result[field.name] = values.indices.contains(index) ? values[index] : field.defaultValue
        }
        onDone(result)
    }
}
