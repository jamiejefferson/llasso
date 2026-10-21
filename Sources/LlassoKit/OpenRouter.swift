import Foundation

/// One part of a chat message: text, or a PNG sent inline as a data URL.
public enum ChatPart: Sendable {
    case text(String)
    case png(Data)
}

public struct ChatMessage: Sendable {
    public var role: String
    public var parts: [ChatPart]

    public init(role: String, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", parts: [.text(text)]) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", parts: [.text(text)]) }

    var json: [String: Any] {
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
    case done
    case failure(String)
    case ignore
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
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty
        else { return .ignore }
        return .delta(content)
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

    public func chatRequest(model: String, messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        try request(path: "chat/completions", body: [
            "model": model,
            "stream": stream,
            "messages": messages.map(\.json),
        ])
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
                        case .ignore: continue
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
