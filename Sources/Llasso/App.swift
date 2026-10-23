import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import LlassoKit

/// One system-wide hotkey via Carbon. Needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.instances[hk.id]?.onFire()
            return noErr
        }, 1, &type, nil, &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4C4C5353 /* 'LLSS' */), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.instances[id] = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let watcher = DragWatcher()
    private var offer: Offer?
    private var gestureRetry: Timer?
    private var statusTimer: Timer?
    /// Menu items for the task list carry this tag so they can be rebuilt each time.
    private static let taskTag = 77

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage.llassoMark()
        let menu = NSMenu()
        menu.addItem(withTitle: "Draw a box   ⌃⌥S", action: #selector(draw), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Show history", action: #selector(history), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Llasso", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        item.menu = menu
        statusItem = item
        item.button?.imagePosition = .imageLeading
        // The menu bar icon shows how many jobs are running or waiting on the user.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey)) {
            DispatchQueue.main.async { Controller.shared.toggle() }
        }

        // Any box-shaped drag offers the Llasso icon where it ended.
        let offer = Offer()
        offer.onOpen = { Controller.shared.begin(box: $0) }
        offer.onHoldBegan = { Controller.shared.holdToTalk(box: $0) }
        offer.onHoldEnded = { Controller.shared.releaseToSend() }
        Controller.shared.offer = offer
        self.offer = offer
        watcher.onPress = { [weak self] p in self?.offer?.pressed(at: p) }
        watcher.onBox = { box, end in
            guard Controller.shared.phase == .idle,
                  !Sensitive.isSensitive(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            else { return }
            offer.show(box: box, near: end)
        }
        // A test run started from a terminal is charged to the terminal's permissions, not
        // Llasso's, so it can look ungranted; it must not open Settings or start the drag watcher.
        let testRun = CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("test") }
        // The tap needs Accessibility; keep trying until it is granted.
        if !testRun, !watcher.start() {
            gestureRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.watcher.start() == true { t.invalidate() }
            }
        }

        if !testRun, !Settings.shared.hasKey || !CGPreflightScreenCaptureAccess() {
            SettingsWindow.show()
        }
        // Dev hooks: `--draw` starts a box straight away; `--selftest` runs the
        // pipeline without the UI and writes the result to selftest.json.
        if CommandLine.arguments.contains("--draw") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Controller.shared.begin() }
        }
        if CommandLine.arguments.contains("--acttest") {
            Task { @MainActor in await SelfTest.act(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--pastetest") {
            Task { @MainActor in await SelfTest.pasteOver(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--fronttest") {
            Task { @MainActor in await SelfTest.front(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--looktest") {
            Task { @MainActor in await SelfTest.look(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--jobtest") {
            Task { @MainActor in await SelfTest.jobs(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--namedtest") {
            Task { @MainActor in await SelfTest.named(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--savetest") {
            Task { @MainActor in SelfTest.save(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--codetest") {
            Task { @MainActor in await SelfTest.code(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--mcptest") {
            Task { @MainActor in await SelfTest.mcp(); NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in await SelfTest.run(); NSApp.terminate(nil) }
        }
    }

    /// A menu-bar-only app has no menu bar of its own, so ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z have
    /// nothing to fire. This hidden main menu gives text fields their shortcuts back.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @MainActor private func refreshStatus() {
        let jobs = Controller.shared.jobs
        let running = jobs.filter(\.isRunning).count
        let waiting = jobs.filter { $0.needsYou && !$0.isRunning }.count
        let title = running + waiting == 0 ? "" : " \(running + waiting)"
        if statusItem?.button?.title != title {
            statusItem?.length = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
            statusItem?.button?.title = title
        }
        statusItem?.button?.contentTintColor = waiting > 0 ? Palette.gold : nil
    }

    /// Rebuild the task list each time the menu opens: one line per job, newest first.
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.items.filter { $0.tag == Self.taskTag }.forEach(menu.removeItem)
            let jobs = Controller.shared.jobs
            guard !jobs.isEmpty else { return }
            var at = 2   // after "Draw a box" and its separator
            func add(_ item: NSMenuItem) { item.tag = Self.taskTag; menu.insertItem(item, at: at); at += 1 }
            let header = NSMenuItem(title: "Tasks", action: nil, keyEquivalent: "")
            header.isEnabled = false
            add(header)
            for job in jobs.reversed() {
                let mark = job.isRunning ? "◐" : job.needsYou ? "●" : job.card.state == .failed ? "✕" : "✓"
                let what = job.isRunning ? (job.card.working ?? "Working") : job.needsYou ? "Needs you" : job.card.state == .failed ? "Stopped" : "Done"
                let mins = Int(Date().timeIntervalSince(job.started) / 60)
                let item = NSMenuItem(title: "\(mark)  \(String(job.title.prefix(48)))", action: #selector(showJob(_:)), keyEquivalent: "")
                item.toolTip = "\(what) · \(mins == 0 ? "just now" : "\(mins) min ago")"
                item.representedObject = job.id
                item.target = self
                add(item)
            }
            if jobs.contains(where: { !$0.isRunning && !$0.needsYou }) {
                let clear = NSMenuItem(title: "Clear finished", action: #selector(clearFinished), keyEquivalent: "")
                clear.target = self
                add(clear)
            }
            add(.separator())
        }
    }

    @objc private func showJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        DispatchQueue.main.async { Controller.shared.showJob(id: id) }
    }

    @objc private func clearFinished() { DispatchQueue.main.async { Controller.shared.clearFinished() } }

    @objc private func draw() { DispatchQueue.main.async { Controller.shared.begin() } }
    @objc private func settings() { SettingsWindow.show() }
    @objc private func history() {
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(History.folder)
    }
}

// MARK: - Settings window

enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 720),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Llasso Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Settings-window state, held in an object because @State needs Xcode's macro plugins.
final class SettingsForm: ObservableObject {
    @Published var key = ""
    @Published var saved = false
    @Published var screenOK = CGPreflightScreenCaptureAccess()
    @Published var axOK = AXIsProcessTrusted()
    @Published var micOK = VoiceInput.microphoneAllowed

    func refresh() {
        screenOK = CGPreflightScreenCaptureAccess()
        axOK = AXIsProcessTrusted()
        micOK = VoiceInput.microphoneAllowed
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var form = SettingsForm()
    @ObservedObject private var integrations = Integrations.shared
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("OpenRouter") {
                HStack {
                    SecureField(settings.hasKey ? "Key saved. Paste a new one to replace it" : "Paste your OpenRouter key (sk-or-…)",
                                text: $form.key)
                    Button(form.saved ? "Saved" : "Save") {
                        settings.saveKey(form.key)
                        form.key = ""
                        form.saved = true
                    }
                    .disabled(form.key.isEmpty)
                }
                TextField("Model", text: $settings.model)
                Text("Any OpenRouter model that reads images and calls tools. Default: \(Settings.defaultModel).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Image model", text: $settings.imageModel)
                Text("Edits boxed images. Default: \(Settings.defaultImageModel).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connected apps") {
                ForEach(integrations.all) { i in
                    HStack(alignment: .top) {
                        Image(systemName: icon(integrations.status[i.name]))
                            .foregroundStyle(integrations.status[i.name] == "Connected" || integrations.status[i.name] == "Ready"
                                             ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.name)
                            Text(integrations.status[i.name] ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                            if integrations.status[i.name] == "Needs set-up" {
                                Text(i.setup).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack(alignment: .top) {
                    Image(systemName: ClaudeCode.path != nil ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(ClaudeCode.path != nil ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code")
                        Text(ClaudeCode.path != nil
                             ? "Ready. Box a local web page or an open file and ask for a change: it edits the project's code, and the card offers Undo."
                             : "Not installed. Install it from claude.com/claude-code to let Llasso edit the code behind local web pages.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Llasso drives these apps through their own tools, and also picks up any local server you have added to Claude Code.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Recheck") { integrations.recheck() }
                }
            }
            Section("Speaking answers") {
                Picker("Voice", selection: $settings.voiceOut) {
                    ForEach(Settings.VoiceOut.allCases) { Text($0.label).tag($0) }
                }
                if settings.voiceOut == .openrouter {
                    TextField("Speech model", text: $settings.ttsModel)
                    TextField("Voice name or id", text: $settings.ttsVoice)
                }
                Text("Answers are spoken only when you asked out loud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                permission("Screen Recording", ok: form.screenOK, need: "Required to see the box") {
                    CGRequestScreenCaptureAccess()
                    open("Privacy_ScreenCapture")
                }
                permission("Microphone", ok: form.micOK, need: "To talk instead of type") {
                    Task { form.micOK = await VoiceInput.requestMicrophone() }
                }
                permission("Accessibility", ok: form.axOK, need: "For the drag-then-icon gesture, and to read the app's file and URL") {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                    _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
                }
            }
            Section("Use") {
                Text("Drag a box round anything as you normally would. A Llasso icon appears where you let go: rest the pointer on it and talk, or type. Or press ⌃⌥S to draw a box straight away. Stop talking and Llasso sends after a second. Or type and press Return. Esc stops or closes.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .onReceive(timer) { _ in
            form.refresh()
        }
    }

    private func permission(_ name: String, ok: Bool, need: String, grant: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading) {
                Text(name)
                Text(need).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Allow", action: grant) }
        }
    }

    private func icon(_ status: String?) -> String {
        switch status {
        case "Connected", "Ready": return "bolt.circle.fill"
        case "Needs set-up": return "exclamationmark.circle"
        default: return "circle"
        }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}


/// Runs capture, context and one OpenRouter call on the middle of the main screen,
/// with no UI, and writes what happened to selftest.json in the history folder.
@MainActor
enum SelfTest {
    static func run() async {
        var report: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date())]
        report["screenRecording"] = CGPreflightScreenCaptureAccess()
        report["accessibility"] = AXIsProcessTrusted()
        report["microphone"] = VoiceInput.microphoneAllowed
        report["hasKey"] = Settings.shared.hasKey
        guard let screen = NSScreen.main else { return write(report) }
        let f = screen.frame
        let box = CGRect(x: f.midX - 400, y: f.midY - 250, width: 800, height: 500)
        let front = NSWorkspace.shared.frontmostApplication
        let ctx = ContextReader.read(app: front, selection: box)
        report["context"] = ["tag": ctx.tag, "app": ctx.appName ?? "", "window": ctx.windowTitle ?? "",
                             "file": ctx.documentPath ?? "", "url": ctx.url ?? "", "elements": ctx.elements]
        do {
            let cap = try await Capture.take(screen: screen, selection: box)
            report["cropBytes"] = cap.crop.count
            report["screenBytes"] = cap.screen.count
            try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
            try? cap.crop.write(to: History.folder.appendingPathComponent("selftest-crop.png"))
            try? cap.screen.write(to: History.folder.appendingPathComponent("selftest-screen.png"))
            if Settings.shared.hasKey {
                let msgs = Brief.firstMessages(prompt: "What is inside the box? One sentence.", verb: nil,
                                               context: ctx, crop: cap.crop, screen: cap.screen, spoken: false)
                let started = Date()
                var answer = ""
                var firstToken: Double?
                for try await piece in Settings.shared.client.streamChat(model: Settings.shared.model, messages: msgs) {
                    if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                    answer += piece
                }
                report["answer"] = answer
                report["model"] = Settings.shared.model
                report["secondsToFirstText"] = firstToken ?? -1
                report["secondsTotal"] = Date().timeIntervalSince(started)
            }
        } catch {
            report["error"] = error.localizedDescription
        }
        write(report)
    }

    /// Opens a TextEdit document and an Excel workbook, runs a real model turn on the
    /// text and writes a formula into the sheet, then closes both without saving.
    /// Text goes back by Accessibility only, never by a synthetic paste.
    /// Replace a selection in a Chrome page Accessibility is told nothing about (the Google Docs case):
    /// ⌘C finds the selection, the paste lands over it, and Undo puts it back. The page copies its
    /// text into its title so the result can be read from the window. Writes pastetest.json.
    /// Brings IDEalize forward from behind Finder and records what each focus signal said,
    /// poll by poll. Types nothing.
    static func front() async {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.projject.idealize.v1").first else {
            write(["error": "IDEalize isn't running"], "fronttest.json"); return
        }
        var r: [String: Any] = ["app pid": app.processIdentifier, "llasso pid": ProcessInfo.processInfo.processIdentifier]
        ContextReader.wake(AXUIElementCreateApplication(app.processIdentifier), pid: app.processIdentifier)
        // The real sequence: Llasso takes the front for the box and prompt, the prompt closes and
        // hands the front back, the card appears, and seconds later the answer goes back.
        NSApp.activate(ignoringOtherApps: true)
        let pill = FloatingPanel(size: CGSize(width: 300, height: 80))
        pill.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        r["while prompting"] = Actuator.focusReport()
        pill.orderOut(nil)
        if NSApp.isActive { app.activate() }
        let card = FloatingPanel(size: CGSize(width: 300, height: 120))
        card.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        r["after prompt closed"] = Actuator.focusReport() + ", llasso active \(NSApp.isActive), key window \(NSApp.keyWindow.map { _ in "yes" } ?? "no")"
        do { try await Actuator.bringForward(app); r["bringForward"] = "ok" } catch { r["bringForward"] = error.localizedDescription }
        r["after"] = Actuator.focusReport()
        card.orderOut(nil)
        write(r, "fronttest.json")
    }

    static func pasteOver() async {
        var r: [String: Any] = [:]
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("llasso-pastetest.html")
        try? Data("""
        <!doctype html><title>start</title><body style="font:20px sans-serif;padding:40px">
        <div id=e contenteditable><h1 style="color:#b8862a">Avoid a rushed strategy</h1><p>AI speeds up <b>research</b> and analysis.</p></div>
        <script>
        const e = document.getElementById('e'); e.focus();
        const r = document.createRange(); r.selectNodeContents(e);
        getSelection().removeAllRanges(); getSelection().addRange(r);
        const t = () => document.title = 'T:' + [...e.querySelectorAll('*')].map(n => n.tagName).join(',') + '|' + e.innerHTML; t();
        new MutationObserver(t).observe(e, {subtree: true, characterData: true, childList: true});
        </script>
        """.utf8).write(to: page)
        _ = try? await Shell.osascript("""
        tell application "Google Chrome"
            activate
            make new window
            set URL of active tab of front window to "\(page.absoluteString)"
        end tell
        """)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else {
            r["error"] = "Chrome didn't start"; write(r, "pastetest.json"); return
        }
        func title() -> String {
            let el = AXUIElementCreateApplication(chrome.processIdentifier)
            guard let w: AXUIElement = ContextReader.attr(el, kAXFocusedWindowAttribute) else { return "" }
            return (ContextReader.attr(w, kAXTitleAttribute) as String?) ?? ""
        }
        r["before"] = title()
        // Pretend Accessibility saw nothing, as in Google Docs.
        var ctx = ScreenContext(appName: "Google Chrome", bundleID: "com.google.Chrome")
        ctx.url = page.absoluteString
        r["offers replace"] = Actuator.destinations(for: .text(text: "x", summary: ""), context: ctx).contains(.replaceInPlace(app: "Google Chrome"))
        if let copied = await Actuator.copySelection(in: chrome) {
            r["copied html"] = copied.html ?? "none"
            if case .rich(let html, _) = await Actuator.styled("Éviter une stratégie bâclée\nL'IA accélère la recherche et l'analyse.", like: copied) {
                r["styled html"] = html
            }
        }
        do {
            _ = try await Actuator.text("Éviter une stratégie bâclée\nL'IA accélère la recherche et l'analyse.", to: .replaceInPlace(app: "Google Chrome"), context: ctx, app: chrome)
            for _ in 0..<20 where !title().hasPrefix("T:Év") { try await Task.sleep(nanoseconds: 100_000_000) }
            r["after"] = title()
            _ = try await Actuator.text("", to: .undoText(app: "Google Chrome"), context: ctx, app: chrome)
            try await Task.sleep(nanoseconds: 500_000_000)
            r["undone"] = title()
            // Nothing selected now? Click away first by collapsing the selection with an arrow key.
            Actuator.press(124, command: false)
            try await Task.sleep(nanoseconds: 300_000_000)
            r["selection after collapse"] = await Actuator.hasSelection(in: chrome)
        } catch { r["error"] = error.localizedDescription }
        _ = try? await Shell.osascript("tell application \"Google Chrome\" to close front window")
        write(r, "pastetest.json")
    }

    static func act() async {
        var r: [String: Any] = [:]
        // Text in place
        do {
            _ = try await Shell.osascript("""
            tell application "TextEdit"
                activate
                make new document with properties {text:"teh quick brwn fox"}
            end tell
            """)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            guard let te = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
                throw ActionError.failed("TextEdit didn't start")
            }
            let appEl = AXUIElementCreateApplication(te.processIdentifier)
            if let focused: AXUIElement = ContextReader.attr(appEl, kAXFocusedUIElementAttribute) {
                var range = CFRange(location: 4, length: 14)   // "quick brwn fox"
                if let v = AXValueCreate(.cfRange, &range) {
                    AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, v)
                }
            }
            let box = NSScreen.main.map { CGRect(x: $0.frame.midX - 300, y: $0.frame.midY - 200, width: 600, height: 400) } ?? .zero
            let ctx = ContextReader.read(app: te, selection: box)
            r["text.kind"] = ctx.kind.rawValue
            r["text.selected"] = ctx.selectedText ?? ""
            r["text.canReplace"] = ctx.canReplaceText
            var calls: [ToolCall] = []
            for try await chunk in Settings.shared.client.streamTurn(
                model: Settings.shared.model,
                messages: [.system(Brief.systemPrompt), .user(Brief.userText(prompt: "fix the spelling", verb: nil, context: ctx))],
                tools: BuiltinTool.available(for: ctx.kind).map(\.schema)) {
                if case .tools(let c) = chunk { calls = c }
            }
            r["text.tool"] = calls.first.map { "\($0.name) \($0.arguments)" } ?? "none"
            if let call = calls.first, case .text(let text, _)? = BuiltinTool.named(call.name)?.proposal(call.args) {
                try await Actuator.replaceText(text, context: ctx, app: te, allowPaste: false)
                if let focused: AXUIElement = ContextReader.attr(appEl, kAXFocusedUIElementAttribute) {
                    r["text.after"] = (ContextReader.attr(focused, kAXValueAttribute) as String?) ?? ""
                }
            }
        } catch { r["text.error"] = error.localizedDescription }
        _ = try? await Shell.osascript("tell application \"TextEdit\" to close front document saving no")

        // Spreadsheet
        let excelWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Excel").isEmpty
        do {
            _ = try await Shell.osascript("""
            tell application "Microsoft Excel"
                set wb to make new workbook
                set value of range "A1" of active sheet to 10
                set value of range "A2" of active sheet to 20
                set value of range "A3" of active sheet to 30
                select range "A1:A3" of active sheet
            end tell
            """, timeout: 60)
            let sel = Sheets.read(.excel)
            r["sheet.address"] = sel?.address ?? "nil"
            r["sheet.values"] = sel?.values ?? []
            var ctx = ScreenContext(appName: "Microsoft Excel", bundleID: "com.microsoft.Excel")
            ctx.sheet = sel
            r["sheet.kind"] = ctx.kind.rawValue
            _ = try await Actuator.cells(start: "A4", rows: [["=SUM(A1:A3)"]], to: .writeCells(app: "Excel"),
                                         context: ctx, app: nil)
            r["sheet.A4"] = try await Shell.osascript("tell application \"Microsoft Excel\" to get value of range \"A4\" of active sheet")
        } catch { r["sheet.error"] = error.localizedDescription }
        _ = try? await Shell.osascript("tell application \"Microsoft Excel\" to close active workbook saving no")
        if !excelWasRunning { _ = try? await Shell.osascript("tell application \"Microsoft Excel\" to quit saving no") }

        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("acttest.json"))
        }
    }

    /// Route A end to end on a scratch project: a page served from a repo, the resolver,
    /// the model choosing edit_code, Claude Code editing, the diff, and Undo. Writes codetest.json.
    static func code() async {
        var r: [String: Any] = [:]
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("llasso-codetest-\(Int(Date().timeIntervalSince1970))")
        let page = "<!doctype html>\n<html><body>\n  <h1>Shop</h1>\n  <button class=\"buy\" style=\"padding:4px;font-size:12px\">Buy now</button>\n</body></html>\n"
        var server: Process?
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(page.utf8).write(to: root.appendingPathComponent("index.html"))
            try Data("notes\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
            for args in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
                _ = try Proc.run(Checkpoint.git, ["-C", root.path] + args)
            }
            // The user's own work in progress: one staged change Llasso must leave alone.
            try Data("notes\nstaged by the user\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
            _ = try Proc.run(Checkpoint.git, ["-C", root.path, "add", "notes.txt"])
            let statusBefore = try Proc.run(Checkpoint.git, ["-C", root.path, "status", "--porcelain"]).out

            let port = 48_000 + Int.random(in: 0..<900)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
            p.currentDirectoryURL = root
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            server = p
            try await Task.sleep(nanoseconds: 1_500_000_000)

            var ctx = ScreenContext(appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Shop",
                                    url: "http://127.0.0.1:\(port)/index.html",
                                    elements: ["AXHeading 'Shop'", "AXButton 'Buy now'"])
            ctx.roles = ["AXButton", "AXStaticText"]
            ctx.source = Resolver.source(for: ctx)
            r["resolve.root"] = ctx.source?.root ?? "nil"
            r["resolve.how"] = ctx.source?.how ?? ""
            r["resolve.ok"] = ctx.source.map { URL(fileURLWithPath: $0.root).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path } ?? false
            r["tag"] = ctx.tag
            guard let target = ctx.source else { throw ActionError.failed("resolver found nothing") }

            let crop = try Capture.png(Self.buttonImage())
            var calls: [ToolCall] = []
            for try await chunk in Settings.shared.client.streamTurn(
                model: Settings.shared.model,
                messages: Brief.firstMessages(prompt: "make this button much bigger", verb: nil, context: ctx,
                                              crop: crop, screen: nil, spoken: false),
                tools: BuiltinTool.available(for: ctx.kind, hasSource: true).map(\.schema)) {
                if case .tools(let c) = chunk { calls = c }
            }
            r["model.tool"] = calls.first?.name ?? "none"
            let instruction = calls.first?.args["instruction"] as? String ?? "Make the Buy now button much bigger."
            r["model.instruction"] = instruction

            let dir = fm.temporaryDirectory.appendingPathComponent("llasso-codetest-crop")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try crop.write(to: dir.appendingPathComponent("box.png"))
            let checkpoint = Checkpoint(target: target)
            let before = try checkpoint.snapshot()
            let start = Date()
            var steps: [String] = []
            let (said, isError) = try await ClaudeCode.edit(
                prompt: CodeBrief.prompt(instruction: instruction, request: "make this button much bigger", context: ctx,
                                         target: target, cropPath: dir.appendingPathComponent("box.png").path),
                in: target.root, extraDirs: [dir.path]) { e in if case .step(let s) = e { DispatchQueue.main.async { steps.append(s) } } }
            r["claude.seconds"] = Int(Date().timeIntervalSince(start))
            r["claude.said"] = said
            r["claude.isError"] = isError
            try await Task.sleep(nanoseconds: 200_000_000)
            r["claude.steps"] = steps
            let after = try checkpoint.snapshot()
            r["changes"] = try checkpoint.changes(from: before, to: after).map { "\($0.path) +\($0.added) -\($0.removed)" }
            r["diff"] = try checkpoint.diff(from: before, to: after)
            r["served.after"] = (try? String(contentsOf: URL(string: "http://127.0.0.1:\(port)/index.html")!, encoding: .utf8)) ?? ""

            try checkpoint.undo(before: before, after: after)
            r["undo.restored"] = (try? String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)) == page
            r["undo.userStagedKept"] = try Proc.run(Checkpoint.git, ["-C", root.path, "status", "--porcelain"]).out == statusBefore

            // A file outside any repo: Llasso's own store holds the checkpoint.
            let loose = fm.temporaryDirectory.appendingPathComponent("llasso-loose-\(Int(Date().timeIntervalSince1970))")
            try fm.createDirectory(at: loose, withIntermediateDirectories: true)
            let file = loose.appendingPathComponent("page.html")
            try Data(page.utf8).write(to: file)
            var looseCtx = ScreenContext(appName: "TextEdit", documentPath: file.path)
            looseCtx.source = Resolver.source(for: looseCtx)
            r["loose.isRepo"] = looseCtx.source?.isRepo ?? true
            if let t = looseCtx.source {
                let cp = Checkpoint(target: t)
                let b = try cp.snapshot()
                try Data(page.replacingOccurrences(of: "4px", with: "20px").utf8).write(to: file)
                try Data("new\n".utf8).write(to: loose.appendingPathComponent("added.css"))
                let a = try cp.snapshot()
                r["loose.changes"] = try cp.changes(from: b, to: a).map(\.path)
                try cp.undo(before: b, after: a)
                r["loose.restored"] = (try? String(contentsOf: file, encoding: .utf8)) == page
                    && !fm.fileExists(atPath: loose.appendingPathComponent("added.css").path)
                r["loose.untouched"] = !fm.fileExists(atPath: loose.appendingPathComponent(".git").path)
            }
            try? fm.removeItem(at: loose)
        } catch { r["error"] = error.localizedDescription }
        server?.terminate()
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: History.folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("codetest.json"))
        }
    }

    /// Two jobs at once; a click away from the first while it works; both finish. Also measures
    /// where the prompt's mic sits. Writes jobtest.json.
    static func jobs() async {
        var r: [String: Any] = [:]
        guard let screen = NSScreen.main else { return }
        let mic = await Controller.shared.measurePill()
        r["micOffset"] = "\(mic.x),\(mic.y)"
        let crop = (try? Capture.png(buttonImage())) ?? Data()
        let ctx = ScreenContext(appName: "Safari", bundleID: "com.apple.Safari", url: "https://example.com/shop",
                                elements: ["AXButton 'Buy now'"])
        let f = screen.visibleFrame
        let a = Controller.shared.startTestJob(box: (CGRect(x: f.minX + 100, y: f.maxY - 300, width: 300, height: 140), screen),
                                               context: ctx, prompt: "In one sentence, what is this?", crop: crop)
        let b = Controller.shared.startTestJob(box: (CGRect(x: f.minX + 700, y: f.maxY - 300, width: 300, height: 140), screen),
                                               context: ctx, prompt: "Name the colour of the button in one word.", crop: crop)
        try? await Task.sleep(nanoseconds: 400_000_000)
        r["a.visibleAtStart"] = a.isVisible
        r["jobsRunning"] = Controller.shared.jobs.filter(\.isRunning).count
        // A click on the desktop, away from both cards: the cards hide, the work goes on.
        let click = CGPoint(x: f.midX, y: f.minY + 40)
        Controller.shared.hideCardsForTest(at: click)
        r["a.hiddenAfterClick"] = !a.isVisible
        r["a.runningAfterClick"] = a.isRunning
        for _ in 0..<120 where a.isRunning || b.isRunning { try? await Task.sleep(nanoseconds: 500_000_000) }
        r["a.state"] = "\(a.card.state)"
        r["a.answer"] = a.card.answer
        r["b.answer"] = b.card.answer
        r["a.error"] = a.card.error ?? ""
        a.show()
        r["a.visibleAfterShow"] = a.isVisible
        a.close(); b.close()
        r["jobsLeft"] = Controller.shared.jobs.count
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("jobtest.json"))
        }
    }

    /// A Chrome box with "do this in Paper": Paper's server connects and the model's first
    /// call is one of Paper's tools. Nothing is written. Writes namedtest.json.
    static func named() async {
        var r: [String: Any] = [:]
        let prompt = "can you do three variations on the design of this in paper please"
        let i = Integrations.shared.named(in: prompt)
        r["named"] = i?.name ?? "none"
        r["notNamed"] = Integrations.shared.named(in: "make the paperwork shorter")?.name ?? "none"
        if let i, let mcp = await Integrations.shared.client(for: i) {
            var ctx = ScreenContext(appName: "Google Chrome", bundleID: "com.google.Chrome", url: "https://example.com/care")
            ctx.roles = ["AXStaticText", "AXImage"]
            ctx.integration = i.name
            let crop = (try? Capture.png(buttonImage())) ?? Data()
            var guides: [String] = []
            if let text = mcp.instructions { guides.append("Guide from \(mcp.name) for its own tools (prefixed \(mcp.name)__):\n" + text) }
            var calls: [ToolCall] = []
            do {
                for try await chunk in Settings.shared.client.streamTurn(
                    model: Settings.shared.model,
                    messages: Brief.firstMessages(prompt: prompt, verb: nil, context: ctx, crop: crop, screen: nil,
                                                  spoken: false, appGuides: guides),
                    tools: BuiltinTool.available(for: ctx.kind).map(\.schema) + Integrations.shared.toolSchemas(mcp, blocked: i.blocked)) {
                    if case .tools(let c) = chunk { calls = c }
                }
            } catch { r["error"] = error.localizedDescription }
            r["firstCalls"] = calls.map(\.name)
        }
        Integrations.shared.stopAll()
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("namedtest.json"))
        }
    }

    /// Open the Save to… panel over a Llasso overlay, check it sits above the overlay and
    /// starts in the project, then close it. Writes savetest.json.
    static func save() {
        guard let screen = NSScreen.main else { return }
        let overlay = OverlayWindow(screen: screen)
        overlay.orderFrontRegardless()
        var ctx = ScreenContext(appName: "Hatch")
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/_AppDev/Powell").path
        ctx.source = SourceTarget(root: root, isRepo: true, how: "test")
        var r: [String: Any] = ["startFolder": Actuator.startFolder(context: ctx, ext: "png").path]
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                let panel = NSApp.windows.compactMap { $0 as? NSSavePanel }.first
                r["panelVisible"] = panel?.isVisible ?? false
                r["panelAboveOverlay"] = (panel?.level.rawValue ?? 0) > overlay.level.rawValue
                r["levels"] = "panel \(panel?.level.rawValue ?? -1), overlay \(overlay.level.rawValue)"
                r["panelFolder"] = panel?.directoryURL?.path ?? ""
                r["onScreenOrder"] = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
                    .map { "\($0[kCGWindowLayer as String] ?? "") \($0[kCGWindowName as String] ?? "")" }
                panel?.cancel(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        do { _ = try Actuator.saveAs(Data("x".utf8), ext: "png", context: ctx) } catch { r["result"] = "\(error)" }
        r["overlayRestored"] = overlay.level == .screenSaver
        overlay.orderOut(nil)
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("savetest.json"))
        }
    }

    /// A small picture of a button labelled "Buy now", standing in for a boxed page.
    static func buttonImage() -> CGImage {
        let size = CGSize(width: 360, height: 160)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: 20, y: 60, width: 80, height: 22))
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        NSAttributedString(string: "Shop", attributes: [.font: NSFont.boldSystemFont(ofSize: 28)]).draw(at: CGPoint(x: 20, y: 105))
        NSAttributedString(string: "Buy now", attributes: [.font: NSFont.systemFont(ofSize: 12)]).draw(at: CGPoint(x: 26, y: 64))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// Connect to every integration that has a server, list its tools and call one
    /// read-only tool, and write what happened to mcptest.json.
    static func mcp() async {
        var report: [String: Any] = [:]
        for i in Integrations.shared.all {
            var r: [String: Any] = ["status": Integrations.shared.status[i.name] ?? ""]
            if let c = await Integrations.shared.client(for: i) {
                r["tools"] = c.tools.count
                r["readOnly"] = c.tools.filter(\.readOnly).count
                r["hasGuide"] = c.instructions != nil
                let probe = i.name == "Paper" ? "get_basic_info" : "status"
                if c.tools.contains(where: { $0.name == probe }) {
                    do {
                        let out = try await c.callTool(probe, arguments: [:])
                        r["probe"] = String(out.text.prefix(300))
                    } catch { r["probeError"] = error.localizedDescription }
                }
            }
            report[i.name] = r
        }
        Integrations.shared.stopAll()
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("mcptest.json"))
        }
    }

    private static func write(_ report: [String: Any], _ name: String = "selftest.json") {
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent(name))
        }
    }
}
