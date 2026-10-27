import AppKit
import SwiftUI
import LlassoKit

/// Add a category, or change one: its name, the kind of work it runs as, what it covers and
/// the words that pick it. Opened from Settings › Models.
enum CategoryEditorWindow {
    private static var window: NSWindow?

    /// nil adds a new category.
    static func show(_ category: WorkCategory?) {
        window?.close()
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 440),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = category == nil ? "Add a category" : "Edit \(category!.name)"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: CategoryEditorView(draft: CategoryDraft(category)) { [weak w] in w?.close() })
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// The editor's fields, held in an object because @State needs Xcode's macro plugins.
final class CategoryDraft: ObservableObject {
    enum Sound: String, CaseIterable, Identifiable {
        case any, speech, music
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Speech and music"
            case .speech: return "Speech only"
            case .music: return "Music only"
            }
        }
    }

    let original: WorkCategory?
    @Published var name: String
    @Published var base: Work
    @Published var about: String
    @Published var words: String
    @Published var sound: Sound

    init(_ c: WorkCategory?) {
        original = c
        name = c?.name ?? ""
        base = c?.base ?? .writing
        about = c?.about ?? ""
        words = c?.keywords.joined(separator: ", ") ?? ""
        sound = c?.sound.map { $0 == .speech ? .speech : .music } ?? .any
    }

    var isBuiltIn: Bool { original?.isBuiltIn ?? false }

    var category: WorkCategory {
        var c = original ?? WorkCategory(name: "", base: base, about: "")
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.base = isBuiltIn ? c.base : base
        c.about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        c.keywords = words.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        c.sound = c.base == .sound ? (sound == .speech ? .speech : sound == .music ? .music : nil) : nil
        return c
    }

    var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct CategoryEditorView: View {
    @ObservedObject var draft: CategoryDraft
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Illustration"))
                    Picker("Runs as", selection: $draft.base) {
                        ForEach(Work.allCases) { w in Text("\(w.label) · \(w.kind.label)s").tag(w) }
                    }
                    .disabled(draft.isBuiltIn)
                    if draft.base == .sound {
                        Picker("Makes", selection: $draft.sound) {
                            ForEach(CategoryDraft.Sound.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } footer: {
                    Text(draft.isBuiltIn
                         ? "A built-in category always runs as its own kind of work."
                         : "Runs as sets which models it can use and how Llasso rates them. Illustration would run as Image; Voice would run as Sound, making speech only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Covers", text: $draft.about, prompt: Text("Flat, editorial illustrations and spot drawings"), axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Words that pick it", text: $draft.words, prompt: Text("illustration, illustrate, spot drawing"))
                } footer: {
                    Text("Covers says, in your words, what requests belong here; Llasso reads it when it decides. A request that uses one of the words, separated by commas, comes here straight away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let original = draft.original {
                    if original.isBuiltIn {
                        Button("Reset") { ModelStore.shared.reset(original); onClose() }
                            .disabled(original == .builtIn(original.base))
                    } else {
                        Button("Delete", role: .destructive) { ModelStore.shared.remove(original); onClose() }
                    }
                }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? "Add" : "Save") {
                    ModelStore.shared.save(draft.category)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
    }
}
