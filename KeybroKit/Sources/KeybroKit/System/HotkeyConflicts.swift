import Foundation

/// Well-known shortcuts other apps already use, so Settings can warn before you pick one.
public enum HotkeyConflicts {
    public struct Combo: Hashable, Sendable {
        public var key: String
        public var command: Bool
        public var shift: Bool
        public var option: Bool
        public var control: Bool

        public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
            self.key = key.lowercased()
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }
    }

    static let known: [Combo: [String]] = [
        Combo(key: "k", command: true, shift: true): ["Slack (open DM)", "VS Code (delete line)", "Xcode (clean build)"],
        Combo(key: "l", command: true, shift: true): ["Safari (sidebar)", "VS Code (select all matches)", "Bitwarden (autofill)"],
        Combo(key: "k", command: true): ["Slack (jump to)", "Notion, Linear and most editors (insert link)"],
        Combo(key: "l", command: true): ["Browsers (address bar)"],
        Combo(key: "space", command: true): ["Spotlight"],
        Combo(key: "space", option: true): ["ChatGPT and Raycast (common default)"],
        Combo(key: "space", control: true): ["Input source switching"],
        Combo(key: "g", command: true, shift: true): ["Finder (go to folder)"],
        Combo(key: "a", command: true, shift: true): ["Slack (all unreads)", "Chrome (search tabs)"],
        Combo(key: "4", command: true, shift: true): ["macOS screenshot"],
        Combo(key: "5", command: true, shift: true): ["macOS screenshot"],
    ]

    public static func apps(for combo: Combo) -> [String] {
        known[combo] ?? []
    }
}
