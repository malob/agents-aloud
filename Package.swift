// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentsAloud",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(
            name: "AgentsAloud",
            targets: ["AgentsAloud"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.3.1"),
    ],
    targets: [
        .executableTarget(
            name: "AgentsAloud",
            dependencies: [
                .product(name: "Textual", package: "textual"),
            ],
            path: "Sources",
            resources: [
                // Includes custom SF Symbol exports plus any loose
                // resources SwiftPM needs to bundle for development
                // and tests. The app wrapper compiles the asset
                // catalog with actool before signing the .app.
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AgentsAloudTests",
            dependencies: ["AgentsAloud"],
            path: "Tests"
        ),
    ]
)
