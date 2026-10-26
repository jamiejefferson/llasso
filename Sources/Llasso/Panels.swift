import AppKit
import SwiftUI
import AVKit
import LlassoKit

/// Reports a view's height so its panel can grow while keeping its top edge still.
struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func reportsHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            .onPreferenceChange(HeightKey.self, perform: onChange)
    }
}

extension FloatingPanel {
    func setHeight(_ height: CGFloat) {
        guard height > 0, abs(frame.height - height) > 0.5 else { return }
        var f = frame
        let top = f.maxY
        f.size.height = height
        f.origin.y = top - height
        if let visible = screen?.visibleFrame, f.minY < visible.minY + 8 {
            f.origin.y = visible.minY + 8
        }
        setFrame(f, display: true)
    }
}

// MARK: - Prompt pill

final class PillModel: ObservableObject {
    @Published var tag = "Reading the screen…"
    @Published var tagKnown = false
    @Published var text = ""
    @Published var listening = false
    /// The mic level while listening, 0...1.
    @Published var level: Double = 0
    var holdingMic = false
    /// Centre of the mic from the panel's top-left corner, measured once laid out.
    @Published var micOffset = CGPoint(x: 54, y: 72.5)
    @Published var verb: Verb?
    /// 0...1 while the pause-to-send countdown runs, nil otherwise.
    @Published var pending: Double?
    @Published var typed = false
    @Published var notice: String?

    /// The entry: threads unwind from the mic (0...1), the glass frosts in, then the text rises.
    @Published var thread: Double = 1
    @Published var glass: Double = 1
    @Published var content: Double = 1
    private var generation = 0

    var onSend: (() -> Void)?
    /// The mic badge pressed (true) or released (false).
    var onHold: ((Bool) -> Void)?
    var onCancel: (() -> Void)?

    /// Run the entry: 0–180ms threads, 180–320ms glass, 320–420ms text.
    func reveal() {
        generation += 1
        thread = 0; glass = 0; content = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) { self.thread = 1 }
            withAnimation(.easeOut(duration: 0.14).delay(0.18)) { self.glass = 1 }
            withAnimation(.easeOut(duration: 0.12).delay(0.30)) { self.content = 1 }
        }
    }

    /// Run the entry backwards in 240ms, then `done` unless the prompt opened again meanwhile.
    func conceal(_ done: @escaping () -> Void) {
        generation += 1
        let mine = generation
        withAnimation(.easeIn(duration: 0.08)) { content = 0 }
        withAnimation(.easeIn(duration: 0.1).delay(0.06)) { glass = 0 }
        withAnimation(.easeIn(duration: 0.12).delay(0.12)) { thread = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if self?.generation == mine { done() }
        }
    }
}

