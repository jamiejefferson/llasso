import AppKit
import Combine

/// Keeps Llasso current without interrupting anyone. It asks GitHub for the latest release at
/// launch and once a day, and when there is a newer one, a line in the menu and the request list
/// offers it. Nothing pops up. Updating downloads the same zip the install command uses, checks
/// it is signed like this copy, waits for running requests, then swaps the app in place and
/// reopens it, so permissions carry over.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        var version: String
        /// The first line of the release notes, written for the people using Llasso.
        var note: String?
        var zip: URL
    }

    enum State: Equatable {
        case idle
        case waiting          // for running requests to finish
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "checkUpdates"); if enabled { check() } } }

    static let repo = "jamiejefferson/llasso"
    static let installCommand = "curl -fsSL llasso.projject.ai/install | sh"
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    private init() {
        enabled = defaults.object(forKey: "checkUpdates") as? Bool ?? true
    }

    /// Check a few seconds after launch, then once a day while Llasso runs.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
    }

    func check() {
        guard enabled else { return }
        Task { await refresh() }
    }

    func refresh() async {
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 20
                let (data, _) = try await URLSession.shared.data(for: req)
                let release = Self.parse(data)
                lastChecked = Date()
                available = release.flatMap { Self.isNewer($0.version, than: Self.current) ? $0 : nil }
                Log.write("update: latest \(release?.version ?? "unknown"), running \(Self.current)")
            } catch {
                Log.write("update: check failed, \(error.localizedDescription)")
            }
    }

    /// The release's version, its zip and the first line of its notes. Notes that open with the
    /// install instructions have no line for people, so none is shown.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]],
              let zip = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix("mac-arm64.zip") }),
              let url = URL(string: zip)
        else { return nil }
        let first = (obj["body"] as? String ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*_ ")) }
            .first { !$0.isEmpty }
        let note = first.flatMap { $0.lowercased().hasPrefix("install or update") ? nil : $0 }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, note: note, zip: url)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// For the look test: a newer version waiting, or an update that failed.
    func showForTest(_ release: Release?, state: State = .idle) {
        available = release
        self.state = state
    }

    // MARK: Updating

    func update() {
        guard let release = available, state == .idle || isFailed else { return }
        Task { await install(release) }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    private func install(_ release: Release) async {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return fail("Llasso can't write to \(folder.path).")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("llasso-update-\(UUID().uuidString.prefix(8))")
        do {
            state = .downloading
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (download, response) = try await URLSession.shared.download(from: release.zip)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return fail("The download was refused.") }
            let zip = work.appendingPathComponent("llasso.zip")
            try FileManager.default.moveItem(at: download, to: zip)
            let fresh = work.appendingPathComponent("Llasso.app")
            // Unpacking and checking the signature run off the main thread.
            let problem: String? = try await Task.detached {
                _ = try Proc.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], timeout: 120)
                guard FileManager.default.fileExists(atPath: fresh.path) else { return "The download held no Llasso.app." }
                _ = try? Proc.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])
                // Only a build signed like this one may replace it: anything else could be tampered
                // with, and macOS would drop the permissions this copy was given.
                guard (try? Proc.run("/usr/bin/codesign", ["--verify", "--strict", fresh.path], timeout: 60))?.status == 0 else {
                    return "The new version's signature didn't check out."
                }
                guard let mine = Self.requirement(app), mine == Self.requirement(fresh) else {
                    return "The new version isn't signed like this one."
                }
                return nil
            }.value
            if let problem { return fail(problem) }
            // Requests still running finish first.
            state = .waiting
            while Controller.shared.jobs.contains(where: \.isRunning) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            state = .installing
            try swapAndRelaunch(fresh: fresh, into: app, work: work)
            Log.write("update: installing \(release.version) over \(Self.current)")
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: work)
            fail(error.localizedDescription)
        }
    }

    /// The signing requirement macOS ties permissions to.
    nonisolated static func requirement(_ app: URL) -> String? {
        guard let r = try? Proc.run("/usr/bin/codesign", ["-d", "-r-", app.path]), r.status == 0 else { return nil }
        let text = r.out + r.err
        return text.split(separator: "\n").first { $0.contains("designated =>") }.map(String.init)
    }

    /// A running app can't replace itself, so a small script waits for Llasso to quit, puts
    /// the new copy where the old one was (putting the old one back if that fails), and opens it.
    private func swapAndRelaunch(fresh: URL, into app: URL, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        old=\(q(work.path))/old.app
        mv \(q(app.path)) "$old" || exit 1
        if ditto \(q(fresh.path)) \(q(app.path)); then
          xattr -dr com.apple.quarantine \(q(app.path)) 2>/dev/null
          open \(q(app.path))
          rm -rf \(q(work.path))
        else
          rm -rf \(q(app.path)); mv "$old" \(q(app.path)); open \(q(app.path))
        fi
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private func fail(_ why: String) {
        Log.write("update: failed, \(why)")
        state = .failed(why)
    }

    /// The line the menu and the request list show, or nil when there is nothing to say.
    var line: String? {
        guard let release = available else { return nil }
        switch state {
        case .idle: return "Update to \(release.version)"
        case .waiting: return "Updating when your requests finish…"
        case .downloading: return "Downloading \(release.version)…"
        case .installing: return "Installing \(release.version)…"
        case .failed: return "Update failed: copy the install command"
        }
    }
}
