import AppKit
import SwiftUI
import Combine
import LlassoKit

/// One request after it is sent: its card, its conversation with the model, and anything it
/// changed. Several can run at once. While it works, a small Working chip at the side of the
/// screen stands in for it; the card comes up beside the chip when there is something to see
/// or decide. Clicking away hides the card and the job carries on; the chip or the menu bar
/// brings it back.
@MainActor
final class Job {
    let id = UUID()
    let card = CardModel()
    let started = Date()
    private var cardPanel: FloatingPanel?
    private var watch: AnyCancellable?
    /// Whether the card had something to show last time it changed, so it comes up once per result.
    private var hadResult = false
    private let speaker: Speaker

    let frontApp: NSRunningApplication?
    let box: (rect: CGRect, screen: NSScreen)
    let verb: Verb?
    private var context: ScreenContext
    private var capture: Capture?
    private var messages: [ChatMessage] = []
    private(set) var lastPrompt = ""
    private var spoken = false
    private var streamTask: Task<Void, Never>?

    private var integration: Integration?
    private var mcp: MCPClient?
    private var approveAll = false
    /// Resumed by the card when the user answers a question or approves a step.
    private var decision: CheckedContinuation<String?, Never>?
    private var proposal: Proposal?
    private var editedImage: Data?
    /// A clip or sound made for this request, and its file extension.
    private var media: (data: Data, ext: String)?
    /// What the router read the request as, started while the screen is captured.
    private var readingTask: Task<Reading, Never>?
    private var reading: Reading?
    /// The chat model this request runs on, and why.
    private var chatChoice: Choice?
    private var modelID: String { chatChoice?.model.id ?? Settings.shared.model }
    private var actions: [String] = []
    /// The code edit on the card, kept so Undo can put the files back.
    private var codeEdit: (checkpoint: Checkpoint, before: String, after: String, files: [FileChange])?

    /// Called when the job is closed, so the controller can drop it.
    var onClose: ((Job) -> Void)?

