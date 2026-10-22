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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let watcher = DragWatcher()
    private var offer: Offer?
    private var gestureRetry: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "lasso", accessibilityDescription: "Llasso")
        let menu = NSMenu()
        menu.addItem(withTitle: "Draw a box   ⌃⌥S", action: #selector(draw), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Show history", action: #selector(history), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Llasso", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

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
        // The tap needs Accessibility; keep trying until it is granted.
        if !watcher.start() {
            gestureRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.watcher.start() == true { t.invalidate() }
            }
        }

        if !Settings.shared.hasKey || !CGPreflightScreenCaptureAccess() {
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

    private static func write(_ report: [String: Any]) {
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("selftest.json"))
        }
    }
}
