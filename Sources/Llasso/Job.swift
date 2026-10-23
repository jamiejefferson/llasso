import AppKit
import SwiftUI
import LlassoKit

/// One request after it is sent: its card, its conversation with the model, and anything it
/// changed. Several can run at once. Clicking away hides the card and the job carries on;
/// the menu bar lists every job and brings its card back.
@MainActor
final class Job {
    let id = UUID()
    let card = CardModel()
    let started = Date()
    private var cardPanel: FloatingPanel?
    private var outline: NSWindow?
    private var lasso: LassoView?
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
        show()
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

    func contains(_ point: CGPoint) -> Bool { cardPanel.map { $0.isVisible && $0.frame.contains(point) } ?? false }
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === cardPanel }

    // MARK: Card

    func show() {
        // Called up from the task list on another desktop: rebuild the card here, since a card
        // stays on the desktop where it first appeared.
        if let old = cardPanel, !old.isVisible, !old.isOnActiveSpace {
            old.close(); cardPanel = nil
            outline?.close(); outline = nil; lasso = nil
        }
        let panel = cardPanel ?? FloatingPanel(size: CGSize(width: 520 + 2 * Glass.margin, height: 120), pinned: true)
        if cardPanel == nil {
            panel.contentView = NSHostingView(rootView: CardView(model: card) { [weak panel] h in panel?.setHeight(h) })
            cardPanel = panel
            panel.place(near: box.rect, on: box.screen)
        }
        panel.orderFrontRegardless()
        showOutline()
    }

    /// Click away: the card goes, the work goes on.
    func hide() {
        cardPanel?.orderOut(nil)
        outline?.orderOut(nil)
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

    private func showOutline() {
        if outline == nil {
            let (o, view) = LassoWindow.make(round: box.rect)
            view.apply(.resting, animated: false)
            outline = o
            lasso = view
        }
        outline?.orderFrontRegardless()
    }

    /// Tell the user when a job they can't see finishes.
    private func finished() {
        guard !isVisible else { return }
        let what = card.state == .failed ? "stopped with a problem" : (needsYou ? "is ready for you" : "finished")
        Toast.show("Llasso \(what): \(title.prefix(60)). Open it from the menu bar.", seconds: 5)
    }

    // MARK: Asking

    /// Wait for the capture, the app's tools and the words, then run.
    func start(prompt: String, spoken: Bool, captureTask: Task<Capture?, Never>?, mcpTask: Task<MCPClient?, Never>?) async {
        self.spoken = spoken
        lastPrompt = prompt
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

    func followUp(_ text: String) {
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
                outline?.orderOut(nil)
                History.append(prompt: lastPrompt, verb: verb, context: context, answer: card.answer,
                               model: Settings.shared.model, actions: actions)
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
                let result = try await ActionQueue.run { try await self.act(p, to: d, context: ctx, app: app, image: image) }
                card.working = nil
                card.proposal?.done = result
                card.proposal?.note = nil
                if case .undoText = d { card.proposal?.destinations = [.copy] }
                if case .replaceInPlace = d { card.proposal?.destinations = [.undoText(app: ctx.appName ?? "the app"), .copy] }
                actions.append(d.label)
                messages.append(.user("(Llasso note, not from the user) The user chose “\(d.label)”. \(result)"))
                History.append(prompt: lastPrompt, verb: verb, context: ctx, answer: card.answer,
                               model: Settings.shared.model, actions: actions)
                // Leaving the boxed app's change in view: drop the outline once text went back in place.
                if case .replaceInPlace = d { outline?.orderOut(nil) }
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
        }
    }

    private func waitForDecision() async -> String? {
        if !isVisible { Toast.show("Llasso needs you: \(card.title.prefix(60)). Open it from the menu bar.", seconds: 5) }
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
        if card.state != .failed { card.state = .done }
    }

    private func fail(_ message: String) {
        Log.write("failed: " + message)
        card.state = .failed
        card.error = message
        finished()
    }

}
