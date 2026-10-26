import Foundation

/// What sort of thing the box holds. Llasso guesses it from the operating system's
/// context before the model sees anything, and the guess decides which actions it offers.
public enum ContentKind: String, Sendable {
    case editableText = "editable text"
    case readOnlyText = "read-only text"
    case webPage = "web page"
    case image
    case spreadsheet
    case design = "design canvas"
    case interface = "app interface"

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "webp", "bmp"]
    static let spreadsheetBundles: Set<String> = ["com.apple.iWork.Numbers", "com.microsoft.Excel"]
    static let designBundles: Set<String> = ["com.figma.Desktop", "com.bohemiancoding.sketch3"]
    static let imageBundles: Set<String> = ["com.apple.Preview", "com.apple.Photos", "com.pixelmatorteam.pixelmator.x",
                                            "com.adobe.Photoshop", "com.seriflabs.affinityphoto2"]

    public static func classify(_ c: ScreenContext) -> ContentKind {
        let bundle = c.bundleID ?? ""
        if c.sheet != nil || spreadsheetBundles.contains(bundle)
            || (c.url ?? "").contains("docs.google.com/spreadsheets") { return .spreadsheet }
        if c.integration != nil || designBundles.contains(bundle) { return c.url != nil ? .webPage : .design }
        if let path = c.documentPath, imageExtensions.contains((path as NSString).pathExtension.lowercased()) { return .image }
        let roles = Set(c.roles)
        let texty = roles.contains("AXStaticText") || roles.contains("AXTextArea") || roles.contains("AXTextField")
        if roles.contains("AXImage") && !texty { return .image }
        if imageBundles.contains(bundle) && !c.canReplaceText { return .image }
        if c.canReplaceText || c.canSetField { return .editableText }
        if c.url != nil { return .webPage }
        if texty { return .readOnlyText }
        return .interface
    }
}

/// The current selection in a spreadsheet app, read through AppleScript.
public struct SheetSelection: Sendable, Equatable {
    public enum App: String, Sendable { case numbers, excel }
    public var app: App
    /// "B2:D9" style address of the selection.
    public var address: String
    public var values: [[String]]

    public init(app: App, address: String, values: [[String]]) {
        self.app = app
        self.address = address
        self.values = values
    }
}

/// One action the model proposed, parsed from a built-in tool call.
public enum Proposal: Sendable, Equatable {
    case text(text: String, summary: String)
    case image(instruction: String, summary: String)
    case cells(start: String?, rows: [[String]], summary: String)
    case script(source: String, summary: String)
    /// A short clip from a video model, optionally starting from the boxed picture.
    case video(prompt: String, fromBox: Bool, seconds: Int?, aspect: String?, summary: String)
    /// Music, a sound effect or speech. For speech the prompt is the exact words.
    case sound(prompt: String, type: SoundType, summary: String)

    public var summary: String {
        switch self {
        case .text(_, let s), .image(_, let s), .cells(_, _, let s), .script(_, let s),
             .video(_, _, _, _, let s), .sound(_, _, let s): return s
        }
    }
}

/// Llasso's own tools, the ones that are not an app's MCP server.
public enum BuiltinTool: String, CaseIterable, Sendable {
    case askUser = "ask_user"
    case pointAt = "point_at"
    case proposeText = "propose_text"
    case editImage = "edit_image"
    case setCells = "set_cells"
    case runScript = "run_applescript"
    case editCode = "edit_code"
    case makeVideo = "make_video"
    case makeSound = "make_sound"

    public static func named(_ name: String) -> BuiltinTool? { BuiltinTool(rawValue: name) }

    /// The tools on offer for this box. Every one leaves the change to the user's tap.
    public static func available(for kind: ContentKind, hasSource: Bool = false) -> [BuiltinTool] {
        var tools: [BuiltinTool] = [.askUser, .pointAt, .proposeText, .editImage, .makeVideo, .makeSound, .runScript]
        if kind == .spreadsheet { tools.append(.setCells) }
        if hasSource { tools.append(.editCode) }
        return tools
    }

