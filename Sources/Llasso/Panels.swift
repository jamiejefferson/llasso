import AppKit
import SwiftUI
import LlassoKit

extension Color {
    static let llInk = Color(nsColor: Palette.ink)
    static let llPaper = Color(nsColor: Palette.paper)
    static let llAmber = Color(nsColor: Palette.amber)
    static let llMuted = Color(nsColor: Palette.muted)
    static let llLine = Color(nsColor: Palette.line)
    static let llOK = Color(nsColor: Palette.ok)
    static let llWell = Color(red: 0.094, green: 0.094, blue: 0.086)   // #181816
}

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
    @Published var verb: Verb?
    /// 0...1 while the pause-to-send countdown runs, nil otherwise.
    @Published var pending: Double?
    @Published var typed = false
    @Published var notice: String?

    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @FocusState private var focused: Bool
    var onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(model.tagKnown ? Color.llOK : Color.llMuted).frame(width: 8, height: 8)
                Text(model.tag)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.73))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
            }
            HStack(alignment: .top, spacing: 12) {
                MicBadge(listening: model.listening)
                TextField(model.listening ? "Listening… or type" : "Ask about the box",
                          text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundColor(.llPaper)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { model.onSend?() }
                    .onChange(of: model.text) { _, _ in
                        if focused { model.typed = true; model.pending = nil }
                    }
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 13)).foregroundColor(.llAmber)
            }
            HStack(spacing: 8) {
                ForEach(Verb.allCases, id: \.self) { verb in
                    Button { model.verb = model.verb == verb ? nil : verb } label: {
                        Text(verb.label)
                            .font(.system(size: 13, weight: model.verb == verb ? .semibold : .regular))
                            .foregroundColor(model.verb == verb ? .llInk : Color(white: 0.73))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(model.verb == verb ? Color.llPaper : Color.clear))
                            .overlay(Capsule().stroke(model.verb == verb ? Color.clear : Color.llLine))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let pending = model.pending {
                    ProgressView(value: pending).progressViewStyle(.linear).tint(.llAmber).frame(width: 72)
                    Text("Sending · Esc").font(.system(size: 13)).foregroundColor(.llMuted)
                } else {
                    Button { model.onSend?() } label: {
                        Text("Send ↵").font(.system(size: 13, weight: .semibold)).foregroundColor(.llInk)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.llAmber))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.llInk))
        .reportsHeight(onHeight)
        .onAppear { if !model.listening { focused = true } }
        .onChange(of: model.listening) { _, listening in if !listening { focused = true } }
    }
}

/// Animation flag for the mic badge; an object because @State needs Xcode's macro plugins.
final class Pulse: ObservableObject { @Published var on = false }

struct MicBadge: View {
    var listening: Bool
    @ObservedObject private var pulse = Pulse()

    var body: some View {
        ZStack {
            Circle().fill(listening ? Color.llAmber : Color.llLine)
            HStack(spacing: 2) {
                ForEach([6.0, 12.0, 9.0, 5.0], id: \.self) { h in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(listening ? Color.llInk : Color.llMuted)
                        .frame(width: 3, height: listening && pulse.on ? h : max(4, h * 0.5))
                }
            }
        }
        .frame(width: 28, height: 28)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pulse.on = true }
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
    /// One line per tool that has run in this job.
    @Published var log: [String] = []
    /// A slow piece of work in progress ("Editing the image…").
    @Published var working: String?

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

/// The preview a proposal carries on the card.
struct ProposalCard {
    var summary: String
    var text: String?
    var original: String?
    var image: Data?
    var rows: [[String]]?
    var script: String?
    /// A code edit already made: the files it touched and the unified diff.
    var files: [FileChange]?
    var diff: String?
    var destinations: [Destination]
    /// Set once a destination has been used: what happened.
    var done: String?
}

struct CardView: View {
    @ObservedObject var model: CardModel
    @FocusState private var focused: Bool
    var onHeight: (CGFloat) -> Void