/// One half of the prompt's outline, from the left edge at `startY` round to the right edge.
struct HalfLoop: Shape {
    var top: Bool
    var startY: CGFloat
    var radius: CGFloat = Glass.radius

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = min(max(startY, rect.minY + radius), rect.maxY - radius)
        let edgeY = top ? rect.minY : rect.maxY
        p.move(to: CGPoint(x: rect.minX, y: y))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: edgeY), tangent2End: CGPoint(x: rect.minX + radius, y: edgeY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: edgeY), tangent2End: CGPoint(x: rect.maxX, y: y), radius: radius)
        p.addLine(to: CGPoint(x: rect.maxX, y: y))
        return p
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @FocusState private var focused: Bool
    var onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.listening {
                    // Listening replaces the app line, so it is plain the mic hears you.
                    LevelBars(level: model.level)
                    Text("Listening · release to send").font(.system(size: 12.5, weight: .medium)).foregroundColor(.llText)
                } else {
                    Circle().fill(model.tagKnown ? Color.llPositive : Color.llFaint).frame(width: 7, height: 7)
                    Text(model.tag)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.llSub)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .frame(height: 16)
            HStack(alignment: .top, spacing: 12) {
                MicBadge(listening: model.listening)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !model.holdingMic { model.holdingMic = true; model.onHold?(true) } }
                        .onEnded { _ in model.holdingMic = false; model.onHold?(false) })
                    .help("Hold to talk; release to send")
                    .background(GeometryReader { g in
                        Color.clear.onAppear {
                            let f = g.frame(in: .global)
                            model.micOffset = CGPoint(x: f.midX, y: f.midY)
                        }
                    })
                TextField(model.listening ? "Listening… release to send" : "Type, or hold the mic to talk",
                          text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundColor(.llText)
                    .lineLimit(1...10)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .padding(.top, 4)
                    .onSubmit { model.onSend?() }
                    .onChange(of: model.text) { _, _ in
                        if focused { model.typed = true; model.pending = nil }
                    }
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 13)).foregroundColor(.llSub)
            }
            HStack(spacing: 8) {
                ForEach(Verb.allCases, id: \.self) { verb in
                    Button { model.verb = model.verb == verb ? nil : verb } label: {
                        Text(verb.label)
                            .font(.system(size: 13, weight: model.verb == verb ? .semibold : .regular))
                            .foregroundColor(model.verb == verb ? .llOnInk : .llSub)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(model.verb == verb ? Color.llInk : Color.clear))
                            .overlay(Capsule().stroke(model.verb == verb ? Color.clear : Color.llHair))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let pending = model.pending {
                    ProgressView(value: pending).progressViewStyle(.linear).tint(.llInk).frame(width: 72)
                    Text("Sending · Esc").font(.system(size: 13)).foregroundColor(.llFaint)
                } else {
                    Button { model.onSend?() } label: {
                        Text("Send ↵").font(.system(size: 13, weight: .semibold)).foregroundColor(.llOnInk)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.llInk))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .opacity(model.content)
        .offset(y: 4 * (1 - model.content))
        .frame(width: 560, alignment: .leading)
        // Its own height, not the window's, so the prompt grows as the text wraps.
        .fixedSize(horizontal: false, vertical: true)
        .overlay(threads)
        .glass(amount: model.glass, edge: model.content)
        .reportsHeight(onHeight)
        .onAppear { if !model.listening { focused = true } }
        .onChange(of: model.listening) { _, listening in if !listening { focused = true } }
    }

    /// The two dotted threads that unwind from the mic round the panel, fading as the hairline fuses.
    private var threads: some View {
        let startY = model.micOffset.y - Glass.margin
        let style = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.01, 4])
        return ZStack {
            HalfLoop(top: true, startY: startY).trim(from: 0, to: model.thread).stroke(Color.llThread, style: style)
            HalfLoop(top: false, startY: startY).trim(from: 0, to: model.thread).stroke(Color.llThread, style: style)
        }
        .opacity(1 - model.content)
        .allowsHitTesting(false)
    }
}

/// Five bars that follow the mic level, so it is plain the mic hears you.
struct LevelBars: View {
    var level: Double
    private static let shape: [Double] = [0.45, 0.8, 1, 0.7, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(Color.llThread)
                    .frame(width: 3, height: 3 + 13 * max(0.08, level * Self.shape[i]))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Animation flag for the mic rings; an object because @State needs Xcode's macro plugins.
final class Pulse: ObservableObject { @Published var on = false }

/// The Llasso mark as the mic. While listening, dotted rings ripple out from it.
struct MicBadge: View {
    var listening: Bool
    @ObservedObject private var pulse = Pulse()

    var body: some View {
        ZStack {
            if listening {
                Circle().stroke(Color.llThread, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.01, 3.5]))
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulse.on ? 1.15 : 0.9)
                    .opacity(pulse.on ? 0.2 : 0.8)
            }
            MarkShape().fill(Color.llInk).frame(width: 26, height: 15)
        }
        .frame(width: 30, height: 30)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) { pulse.on = true }
        }
    }
}

// MARK: - Result card

final class CardModel: ObservableObject {
    enum State { case thinking, streaming, done, failed }

    @Published var title = ""
    @Published var answer = ""
    @Published var state: State = .thinking
    @Published var error: String?
    @Published var followUp = ""
    @Published var askingMore = false
    @Published var copied = false

    /// What the agent proposes, waiting for the user to pick where it goes.
    @Published var proposal: ProposalCard?
    /// A question from the agent, with tappable answers.
    @Published var question: (text: String, options: [String])?
    /// An app change through its MCP server, waiting for approval.
    @Published var step: (title: String, detail: String)?
    /// The step's tool and arguments, shown only when asked for.
    @Published var stepDetailOpen = false
    /// One line per tool that has run in this job.
    @Published var log: [String] = []
    /// A slow piece of work in progress ("Editing the image…").
    @Published var working: String?
    /// The model this request runs on and why, under the title.
    @Published var route: RouteLine?

