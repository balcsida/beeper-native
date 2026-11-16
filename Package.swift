// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeeperNative",
    platforms: [.macOS(.v14)],
    targets: [
        // Foundation only, no UI: everything that talks to the Beeper Desktop API.
        .target(name: "BeeperKit"),
        .executableTarget(name: "BeeperNative", dependencies: ["BeeperKit"]),
        .testTarget(name: "BeeperKitTests", dependencies: ["BeeperKit"]),
    ]
)
