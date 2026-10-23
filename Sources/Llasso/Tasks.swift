import AppKit
import SwiftUI
import LlassoKit

/// Runs one job's change at a time, and only once the user has finished drawing or typing a
/// new prompt: changes go in by bringing an app forward and pressing keys, so two at once, or one
/// mid-prompt, would type into the wrong place.
@MainActor
enum ActionQueue {
    private static var tail: Task<Void, Never>?

    static func run<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            while Controller.shared.phase != .idle { try await Task.sleep(nanoseconds: 200_000_000) }
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

// MARK: - Task list

/// The menu bar panel's list: this session's jobs, newest first, then earlier requests
/// read back from history.jsonl.
@MainActor
final class TasksModel: ObservableObject {
    static let shared = TasksModel()
    @Published var jobs: [Job] = []
    @Published var earlier: [Earlier] = []
    /// The earlier request opened to show its whole response.
    @Published var expanded: UUID?
    let launched = Date()

    struct Earlier: Identifiable {
        let id = UUID()
        var at: Date
        var prompt: String
        var app: String
        var answer: String
        var actions: [String]
    }

    func sync() {
        let now = Controller.shared.jobs.reversed() as [Job]
        if now.map(ObjectIdentifier.init) != jobs.map(ObjectIdentifier.init) { jobs = now }
    }

    func loadEarlier() {
        let file = History.folder.appendingPathComponent("history.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { earlier = []; return }
        let iso = ISO8601DateFormatter()
        var out: [Earlier] = []
        for line in text.split(separator: "\n").suffix(300) {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let at = (o["at"] as? String).flatMap(iso.date), at < launched else { continue }
            let e = Earlier(at: at, prompt: o["prompt"] as? String ?? "", app: o["app"] as? String ?? "",
                            answer: o["answer"] as? String ?? "", actions: o["actions"] as? [String] ?? [])
            // A job writes a line each time it acts; keep its last.
            if let last = out.last, last.prompt == e.prompt, last.app == e.app { out[out.count - 1] = e } else { out.append(e) }
        }
        earlier = Array(out.suffix(30).reversed())
    }
}

struct TasksView: View {
    @ObservedObject var model: TasksModel
    var onShow: (Job) -> Void
    var onDraw: () -> Void
    var onClear: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Requests").font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Button(action: onDraw) { Text("Draw a box  ⌃⌥S").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).foregroundColor(.llGold)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if model.jobs.isEmpty && model.earlier.isEmpty {
                Text("Nothing yet. Draw a box round anything and ask.")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.jobs, id: \.id) { job in
                            JobRow(job: job, card: job.card).onTapGesture { onShow(job) }
                        }
                        if !model.earlier.isEmpty {
                            Text("EARLIER").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor)).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                            ForEach(model.earlier) { e in
                                EarlierRow(entry: e, open: model.expanded == e.id)
                                    .onTapGesture { model.expanded = model.expanded == e.id ? nil : e.id }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 460)
            }
            Divider()
            HStack(spacing: 16) {
                if model.jobs.contains(where: { !$0.isRunning && !$0.needsYou }) {
                    Button("Clear finished", action: onClear)
                }
                Spacer()
                Button("Settings…", action: onSettings)
                Button("Quit", action: onQuit)
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 400)
    }
}

/// One live job: its status, the request, and the latest of its response.
struct JobRow: View {
    let job: Job
    @ObservedObject var card: CardModel

    private enum Status { case working, needsYou, done, stopped }
    private var status: Status {
        if job.isRunning { return .working }
        if job.needsYou { return .needsYou }
        if card.state == .failed || (job.closed && card.state != .done) { return .stopped }
        return .done
    }
    private var label: String {
        switch status {
        case .working: return card.working ?? (card.state == .thinking ? "Thinking" : "Answering")
        case .needsYou: return card.question != nil ? "Has a question" : card.step != nil ? "Waiting for approval" : "Waiting for you"
        case .done: return "Done"
        case .stopped: return card.error != nil ? "Stopped" : "Closed"
        }
    }
    private var response: String {
        if let e = card.error { return e }
        if let p = card.proposal { return p.done ?? p.note ?? p.summary }
        return card.answer
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusMark(status: { switch status { case .working: return 0; case .needsYou: return 1; case .done: return 2; case .stopped: return 3 } }())
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.system(size: 13, weight: .medium)).foregroundColor(.primary).lineLimit(2)
                if !response.isEmpty {
                    Text(response.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                }
                Text([label, job.appName, Self.ago(job.started)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(status == .needsYou ? .llGold : Color(nsColor: .tertiaryLabelColor))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
        .help("Show this card")
    }

    static func ago(_ date: Date) -> String {
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins) min ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// A request from before this launch: tap to read the whole response.
struct EarlierRow: View {
    let entry: TasksModel.Earlier
    let open: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusMark(status: 2).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.prompt.isEmpty ? "Explain" : entry.prompt)
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.primary).lineLimit(open ? nil : 2)
                if !entry.answer.isEmpty {
                    Text(open ? entry.answer : entry.answer.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(open ? nil : 2)
                        .textSelection(.enabled)
                }
                Text(([entry.actions.last ?? "", entry.app, entry.at.formatted(date: .abbreviated, time: .shortened)])
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// 0 working (a turning gold arc), 1 needs you (gold dot), 2 done (green tick), 3 stopped (grey cross).
struct StatusMark: View {
    let status: Int

    var body: some View {
        ZStack {
            switch status {
            case 0:
                TimelineView(.animation) { t in
                    Circle().trim(from: 0, to: 0.7).stroke(Color.llGold, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            case 1: Circle().fill(Color.llGold).frame(width: 8, height: 8)
            case 2: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.llPositive)
            default: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .frame(width: 12, height: 12)
    }
}
