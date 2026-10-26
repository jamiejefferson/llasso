import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Feedback from the menu bar: a note, its kind, an optional email and screenshot. Each one goes
/// to the `llasso_feedback` table in Supabase and to feedback.md in the history folder.
enum Feedback {
    // The publishable key is safe to ship: row-level security lets it add feedback rows and
    // nothing else, so the app can never read anyone's feedback back.
    static let endpoint = "https://xlswtyprnmiymfjdbaez.supabase.co/rest/v1/llasso_feedback"
    static let publishableKey = "sb_publishable_ISmJRrzDN3Z6OEdEEZe2Cw_5YvSDGkt"
    /// The screenshot column holds at most 2,000,000 characters of base64.
    static let maxScreenshotB64 = 1_900_000

    enum Kind: String, CaseIterable { case feedback, bug, feature
        var label: String { self == .feature ? "Idea" : rawValue.capitalized }
    }

    /// Sends one note. Throws when Supabase doesn't take it; the local copy is kept either way.
    static func send(_ raw: String, kind: Kind, email: String, screenshot: NSImage?) async throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let jpeg = screenshot.flatMap(encode)
        keepLocal(text, kind: kind, jpeg: jpeg)
        var row: [String: Any] = [
            "text": String(text.prefix(5000)),
            "feedback_type": kind.rawValue,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mail.isEmpty { row["email"] = String(mail.prefix(320)) }
        if let jpeg { row["screenshot_b64"] = jpeg.base64EncodedString() }

        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: row)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            Log.write("feedback: HTTP \(status) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            throw URLError(.badServerResponse)
        }
        Log.write("feedback: sent (\(kind.rawValue))")
    }

    /// Longest side at most 1600px, as JPEG, stepping the quality down until it fits the column.
    private static func encode(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return nil }
        let scale = min(1, 1600 / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        var quality: CGFloat = 0.7
        while quality >= 0.15 {
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               (data.count + 2) / 3 * 4 <= maxScreenshotB64 { return data }
            quality -= 0.1
        }
        return nil
    }

    private static func keepLocal(_ text: String, kind: Kind, jpeg: Data?) {
        let dir = History.folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        var entry = "\n## \(stamp) (\(kind.rawValue))\n\n\(text)\n"
        if let jpeg {
            let name = "feedback-\(stamp.replacingOccurrences(of: ":", with: "-")).jpg"
            if (try? jpeg.write(to: dir.appendingPathComponent(name))) != nil { entry += "\n![screenshot](\(name))\n" }
        }
        let file = dir.appendingPathComponent("feedback.md")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? ("# Llasso feedback\n" + entry).write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

enum FeedbackWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Send feedback"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: FeedbackView(onDone: { window?.close() }))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Form state, held in an object because @State needs Xcode's macro plugins.
final class FeedbackForm: ObservableObject {
    enum Stage: Equatable { case writing, sending, sent, failed }
    @Published var kind = Feedback.Kind.feedback
    @Published var text = ""
    @Published var email = ""
    @Published var screenshot: NSImage?
    @Published var stage = Stage.writing
    @Published var dropTargeted = false

    var canSend: Bool { stage != .sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func reset() { text = ""; screenshot = nil; kind = .feedback; stage = .writing }
}

struct FeedbackView: View {
    @ObservedObject private var form = FeedbackForm()
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's working, what isn't, or what you'd like next. It goes straight to the people who make Llasso.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $form.kind) {
                ForEach(Feedback.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            TextEditor(text: $form.text)
                .font(.system(size: 13))
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
            TextField("Email, if you'd like a reply (optional)", text: $form.email)
                .textFieldStyle(.roundedBorder)
            screenshotRow
            HStack {
                switch form.stage {
                case .sent: Label("Sent. Thank you!", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                case .failed: Text("Couldn't send. It's saved on this Mac; try again.").foregroundColor(.red)
                case .sending: ProgressView().controlSize(.small)
                case .writing: EmptyView()
                }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Send", action: send).keyboardShortcut(.defaultAction).disabled(!form.canSend)
            }
            .font(.system(size: 12))
        }
        .padding(20)
        .frame(width: 460)
        .onDrop(of: [.image, .fileURL], isTargeted: $form.dropTargeted) { drop($0) }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(form.dropTargeted ? 0.8 : 0), lineWidth: 2)
            .padding(4).allowsHitTesting(false))
    }

    @ViewBuilder private var screenshotRow: some View {
        if let shot = form.screenshot {
            HStack(spacing: 10) {
                Image(nsImage: shot).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 110, maxHeight: 62).clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Screenshot attached").font(.system(size: 12)).foregroundColor(.secondary)
                Button("Remove") { form.screenshot = nil }.font(.system(size: 12))
                Spacer()
            }
        } else {
            HStack(spacing: 8) {
                Button("Attach screenshot…", action: pick).font(.system(size: 12))
                Button("Paste") { form.screenshot = Self.pastedImage() }
                    .font(.system(size: 12)).disabled(Self.pastedImage() == nil)
                Text("or drop an image here").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func send() {
        guard form.canSend else { return }
        form.stage = .sending
        let (text, kind, email, shot) = (form.text, form.kind, form.email, form.screenshot)
        Task { @MainActor in
            do {
                try await Feedback.send(text, kind: kind, email: email, screenshot: shot)
                form.stage = .sent
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                form.reset()
                onDone()
            } catch {
                form.stage = .failed
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a screenshot to send with your feedback"
        panel.begin { response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async { form.screenshot = image }
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        if let p = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            _ = p.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async { form.screenshot = image }
            }
            return true
        }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? item as? URL
                guard let url, let image = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { form.screenshot = image }
            }
            return true
        }
        return false
    }

    /// An image on the clipboard: a fresh screenshot, or a copied image file.
    static func pastedImage() -> NSImage? {
        let pb = NSPasteboard.general
        if pb.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier]) {
            return NSImage(pasteboard: pb)
        }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                  .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL]
        return urls?.first.flatMap(NSImage.init(contentsOf:))
    }
}

extension SelfTest {
    /// `--feedbacktest`: opens the form and saves a picture of it as feedback-form.png.
    /// With `--send`, also sends one note marked as a test and writes the outcome to feedbacktest.json.
    @MainActor static func feedback() async {
        FeedbackWindow.show()
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let w = NSApp.windows.first(where: { $0.title == "Send feedback" && $0.isVisible }) {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-l", "\(w.windowNumber)", History.folder.appendingPathComponent("feedback-form.png").path]
            try? shot.run(); shot.waitUntilExit()
        }
        guard CommandLine.arguments.contains("--send") else { return }
        var r: [String: Any] = [:]
        do {
            try await Feedback.send("Test from --feedbacktest. Safe to delete.", kind: .feedback, email: "", screenshot: nil)
            r["sent"] = true
        } catch { r["sent"] = false; r["error"] = "\(error)" }
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("feedbacktest.json"))
        }
    }
}
