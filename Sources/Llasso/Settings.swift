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

    /// Keychain first; the environment variable is a developer fallback.
    var apiKey: String {
        Keychain.read(service: "llasso-openrouter", account: "default")
            ?? ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
            ?? ""
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(service: "llasso-openrouter", account: "default")
        } else {
            Keychain.save(trimmed, service: "llasso-openrouter", account: "default")
        }
        hasKey = !apiKey.isEmpty
    }

    var client: OpenRouterClient { OpenRouterClient(apiKey: apiKey) }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
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
    static func save(_ value: String, service: String, account: String) -> Bool {
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
