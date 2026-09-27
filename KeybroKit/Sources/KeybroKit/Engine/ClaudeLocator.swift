import Foundation

/// Finds the `claude` binary. GUI apps don't inherit the shell PATH, so check known
/// install locations first, then ask a login shell.
public struct ClaudeLocator: Sendable {
    public var home: String
    public var isExecutable: @Sendable (String) -> Bool
    public var loginShellLookup: @Sendable () -> String?

    public init(
        home: String,
        isExecutable: @escaping @Sendable (String) -> Bool,
        loginShellLookup: @escaping @Sendable () -> String?
    ) {
        self.home = home
        self.isExecutable = isExecutable
        self.loginShellLookup = loginShellLookup
    }

    public var candidates: [String] {
        [
            "\(home)/.local/bin/claude",   // native installer
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", // older local installs
        ]
    }

    public func locate() -> String? {
        if let hit = candidates.first(where: isExecutable) { return hit }
        guard let found = loginShellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
              found.hasPrefix("/"), isExecutable(found)
        else { return nil }
        return found
    }

    public static let live = ClaudeLocator(
        home: FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        loginShellLookup: {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v claude"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
        }
    )
}
