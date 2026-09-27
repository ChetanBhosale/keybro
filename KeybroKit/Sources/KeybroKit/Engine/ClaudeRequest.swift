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
    /// Replaces Claude Code's own system prompt. Much cheaper for plain text tasks like Fix.
    public var systemPrompt: String?
    /// Built-in tools Claude can see. nil keeps the default set, [] disables all tools.
    public var tools: [String]?
    /// Extended thinking. Off for Fix: measured 2.5s vs 4.5s wall time on Haiku.
    public var thinking: Bool
    public var timeout: Duration

    public init(
        prompt: String,
        model: Model = .haiku,
        allowedTools: [String] = [],
        addDirs: [String] = [],
        resumeSessionID: String? = nil,
        persistSession: Bool = false,
        systemPrompt: String? = nil,
        tools: [String]? = nil,
        thinking: Bool = true,
        timeout: Duration = .seconds(60)
    ) {
        self.prompt = prompt
        self.model = model
        self.allowedTools = allowedTools
        self.addDirs = addDirs
        self.resumeSessionID = resumeSessionID
        self.persistSession = persistSession
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.thinking = thinking
        self.timeout = timeout
    }

    /// Extra environment for the claude process.
    public var environment: [String: String] {
        thinking ? [:] : ["MAX_THINKING_TOKENS": "0"]
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
        if let systemPrompt {
            args += ["--system-prompt", systemPrompt]
        }
        if let tools {
            args += ["--tools", tools.joined(separator: ",")]
        }
        if !thinking {
            args += ["--settings", #"{"alwaysThinkingEnabled":false}"#]
        }
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
