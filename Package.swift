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
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.3.1"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeVoice",
            dependencies: [
                .product(name: "Textual", package: "textual"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "ClaudeCodeVoiceTests",
            dependencies: ["ClaudeCodeVoice"],
            path: "Tests"
        ),
    ]
)
