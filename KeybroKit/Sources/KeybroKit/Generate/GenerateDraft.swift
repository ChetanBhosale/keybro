import Foundation

public enum DraftVariant: String, CaseIterable, Sendable {
    case casual, safe, bold

    public var title: String { rawValue.capitalized }
}

/// The three versions Claude writes, filled in as the reply streams.
public struct GenerateDraft: Equatable, Sendable {
    public var contact: String?
    /// Set for questions about the screen instead of variants.
    public var answer: String?
    public var variants: [DraftVariant: String] = [:]
    /// Variants whose closing tag has arrived.
    public var finished: Set<DraftVariant> = []

    public init(contact: String? = nil, variants: [DraftVariant: String] = [:], finished: Set<DraftVariant> = []) {
        self.contact = contact
        self.variants = variants
        self.finished = finished
    }

    public var isEmpty: Bool { variants.values.allSatisfy { $0.isEmpty } && (answer ?? "").isEmpty }

    /// Parses a partial or complete reply. Unclosed tags yield their text so far.
    /// `final`: the reply is complete; untagged text becomes the casual version.
    public static func parse(_ raw: String, final: Bool = false) -> GenerateDraft {
        var draft = GenerateDraft()
        if let (contact, closed) = tag("contact", in: raw), closed {
            let name = contact.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.contact = name.isEmpty ? nil : name
        }
        if let (text, _) = tag("answer", in: raw) {
            let cleaned = TextCleanup.removeDashes(text.trimmingCharacters(in: .whitespacesAndNewlines))
            draft.answer = cleaned.isEmpty ? nil : cleaned
        }
        for variant in DraftVariant.allCases {
            guard let (text, closed) = tag(variant.rawValue, in: raw) else { continue }
            let cleaned = TextCleanup.removeDashes(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if !cleaned.isEmpty { draft.variants[variant] = cleaned }
            if closed { draft.finished.insert(variant) }
        }
        if final, draft.isEmpty {
            let plain = TextCleanup.removeDashes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if !plain.isEmpty, !plain.contains("<") {
                draft.variants[.casual] = plain
                draft.finished.insert(.casual)
            }
        }
        return draft
    }

    private static func tag(_ name: String, in raw: String) -> (String, Bool)? {
        guard let open = raw.range(of: "<\(name)>") else { return nil }
        let rest = raw[open.upperBound...]
        if let close = rest.range(of: "</\(name)>") {
            return (String(rest[..<close.lowerBound]), true)
        }
        // Still streaming: drop a half-written closing tag like "</cas".
        var text = String(rest)
        if let lt = text.lastIndex(of: "<"), "</\(name)>".hasPrefix(String(text[lt...])) {
            text = String(text[..<lt])
        }
        return (text, false)
    }
}
