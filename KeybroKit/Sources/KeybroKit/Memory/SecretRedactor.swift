import Foundation

/// Removes things that must never sit in a plain-text memory: API keys, tokens, card numbers, OTPs.
public enum SecretRedactor {
    static let placeholder = "[redacted]"

    private static let patterns: [NSRegularExpression] = [
        #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#,           // OpenAI / Anthropic keys
        #"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#, // GitHub tokens
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,                     // Slack tokens
        #"\bAKIA[0-9A-Z]{16}\b"#,                                // AWS access key id
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,                          // Google API key
        #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"#, // JWT
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]\s*\S+"#,
        #"(?i)\b(?:otp|code|pin)\b[^\d\n]{0,20}\b\d{4,8}\b"#,    // "your OTP is 482913"
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Long random-looking strings: 32+ chars mixing letters and digits.
    private static let token = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-]{32,}\b"#)
    /// 13-19 digit runs, spaces or dashes allowed, checked with Luhn.
    private static let card = try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){12,18}\d\b"#)

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = replace(pattern, in: result) { _ in true }
        }
        result = replace(token, in: result) { match in
            match.rangeOfCharacter(from: .decimalDigits) != nil && match.rangeOfCharacter(from: .letters) != nil
        }
        result = replace(card, in: result) { match in luhn(match.filter(\.isNumber)) }
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, when shouldRedact: (String) -> Bool) -> String {
        let ns = text as NSString
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let found = ns.substring(with: match.range)
            guard shouldRedact(found), let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: placeholder)
        }
        return output
    }

    static func luhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}
