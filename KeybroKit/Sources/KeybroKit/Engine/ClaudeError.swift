import Foundation

public enum ClaudeError: Error, Equatable, Sendable, LocalizedError {
    case notFound
    case launchFailed(String)
    case notLoggedIn
    case rateLimited(String)
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Claude Code wasn't found. Install it, or pick the claude binary in Settings."
        case .launchFailed(let detail):
            "Couldn't start Claude Code (\(detail))."
        case .notLoggedIn:
            "Claude Code isn't logged in. Run `claude` in Terminal and log in, then try again."
        case .rateLimited(let detail):
            "You've hit your Claude plan's usage limit. \(detail)"
        case .timedOut:
            "Claude Code took too long to answer. Try again."
        case .failed(let detail):
            "Claude Code failed: \(detail)"
        }
    }

    /// Maps a failed run to an error the user can act on.
    public static func classify(exitCode: Int32, stderr: String, resultText: String?, apiErrorStatus: Int?, timedOut: Bool) -> ClaudeError {
        if timedOut { return .timedOut }
        let haystack = (stderr + "\n" + (resultText ?? "")).lowercased()
        if apiErrorStatus == 401
            || haystack.contains("not logged in")
            || haystack.contains("/login")
            || haystack.contains("invalid api key")
            || haystack.contains("oauth token") {
            return .notLoggedIn
        }
        if apiErrorStatus == 429
            || haystack.contains("rate limit")
            || haystack.contains("usage limit") {
            return .rateLimited(firstLine(resultText) ?? "")
        }
        let detail = firstLine(resultText) ?? firstLine(stderr) ?? "exit code \(exitCode)"
        return .failed(detail)
    }

    private static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }
}
