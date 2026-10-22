import AppKit
import SwiftUI
import LlassoKit

/// Runs one Llasso job: hotkey → box → prompt → answer card.
@MainActor
final class Controller {
    static let shared = Controller()

    enum Phase { case idle, selecting, prompting, answering }
    private(set) var phase: Phase = .idle

    private var overlays: [OverlayWindow] = []
    private var pillPanel: FloatingPanel?
    private var cardPanel: FloatingPanel?
    private let pill = PillModel()
    private let card = CardModel()
    private let voice = VoiceInput()
    private let speaker = Speaker()

    private var frontApp: NSRunningApplication?
    private var box: (rect: CGRect, screen: NSScreen)?
    private var capture: Capture?
    private var captureTask: Task<Capture?, Never>?
    private var context = ScreenContext()
    private var messages: [ChatMessage] = []
    private var lastPrompt = ""
    private var spoken = false
    private var pointerHeld = false
    /// The icon offered after a drag; it stays beside the prompt as the hold-to-talk button.
    var offer: Offer?
    private var holding = false
    private var voiceStarting = false

    private var keyMonitor: Any?
    private var clickMonitors: [Any] = []
    private var streamTask: Task<Void, Never>?
    private var pauseTimer: Timer?
    private var lastSpeechChange = Date()

    // Acting
    private var integration: Integration?
    private var mcpTask: Task<MCPClient?, Never>?
    private var mcp: MCPClient?
    private var approveAll = false
    /// Resumed by the card when the user answers a question or approves a step.
    private var decision: CheckedContinuation<String?, Never>?
    private var proposal: Proposal?
    private var editedImage: Data?
    private var actions: [String] = []
    /// The code edit on the card, kept so Undo can put the files back.
    private var codeEdit: (checkpoint: Checkpoint, before: String, after: String, files: [FileChange])?

    private var watchdog: Timer?

