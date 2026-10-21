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

    var onCopy: (() -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onFollowUp: ((String) -> Void)?
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
                    chip(model.copied ? "Copied" : "Copy", primary: true) { model.onCopy?() }
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
