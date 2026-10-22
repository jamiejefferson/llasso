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

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(Int32(failures))
