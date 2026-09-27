import Foundation

/// Rules shared by everything keybro writes into your fields.
public enum TextCleanup {
    static let emDash = "\u{2014}"
    static let enDash = "\u{2013}"

    /// Em and en dashes read as AI-written. Swap them for commas, unless the user typed them.
    public static func removeDashes(_ text: String, unlessPresentIn original: String = "") -> String {
        if original.contains(emDash) || original.contains(enDash) { return text }
        return text
            .replacingOccurrences(of: " \(emDash) ", with: ", ")
            .replacingOccurrences(of: " \(enDash) ", with: ", ")
            .replacingOccurrences(of: emDash, with: ", ")
            .replacingOccurrences(of: enDash, with: "-")
    }
}
