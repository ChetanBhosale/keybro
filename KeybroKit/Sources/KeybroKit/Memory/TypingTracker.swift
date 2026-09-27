import Foundation

/// A reading of the focused text field, taken about once a second.
public struct FieldSample: Equatable, Sendable {
    /// Identifies the field (app + element), so switching fields starts a new draft.
    public var fieldKey: String
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var value: String
    public var at: Date

    public init(fieldKey: String, bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil, value: String, at: Date) {
        self.fieldKey = fieldKey
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.value = value
        self.at = at
    }
}

/// Turns field samples into memory events. Pure logic, no Accessibility, so it's testable.
///
/// - After you pause typing (2s by default) the text is saved as a draft.
/// - When a non-empty field is suddenly empty (you hit send) the draft becomes `sent`.
/// - Switching fields keeps whatever you had as a draft.
public struct TypingTracker: Sendable {
    public enum Event: Equatable, Sendable {
        /// Save or update the draft for this field.
        case draft(key: String, text: String, sample: FieldSample)
        /// The draft was sent.
        case sent(key: String, text: String, sample: FieldSample)
    }

    public var debounce: TimeInterval
    /// Shorter texts aren't worth remembering ("ok", "k").
    public var minimumLength: Int
    /// Beyond this it's a document, not a message. Skipped.
    public var maximumLength: Int

    private var current: (sample: FieldSample, changedAt: Date, savedText: String?)?

    public init(debounce: TimeInterval = 2, minimumLength: Int = 3, maximumLength: Int = 4000) {
        self.debounce = debounce
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
    }

    public mutating func observe(_ sample: FieldSample?) -> [Event] {
        var events: [Event] = []

        guard let sample else {
            // Focus left any text field: keep what was typed.
            events += flush()
            current = nil
            return events
        }

        guard let prev = current, prev.sample.fieldKey == sample.fieldKey else {
            events += flush()
            current = (sample, sample.at, nil)
            return events
        }

        let before = prev.sample.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = sample.value.trimmingCharacters(in: .whitespacesAndNewlines)

        if now.isEmpty, before.count >= minimumLength, before.count <= maximumLength {
            // Non-empty to empty in one step: sent. (Backspacing shrinks gradually.)
            events.append(.sent(key: sample.fieldKey, text: before, sample: prev.sample))
            current = (sample, sample.at, nil)
            return events
        }

        if sample.value != prev.sample.value {
            current = (sample, sample.at, prev.savedText)
        } else if sample.at.timeIntervalSince(prev.changedAt) >= debounce,
                  now.count >= minimumLength, now.count <= maximumLength, now != prev.savedText {
            events.append(.draft(key: sample.fieldKey, text: now, sample: sample))
            current = (sample, prev.changedAt, now)
        } else {
            current = (sample, prev.changedAt, prev.savedText)
        }
        return events
    }

    private func flush() -> [Event] {
        guard let prev = current else { return [] }
        let text = prev.sample.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumLength, text.count <= maximumLength, text != prev.savedText else { return [] }
        return [.draft(key: prev.sample.fieldKey, text: text, sample: prev.sample)]
    }
}
