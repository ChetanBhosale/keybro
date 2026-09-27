import Foundation

/// Where a conversation happens and who it's with, worked out from the app and its window title.
public struct Conversation: Equatable, Sendable {
    /// App family: "whatsapp", "slack", "imessage", ... or the bundle id for anything else.
    public var surface: String
    public var contact: String?
}

public enum ContactResolver {
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static let surfaces: [String: String] = [
        "net.whatsapp.WhatsApp": "whatsapp",
        "desktop.WhatsApp": "whatsapp",
        "com.tinyspeck.slackmacgap": "slack",
        "com.apple.MobileSMS": "imessage",
        "com.hnc.Discord": "discord",
        "ru.keepcoder.Telegram": "telegram",
        "org.telegram.desktop": "telegram",
        "com.apple.mail": "mail",
        "com.linear": "linear",
        "com.microsoft.teams2": "teams",
    ]

    /// Web apps recognised from the browser tab title.
    static let webApps: [(needle: String, surface: String)] = [
        ("WhatsApp", "whatsapp"), ("Slack", "slack"), ("Gmail", "gmail"), ("Discord", "discord"),
        ("Telegram", "telegram"), ("LinkedIn", "linkedin"), (" / X", "x"), ("Messenger", "messenger"),
    ]

    public static func resolve(bundleID: String?, windowTitle: String?) -> Conversation {
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var surface = bundleID.flatMap { surfaces[$0] } ?? bundleID ?? "unknown"
        if let bundleID, browsers.contains(bundleID) {
            surface = webApps.first { title.contains($0.needle) }?.surface ?? "web"
        }
        return Conversation(surface: surface, contact: contact(surface: surface, title: title))
    }

    /// Only for titles known to carry the conversation name. Everything else stays unknown
    /// rather than guessing; Generate fills it in from the screenshot.
    static func contact(surface: String, title: String) -> String? {
        switch surface {
        case "slack":
            // "Rahul (DM) - Linkrunner - Slack", "#eng (Channel) - Linkrunner - Slack"
            guard let first = title.components(separatedBy: " - ").first, first != "Slack" else { return nil }
            return clean(first.replacingOccurrences(of: #"\s*\((DM|Channel|Private channel|Group DM)\)"#, with: "", options: .regularExpression))
        case "discord":
            // "@rahul - Discord", "#general | Server - Discord"
            guard title.hasSuffix(" - Discord") else { return nil }
            let head = String(title.dropLast(" - Discord".count)).components(separatedBy: " | ").first ?? ""
            return clean(head.hasPrefix("@") ? String(head.dropFirst()) : head)
        case "telegram":
            guard title != "Telegram", !title.isEmpty else { return nil }
            return clean(title.replacingOccurrences(of: #"\s*[–-]\s*\(?\d+\)?$"#, with: "", options: .regularExpression))
        default:
            return nil
        }
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