    public var schema: [String: Any] {
        func fn(_ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function",
             "function": ["name": rawValue, "description": description,
                          "parameters": ["type": "object", "properties": properties, "required": required]]]
        }
        let summary: [String: Any] = ["type": "string", "description": "One short line for the card saying what this does, in the user's terms."]
        switch self {
        case .askUser:
            return fn("Ask the user one short question when you cannot tell what they want or where the result should go. Offer two to four answers.",
                      ["question": ["type": "string"],
                       "options": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 4]],
                      ["question", "options"])
        case .pointAt:
            return fn("Show the user where something is by ringing a point inside the boxed image. Use it to guide them through an app.",
                      ["x": ["type": "number", "description": "0 to 1, left to right across the boxed image"],
                       "y": ["type": "number", "description": "0 to 1, top to bottom down the boxed image"],
                       "label": ["type": "string", "description": "A few words shown beside the ring"]],
                      ["x", "y", "label"])
        case .proposeText:
            return fn("Propose new or rewritten text. Llasso shows it and lets the user put it back in place, copy it, or open it in a new document. Give the complete replacement text, not a diff.",
                      ["text": ["type": "string"], "summary": summary], ["text", "summary"])
        case .editImage:
            return fn("Make an image with an image model, starting from what is in the box: edit the boxed image, or create a new image, illustration, drawing or variation of what the box shows. Write the full instruction for the image model, including style. Llasso shows the image on the card and lets the user save it, copy it or replace the source image.",
                      ["instruction": ["type": "string"], "summary": summary], ["instruction", "summary"])
        case .makeVideo:
            return fn("Make a short video clip with a video model: an animation, a moving version of the boxed picture, or a clip from a description. Write the full shot description: subject, motion, camera and style. Llasso plays it on the card and lets the user save it. It takes from half a minute to a few minutes.",
                      ["prompt": ["type": "string"],
                       "from_box": ["type": "boolean", "description": "Start the clip from the boxed picture as its first frame."],
                       "seconds": ["type": "integer", "description": "Length in seconds; 5 when unsure."],
                       "aspect_ratio": ["type": "string", "description": "16:9, 9:16 or 1:1. Omit to match the box."],
                       "summary": summary],
                      ["prompt", "summary"])
        case .makeSound:
            return fn("Make audio: music, a jingle or a sound effect from a description, or speech that reads out exact words. Llasso plays it on the card and lets the user save it.",
                      ["type": ["type": "string", "enum": ["music", "speech"], "description": "music covers songs, jingles and sound effects"],
                       "prompt": ["type": "string", "description": "For music, the full description. For speech, exactly the words to say."],
                       "summary": summary],
                      ["type", "prompt", "summary"])
        case .setCells:
            return fn("Write values or formulas into the spreadsheet. Rows are lists of cell strings; a string starting with = is a formula. The user confirms before anything is written.",
                      ["start": ["type": "string", "description": "Top-left cell, e.g. D2. Omit to use the top-left of the selection."],
                       "rows": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]],
                       "summary": summary],
                      ["rows", "summary"])
        case .editCode:
            return fn("Change the source code behind the box. A coding agent edits the project's files; the user sees the diff and can undo it. Say exactly what should look or behave differently, naming the visible text, element and values.",
                      ["instruction": ["type": "string"], "summary": summary], ["instruction", "summary"])
        case .runScript:
            return fn("Run an AppleScript that acts in a scriptable Mac app (Finder, Mail, Notes, Keynote, Music and others). The user reads the summary and confirms first. Use only when no other tool fits.",
                      ["script": ["type": "string"], "summary": summary], ["script", "summary"])
        }
    }

    /// Parse a proposal from this tool's arguments; nil for tools that are not proposals.
    public func proposal(_ a: [String: Any]) -> Proposal? {
        let summary = (a["summary"] as? String) ?? ""
        switch self {
        case .proposeText:
            guard let t = a["text"] as? String else { return nil }
            return .text(text: t, summary: summary)
        case .editImage:
            guard let i = a["instruction"] as? String else { return nil }
            return .image(instruction: i, summary: summary)
        case .setCells:
            guard let rows = a["rows"] as? [[Any]] else { return nil }
            return .cells(start: a["start"] as? String,
                          rows: rows.map { $0.map { "\($0)" } }, summary: summary)
        case .runScript:
            guard let s = a["script"] as? String else { return nil }
            return .script(source: s, summary: summary)
        case .makeVideo:
            guard let p = a["prompt"] as? String else { return nil }
            let seconds = (a["seconds"] as? Int) ?? (a["seconds"] as? Double).map { Int($0) }
            return .video(prompt: p, fromBox: a["from_box"] as? Bool ?? false, seconds: seconds,
                          aspect: a["aspect_ratio"] as? String, summary: summary)
        case .makeSound:
            guard let p = a["prompt"] as? String else { return nil }
            return .sound(prompt: p, type: (a["type"] as? String) == "speech" ? .speech : .music, summary: summary)
        case .askUser, .pointAt, .editCode:
            return nil
        }
    }
}

/// MCP tool names go to the model as "<server>__<tool>", which must match ^[A-Za-z0-9_-]{1,64}$.
public enum ToolName {
    public static func clean(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    public static func qualified(server: String, tool: String) -> String {
        String((clean(server) + "__" + clean(tool)).prefix(64))
    }

    /// Split "<server>__<tool>" back apart.
    public static func split(_ name: String) -> (server: String, tool: String)? {
        guard let r = name.range(of: "__") else { return nil }
        return (String(name[..<r.lowerBound]), String(name[r.upperBound...]))
    }
}

/// Spreadsheet cell addresses: "B2" to (column 2, row 2) and back.
public enum CellRef {
    public static func parse(_ ref: String) -> (col: Int, row: Int)? {
        let s = ref.uppercased().replacingOccurrences(of: "$", with: "")
        let letters = s.prefix { $0.isLetter }
        let digits = s.dropFirst(letters.count)
        guard !letters.isEmpty, let row = Int(digits), row > 0 else { return nil }
        let col = letters.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) }
        return (col, row)
    }

    public static func name(col: Int, row: Int) -> String {
        var n = col, letters = ""
        while n > 0 {
            let r = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + r))) + letters
            n = (n - 1) / 26
        }
        return letters + String(row)
    }

    /// The top-left cell of an address such as "B2:D9".
    public static func topLeft(of address: String) -> String {
        String(address.split(separator: ":").first ?? Substring(address))
    }
}
