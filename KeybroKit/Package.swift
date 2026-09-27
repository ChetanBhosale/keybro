// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeybroKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KeybroKit", targets: ["KeybroKit"]),
        .executable(name: "keybro-smoke", targets: ["keybro-smoke"]),
    ],
    targets: [
        .target(name: "KeybroKit"),
        // Dev tool: runs one prompt through ClaudeRunner from the terminal.
        .executableTarget(name: "keybro-smoke", dependencies: ["KeybroKit"]),
        .testTarget(
            name: "KeybroKitTests",
            dependencies: ["KeybroKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
