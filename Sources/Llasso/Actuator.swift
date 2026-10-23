import AppKit
import ApplicationServices
import LlassoKit
import UniformTypeIdentifiers

/// Where a proposal can go. Llasso offers only the ones that work for the box.
enum Destination: Hashable {
    case replaceInPlace(app: String)
    case pasteInto(app: String)
    case replaceFile(name: String)
    case copy
    case newDocument
    case saveAs
    case writeCells(app: String)
    case run
    case keepCode
    case undoCode
    case openCode(name: String)
    case undoText(app: String)

    var label: String {
        switch self {
        case .replaceInPlace(let app): return "Replace in \(app)"
        case .pasteInto(let app): return "Paste into \(app)"
        case .replaceFile(let name): return "Save beside \(name)"
        case .copy: return "Copy"
        case .newDocument: return "New document"
        case .saveAs: return "Save to…"
        case .writeCells(let app): return "Write to \(app)"
        case .run: return "Run"
        case .keepCode: return "Keep"
        case .undoCode: return "Undo"
        case .openCode(let name): return "Open \(name)"
        case .undoText: return "Undo"
        }
    }
}

enum ActionError: Error, LocalizedError {
    case failed(String)
    /// The user closed a panel; nothing happened and nothing needs saying.
    case cancelled
    var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
}

