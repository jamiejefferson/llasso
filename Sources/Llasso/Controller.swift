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

    private init() {
        pill.onSend = { [weak self] in self?.send() }
        pill.onCancel = { [weak self] in self?.cancel() }
        card.onStop = { [weak self] in self?.stopAnswer() }
        card.onClose = { [weak self] in self?.cancel() }
        card.onCopy = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.card.answer, forType: .string)
            self.card.copied = true
        }
        card.onFollowUp = { [weak self] text in self?.followUp(text) }
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
        startVoice()
        selectionMade(local, in: w)
    }

    /// Press on the offer icon: open the prompt if it isn't open, and record until release.
    func holdToTalk(box: CGRect) {
        if phase == .idle { begin(box: box) }
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
        startVoice()
    }

    private func startVoice() {
        // Hover and press can both ask for the mic within a moment; start it once.
        guard !voice.isRunning, !voiceStarting else { return }
        voiceStarting = true
        Task {
            defer { voiceStarting = false }
            if !VoiceInput.microphoneAllowed {
                guard await VoiceInput.requestMicrophone() else { return }
            }
            do {
                try await voice.start()
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
            let ctx = ContextReader.read(app: app, selection: global)
            await MainActor.run {
                guard let self, self.phase == .prompting || self.phase == .answering else { return }
                self.context = ctx
                self.pill.tag = ctx.tag
                self.pill.tagKnown = ctx.documentPath != nil || ctx.url != nil
            }
        }
        pill.tag = context.tag
        captureTask = Task { try? await Capture.take(screen: screen, selection: global) }

        showPill(near: global, on: screen)
        startPauseTimer()
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
            messages = Brief.firstMessages(prompt: prompt, verb: pill.verb, context: context,
                                           crop: cap.crop, screen: cap.screen, spoken: spoken)
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
        let client = settings.client
        let model = settings.model
        let msgs = messages
        let speak = spoken && settings.voiceOut != .off
        streamTask = Task {
            var sentences = SentenceBuffer()
            var answer = ""
            do {
                for try await piece in client.streamChat(model: model, messages: msgs) {
                    if Task.isCancelled { break }
                    answer += piece
                    card.answer = answer
                    card.state = .streaming
                    if speak { sentences.append(piece).forEach(speaker.say) }
                }
                if speak, !Task.isCancelled, let rest = sentences.flush() { speaker.say(rest) }
                card.state = .done
                messages.append(.assistant(answer))
                History.append(prompt: lastPrompt, verb: pill.verb, context: context, answer: answer, model: model)
            } catch {
                if Task.isCancelled { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func stopAnswer() {
        streamTask?.cancel()
        streamTask = nil
        speaker.stop()
        if card.state != .failed { card.state = .done }
    }

    private func fail(_ message: String) {
        card.state = .failed
        card.error = message
    }

    private func showCard(near rect: CGRect, on screen: NSScreen) {
        card.answer = ""
        card.error = nil
        card.copied = false
        card.askingMore = false
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
        holding = false
        if !keepingOffer { offer?.dismiss() }
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
    }
}
