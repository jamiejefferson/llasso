import Foundation

/// One part of a chat message: text, or a PNG sent inline as a data URL.
public enum ChatPart: Sendable {
    case text(String)
    case png(Data)
}

/// A tool call the model asked for. `arguments` is the raw JSON string it wrote.
public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// The arguments parsed as a JSON object; empty when the model wrote none or bad JSON.
    public var args: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

public struct ChatMessage: Sendable {
    public var role: String
    public var parts: [ChatPart]
    /// Set on an assistant message that asked for tools.
    public var toolCalls: [ToolCall] = []
    /// Set on a "tool" message: which call it answers.
    public var toolCallID: String?

    public init(role: String, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", parts: [.text(text)]) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", parts: [.text(text)]) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", parts: [.text(text)]) }

    public static func assistant(_ text: String, calls: [ToolCall]) -> ChatMessage {
        var m = ChatMessage(role: "assistant", parts: text.isEmpty ? [] : [.text(text)])
        m.toolCalls = calls
        return m
    }

    public static func toolResult(id: String, _ text: String) -> ChatMessage {
        var m = ChatMessage(role: "tool", parts: [.text(text)])
        m.toolCallID = id
        return m
    }

    var json: [String: Any] {
        if role == "tool" {
            let text = parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
            return ["role": "tool", "tool_call_id": toolCallID ?? "", "content": text]
        }
        if !toolCalls.isEmpty {
            var out: [String: Any] = [
                "role": role,
                "tool_calls": toolCalls.map { ["id": $0.id, "type": "function",
                                               "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]] },
            ]
            let text = parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
            out["content"] = text.isEmpty ? NSNull() : text
            return out
        }
        // A text-only message goes as a plain string; providers accept that everywhere.
        if parts.count == 1, case .text(let t) = parts[0] {
            return ["role": role, "content": t]
        }
        let content: [[String: Any]] = parts.map { part in
            switch part {
            case .text(let t):
                return ["type": "text", "text": t]
            case .png(let data):
                return ["type": "image_url",
                        "image_url": ["url": "data:image/png;base64," + data.base64EncodedString()]]
            }
        }
        return ["role": role, "content": content]
    }
}

public enum OpenRouterError: Error, LocalizedError, Equatable {
    case missingKey
    case http(Int, String)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your OpenRouter key in Llasso's settings."
        case .http(let code, let body): return "OpenRouter answered \(code): \(body)"
        case .api(let message): return "OpenRouter: \(message)"
        }
    }
}

/// What one line of OpenRouter's server-sent event stream carries.
public enum StreamEvent: Equatable {
    case delta(String)
    /// A fragment of a tool call: the index it belongs to, and whichever of id, name and
    /// argument text this chunk carries.
    case toolDelta(index: Int, id: String?, name: String?, arguments: String)
    case done
    case failure(String)
    case ignore
}

/// Joins streamed tool-call fragments into whole calls.
public struct ToolCallAccumulator {
    private var calls: [Int: ToolCall] = [:]

    public init() {}

    public mutating func add(index: Int, id: String?, name: String?, arguments: String) {
        var c = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
        if let id, !id.isEmpty { c.id = id }
        if let name, !name.isEmpty { c.name += name }
        c.arguments += arguments
        calls[index] = c
    }

    public var result: [ToolCall] {
        calls.sorted { $0.key < $1.key }.map { i, c in
            var c = c
            if c.id.isEmpty { c.id = "call_\(i)" }
            return c
        }.filter { !$0.name.isEmpty }
    }
}

/// What a chat stream yields to the app.
public enum ChatChunk: Sendable {
    case text(String)
    case tools([ToolCall])
}

public enum SSE {
    /// Parse one line of a chat-completions stream. Comment lines (": OPENROUTER
    /// PROCESSING") and blank keep-alives are ignored.
    public static func parse(line: String) -> StreamEvent {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignore }
        if let err = obj["error"] as? [String: Any] {
            return .failure(err["message"] as? String ?? "unknown error")
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any]
        else { return .ignore }
        if let calls = delta["tool_calls"] as? [[String: Any]], let call = calls.first {
            let fn = call["function"] as? [String: Any]
            return .toolDelta(index: call["index"] as? Int ?? 0, id: call["id"] as? String,
                              name: fn?["name"] as? String, arguments: fn?["arguments"] as? String ?? "")
        }
        guard let content = delta["content"] as? String, !content.isEmpty else { return .ignore }
        return .delta(content)
    }

    /// A chunk can carry several tool-call fragments; `parse` returns the first, this returns all.
    public static func parseAll(line: String) -> [StreamEvent] {
        let first = parse(line: line)
        guard case .toolDelta = first,
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delta = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [[String: Any]], calls.count > 1
        else { return [first] }
        return calls.map { call in
            let fn = call["function"] as? [String: Any]
            return .toolDelta(index: call["index"] as? Int ?? 0, id: call["id"] as? String,
                              name: fn?["name"] as? String, arguments: fn?["arguments"] as? String ?? "")
        }
    }
}

