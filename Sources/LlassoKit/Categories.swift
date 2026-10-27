import Foundation

/// A kind of work the person names, such as Illustration or Voice. Each one runs on one of the
/// seven built-in kinds of work, which decides its model list and how models are rated, and has
/// its own description, the words that pick it, and its own chosen model. The seven built-ins
/// are categories too, so they can be renamed and described in the same way.
public struct WorkCategory: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// The built-in work it runs as.
    public var base: Work
    /// What requests it covers, in the person's words. Jev reads it to pick the category.
    public var about: String
    /// Words that pick this category straight away when the request uses them.
    public var keywords: [String]
    /// Sound categories only: speech models only, or music models only.
    public var sound: SoundType?

    public init(id: String = UUID().uuidString, name: String, base: Work, about: String,
                keywords: [String] = [], sound: SoundType? = nil) {
        self.id = id
        self.name = name
        self.base = base
        self.about = about
        self.keywords = keywords
        self.sound = sound
    }

    public var isBuiltIn: Bool { Work(rawValue: id) != nil }

    public static func builtIn(_ work: Work) -> WorkCategory {
        WorkCategory(id: work.rawValue, name: work.label, base: work, about: work.blurb)
    }

    public static let builtIns: [WorkCategory] = Work.allCases.map(builtIn)

    /// What Jev reads as this option's meaning. An untouched built-in keeps its tuned wording.
    public var criterion: String {
        if isBuiltIn, about == base.blurb { return base.criterion }
        var s = "The person wants \(base.phrase) of this kind: \(about)."
        if !keywords.isEmpty { s += " Requests often say: " + keywords.joined(separator: ", ") + "." }
        return s
    }

    /// Does this model suit the category beyond its base work: a voice category takes speech models only.
    public func fits(_ m: ModelInfo) -> Bool {
        guard base == .sound, let sound else { return true }
        return m.sound == sound
    }

    /// Whether the request names one of this category's words, as a whole word.
    public func matches(_ text: String) -> Bool {
        keywords.contains { word in
            let w = word.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty else { return false }
            return text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: w) + #"\b"#,
                              options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The person's list: the seven built-ins (as edited) first, then their own, in the order made.
    /// Built-ins missing from a saved list come back, so the router always has all seven.
    public static func merged(_ saved: [WorkCategory]) -> [WorkCategory] {
        let edited = Dictionary(saved.filter(\.isBuiltIn).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return builtIns.map { edited[$0.id] ?? $0 } + saved.filter { !$0.isBuiltIn }
    }
}