/// Carries out proposals in the app the user boxed.
@MainActor
enum Actuator {
    /// Folder for saved results when no project resolved.
    static var outputFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Llasso", isDirectory: true)
    }

    static func destinations(for p: Proposal, context c: ScreenContext) -> [Destination] {
        let app = c.appName ?? "the app"
        switch p {
        case .text:
            var d: [Destination] = []
            if c.canReplaceText || c.canSetField || c.mayHoldSelection { d.append(.replaceInPlace(app: app)) }
            d += [.copy, .newDocument, .saveAs]
            return d
        case .image:
            var d: [Destination] = []
            if let path = c.documentPath, ContentKind.imageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                d.append(.replaceFile(name: (path as NSString).lastPathComponent))
            }
            if c.kind != .webPage && c.kind != .readOnlyText { d.append(.pasteInto(app: app)) }
            d += [.copy, .saveAs]
            return d
        case .cells:
            var d: [Destination] = []
            if let s = c.sheet { d.append(.writeCells(app: s.app == .numbers ? "Numbers" : "Excel")) }
            else { d.append(.pasteInto(app: app)) }
            d.append(.copy)
            return d
        case .script:
            return [.run]
        }
    }

    /// The chips under a code edit that has already been made.
    static func codeDestinations(changed: [FileChange]) -> [Destination] {
        var d: [Destination] = [.keepCode, .undoCode]
        if let first = changed.first { d.append(.openCode(name: (first.path as NSString).lastPathComponent)) }
        return d
    }

    // MARK: Text

    static func text(_ text: String, to d: Destination, context c: ScreenContext, app: NSRunningApplication?) async throws -> String {
        switch d {
        case .replaceInPlace(let name):
            try await replaceText(text, context: c, app: app)
            return "Replaced the text in \(name)."
        case .pasteInto(let name):
            try await paste(.string(text), into: app)
            return "Pasted into \(name)."
        case .copy:
            copy(.string(text))
            return "Copied to the clipboard."
        case .undoText(let name):
            guard let app else { throw ActionError.failed("The app has closed.") }
            try await bringForward(app)
            try press(6, command: true, to: app)   // ⌘Z
            return "Undone in \(name)."
        case .newDocument:
            try newDocument(text)
            return "Opened a new TextEdit document with the text."
        case .saveAs:
            let url = try saveAs(Data(text.utf8), ext: "txt", context: c)
            return "Saved \(url.lastPathComponent) in \(url.deletingLastPathComponent().lastPathComponent)."
        default:
            throw ActionError.failed("That destination doesn't take text.")
        }
    }

    /// Replace the selection through Accessibility, read it back to check, and fall back
    /// to pasting over the selection, which works in browsers and Electron editors.
    static func replaceText(_ text: String, context c: ScreenContext, app: NSRunningApplication?,
                            allowPaste: Bool = true) async throws {
        guard let app else { throw ActionError.failed("The app has closed.") }
        try await bringForward(app)
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let focused: AXUIElement? = ContextReader.attr(appEl, kAXFocusedUIElementAttribute)
        // Native text views keep the selection's style when Accessibility swaps its text.
        // Web pages don't, so they always take a styled paste instead.
        if !c.isWeb, c.canReplaceText, let focused {
            if AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success,
               let value: String = ContextReader.attr(focused, kAXValueAttribute), value.contains(text) {
                return
            }
            guard allowPaste else { throw ActionError.failed("Accessibility refused the change.") }
        } else if !c.isWeb, c.canSetField {
            guard let focused, AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, text as CFTypeRef) == .success else {
                throw ActionError.failed("\(c.appName ?? "The app") refused the change.")
            }
            return
        }
        guard allowPaste, c.canReplaceText || c.canSetField || c.mayHoldSelection else {
            throw ActionError.failed("Llasso can't put text back in this app. Copy it instead.")
        }
        // ⌘C proves there is a selection, so nothing lands at a stray caret, and hands over
        // the selection's formatting for the replacement to wear.
        guard let copied = await copySelection(in: app) else {
            throw ActionError.failed("Nothing is selected in \(c.appName ?? "the app"). Select the text, then tap Replace.")
        }
        try await paste(await styled(text, like: copied), into: app)
    }

    struct Copied { var text: String; var html: String? }

    /// The replacement dressed in the selection's formatting. Paragraph-for-paragraph when each
    /// paragraph is one style; otherwise a model rewrites the copied HTML and Llasso keeps it only
    /// if every tag survived and the words are exactly the new text. Plain text is the last resort.
    static func styled(_ text: String, like copied: Copied) async -> Clip {
        guard let html = copied.html, !RichText.plain(html).isEmpty else {
            Log.write("replace: plain (no formatting copied)"); return .string(text)
        }
        if RichText.isSimple(html), let swapped = RichText.swapParagraphs(html, with: text) {
            Log.write("replace: paragraph styles kept"); return .rich(html: swapped, text: text)
        }
        if let rewritten = await rewrite(html, as: text), RichText.isFaithful(rewritten, original: html, text: text) {
            Log.write("replace: inline styles kept by rewrite"); return .rich(html: rewritten, text: text)
        }
        if let swapped = RichText.swapParagraphs(html, with: text) {
            Log.write("replace: paragraph styles kept, inline styles lost"); return .rich(html: swapped, text: text)
        }
        Log.write("replace: plain (paragraphs didn't line up)")
        return .string(text)
    }

    static func rewrite(_ html: String, as text: String) async -> String? {
        guard html.count < 60_000 else { return nil }
        let messages: [ChatMessage] = [.system(RichText.rewritePrompt),
                                       .user("HTML:\n\(html)\n\nNew text:\n\(text)")]
        return try? await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var out = ""
                for try await chunk in Settings.shared.client.streamTurn(model: Settings.shared.model, messages: messages, tools: []) {
                    if case .text(let t) = chunk { out += t }
                }
                return out.replacingOccurrences(of: "^```[a-z]*\\s*|\\s*```$", with: "", options: .regularExpression)
            }
            group.addTask { try await Task.sleep(nanoseconds: 20_000_000_000); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func hasSelection(in app: NSRunningApplication) async -> Bool { await copySelection(in: app) != nil }

    /// The selection as the app copies it: ⌘C changes the clipboard only when something is
    /// selected. The clipboard is put back afterwards.
    static func copySelection(in app: NSRunningApplication) async -> Copied? {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        let before = pb.changeCount
        guard (try? await bringForward(app)) != nil else { return nil }
        guard (try? press(8, command: true, to: app)) != nil else { return nil }   // ⌘C
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string) ?? ""
        let html = pb.string(forType: .html)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return text.isEmpty ? nil : Copied(text: text, html: html)
    }

    /// Bring the boxed app to the front and wait until it is, because a keystroke sent before
    /// then lands in whichever app is in front. Asks again halfway, this time also through
    /// Accessibility, since a busy Electron app can miss the first request. Throws rather than
    /// type into the wrong app.
    static func bringForward(_ app: NSRunningApplication) async throws {
        func ask() {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
            app.activate(options: [.activateAllWindows])
        }
        ask()
        for i in 0..<40 {
            if isFront(app) {
                try await Task.sleep(nanoseconds: 150_000_000)
                return
            }
            if i == 15 {
                ask()
                let appEl = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                if let window: AXUIElement = ContextReader.attr(appEl, kAXMainWindowAttribute) {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Log.write("front: \(app.localizedName ?? "?") \(app.processIdentifier) never came forward; \(focusReport())")
        throw ActionError.failed("\(app.localizedName ?? "The app") wouldn't come to the front, so Llasso typed nothing.")
    }

    /// The pid Accessibility names as focused, or nil when it can't say (a busy app can make
    /// the system-wide query fail).
    static func focusedPid() -> pid_t? {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
    }

    static func focusReport() -> String {
        "ax \(focusedPid().map(String.init) ?? "no answer"), workspace \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"
    }

    /// Whether `app` has keyboard focus right now. Accessibility answers live; NSWorkspace's
    /// frontmost app can lag a focus change by a beat, so it counts only when Accessibility
    /// can't answer and the app itself agrees it is active.
    static func isFront(_ app: NSRunningApplication) -> Bool {
        if let pid = focusedPid() { return pid == app.processIdentifier }
        return app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Send a keystroke to `app`, refusing if another app has taken the front since.
    static func press(_ key: CGKeyCode, command: Bool, to app: NSRunningApplication) throws {
        guard isFront(app) else {
            throw ActionError.failed("\(app.localizedName ?? "The app") lost the front before Llasso could type, so nothing was typed.")
        }
        press(key, command: command)
    }

    static func press(_ key: CGKeyCode, command: Bool) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        if command { down?.flags = .maskCommand; up?.flags = .maskCommand }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Images

    /// `fit` is the boxed area's pixel size: an image going back into an app is scaled to it,
    /// because image models answer at their own size (often 1024 square).
    static func image(_ png: Data, to d: Destination, context c: ScreenContext, app: NSRunningApplication?,
                      fit: CGSize?, points: CGSize?) async throws -> String {
        switch d {
        case .replaceFile:
            // The box may cover only part of the file, so the edit never overwrites it.
            guard let path = c.documentPath else { throw ActionError.failed("Llasso lost track of the file.") }
            let url = URL(fileURLWithPath: path)
            var out = url.deletingPathExtension().appendingPathExtension("llasso").appendingPathExtension(url.pathExtension)
            var n = 2
            while FileManager.default.fileExists(atPath: out.path) {
                out = url.deletingPathExtension().appendingPathExtension("llasso-\(n)").appendingPathExtension(url.pathExtension)
                n += 1
            }
            try encode(png, as: url.pathExtension).write(to: out)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            return "Saved \(out.lastPathComponent) beside the original."
        case .pasteInto(let name):
            try await paste(.png(resized(png, to: fit, points: points)), into: app)
            return "Pasted the image into \(name)."
        case .copy:
            copy(.png(png))
            return "Copied the image to the clipboard."
        case .saveAs:
            let url = try saveAs(png, ext: "png", context: c)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Saved \(url.lastPathComponent) in \(url.deletingLastPathComponent().lastPathComponent)."
        default:
            throw ActionError.failed("That destination doesn't take an image.")
        }
    }

    /// Scale to `size` pixels, tagged as `points` so a Retina capture pastes at the size it was boxed.
    static func resized(_ png: Data, to size: CGSize?, points: CGSize? = nil) -> Data {
        guard let size, size.width > 0, size.height > 0,
              let src = NSBitmapImageRep(data: png), src.pixelsWide != Int(size.width) || src.pixelsHigh != Int(size.height),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return png }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        if let points { rep.size = points }
        return rep.representation(using: .png, properties: [:]) ?? png
    }

    static func encode(_ png: Data, as ext: String) throws -> Data {
        let type: NSBitmapImageRep.FileType
        switch ext.lowercased() {
        case "jpg", "jpeg": type = .jpeg
        case "tif", "tiff": type = .tiff
        case "gif": type = .gif
        case "bmp": type = .bmp
        default: return png
        }
        guard let rep = NSBitmapImageRep(data: png), let out = rep.representation(using: type, properties: [:]) else {
            throw ActionError.failed("Llasso couldn't convert the image to .\(ext).")
        }
        return out
    }

    // MARK: Spreadsheets

    static func cells(start: String?, rows: [[String]], to d: Destination, context c: ScreenContext,
                      app: NSRunningApplication?) async throws -> String {
        let tsv = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        switch d {
        case .writeCells:
            guard let sheet = c.sheet else { throw ActionError.failed("Llasso lost the spreadsheet selection.") }
            let origin = start ?? CellRef.topLeft(of: sheet.address)
            guard let o = CellRef.parse(origin) else { throw ActionError.failed("\(origin) isn't a cell address.") }
            try Sheets.write(rows, at: o, in: sheet.app)
            let end = CellRef.name(col: o.col + max(0, (rows.map(\.count).max() ?? 1) - 1), row: o.row + rows.count - 1)
            return "Wrote \(origin)\(end == origin ? "" : ":" + end)."
        case .pasteInto(let name):
            try await paste(.string(tsv), into: app)
            return "Pasted the cells into \(name)."
        case .copy:
            copy(.string(tsv))
            return "Copied as a table; paste it into any spreadsheet."
        default:
            throw ActionError.failed("That destination doesn't take cells.")
        }
    }

    // MARK: Scripts

    static func run(script: String) async throws -> String {
        let out = try await Shell.osascript(script)
        return out.isEmpty ? "The script ran." : "The script ran and returned: \(out.prefix(500))"
    }

    // MARK: Shared

    enum Clip { case string(String), png(Data), rich(html: String, text: String) }

    static func copy(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clip {
        case .string(let s): pb.setString(s, forType: .string)
        case .rich(let html, let text):
            pb.setString(html, forType: .html)
            pb.setString(text, forType: .string)
        case .png(let d): pb.setData(d, forType: .png)
            if let rep = NSBitmapImageRep(data: d), let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        }
    }

    /// Put the clip on the clipboard, bring the app forward, press ⌘V, then put back what
    /// the clipboard held before.
    static func paste(_ clip: Clip, into app: NSRunningApplication?) async throws {
        guard AXIsProcessTrusted() else { throw ActionError.failed("Pasting needs Accessibility permission. Allow it in Llasso's settings.") }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        guard let app else { throw ActionError.failed("The app has closed.") }
        try await bringForward(app)
        copy(clip)
        do { try press(9, command: true, to: app) }   // ⌘V
        catch { pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) }; throw error }
        try await Task.sleep(nanoseconds: 600_000_000)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }

    static func newDocument(_ text: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Llasso \(stamp()).txt")
        try Data(text.utf8).write(to: url)
        let config = NSWorkspace.OpenConfiguration()
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(url); return
        }
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
    }

    /// Ask where to save, starting in the project behind the box when there is one,
    /// otherwise where the user last saved. Throws `.cancelled` if they close the panel.
    static func saveAs(_ data: Data, ext: String, context c: ScreenContext) throws -> URL {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [ext == "png" ? .png : .plainText]
        panel.nameFieldStringValue = "Llasso \(stamp()).\(ext)"
        panel.directoryURL = startFolder(context: c, ext: ext)
        panel.message = c.source.map { "Saving into \($0.name)" } ?? ""
        // runModal puts the panel at the modal level, under Llasso's overlay and card;
        // drop those below it while the panel is open.
        let raised = NSApp.windows.filter { $0 !== panel && $0.isVisible && $0.level.rawValue > NSWindow.Level.modalPanel.rawValue }
        let levels = raised.map(\.level)
        raised.forEach { $0.level = .floating }
        defer { zip(raised, levels).forEach { $0.level = $1 } }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { throw ActionError.cancelled }
        try data.write(to: url)
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastFolderKey)
        return url
    }

    static let lastFolderKey = "lastSaveFolder"

    /// The folder the save panel opens in. Inside a project: the last folder used there,
    /// else its usual image folder for images, else its root.
    static func startFolder(context c: ScreenContext, ext: String) -> URL {
        let fm = FileManager.default
        let last = UserDefaults.standard.string(forKey: lastFolderKey).flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
        if let root = c.source?.root {
            if let last, last.hasPrefix(root) { return URL(fileURLWithPath: last) }
            let candidates = ext == "png" ? ["public/images", "src/assets/images", "assets/images", "images", "src/assets", "assets", "public"] : []
            for sub in candidates where fm.fileExists(atPath: root + "/" + sub) { return URL(fileURLWithPath: root + "/" + sub) }
            return URL(fileURLWithPath: root)
        }
        if let last { return URL(fileURLWithPath: last) }
        try? fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        return outputFolder
    }

    static func save(_ data: Data, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let url = outputFolder.appendingPathComponent("Llasso \(stamp()).\(ext)")
        try data.write(to: url)
        return url
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}