    init(frontApp: NSRunningApplication?, box: (rect: CGRect, screen: NSScreen), verb: Verb?,
         context: ScreenContext, integration: Integration?, speaker: Speaker) {
        self.frontApp = frontApp
        self.box = box
        self.verb = verb
        self.context = context
        self.integration = integration
        self.speaker = speaker
        card.onStop = { [weak self] in self?.stopAnswer() }
        card.onClose = { [weak self] in self?.close() }
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
        card.title = "…"
        watch = card.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.cardChanged() }
        }
        WorkingDock.shared.refresh()
    }

    /// Something for the user arrived (text, a result, a question, a step, an error): bring
    /// the card up beside the chip. Otherwise keep the chip current.
    private func cardChanged() {
        guard !closed else { return }
        let result = !card.answer.isEmpty || card.proposal != nil || card.question != nil || card.step != nil
            || card.error != nil || (card.state == .done && card.working == nil)
        if result && !hadResult && !isVisible { show() }
        hadResult = result
        WorkingDock.shared.refresh()
    }

    // MARK: State for the menu

    var title: String { card.title == "…" ? "Starting…" : card.title }
    /// Closed with ×: kept in the task list until cleared, but no longer running or waiting.
    private(set) var closed = false
    var isRunning: Bool { !closed && (card.state == .thinking || card.state == .streaming || card.working != nil) }
    /// Waiting on the user: a question, an approval, or a result not yet placed.
    var needsYou: Bool {
        !closed && (card.question != nil || card.step != nil
            || (card.proposal != nil && card.proposal?.done == nil && !(card.proposal?.destinations.isEmpty ?? true)))
    }
    var appName: String { context.appName ?? "" }
    var isVisible: Bool { cardPanel?.isVisible ?? false }
    var cardFrame: CGRect? { cardPanel?.frame }
    func approveAllForTest() { approveAll = true }

    func contains(_ point: CGPoint) -> Bool { cardPanel.map { $0.isVisible && $0.frame.contains(point) } ?? false }
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === cardPanel }

    // MARK: Card

    /// The card, at the side of the screen beside the Working chips. The box itself may have
    /// scrolled away by now, so the card no longer sits on it.
    func show() {
        // Called up from the task list on another desktop: rebuild the card here, since a card
        // stays on the desktop where it first appeared.
        if let old = cardPanel, !old.isVisible, !old.isOnActiveSpace {
            old.close(); cardPanel = nil
        }
        let panel = cardPanel ?? FloatingPanel(size: CGSize(width: 520 + 2 * Glass.margin, height: 120), pinned: true)
        if cardPanel == nil {
            panel.contentView = NSHostingView(rootView: CardView(model: card) { [weak panel] h in panel?.setHeight(h) })
            cardPanel = panel
        }
        if !panel.isVisible { WorkingDock.shared.placeCard(panel, on: NSScreen.main ?? box.screen) }
        panel.orderFrontRegardless()
        WorkingDock.shared.refresh()
    }

    /// Click away: the card goes, the work goes on, and its chip comes back if it is still working.
    func hide() {
        cardPanel?.orderOut(nil)
        WorkingDock.shared.refresh()
    }

    func close() {
        closed = true
        decide(nil)
        streamTask?.cancel()
        streamTask = nil
        if spoken { speaker.stop() }
        Pointer.clear()
        hide()
        onClose?(self)
    }

    static let toolImagesNote = "Images returned by the tool calls above."
    static let staleImages = "(Screenshots from an earlier step were here; the newest ones are further on.)"

    /// The card comes up by itself when the job finishes, so this only keeps the chips current.
    private func finished() { WorkingDock.shared.refresh() }

    // MARK: Asking

    /// Wait for the capture, the app's tools and the words, then run.
    func start(prompt: String, spoken: Bool, captureTask: Task<Capture?, Never>?, mcpTask: Task<MCPClient?, Never>?) async {
        self.spoken = spoken
        lastPrompt = prompt
        startReading(prompt)
        card.title = prompt.isEmpty ? (verb?.label ?? "Explain") + " · " + context.tag : prompt
        guard let cap = await captureTask?.value else {
            fail("Llasso couldn't capture the screen. Check Screen Recording in System Settings.")
            return
        }
        capture = cap
        if let mcpTask { mcp = await mcpTask.value }
        if mcp != nil, let integration { context.integration = integration.name }
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
        messages = Brief.firstMessages(prompt: prompt, verb: verb, context: context,
                                       crop: cap.crop, screen: cap.screen, spoken: spoken, appGuides: guides)
        run()
    }

    /// Read the request now, so the reading is ready by the time the capture is.
    private func startReading(_ prompt: String) {
        let ctx = context
        readingTask = Task { await ModelStore.shared.read(prompt, context: ctx) }
    }

    /// Pick the chat model for this turn and say on the card which one and why.
    private func route() async {
        let r = await readingTask?.value ?? Reader.read(lastPrompt, kind: context.kind, hasSource: context.source != nil)
        reading = r
        let choice = ModelStore.shared.chat(for: r)
        chatChoice = choice
        card.route = RouteLine(work: r.work.label, model: choice.model.name, auto: choice.auto, reason: choice.reason)
        Log.write("router: \(r.work.rawValue)/\(r.difficulty.rawValue) by \(r.source.rawValue) → \(choice.model.id)\(choice.auto ? "" : " (chosen)")")
    }

    func followUp(_ text: String) {
        lastPrompt = text
        startReading(text)
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
        streamTask = Task {
            await route()
            await agentLoop()
        }
    }

    /// Stream a turn; run the tools it asks for; repeat until the model stops asking,
    /// or until it proposes something the user must place.
    private func agentLoop() async {
        let settings = Settings.shared
        let client = settings.client
        let model = modelID
        let speak = spoken && settings.voiceOut != .off
        var tools = BuiltinTool.available(for: context.kind, hasSource: context.source != nil).map(\.schema)
        if let mcp, let integration { tools += Integrations.shared.toolSchemas(mcp, blocked: integration.blocked, offered: integration.offered) }
        var shown = ""
        do {
            // Browsing a page can take many small steps: scroll, read, scroll again.
            for step in 0..<30 {
                let turnStart = Date()
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
                Log.write("turn \(step + 1): \(String(format: "%.1f", Date().timeIntervalSince(turnStart)))s, \(calls.count) call(s), \(messages.count) messages")
                if calls.isEmpty { break }

                var images: [Data] = []
                var stop = false
                for call in calls {
                    if Task.isCancelled { return }
                    let toolStart = Date()
                    let outcome = await handle(call)
                    Log.write("tool: \(call.name) \(String(format: "%.1f", Date().timeIntervalSince(toolStart)))s")
                    messages.append(.toolResult(id: call.id, outcome.text))
                    images += outcome.images
                    if outcome.endsTurn { stop = true }
                }
                if !images.isEmpty {
                    // Only the newest screenshots stay: older ones are stale and slow every later step.
                    for i in messages.indices where messages[i].role == "user" && messages[i].isToolImages {
                        messages[i] = .user(Self.staleImages)
                    }
                    messages.append(ChatMessage(role: "user", parts: images.prefix(3).map { .png($0) }
                        + [.text(Self.toolImagesNote)]))
                }
                if stop { break }
                card.state = .thinking
            }
            card.working = nil
            card.state = .done
            finished()
            if shown.isEmpty && card.proposal == nil && card.question == nil && card.log.isEmpty && card.error == nil {
                card.error = "The model sent nothing back. Try again, or say what you want in more words."
            }
            Log.write("done: \(shown.count) chars, proposal \(card.proposal != nil), log \(card.log)")
            History.append(prompt: lastPrompt, verb: verb, context: context, answer: shown, model: model, actions: actions)
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
        var args = call.args
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
            case .proposeText, .editImage, .setCells, .runScript, .makeVideo, .makeSound:
                guard let p = builtin.proposal(args) else { return Outcome(text: "The arguments were incomplete.") }
                return await propose(p)
            }
        }
        guard let mcp, let (server, tool) = ToolName.split(call.name), server == ToolName.clean(mcp.name),
              let spec = mcp.tools.first(where: { $0.name == tool }) else {
            return Outcome(text: "There is no tool called \(call.name).")
        }
        let why = (args.removeValue(forKey: Integrations.why) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spec.readOnly && !(integration?.safe.contains(tool) ?? false) && !approveAll {
            let title = why.flatMap { $0.isEmpty ? nil : $0 } ?? "\(mcp.name) wants to \(tool.replacingOccurrences(of: "_", with: " "))"
            card.step = (title, "\(mcp.name) · \(tool.replacingOccurrences(of: "_", with: " "))\n" + Self.brief(args))
            card.stepDetailOpen = false
            card.state = .done
            let choice = await waitForDecision()
            card.step = nil
            guard choice == "run" else {
                card.log.append("– skipped \(mcp.name) \(tool)")
                return Outcome(text: "The user skipped this step.", endsTurn: choice == nil)
            }
        }
        card.state = .thinking
        card.working = why.flatMap { $0.isEmpty ? nil : $0 + "…" } ?? "\(mcp.name): \(tool.replacingOccurrences(of: "_", with: " "))…"
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
            // The boxed picture always goes along, so the model has to take pictures.
            let choice = ModelStore.shared.choose(.image, difficulty: reading?.difficulty ?? .moderate)
            card.working = "Making the image with \(choice.model.name)…"
            card.state = .thinking
            do {
                let image = try await Settings.shared.client.image(model: choice.model.id,
                                                                   prompt: instruction, source: crop)
                card.working = nil
                editedImage = image
                cardP.image = image
                cardP.madeBy = Self.madeBy(choice)
            } catch {
                card.working = nil
                card.error = "Image edit: " + error.localizedDescription
                return Outcome(text: "The image model failed: \(error.localizedDescription)", endsTurn: true)
            }
        case .cells(_, let rows, _):
            cardP.rows = rows
        case .script(let source, _):
            cardP.script = source
        case .video(let prompt, let fromBox, let seconds, let aspect, _):
            let choice = ModelStore.shared.choose(.motion, difficulty: reading?.difficulty ?? .moderate)
            let m = choice.model
            let frame = fromBox && (m.frames.contains("first_frame") || m.frames.isEmpty) ? capture?.crop : nil
            let shape = aspect ?? Self.aspect(of: box.rect.size, from: m.aspects)
            let length = Self.nearest(seconds ?? 5, in: m.durations)
            let resolution = m.resolutions.first { $0 == "720p" } ?? m.resolutions.first { $0 == "768p" }
            card.state = .thinking
            card.working = "Making a \(length.map { "\($0) s " } ?? "")clip with \(m.name). This can take a few minutes…"
            do {
                let clip = try await Settings.shared.client.video(model: m.id, prompt: prompt, firstFrame: frame, seconds: length,
                                                                  aspect: shape, resolution: resolution) { status in
                    Task { @MainActor [weak self] in
                        guard let self, self.card.working != nil else { return }
                        self.card.working = "\(m.name): " + (status == "in_progress" ? "making the clip…" : "\(status.replacingOccurrences(of: "_", with: " "))…")
                    }
                }
                card.working = nil
                media = (clip, "mp4")
                cardP.mediaURL = Self.preview(clip, ext: "mp4")
                cardP.madeBy = Self.madeBy(choice)
            } catch {
                card.working = nil
                card.error = "Video: " + error.localizedDescription
                return Outcome(text: "The video model failed: \(error.localizedDescription)", endsTurn: true)
            }
        case .sound(let prompt, let type, _):
            let choice = ModelStore.shared.choose(.sound, difficulty: reading?.difficulty ?? .moderate, fits: { $0.sound == type })
            card.state = .thinking
            card.working = (type == .speech ? "Recording the words with " : "Making the sound with ") + choice.model.name + "…"
            do {
                let client = Settings.shared.client
                let audio = type == .speech
                    ? try await client.speech(model: choice.model.id, voice: Settings.voice(for: choice.model), text: prompt)
                    : try await client.music(model: choice.model.id, prompt: prompt)
                card.working = nil
                media = (audio, "mp3")
                cardP.mediaURL = Self.preview(audio, ext: "mp3")
                cardP.isAudio = true
                cardP.madeBy = Self.madeBy(choice)
            } catch {
                card.working = nil
                card.error = "Sound: " + error.localizedDescription
                return Outcome(text: "The sound model failed: \(error.localizedDescription)", endsTurn: true)
            }
        }
        card.proposal = cardP
        // Text that can go back where it came from goes straight back; the card offers Undo.
        if case .text(let text, _) = p, let place = cardP.destinations.first(where: { if case .replaceInPlace = $0 { return true }; return false }) {
            card.working = "Putting it back…"
            do {
                let result = try await ActionQueue.run { [context, frontApp] in
                    try await Actuator.text(text, to: place, context: context, app: frontApp)
                }
                card.working = nil
                card.proposal?.done = result
                card.proposal?.destinations = [.undoText(app: context.appName ?? "the app"), .copy]
                actions.append(place.label + " (automatic)")
                History.append(prompt: lastPrompt, verb: verb, context: context, answer: card.answer,
                               model: modelID, actions: actions)
                return Outcome(text: "\(result) The user can undo it from the card. Do not repeat the text.", endsTurn: true)
            } catch {
                // Couldn't put it back (nothing selected, app busy): Replace stays on the card to try again.
                card.working = nil
                card.proposal?.note = error.localizedDescription
            }
        }
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
        History.append(prompt: lastPrompt, verb: verb, context: context, answer: card.answer,
                       model: modelID, actions: actions)
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
                let result = try await ActionQueue.run { try await self.act(p, to: d, context: ctx, app: app, image: image) }
                card.working = nil
                card.proposal?.done = result
                card.proposal?.note = nil
                if case .undoText = d { card.proposal?.destinations = [.copy] }
                if case .replaceInPlace = d { card.proposal?.destinations = [.undoText(app: ctx.appName ?? "the app"), .copy] }
                if case .replaceImage(let name) = d { card.proposal?.destinations = [.undoImage(name: name), .copy, .saveAs] }
                if case .undoImage = d { card.proposal?.destinations = [.copy, .saveAs] }
                actions.append(d.label)
                messages.append(.user("(Llasso note, not from the user) The user chose “\(d.label)”. \(result)"))
                History.append(prompt: lastPrompt, verb: verb, context: ctx, answer: card.answer,
                               model: modelID, actions: actions)
            } catch ActionError.cancelled {
                card.working = nil
            } catch {
                card.working = nil
                card.error = error.localizedDescription
            }
        }
    }

    private func act(_ p: Proposal, to d: Destination, context ctx: ScreenContext, app: NSRunningApplication?,
                     image: Data?) async throws -> String {
        switch p {
        case .text(let text, _): return try await Actuator.text(text, to: d, context: ctx, app: app)
        case .image:
            guard let image else { throw ActionError.failed("The edited image is missing.") }
            let fit = capture.flatMap { NSBitmapImageRep(data: $0.crop) }
                .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            return try await Actuator.image(image, to: d, context: ctx, app: app, fit: fit, points: box.rect.size)
        case .cells(let start, let rows, _): return try await Actuator.cells(start: start, rows: rows, to: d, context: ctx, app: app)
        case .script(let source, _): return try await Actuator.run(script: source)
        case .video, .sound:
            guard let media else { throw ActionError.failed("The clip is missing.") }
            return try Actuator.media(media.data, ext: media.ext, to: d, context: ctx)
        }
    }

    /// The line under a made thing that says which model made it and why.
    static func madeBy(_ c: Choice) -> String {
        "Made with \(c.model.name). " + (c.auto ? c.reason : "Your choice for \(c.work.label.lowercased()).")
    }

    /// A temporary copy the card can play from; nothing is saved anywhere the user keeps.
    static func preview(_ data: Data, ext: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Llasso preview \(UUID().uuidString.prefix(6)).\(ext)")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// The model's shape nearest the box, so a clip of a tall box comes out tall.
    static func aspect(of size: CGSize, from shapes: [String]) -> String? {
        let wanted = size.height > 0 ? size.width / size.height : 16.0 / 9
        let options = shapes.isEmpty ? ["16:9", "9:16", "1:1"] : shapes
        return options.min { a, b in
            func ratio(_ s: String) -> Double {
                let p = s.split(separator: ":").compactMap { Double($0) }
                return p.count == 2 && p[1] > 0 ? p[0] / p[1] : 1
            }
            return abs(log(ratio(a) / wanted)) < abs(log(ratio(b) / wanted))
        }
    }

    /// The length the model accepts nearest the one asked for.
    static func nearest(_ seconds: Int, in options: [Int]) -> Int? {
        options.isEmpty ? seconds : options.min { abs($0 - seconds) < abs($1 - seconds) }
    }

    private func waitForDecision() async -> String? {
        return await withCheckedContinuation { cont in
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

    func stopAnswer() {
        decide(nil)
        streamTask?.cancel()
        streamTask = nil
        speaker.stop()
        card.working = nil
        Pointer.clear()
        Log.write("stopped: \(title.prefix(60))")
        if card.state != .failed { card.state = .done }
    }

    private func fail(_ message: String) {
        Log.write("failed: " + message)
        card.state = .failed
        card.error = message
        finished()
    }

}

extension ChatMessage {
    /// A user message carrying screenshots that tools returned.
    var isToolImages: Bool {
        parts.contains { if case .text(let t) = $0 { return t == Job.toolImagesNote }; return false }
    }
}
