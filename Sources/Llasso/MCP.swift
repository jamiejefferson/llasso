import AppKit
import LlassoKit

/// One tool an MCP server offers.
struct MCPTool {
    var name: String
    var description: String
    var schema: [String: Any]
    /// The server marked it read-only, so it runs without asking.
    var readOnly: Bool
}

/// What a tool call returned: text for the model, and any images it sent.
struct MCPResult {
    var text: String
    var images: [Data]
    var isError: Bool
}

enum MCPError: Error, LocalizedError {
    case launch(String)
    case closed
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .launch(let m): return "Couldn't start the app's MCP server: \(m)"
        case .closed: return "The app's MCP server stopped."
        case .timeout: return "The app's MCP server didn't answer in time."
        case .server(let m): return m
        }
    }
}

/// How to reach a server: a command to run (stdio) or a local URL (streamable HTTP).
enum MCPTransport: Equatable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(URL)
}

/// A connection to one MCP server, spoken as JSON-RPC.
final class MCPClient {
    let name: String
    let transport: MCPTransport
    private(set) var tools: [MCPTool] = []
    private(set) var instructions: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var sessionID: String?
    private let lock = NSLock()

    init(name: String, transport: MCPTransport) {
        self.name = name
        self.transport = transport
    }

    var isRunning: Bool {
        switch transport {
        case .stdio: return process?.isRunning == true
        case .http: return sessionID != nil || !tools.isEmpty
        }
    }

    /// Start the server, shake hands and fetch its tools.
    func connect() async throws {
        if case .stdio(let command, let args, let env) = transport { try launch(command, args, env) }
        let info = try await call("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Llasso", "version": "0.2"],
        ])
        instructions = info["instructions"] as? String
        try await notify("notifications/initialized")
        let list = try await call("tools/list", [:])
        tools = (list["tools"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let notes = t["annotations"] as? [String: Any] ?? [:]
            return MCPTool(name: name, description: t["description"] as? String ?? "",
                           schema: t["inputSchema"] as? [String: Any] ?? ["type": "object"],
                           readOnly: notes["readOnlyHint"] as? Bool ?? false)
        }
    }

    func callTool(_ tool: String, arguments: [String: Any]) async throws -> MCPResult {
        let r = try await call("tools/call", ["name": tool, "arguments": arguments], timeout: 120)
        var texts: [String] = []
        var images: [Data] = []
        for block in r["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text": if let t = block["text"] as? String { texts.append(t) }
            case "image":
                if let b = block["data"] as? String, let d = Data(base64Encoded: b) { images.append(d) }
            case "resource":
                if let res = block["resource"] as? [String: Any], let t = res["text"] as? String { texts.append(t) }
            default: continue
            }
        }
        return MCPResult(text: texts.joined(separator: "\n"), images: images, isError: r["isError"] as? Bool ?? false)
    }

    func stop() {
        process?.terminate()
        process = nil
        failAll(MCPError.closed)
    }

    // MARK: JSON-RPC

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let id: Int = lock.withLock { defer { nextID += 1 }; return nextID }
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if case .http(let url) = transport { return try await post(msg, to: url, id: id, timeout: timeout) }
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { waiting[id] = cont }
            do { try write(msg) } catch { resolve(id, .failure(error)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(MCPError.timeout))
            }
        }
    }

    private func notify(_ method: String) async throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if case .http(let url) = transport { _ = try? await post(msg, to: url, id: nil, timeout: 10); return }
        try write(msg)
    }

    private func resolve(_ id: Int, _ result: Result<[String: Any], Error>) {
        let cont = lock.withLock { waiting.removeValue(forKey: id) }
        cont?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let all = lock.withLock { defer { waiting = [:] }; return waiting }
        all.values.forEach { $0.resume(throwing: error) }
    }

    private static func outcome(of obj: [String: Any]) -> Result<[String: Any], Error> {
        if let err = obj["error"] as? [String: Any] {
            return .failure(MCPError.server(err["message"] as? String ?? "MCP error"))
        }
        return .success(obj["result"] as? [String: Any] ?? [:])
    }

    // MARK: stdio

    private func launch(_ command: String, _ args: [String], _ env: [String: String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        // An app launched from Finder has a bare PATH; servers written in Node need more.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        env.forEach { environment[$0] = $1 }
        p.environment = environment
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty { h.readabilityHandler = nil; self.failAll(MCPError.closed); return }
            self.received(data)
        }
        p.terminationHandler = { [weak self] _ in self?.failAll(MCPError.closed) }
        do { try p.run() } catch { throw MCPError.launch(error.localizedDescription) }
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    private func write(_ msg: [String: Any]) throws {
        guard let stdin, process?.isRunning == true else { throw MCPError.closed }
        var data = try JSONSerialization.data(withJSONObject: msg)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func received(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(Data(buffer[buffer.startIndex..<nl]))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int, obj["method"] == nil else { continue }
            resolve(id, Self.outcome(of: obj))
        }
    }

    // MARK: Streamable HTTP

    private func post(_ msg: [String: Any], to url: URL, id: Int?, timeout: TimeInterval) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = s }
            if !(200..<300).contains(http.statusCode) { throw MCPError.server("MCP server answered \(http.statusCode)") }
        }
        guard id != nil else { return [:] }
        // The answer is either plain JSON or a short event stream whose data lines hold it.
        let body = String(decoding: data, as: UTF8.self)
        let candidates = body.hasPrefix("{") ? [body]
            : body.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) }
        for c in candidates {
            if let obj = try? JSONSerialization.jsonObject(with: Data(c.utf8)) as? [String: Any], obj["id"] as? Int == id {
                return try Self.outcome(of: obj).get()
            }
        }
        throw MCPError.server("The MCP server sent an answer Llasso couldn't read.")
    }
}

