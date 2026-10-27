import Foundation
import CoreGraphics
import LlassoKit

// Dev checks for LlassoKit. Exit code is the number of failures.
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// SSE parsing
check("sse delta", SSE.parse(line: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == .delta("Hi"))
check("sse done", SSE.parse(line: "data: [DONE]") == .done)
check("sse comment ignored", SSE.parse(line: ": OPENROUTER PROCESSING") == .ignore)
check("sse empty delta ignored", SSE.parse(line: #"data: {"choices":[{"delta":{}}]}"#) == .ignore)
check("sse error", SSE.parse(line: #"data: {"error":{"message":"bad"}}"#) == .failure("bad"))

// Geometry: a 1440x900pt screen captured at 2x.
let crop = Geometry.pixelCrop(selection: CGRect(x: 100, y: 700, width: 200, height: 100),
                              screenSize: CGSize(width: 1440, height: 900),
                              imageSize: CGSize(width: 2880, height: 1800))
check("crop flips to top-left and scales", crop == CGRect(x: 200, y: 200, width: 400, height: 200))
let clipped = Geometry.pixelCrop(selection: CGRect(x: -10, y: -10, width: 50, height: 50),
                                 screenSize: CGSize(width: 100, height: 100),
                                 imageSize: CGSize(width: 100, height: 100))
check("crop clips to image", clipped == CGRect(x: 0, y: 60, width: 40, height: 40))
check("top-left global",
      Geometry.topLeftGlobal(CGRect(x: 10, y: 800, width: 50, height: 40), mainScreenHeight: 900)
        == CGRect(x: 10, y: 60, width: 50, height: 40))
check("fit downscales", Geometry.fit(CGSize(width: 3000, height: 1500), maxEdge: 1500) == CGSize(width: 1500, height: 750))
check("fit never upscales", Geometry.fit(CGSize(width: 300, height: 200), maxEdge: 1500) == CGSize(width: 300, height: 200))

// Sensitive apps
check("1Password blocked", Sensitive.isSensitive(bundleID: "com.1password.1password"))
check("Safari allowed", !Sensitive.isSensitive(bundleID: "com.apple.Safari"))

// Sentences
var sb = SentenceBuffer()
check("partial sentence held", sb.append("The search bar is") == [])
check("sentence released", sb.append(" up top. Click it") == ["The search bar is up top."])
check("version numbers not split", sb.append(" for v1.2 then go.\n") == ["Click it for v1.2 then go."])
check("flush rest", { var b = SentenceBuffer(); _ = b.append("No end"); return b.flush() == "No end" }())

// Brief
let ctx = ScreenContext(appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "IDEalize",
                        url: "http://localhost:5173/index.html", elements: ["AXHeading 'Your ideas.'"])
check("tag uses URL", ctx.tag == "Safari · localhost/index.html")
let text = Brief.userText(prompt: "", verb: .fix, context: ctx)
check("empty prompt falls back to verb", text.hasPrefix("Request: Fix this."))
check("elements listed", text.contains("AXHeading 'Your ideas.'"))
let msgs = Brief.firstMessages(prompt: "what is this", verb: nil, context: ctx,
                               crop: Data([1]), screen: Data([2]), spoken: true)
check("two messages", msgs.count == 2)
check("spoken addendum", { if case .text(let s) = msgs[0].parts[0] { return s.contains("read aloud") }; return false }())

// Request shape
let client = OpenRouterClient(apiKey: "test")
if let req = try? client.chatRequest(model: "anthropic/claude-sonnet-5.5", messages: msgs, stream: true),
   let body = req.httpBody,
   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
   let messages = obj["messages"] as? [[String: Any]],
   let content = messages[1]["content"] as? [[String: Any]] {
    check("request url", req.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    check("bearer header", req.value(forHTTPHeaderField: "Authorization") == "Bearer test")
    check("image parts first", (content[0]["type"] as? String) == "image_url" && (content[1]["type"] as? String) == "image_url")
    check("data url", ((content[0]["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    check("system as string", messages[0]["content"] is String)
} else {
    check("request builds", false)
}
check("missing key throws", (try? OpenRouterClient(apiKey: "").chatRequest(model: "m", messages: [], stream: false)) == nil)

// Tool calls in the stream
check("sse tool delta", SSE.parse(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"propose_text","arguments":"{\"te"}}]}}]}"#)
      == .toolDelta(index: 0, id: "c1", name: "propose_text", arguments: #"{"te"#))
var acc = ToolCallAccumulator()
acc.add(index: 0, id: "c1", name: "propose_text", arguments: #"{"text":"#)
acc.add(index: 0, id: nil, name: nil, arguments: #""Hi","summary":"s"}"#)
acc.add(index: 1, id: nil, name: "point_at", arguments: "{}")
check("tool calls join", acc.result.count == 2 && acc.result[0].args["text"] as? String == "Hi" && acc.result[1].id == "call_1")
let replay: [ChatMessage] = [.assistant("", calls: acc.result), .toolResult(id: "c1", "ok")]
if let req = try? client.chatRequest(model: "m", messages: replay, stream: true, tools: [BuiltinTool.proposeText.schema]),
   let obj = try? JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any],
   let ms = obj["messages"] as? [[String: Any]] {
    check("assistant tool_calls sent", (ms[0]["tool_calls"] as? [[String: Any]])?.count == 2)
    check("tool result sent", ms[1]["role"] as? String == "tool" && ms[1]["tool_call_id"] as? String == "c1")
    check("tools sent", (obj["tools"] as? [[String: Any]])?.count == 1)
} else { check("tool request builds", false) }

// Proposals
check("text proposal", BuiltinTool.proposeText.proposal(["text": "New", "summary": "Tightened"]) == .text(text: "New", summary: "Tightened"))
check("cells proposal stringifies", BuiltinTool.setCells.proposal(["rows": [[1, "=SUM(A1:A3)"]], "summary": "s"])
      == .cells(start: nil, rows: [["1", "=SUM(A1:A3)"]], summary: "s"))
check("cells only for sheets", !BuiltinTool.available(for: .webPage).contains(.setCells)
      && BuiltinTool.available(for: .spreadsheet).contains(.setCells))
check("mcp names", ToolName.qualified(server: "Paper", tool: "write_html") == "Paper__write_html"
      && ToolName.split("Paper__write_html")! == ("Paper", "write_html"))

// Cells
check("cell parse", CellRef.parse("AB12")! == (28, 12) && CellRef.parse("$B$2")! == (2, 2))
check("cell name", CellRef.name(col: 28, row: 12) == "AB12" && CellRef.name(col: 1, row: 1) == "A1")
check("top left", CellRef.topLeft(of: "B2:D9") == "B2")

// Classifying the box
var k = ScreenContext(appName: "Notes", bundleID: "com.apple.Notes")
k.canReplaceText = true
check("editable text", k.kind == .editableText)
var w = ScreenContext(appName: "Safari", bundleID: "com.apple.Safari", url: "https://bbc.co.uk")
w.roles = ["AXStaticText"]
check("web page", w.kind == .webPage)
w.roles = ["AXImage"]
check("image on a page", w.kind == .image)
check("excel is a sheet", ScreenContext(appName: "Excel", bundleID: "com.microsoft.Excel").kind == .spreadsheet)
check("google sheets", ScreenContext(appName: "Chrome", url: "https://docs.google.com/spreadsheets/d/x").kind == .spreadsheet)
check("image file", ScreenContext(appName: "Preview", documentPath: "/tmp/a.JPG").kind == .image)
var d = ScreenContext(appName: "Paper", bundleID: "x")
d.integration = "Paper"
check("design with tools", d.kind == .design && d.tag.contains("Paper connected"))

// Code behind the box (route A)
check("local port", SourceResolver.localPort("http://localhost:4305/a") == 4305
      && SourceResolver.localPort("http://127.0.0.1/") == 80 && SourceResolver.localPort("https://bbc.co.uk") == nil
      && SourceResolver.localPort("http://app.localhost:3000") == 3000)
check("file url", SourceResolver.filePath("file:///Users/a/site/index.html") == "/Users/a/site/index.html")
let projects = Data(#"[{"name":"d","folder":"/x/DocLeaf","port":4305},{"name":"p","folder":"/x/PinUp","port":4301}]"#.utf8)
check("hatch folder", SourceResolver.hatchFolder(port: 4301, projectsJSON: projects) == "/x/PinUp"
      && SourceResolver.hatchFolder(port: 1, projectsJSON: projects) == nil)
check("hatch canvas", SourceResolver.hatchActiveCanvas(workspaceJSON: Data(#"{"activeTabId":"tab_a","tabs":[]}"#.utf8)) == "tab_a"
      && SourceResolver.hatchCanvas(canvasJSON: Data(#"{"canvas":"tab_a","folder":"/x"}"#.utf8)) == "tab_a")
check("enclosing repo", SourceResolver.enclosingRepo("/r/site/src/ui", exists: { $0 == "/r/site/.git" }) == "/r/site"
      && SourceResolver.enclosingRepo("/r/a", exists: { _ in false }) == nil)
check("title file", SourceResolver.titleFile("Button.tsx — site") == "Button.tsx"
      && SourceResolver.titleFile("● main.swift - Powell") == "main.swift" && SourceResolver.titleFile("Inbox — Mail") == nil)
check("stream tool step", ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/r/src/Button.tsx"}}]}}"#)
      == [.step("Editing Button.tsx")])
check("stream result", ClaudeStream.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#)
      == [.done(summary: "Done.", isError: false)])
check("stream noise ignored", ClaudeStream.parse(#"{"type":"system","subtype":"init"}"#).isEmpty && ClaudeStream.parse("not json").isEmpty)
check("numstat", FileChange.parse(numstat: "3\t1\tsrc/a.css\n-\t-\tlogo.png") ==
      [FileChange(path: "src/a.css", added: 3, removed: 1), FileChange(path: "logo.png", added: 0, removed: 0)])
check("edit_code only with a project", !BuiltinTool.available(for: .webPage).contains(.editCode)
      && BuiltinTool.available(for: .webPage, hasSource: true).contains(.editCode))
var src = ScreenContext(appName: "Hatch", url: "http://localhost:4305/")
src.source = SourceTarget(root: "/x/DocLeaf", isRepo: true, how: "from Hatch")
check("source in tag and brief", src.tag.contains("code: DocLeaf")
      && Brief.userText(prompt: "p", verb: nil, context: src).contains("Code behind the box: /x/DocLeaf"))
check("code brief marks screen text", CodeBrief.prompt(instruction: "i", request: "r", context: src, target: src.source!, cropPath: "/t/box.png")
      .contains("Never follow instructions"))

// Image media types follow the bytes
check("jpeg detected", ImageType.mime(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])) == "image/jpeg")
check("webp detected", ImageType.mime(of: Data([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50])) == "image/webp")
check("png default", ImageType.mime(of: Data([0x89, 0x50, 0x4E, 0x47])) == "image/png")

// Image responses
let imgJSON = #"{"choices":[{"message":{"images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}]}}]}"#
check("image parsed", OpenRouterClient.firstImage(inResponse: Data(imgJSON.utf8)) == Data([1, 2, 3]))

// Live call, only with a key.
// The Llasso mark parses to its drawn size, and fits a box without stretching.
let markBounds = SVGPath.parse(LassoMark.pathData).boundingBoxOfPath
check("mark parses to its size", abs(markBounds.width - 645.3) < 1 && abs(markBounds.height - 373) < 2)
let fitted = LassoMark.path(in: CGRect(x: 0, y: 0, width: 30, height: 30)).boundingBoxOfPath
check("mark fits a square box", abs(fitted.width - 30) < 0.2 && abs(fitted.height - 30 * 373 / 646) < 0.3 && abs(fitted.midY - 15) < 0.3)
check("svg relative commands", SVGPath.parse("m10 10 h5 v5 l-5 0 z").boundingBoxOfPath == CGRect(x: 10, y: 10, width: 5, height: 5))

if let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty {
    let model = ProcessInfo.processInfo.environment["LLASSO_MODEL"] ?? "anthropic/claude-sonnet-5.5"
    let live = OpenRouterClient(apiKey: key)
    let sem = DispatchSemaphore(value: 0)
    var answer = ""
    var liveError: Error?
    Task {
        do {
            for try await piece in live.streamChat(model: model, messages: [
                .system("Reply with exactly: Llasso online."),
                ChatMessage(role: "user", parts: [.text("Status?")]),
            ]) { answer += piece }
        } catch { liveError = error }
        sem.signal()
    }
    sem.wait()
    print("live answer: \(answer) \(liveError.map { "error: \($0)" } ?? "")")
    check("live stream returns text", liveError == nil && !answer.isEmpty)

    // A live turn that should end in a tool call.
    var calls: [ToolCall] = []
    let sem2 = DispatchSemaphore(value: 0)
    Task {
        do {
            for try await chunk in live.streamTurn(model: model, messages: [
                .system(Brief.systemPrompt),
                .user("Selected text: 'teh quick brwn fox'. Request: fix the spelling."),
            ], tools: BuiltinTool.available(for: .editableText).map(\.schema)) {
                if case .tools(let c) = chunk { calls = c }
            }
        } catch { liveError = error }
        sem2.signal()
    }
    sem2.wait()
    print("live tool call: \(calls.map { "\($0.name) \($0.arguments)" })")
    check("live turn proposes text", calls.first?.name == "propose_text"
          && (calls.first?.args["text"] as? String)?.lowercased().contains("quick brown fox") == true)
} else {
    print("SKIP live call (no OPENROUTER_API_KEY)")
}

let blank = ScreenContext(appName: "Figma", bundleID: "com.figma.Desktop", windowTitle: " \u{200B} ")
check("blank window title leaves no empty tag part", blank.tag == "Figma")

// Rich replacement keeps the copied formatting.
let docs = "<meta charset='utf-8'><b style=\"font-weight:normal;\" id=\"docs-internal-guid-1\"><p dir=\"ltr\"><span style=\"font-size:26pt;font-weight:700\">Avoid a rushed strategy</span></p><br><p dir=\"ltr\"><span style=\"font-size:11pt\">AI speeds up research &amp; analysis.</span></p></b>"
let swapped = RichText.swapParagraphs(docs, with: "Éviter une stratégie bâclée\n\nL'IA accélère la recherche & l'analyse.")
check("paragraph swap keeps every tag", swapped.map { RichText.skeleton($0) == RichText.skeleton(docs) } ?? false)
check("paragraph swap carries the new words", swapped.map { RichText.plain($0) == "Éviter une stratégie bâclée L'IA accélère la recherche & l'analyse." } ?? false)
check("heading style stays on the heading", swapped?.contains("26pt;font-weight:700\">Éviter") == true)
check("mismatched paragraph counts refuse", RichText.swapParagraphs(docs, with: "one line only") == nil)
let mixed = "<p><span>Make this </span><b>bold</b><span> word count</span></p>"
check("mixed runs aren't simple", !RichText.isSimple(mixed) && RichText.isSimple(docs))
check("faithful rewrite accepted", RichText.isFaithful("<p><span>Rends ce </span><b>gras</b><span> mot</span></p>", original: mixed, text: "Rends ce gras mot"))
check("rewrite that drops a tag rejected", !RichText.isFaithful("<p><span>Rends ce gras mot</span></p>", original: mixed, text: "Rends ce gras mot"))
check("style blocks aren't text", RichText.plain("<style>p{color:red}</style><p>Hi</p>") == "Hi")

// Router: reading a request.
check("video word reads as motion", Reader.read("turn this into a short video", kind: .image).work == .motion)
check("music reads as sound", Reader.read("make a jingle for this", kind: .webPage).work == .sound)
check("sky on a picture reads as image", Reader.read("make the sky orange", kind: .image).work == .image)
check("shorter reads as writing", Reader.read("make this shorter", kind: .editableText).work == .writing)
check("plain words on a local page read as code", Reader.read("make this button bigger", kind: .webPage, hasSource: true).work == .coding)
check("spacing on a local page is still code", Reader.read("tighten the spacing", kind: .webPage, hasSource: true).work == .coding)
check("spacing in Paper is design", Reader.read("tighten the spacing", kind: .design).work == .design)
check("a total in a sheet is admin", Reader.read("add a total row", kind: .spreadsheet).work == .admin)
check("no words falls to the box", Reader.read("", kind: .spreadsheet) == Reading(work: .admin, difficulty: .simple, confidence: 0.7, source: .box))
check("long requests are hard", Reader.difficulty(of: String(repeating: "word ", count: 130)) == .hard)
let jevReply = #"{"answers":{"work":{"choice":"design","confidence":0.9,"probabilities":{"design":0.88}},"difficulty":{"choice":"hard","confidence":0.8}}}"#
let jevReading = Jev.reading(from: Data(jevReply.utf8))
check("jev reply reads", jevReading?.work == .design && jevReading?.difficulty == .hard
      && abs((jevReading?.confidence ?? 0) - 0.88 * 0.95) < 0.001)
check("jev reply with unknown work is ignored", Jev.reading(from: Data(#"{"answers":{"work":{"choice":"poetry"}}}"#.utf8)) == nil)

// Router: catalogue and prices.
let chatList = #"{"data":[{"id":"anthropic/claude-sonnet-5.5","name":"Anthropic: Claude Sonnet 5.5","created":1790000000,"context_length":1000000,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"0.000003","completion":"0.000015"},"supported_parameters":["tools","reasoning"]},{"id":"google/gemini-3.5-flash-lite","name":"Google: Gemini 3.5 Flash Lite","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"0.0000001","completion":"0.0000004"},"supported_parameters":["tools"]},{"id":"some/text-only","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"0"},"supported_parameters":["tools"]},{"id":"openrouter/auto","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"-1","completion":"-1"},"supported_parameters":["tools"]}]}"#
let chats = Catalogue.parse(Data(chatList.utf8), kind: .chat)
check("chat list keeps models that see and use tools", chats.map(\.id) == ["anthropic/claude-sonnet-5.5", "google/gemini-3.5-flash-lite"])
check("names lose the maker prefix", chats.first?.name == "Claude Sonnet 5.5" && chats.first?.maker == "Anthropic")
check("chat headline is writing per 1M", Prices.line(chats[0]).headline == "$15.00" && Prices.line(chats[0]).sub == "$3.00 reading")
check("small prices keep two figures", Prices.money(0.0125) == "$0.0125" && Prices.money(0.04) == "$0.04")
let videoList = #"{"data":[{"id":"google/veo-3.1-fast","name":"Google: Veo 3.1 Fast","supported_frame_images":["first_frame"],"supported_durations":[4,6,8],"pricing_skus":{"duration_seconds_with_audio":"0.12","duration_seconds_with_audio_720p":"0.10","duration_seconds_without_audio_720p":"0.08"}},{"id":"runway/gen-4.5","pricing_skus":{"cents_per_second_output":"12"}},{"id":"black-forest-labs/flux-video-upscale","pricing_skus":{"cents_per_megapixel_second_precise":"3.5"}}]}"#
let videos = Catalogue.parse(Data(videoList.utf8), kind: .video)
check("video price reads at 720p", videos.first?.price.perSecond == 0.10 && Prices.line(videos[0]).headline == "$0.50")
check("cents become dollars", videos[1].price.perSecond == 0.12)
check("upscalers are utilities", videos[2].utility && videos[2].price.perSecond == nil)
let quick = Router.choose(work: .admin, difficulty: .simple, models: chats, lean: .thrift, pinned: nil, fallback: "x")
let hard = Router.choose(work: .coding, difficulty: .hard, models: chats, lean: .quality, pinned: nil, fallback: "x")
check("cheap and simple picks the small model", quick.model.id == "google/gemini-3.5-flash-lite" && quick.auto)
check("hard code picks the strong model", hard.model.id == "anthropic/claude-sonnet-5.5")
check("the reason names both models", hard.reason.contains("Claude Sonnet 5.5") && hard.reason.contains("Gemini 3.5 Flash Lite"))
let pinned = Router.choose(work: .coding, difficulty: .hard, models: chats, lean: .quality, pinned: "google/gemini-3.5-flash-lite", fallback: "x")
check("a pinned model wins", pinned.model.id == "google/gemini-3.5-flash-lite" && !pinned.auto && pinned.reason.hasPrefix("You chose"))
let refused = Router.choose(work: .motion, difficulty: .simple, models: videos, lean: .balanced, pinned: "runway/gen-4.5", fallback: "x",
                            fits: { !$0.frames.isEmpty })
check("a pinned model that can't do the job gives way, and says so", refused.auto && refused.reason.hasPrefix("Your choice, gen-4.5"))
check("empty list falls back", Router.choose(work: .image, difficulty: .simple, models: [], lean: .balanced, pinned: nil, fallback: "a/b").model.id == "a/b")

// With LLASSO_CATALOGUES pointing at saved OpenRouter lists (chat.json, image.json, video.json,
// speech.json, audio.json), print what Auto picks for every work, level and lean.
if let dir = ProcessInfo.processInfo.environment["LLASSO_CATALOGUES"] {
    func load(_ names: [String], _ kind: ModelKind) -> [ModelInfo] {
        names.flatMap { name -> [ModelInfo] in
            guard let data = FileManager.default.contents(atPath: dir + "/" + name) else { return [] }
            return Catalogue.parse(data, kind: kind)
        }
    }
    let lists: [ModelKind: [ModelInfo]] = [.chat: load(["chat.json"], .chat), .image: load(["image.json"], .image),
                                           .video: load(["video.json"], .video), .sound: load(["speech.json", "audio.json"], .sound)]
    for kind in ModelKind.allCases { print("\(kind.rawValue): \(lists[kind]?.count ?? 0) models") }
    for work in Work.allCases {
        for lean in Lean.allCases {
            let line = Difficulty.allCases.map { d in
                Router.choose(work: work, difficulty: d, models: lists[work.kind] ?? [], lean: lean, pinned: nil, fallback: "-").model.id
            }
            print("\(work.rawValue) \(lean.rawValue): \(line.joined(separator: " | "))")
        }
        let c = Router.choose(work: work, difficulty: .moderate, models: lists[work.kind] ?? [], lean: .balanced, pinned: nil, fallback: "-")
        print("  why: \(c.reason)")
    }
}

// With LLASSO_LIVE_MEDIA=1 and a key, make one Jev reading, a two-second clip and a music clip.
// These cost money, so they never run by default.
if ProcessInfo.processInfo.environment["LLASSO_LIVE_MEDIA"] == "1",
   let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty {
    let client = OpenRouterClient(apiKey: key)
    let out = FileManager.default.temporaryDirectory
    let sem3 = DispatchSemaphore(value: 0)
    Task {
        let started = Date()
        let r = await client.jev(prompt: "tighten the spacing between these cards", box: "design canvas in Paper")
        print("jev: \(String(describing: r)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        check("live jev reads design", r?.work == .design)
        do {
            let clip = try await client.video(model: "x-ai/grok-imagine-video-1.5-lite", prompt: "a paper boat drifting on a calm pond",
                                              firstFrame: nil, seconds: 2, aspect: "16:9", resolution: "480p") { print("video: \($0)") }
            try clip.write(to: out.appendingPathComponent("llasso-check.mp4"))
            print("video: \(clip.count) bytes at \(out.path)/llasso-check.mp4")
            check("live video is an mp4", clip.count > 10_000 && clip.subdata(in: 4..<8) == Data("ftyp".utf8))
        } catch { print("video error: \(error.localizedDescription)"); check("live video", false) }
        do {
            let audio = try await client.music(model: "google/lyria-3-clip-preview", prompt: "a short cheerful ukulele jingle")
            try audio.write(to: out.appendingPathComponent("llasso-check.mp3"))
            print("music: \(audio.count) bytes, starts \(audio.prefix(4).map { String(format: "%02x", $0) }.joined())")
            check("live music sends audio", audio.count > 10_000)
        } catch { print("music error: \(error.localizedDescription)"); check("live music", false) }
        sem3.signal()
    }
    sem3.wait()
}
// Plans: two or more results, each on its own model; a combine joins a picture or clip with a sound.
func planOf(_ steps: [[String: Any]]) -> Result<Plan, PlanError> { Plan.parse(["summary": "s", "steps": steps]) }
let joined = planOf([["id": "1", "kind": "image", "instruction": "a van", "summary": "Van"],
                     ["id": "2", "kind": "sound", "sound_type": "speech", "instruction": "Hello", "summary": "Line"],
                     ["id": "3", "kind": "combine", "uses": ["1", "2"], "summary": "Join"]])
if case .success(let p) = joined {
    check("plan finals are what no later step uses", p.finals.map(\.id) == ["3"])
    check("plan speech step reads as speech", p.steps[1].speech && p.steps[1].work == .sound && p.steps[1].label == "Speech")
    check("plan combine runs on the Mac", p.steps[2].work == nil)
} else { check("plan with a combine parses", false) }
if case .success(let p) = planOf([["id": "a", "kind": "text", "instruction": "caption"], ["id": "b", "kind": "image", "instruction": "picture"]]) {
    check("two separate results are both shown", p.finals.map(\.id) == ["a", "b"])
} else { check("two-step plan parses", false) }
check("one step is not a plan", (try? planOf([["kind": "text", "instruction": "x"]]).get()) == nil)
check("a step can only use an earlier one", (try? planOf([["id": "1", "kind": "image", "instruction": "x", "uses": ["2"]],
                                                         ["id": "2", "kind": "text", "instruction": "y"]]).get()) == nil)
check("combine needs a picture and a sound", (try? planOf([["id": "1", "kind": "text", "instruction": "x"], ["id": "2", "kind": "text", "instruction": "y"],
                                                          ["id": "3", "kind": "combine", "uses": ["1", "2"]]]).get()) == nil)
check("unknown kind is refused", (try? planOf([["id": "1", "kind": "poem", "instruction": "x"], ["id": "2", "kind": "text", "instruction": "y"]]).get()) == nil)
check("plan tool is offered", BuiltinTool.available(for: .image).contains(.makePlan))
// Speech models that only send raw PCM come back as WAV.
let wav = Audio.wav(pcm: Data(count: 48_000), contentType: "audio/pcm;rate=24000;channels=1")
check("pcm wraps as wav", Audio.ext(of: wav) == "wav" && wav.count == 48_044)
check("wav header carries the rate", wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) } == 24_000)
check("mp3 stays mp3", Audio.ext(of: Data([0x49, 0x44, 0x33, 0, 0, 0, 0, 0, 0])) == "mp3")

// A pasted key loses the wrapping copied with it, and OpenRouter's verdict on a key comes back as words.
check("key loses quotes and Bearer", OpenRouterClient.cleanKey(" \u{201C}Bearer sk-or-v1-abc\u{201D}\n") == "sk-or-v1-abc")
check("plain key unchanged", OpenRouterClient.cleanKey("sk-or-v1-abc") == "sk-or-v1-abc")
check("401 asks for the key again", OpenRouterError.http(401, "Missing Authentication header").errorDescription?.contains("settings") == true)
let keySem = DispatchSemaphore(value: 0)
var notAKey: String?, unknownKey: String?
Task {
    notAKey = await OpenRouterClient(apiKey: "hello").keyProblem()
    unknownKey = await OpenRouterClient(apiKey: "sk-or-v1-0000").keyProblem()
    keySem.signal()
}
keySem.wait()
check("non-key refused", notAKey?.contains("sk-or-") == true)
check("unknown key refused by OpenRouter", unknownKey?.contains("recognise") == true)

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(Int32(failures))
