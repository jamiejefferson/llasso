import AppKit
import SwiftUI
import LlassoKit

// The model picker, after IDEalize's (Paper, Idealize file, "Model picker" boards 02 to 04):
// a list on the left with search, sort and filter chips, a detail pane on the right, and
// one button that uses the selection. Llasso adds an Auto row on top, which hands the
// choice back to the router, and a "Best for" sort that lists models in the router's order.

enum ModelBrowserWindow {
    private static var window: NSWindow?

    static func show(_ work: Work) {
        window?.close()
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 760),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Choose a model"
        w.isReleasedWhenClosed = false
        w.minSize = CGSize(width: 860, height: 600)
        w.contentView = NSHostingView(rootView: ModelBrowserView(work: work) { [weak w] in w?.close() })
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// The browser's state, held in an object because @State needs Xcode's macro plugins.
final class BrowserState: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case best, cheapest, newest, name
        var id: String { rawValue }
    }
    @Published var query = ""
    @Published var sort: Sort = .best
    @Published var takes: Set<String> = []
    @Published var goodAt: Set<String> = []
    @Published var selected: String

    static let auto = "auto"

    init(selected: String) { self.selected = selected }
}

struct ModelBrowserView: View {
    let work: Work
    var onClose: () -> Void
    @ObservedObject private var store = ModelStore.shared
    @ObservedObject private var state: BrowserState

    init(work: Work, onClose: @escaping () -> Void) {
        self.work = work
        self.onClose = onClose
        state = BrowserState(selected: ModelStore.shared.pin(for: work) ?? BrowserState.auto)
    }

    private var kind: ModelKind { work.kind }
    private var all: [ModelInfo] { store.models(kind) }
    /// Every model in the router's order for this work.
    /// Models that can do this work come first, in the router's order; the rest follow.
    private var ranked: [Scored] {
        let ok = ModelStore.usable(for: work)
        return Router.score(all.filter(ok), for: work, difficulty: .moderate, lean: store.lean)
            + Router.score(all.filter { !ok($0) }, for: work, difficulty: .moderate, lean: store.lean).map { var s = $0; s.known = false; return s }
    }

    private var shown: [ModelInfo] {
        let q = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = ranked.map(\.model).filter { m in
            (q.isEmpty || (m.name + " " + m.maker + " " + m.id + " " + m.summary).lowercased().contains(q))
                && state.takes.isSubset(of: Set(m.takes))
                && state.goodAt.allSatisfy { Self.goodAt(m).contains($0) }
        }
        switch state.sort {
        case .best: break
        case .cheapest:
            list.sort { a, b in
                switch (Prices.line(a).sortValue, Prices.line(b).sortValue) {
                case let (x?, y?): return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.name < b.name
                }
            }
        case .newest: list.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            searchRow
            filters
            Divider()
            HStack(spacing: 0) {
                listPane.frame(width: 600)
                Divider()
                detail
            }
            Divider()
            foot
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refresh() }
    }

    // MARK: Head