/// Reads and writes spreadsheet selections in Numbers and Excel through AppleScript.
enum Sheets {
    static func app(for bundleID: String?) -> SheetSelection.App? {
        switch bundleID {
        case "com.apple.iWork.Numbers": return .numbers
        case "com.microsoft.Excel": return .excel
        default: return nil
        }
    }

    /// The selection's address and values, rows separated by newlines and cells by tabs.
    static func read(_ app: SheetSelection.App) -> SheetSelection? {
        let script: String
        switch app {
        case .excel:
            // Inside an app's tell block `tab` can resolve to the app's own term; use a character id.
            script = """
            set TB to character id 9
            tell application "Microsoft Excel"
                set r to selection
                set addr to get address r row absolute false column absolute false
                set v to value of r
                set out to addr & linefeed
                if class of v is list then
                    repeat with rowv in v
                        set ln to ""
                        if class of rowv is list then
                            repeat with c in rowv
                                set ln to ln & (c as text) & TB
                            end repeat
                        else
                            set ln to (rowv as text) & TB
                        end if
                        set out to out & ln & linefeed
                    end repeat
                else
                    set out to out & (v as text) & linefeed
                end if
                return out
            end tell
            """
        case .numbers:
            script = """
            set TB to character id 9
            tell application "Numbers"
                tell front document's active sheet
                    set t to first table whose selection range is not missing value
                    set sr to selection range of t
                    set addr to name of sr
                    set out to addr & linefeed
                    repeat with rw in rows of sr
                        set ln to ""
                        repeat with c in cells of rw
                            set v to value of c
                            if v is missing value then set v to ""
                            set ln to ln & (v as text) & TB
                        end repeat
                        set out to out & ln & linefeed
                    end repeat
                    return out
                end tell
            end tell
            """
        }
        guard let out = try? Shell.osascriptSync(script, timeout: 3) else { return nil }
        var lines = out.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let address = lines.removeFirst().replacingOccurrences(of: "$", with: "")
        let values = lines.filter { !$0.isEmpty }.map { line in
            line.hasSuffix("\t") ? String(line.dropLast()).components(separatedBy: "\t") : line.components(separatedBy: "\t")
        }
        return SheetSelection(app: app, address: address, values: values)
    }