/// Apps whose own MCP servers Llasso can drive, and how to find each server on this Mac.
struct Integration: Identifiable {
    var id: String { name }
    var name: String
    /// Bundle ids of the app the server drives.
    var bundleIDs: [String]
    /// App names to match when the bundle id varies between builds.
    var appNames: [String]
    var transport: MCPTransport?
    /// Shown when the app is installed but no server was found.
    var setup: String
    /// Tools never offered to the model, for privacy.
    var blocked: Set<String> = []

    func matches(bundleID: String?, appName: String?) -> Bool {
        if let b = bundleID, bundleIDs.contains(b) { return true }
        if let n = appName?.lowercased(), appNames.contains(n) { return true }
        return false
    }

    var installedApp: URL? {
        for b in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return url }
        }
        for n in appNames {
            let url = URL(fileURLWithPath: "/Applications/\(n.capitalized).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Finds integrations, keeps one running server per app, and hands out tools for a job.
@MainActor
final class Integrations: ObservableObject {
    static let shared = Integrations()

    @Published private(set) var all: [Integration] = []
    @Published private(set) var status: [String: String] = [:]
    private var clients: [String: MCPClient] = [:]

    private init() { discover() }

    /// Built-in knowledge first, then any stdio server in Claude Code's config whose name
    /// matches a running app, so a server added there shows up here with no extra set-up.
    func discover() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        func exe(_ path: String) -> Bool { fm.isExecutableFile(atPath: path) }

        var list: [Integration] = []
        let paper = "\(home)/.paper/bin/paper"
        list.append(Integration(
            name: "Paper", bundleIDs: ["com.todesktop.2601167vjw8xe"], appNames: ["paper"],
            transport: exe(paper) ? .stdio(command: paper, args: ["mcp"], env: [:]) : nil,
            setup: "Install Paper's command-line tool from Paper's settings so ~/.paper/bin/paper exists, then press Recheck."))
        let hatch = "/Applications/Hatch.app/Contents/Resources/hatch-mcp"
        list.append(Integration(
            name: "Hatch", bundleIDs: ["app.hatch.browser"], appNames: ["hatch"],
            transport: exe(hatch) ? .stdio(command: hatch, args: [], env: ["HATCH_AGENT": "llasso"]) : nil,
            setup: "Update Hatch to a build that includes hatch-mcp, then press Recheck.",
            blocked: ["list_credentials", "fill_credentials"]))
        list.append(Integration(
            name: "Figma", bundleIDs: ["com.figma.Desktop"], appNames: ["figma"],
            transport: nil,
            setup: "In the Figma desktop app, open Preferences and turn on the Dev Mode MCP server, then press Recheck."))

        for (name, server) in claudeCodeServers() {
            let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
            if let i = list.firstIndex(where: { key.contains($0.name.lowercased()) }) {
                if list[i].transport == nil { list[i].transport = server }
            }
        }
        all = list
        Task { await refreshFigma() }
        for i in list { status[i.name] = label(i) }
    }

    /// Figma's desktop server only answers while Figma runs with the setting on.
    private func refreshFigma() async {
        guard let i = all.firstIndex(where: { $0.name == "Figma" }), all[i].transport == nil,
              let url = URL(string: "http://127.0.0.1:3845/mcp") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        if (try? await URLSession.shared.data(for: req)) != nil {
            all[i].transport = .http(url)
            status["Figma"] = label(all[i])
        }
    }

    private func label(_ i: Integration) -> String {
        if clients[i.name]?.isRunning == true { return "Connected" }
        if i.transport != nil { return "Ready" }
        return i.installedApp != nil ? "Needs set-up" : "Not installed"
    }

    /// stdio servers from ~/.claude.json and installed Claude Code plugins.
    private func claudeCodeServers() -> [(String, MCPTransport)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [(String, MCPTransport)] = []
        func add(_ servers: [String: Any]?, base: URL?) {
            for (name, value) in servers ?? [:] {
                guard let s = value as? [String: Any] else { continue }
                if let cmd = s["command"] as? String {
                    var path = cmd
                    if let base, path.contains("${CLAUDE_PLUGIN_ROOT}") {
                        path = path.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: base.path)
                    }
                    guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { continue }
                    out.append((name, .stdio(command: path, args: s["args"] as? [String] ?? [],
                                             env: s["env"] as? [String: String] ?? [:])))
                } else if let u = s["url"] as? String, let url = URL(string: u),
                          url.host == "127.0.0.1" || url.host == "localhost" {
                    out.append((name, .http(url)))
                }
            }
        }
        func json(_ url: URL) -> [String: Any]? {
            guard let d = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        add(json(home.appendingPathComponent(".claude.json"))?["mcpServers"] as? [String: Any], base: nil)
        let market = home.appendingPathComponent(".claude/plugins/marketplaces")
        let walker = FileManager.default.enumerator(at: market, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if walker?.level ?? 0 > 4 { walker?.skipDescendants(); continue }
            guard url.lastPathComponent == "mcp.claude.json" || url.lastPathComponent == ".mcp.json" else { continue }
            add(json(url)?["mcpServers"] as? [String: Any], base: url.deletingLastPathComponent())
        }
        return out
    }

    func integration(bundleID: String?, appName: String?) -> Integration? {
        all.first { $0.matches(bundleID: bundleID, appName: appName) }
    }

    /// An app with its own server that the user named in the request ("do this in Paper").
    func named(in prompt: String) -> Integration? {
        all.first { i in
            i.transport != nil && prompt.range(of: "\\b\(NSRegularExpression.escapedPattern(for: i.name))\\b",
                                               options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The running client for this app, started on first use. Nil when the app has none.
    func client(for i: Integration) async -> MCPClient? {
        if let c = clients[i.name], c.isRunning { return c }
        guard let transport = i.transport else { return nil }
        let c = MCPClient(name: i.name, transport: transport)
        do {
            try await c.connect()
        } catch {
            c.stop()
            status[i.name] = "Didn't start: " + error.localizedDescription
            return nil
        }
        clients[i.name] = c
        status[i.name] = "Connected"
        return c
    }

    /// The client's tools as OpenRouter tool definitions.
    func toolSchemas(_ c: MCPClient, blocked: Set<String>) -> [[String: Any]] {
        c.tools.filter { !blocked.contains($0.name) }.map { t in
            ["type": "function",
             "function": ["name": ToolName.qualified(server: c.name, tool: t.name),
                          "description": String(t.description.prefix(1000)),
                          "parameters": Self.withWhy(t.schema)]]
        }
    }

    /// The argument every app tool gains, so an approval can say what the step is for in plain words.
    static let why = "llasso_why"

    /// Add a required `llasso_why` to a tool's parameters. Job strips it before the call.
    static func withWhy(_ schema: [String: Any]) -> [String: Any] {
        var s = schema
        var props = s["properties"] as? [String: Any] ?? [:]
        props[why] = ["type": "string",
                      "description": "One short plain sentence for the user saying what this step does, in their terms, e.g. \"Open the link under the box in a new Hatch window\". No code."]
        s["properties"] = props
        s["required"] = (s["required"] as? [String] ?? []) + [why]
        if s["type"] == nil { s["type"] = "object" }
        return s
    }

    func recheck() {
        discover()
    }

    func stopAll() {
        clients.values.forEach { $0.stop() }
        clients = [:]
    }
}
