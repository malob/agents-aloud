// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeCodeVoice",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(
            name: "ClaudeCodeVoice",
            targets: ["ClaudeCodeVoice"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeVoice",
            path: "Sources"
        ),
    ]
)
