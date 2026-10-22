import Foundation
import LlassoKit

/// Finds the project folder behind the box (spec §8, steps 1 and 2).
enum Resolver {
    static func source(for c: ScreenContext) -> SourceTarget? {
        let fm = FileManager.default
        let exists = { fm.fileExists(atPath: $0) }
        if let path = c.documentPath ?? c.url.flatMap(SourceResolver.filePath), exists(path) {
            let folder = (path as NSString).deletingLastPathComponent
            if let repo = SourceResolver.enclosingRepo(folder, exists: exists) {
                return SourceTarget(root: repo, file: path, isRepo: true, how: "from the open file")
            }
            guard Checkpoint.smallEnough(folder) else { return nil }
            return SourceTarget(root: folder, file: path, isRepo: false, how: "from the open file's folder")
        }
        guard let url = c.url, let port = SourceResolver.localPort(url) else {
            return c.bundleID == "app.hatch.browser" ? hatchCanvasFolder() : nil
        }
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".hatch/projects.json")
        var folder = (try? Data(contentsOf: projects)).flatMap { SourceResolver.hatchFolder(port: port, projectsJSON: $0) }
        var how = "from Hatch's project on port \(port)"
        if folder == nil, let cwd = listenerFolder(port: port) {
            folder = cwd
            how = "from the dev server on port \(port)"
        }
        guard let folder, exists(folder) else { return nil }
        if let repo = SourceResolver.enclosingRepo(folder, exists: exists) {
            return SourceTarget(root: repo, isRepo: true, how: how)
        }
        guard Checkpoint.smallEnough(folder) else { return nil }
        return SourceTarget(root: folder, isRepo: false, how: how)
    }

    /// When Hatch doesn't expose the page's address, use the folder whose canvas is in front.
    static func hatchCanvasFolder() -> SourceTarget? {
        let fm = FileManager.default
        let hatch = fm.homeDirectoryForCurrentUser.appendingPathComponent(".hatch")
        guard let ws = try? Data(contentsOf: hatch.appendingPathComponent("workspace.json")),
              let active = SourceResolver.hatchActiveCanvas(workspaceJSON: ws) else { return nil }
        var folders: [String] = []
        if let d = try? Data(contentsOf: hatch.appendingPathComponent("work-folders.json")),
           let list = try? JSONSerialization.jsonObject(with: d) as? [String] { folders += list }
        if let d = try? Data(contentsOf: hatch.appendingPathComponent("projects.json")),
           let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            folders += list.compactMap { $0["folder"] as? String }
        }
        for folder in folders {
            let file = URL(fileURLWithPath: folder).appendingPathComponent(".hatch/canvas.json")
            guard let d = try? Data(contentsOf: file), SourceResolver.hatchCanvas(canvasJSON: d) == active else { continue }
            if let repo = SourceResolver.enclosingRepo(folder, exists: { fm.fileExists(atPath: $0) }) {
                return SourceTarget(root: repo, isRepo: true, how: "from the Hatch canvas in front")
            }
            return Checkpoint.smallEnough(folder) ? SourceTarget(root: folder, isRepo: false, how: "from the Hatch canvas in front") : nil
        }
        return nil
    }

    /// The working folder of the process listening on a local port.
    static func listenerFolder(port: Int) -> String? {
        guard let pids = try? Proc.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 3).out,
              let pid = pids.split(separator: "\n").first,
              let cwd = try? Proc.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 3).out
        else { return nil }
        let path = cwd.split(separator: "\n").first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
        // A server started from the home folder or root says nothing about the project.
        if path == "/" || path == FileManager.default.homeDirectoryForCurrentUser.path { return nil }
        return path
    }
}

/// Runs a command and collects its output, off the main thread.
enum Proc {
    struct Result { var out: String; var err: String; var status: Int32 }

    static func run(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:],
                    stdin: Data? = nil, timeout: TimeInterval = 30) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(stdin) }
        try? inp.fileHandleForWriting.close()
        // Read while it runs so a large diff can't fill the pipe and stall the process.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw ActionError.failed("\((exe as NSString).lastPathComponent) took too long.")
        }
        p.waitUntilExit()
        return Result(out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self),
                      status: p.terminationStatus)
    }
}

/// Snapshots of a project folder as git trees, so a change can be shown as a diff and undone.
/// In a repo it uses a private index file and leaves the user's index, branches and commits alone.
/// Elsewhere it keeps a separate git store under Application Support.
struct Checkpoint {
    let target: SourceTarget

    static let git = "/usr/bin/git"

