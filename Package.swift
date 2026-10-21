// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PressurePilot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PressurePilot", path: "Sources/PressurePilot"),
        .testTarget(name: "PressurePilotTests", dependencies: ["PressurePilot"])
    ]
)