    private var head: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(work.label) · \(kind.label)").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    .textCase(.uppercase).foregroundStyle(.secondary)
                Text("Choose a model").font(.system(size: 26, weight: .bold)).tracking(-0.5)
            }
            Spacer()
            Text("\(shown.count) of \(all.count) models").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32).background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain).padding(.leading, 12)
        }
        .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 20)
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $state.query, prompt: Text(searchHint)).textFieldStyle(.plain).font(.system(size: 14))
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 6) {
                Text("Sort").foregroundStyle(.secondary)
                Picker("", selection: $state.sort) {
                    Text("Best for \(work.label.lowercased())").tag(BrowserState.Sort.best)
                    Text("Cheapest first").tag(BrowserState.Sort.cheapest)
                    Text("Newest first").tag(BrowserState.Sort.newest)
                    Text("Name").tag(BrowserState.Sort.name)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 40)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 32).padding(.bottom, 14)
    }

    private var searchHint: String {
        switch kind {
        case .chat: return "Search names and descriptions, e.g. \"coding\" or \"fast\""
        case .image: return "Search names and descriptions, e.g. \"posters\" or \"vector\""
        case .video: return "Search names and descriptions, e.g. \"cinematic\" or \"fast\""
        case .sound: return "Search names and descriptions, e.g. \"music\" or \"voice\""
        }
    }

    // MARK: Filters

    private static let takesLabels: [(String, String)] = [("text", "Text"), ("image", "Pictures"), ("audio", "Sound"), ("video", "Video"), ("file", "Files")]

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            let present = Set(all.flatMap(\.takes))
            chipGroup("Takes", Self.takesLabels.filter { present.contains($0.0) }, selection: $state.takes)
            let good = Self.goodAtLabels(kind).filter { label in all.contains { Self.goodAt($0).contains(label) } }
            if !good.isEmpty { chipGroup("Good at", good.map { ($0, $0) }, selection: $state.goodAt) }
        }
        .padding(.horizontal, 32).padding(.bottom, 20)
    }

    private func chipGroup(_ label: String, _ items: [(String, String)], selection: Binding<Set<String>>) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            WrapLayout(spacing: 6) {
                ForEach(items, id: \.0) { key, title in
                    let on = selection.wrappedValue.contains(key)
                    Button {
                        if on { selection.wrappedValue.remove(key) } else { selection.wrappedValue.insert(key) }
                    } label: {
                        Text(title).font(.system(size: 13, weight: on ? .medium : .regular))
                            .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Color.primary : Color.clear))
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.primary.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func goodAtLabels(_ kind: ModelKind) -> [String] {
        switch kind {
        case .chat: return ["Thinks first", "Long documents", "Quick and cheap", "Top rated"]
        case .image: return ["Edits pictures", "Photoreal", "Illustration", "Lettering", "Vector"]
        case .video: return ["Starts from a picture", "Sound included"]
        case .sound: return ["Speech", "Music"]
        }
    }

    static func goodAt(_ m: ModelInfo) -> [String] {
        let text = (m.id + " " + m.name + " " + m.summary).lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        var out: [String] = []
        switch m.kind {
        case .chat:
            if m.reasoning { out.append("Thinks first") }
            if (m.context ?? 0) >= 1_000_000 { out.append("Long documents") }
            if let v = Prices.line(m).sortValue, v * 1e6 <= 0.5 { out.append("Quick and cheap") }
            if (m.bench.intelligence ?? 0) >= 45 { out.append("Top rated") }
        case .image:
            if m.takes.contains("image") { out.append("Edits pictures") }
            if has("photoreal", "realis", "photograph") { out.append("Photoreal") }
            if has("illustrat", "artistic", "anime", "stylis", "styliz") { out.append("Illustration") }
            if has("typograph", "text rendering", "lettering", "legible text") { out.append("Lettering") }
            if has("vector", "svg") { out.append("Vector") }
        case .video:
            if !m.frames.isEmpty { out.append("Starts from a picture") }
            if m.withAudio { out.append("Sound included") }
        case .sound:
            if m.sound == .speech { out.append("Speech") }
            if m.sound == .music { out.append("Music") }
        }
        if m.utility { out.removeAll() }
        return out
    }

    // MARK: List

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Takes").frame(width: 96, alignment: .leading)
                if all.contains(where: { $0.created != nil }) { Text("Released").frame(width: 72, alignment: .leading) }
                Text(Prices.unit(kind)).lineLimit(1).fixedSize().frame(width: 120, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase).foregroundStyle(.secondary)
            .padding(.leading, 32).padding(.trailing, 24).padding(.top, 20).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        autoRow.id(BrowserState.auto)
                        ForEach(shown) { m in row(m).id(m.id) }
                        if shown.isEmpty {
                            Text(all.isEmpty ? (store.loading ? "Loading OpenRouter's models…" : "No models yet. Check the connection, then Refresh in Settings.")
                                 : "Nothing matches. Clear a filter or the search.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 32).padding(.vertical, 24)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .onAppear { proxy.scrollTo(state.selected, anchor: .center) }
            }
        }
    }

    private var autoPick: Choice { store.choose(work) }

    private var autoRow: some View {
        let on = state.selected == BrowserState.auto
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Auto").font(.system(size: 14.5, weight: .semibold))
                    if store.pin(for: work) == nil { inUse }
                }
                Text("Llasso picks for each request · now \(autoPick.model.name)").font(.system(size: 12.5))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("varies").font(.system(size: 13, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 120, alignment: .trailing)
        }
        .modifier(RowStyle(selected: on))
        .onTapGesture { state.selected = BrowserState.auto }
    }

    private var inUse: some View {
        Text("In use").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func row(_ m: ModelInfo) -> some View {
        let price = Prices.line(m)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    if store.pin(for: work) == m.id { inUse }
                }
                Text(m.utility ? m.maker + " · a tool for existing clips"
                     : ModelStore.usable(for: work)(m) ? m.maker : m.maker + " · can't take the boxed picture").font(.system(size: 12.5))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(Self.ordered(m.takes).prefix(3)), id: \.self) { glyph($0) }
                if m.takes.count > 3 { Text("+\(m.takes.count - 3)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .frame(width: 96, alignment: .leading)
            if all.contains(where: { $0.created != nil }) {
                Text(m.created.map(Self.month) ?? "").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(price.headline ?? "—").font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(price.headline == nil ? .tertiary : .primary)
                Text(price.sub).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 120, alignment: .trailing)
        }
        .modifier(RowStyle(selected: state.selected == m.id))
        .onTapGesture { state.selected = m.id }
    }

    private func glyph(_ input: String) -> some View {
        Group {
            switch input {
            case "text": Text("Aa").font(.system(size: 10.5, weight: .bold))
            case "image": Image(systemName: "photo").font(.system(size: 11))
            case "audio": Image(systemName: "waveform").font(.system(size: 11))
            case "video": Image(systemName: "film").font(.system(size: 11))
            default: Image(systemName: "doc").font(.system(size: 11))
            }
        }
        .foregroundStyle(.secondary)
        .frame(minWidth: 24, minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }

    /// Inputs in one order on every row, so the glyphs line up down the column.
    static func ordered(_ takes: [String]) -> [String] {
        let order = ["text", "image", "audio", "video", "file"]
        return takes.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
    }

    static func month(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }

    // MARK: Detail

    private var selectedModel: ModelInfo? {
        state.selected == BrowserState.auto ? nil : (all.first { $0.id == state.selected } ?? ModelInfo(id: state.selected, kind: kind))
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let m = selectedModel { modelDetail(m) } else { autoDetail }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.02))
    }

    private var autoDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                if store.pin(for: work) == nil { inUse }
                Text("Auto").font(.system(size: 22, weight: .bold))
                Text("Llasso reads each request, then picks the model that suits it best.").foregroundStyle(.secondary)
            }
            Text("It weighs how well each model does \(work.phrase) (from benchmarks OpenRouter publishes, and Llasso's own ratings of each family) against its price and speed. A harder request leans further towards quality. Settings › Lean towards sets the balance; it is \(store.lean.label.lowercased()) now.")
                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Difficulty.allCases, id: \.self) { d in
                    let c = store.choose(work, difficulty: d)
                    fact(d == .simple ? "A quick request" : d == .moderate ? "An everyday request" : "A long or hard request", c.model.name)
                }
            }
            .overlay(alignment: .top) { Divider() }
            Text(autoPick.reason).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func modelDetail(_ m: ModelInfo) -> some View {
        let rank = ranked.firstIndex { $0.id == m.id }
        let scored = rank.map { ranked[$0] }
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                if store.pin(for: work) == m.id { inUse }
                Text(m.name).font(.system(size: 22, weight: .bold)).tracking(-0.3)
                Text(m.maker + (m.created.map { " · released " + Self.month($0) } ?? "")).foregroundStyle(.secondary)
            }
            if !m.summary.isEmpty {
                Text(m.summary).font(.system(size: 14)).lineSpacing(4).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(spacing: 0) {
                fact("Takes", Self.ordered(m.takes).map(Self.takesWord).joined(separator: ", "))
                fact("Makes", m.makes.map(Self.takesWord).joined(separator: ", "))
                let good = Self.goodAt(m)
                if !good.isEmpty { fact("Good at", good.joined(separator: " · ")) }
                if let c = m.context { fact("Remembers up to", c.formatted() + " tokens", figure: true) }
                if let iq = m.bench.intelligence { fact("Intelligence index", String(format: "%.1f", iq), figure: true) }
                if let elo = Router.arenaElo(m) { fact("Design Arena", String(format: "%.0f Elo", elo), figure: true) }
                if let rank, let scored, scored.known, !m.utility {
                    fact("For \(work.label.lowercased())", "#\(rank + 1) of \(ranked.filter(\.known).count) · \(scored.family)")
                } else if m.utility {
                    fact("For \(work.label.lowercased())", "Works on existing clips; Auto never picks it")
                } else if scored != nil {
                    fact("For \(work.label.lowercased())", "Unrated; Auto never picks it")
                }
                if !m.durations.isEmpty { fact("Lengths", m.durations.map { "\($0) s" }.joined(separator: ", ")) }
                if !m.voices.isEmpty { fact("Voices", "\(m.voices.count), e.g. " + m.voices.prefix(3).joined(separator: ", ")) }
                ForEach(Array(Prices.facts(m).enumerated()), id: \.offset) { _, row in fact(row.0, row.1, figure: true) }
                fact("Price from", "OpenRouter")
            }
            .overlay(alignment: .top) { Divider() }
        }
    }

    static func takesWord(_ s: String) -> String {
        switch s {
        case "text": return "Text"
        case "image": return "Pictures"
        case "audio", "sound", "speech": return "Sound"
        case "video": return "Video"
        case "file": return "Files"
        default: return s.capitalized
        }
    }

    private func fact(_ label: String, _ value: String, figure: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(figure ? .system(size: 13, design: .monospaced) : .system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Foot

    private var foot: some View {
        let current = store.pin(for: work) ?? BrowserState.auto
        let name = selectedModel?.name ?? "Auto"
        return HStack(spacing: 10) {
            Text(footNote).foregroundStyle(.secondary).font(.system(size: 13))
            Spacer()
            Button("Cancel", action: onClose).controlSize(.large)
            Button((state.selected == current ? "Keep " : "Use ") + name) {
                store.setPin(state.selected == BrowserState.auto ? nil : state.selected, for: work)
                onClose()
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
    }

    private var footNote: String {
        switch kind {
        case .chat: return "Prices are per million tokens. Models without a price sort last."
        case .image: return "Prices are per million image tokens. Models without a price sort last."
        case .video: return "Clip prices are for 5 seconds at 720p where the model sets prices by size."
        case .sound: return "Speech is priced per 1,000 characters. Models without a price sort last."
        }
    }
}

/// A 62px list row with lanes on fixed widths; the selected row is filled with a 3px bar.
private struct RowStyle: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        content
            .padding(.leading, 32).padding(.trailing, 24)
            .frame(height: 62)
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.06) : Color.clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Color.accentColor).frame(width: 3) } }
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }
}
