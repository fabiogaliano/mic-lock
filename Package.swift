// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "miclock",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/onevcat/Rainbow", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "miclock",
            dependencies: ["Rainbow"],
            path: "Sources"
        )
    ]
)
