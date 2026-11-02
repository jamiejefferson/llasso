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
    /// What a plan made, in the order the card shows it.
    private var planResults: [Made] = []
    /// What the router read the request as, started while the screen is captured.
    private var readingTask: Task<Reading, Never>?
    private var reading: Reading?
    /// The chat model this request runs on, and why.
    private var chatChoice: Choice?
    private var modelID: String { chatChoice?.model.id ?? Settings.shared.model }
    private var actions: [String] = []
    /// This request changed the app's file through its tools, and whether Llasso has since
    /// checked for other places the same change belongs.
    private var changedInApp = false
    private var widerChecked = false
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
        card.onResultDestination = { [weak self] i, d in self?.deliver(to: d, result: i) }
        card.onPlan = { [weak self] yes in self?.decide(yes ? "run" : nil) }
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
            || card.plan != nil || !card.results.isEmpty
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
        !closed && (card.question != nil || card.step != nil || card.plan?.approved == false
            || card.results.contains { $0.done == nil && !$0.destinations.isEmpty }
            || (card.proposal != nil && card.proposal?.done == nil && !(card.proposal?.destinations.isEmpty ?? true)))
    }
    var appName: String { context.appName ?? "" }
    var isVisible: Bool { cardPanel?.isVisible ?? false }
    var cardFrame: CGRect? { cardPanel?.frame }
    func approveAllForTest() { approveAll = true }
    func proposeForTest(_ p: Proposal) async { _ = await propose(p) }
    func lookForTest(_ args: [String: Any]) async -> String { await look(args).text }
    func ringForTest(crop: Data, x: Double, y: Double, target: String) {
        capture = Capture(crop: crop, screen: crop)
        ring(x: x, y: y, label: "Test", target: target)
    }

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
        if let mcp, editsFile { guides.append(Brief.canvasGuide(app: mcp.name)) }
        if Glance.on { guides.append(Brief.lookGuide) }
        if context.photoshop != nil { guides.append(PhotoshopTool.guide) }
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
        // Pictures, clips and sound are made by their own model, so the card names that one.
        let shown = r.work.kind == .chat ? choice : ModelStore.shared.media(r.work, reading: r)
        card.route = RouteLine(work: shown.label ?? r.work.label, model: shown.model.name, auto: shown.auto, reason: shown.reason)
        Log.write("router: \(r.work.rawValue)/\(r.difficulty.rawValue) by \(r.source.rawValue) → \(choice.model.id)\(choice.auto ? "" : " (chosen)")")
    }

    /// The connected app's tools edit its file, so text changes go through them.
    private var editsFile: Bool { mcp != nil && !(integration?.edits.isEmpty ?? true) }

    func followUp(_ text: String) {
        lastPrompt = text
        changedInApp = false
        widerChecked = false
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
        var builtins = BuiltinTool.available(for: context.kind, hasSource: context.source != nil)
        // A paste can't reach a design file, so its text changes go through the app's own tools.
        if editsFile { builtins.removeAll { $0 == .proposeText } }
        if Glance.on { builtins.append(.look) }
        var tools = builtins.map(\.schema)
        if let mcp, let integration { tools += Integrations.shared.toolSchemas(mcp, blocked: integration.blocked, offered: integration.offered) }
        if context.photoshop != nil { tools += PhotoshopTool.allCases.map(\.schema) }
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
                // A change in the app's file isn't done until Llasso has looked for the other
                // places it belongs, such as the same word on other artboards.
                if calls.isEmpty, changedInApp, !widerChecked, let mcp {
                    widerChecked = true
                    messages.append(.user(Brief.widerCheck(app: mcp.name)))
                    card.working = "Checking whether this belongs anywhere else…"
                    card.state = .thinking
                    Log.write("wider check")
                    continue
                }
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
            if shown.isEmpty && card.proposal == nil && card.plan == nil && card.results.isEmpty && card.question == nil && card.log.isEmpty && card.error == nil {
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
                let label = args["label"] as? String ?? "Here"
                ring(x: args["x"] as? Double ?? 0.5, y: args["y"] as? Double ?? 0.5, label: label,
                     target: (args["target"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label)
                return Outcome(text: "Ringed the point on screen.")
            case .look:
                return await look(args)
            case .editCode:
                return await editCode(instruction: args["instruction"] as? String ?? lastPrompt,
                                      summary: args["summary"] as? String ?? "")
            case .makePlan:
                return await runPlan(args)
            case .proposeText, .editImage, .setCells, .runScript, .makeVideo, .makeSound:
                guard let p = builtin.proposal(args) else { return Outcome(text: "The arguments were incomplete.") }
                return await propose(p)
            }
        }
        if let tool = PhotoshopTool.named(call.name) { return await photoshop(tool, args) }
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
        // A change to the app's file: look at the screen before, to tell afterwards whether it shows.
        let edits = integration?.edits.contains(tool) == true
        let before = edits && Glance.on ? await Glance.screen(box) : nil
        do {
            let r = try await mcp.callTool(tool, arguments: args)
            if !spec.readOnly { actions.append("\(mcp.name).\(tool)") }
            if !r.isError, edits { changedInApp = true }
            var text = String(r.text.prefix(20_000)).ifEmpty("Done.")
            var line = (r.isError ? "✕ " : "✓ ") + "\(mcp.name) \(tool)"
            if !r.isError, let before {
                let change = why.flatMap { $0.isEmpty ? nil : $0 } ?? "\(mcp.name) \(tool.replacingOccurrences(of: "_", with: " "))"
                // One look: changes in the file are often off screen, where a second look can't help.
                switch await Glance.landed(change, before: before, box: box, retry: false) {
                case let p? where p >= 0.5:
                    line += " · seen on screen"
                    text += "\n\nLlasso looked at the screen afterwards: the change shows."
                case .some:
                    text += "\n\nLlasso looked at the screen afterwards and can't see the change. That is expected when it is outside the visible area; if it should be on screen, check it with the app's tools."
                case nil: break
                }
            }
            card.log.append(line)
            return Outcome(text: text, images: r.images)
        } catch {
            card.log.append("✕ \(mcp.name) \(tool)")
            return Outcome(text: "The tool failed: \(error.localizedDescription)")
        }
    }

    /// One of Photoshop's own tools, run straight away: each is one step in Photoshop's
    /// History, so the user takes it back there.
    private func photoshop(_ tool: PhotoshopTool, _ args: [String: Any]) async -> Outcome {
        guard let ps = context.photoshop else { return Outcome(text: "There is no Photoshop document under the box.") }
        let label = (args["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? tool.rawValue.replacingOccurrences(of: "photoshop_", with: "").replacingOccurrences(of: "_", with: " ")
        card.state = .thinking
        card.working = "Photoshop: \(label.lowercased())…"
        defer { card.working = nil }
        let box = self.box.rect
        let before = Glance.on ? await Glance.screen(self.box) : nil
        do {
            let now = try await ActionQueue.run { try await PhotoshopApp.tool(tool, args: args, state: ps, box: box) }
            if let now { context.photoshop = now }
            var seen = ""
            if let before, let p = await Glance.landed(label, before: before, box: self.box, retry: false) {
                seen = p >= 0.5 ? " It shows on screen." : " Llasso can't see it on screen."
            }
            card.log.append("✓ Photoshop: " + label + (seen.hasPrefix(" It") ? " · seen on screen" : ""))
            actions.append("photoshop: \(label)")
            let sel = context.photoshop?.selection.map { "the selection is \(Int($0.minX)),\(Int($0.minY)) to \(Int($0.maxX)),\(Int($0.maxY)) px" }
                ?? "nothing is selected"
            return Outcome(text: "Done in Photoshop as one History step. Now \(sel).\(seen)")
        } catch {
            card.log.append("✕ Photoshop: " + label)
            Log.write("photoshop: \(tool.rawValue) failed: \(error.localizedDescription)")
            return Outcome(text: "It didn't work: \(error.localizedDescription)")
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
            card.state = .thinking
            do {
                // The boxed picture always goes along, so the model has to take pictures. In
                // Photoshop it is the document's own pixels for the area, at full resolution.
                var sources = [crop], prompt = instruction
                if let ps = context.photoshop {
                    card.working = "Taking \(ps.regionSource) from Photoshop…"
                    sources = [try await PhotoshopApp.export(ps)]
                    prompt += "\n\nKeep the framing and aspect ratio exactly as they are, so the result lines up with the original."
                }
                let (image, choice) = try await makeImage(prompt, sources: sources)
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
            card.state = .thinking
            do {
                let (clip, choice) = try await makeVideo(prompt, frame: fromBox ? capture?.crop : nil, seconds: seconds, aspect: aspect)
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
            card.state = .thinking
            do {
                let (audio, choice) = try await makeSound(prompt, type: type)
                card.working = nil
                media = (audio, Audio.ext(of: audio))
                cardP.mediaURL = Self.preview(audio, ext: Audio.ext(of: audio))
                cardP.isAudio = true
                cardP.madeBy = Self.madeBy(choice)
            } catch {
                card.working = nil
                card.error = "Sound: " + error.localizedDescription
                return Outcome(text: "The sound model failed: \(error.localizedDescription)", endsTurn: true)
            }
        }
        if case .text = p { askToReplace(&cardP) }
        card.proposal = cardP
        return Outcome(text: "Shown to the user, who will choose where it goes. Do not repeat it.", endsTurn: true)
    }

    /// Text always checks whether it can go back where it came from, and asks first.
    private func askToReplace(_ cardP: inout ProposalCard) {
        let app = context.appName ?? "the app"
        if cardP.destinations.contains(where: { if case .replaceInPlace = $0 { return true }; return false }) {
            cardP.ask = context.boxedRange != nil ? "Replace the boxed text in \(app) with this?"
                : context.canSetField ? "Replace what's in the field in \(app) with this?"
                : context.mayHoldSelection ? "Replace your selection in \(app) with this?"
                : "Replace the selected text in \(app) with this?"
        } else {
            cardP.note = "Llasso can't change the text in \(app) from here. Select the text and ask again to replace it, or copy this."
        }
    }

    // MARK: Making

    private func makeImage(_ instruction: String, sources: [Data]) async throws -> (Data, Choice) {
        let choice = ModelStore.shared.media(.image, reading: reading)
        card.working = "Making the image with \(choice.model.name)…"
        let image = try await Settings.shared.client.image(model: choice.model.id, prompt: instruction,
                                                           sources: sources, makes: choice.model.makes)
        return (image, choice)
    }

    /// A clip, starting from `frame` when the model can start from a picture.
    private func makeVideo(_ prompt: String, frame: Data?, seconds: Int?, aspect: String?) async throws -> (Data, Choice) {
        let choice = ModelStore.shared.media(.motion, reading: reading)
        let m = choice.model
        let first = m.frames.contains("first_frame") || m.frames.isEmpty ? frame : nil
        let shape = aspect ?? Self.aspect(of: box.rect.size, from: m.aspects)
        let length = Self.nearest(seconds ?? 5, in: m.durations)
        let resolution = m.resolutions.first { $0 == "720p" } ?? m.resolutions.first { $0 == "768p" }
        card.working = "Making a \(length.map { "\($0) s " } ?? "")clip with \(m.name). This can take a few minutes…"
        let clip = try await Settings.shared.client.video(model: m.id, prompt: prompt, firstFrame: first, seconds: length,
                                                          aspect: shape, resolution: resolution) { status in
            Task { @MainActor [weak self] in
                guard let self, self.card.working != nil else { return }
                self.card.working = "\(m.name): " + (status == "in_progress" ? "making the clip…" : "\(status.replacingOccurrences(of: "_", with: " "))…")
            }
        }
        return (clip, choice)
    }

    private func makeSound(_ prompt: String, type: SoundType) async throws -> (Data, Choice) {
        let choice = soundChoice(type)
        card.working = (type == .speech ? "Recording the words with " : "Making the sound with ") + choice.model.name + "…"
        let client = Settings.shared.client
        let audio = type == .speech
            ? try await client.speech(model: choice.model.id, voice: Settings.voice(for: choice.model), text: prompt)
            : try await client.music(model: choice.model.id, prompt: prompt)
        return (audio, choice)
    }

    private func soundChoice(_ type: SoundType) -> Choice {
        ModelStore.shared.media(.sound, reading: reading, sound: type)
    }

    // MARK: Plans

    /// One thing a plan's step made, and the model that made it.
    private struct Piece {
        enum Kind { case text(String), image(Data), video(Data), sound(Data) }
        var kind: Kind
        var madeBy: String
        /// The model's name, for a combine's line.
        var model = ""
    }

    /// One result on the card from a plan, with what its chips need.
    private struct Made {
        var proposal: Proposal
        var image: Data?
        var media: (data: Data, ext: String)?
    }

    /// The model a step runs on; nil for a combine, which runs on this Mac.
    private func choice(for step: PlanStep) -> Choice? {
        guard let work = step.work else { return nil }
        if work == .sound { return soundChoice(step.speech ? .speech : .music) }
        return work.kind == .chat ? ModelStore.shared.choose(work, difficulty: reading?.difficulty ?? .moderate)
            : ModelStore.shared.media(work, reading: reading)
    }

    /// Show the plan, wait for a yes, make each step on its own model, then show the results.
    private func runPlan(_ args: [String: Any]) async -> Outcome {
        let plan: Plan
        switch Plan.parse(args) {
        case .failure(let e): return Outcome(text: "The plan can't run: \(e.message) Fix it and call make_plan again, or use one tool.")
        case .success(let p): plan = p
        }
        var costs: [String] = []
        let lines = plan.steps.map { step -> PlanCard.Line in
            let c = choice(for: step)
            if step.kind == .video, let m = c?.model, let perSecond = m.price.perSecond {
                let seconds = Self.nearest(step.seconds ?? 5, in: m.durations) ?? 5
                costs.append("The \(seconds) s clip costs \(Prices.money(perSecond * Double(seconds))) and can take a few minutes.")
            }
            let numbers = step.uses.compactMap { id in plan.steps.firstIndex { $0.id == id }.map { String($0 + 1) } }
            return PlanCard.Line(id: step.id, label: step.label, model: c?.model.name ?? "On this Mac",
                                 summary: step.summary.ifEmpty(step.instruction),
                                 uses: numbers.isEmpty ? nil : "uses " + numbers.joined(separator: " and "))
        }
        card.plan = PlanCard(summary: plan.summary, lines: lines, note: costs.isEmpty ? nil : costs.joined(separator: " "))
        card.state = .done
        Log.write("plan: \(plan.steps.map { "\($0.id) \($0.kind.rawValue)\($0.uses.isEmpty ? "" : "<" + $0.uses.joined(separator: ","))" }.joined(separator: ", "))")
        guard await waitForDecision() == "run" else {
            card.plan = nil
            card.log.append("– plan cancelled, nothing made")
            return Outcome(text: "The user cancelled the plan, so nothing was made.", endsTurn: true)
        }
        card.plan?.approved = true
        card.state = .thinking
        actions.append("plan: \(plan.steps.count) steps")
        var made: [String: Piece] = [:]
        var failure: String?
        for (i, step) in plan.steps.enumerated() {
            if Task.isCancelled { return Outcome(text: "Stopped.", endsTurn: true) }
            card.plan?.lines[i].status = .working
            do {
                made[step.id] = try await make(step, number: i + 1, from: made, plan: plan)
                card.plan?.lines[i].status = .done
            } catch {
                card.plan?.lines[i].status = .failed
                failure = "Step \(i + 1) (\(step.label.lowercased())): \(error.localizedDescription)"
                break
            }
        }
        card.working = nil
        // When a step fails, everything already made is still shown, so nothing paid for is lost.
        let shown = failure == nil ? plan.finals : plan.steps.filter { made[$0.id] != nil }
        planResults = []
        card.results = []
        for step in shown {
            guard let piece = made[step.id] else { continue }
            let (m, cardP) = result(step, piece)
            planResults.append(m)
            card.results.append(cardP)
        }
        if let failure {
            card.error = failure
            return Outcome(text: "The plan stopped. \(failure). What was made so far is shown.", endsTurn: true)
        }
        return Outcome(text: "Made \(plan.steps.count) steps; the user sees \(shown.count) result\(shown.count == 1 ? "" : "s") and chooses where each goes. Do not repeat them.",
                       endsTurn: true)
    }

    private func make(_ step: PlanStep, number: Int, from made: [String: Piece], plan: Plan) async throws -> Piece {
        let inputs = step.uses.compactMap { made[$0] }
        let texts = inputs.compactMap { if case .text(let t) = $0.kind { return t } else { return nil } }
        let images = inputs.compactMap { if case .image(let d) = $0.kind { return d } else { return nil } }
        let box = step.fromBox ? capture?.crop : nil
        let withTexts = texts.isEmpty ? step.instruction
            : step.instruction + "\n\nUse this text, made earlier for the same request:\n" + texts.joined(separator: "\n\n")
        switch step.kind {
        case .text:
            let c = choice(for: step)!
            card.working = "Writing with \(c.model.name)…"
            var brief = "The user asked: \(lastPrompt)\n\nYour part of it: \(step.instruction)"
            if let boxed = context.selectedText ?? context.fieldValue, !boxed.isEmpty { brief += "\n\nThe text in the box:\n" + boxed }
            if !texts.isEmpty { brief += "\n\nText made earlier for this request:\n" + texts.joined(separator: "\n\n") }
            brief += "\n\nReply with only the finished text, with no preamble. Use British English."
            let parts: [ChatPart] = ([box].compactMap { $0 } + images).map { .png($0) } + [.text(brief)]
            var out = ""
            for try await piece in Settings.shared.client.streamChat(model: c.model.id, messages: [ChatMessage(role: "user", parts: parts)]) {
                out += piece
            }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Combine.Failure(message: "the writer sent nothing back") }
            return Piece(kind: .text(text), madeBy: Self.madeBy(c), model: c.model.name)
        case .image:
            let (image, c) = try await makeImage(withTexts, sources: [box].compactMap { $0 } + images)
            return Piece(kind: .image(image), madeBy: Self.madeBy(c), model: c.model.name)
        case .video:
            let (clip, c) = try await makeVideo(withTexts, frame: images.first ?? box, seconds: step.seconds, aspect: nil)
            return Piece(kind: .video(clip), madeBy: Self.madeBy(c), model: c.model.name)
        case .sound:
            // Speech reads out the text an earlier step wrote, when there is one.
            let words = step.speech && !texts.isEmpty ? texts.joined(separator: "\n\n") : withTexts
            let (audio, c) = try await makeSound(words, type: step.speech ? .speech : .music)
            return Piece(kind: .sound(audio), madeBy: Self.madeBy(c), model: c.model.name)
        case .combine:
            card.working = "Joining the parts on this Mac…"
            var picture: Piece.Kind?, sound: Data?
            for p in inputs {
                switch p.kind {
                case .video, .image: picture = p.kind
                case .sound(let d): sound = d
                case .text: break
                }
            }
            guard let sound, let picture else { throw Combine.Failure(message: "a combine needs a clip or picture and a sound") }
            let clip: Data
            switch picture {
            case .video(let v): clip = try await Combine.clip(v, with: sound, soundExt: Audio.ext(of: sound))
            case .image(let i): clip = try await Combine.still(i, with: sound, soundExt: Audio.ext(of: sound))
            default: throw Combine.Failure(message: "a combine needs a clip or picture")
            }
            let parts = step.uses.compactMap { id -> String? in
                guard let p = made[id], let n = plan.steps.firstIndex(where: { $0.id == id }) else { return nil }
                return "step \(n + 1) by \(p.model)"
            }
            return Piece(kind: .video(clip), madeBy: "Joined on this Mac from " + parts.joined(separator: " and ") + ".")
        }
    }

    /// A plan's piece as a result on the card, with the same chips a single result would get.
    private func result(_ step: PlanStep, _ piece: Piece) -> (Made, ProposalCard) {
        let summary = step.summary.ifEmpty(step.label)
        let m: Made
        switch piece.kind {
        case .text(let t): m = Made(proposal: .text(text: t, summary: summary))
        case .image(let d): m = Made(proposal: .image(instruction: step.instruction, summary: summary), image: d)
        case .video(let d): m = Made(proposal: .video(prompt: step.instruction, fromBox: step.fromBox, seconds: step.seconds, aspect: nil, summary: summary), media: (d, "mp4"))
        case .sound(let d): m = Made(proposal: .sound(prompt: step.instruction, type: step.speech ? .speech : .music, summary: summary), media: (d, Audio.ext(of: d)))
        }
        var cardP = ProposalCard(summary: summary, destinations: Actuator.destinations(for: m.proposal, context: context))
        cardP.madeBy = piece.madeBy
        switch piece.kind {
        case .text(let t):
            cardP.text = t
            askToReplace(&cardP)
        case .image(let d): cardP.image = d
        case .video(let d): cardP.mediaURL = Self.preview(d, ext: "mp4")
        case .sound(let d):
            cardP.mediaURL = Self.preview(d, ext: Audio.ext(of: d))
            cardP.isAudio = true
        }
        return (m, cardP)
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
    /// `result` picks one of a plan's results; nil is the single proposal.
    private func deliver(to d: Destination, result index: Int? = nil) {
        switch d {
        case .keepCode, .undoCode, .openCode: deliverCode(d); return
        default: break
        }
        let made: Made
        if let index {
            guard planResults.indices.contains(index) else { return }
            made = planResults[index]
        } else {
            guard let p = proposal else { return }
            made = Made(proposal: p, image: editedImage, media: media)
        }
        let ctx = context
        let app = frontApp
        card.working = d == .run ? "Running…" : "Working…"
        Task {
            do {
                let before = d.changesScreen && Glance.on ? await Glance.screen(box) : nil
                let result = try await ActionQueue.run { try await self.act(made.proposal, to: d, context: ctx, app: app,
                                                                             image: made.image, media: made.media) }
                card.working = nil
                if let before { check(made.proposal, before: before, result: index) }
                update(index) { p in
                    p.done = result
                    p.note = nil
                    if case .undoText = d { p.destinations = [.copy] }
                    if case .replaceInPlace = d { p.destinations = [.undoText(app: ctx.appName ?? "the app"), .copy] }
                    if case .replaceImage(let name) = d { p.destinations = [.undoImage(name: name), .copy, .saveAs] }
                    if case .undoImage = d { p.destinations = [.copy, .saveAs] }
                    if case .addLayer = d, let placed = Actuator.lastLayer {
                        p.destinations = [.undoLayer(document: placed.document, layer: placed.layer), .copy, .saveAs]
                    }
                    if case .undoLayer = d { p.destinations = [.addLayer(app: ctx.appName ?? "Photoshop"), .copy, .saveAs] }
                }
                actions.append(d.label)
                messages.append(.user("(Llasso note, not from the user) The user chose “\(d.label)”\(index.map { " for result \($0 + 1)" } ?? ""). \(result)"))
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

    /// Change the single proposal on the card, or one of a plan's results.
    private func update(_ index: Int?, _ change: (inout ProposalCard) -> Void) {
        if let index {
            if card.results.indices.contains(index) { change(&card.results[index]) }
        } else if card.proposal != nil {
            change(&card.proposal!)
        }
    }

    private func act(_ p: Proposal, to d: Destination, context ctx: ScreenContext, app: NSRunningApplication?,
                     image: Data?, media: (data: Data, ext: String)?) async throws -> String {
        switch p {
        case .text(let text, _): return try await Actuator.text(text, to: d, context: ctx, app: app)
        case .image:
            guard let image else { throw ActionError.failed("The edited image is missing.") }
            let fit = capture.flatMap { NSBitmapImageRep(data: $0.crop) }
                .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            return try await Actuator.image(image, to: d, context: ctx, app: app, fit: fit, points: box.rect.size, summary: p.summary)
        case .cells(let start, let rows, _): return try await Actuator.cells(start: start, rows: rows, to: d, context: ctx, app: app)
        case .script(let source, _): return try await Actuator.run(script: source)
        case .video, .sound:
            guard let media else { throw ActionError.failed("The clip is missing.") }
            return try Actuator.media(media.data, ext: media.ext, to: d, context: ctx)
        }
    }

    /// The line under a made thing that says which model made it and why.
    static func madeBy(_ c: Choice) -> String {
        "Made with \(c.model.name). " + (c.auto ? c.reason : "Your choice for \((c.label ?? c.work.label).lowercased()).")
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

    /// A point given as fractions of the boxed image, on screen.
    private func onScreen(_ x: Double, _ y: Double) -> CGPoint {
        let fx = min(1, max(0, x)), fy = min(1, max(0, y))
        return CGPoint(x: box.rect.minX + box.rect.width * fx, y: box.rect.maxY - box.rect.height * fy)
    }

    /// Where each ring went: the model's point, and Jev's when a closer look moved it. For tests.
    private(set) var rings: [(model: CGPoint, jev: CGPoint?, moved: Bool)] = []

    /// Ring the model's point straight away, then let Jev find `target` in the boxed image;
    /// when a close-up confirms it somewhere else, the ring moves there.
    private func ring(x: Double, y: Double, label: String, target: String) {
        let panel = Pointer.ring(at: onScreen(x, y), label: label)
        card.log.append("◎ " + label)
        rings.append((CGPoint(x: x, y: y), nil, false))
        let index = rings.count - 1
        guard Glance.on, let crop = capture?.crop else { return }
        Task { [weak self] in
            guard let found = await Glance.find(target, in: crop), let self, !self.closed else { return }
            let spot = CGPoint(x: found.midX, y: found.midY)
            self.rings[index].jev = spot
            guard hypot(spot.x - x, spot.y - y) > 0.04,
                  let image = NSImage(data: crop)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            // Move only when a close-up of the model's own point says it missed.
            let model = await Glance.shows(target, at: CGPoint(x: x, y: y), size: found.size, in: image) ?? 1
            Log.write("ring: \(label.prefix(30)) model at \(String(format: "%.2f,%.2f", x, y)) close-up \(String(format: "%.2f", model)), Jev at \(String(format: "%.2f,%.2f", spot.x, spot.y))")
            guard model < 0.5, !self.closed else { return }
            self.rings[index].moved = true
            Pointer.move(panel, to: self.onScreen(spot.x, spot.y))
        }
    }

    /// The model's quick question about the screen, answered by Jev.
    private func look(_ args: [String: Any]) async -> Outcome {
        let question = (args["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return Outcome(text: "The look needs a question.") }
        let kind = args["kind"] as? String ?? "yes_no"
        card.working = "Looking at the screen…"
        defer { card.working = nil }
        let start = Date()
        guard let now = await Glance.screen(box) else {
            return Outcome(text: "Llasso couldn't capture the screen. Take a screenshot with the app's tools instead.")
        }
        func verdict(_ p: Double) -> String {
            p >= 0.8 ? "yes" : p <= 0.2 ? "no" : "unsure (\(Int(p * 100))% yes), so check another way"
        }
        var answer: String?
        switch kind {
        case "choice":
            let options = (args["options"] as? [String] ?? []).filter { !$0.isEmpty }
            guard options.count >= 2 else { return Outcome(text: "A choice look needs at least two options.") }
            if let (picked, p) = await Glance.choose(question, options: options, state: ["The screen now, with the user's box outlined in amber:", Jev.image(now)]) {
                answer = p >= 0.6 ? picked : "\(picked), but only \(Int(p * 100))% sure, so check another way"
            }
        case "changed":
            if let first = capture?.screen, let p = await Glance.yes(question, state: [
                "The screen when the user drew the box, outlined in amber:", Jev.image(first),
                "The screen now:", Jev.image(now)]) { answer = verdict(p) }
        default:
            if let p = await Glance.yes(question, state: ["The screen now, with the user's box outlined in amber:", Jev.image(now)]) {
                answer = verdict(p)
            }
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        Log.write("look: \(kind) \(question.prefix(60)) → \(answer ?? "no answer") in \(seconds)s")
        guard let answer else {
            return Outcome(text: "The quick look didn't answer. Take a screenshot with the app's tools instead.")
        }
        card.log.append("◌ \(question) \(answer.prefix(while: { $0 != "," }))")
        return Outcome(text: "Looked at the screen: \(answer).")
    }

    /// After a card destination changed the app, look for the change and say on the card.
    private func check(_ p: Proposal, before: Data, result index: Int?) {
        update(index) { $0.seen = .looking }
        var change = p.summary.ifEmpty("the change on the card")
        switch p {
        case .text(let text, _): change += ". The changed text should now read: \"\(text.prefix(300))\""
        case .cells(let start, let rows, _):
            change += ". Cells from \(start ?? "the selection") should now hold: " + rows.prefix(4).map { $0.joined(separator: ", ") }.joined(separator: "; ")
        default: break
        }
        Task { [weak self] in
            guard let self else { return }
            let p = await Glance.landed(change, before: before, box: self.box)
            Log.write("check: \(change.prefix(60)) → \(p.map { String(format: "%.2f", $0) } ?? "no answer")")
            self.update(index) { $0.seen = p.map { $0 >= 0.5 ? .shows : .missing } }
        }
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
