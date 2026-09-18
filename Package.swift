// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TokenWatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenWatch", targets: ["TokenWatch"]),
        .library(name: "TokenWatchCore", targets: ["TokenWatchCore"])
    ],
    targets: [
        .target(
            name: "TokenWatchCore",
            path: "Sources/TokenWatchCore"
        ),
        .executableTarget(
            name: "TokenWatch",
            dependencies: ["TokenWatchCore"],
            path: "Sources/TokenWatch"
        ),
        .testTarget(
            name: "TokenWatchCoreTests",
            dependencies: ["TokenWatchCore"],
            path: "Tests/TokenWatchCoreTests"
        )
    ]
)
