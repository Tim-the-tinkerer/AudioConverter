// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioConverter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AudioConverter",
            path: "Sources/AudioConverter",
            resources: [.process("Resources")]
        )
    ]
)
