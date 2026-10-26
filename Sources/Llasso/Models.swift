import Foundation
import LlassoKit

/// The router's side of Llasso: OpenRouter's model lists, cached on disk and refreshed once
/// a day, the person's own model for each kind of work, and the choice for each request.
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var lists: [ModelKind: [ModelInfo]] = [:]
    @Published private(set) var updated: Date?
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    @Published private(set) var pins: [Work: String] = [:]
    @Published var lean: Lean { didSet { defaults.set(lean.rawValue, forKey: "routerLean") } }
    /// Ask Jev what each request is for; the keyword rules answer when it is off or slow.
    @Published var useJev: Bool { didSet { defaults.set(useJev, forKey: "routerJev") } }

    /// Used when the lists haven't loaded and nothing is chosen.
    static let fallback: [ModelKind: String] = [
        .chat: Settings.defaultModel,
        .image: Settings.defaultImageModel,
        .video: "google/veo-3.1-fast",
        .sound: "elevenlabs/eleven-v4-turbo",
    ]

    private let defaults = UserDefaults.standard
    private var folder: URL { History.folder.appendingPathComponent("Models", isDirectory: true) }

    private init() {
        lean = Lean(rawValue: defaults.string(forKey: "routerLean") ?? "") ?? .balanced
        useJev = defaults.object(forKey: "routerJev") as? Bool ?? true
        for work in Work.allCases {
            if let id = defaults.string(forKey: "pin." + work.rawValue), !id.isEmpty { pins[work] = id }
        }
        migrate()
        loadCached()
    }

    /// Before the router, one chat model, one image model and one speech model were typed into
    /// Settings. A model someone changed from the default becomes their choice for that work.
    private func migrate() {
        if let model = defaults.string(forKey: "model") {
            if model != Settings.defaultModel { for w in [Work.writing, .coding, .design, .admin] { setPin(model, for: w) } }
            defaults.removeObject(forKey: "model")
        }
        if let image = defaults.string(forKey: "imageModel") {
            if image != Settings.defaultImageModel { setPin(image, for: .image) }
            defaults.removeObject(forKey: "imageModel")
        }
        if let tts = defaults.string(forKey: "ttsModel") {
            if tts != Self.fallback[.sound] { setPin(tts, for: .sound) }
            defaults.removeObject(forKey: "ttsModel")
        }
    }

    // MARK: Choices

    func pin(for work: Work) -> String? { pins[work] }

    func setPin(_ id: String?, for work: Work) {
        pins[work] = id
        if let id { defaults.set(id, forKey: "pin." + work.rawValue) } else { defaults.removeObject(forKey: "pin." + work.rawValue) }
    }

    func models(_ kind: ModelKind) -> [ModelInfo] { lists[kind] ?? [] }

    func model(_ id: String, kind: ModelKind) -> ModelInfo? { models(kind).first { $0.id == id } }

    /// The model for one request. Media work also fixes the chat model that drives it.
    func choose(_ work: Work, difficulty: Difficulty = .moderate, fits: ((ModelInfo) -> Bool)? = nil) -> Choice {
        Router.choose(work: work, difficulty: difficulty, models: models(work.kind), lean: lean,
                      pinned: pins[work], fallback: Self.fallback[work.kind]!, fits: fits ?? Self.usable(for: work))
    }

    /// What a model must do to be used for a kind of work at all. Llasso always sends the boxed
    /// picture to an image model, and tools for existing clips can't make one from words.
    static func usable(for work: Work) -> (ModelInfo) -> Bool {
        switch work {
        case .image: return { $0.takes.contains("image") && !$0.utility }
        case .motion: return { !$0.utility }
        default: return { _ in true }
        }
    }

    /// The chat model that runs a request read as this work.
    func chat(for reading: Reading) -> Choice {
        let driver = reading.work.driver
        var c = choose(driver, difficulty: reading.difficulty)
        c.work = reading.work
        return c
    }

    /// The voice for spoken answers: the person's sound model when it speaks, else the best speaker.
    func speech() -> Choice { choose(.sound, fits: { $0.sound == .speech }) }

    /// What a request asks for. The keyword rules answer at once; Jev, when it is on and
    /// answers inside its time limit, has the last word.
    func read(_ prompt: String, context: ScreenContext) async -> Reading {
        let local = Reader.read(prompt, kind: context.kind, hasSource: context.source != nil)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard useJev, Settings.shared.hasKey, !trimmed.isEmpty else { return local }
        let started = Date()
        guard let jev = await Settings.shared.client.jev(prompt: trimmed, box: context.kind.rawValue + " in " + (context.appName ?? "an app")) else {
            Log.write("router: jev gave no answer in \(String(format: "%.2f", Date().timeIntervalSince(started)))s, rules read \(local.work.rawValue)")
            return local
        }
        Log.write("router: jev read \(jev.work.rawValue)/\(jev.difficulty.rawValue) at \(String(format: "%.2f", jev.confidence)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s; rules read \(local.work.rawValue)")
        return jev.confidence >= 0.6 ? jev : local
    }

    // MARK: Lists

    private func file(_ kind: ModelKind, _ i: Int) -> URL { folder.appendingPathComponent("\(kind.rawValue)-\(i).json") }

    private func loadCached() {
        var out: [ModelKind: [ModelInfo]] = [:]
        var newest: Date?
        for kind in ModelKind.allCases {
            var models: [ModelInfo] = []
            for i in kind.listPaths.indices {
                let url = file(kind, i)
                guard let data = try? Data(contentsOf: url) else { continue }
                models += Catalogue.parse(data, kind: kind)
                if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    newest = max(newest ?? d, d)
                }
            }
            if !models.isEmpty { out[kind] = models }
        }
        lists = out
        updated = newest
    }

    /// Fetch every list again when the cache is a day old, or when asked.
    func refresh(force: Bool = false) {
        if loading { return }
        if !force, let updated, Date().timeIntervalSince(updated) < 86_400, lists.count == ModelKind.allCases.count { return }
        loading = true
        loadError = nil
        let client = Settings.shared.client
        Task { @MainActor in
            var failed: String?
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for kind in ModelKind.allCases {
                for (i, path) in kind.listPaths.enumerated() {
                    do {
                        let data = try await client.list(path)
                        guard !Catalogue.parse(data, kind: kind).isEmpty else { continue }
                        try data.write(to: file(kind, i), options: .atomic)
                    } catch {
                        failed = error.localizedDescription
                    }
                }
            }
            loadCached()
            loading = false
            loadError = failed
            Log.write("router: lists refreshed, " + ModelKind.allCases.map { "\($0.rawValue) \(models($0).count)" }.joined(separator: ", ")
                      + (failed.map { "; failed: \($0)" } ?? ""))
        }
    }
}