/// The only network client Llasso has: chat, and speech, through one OpenRouter key.
public struct OpenRouterClient: Sendable {
    public var apiKey: String
    public var baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    func request(path: String, body: [String: Any]) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingKey }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OpenRouter's app attribution headers.
        req.setValue("https://github.com/jamiejefferson/llasso", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Llasso", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        return req
    }

    public func chatRequest(model: String, messages: [ChatMessage], stream: Bool,
                            tools: [[String: Any]] = []) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": messages.map(\.json),
        ]
        if !tools.isEmpty { body["tools"] = tools }
        return try request(path: "chat/completions", body: body)
    }

    /// Stream an answer that may end in tool calls: text pieces as they arrive, then
    /// one `.tools` chunk if the model asked for any.
    public func streamTurn(model: String, messages: [ChatMessage], tools: [[String: Any]]) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try chatRequest(model: model, messages: messages, stream: true, tools: tools)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw OpenRouterError.http(http.statusCode, Self.message(fromErrorBody: body))
                    }
                    var acc = ToolCallAccumulator()
                    lines: for try await line in bytes.lines {
                        for event in SSE.parseAll(line: line) {
                            switch event {
                            case .delta(let text): continuation.yield(.text(text))
                            case .toolDelta(let i, let id, let name, let args): acc.add(index: i, id: id, name: name, arguments: args)
                            case .done: break lines
                            case .failure(let message): throw OpenRouterError.api(message)
                            case .ignore: continue
                            }
                        }
                    }
                    let calls = acc.result
                    if !calls.isEmpty { continuation.yield(.tools(calls)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Edit or make an image with an image model through chat completions. Returns the
    /// first image the model sends back, as encoded bytes (usually PNG).
    public func image(model: String, prompt: String, source: Data?) async throws -> Data {
        var parts: [ChatPart] = []
        if let source { parts.append(.png(source)) }
        parts.append(.text(prompt))
        var req = try request(path: "chat/completions", body: [
            "model": model,
            "modalities": ["image", "text"],
            "messages": [ChatMessage(role: "user", parts: parts).json],
        ])
        req.timeoutInterval = 180
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenRouterError.http(http.statusCode, Self.message(fromErrorBody: String(decoding: data, as: UTF8.self)))
        }
        guard let image = Self.firstImage(inResponse: data) else {
            throw OpenRouterError.api("the image model sent no image back")
        }
        return image
    }

    /// Pull the first data-URL image out of a chat-completions response.
    public static func firstImage(inResponse data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let images = message["images"] as? [[String: Any]],
              let url = (images.first?["image_url"] as? [String: Any])?["url"] as? String,
              let comma = url.firstIndex(of: ",")
        else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    /// Stream the answer's text as it arrives.
    public func streamChat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try chatRequest(model: model, messages: messages, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw OpenRouterError.http(http.statusCode, Self.message(fromErrorBody: body))
                    }
                    for try await line in bytes.lines {
                        switch SSE.parse(line: line) {
                        case .delta(let text): continuation.yield(text)
                        case .done: continuation.finish(); return
                        case .failure(let message): throw OpenRouterError.api(message)
                        case .ignore, .toolDelta: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Text to speech through /audio/speech. Returns audio bytes (mp3).
    public func speech(model: String, voice: String, text: String) async throws -> Data {
        let req = try request(path: "audio/speech", body: [
            "model": model,
            "voice": voice,
            "input": text,
            "response_format": "mp3",
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenRouterError.http(http.statusCode,
                                       Self.message(fromErrorBody: String(decoding: data, as: UTF8.self)))
        }
        return data
    }

    static func message(fromErrorBody body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            return message
        }
        return String(body.prefix(300))
    }
}
