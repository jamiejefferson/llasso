import AVFoundation
import Speech
import LlassoKit

/// Push-to-talk transcription on the Mac with Apple's SpeechAnalyzer. Audio stays in memory
/// and never leaves the machine. Live (volatile) text is reported as it changes.
final class VoiceInput {
    /// Called on the main thread with the whole transcript so far.
    var onUpdate: ((String) -> Void)?

    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""
    private var locale: Locale?

    var transcript: String {
        (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var microphoneAllowed: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Pick a supported locale (system, then en-GB, then en-US) and install its model if needed.
    func prepare() async -> Bool {
        if locale != nil { return true }
        let supported = await SpeechTranscriber.supportedLocales
        let wanted = [Locale.current, Locale(identifier: "en-GB"), Locale(identifier: "en-US")]
        guard let chosen = wanted.first(where: { w in
            supported.contains { $0.identifier(.bcp47) == w.identifier(.bcp47) }
        }) else { return false }
        do {
            let probe = SpeechTranscriber(locale: chosen, transcriptionOptions: [],
                                          reportingOptions: [], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
            locale = chosen
            return true
        } catch {
            return false
        }
    }

    func start() async throws {
        guard !isRunning, await prepare(), let locale else { return }
        finalText = ""
        volatileText = ""

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.input = continuation

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

        let engine = AVAudioEngine()
        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        let converter = micFormat == format ? nil : AVAudioConverter(from: micFormat, to: format)
        node.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { buffer, _ in
            if let converter {
                if let out = Self.convert(buffer, with: converter, to: format) {
                    continuation.yield(AnalyzerInput(buffer: out))
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
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
