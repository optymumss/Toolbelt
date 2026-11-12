import AppKit
import SwiftUI

// 0.36: variables that last. A variable whose name starts with Global_ (like Keyboard Maestro's global
// variables) is shared by every macro and kept between runs and restarts, in variables.json. The
// Variables window shows them and lets you change or delete them.

@MainActor
final class GlobalVariables: ObservableObject {
    static let shared = GlobalVariables()
    nonisolated static let prefix = "global_"

    @Published private(set) var values: [String: String] = [:]
    private var saveScheduled = false

    static var file: URL { SettingsStore.folder.appendingPathComponent("variables.json") }

    nonisolated static func isGlobal(_ name: String) -> Bool {
        name.count > prefix.count && name.lowercased().hasPrefix(prefix)
    }

    init() {
        reload()
    }

    func reload() {
        values = ((try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
    }

    /// Names are matched ignoring case (Global_Count and global_count are the same variable).
    private func key(for name: String) -> String {
        values.keys.first { $0.compare(name, options: .caseInsensitive) == .orderedSame } ?? name
    }

    func value(_ name: String) -> String { values[key(for: name)] ?? "" }

    func set(_ name: String, _ value: String) {
        values[key(for: name)] = value
        save()
    }

    func remove(_ name: String) {
        values[key(for: name)] = nil
        save()
    }

    /// Written after the current step, so a loop setting a variable a thousand times writes it once.
    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                self.saveNow()
            }
        }
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(values) { try? data.write(to: Self.file, options: .atomic) }
        RealUseHooks.writeStatus()
    }

    var sortedNames: [String] { values.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
}

struct VariablesView: View {
    @ObservedObject var store = GlobalVariables.shared
    @State private var newName = "Global_"
    @State private var newValue = ""
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Variables that last").font(.headline)
            Text("A variable whose name starts with Global_ is shared by every macro and kept between runs and restarts. Use it like any other: %Global_Count%. Others last only while their macro runs.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(store.sortedNames.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                    HStack(alignment: .firstTextBaseline) {
                        Text(name).font(.system(.body, design: .monospaced)).frame(width: 180, alignment: .leading).lineLimit(1)
                        TextField("Value", text: Binding(get: { store.value(name) }, set: { store.set(name, $0) }), axis: .vertical)
                            .lineLimit(1...4)
                        Button { store.remove(name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Delete this variable")
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if store.values.isEmpty {
                    Text("None yet. A macro step like “Set a variable” with a name starting Global_ makes one.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            HStack {
                TextField("Name", text: $newName).frame(width: 180)
                TextField("Value", text: $newValue)
                Button("Add") {
                    var name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
                    if !GlobalVariables.isGlobal(name) { name = "Global_" + name }
                    store.set(name, newValue)
                    newName = "Global_"
                    newValue = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: GlobalVariables.prefix, with: "").isEmpty)
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 360)
    }
}

@MainActor
enum VariablesWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Macro Variables"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: VariablesView())
            window.setContentSize(NSSize(width: 600, height: 420))
            window.center()
            window.setFrameAutosaveName("ToolbeltVariables")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
