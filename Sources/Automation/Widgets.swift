import AppKit
import SwiftUI
import WebKit

// 0.40: widgets made from web pages, like BetterTouchTool's floating web views: small always-on-top
// panels that show HTML you write, a web page, or what a shell script prints (as HTML), refreshed every
// so often. Your own HTML (and a script's) can run your macros with toolbelt.runMacro("Name") and Mac
// controls with toolbelt.control("volumeUp"); a web page from the internet can't. %Global_Name%
// variables are filled in. Saved in widgets.json.

struct WebWidget: Identifiable, Codable, Equatable {
    enum Source: String, Codable, CaseIterable, Identifiable {
        case html, address, script
        var id: String { rawValue }
        var title: String {
            switch self {
            case .html: return "My own HTML"
            case .address: return "A web page"
            case .script: return "What a shell script prints (HTML)"
            }
        }
    }

    var id = UUID()
    var name = "Widget"
    var source = Source.html
    var content = "<h2 style=\"font: 600 15px -apple-system\">Hello</h2>"
    /// Top-left corner in screen points, and size.
    var x = 80.0
    var y = 120.0
    var width = 260.0
    var height = 160.0
    /// Seconds between reloads (0: never).
    var refresh = 0.0
    var opacity = 1.0
    var showAtStart = false
    /// Clicks go through to whatever is underneath.
    var clickThrough = false
}

/// What a widget's page may ask Toolbelt to do. Pure, so it can be tested.
enum WidgetBridge {
    enum Command: Equatable {
        case runMacro(String)
        case control(SystemControl)
    }

    /// Only your own HTML and scripts may run things; a web page from the internet may not.
    static func allowed(_ source: WebWidget.Source) -> Bool { source != .address }

    static func command(from body: Any) -> Command? {
        guard let dict = body as? [String: Any] else { return nil }
        if let name = dict["macro"] as? String, !name.isEmpty { return .runMacro(name) }
        if let raw = dict["control"] as? String, let control = SystemControl(rawValue: raw) { return .control(control) }
        return nil
    }

    /// Added to every page that may use it.
    static let script = """
    window.toolbelt = {
      runMacro: function (name) { window.webkit.messageHandlers.toolbelt.postMessage({ macro: String(name) }); },
      control: function (name) { window.webkit.messageHandlers.toolbelt.postMessage({ control: String(name) }); }
    };
    """

