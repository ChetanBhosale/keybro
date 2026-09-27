// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeybroKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KeybroKit", targets: ["KeybroKit"]),
        .executable(name: "keybro-smoke", targets: ["keybro-smoke"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        .target(name: "KeybroKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Dev tool: runs one prompt through ClaudeRunner from the terminal.
        .executableTarget(name: "keybro-smoke", dependencies: ["KeybroKit"]),
        // Dev tool: Fix end to end in a scratch TextEdit document (needs Accessibility).
        .executableTarget(name: "keybro-axprobe", dependencies: ["KeybroKit"]),
        .testTarget(
            name: "KeybroKitTests",
            dependencies: ["KeybroKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