    var onCopy: (() -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onFollowUp: ((String) -> Void)?
    var onDestination: ((Destination) -> Void)?
    var onAnswer: ((String) -> Void)?
    /// true runs this step, false skips it; `all` approves the rest of the job's steps too.
    var onStep: ((_ run: Bool, _ all: Bool) -> Void)?

    func resetAction() {
        proposal = nil
        question = nil
        step = nil
        working = nil
    }
}

/// Which model a request runs on, as the card shows it.
struct RouteLine: Equatable {
    var work: String
    var model: String
    var auto: Bool
    var reason: String
}

/// The preview a proposal carries on the card.
struct ProposalCard {
    var summary: String
    var text: String?
    var original: String?
    var image: Data?
    /// A clip or sound to play, from a temporary file.
    var mediaURL: URL?
    var isAudio = false
    /// Which model made the picture, clip or sound, and why.
    var madeBy: String?
    var rows: [[String]]?
    var script: String?
    /// A code edit already made: the files it touched and the unified diff.
    var files: [FileChange]?
    var diff: String?
    var destinations: [Destination]
    /// Set once a destination has been used: what happened.
    var done: String?
    /// Why an automatic step didn't happen, shown quietly above the chips.
    var note: String?
    /// The question the first chip answers ("Replace the boxed text in Notes with this?").
    var ask: String?
}

struct CardView: View {
    @ObservedObject var model: CardModel
    @FocusState private var focused: Bool
    var onHeight: (CGFloat) -> Void

    private var dot: Color {
        switch model.state {
        case .thinking, .streaming: return .llThread
        case .done: return .llPositive
        case .failed: return .llDanger
        }
    }

