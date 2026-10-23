import AppKit
import SwiftUI
import LlassoKit

/// Takes the user from a box to a sent request: hotkey or drag → box → prompt. Each sent
/// request becomes a Job with its own card, and several can run at once.
@MainActor
final class Controller {
    static let shared = Controller()

    enum Phase { case idle, selecting, prompting }
    private(set) var phase: Phase = .idle

    private var overlays: [OverlayWindow] = []
    private var pillPanel: FloatingPanel?
    private let pill = PillModel()
    private let voice = VoiceInput()
    let speaker = Speaker()
    /// Sent requests, newest last. Each keeps running when its card is hidden.
    private(set) var jobs: [Job] = []
    private var jobClickMonitors: [Any] = []

    private var frontApp: NSRunningApplication?
    private var box: (rect: CGRect, screen: NSScreen)?
    private var captureTask: Task<Capture?, Never>?
    private var context = ScreenContext()
    private var pointerHeld = false
    /// The icon offered after a drag; it stays beside the prompt as the hold-to-talk button.
    var offer: Offer?
    private var holding = false
    private var voiceStarting = false

    private var keyMonitor: Any?
    private var clickMonitors: [Any] = []
    private var pauseTimer: Timer?
    private var lastSpeechChange = Date()

    private var integration: Integration?
    private var mcpTask: Task<MCPClient?, Never>?

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
        speaker.onError = { message in Toast.show("Voice: " + message) }
        installJobClickMonitors()
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
        let visible = (pillPanel?.isVisible ?? false)
            || overlays.contains { $0.isVisible } || (offer?.isShowing ?? false)
        if !visible { Log.write("watchdog: phase \(phase) with no windows; reset"); cancel() }
    }

    // MARK: Start

    /// A click outside a job's card hides that card; the job carries on.
    private func installJobClickMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hideCards(except: nil, at: NSEvent.mouseLocation) }
        }) { jobClickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, NSApp.modalWindow == nil, !(event.window is NSSavePanel) else { return event }
            self.hideCards(except: event.window, at: NSEvent.mouseLocation)
            return event
        }) { jobClickMonitors.append(local) }
    }

    func hideCardsForTest(at point: CGPoint) { hideCards(except: nil, at: point) }

    private func hideCards(except window: NSWindow?, at point: CGPoint) {
        for job in jobs where job.isVisible && !job.owns(window) && !job.contains(point) { job.hide() }
    }

    /// For the self-test: start a job without the prompt.
    func startTestJob(box: (rect: CGRect, screen: NSScreen), context: ScreenContext, prompt: String, crop: Data) -> Job {
        let job = Job(frontApp: nil, box: box, verb: nil, context: context, integration: nil, speaker: speaker)
        job.onClose = { [weak self] j in self?.jobs.removeAll { $0 === j } }
        jobs.append(job)
        let capture = Task<Capture?, Never> { Capture(crop: crop, screen: crop) }
        Task { await job.start(prompt: prompt, spoken: false, captureTask: capture, mcpTask: nil) }
        return job
    }

    /// For the look test: a card on screen without asking the model anything.
    func showTestCard(box: (rect: CGRect, screen: NSScreen)) -> Job {
        let job = Job(frontApp: nil, box: box, verb: nil, context: ScreenContext(appName: "Safari", bundleID: nil),
                      integration: nil, speaker: speaker)
        job.onClose = { [weak self] j in self?.jobs.removeAll { $0 === j } }
        jobs.append(job)
        return job
    }

    /// For the self-test: lay the prompt out and report its mic's offset.
    func measurePill() async -> CGPoint {
        let panel = FloatingPanel(size: CGSize(width: 560 + 2 * Glass.margin, height: 150))
        panel.contentView = NSHostingView(rootView: PillView(model: pill) { [weak panel] h in panel?.setHeight(h) })
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        panel.orderOut(nil)
        return pill.micOffset
    }

    func showJob(id: UUID) {
        jobs.first { $0.id == id }?.show()
    }

    /// Close every job that has finished and isn't waiting on the user.
    func clearFinished() {
        for job in jobs where !job.isRunning && !job.needsYou { job.close() }
    }

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
            if window === self.pillPanel || window === self.offer?.window || self.jobs.contains(where: { $0.owns(window) }) { return event }
            // A save panel or alert Llasso opened is part of the job, not a click away from it.
            if NSApp.modalWindow != nil || window is NSSavePanel { return event }
            return self.clicked(at: NSEvent.mouseLocation) ? nil : event
        }) { clickMonitors.append(local) }
    }

    /// Returns true if the click dismissed Llasso.
    @discardableResult
    private func clicked(at point: CGPoint) -> Bool {
        guard phase == .prompting else { return false }
        if let p = pillPanel, p.isVisible, p.frame.contains(point) { return false }
        if let o = offer?.window, o.isVisible, o.frame.contains(point) { return false }
        if phase == .prompting, let box, box.rect.contains(point) { return false }
        cancel()
        return true
    }

    private func escape() { cancel() }

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
                guard let self, self.phase == .prompting else { return }
                var ctx = ctx
                ctx.integration = self.context.integration
                ctx.integrationHint = self.context.integrationHint
                self.context = ctx
                self.pill.tag = ctx.tag + " · " + ctx.kind.rawValue
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
            guard let self, client != nil, self.phase == .prompting else { return client }
            self.context.integration = integration.name
            self.pill.tag = self.context.tag + " · " + self.context.kind.rawValue
            self.pill.tagKnown = true
            return client
        }
    }

    private func showPill(near rect: CGRect, on screen: NSScreen) {
        let panel = pillPanel ?? FloatingPanel(size: CGSize(width: 560 + 2 * Glass.margin, height: 150))
        if pillPanel == nil {
            let host = NSHostingView(rootView: PillView(model: pill) { [weak panel] h in panel?.setHeight(h) })
            panel.contentView = host
            pillPanel = panel
        }
        if let anchor = offer?.iconCentre {
            // Opened from the icon: the prompt appears under the pointer, with its mic
            // where the icon was, and the icon stays on the mic as the hold-to-talk button.
            panel.place(pill.micOffset, at: anchor, on: screen)
            offer?.moveIcon(to: CGPoint(x: panel.frame.minX + pill.micOffset.x, y: panel.frame.maxY - pill.micOffset.y))
        } else {
            panel.place(near: rect, on: screen)
        }
        pill.reveal()
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
        let job = Job(frontApp: frontApp, box: box, verb: pill.verb, context: context,
                      integration: integration, speaker: speaker)
        job.onClose = { [weak self] j in self?.jobs.removeAll { $0 === j } }
        jobs.append(job)
        // The job owns the capture and the app's connection now; the prompt resets.
        let capture = captureTask, connection = mcpTask
        captureTask = nil
        mcpTask = nil
        let typed = pill.typed, typedText = pill.text
        Task {
            let heard = usedVoice ? await voice.stop() : { voice.abandon(); return "" }()
            let prompt = typed ? typedText : (heard.isEmpty ? typedText : heard)
            await job.start(prompt: prompt, spoken: usedVoice && !prompt.isEmpty, captureTask: capture, mcpTask: connection)
        }
        cancel(keepingVoice: usedVoice)
    }

    // MARK: End

    /// The prompt winds back into the icon, then its window goes.
    private func hidePill() {
        guard let panel = pillPanel, panel.isVisible else { return }
        pill.conceal { [weak self, weak panel] in
            guard let self, self.phase != .prompting else { return }
            panel?.orderOut(nil)
        }
    }

    func cancel() { cancel(keepingOffer: false) }

    /// Reset the prompt. Sent jobs are left alone.
    private func cancel(keepingOffer: Bool = false, keepingVoice: Bool = false) {
        if phase != .idle { Log.write("prompt closed from \(phase)") }
        holding = false
        if !keepingOffer { offer?.dismiss() }
        pauseTimer?.invalidate()
        pauseTimer = nil
        captureTask?.cancel()
        captureTask = nil
        if !keepingVoice { voice.abandon() }
        pill.listening = false
        hidePill()
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
        mcpTask?.cancel()
        mcpTask = nil
        integration = nil
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
