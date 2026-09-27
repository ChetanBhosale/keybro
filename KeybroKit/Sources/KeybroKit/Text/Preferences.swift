import Foundation

/// How to write in each app family. Editable in Settings; stored in ~/keybro-memory/modes.json.
public struct AppModes: Codable, Equatable, Sendable {
    public var modes: [String: String]

    public init(modes: [String: String] = AppModes.defaults) {
        self.modes = modes
    }

    public static let defaults: [String: String] = [
        "whatsapp": "Casual texting. Short, like a real chat message. Emoji only if the chat already uses them.",
        "imessage": "Casual texting. Short, like a real chat message.",
        "telegram": "Casual texting. Short.",
        "slack": "Work chat. Concise and direct. No greetings or sign-offs.",
        "discord": "Casual chat. Short.",
        "gmail": "Email. Professional but warm. Short paragraphs. Greeting and sign-off only if the thread uses them.",
        "mail": "Email. Professional but warm. Short paragraphs.",
        "linkedin": "LinkedIn. Thoughtful and professional, no hype, no hashtags unless asked.",
        "x": "X/Twitter. Punchy and witty, lowercase is fine, under 280 characters.",
        "linear": "Engineering ticket or comment. Precise and technical.",
    ]

    public func instructions(for surface: String) -> String? {
        modes[surface].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    public static var fileURL: URL { KeybroPaths.memory.appending(path: "modes.json") }
    public static func load(from url: URL = fileURL) -> AppModes { JSONFile.load(url) ?? AppModes() }
    public func save(to url: URL = fileURL) throws { try JSONFile.save(self, to: url) }
}

/// Shortcuts typed in the command bar, like "/standup". Stored in ~/keybro-memory/commands.json.
public struct SavedCommands: Codable, Equatable, Sendable {
    public var commands: [String: String]

    public init(commands: [String: String] = SavedCommands.defaults) {
        self.commands = commands
    }

    public static let defaults: [String: String] = [
        "standup": "Write my standup update (done, doing, blockers) from what's on screen and what I did recently.",
        "followup": "Politely follow up on this. Short.",
        "decline": "Decline politely and briefly, and keep the door open.",
        "thanks": "Thank them. Warm and short.",
        "eta": "Give an update with a new ETA. Short and honest.",
        "summary": "Summarise this conversation for someone who missed it, in 3 short bullets.",
    ]

    /// "/decline too busy this week" -> the decline template plus "too busy this week".
    /// Returns nil when the text isn't a known command.
    public func expand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        guard let template = commands[name] else { return nil }
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? template : "\(template) Details: \(rest)"
    }

    public static var fileURL: URL { KeybroPaths.memory.appending(path: "commands.json") }
    public static func load(from url: URL = fileURL) -> SavedCommands { JSONFile.load(url) ?? SavedCommands() }
    public func save(to url: URL = fileURL) throws { try JSONFile.save(self, to: url) }
}

enum JSONFile {
    static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
