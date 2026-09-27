import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌘⇧L also means something in Safari, VS Code and Bitwarden. Remap from the menu bar.
    static let fix = Self("fix", default: .init(.l, modifiers: [.command, .shift]))
}

extension KeyboardShortcuts.Name {
    /// ⌘⇧K also means something in Slack, VS Code and Xcode. Remap from the menu bar.
    static let generate = Self("generate", default: .init(.k, modifiers: [.command, .shift]))
}
