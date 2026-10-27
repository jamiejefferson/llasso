import Foundation

/// A request that one result can't answer: two or more things to make, each on the model for
/// its kind of work, and possibly a last step that joins some of them into one. The user
/// approves the plan before anything is made.
public struct Plan: Sendable, Equatable {
    public var summary: String
    public var steps: [PlanStep]

    public init(summary: String, steps: [PlanStep]) {
        self.summary = summary
        self.steps = steps
    }

    public static let maxSteps = 5

    /// The results the user sees: every step whose result no later step uses.
    public var finals: [PlanStep] {
        let used = Set(steps.flatMap(\.uses))
        return steps.filter { !used.contains($0.id) }
    }

    public func step(_ id: String) -> PlanStep? { steps.first { $0.id == id } }

    /// Parse make_plan's arguments, or say what is wrong so the model can try again.
    public static func parse(_ a: [String: Any]) -> Result<Plan, PlanError> {
        guard let raw = a["steps"] as? [[String: Any]], !raw.isEmpty else { return .failure(.init("The plan has no steps.")) }
        var steps: [PlanStep] = []
        for (i, s) in raw.enumerated() {
            let id = (s["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(i + 1)"
            guard let kindName = s["kind"] as? String, let kind = PlanStep.Kind(rawValue: kindName) else {
                return .failure(.init("Step \(id) needs a kind: text, image, video, sound or combine."))
            }
            let seconds = (s["seconds"] as? Int) ?? (s["seconds"] as? Double).map { Int($0) }
            steps.append(PlanStep(id: id, kind: kind,
                                  instruction: s["instruction"] as? String ?? "",
                                  summary: s["summary"] as? String ?? "",
                                  uses: s["uses"] as? [String] ?? [],
                                  fromBox: s["from_box"] as? Bool ?? false,
                                  seconds: seconds,
                                  speech: (s["sound_type"] as? String) == "speech"))
        }
        let plan = Plan(summary: a["summary"] as? String ?? "", steps: steps)
        if let problem = plan.problem { return .failure(.init(problem)) }
        return .success(plan)
    }

    /// Why the plan can't run as written, or nil when it can.
    public var problem: String? {
        if steps.count < 2 { return "A plan needs at least two steps. Use the single tool for one result." }
        if steps.count > Self.maxSteps { return "Keep the plan to \(Self.maxSteps) steps or fewer." }
        var seen: Set<String> = []
        for s in steps {
            if seen.contains(s.id) { return "Two steps share the id \(s.id)." }
            for u in s.uses where !seen.contains(u) {
                return "Step \(s.id) uses \(u), which must be an earlier step."
            }
            if s.kind != .combine && s.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Step \(s.id) needs an instruction."
            }
            if s.kind == .combine {
                let kinds = s.uses.compactMap { step($0)?.kind }
                let picture = kinds.filter { $0 == .video || $0 == .image }.count
                let sound = kinds.filter { $0 == .sound }.count
                if kinds.count != 2 || picture != 1 || sound != 1 {
                    return "A combine step joins exactly one clip or picture with one sound. To merge texts or pictures, give a text or image step that uses them."
                }
            }
            seen.insert(s.id)
        }
        return nil
    }
}

public struct PlanError: Error, Sendable {
    public var message: String
    init(_ message: String) { self.message = message }
}

public struct PlanStep: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case text, image, video, sound
        /// Joins a clip or a still picture with a sound into one clip, on this Mac.
        case combine
    }

    public var id: String
    public var kind: Kind
    public var instruction: String
    public var summary: String
    /// Earlier steps whose results this one takes in.
    public var uses: [String]
    public var fromBox: Bool
    public var seconds: Int?
    /// Sound only: read the words aloud, instead of music.
    public var speech: Bool

    public init(id: String, kind: Kind, instruction: String, summary: String = "", uses: [String] = [],
                fromBox: Bool = false, seconds: Int? = nil, speech: Bool = false) {
        self.id = id
        self.kind = kind
        self.instruction = instruction
        self.summary = summary
        self.uses = uses
        self.fromBox = fromBox
        self.seconds = seconds
        self.speech = speech
    }

    /// The kind of work whose model makes this step; nil for a combine, which runs locally.
    public var work: Work? {
        switch kind {
        case .text: return .writing
        case .image: return .image
        case .video: return .motion
        case .sound: return .sound
        case .combine: return nil
        }
    }

    public var label: String {
        switch kind {
        case .text: return "Text"
        case .image: return "Image"
        case .video: return "Clip"
        case .sound: return speech ? "Speech" : "Sound"
        case .combine: return "Combine"
        }
    }
}
