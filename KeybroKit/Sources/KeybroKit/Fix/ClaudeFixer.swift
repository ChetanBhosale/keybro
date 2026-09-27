import Foundation

/// Fix through `claude -p`: Haiku, custom system prompt, no tools, no thinking.
public struct ClaudeFixer: Sendable {
    public var runner: ClaudeRunner
    public var style: String?

    public init(runner: ClaudeRunner, style: String? = FixPrompt.loadStyle()) {
        self.runner = runner
        self.style = style
    }

    public func request(for text: String, mode: String? = nil) -> ClaudeRequest {
        ClaudeRequest(
            prompt: FixPrompt.userPrompt(text: text),
            model: .haiku,
            systemPrompt: FixPrompt.systemPrompt(style: style, mode: mode),
            tools: [],
            thinking: false,
            timeout: .seconds(30)
        )
    }

    /// Returns the model's raw reply. Clean it with `FixOutput.clean`.
    public func fix(_ text: String, mode: String? = nil) async throws -> String {
        var streamed = ""
        var final: String?
        for try await event in runner.run(request(for: text, mode: mode)) {
            switch event {
            case .textDelta(let chunk): streamed += chunk
            case .result(let result): final = result.text
            default: break
            }
        }
        return final ?? streamed
    }
}
