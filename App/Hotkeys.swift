import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌘⇧L also means something in Safari, VS Code and Bitwarden. Remap from the menu bar.
    static let fix = Self("fix", default: .init(.l, modifiers: [.command, .shift]))
}
