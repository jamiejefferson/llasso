import Foundation

/// The router's calls: OpenRouter's model lists, Jev's reading of a request, and the media
/// a request can make besides pictures (video clips, music and speech).
extension OpenRouterClient {
    func get(_ path: String, timeout: TimeInterval = 60) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.setValue("https://github.com/jamiejefferson/llasso", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Llasso", forHTTPHeaderField: "X-Title")
        req.timeoutInterval = timeout
        return req
    }

    static func check(_ data: Data, _ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenRouterError.http(http.statusCode, message(fromErrorBody: String(decoding: data, as: UTF8.self)))
        }
    }

    /// One of OpenRouter's model lists, as it sends it. The lists are public, so this works
    /// before a key is saved.
    public func list(_ path: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: get(path))
        try Self.check(data, response)
        return data
    }

    /// Ask Jev what a request is for. Nil when it can't answer within its time limit.
    public func jev(prompt: String, box: String, categories: [WorkCategory] = WorkCategory.builtIns) async -> Reading? {
        guard !apiKey.isEmpty, var req = try? request(path: "decisions", body: Jev.request(prompt: prompt, box: box, categories: categories)) else { return nil }
        req.url = URL(string: Jev.path)
        req.timeoutInterval = Jev.timeout
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Jev.reading(from: data, categories: categories)
    }

    /// Make a video clip. Video is a job OpenRouter runs in the background: submit it, poll
    /// until it is done, then download the clip. `progress` hears each status.
    public func video(model: String, prompt: String, firstFrame: Data?, seconds: Int?, aspect: String?,
                      resolution: String?, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Data {
        var body: [String: Any] = ["model": model, "prompt": prompt]
        if let seconds { body["duration"] = seconds }
        if let aspect { body["aspect_ratio"] = aspect }
        if let resolution { body["resolution"] = resolution }
        if let firstFrame {
            body["frame_images"] = [["type": "image_url", "frame_type": "first_frame",
                                     "image_url": ["url": "data:\(ImageType.mime(of: firstFrame));base64,\(firstFrame.base64EncodedString())"]]]
        }
        let (submitted, response) = try await URLSession.shared.data(for: request(path: "videos", body: body))
        try Self.check(submitted, response)
        guard let job = try JSONSerialization.jsonObject(with: submitted) as? [String: Any],
              let id = job["id"] as? String else { throw OpenRouterError.api("the video job sent no id back") }
        let started = Date()
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let (data, response) = try await URLSession.shared.data(for: get("videos/\(id)"))
            try Self.check(data, response)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let status = obj["status"] as? String ?? ""
            progress(status)
            switch status {
            case "completed":
                let url = (obj["unsigned_urls"] as? [String])?.first ?? baseURL.absoluteString + "/videos/\(id)/content?index=0"
                var req = URLRequest(url: URL(string: url)!)
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 300
                let (clip, r) = try await URLSession.shared.data(for: req)
                try Self.check(clip, r)
                return clip
            case "failed", "cancelled", "expired":
                let e = obj["error"]
                throw OpenRouterError.api((e as? String) ?? ((e as? [String: Any])?["message"] as? String) ?? "the video model gave up")
            default:
                if Date().timeIntervalSince(started) > 900 { throw OpenRouterError.api("the clip took over 15 minutes") }
            }
        }
    }

    /// Make music or a sound through a model that answers in audio. Audio replies only
    /// come streamed, as base64 pieces.
    public func music(model: String, prompt: String) async throws -> Data {
        var req = try request(path: "chat/completions", body: [
            "model": model,
            "stream": true,
            "modalities": ["text", "audio"],
            "audio": ["format": "mp3"],
            "messages": [["role": "user", "content": prompt]],
        ])
        req.timeoutInterval = 300
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw OpenRouterError.http(http.statusCode, Self.message(fromErrorBody: body))
        }
        var audio = Data()
        var base64 = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] { throw OpenRouterError.api(err["message"] as? String ?? "audio failed") }
            guard let delta = ((obj["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any],
                  let piece = (delta["audio"] as? [String: Any])?["data"] as? String else { continue }
            // Pieces may split a base64 quantum; decode whole quanta and carry the rest.
            base64 += piece
            let whole = base64.count - base64.count % 4
            if whole > 0, let d = Data(base64Encoded: String(base64.prefix(whole))) {
                audio.append(d)
                base64 = String(base64.dropFirst(whole))
            }
        }
        if !base64.isEmpty, let d = Data(base64Encoded: base64) { audio.append(d) }
        guard !audio.isEmpty else { throw OpenRouterError.api("the sound model sent no audio back") }
        return audio
    }
}