    static func write(_ rows: [[String]], at origin: (col: Int, row: Int), in app: SheetSelection.App) throws {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var body = ""
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() {
                let ref = CellRef.name(col: origin.col + c, row: origin.row + r)
                switch app {
                case .excel:
                    let prop = value.hasPrefix("=") ? "formula" : "value"
                    body += "set \(prop) of range \(quoted(ref)) of active sheet to \(quoted(value))\n"
                case .numbers:
                    body += "set value of cell \(quoted(ref)) of t to \(quoted(value))\n"
                }
            }
        }
        let script: String
        switch app {
        case .excel:
            script = "tell application \"Microsoft Excel\"\n\(body)end tell"
        case .numbers:
            script = """
            tell application "Numbers"
                tell front document's active sheet
                    set t to first table whose selection range is not missing value
            \(body)
                end tell
            end tell
            """
        }
        _ = try Shell.osascriptSync(script, timeout: 20)
    }
}

/// Runs osascript off the main thread so a slow app can't freeze Llasso.
enum Shell {
    static func osascriptSync(_ script: String, timeout: TimeInterval) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); throw ActionError.failed("The app took too long to answer the script.") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ActionError.failed("The script failed: " + e.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text.trimmingCharacters(in: .newlines)
    }

    static func osascript(_ script: String, timeout: TimeInterval = 60) async throws -> String {
        try await Task.detached { try osascriptSync(script, timeout: timeout) }.value
    }
}

