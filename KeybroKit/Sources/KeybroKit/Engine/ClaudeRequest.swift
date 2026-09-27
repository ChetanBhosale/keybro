import Foundation

public struct ClaudeRequest: Sendable, Equatable {
    public enum Model: String, Sendable {
        case haiku, sonnet, opus
    }

    public var prompt: String
    public var model: Model
    /// Tools Claude may use without asking, e.g. ["Read"] to read a screenshot.
    public var allowedTools: [String]
    /// Extra folders Claude may read, e.g. the memory folder.
    public var addDirs: [String]
    /// Continue an earlier session (Generate refine). Requires `persistSession` on the first call.
    public var resumeSessionID: String?
    /// Keep the session on disk so it can be resumed. Off for one-shot calls like Fix.
    public var persistSession: Bool
    public var timeout: Duration

    public init(
        prompt: String,
        model: Model = .haiku,
        allowedTools: [String] = [],
        addDirs: [String] = [],
        resumeSessionID: String? = nil,
        persistSession: Bool = false,
        timeout: Duration = .seconds(60)
    ) {
        self.prompt = prompt
        self.model = model
        self.allowedTools = allowedTools
        self.addDirs = addDirs
        self.resumeSessionID = resumeSessionID
        self.persistSession = persistSession
        self.timeout = timeout
    }

    public var arguments: [String] {
        var args = [
            "-p", prompt,
            "--model", model.rawValue,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // Lean mode: skip user/project settings, hooks, MCP servers and skills.
            // Measured 4.5s vs 7.7s for a Fix call. Still uses the Claude login (unlike --bare).
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
        ]
        if !allowedTools.isEmpty {
            args += ["--allowedTools", allowedTools.joined(separator: ",")]
        }
        for dir in addDirs {
            args += ["--add-dir", dir]
        }
        if let resumeSessionID {
            args += ["--resume", resumeSessionID]
        } else if !persistSession {
            args.append("--no-session-persistence")
        }
        return args
    }
}