    static var store: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Llasso/Snapshots", isDirectory: true)
    }

    /// Folders outside a repo are snapshotted whole, so only small ones qualify.
    static func smallEnough(_ folder: String) -> Bool {
        guard let e = FileManager.default.enumerator(atPath: folder) else { return false }
        var n = 0
        while e.nextObject() != nil { n += 1; if n > 2000 { return false } }
        return true
    }

    /// A hash of the folder path that stays the same between launches.
    private var id: String {
        String(target.root.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }, radix: 16)
    }

    private var gitDir: String? {
        target.isRepo ? nil : Self.store.appendingPathComponent(id).path
    }

    private var baseArgs: [String] {
        if let gitDir { return ["--git-dir=\(gitDir)", "--work-tree=\(target.root)"] }
        return ["-C", target.root]
    }

    private var index: String {
        NSTemporaryDirectory() + "llasso-index-" + id
    }

    @discardableResult
    private func git(_ args: [String], stdin: Data? = nil, privateIndex: Bool = false) throws -> String {
        var env = ["GIT_AUTHOR_NAME": "Llasso", "GIT_AUTHOR_EMAIL": "llasso@localhost",
                   "GIT_COMMITTER_NAME": "Llasso", "GIT_COMMITTER_EMAIL": "llasso@localhost"]
        if privateIndex { env["GIT_INDEX_FILE"] = index }
        let r = try Proc.run(Self.git, baseArgs + args, cwd: target.root, env: env, stdin: stdin, timeout: 60)
        guard r.status == 0 else {
            throw ActionError.failed("git: " + r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole working folder as a tree id, untracked files included, ignored files left out.
    func snapshot() throws -> String {
        if let gitDir, !FileManager.default.fileExists(atPath: gitDir) {
            try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
            _ = try Proc.run(Self.git, ["init", "-q", "--bare", gitDir], timeout: 20)
        }
        // Start from the repo's own index so unchanged files aren't hashed again.
        if gitDir == nil, let real = try? git(["rev-parse", "--path-format=absolute", "--git-path", "index"]) {
            try? FileManager.default.removeItem(atPath: index)
            try? FileManager.default.copyItem(atPath: real, toPath: index)
        }
        try git(["add", "-A", "--", "."], privateIndex: true)
        let tree = try git(["write-tree"], privateIndex: true)
        // Pin the tree under a Llasso ref so git's clean-up keeps it until the next job.
        let commit = try git(["commit-tree", tree, "-m", "Llasso checkpoint"])
        try git(["update-ref", "refs/llasso/last", commit])
        return tree
    }

    func changes(from a: String, to b: String) throws -> [FileChange] {
        FileChange.parse(numstat: try git(["diff", "--numstat", a, b]))
    }

    func diff(from a: String, to b: String) throws -> String {
        try git(["diff", "--no-color", "-U2", a, b])
    }

    /// Put the folder back as it was at `before`, for the files that changed since.
    func undo(before: String, after: String) throws {
        let patch = try Proc.run(Self.git, baseArgs + ["diff", "--binary", after, before], cwd: target.root, timeout: 60).out
        guard !patch.isEmpty else { return }
        let r = try Proc.run(Self.git, baseArgs + ["apply", "--whitespace=nowarn", "-"], cwd: target.root,
                             stdin: Data(patch.utf8), timeout: 60)
        guard r.status == 0 else {
            throw ActionError.failed("Llasso couldn't undo: the files changed again after the edit. " + r.err.prefix(200))
        }
    }
}

/// Claude Code, run headless in the project folder (route A).
enum ClaudeCode {
    static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run one edit and stream its steps. Only file tools are allowed: no shell, no network.
    static func edit(prompt: String, in root: String, extraDirs: [String],
                     onEvent: @escaping @Sendable (CodeEvent) -> Void) async throws -> (summary: String, isError: Bool) {
        guard let exe = path else {
            throw ActionError.failed("Editing code needs Claude Code. Install it from claude.com/claude-code, then try again.")
        }
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                               "--permission-mode", "acceptEdits",
                               "--allowedTools", "Read", "Edit", "MultiEdit", "Write", "Glob", "Grep",
                               "--disallowedTools", "Bash", "WebFetch", "WebSearch",
                               // The user's own hooks and plugins are for their sessions, not Llasso's.
                               "--setting-sources", "project,local"]
                    + extraDirs.flatMap { ["--add-dir", $0] }
                p.currentDirectoryURL = URL(fileURLWithPath: root)
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                try p.run()
                Running.shared.set(p)
                defer { Running.shared.set(nil) }
                var result: (String, Bool)?
                var buffer = Data()
                let handle = out.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[..<nl], as: UTF8.self)
                        buffer.removeSubrange(...nl)
                        for e in ClaudeStream.parse(line) {
                            if case .done(let s, let isError) = e { result = (s, isError) }
                            onEvent(e)
                        }
                    }
                }
                p.waitUntilExit()
                if let result { return (summary: result.0, isError: result.1) }
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw ActionError.failed("Claude Code stopped: " + String(e.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)).ifEmpty("no result."))
            }.value
        } onCancel: {
            Running.shared.stop()
        }
    }

    /// The one Claude Code process a job may have running, so Stop can end it.
    final class Running: @unchecked Sendable {
        static let shared = Running()
        private let lock = NSLock()
        private var process: Process?
        func set(_ p: Process?) { lock.withLock { process = p } }
        func stop() { lock.withLock { if process?.isRunning == true { process?.terminate() } } }
    }
}