    private init() {
        // Every two seconds, put Llasso right if a job has lost all its windows, or the
        // icon is left open with no job behind it. Either leaves new drags ignored.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStuck() }
        }
        pill.onSend = { [weak self] in self?.send() }
        pill.onCancel = { [weak self] in self?.cancel() }
        pill.onHold = { [weak self] down in
            guard let self else { return }
            if down { self.holdToTalk() } else { self.releaseToSend() }
        }
        card.onStop = { [weak self] in self?.stopAnswer() }
        card.onClose = { [weak self] in self?.cancel() }
        card.onCopy = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.card.answer, forType: .string)
            self.card.copied = true
        }
        card.onFollowUp = { [weak self] text in self?.followUp(text) }
        card.onAnswer = { [weak self] answer in self?.decide(answer) }
        card.onStep = { [weak self] run, all in
            if all { self?.approveAll = true }
            self?.decide(run ? "run" : "skip")
        }
        card.onDestination = { [weak self] d in self?.deliver(to: d) }
        speaker.onError = { [weak self] message in self?.card.error = "Voice: " + message }
        voice.onUpdate = { [weak self] text in
            guard let self, self.phase == .selecting || self.phase == .prompting, !self.pill.typed else { return }
            if text != self.pill.text {
                self.pill.text = text
                self.lastSpeechChange = Date()
                self.pill.pending = nil
            }
        }
    }

    private func checkStuck() {
        if NSApp.modalWindow != nil { return }
        if phase == .idle {
            if offer?.isOpened == true { Log.write("watchdog: open icon with no job; dismissed"); offer?.dismiss() }
            return
        }
        let visible = (pillPanel?.isVisible ?? false) || (cardPanel?.isVisible ?? false)
            || overlays.contains { $0.isVisible } || (offer?.isShowing ?? false)
        if !visible { Log.write("watchdog: phase \(phase) with no windows; reset"); cancel() }
    }

    // MARK: Start

    /// The hotkey. Pressed again mid-job, it cancels.
    func toggle() {
        if phase == .idle { begin() } else { cancel() }
    }

    /// From the drag offer: the box is already drawn (AppKit global), so go straight to the prompt.
    func begin(box: CGRect) {
        begin()
        guard phase == .selecting,
              let w = overlays.first(where: { $0.frame.intersects(box) && $0.frame.contains(CGPoint(x: box.midX, y: box.midY)) })
                ?? overlays.first(where: { $0.frame.intersects(box) })
        else { return }
        let local = box.intersection(w.frame).offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)
        w.selectionView.show(selection: local)
        selectionMade(local, in: w)
    }

    /// Press on the offer icon: open the prompt if it isn't open, and record until release.
    /// This press, or one on the pill's mic, is the only thing that turns the microphone on.
    func holdToTalk(box: CGRect) {
        if phase == .idle { begin(box: box) }
        holdToTalk()
    }

    func holdToTalk() {
        guard phase == .prompting else { return }
        holding = true
        pill.typed = false
        pill.pending = nil
        offer?.setRecording(true)
        startVoice()
    }

    /// Release after holding the icon: send straight away.
    func releaseToSend() {
        guard holding else { return }
        holding = false
        offer?.setRecording(false)
        guard phase == .prompting else { return }
        if pill.text.isEmpty {
            // Released before any words arrived: wait briefly for the last of them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.send() }
        } else {
            send()
        }
    }

    func begin() {
        let keepOffer = offer?.window != nil && phase == .idle
        cancel(keepingOffer: keepOffer)
        let front = NSWorkspace.shared.frontmostApplication
        if Sensitive.isSensitive(bundleID: front?.bundleIdentifier) {
            Toast.show("Llasso is off while \(front?.localizedName ?? "this app") is in front.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            Toast.show("Llasso needs Screen Recording. Allow it in System Settings, then try again.", seconds: 6)
            SettingsWindow.show()
            return
        }
        frontApp = front
        Log.write("begin in \(front?.localizedName ?? "?")")
        phase = .selecting
        pill.text = ""
        pill.typed = false
        pill.verb = nil
        pill.pending = nil
        pill.notice = nil
        pill.tag = "Reading the screen…"
        pill.tagKnown = false

        for screen in NSScreen.screens {
            let w = OverlayWindow(screen: screen)
            w.selectionView.onPointerDown = { [weak self] in self?.pointerDown() }
            w.selectionView.onSelection = { [weak self, weak w] rect in
                guard let self, let w else { return }
                self.selectionMade(rect, in: w)
            }
            overlays.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let target = overlays.first { $0.frame.contains(mouse) } ?? overlays.first
        target?.makeKey()
        target?.makeFirstResponder(target?.selectionView)
        NSCursor.crosshair.set()
        installKeyMonitor()
        // Load the speech model early so the first word isn't lost.
        Task { _ = await voice.prepare() }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        installClickMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }   // Esc
            self.escape()
            return nil
        }
    }

    /// A click anywhere outside the box, the prompt and the card dismisses Llasso.
    /// The global monitor sees clicks that go to other apps; the local one sees clicks
    /// on Llasso's own dimmed overlay.
    private func installClickMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            let window = event.window
            if window === self.pillPanel || window === self.cardPanel || window === self.offer?.window { return event }
            // A save panel or alert Llasso opened is part of the job, not a click away from it.
            if NSApp.modalWindow != nil || window is NSSavePanel { return event }
            return self.clicked(at: NSEvent.mouseLocation) ? nil : event
        }) { clickMonitors.append(local) }
    }

    /// Returns true if the click dismissed Llasso.
    @discardableResult
    private func clicked(at point: CGPoint) -> Bool {
        guard phase == .prompting || phase == .answering else { return false }
        if let p = pillPanel, p.isVisible, p.frame.contains(point) { return false }
        if let c = cardPanel, c.isVisible, c.frame.contains(point) { return false }
        if let o = offer?.window, o.isVisible, o.frame.contains(point) { return false }
        if phase == .prompting, let box, box.rect.contains(point) { return false }
        cancel()
        return true
    }

    private func escape() {
        switch phase {
        case .answering where card.state == .thinking || card.state == .streaming:
            stopAnswer()
        default:
            cancel()
        }
    }

    // MARK: Selecting

    private func pointerDown() {
        pointerHeld = true
        for o in overlays where o.selectionView.mode == .selecting { o.selectionView.clear() }
        pillPanel?.orderOut(nil)
    }

    private func startVoice() {
        // Two presses can ask for the mic within a moment; start it once.
        guard !voice.isRunning, !voiceStarting else { return }
        voiceStarting = true
        Task {
            defer { voiceStarting = false }
            if !VoiceInput.microphoneAllowed {
                guard await VoiceInput.requestMicrophone() else { return }
            }
            do {
                try await voice.start()
                // Released and sent, or cancelled, before the mic came up: let it go at once.
                guard phase == .prompting else { voice.abandon(); pill.listening = false; return }
                pill.listening = voice.isRunning
                lastSpeechChange = Date()
            } catch {
                pill.listening = false
                pill.notice = "Microphone didn't start. Type instead."
            }
        }
    }

    private func selectionMade(_ rect: CGRect, in window: OverlayWindow) {
        pointerHeld = false
        guard rect != .zero else { return }   // a click: keep waiting for a box
        let screen = window.screenRef
        let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        box = (global, screen)
        for o in overlays where o !== window { o.selectionView.clear() }
        window.selectionView.mode = .holding
        phase = .prompting

        context = ScreenContext(appName: frontApp?.localizedName, bundleID: frontApp?.bundleIdentifier)
        let app = frontApp
        // Read accessibility context off the main thread; slow apps can take a moment.
        Task.detached { [weak self] in
            var found = ContextReader.read(app: app, selection: global)
            found.source = Resolver.source(for: found)
            let ctx = found
            await MainActor.run {
                guard let self, self.phase == .prompting || self.phase == .answering else { return }
                var ctx = ctx
                ctx.integration = self.context.integration
                ctx.integrationHint = self.context.integrationHint
                self.context = ctx
                self.pill.tag = ctx.tag + "  ·  " + ctx.kind.rawValue
                self.pill.tagKnown = ctx.documentPath != nil || ctx.url != nil || ctx.integration != nil || ctx.source != nil
            }
        }
        connectIntegration(for: app)
        pill.tag = context.tag
        captureTask = Task { try? await Capture.take(screen: screen, selection: global) }

        showPill(near: global, on: screen)
        startPauseTimer()
    }

    /// Start the app's MCP server in the background while the user talks.
    private func connectIntegration(for app: NSRunningApplication?) {
        integration = Integrations.shared.integration(bundleID: app?.bundleIdentifier, appName: app?.localizedName)
        guard let integration else { return }
        guard integration.transport != nil else {
            context.integrationHint = integration.setup
            pill.notice = "\(integration.name) can give Llasso its own tools. Set it up under Settings → Connected apps."
            return
        }
        mcpTask = Task { [weak self] in
            let client = await Integrations.shared.client(for: integration)
            guard let self, client != nil, self.phase == .prompting || self.phase == .answering else { return client }
            self.context.integration = integration.name
            self.pill.tag = self.context.tag + "  ·  " + self.context.kind.rawValue
            self.pill.tagKnown = true
            return client
        }
    }

    private func showPill(near rect: CGRect, on screen: NSScreen) {
        let panel = pillPanel ?? FloatingPanel(size: CGSize(width: 560, height: 150))
        if pillPanel == nil {
            let host = NSHostingView(rootView: PillView(model: pill) { [weak panel] h in panel?.setHeight(h) })
            panel.contentView = host
            pillPanel = panel
        }
        panel.place(near: rect, on: screen)
        panel.makeKeyAndOrderFront(nil)
    }

    /// One second of quiet after speech starts the pending bar; one more second sends.
    private func startPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .prompting, !self.pill.typed, !self.holding, self.voice.isRunning else { return }
                let quiet = Date().timeIntervalSince(self.lastSpeechChange)
                guard !self.pill.text.isEmpty, quiet >= 1.0 else { self.pill.pending = nil; return }
                let progress = min(1, (quiet - 1.0) / 1.0)
                self.pill.pending = progress
                if progress >= 1 { self.send() }
            }
        }
    }

    // MARK: Asking

    private func send() {
        guard phase == .prompting, let box else { return }
        pauseTimer?.invalidate()
        pill.pending = nil
        holding = false
        offer?.dismiss()
        let usedVoice = voice.isRunning && !pill.typed
        phase = .answering
        pillPanel?.orderOut(nil)
        // Only the boxed screen keeps an outline; the others go away.
        for o in overlays where o.screenRef != box.screen { o.orderOut(nil) }
        if let w = overlays.first(where: { $0.screenRef == box.screen }) {
            let local = box.rect.offsetBy(dx: -box.screen.frame.minX, dy: -box.screen.frame.minY)
            w.selectionView.show(selection: local)
            w.selectionView.mode = .outline
        }

        showCard(near: box.rect, on: box.screen)
        Task {
            let heard = usedVoice ? await voice.stop() : { voice.abandon(); return "" }()
            pill.listening = false
            let prompt = pill.typed ? pill.text : (heard.isEmpty ? pill.text : heard)
            spoken = usedVoice && !prompt.isEmpty
            lastPrompt = prompt
            card.title = prompt.isEmpty ? (pill.verb?.label ?? "Explain") + " · " + context.tag : prompt
            guard let cap = await captureTask?.value else {
                fail("Llasso couldn't capture the screen. Check Screen Recording in System Settings.")
                return
            }
            capture = cap
            if let task = mcpTask { mcp = await task.value }
            // "Do this in Paper" from another app: connect the app the user named.
            if mcp == nil, let named = Integrations.shared.named(in: prompt) {
                card.working = "Connecting to \(named.name)…"
                if let client = await Integrations.shared.client(for: named) {
                    integration = named
                    mcp = client
                    context.integration = named.name
                }
                card.working = nil
            }
            Log.write("send: \(prompt.prefix(80)) · \(context.kind.rawValue) · tools: \(mcp?.name ?? "none")")
            var guides: [String] = []
            if let mcp, let text = mcp.instructions, !text.isEmpty {
                guides.append("Guide from \(mcp.name) for its own tools (prefixed \(mcp.name)__):\n" + text)
            }
            messages = Brief.firstMessages(prompt: prompt, verb: pill.verb, context: context,
                                           crop: cap.crop, screen: cap.screen, spoken: spoken, appGuides: guides)
            run()
        }
    }

    private func followUp(_ text: String) {
        guard phase == .answering else { return }
        lastPrompt = text
        spoken = false
        messages.append(ChatMessage(role: "user", parts: [.text(text)]))
        card.title = text
        card.answer = ""
        card.copied = false
        card.resetAction()
        card.log = []
        run()
    }

    private func run() {
        let settings = Settings.shared
        guard settings.hasKey else {
            fail("Add your OpenRouter key in Llasso's settings (menu bar → Settings).")
            SettingsWindow.show()
            return
        }
        card.state = .thinking
        card.error = nil
        streamTask = Task { await agentLoop() }
    }

    /// Stream a turn; run the tools it asks for; repeat until the model stops asking,
    /// or until it proposes something the user must place.
    private func agentLoop() async {
        let settings = Settings.shared
        let client = settings.client
        let model = settings.model
        let speak = spoken && settings.voiceOut != .off
        var tools = BuiltinTool.available(for: context.kind, hasSource: context.source != nil).map(\.schema)
        if let mcp, let integration { tools += Integrations.shared.toolSchemas(mcp, blocked: integration.blocked) }
        var shown = ""
        do {
            for _ in 0..<16 {
                var sentences = SentenceBuffer()
                var text = ""
                var calls: [ToolCall] = []
                let prefix = shown.isEmpty ? "" : shown + "\n\n"
                for try await chunk in client.streamTurn(model: model, messages: messages, tools: tools) {
                    if Task.isCancelled { return }
                    switch chunk {
                    case .text(let piece):
                        text += piece
                        card.answer = prefix + text
                        card.state = .streaming
                        if speak { sentences.append(piece).forEach(speaker.say) }
                    case .tools(let c):
                        calls = c
                    }
                }
                if speak, !Task.isCancelled, let rest = sentences.flush() { speaker.say(rest) }
                if !text.isEmpty { shown = prefix + text }
                messages.append(.assistant(text, calls: calls))
                if calls.isEmpty { break }

                var images: [Data] = []
                var stop = false
                for call in calls {
                    if Task.isCancelled { return }
                    Log.write("tool: \(call.name)")
                    let outcome = await handle(call)
                    messages.append(.toolResult(id: call.id, outcome.text))
                    images += outcome.images
                    if outcome.endsTurn { stop = true }
                }
                if !images.isEmpty {
                    messages.append(ChatMessage(role: "user", parts: images.prefix(3).map { .png($0) }
                        + [.text("Images returned by the tool calls above.")]))
                }
                if stop { break }
                card.state = .thinking
            }
            card.working = nil
            card.state = .done
            if shown.isEmpty && card.proposal == nil && card.question == nil && card.log.isEmpty && card.error == nil {
                card.error = "The model sent nothing back. Try again, or say what you want in more words."
            }
            Log.write("done: \(shown.count) chars, proposal \(card.proposal != nil), log \(card.log)")
            History.append(prompt: lastPrompt, verb: pill.verb, context: context, answer: shown, model: model, actions: actions)
        } catch {
            if Task.isCancelled { return }
            card.working = nil
            fail(error.localizedDescription)
        }
    }

    private struct Outcome {
        var text: String
        var images: [Data] = []
        /// A proposal is waiting on the card; the model's turn ends there.
        var endsTurn = false
    }

    private func handle(_ call: ToolCall) async -> Outcome {
        let args = call.args
        if let builtin = BuiltinTool.named(call.name) {
            switch builtin {
            case .askUser:
                let q = args["question"] as? String ?? "Which do you mean?"
                let options = (args["options"] as? [String] ?? []).prefix(4)
                card.question = (q, Array(options))
                card.state = .done
                let answer = await waitForDecision()
                card.question = nil
                guard let answer else { return Outcome(text: "The user closed the question.", endsTurn: true) }
                card.log.append("› " + answer)
                card.state = .thinking
                return Outcome(text: "The user answered: \(answer)")
            case .pointAt:
                point(x: args["x"] as? Double ?? 0.5, y: args["y"] as? Double ?? 0.5, label: args["label"] as? String ?? "Here")
                return Outcome(text: "Ringed the point on screen.")
            case .editCode:
                return await editCode(instruction: args["instruction"] as? String ?? lastPrompt,
                                      summary: args["summary"] as? String ?? "")
            case .proposeText, .editImage, .setCells, .runScript:
                guard let p = builtin.proposal(args) else { return Outcome(text: "The arguments were incomplete.") }
                return await propose(p)
            }
        }
        guard let mcp, let (server, tool) = ToolName.split(call.name), server == ToolName.clean(mcp.name),
              let spec = mcp.tools.first(where: { $0.name == tool }) else {
            return Outcome(text: "There is no tool called \(call.name).")
        }
        if !spec.readOnly && !approveAll {
            card.step = ("\(mcp.name) wants to \(tool.replacingOccurrences(of: "_", with: " "))", Self.brief(args))
            card.state = .done
            let choice = await waitForDecision()
            card.step = nil
            guard choice == "run" else {
                card.log.append("– skipped \(mcp.name) \(tool)")
                return Outcome(text: "The user skipped this step.", endsTurn: choice == nil)
            }
        }
        card.state = .thinking
        card.working = "\(mcp.name): \(tool.replacingOccurrences(of: "_", with: " "))…"
        defer { card.working = nil }
        do {
            let r = try await mcp.callTool(tool, arguments: args)
            card.log.append((r.isError ? "✕ " : "✓ ") + "\(mcp.name) \(tool)")
            if !spec.readOnly { actions.append("\(mcp.name).\(tool)") }
            return Outcome(text: String(r.text.prefix(20_000)).ifEmpty("Done."), images: r.images)
        } catch {
            card.log.append("✕ \(mcp.name) \(tool)")
            return Outcome(text: "The tool failed: \(error.localizedDescription)")
        }
    }

    /// Show a proposal on the card. Images are made first so the card can preview them.
    private func propose(_ p: Proposal) async -> Outcome {
        proposal = p
        editedImage = nil
        var cardP = ProposalCard(summary: p.summary, destinations: Actuator.destinations(for: p, context: context))
        switch p {
        case .text(let text, _):
            cardP.text = text
            cardP.original = context.selectedText ?? context.fieldValue
        case .image(let instruction, _):
            guard let crop = capture?.crop else { return Outcome(text: "There is no image to edit.") }
            card.working = "Editing the image…"
            card.state = .thinking
            do {
                let image = try await Settings.shared.client.image(model: Settings.shared.imageModel,
                                                                   prompt: instruction, source: crop)
                card.working = nil
                editedImage = image
                cardP.image = image
            } catch {
                card.working = nil
                card.error = "Image edit: " + error.localizedDescription
                return Outcome(text: "The image model failed: \(error.localizedDescription)", endsTurn: true)
            }
        case .cells(_, let rows, _):
            cardP.rows = rows
        case .script(let source, _):
            cardP.script = source
        }
        card.proposal = cardP
        return Outcome(text: "Shown to the user, who will choose where it goes. Do not repeat it.", endsTurn: true)
    }

    /// Route A: Claude Code edits the project behind the box, between two snapshots.
    private func editCode(instruction: String, summary: String) async -> Outcome {
        guard let target = context.source else { return Outcome(text: "No project folder was found for this box.") }
        guard let crop = capture?.crop else { return Outcome(text: "There is no capture to show the coding agent.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llasso-\(UUID().uuidString.prefix(8))")
        let cropURL = dir.appendingPathComponent("box.png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try crop.write(to: cropURL)
        } catch { return Outcome(text: "Llasso couldn't save the capture: \(error.localizedDescription)") }
        defer { try? FileManager.default.removeItem(at: dir) }

        let checkpoint = Checkpoint(target: target)
        card.state = .thinking
        card.working = "Checkpointing \(target.name)…"
        let prompt = CodeBrief.prompt(instruction: instruction, request: lastPrompt, context: context,
                                      target: target, cropPath: cropURL.path)
        do {
            let before = try await Task.detached { try checkpoint.snapshot() }.value
            card.working = "Claude Code is reading \(target.name)…"
            let (said, isError) = try await ClaudeCode.edit(prompt: prompt, in: target.root, extraDirs: [dir.path]) { event in
                Task { @MainActor [weak self] in
                    guard let self, case .step(let step) = event else { return }
                    self.card.working = "Claude Code: \(step)…"
                    if step.hasPrefix("Editing") || step.hasPrefix("Writing") { self.card.log.append("✎ " + step) }
                }
            }
            if Task.isCancelled { return Outcome(text: "Stopped.", endsTurn: true) }
            card.working = "Reading the changes…"
            let (after, files, diff) = try await Task.detached { () throws -> (String, [FileChange], String) in
                let after = try checkpoint.snapshot()
                return (after, try checkpoint.changes(from: before, to: after), try checkpoint.diff(from: before, to: after))
            }.value
            card.working = nil
            guard !files.isEmpty else {
                return Outcome(text: (isError ? "Claude Code failed: " : "Claude Code changed no files. It said: ") + said)
            }
            codeEdit = (checkpoint, before, after, files)
            actions.append("edit_code \(target.name): \(files.map(\.path).joined(separator: ", "))")
            var p = ProposalCard(summary: summary.ifEmpty("Changed \(files.count) file\(files.count == 1 ? "" : "s") in \(target.name)"),
                                 destinations: Actuator.codeDestinations(changed: files))
            p.text = said
            p.files = files
            p.diff = String(diff.prefix(30_000))
            card.proposal = p
            return Outcome(text: "Edited \(files.map(\.path).joined(separator: ", ")) in \(target.root). Claude Code said: \(said)\nThe user sees the diff with Keep and Undo. Do not repeat it.",
                           endsTurn: true)
        } catch {
            card.working = nil
            card.error = error.localizedDescription
            return Outcome(text: "The code edit failed: \(error.localizedDescription)", endsTurn: true)
        }
    }

    /// Keep, Undo or open a code edit that has already been made.
    private func deliverCode(_ d: Destination) {
        guard let edit = codeEdit else { return }
        switch d {
        case .keepCode:
            card.proposal?.done = "Kept."
            card.proposal?.destinations = []
            actions.append("kept")
        case .undoCode:
            card.working = "Undoing…"
            Task {
                do {
                    try await Task.detached { try edit.checkpoint.undo(before: edit.before, after: edit.after) }.value
                    card.working = nil
                    card.proposal?.done = "Undone. The files are as they were."
                    card.proposal?.destinations = []
                    actions.append("undone")
                    codeEdit = nil
                    messages.append(.user("(Llasso note, not from the user) The user undid the code edit."))
                } catch {
                    card.working = nil
                    card.error = error.localizedDescription
                }
            }
        case .openCode:
            if let first = edit.files.first {
                NSWorkspace.shared.open(URL(fileURLWithPath: edit.checkpoint.target.root).appendingPathComponent(first.path))
            }
        default: break
        }
        History.append(prompt: lastPrompt, verb: pill.verb, context: context, answer: card.answer,
                       model: Settings.shared.model, actions: actions)
    }

    /// The user tapped a destination on the proposal.
    private func deliver(to d: Destination) {
        switch d {
        case .keepCode, .undoCode, .openCode: deliverCode(d); return
        default: break
        }
        guard let p = proposal else { return }
        let ctx = context
        let app = frontApp
        let image = editedImage
        card.working = d == .run ? "Running…" : "Working…"
        Task {
            do {
                let result: String
                switch p {
                case .text(let text, _): result = try await Actuator.text(text, to: d, context: ctx, app: app)
                case .image:
                    guard let image else { throw ActionError.failed("The edited image is missing.") }
                    let fit = self.capture.flatMap { NSBitmapImageRep(data: $0.crop) }
                        .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
                    result = try await Actuator.image(image, to: d, context: ctx, app: app, fit: fit, points: self.box?.rect.size)
                case .cells(let start, let rows, _): result = try await Actuator.cells(start: start, rows: rows, to: d, context: ctx, app: app)
                case .script(let source, _): result = try await Actuator.run(script: source)
                }
                card.working = nil
                card.proposal?.done = result
                actions.append(d.label)
                messages.append(.user("(Llasso note, not from the user) The user chose “\(d.label)”. \(result)"))
                History.append(prompt: lastPrompt, verb: pill.verb, context: ctx, answer: card.answer,
                               model: Settings.shared.model, actions: actions)
                // Leaving the boxed app's change in view: drop the outline once text went back in place.
                if case .replaceInPlace = d { overlays.forEach { $0.orderOut(nil) } }
            } catch ActionError.cancelled {
                card.working = nil
            } catch {
                card.working = nil
                card.error = error.localizedDescription
            }
        }
    }

    private func waitForDecision() async -> String? {
        await withCheckedContinuation { cont in
            decision?.resume(returning: nil)
            decision = cont
        }
    }

    private func decide(_ answer: String?) {
        let d = decision
        decision = nil
        d?.resume(returning: answer)
    }

    /// Ring a point given as fractions of the boxed image.
    private func point(x: Double, y: Double, label: String) {
        guard let box else { return }
        let fx = min(1, max(0, x)), fy = min(1, max(0, y))
        let p = CGPoint(x: box.rect.minX + box.rect.width * fx, y: box.rect.maxY - box.rect.height * fy)
        Pointer.ring(at: p, label: label)
        card.log.append("◎ " + label)
    }

    /// Tool arguments in a few readable lines for the approval step.
    static func brief(_ args: [String: Any]) -> String {
        args.sorted { $0.key < $1.key }.map { k, v in
            let s = (v as? String) ?? ((try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\(v)")
            return "\(k): \(s.prefix(160))"
        }.joined(separator: "\n")
    }

    private func stopAnswer() {
        decide(nil)
        streamTask?.cancel()
        streamTask = nil
        speaker.stop()
        if card.state != .failed { card.state = .done }
    }

    private func fail(_ message: String) {
        Log.write("failed: " + message)
        card.state = .failed
        card.error = message
    }

    private func showCard(near rect: CGRect, on screen: NSScreen) {
        card.answer = ""
        card.error = nil
        card.copied = false
        card.askingMore = false
        card.resetAction()
        card.log = []
        card.state = .thinking
        card.title = "…"
        let panel = cardPanel ?? FloatingPanel(size: CGSize(width: 520, height: 120))
        if cardPanel == nil {
            panel.contentView = NSHostingView(rootView: CardView(model: card) { [weak panel] h in panel?.setHeight(h) })
            cardPanel = panel
        }
        panel.place(near: rect, on: screen)
        panel.orderFrontRegardless()
    }

    // MARK: End

    func cancel() { cancel(keepingOffer: false) }

    private func cancel(keepingOffer: Bool) {
        if phase != .idle { Log.write("cancel from \(phase)") }
        holding = false
        decide(nil)
        if !keepingOffer { offer?.dismiss() }
        Pointer.clear()
        pauseTimer?.invalidate()
        pauseTimer = nil
        streamTask?.cancel()
        streamTask = nil
        captureTask?.cancel()
        captureTask = nil
        voice.abandon()
        speaker.stop()
        pill.listening = false
        pillPanel?.orderOut(nil)
        cardPanel?.orderOut(nil)
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        NSCursor.arrow.set()
        if phase != .idle, NSApp.isActive { frontApp?.activate() }
        phase = .idle
        box = nil
        capture = nil
        messages = []
        mcpTask?.cancel()
        mcpTask = nil
        mcp = nil
        integration = nil
        approveAll = false
        proposal = nil
        editedImage = nil
        actions = []
        codeEdit = nil
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
