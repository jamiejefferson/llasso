import Foundation
import Security
import LlassoKit

/// User settings. The OpenRouter key lives in the Keychain; everything else in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    enum VoiceOut: String, CaseIterable, Identifiable {
        case system, openrouter, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "Mac voice (free, on device)"
            case .openrouter: return "OpenRouter voice (e.g. ElevenLabs)"
            case .off: return "Don't speak answers"
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var voiceOut: VoiceOut { didSet { defaults.set(voiceOut.rawValue, forKey: "voiceOut") } }
    @Published var ttsModel: String { didSet { defaults.set(ttsModel, forKey: "ttsModel") } }
    @Published var ttsVoice: String { didSet { defaults.set(ttsVoice, forKey: "ttsVoice") } }
    @Published var imageModel: String { didSet { defaults.set(imageModel, forKey: "imageModel") } }
    @Published private(set) var hasKey = false

    static let defaultModel = "anthropic/claude-sonnet-5.5"
    static let defaultImageModel = "google/gemini-3.1-flash-image"

    private init() {
        model = defaults.string(forKey: "model") ?? Settings.defaultModel
        voiceOut = VoiceOut(rawValue: defaults.string(forKey: "voiceOut") ?? "") ?? .system
        ttsModel = defaults.string(forKey: "ttsModel") ?? "elevenlabs/eleven-v4-turbo"
        ttsVoice = defaults.string(forKey: "ttsVoice") ?? ""
        imageModel = defaults.string(forKey: "imageModel") ?? Settings.defaultImageModel
        hasKey = !apiKey.isEmpty
    }

    /// Read from the Keychain once per launch and kept in memory, so the Keychain is asked
    /// once, not on every request. The environment variable is a developer fallback.
    private var cachedKey: String?

    var apiKey: String {
        if let cachedKey { return cachedKey }
        let key = Keychain.read(service: "llasso-openrouter", account: "default")
            ?? ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
            ?? ""
        cachedKey = key
        return key
    }

    func saveKey(_ key: String) {
        let trimmed = OpenRouterClient.cleanKey(key)
        cachedKey = nil
        if trimmed.isEmpty {
            Keychain.delete(service: "llasso-openrouter", account: "default")
        } else {
            Keychain.save(trimmed, service: "llasso-openrouter", account: "default")
        }
        hasKey = !apiKey.isEmpty
    }

    var client: OpenRouterClient { OpenRouterClient(apiKey: apiKey) }
}

/// The key lives in the login keychain. Llasso is signed with a local certificate and has no
/// Team ID, so the Keychain ties each item to the exact build that wrote or last read it,
/// and every rebuild would ask for the login password again. Going through Apple's own
/// `security` tool, which the item lists as allowed, avoids that prompt and is no wider
/// than the access the item already grants that tool.
enum Keychain {
    static let tool = "/usr/bin/security"

    static func read(service: String, account: String) -> String? {
        if let r = try? Proc.run(tool, ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 10),
           r.status == 0 {
            let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return readDirect(service: service, account: account)
    }

    /// Write through the `security` tool, listing both the tool and this app as allowed.
    /// The value goes in on standard input, never on a command line other processes can see.
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        let safe = value.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            && service.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        guard safe else { return saveDirect(value, service: service, account: account) }
        let app = Bundle.main.bundlePath
        let command = "add-generic-password -U -s \(service) -a \(account) -w \"\(value)\" -T \(tool) -T \"\(app)\"\n"
        guard let r = try? Proc.run(tool, ["-i"], stdin: Data(command.utf8), timeout: 10), r.status == 0,
              read(service: service, account: account) == value
        else { return saveDirect(value, service: service, account: account) }
        return true
    }

    static func readDirect(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func saveDirect(_ value: String, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let s = SecItemDelete(query as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}

/// One line of JSON per job, kept locally. Images are not stored.
/// A plain event log for working out what happened when Llasso misbehaves.
enum Log {
    static func write(_ line: String) {
        let url = History.folder.appendingPathComponent("llasso.log")
        try? FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

enum History {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Llasso", isDirectory: true)
    }

    static func append(prompt: String, verb: Verb?, context: ScreenContext, answer: String, model: String,
                       actions: [String] = []) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "prompt": prompt,
            "verb": verb?.rawValue ?? "",
            "app": context.appName ?? "",
            "target": context.tag,
            "model": model,
            "answer": answer,
            "kind": context.kind.rawValue,
            "actions": actions,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.jsonl")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }
}
