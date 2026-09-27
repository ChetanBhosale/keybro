import Foundation

/// One meaningful line from `claude -p --output-format stream-json`.
public enum ClaudeEvent: Equatable, Sendable {
    case started(sessionID: String, model: String?)
    /// A streamed chunk of the reply (needs `--include-partial-messages`).
    case textDelta(String)
    /// The model is thinking. Useful to show a "thinking" state before text arrives.
    case thinking
    /// A complete assistant text block. Sent after its deltas.
    case assistantText(String)
    case rateLimit(status: String, resetsAt: Date?)
    case result(ClaudeResult)
}

public struct ClaudeResult: Equatable, Sendable {
    public var isError: Bool
    public var text: String
    public var sessionID: String
    public var durationMs: Int?
    public var costUSD: Double?
    public var apiErrorStatus: Int?

    public init(isError: Bool, text: String, sessionID: String, durationMs: Int? = nil, costUSD: Double? = nil, apiErrorStatus: Int? = nil) {
        self.isError = isError
        self.text = text
        self.sessionID = sessionID
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.apiErrorStatus = apiErrorStatus
    }
}

public enum StreamJSONParser {
    /// Parses one NDJSON line. Returns nil for lines keybro doesn't care about.
    public static func parse(_ line: String) -> ClaudeEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "system":
            guard obj["subtype"] as? String == "init" else { return nil }
            return .started(sessionID: obj["session_id"] as? String ?? "", model: obj["model"] as? String)

        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any]
            else { return nil }
            switch delta["type"] as? String {
            case "text_delta": return (delta["text"] as? String).map(ClaudeEvent.textDelta)
            case "thinking_delta": return .thinking
            default: return nil
            }

        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? nil : .assistantText(text)

        case "rate_limit_event":
            let info = obj["rate_limit_info"] as? [String: Any] ?? [:]
            let resetsAt = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return .rateLimit(status: info["status"] as? String ?? "unknown", resetsAt: resetsAt)

        case "result":
            let subtype = obj["subtype"] as? String
            return .result(ClaudeResult(
                isError: obj["is_error"] as? Bool ?? (subtype != "success"),
                text: obj["result"] as? String ?? "",
                sessionID: obj["session_id"] as? String ?? "",
                durationMs: obj["duration_ms"] as? Int,
                costUSD: obj["total_cost_usd"] as? Double,
                apiErrorStatus: obj["api_error_status"] as? Int
            ))

        default:
            return nil
        }
    }
}
