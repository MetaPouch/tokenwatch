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
    targets: [
        .target(
            name: "TokenWatchCore",
            path: "Sources/TokenWatchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TokenWatch",
            dependencies: ["TokenWatchCore"],
            path: "Sources/TokenWatch",
            resources: [.copy("Icons")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TokenWatchCoreTests",
            dependencies: ["TokenWatchCore"],
            path: "Tests/TokenWatchCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
