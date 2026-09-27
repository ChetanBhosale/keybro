import Foundation

/// Generate through `claude -p`: Sonnet (Haiku wrote broken variants in testing),
/// screenshot inline, own system prompt, no tools, thinking off, nothing saved to disk.
public struct ClaudeGenerator: Sendable {
    public var runner: ClaudeRunner
    public var style: String?

    public init(runner: ClaudeRunner, style: String? = FixPrompt.loadStyle()) {
        self.runner = runner
        self.style = style
    }

    public func request(for input: GenerateInput) -> ClaudeRequest {
        ClaudeRequest(
            prompt: GeneratePrompt.userPrompt(input),
            images: input.screenshot.map { [$0] } ?? [],
            model: .sonnet,
            systemPrompt: GeneratePrompt.systemPrompt(style: style),
            tools: [],
            thinking: false,
            timeout: .seconds(60)
        )
    }

    public func generate(_ input: GenerateInput) -> AsyncThrowingStream<GenerateDraft, Error> {
        let events = runner.run(request(for: input))
        return AsyncThrowingStream { continuation in
            let task = Task {
                var raw = ""
                do {
                    for try await event in events {
                        switch event {
                        case .textDelta(let chunk):
                            raw += chunk
                            continuation.yield(GenerateDraft.parse(raw))
                        case .result(let result):
                            raw = result.text.isEmpty ? raw : result.text
                        default:
                            break
                        }
                    }
                    let final = GenerateDraft.parse(raw, final: true)
                    if final.isEmpty {
                        continuation.finish(throwing: ClaudeError.failed("Claude didn't return a message. Try rephrasing."))
                    } else {
                        continuation.yield(final)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