    /// %Global_Name% filled in from the variables that last (unknown ones become empty).
    static func render(_ html: String, globals: (String) -> String) -> String {
        guard html.contains("%") else { return html }
        var result = ""
        var rest = Substring(html)
        while let start = rest.firstIndex(of: "%") {
            result += rest[..<start]
            let after = rest.index(after: start)
            if let end = rest[after...].firstIndex(of: "%") {
                let name = String(rest[after..<end])
                if GlobalVariables.isGlobal(name), !name.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) {
                    result += globals(name)
                    rest = rest[rest.index(after: end)...]
                    continue
                }
            }
            result += "%"
            rest = rest[after...]
        }
        return result + rest
    }

    /// The page wrapped so it looks at home on a Mac (system font, clear background, dark mode).
    static func page(_ body: String) -> String {
        if body.range(of: "<html", options: .caseInsensitive) != nil { return body }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 10px; font: 13px -apple-system, sans-serif; background: transparent; }
        </style></head><body>\(body)</body></html>
        """
    }
}

@MainActor
final class WidgetStore: ObservableObject {
    @Published var widgets: [WebWidget] = [] { didSet { if widgets != oldValue { save(); onChange?() } } }
    var onChange: (() -> Void)?
    static var file: URL { SettingsStore.folder.appendingPathComponent("widgets.json") }

    init() {
        reload()
        EverythingSync.shared.register("Widgets", file: Self.file) { [weak self] in self?.reload() }
    }

    func reload() {
        let loaded = ((try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([WebWidget].self, from: $0) }) ?? []
        if loaded != widgets { widgets = loaded }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(widgets) { try? data.write(to: Self.file, options: .atomic) }
    }
}

/// A panel that can be clicked without Toolbelt coming to the front.
private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class WidgetController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let store = WidgetStore()
    private var panels: [UUID: (panel: NSPanel, web: WKWebView, timer: Timer?)] = [:]
    /// The text each showing widget displays (for the real-use test).
    private(set) var texts: [String: String] = [:]
    var runMacro: ((String) -> Void)?
    var runControl: ((SystemControl) -> Void)?

    func start() {
        store.onChange = { [weak self] in self?.refreshShowing() }
        for widget in store.widgets where widget.showAtStart { show(widget) }
    }

    func stop() {
        for id in Array(panels.keys) { hide(id) }
    }

    var showingNames: [String] { store.widgets.filter { panels[$0.id] != nil }.map(\.name) }

    func toggle(named name: String) {
        guard let widget = store.widgets.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else { return }
        panels[widget.id] != nil ? hide(widget.id) : show(widget)
    }

    func show(named name: String) {
        guard let widget = store.widgets.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else { return }
        show(widget)
    }

    func hide(named name: String) {
        if let widget = store.widgets.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) { hide(widget.id) }
    }

    func show(_ widget: WebWidget) {
        hide(widget.id)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 900
        let frame = NSRect(x: widget.x, y: screenHeight - widget.y - widget.height, width: max(80, widget.width), height: max(40, widget.height))
        let panel = WidgetPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless, .utilityWindow, .resizable],
                                backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.alphaValue = CGFloat(min(1, max(0.2, widget.opacity)))
        panel.ignoresMouseEvents = widget.clickThrough
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = widget.name
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        let configuration = WKWebViewConfiguration()
        if WidgetBridge.allowed(widget.source) {
            configuration.userContentController.add(self, name: "toolbelt")
            configuration.userContentController.addUserScript(WKUserScript(source: WidgetBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // A thin edge is left around the page, to drag the widget by.
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size).insetBy(dx: 6, dy: 6), configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        background.addSubview(web)
        panel.contentView = background

        var timer: Timer?
        if widget.refresh > 0 {
            let id = widget.id
            let repeating = Timer(timeInterval: max(1, widget.refresh), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.load(id) }
            }
            RunLoop.main.add(repeating, forMode: .common)
            timer = repeating
        }
        panels[widget.id] = (panel, web, timer)
        panel.orderFrontRegardless()
        load(widget.id)
        RealUseHooks.writeStatus()
    }

    func hide(_ id: UUID) {
        guard let entry = panels.removeValue(forKey: id) else { return }
        entry.timer?.invalidate()
        entry.web.configuration.userContentController.removeScriptMessageHandler(forName: "toolbelt")
        entry.panel.orderOut(nil)
        if let name = store.widgets.first(where: { $0.id == id })?.name { texts[name] = nil }
        RealUseHooks.writeStatus()
    }

    /// After a widget is edited: show the change in the ones that are showing.
    private func refreshShowing() {
        for (id, _) in panels {
            if let widget = store.widgets.first(where: { $0.id == id }) { show(widget) } else { hide(id) }
        }
    }

    func load(_ id: UUID) {
        guard let widget = store.widgets.first(where: { $0.id == id }), let web = panels[id]?.web else { return }
        let globals: (String) -> String = { GlobalVariables.shared.value($0) }
        switch widget.source {
        case .html:
            web.loadHTMLString(WidgetBridge.page(WidgetBridge.render(widget.content, globals: globals)), baseURL: nil)
        case .address:
            if let url = ActionRunner.url(from: widget.content) { web.load(URLRequest(url: url)) }
        case .script:
            let script = widget.content
            Task { [weak self] in
                let result = await MacroRun.runProcess("/bin/zsh", ["-lc", script], environment: [:], timeout: 30)
                guard let self, let web = self.panels[id]?.web else { return }
                web.loadHTMLString(WidgetBridge.page(WidgetBridge.render(result.output, globals: globals)), baseURL: nil)
            }
        }
    }

    // MARK: Delegates

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated {
            guard let command = WidgetBridge.command(from: body) else { return }
            switch command {
            case .runMacro(let name): runMacro?(name)
            case .control(let control): runControl?(control)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard let id = panels.first(where: { $0.value.web === webView })?.key,
                  let name = store.widgets.first(where: { $0.id == id })?.name else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    self?.texts[name] = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    RealUseHooks.writeStatus()
                }
            }
        }
    }

    /// Dragged or resized: remember where.
    nonisolated func windowDidMove(_ notification: Notification) { remember(notification) }
    nonisolated func windowDidEndLiveResize(_ notification: Notification) { remember(notification) }

    private nonisolated func remember(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        MainActor.assumeIsolated {
            guard let id = panels.first(where: { $0.value.panel === panel })?.key,
                  let index = store.widgets.firstIndex(where: { $0.id == id }) else { return }
            let screenHeight = NSScreen.screens.first?.frame.height ?? 900
            let frame = panel.frame
            var widget = store.widgets[index]
            widget.x = frame.minX
            widget.y = screenHeight - frame.maxY
            widget.width = frame.width
            widget.height = frame.height
            // Saved quietly: the panel is already where it should be.
            let onChange = store.onChange
            store.onChange = nil
            store.widgets[index] = widget
            store.onChange = onChange
        }
    }

    func registerTestHooks() {
        RealUseHooks.commands["widget-show"] = { [weak self] name in self?.show(named: name) }
        RealUseHooks.commands["widget-hide"] = { [weak self] name in self?.hide(named: name) }
        RealUseHooks.commands["widgets-reload"] = { [weak self] _ in self?.store.reload() }
        // "Name|javascript": runs a script in the widget, like a click on one of its buttons.
        RealUseHooks.commands["widget-js"] = { [weak self] text in
            let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let self,
                  let widget = self.store.widgets.first(where: { $0.name == parts[0] }), let web = self.panels[widget.id]?.web else { return }
            web.evaluateJavaScript(parts[1], completionHandler: nil)
        }
        RealUseHooks.extraStatus["widgets"] = { [weak self] in self?.texts ?? [:] }
    }
}

// MARK: - Settings

struct WidgetSettings: View {
    @ObservedObject var store: WidgetStore
    let controller: WidgetController
    @State private var editing: UUID?

    var body: some View {
        Section {
            ForEach($store.widgets) { $widget in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $widget.name)
                        Button("Show / Hide") { controller.toggle(named: widget.name) }
                        Button(editing == widget.id ? "Done" : "Edit") { editing = editing == widget.id ? nil : widget.id }
                        Button { store.widgets.removeAll { $0.id == widget.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    if editing == widget.id {
                        Picker("Shows", selection: $widget.source) {
                            ForEach(WebWidget.Source.allCases) { Text($0.title).tag($0) }
                        }
                        if widget.source == .address {
                            TextField("Web address", text: $widget.content)
                        } else {
                            TextEditor(text: $widget.content)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 70, maxHeight: 140)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        }
                        HStack {
                            Picker("Reload", selection: $widget.refresh) {
                                Text("Never").tag(0.0)
                                Text("Every 5 seconds").tag(5.0)
                                Text("Every minute").tag(60.0)
                                Text("Every 15 minutes").tag(900.0)
                                Text("Every hour").tag(3600.0)
                            }
                            .fixedSize()
                            Slider(value: $widget.opacity, in: 0.3...1) { Text("Opacity") }.frame(maxWidth: 180)
                        }
                        HStack {
                            Toggle("Show when Toolbelt starts", isOn: $widget.showAtStart)
                            Toggle("Clicks go through it", isOn: $widget.clickThrough)
                        }
                    }
                }
            }
            Menu("Add Widget") {
                Button("Clock") {
                    add(WebWidget(name: "Clock", content: "<div id=\"t\" style=\"font: 600 34px -apple-system; text-align: center\"></div><script>setInterval(() => t.textContent = new Date().toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'}), 1000); t.textContent = new Date().toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'})</script>", height: 90))
                }
                Button("Buttons for my macros") {
                    add(WebWidget(name: "Macro buttons", content: "<button onclick=\"toolbelt.runMacro('My macro')\">My macro</button>\n<button onclick=\"toolbelt.control('playPause')\">⏯</button>"))
                }
                Button("Output of a script") {
                    add(WebWidget(name: "Disk space", source: .script, content: "echo \"<b>Free:</b> $(df -h / | awk 'NR==2{print $4}')\"", height: 80, refresh: 60))
                }
                Button("A web page") { add(WebWidget(name: "Web page", source: .address, content: "https://example.com", width: 380, height: 300)) }
            }
            .fixedSize()
        } header: {
            Text("Widgets")
        } footer: {
            Text("Small always-on-top panels made from a web page: your own HTML, a web address, or the HTML a shell script prints. Drag one by its edge to move it; its place and size are kept. In your own HTML, a button can run a macro with toolbelt.runMacro('Name') or a Mac control with toolbelt.control('volumeUp'), and %Global_Name% shows a variable. Show or hide one from any trigger with “Show / hide a widget”.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add(_ widget: WebWidget) {
        store.widgets.append(widget)
        editing = widget.id
    }
}
