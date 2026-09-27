import Foundation
import FoundationModels

/// A language model for background work (memory extraction, summaries, loop checks).
public protocol TextModel: Sendable {
    var name: String { get }
    /// True when this model runs on this Mac.
    var isLocal: Bool { get }
    /// `json`: ask for a single JSON object.
    func complete(system: String, prompt: String, json: Bool) async throws -> String
}

public enum TextModelError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): m
        case .badResponse(let m): "The model returned something unexpected: \(m)"
        }
    }
}

/// Apple's on-device model (needs Apple Intelligence turned on).
public struct AppleTextModel: TextModel {
    public let name = "Apple on-device"
    public let isLocal = true

    public init() {}

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func complete(system: String, prompt: String, json: Bool) async throws -> String {
        guard Self.isAvailable else { throw TextModelError.unavailable("Apple Intelligence is off.") }
        let session = LanguageModelSession(instructions: system + (json ? "\nReply with one JSON object only." : ""))
        return try await session.respond(to: prompt).content
    }
}

/// A model served by Ollama on localhost.
public struct OllamaTextModel: TextModel {
    public let model: String
    public let baseURL: URL
    public var name: String { "Ollama \(model)" }
    public let isLocal = true

    public static let defaultModel = "qwen3:4b"

    public init(model: String = OllamaTextModel.defaultModel, baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.model = model
        self.baseURL = baseURL
    }

    /// True if Ollama is running and has the model.
    public func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]]
        else { return false }
        return models.contains { ($0["name"] as? String) == model || ($0["model"] as? String) == model }
    }

    public func complete(system: String, prompt: String, json: Bool) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "options": ["temperature": 0],
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        if json { body["format"] = "json" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (obj["message"] as? [String: Any])?["content"] as? String
        else { throw TextModelError.badResponse(String(decoding: data.prefix(200), as: UTF8.self)) }
        return Self.stripThinking(content)
    }

    /// Some models (qwen3) still write their reasoning into the reply, even with thinking off.
    static func stripThinking(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Claude through Claude Code. Not local: text leaves the Mac.
public struct ClaudeTextModel: TextModel {
    public let runner: ClaudeRunner
    public let model: ClaudeRequest.Model
    public var name: String { "Claude \(model.rawValue)" }
    public let isLocal = false

    public init(runner: ClaudeRunner, model: ClaudeRequest.Model = .haiku) {
        self.runner = runner
        self.model = model
    }

    public func complete(system: String, prompt: String, json: Bool) async throws -> String {
        let request = ClaudeRequest(prompt: prompt, model: model,
                                    systemPrompt: system + (json ? "\nReply with one JSON object only. No code fences." : ""),
                                    tools: [], thinking: false, timeout: .seconds(120))
        var final = ""
        for try await event in runner.run(request) {
            if case .result(let r) = event { final = r.text }
        }
        return final
    }
}

/// Which model does background memory work.
public enum BackgroundEngine: String, CaseIterable, Sendable {
    /// Apple on-device, then Ollama. Never leaves the Mac.
    case localOnly
    /// Local first, Claude Code if nothing local is available.
    case localThenClaude
    case claude
    case off

    public var title: String {
        switch self {
        case .localOnly: "On this Mac only"
        case .localThenClaude: "On this Mac, Claude if needed"
        case .claude: "Claude Code"
        case .off: "Off"
        }
    }

    public func resolve(ollama: OllamaTextModel = OllamaTextModel(), claudePath: String?) async -> TextModel? {
        let local: TextModel? = if AppleTextModel.isAvailable { AppleTextModel() } else if await ollama.isAvailable() { ollama } else { nil }
        let claude = claudePath.map { ClaudeTextModel(runner: ClaudeRunner(executablePath: $0)) }
        switch self {
        case .localOnly: return local
        case .localThenClaude: return local ?? claude
        case .claude: return claude
        case .off: return nil
        }
    }
}

enum JSONExtract {
    /// Pulls the first JSON object out of a reply that may have fences or prose around it.
    static func object(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }
}
