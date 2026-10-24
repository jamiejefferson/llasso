import AVFoundation
import Speech
import LlassoKit

/// Push-to-talk transcription on the Mac with Apple's SpeechAnalyzer. Audio stays in memory
/// and never leaves the machine. Live (volatile) text is reported as it changes.
///
/// The mic starts the moment the press lands and its audio queues while the analyzer starts, so
/// the first words are kept. A spare analyzer is made ready while the prompt opens, so a press
/// only has to start it.
final class VoiceInput {
    /// Called on the main thread with the whole transcript so far.
    var onUpdate: ((String) -> Void)?
    /// Called on the main thread about 20 times a second with the mic level, 0...1.
    var onLevel: ((Double) -> Void)?

    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""
    private var locale: Locale?
    private var format: AVAudioFormat?
    private var spare: (SpeechTranscriber, SpeechAnalyzer)?
    /// An audio engine made ready with the spare analyzer; preparing does not turn the mic on.
    private var spareEngine: AVAudioEngine?
    /// Words the transcriber should expect: app and tool names it would otherwise mishear.
    static let vocabulary = ["Llasso", "Hatch", "Paper", "Figma", "IDEalize", "Teams", "Notes", "Excel", "Chrome", "Safari"]

    var transcript: String {
        (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var microphoneAllowed: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Pick a supported locale (system, then en-GB, then en-US), install its model if needed,
    /// and make a spare analyzer ready for the next press.
    func prepare() async -> Bool {
        if locale == nil {
            let supported = await SpeechTranscriber.supportedLocales
            let wanted = [Locale.current, Locale(identifier: "en-GB"), Locale(identifier: "en-US")]
            guard let chosen = wanted.first(where: { w in
                supported.contains { $0.identifier(.bcp47) == w.identifier(.bcp47) }
            }) else { Log.write("voice: no supported locale"); return false }
            do {
                let probe = Self.transcriber(chosen)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    try await request.downloadAndInstall()
                }
                format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
                locale = chosen
            } catch {
                Log.write("voice: model install failed: \(error.localizedDescription)")
                return false
            }
        }
        if spareEngine == nil {
            let e = AVAudioEngine()
            _ = e.inputNode.outputFormat(forBus: 0)
            e.prepare()
            spareEngine = e
        }
        if spare == nil, let locale, let format {
            let t = Self.transcriber(locale)
            let a = SpeechAnalyzer(modules: [t])
            spare = (t, a)
            try? await a.prepareToAnalyze(in: format)
            let context = AnalysisContext()
            context.contextualStrings[.general] = Self.vocabulary
            try? await a.setContext(context)
        }
        return format != nil
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults], attributeOptions: [])
    }

    func start() async throws {
        guard !isRunning else { return }
        let began = Date()
        finalText = ""
        volatileText = ""
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = continuation

        // The mic first, converting into the analyzer's format if it is known yet; the stream
        // holds the audio until the analyzer takes it.
        let engine = spareEngine ?? AVAudioEngine()
        spareEngine = nil
        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        if format == nil { _ = await prepare() }
        guard let format else { return }
        let converter = micFormat == format ? nil : AVAudioConverter(from: micFormat, to: format)
        var lastLevel = Date.distantPast
        node.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            if let converter {
                if let out = Self.convert(buffer, with: converter, to: format) {
                    continuation.yield(AnalyzerInput(buffer: out))
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            if Date().timeIntervalSince(lastLevel) > 0.05 {
                lastLevel = Date()
                let level = Self.level(buffer)
                DispatchQueue.main.async { self?.onLevel?(level) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
        Log.write("voice: mic on in \(Int(Date().timeIntervalSince(began) * 1000))ms")

        if spare == nil { _ = await prepare() }
        guard isRunning, let (transcriber, analyzer) = spare else { return }
        spare = nil
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal {
                            self.finalText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        self.onUpdate?(self.transcript)
                    }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        Log.write("voice: analyzer on in \(Int(Date().timeIntervalSince(began) * 1000))ms")
    }

    /// For the voice test: transcribe a whole audio file with the same model and vocabulary.
    func transcribe(file url: URL) async throws -> String {
        guard await prepare(), let locale else { return "" }
        let t = Self.transcriber(locale)
        let file = try AVAudioFile(forReading: url)
        let context = AnalysisContext()
        context.contextualStrings[.general] = Self.vocabulary
        let a = SpeechAnalyzer(modules: [t])
        try await a.setContext(context)
        async let text: String = {
            var out = ""
            for try await r in t.results where r.isFinal { out += String(r.text.characters) }
            return out
        }()
        if let last = try await a.analyzeSequence(from: file) {
            try await a.finalizeAndFinish(through: last)
        } else {
            await a.cancelAndFinishNow()
        }
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loudness of a buffer on a 0...1 scale that suits speech (about −50 dB to −10 dB).
    private static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return Double(min(1, max(0, (db + 50) / 40)))
    }

    /// Stop listening and return the final transcript.
    func stop() async -> String {
        guard isRunning else { return transcript }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        _ = await resultsTask?.value
        resultsTask = nil
        return transcript
    }

    /// Stop without waiting for the last words.
    func abandon() {
        guard isRunning else { return }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        input?.finish()
        input = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private static func convert(_ buf: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard cap > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if consumed { inStatus.pointee = .noDataNow; return nil }
            consumed = true
            inStatus.pointee = .haveData
            return buf
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }
}

/// Speaks answers sentence by sentence as they stream in, with the Mac's voice or an OpenRouter voice.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var chain: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playerDone: CheckedContinuation<Void, Never>?
    private var generation = 0
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Best installed British voice, preferring premium and enhanced quality.
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        return british.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()

    func say(_ sentence: String) {
        let settings = Settings.shared
        switch settings.voiceOut {
        case .off:
            return
        case .system:
            let u = AVSpeechUtterance(string: sentence)
            u.voice = voice
            synth.speak(u)
        case .openrouter:
            // Fetch now so audio is ready by the time earlier sentences finish.
            let client = settings.client
            let model = settings.ttsModel
            let voiceName = settings.ttsVoice
            let fetch = Task { try await client.speech(model: model, voice: voiceName, text: sentence) }
            let previous = chain
            let gen = generation
            chain = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, gen == self.generation else { return }
                do {
                    let data = try await fetch.value
                    guard gen == self.generation else { return }
                    await self.play(data)
                } catch {
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func play(_ data: Data) async {
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.delegate = self
        player = p
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            playerDone = c
            if !p.play() { finishPlayback() }
        }
    }

    private func finishPlayback() {
        playerDone?.resume()
        playerDone = nil
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.finishPlayback() }
    }

    func stop() {
        generation += 1
        synth.stopSpeaking(at: .immediate)
        chain?.cancel()
        chain = nil
        player?.stop()
        finishPlayback()
    }
}
