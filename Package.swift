// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Llasso",
    // macOS 26 for the on-device SpeechAnalyzer transcription API.
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic with no AppKit: OpenRouter client, prompt brief, geometry,
        // sensitive-app list. Exercised by LlassoCheck.
        .target(name: "LlassoKit", path: "Sources/LlassoKit",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Llasso",
            dependencies: ["LlassoKit"],
            path: "Sources/Llasso",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dev-only checks for LlassoKit, plus a live OpenRouter call when
        // OPENROUTER_API_KEY is set. Not shipped.
        .executableTarget(
            name: "LlassoCheck",
            dependencies: ["LlassoKit"],
            path: "Sources/LlassoCheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
