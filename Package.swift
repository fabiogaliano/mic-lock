// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "miclock",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "miclock", path: "Sources")
    ]
)