/// An amber ring with a label, shown where the model points.
@MainActor
enum Pointer {
    private static var panels: [NSPanel] = []

    static func ring(at point: CGPoint, label: String, seconds: Double = 6) {
        let size = CGSize(width: 64, height: 64)
        let ring = NSPanel(contentRect: CGRect(origin: .zero, size: CGSize(width: 320, height: size.height)),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ring.isOpaque = false
        ring.backgroundColor = .clear
        ring.hasShadow = false
        ring.ignoresMouseEvents = true
        ring.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        ring.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RingView(frame: CGRect(origin: .zero, size: ring.frame.size))
        view.label = label
        ring.contentView = view
        ring.setFrameOrigin(CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        ring.orderFrontRegardless()
        panels.append(ring)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            ring.orderOut(nil)
            panels.removeAll { $0 === ring }
        }
    }

    static func clear() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private final class RingView: NSView {
        var label = ""
        override func draw(_ dirtyRect: NSRect) {
            let r = CGRect(x: 6, y: 6, width: 52, height: 52)
            let path = NSBezierPath(ovalIn: r)
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = Palette.gold.withAlphaComponent(0.8)
            glow.shadowBlurRadius = 6
            glow.set()
            Palette.gold.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 2
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.setLineDash([0.01, 4], count: 2, phase: 0)
            Palette.gold.setStroke()
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                        .foregroundColor: NSColor(white: 0.08, alpha: 1)]
            let text = NSAttributedString(string: label, attributes: attrs)
            let w = min(240, text.size().width + 20)
            let pill = CGRect(x: 66, y: 20, width: w, height: 24)
            let shape = NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12)
            NSColor(white: 1, alpha: 0.92).setFill()
            shape.fill()
            Palette.gold.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            text.draw(in: pill.insetBy(dx: 10, dy: 4))
        }
    }
}
