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
    /// The person's model for a category, by category id. A built-in's id is its work's name.
    @Published private(set) var pins: [String: String] = [:]
    /// The seven built-ins, as edited, then the person's own categories.
    @Published private(set) var categories: [WorkCategory] = WorkCategory.builtIns
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
        if let data = defaults.data(forKey: "categories"), let saved = try? JSONDecoder().decode([WorkCategory].self, from: data) {
            categories = WorkCategory.merged(saved)
        }
        for c in categories {
            if let id = defaults.string(forKey: "pin." + c.id), !id.isEmpty { pins[c.id] = id }
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

    func pin(for work: Work) -> String? { pins[work.rawValue] }
    func pin(for category: WorkCategory) -> String? { pins[category.id] }

    func setPin(_ id: String?, for work: Work) { setPin(id, for: category(work)) }

    func setPin(_ id: String?, for category: WorkCategory) {
        pins[category.id] = id
        if let id { defaults.set(id, forKey: "pin." + category.id) } else { defaults.removeObject(forKey: "pin." + category.id) }
    }

    // MARK: Categories

    /// The built-in category for a kind of work, as the person edited it.
    func category(_ work: Work) -> WorkCategory { categories.first { $0.id == work.rawValue } ?? .builtIn(work) }

    func category(id: String) -> WorkCategory? { categories.first { $0.id == id } }

    /// Add a category, or save changes to one.
    func save(_ category: WorkCategory) {
        if let i = categories.firstIndex(where: { $0.id == category.id }) {
            // A category moved to another kind of work can't keep a model from the old list.
            if categories[i].base.kind != category.base.kind { setPin(nil, for: category) }
            categories[i] = category
        } else {
            categories.append(category)
        }
        storeCategories()
    }

    /// For the look test: show these categories without saving them.
    func previewCategories(_ list: [WorkCategory]) { categories = WorkCategory.merged(list) }

    /// Remove one of the person's own categories; the built-ins stay.
    func remove(_ category: WorkCategory) {
        guard !category.isBuiltIn else { return }
        setPin(nil, for: category)
        categories.removeAll { $0.id == category.id }
        storeCategories()
    }

    /// Put a built-in's name, description and words back as they came.
    func reset(_ category: WorkCategory) {
        guard let work = Work(rawValue: category.id) else { return }
        save(.builtIn(work))
    }

    private func storeCategories() {
        // Only what differs from the built-ins is kept, so later wording changes reach untouched ones.
        let changed = categories.filter { !$0.isBuiltIn || $0 != .builtIn($0.base) }
        if let data = try? JSONEncoder().encode(changed) { defaults.set(data, forKey: "categories") }
    }

    func models(_ kind: ModelKind) -> [ModelInfo] { lists[kind] ?? [] }

    func model(_ id: String, kind: ModelKind) -> ModelInfo? { models(kind).first { $0.id == id } }

    /// The model for one request. Media work also fixes the chat model that drives it.
    func choose(_ work: Work, difficulty: Difficulty = .moderate, fits: ((ModelInfo) -> Bool)? = nil) -> Choice {
        choose(category(work), difficulty: difficulty, fits: fits)
    }

    /// The model for a category: its own choice when that can do the job, else the router's
    /// pick for its kind of work among the models it allows.
    func choose(_ category: WorkCategory, difficulty: Difficulty = .moderate, fits: ((ModelInfo) -> Bool)? = nil) -> Choice {
        let work = category.base
        let usable = fits ?? Self.usable(for: work)
        return Router.choose(work: work, difficulty: difficulty, models: models(work.kind), lean: lean,
                             pinned: pins[category.id], fallback: Self.fallback[work.kind]!,
                             fits: { usable($0) && category.fits($0) })
    }

    /// The model that makes a picture, clip or sound for this request: the category the request
    /// read as, when it makes this kind of thing, else the built-in one.
    func media(_ work: Work, reading: Reading?, sound: SoundType? = nil) -> Choice {
        let read = reading.flatMap { category(id: $0.category) }
        let c = read.flatMap { $0.base == work && (sound == nil || $0.sound == nil || $0.sound == sound) ? $0 : nil }
            ?? (work == .sound && sound == .speech ? voice : nil)
            ?? category(work)
        let fits: ((ModelInfo) -> Bool)? = sound.map { s in { $0.sound == s } }
        var choice = choose(c, difficulty: reading?.difficulty ?? .moderate, fits: fits)
        choice.label = c.name
        return choice
    }

    /// The person's own speech-only category, if they made one; spoken answers use it.
    private var voice: WorkCategory? { categories.first { !$0.isBuiltIn && $0.base == .sound && $0.sound == .speech } }

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
        // A category that runs on chat models uses its own choice; a picture, clip or sound
        // request is written by the model for the work that drives it.
        let read = category(id: reading.category)
        var c = read.flatMap { $0.base.kind == .chat ? choose($0, difficulty: reading.difficulty) : nil }
            ?? choose(reading.work.driver, difficulty: reading.difficulty)
        c.work = reading.work
        c.label = read?.name ?? reading.work.label
        return c
    }

    /// The voice for spoken answers: the person's sound model when it speaks, else the best speaker.
    func speech() -> Choice { media(.sound, reading: nil, sound: .speech) }

    /// What a request asks for. The keyword rules answer at once; Jev, when it is on and
    /// answers inside its time limit, has the last word.
    func read(_ prompt: String, context: ScreenContext) async -> Reading {
        let local = Reader.read(prompt, kind: context.kind, hasSource: context.source != nil, categories: categories)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard useJev, Settings.shared.hasKey, !trimmed.isEmpty else { return local }
        let started = Date()
        // Words the person tied to a category decide it outright.
        if categories.contains(where: { $0.matches(trimmed) }) { return local }
        guard let jev = await Settings.shared.client.jev(prompt: trimmed, box: context.kind.rawValue + " in " + (context.appName ?? "an app"),
                                                         categories: categories) else {
            Log.write("router: jev gave no answer in \(String(format: "%.2f", Date().timeIntervalSince(started)))s, rules read \(local.work.rawValue)")
            return local
        }
        Log.write("router: jev read \(category(id: jev.category)?.name ?? jev.work.rawValue)/\(jev.difficulty.rawValue) at \(String(format: "%.2f", jev.confidence)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s; rules read \(local.work.rawValue)")
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
