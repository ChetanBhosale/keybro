// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeybroKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KeybroKit", targets: ["KeybroKit"]),
        .executable(name: "keybro-smoke", targets: ["keybro-smoke"]),
        .executable(name: "keybro-mcp", targets: ["keybro-mcp"]),
        .executable(name: "keybro-nmh", targets: ["keybro-nmh"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        .target(name: "KeybroKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Dev tool: runs one prompt through ClaudeRunner from the terminal.
        .executableTarget(name: "keybro-smoke", dependencies: ["KeybroKit"]),
        // MCP server for Claude Code and other agents.
        .executableTarget(name: "keybro-mcp", dependencies: ["KeybroKit"]),
        // Native messaging host for the browser extension.
        .executableTarget(name: "keybro-nmh", dependencies: ["KeybroKit"]),
        // Memory retrieval benchmark (built-in demo or LongMemEval JSON).
        .executableTarget(name: "keybro-eval", dependencies: ["KeybroKit"]),
        // Dev tool: Fix end to end in a scratch TextEdit document (needs Accessibility).
        .executableTarget(name: "keybro-axprobe", dependencies: ["KeybroKit"]),
        .testTarget(
            name: "KeybroKitTests",
            dependencies: ["KeybroKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
