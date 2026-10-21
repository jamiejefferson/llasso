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
} else {
    print("SKIP live call (no OPENROUTER_API_KEY)")
}

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(Int32(failures))
