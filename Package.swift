// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenWatch",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "TokenWatch", targets: ["TokenWatch"]),
        .library(name: "TokenWatchCore", targets: ["TokenWatchCore"])
    ],
    dependencies: [
        // Sole external dependency, used only for in-app auto-update -- see DISTRIBUTION.md's
        // "Auto-update (Sparkle)" section for the EdDSA key setup this requires before release
        // builds can actually self-update.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "TokenWatchCore",
            path: "Sources/TokenWatchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TokenWatch",
            dependencies: [
                "TokenWatchCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/TokenWatch",
            resources: [.copy("Icons")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TokenWatchCoreTests",
            dependencies: ["TokenWatchCore"],
            path: "Tests/TokenWatchCoreTests",
            // tokenwatch-cloud's `packages/contracts` build output (schema/ and fixtures/),
            // copied verbatim so the Swift encoder is checked against the server's own files.
            resources: [.copy("Contracts")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