    private var dot: Color {
        switch model.state {
        case .thinking, .streaming: return .llAmber
        case .done: return .llOK
        case .failed: return Color(red: 0.89, green: 0.40, blue: 0.36)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(model.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.llPaper)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundColor(.llMuted)
                }
                .buttonStyle(.plain)
            }
            if model.state == .thinking {
                Text("Looking at the box…").font(.system(size: 15)).foregroundColor(.llMuted)
            }
            if !model.answer.isEmpty {
                ScrollView {
                    Text(rendered)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundColor(.llPaper)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !model.log.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.log.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12, design: .monospaced)).foregroundColor(.llMuted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            if let working = model.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.system(size: 14)).foregroundColor(.llMuted)
                }
            }
            if let p = model.proposal { proposalView(p) }
            if let q = model.question {
                VStack(alignment: .leading, spacing: 10) {
                    Text(q.text).font(.system(size: 15, weight: .medium)).foregroundColor(.llPaper)
                    FlowRow(items: q.options) { option in
                        chip(option, primary: false) { model.onAnswer?(option) }
                    }
                }
            }
            if let step = model.step {
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.llAmber)
                    Text(step.detail).font(.system(size: 12, design: .monospaced)).foregroundColor(Color(white: 0.73))
                        .lineLimit(6).textSelection(.enabled)
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
                Text(error).font(.system(size: 14)).foregroundColor(Color(red: 0.95, green: 0.55, blue: 0.5))
                    .textSelection(.enabled)
            }
            if model.askingMore {
                TextField("Ask more about the box", text: $model.followUp, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(.llPaper)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.llWell))
                    .focused($focused)
                    .onSubmit { submitFollowUp() }
                    .onAppear { focused = true }
            }
            HStack(spacing: 8) {
                if model.state == .thinking || model.state == .streaming {
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
                Text("Esc closes").font(.system(size: 12)).foregroundColor(.llMuted)
            }
        }
        .padding(18)
        .frame(width: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.llInk))
        .reportsHeight(onHeight)
    }

    @ViewBuilder
    private func proposalView(_ p: ProposalCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !p.summary.isEmpty {
                Text(p.summary).font(.system(size: 14, weight: .semibold)).foregroundColor(.llAmber)
            }
            if let original = p.original, !original.isEmpty {
                Text(original).font(.system(size: 13)).strikethrough().foregroundColor(.llMuted)
                    .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let text = p.text {
                ScrollView {
                    Text(text).font(.system(size: 14)).foregroundColor(.llPaper).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
            }
            if let data = p.image, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let rows = p.rows {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.prefix(12).enumerated()), id: \.offset) { _, row in
                        Text(row.joined(separator: "   ")).font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.llPaper).lineLimit(1)
                    }
                }
            }
            if let script = p.script {
                ScrollView {
                    Text(script).font(.system(size: 11, design: .monospaced)).foregroundColor(Color(white: 0.73))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
            }
            if let files = p.files {
                ForEach(Array(files.prefix(8).enumerated()), id: \.offset) { _, f in
                    HStack(spacing: 8) {
                        Text(f.path).font(.system(size: 12, design: .monospaced)).foregroundColor(.llPaper).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("+\(f.added)").font(.system(size: 12, design: .monospaced)).foregroundColor(.llOK)
                        Text("−\(f.removed)").font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(red: 0.89, green: 0.40, blue: 0.36))
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
                Text("✓ " + done).font(.system(size: 13)).foregroundColor(.llOK)
            }
            FlowRow(items: p.destinations) { d in
                chip(d.label, primary: d == p.destinations.first && p.done == nil) { model.onDestination?(d) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.llWell))
    }

    private func diffColour(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return .llMuted }
        if line.hasPrefix("+") { return .llOK }
        if line.hasPrefix("-") { return Color(red: 0.89, green: 0.40, blue: 0.36) }
        if line.hasPrefix("@@") { return .llAmber }
        return Color(white: 0.73)
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
                .foregroundColor(primary ? .llInk : Color(white: 0.73))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(primary ? Color.llPaper : Color.clear))
                .overlay(Capsule().stroke(primary ? Color.clear : Color.llLine))
        }
        .buttonStyle(.plain)
    }
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
                .foregroundColor(.llPaper)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Capsule().fill(Color.llInk))
                .fixedSize())
        let size = host.fittingSize
        let p = FloatingPanel(size: size)
        p.contentView = host
        if let screen = NSScreen.main {
            p.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if panel === p { p.orderOut(nil); panel = nil }
        }
    }
}