    private var running: Bool {
        model.state == .thinking || model.state == .streaming || model.working != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(model.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.llText)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                // Finished, Thanks! closes the card; the cross is only for one still working.
                if running {
                    Button { model.onClose?() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundColor(.llFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let r = model.route {
                // Which model this runs on and why, so the router's choice is never hidden.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.work.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.llWell))
                        Text(r.model).font(.system(size: 12, weight: .medium)).foregroundColor(.llSub)
                        Text(r.auto ? "· picked by Llasso" : "· your choice").font(.system(size: 12)).foregroundColor(.llFaint)
                    }
                    if r.auto {
                        Text(r.reason).font(.system(size: 12)).foregroundColor(.llFaint)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundColor(.llSub)
            }
            if model.state == .thinking {
                Text("Looking at the box…").font(.system(size: 15)).foregroundColor(.llFaint)
            }
            if !model.answer.isEmpty {
                ScrollView {
                    Text(rendered)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundColor(.llText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !model.log.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.log.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12, design: .monospaced)).foregroundColor(.llFaint)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            if let working = model.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.system(size: 14)).foregroundColor(.llFaint)
                }
            }
            if let p = model.proposal { proposalView(p) }
            if let q = model.question {
                VStack(alignment: .leading, spacing: 10) {
                    Text(q.text).font(.system(size: 15, weight: .medium)).foregroundColor(.llText)
                    FlowRow(items: q.options) { option in
                        chip(option, primary: false) { model.onAnswer?(option) }
                    }
                }
            }
            if let step = model.step {
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.llText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.stepDetailOpen.toggle() } label: {
                        Text(model.stepDetailOpen ? "Hide details" : "Details").font(.system(size: 12)).foregroundColor(.llFaint)
                    }
                    .buttonStyle(.plain)
                    if model.stepDetailOpen {
                        Text(step.detail).font(.system(size: 12, design: .monospaced)).foregroundColor(.llSub)
                            .lineLimit(8).textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        chip("Run", primary: true) { model.onStep?(true, false) }
                        chip("Run all", primary: false) { model.onStep?(true, true) }
                        chip("Skip", primary: false) { model.onStep?(false, false) }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.llWell))
            }
            if let error = model.error {
                Text(error).font(.system(size: 14)).foregroundColor(.llDanger)
                    .textSelection(.enabled)
            }
            if model.askingMore {
                TextField("Ask more about the box", text: $model.followUp, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(.llText)
                    .lineLimit(1...8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.llWell))
                    .focused($focused)
                    .onSubmit { submitFollowUp() }
                    .onAppear { focused = true }
            }
            HStack(spacing: 8) {
                if running {
                    chip("Stop", primary: true) { model.onStop?() }
                } else {
                    if !model.answer.isEmpty {
                        chip(model.copied ? "Copied" : "Copy", primary: model.proposal == nil) { model.onCopy?() }
                    }
                    chip(model.askingMore ? "Send" : "Ask more", primary: false) {
                        if model.askingMore { submitFollowUp() } else { model.askingMore = true }
                    }
                }
                Spacer()
                if !running {
                    chip("Thanks!", primary: false) { model.onClose?() }
                }
            }
        }
        .padding(18)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glass()
        .reportsHeight(onHeight)
    }

    @ViewBuilder
    private func proposalView(_ p: ProposalCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !p.summary.isEmpty {
                Text(p.summary).font(.system(size: 14, weight: .semibold)).foregroundColor(.llText)
            }
            if let original = p.original, !original.isEmpty {
                Text(original).font(.system(size: 13)).strikethrough().foregroundColor(.llFaint)
                    .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let text = p.text {
                ScrollView {
                    Text(text).font(.system(size: 14)).foregroundColor(.llText).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
            }
            if let data = p.image, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { Self.openFullSize(data) }
                    .help("Click to open full size")
                if p.done == nil {
                    Text("Not saved yet. Click the image to see it full size.")
                        .font(.system(size: 11)).foregroundColor(.llFaint)
                }
            }
            if let url = p.mediaURL {
                MediaPreview(url: url, audio: p.isAudio)
                    .frame(maxWidth: .infinity).frame(height: p.isAudio ? 44 : 280)
                if p.done == nil {
                    Text("Not saved yet.").font(.system(size: 11)).foregroundColor(.llFaint)
                }
            }
            if let made = p.madeBy {
                Text(made).font(.system(size: 11)).foregroundColor(.llFaint).fixedSize(horizontal: false, vertical: true)
            }
            if let rows = p.rows {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.prefix(12).enumerated()), id: \.offset) { _, row in
                        Text(row.joined(separator: "   ")).font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.llText).lineLimit(1)
                    }
                }
            }
            if let script = p.script {
                ScrollView {
                    Text(script).font(.system(size: 11, design: .monospaced)).foregroundColor(.llSub)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
            }
            if let files = p.files {
                ForEach(Array(files.prefix(8).enumerated()), id: \.offset) { _, f in
                    HStack(spacing: 8) {
                        Text(f.path).font(.system(size: 12, design: .monospaced)).foregroundColor(.llText).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("+\(f.added)").font(.system(size: 12, design: .monospaced)).foregroundColor(.llPositive)
                        Text("−\(f.removed)").font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.llDanger)
                    }
                }
            }
            if let diff = p.diff, !diff.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(400).enumerated()), id: \.offset) { _, line in
                            Text(String(line)).font(.system(size: 11, design: .monospaced))
                                .foregroundColor(diffColour(line)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
            }
            if let done = p.done {
                Text("✓ " + done).font(.system(size: 13)).foregroundColor(.llPositive)
            }
            if let note = p.note, p.done == nil {
                Text(note).font(.system(size: 12)).foregroundColor(.llSub)
            }
            if let ask = p.ask, p.done == nil {
                Text(ask).font(.system(size: 14, weight: .semibold)).foregroundColor(.llText)
            }
            FlowRow(items: p.destinations) { d in
                chip(d.label, primary: d == p.destinations.first && p.done == nil) { model.onDestination?(d) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.llWell))
    }

    /// Open the image in Preview from a temporary file; nothing is saved anywhere the user keeps.
    static func openFullSize(_ png: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Llasso preview \(UUID().uuidString.prefix(6)).png")
        guard (try? png.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }

    private func diffColour(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return .llFaint }
        if line.hasPrefix("+") { return .llPositive }
        if line.hasPrefix("-") { return .llDanger }
        if line.hasPrefix("@@") { return .llFaint }
        return .llSub
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: model.answer,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(model.answer)
    }

    private func submitFollowUp() {
        let text = model.followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.followUp = ""
        model.askingMore = false
        model.onFollowUp?(text)
    }

    private func chip(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: primary ? .semibold : .regular))
                .foregroundColor(primary ? .llOnInk : .llSub)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(primary ? Color.llInk : Color.clear))
                .overlay(Capsule().stroke(primary ? Color.clear : Color.llHair))
        }
        .buttonStyle(.plain)
    }
}

/// Plays a clip or a sound on the card from its temporary file. AppKit's player view: the
/// SwiftUI VideoPlayer can't load in a SwiftPM build and stops the app.
struct MediaPreview: NSViewRepresentable {
    let url: URL
    let audio: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = audio ? .inline : .floating
        v.showsFullScreenToggleButton = !audio
        v.player = AVPlayer(url: url)
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url { v.player = AVPlayer(url: url) }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

/// Lays chips out left to right and wraps them onto new lines.
struct FlowRow<Item: Hashable, Content: View>: View {
    var items: [Item]
    var content: (Item) -> Content

    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// A small dark notice near the top of the screen, for refusals and permission prompts.
enum Toast {
    private static var panel: FloatingPanel?

    static func show(_ message: String, seconds: Double = 3.5) {
        panel?.orderOut(nil)
        let host = NSHostingView(rootView:
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.llText)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glass(radius: 22)
                .fixedSize())
        let size = host.fittingSize
        let p = FloatingPanel(size: size)
        p.contentView = host
        if let screen = NSScreen.main {
            p.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24 + Glass.margin))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if panel === p { p.orderOut(nil); panel = nil }
        }
    }
}
