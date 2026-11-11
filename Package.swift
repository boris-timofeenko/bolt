// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bolt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bolt", targets: ["Bolt"]),
        // Not "bolt": on a case-insensitive disk it would overwrite the app's "Bolt" binary.
        .executable(name: "bolt-cli", targets: ["BoltCLI"]),
    ],
    targets: [
        .target(name: "BoltCore"),
        .executableTarget(name: "Bolt", dependencies: ["BoltCore"]),
        .executableTarget(name: "BoltCLI", dependencies: ["BoltCore"]),
        .testTarget(name: "BoltCoreTests", dependencies: ["BoltCore"]),
    ]
)
