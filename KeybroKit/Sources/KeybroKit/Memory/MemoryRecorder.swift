import Foundation

/// Writes what happens into memory: typed drafts and sent messages, fixes, generated replies.
/// Everything passes through `SecretRedactor` first.
public actor MemoryRecorder {
    public let store: MemoryStore
    private var tracker: TypingTracker
    private var draftIDs: [String: Int64] = [:]
    /// Contact names Claude read from a screenshot, per window, for apps whose title doesn't say.
    private var learnedContacts: [String: String] = [:]

    public init(store: MemoryStore, tracker: TypingTracker = TypingTracker()) {
        self.store = store
        self.tracker = tracker
    }

    public func observe(_ sample: FieldSample?) {
        for event in tracker.observe(sample) {
            do { try handle(event) } catch { /* A failed write shouldn't break typing. */ }
        }
    }

    private func handle(_ event: TypingTracker.Event) throws {
        switch event {
        case .draft(let key, let text, let sample):
            let text = SecretRedactor.redact(text)
            if let id = draftIDs[key], try store.episode(id: id) != nil {
                try store.update(episodeID: id, text: text, at: sample.at)
            } else {
                draftIDs[key] = try store.insert(episode(.draft, text: text, sample: sample)).id
            }

        case .sent(let key, let text, let sample):
            let text = SecretRedactor.redact(text)
            defer { draftIDs[key] = nil }
            let conversation = conversation(bundleID: sample.bundleID, windowTitle: sample.windowTitle)
            // Inserted by Generate and then sent: mark that episode instead of storing it twice.
            if let generated = try recentGenerate(matching: text, surface: conversation.surface, before: sample.at) {
                try store.update(episodeID: generated, text: text, kind: .sent, at: sample.at)
                if let id = draftIDs[key] { try store.deleteEpisode(id: id) }
                return
            }
            if let id = draftIDs[key], try store.episode(id: id) != nil {
                try store.update(episodeID: id, text: text, kind: .sent, at: sample.at)
            } else {
                try store.insert(episode(.sent, text: text, sample: sample))
            }
        }
    }

    private func recentGenerate(matching text: String, surface: String, before date: Date) throws -> Int64? {
        try store.recentEpisodes(limit: 20).first {
            $0.kind == .generate && $0.surface == surface && $0.text == text && date.timeIntervalSince($0.createdAt) < 600
        }?.id
    }

    private func episode(_ kind: Episode.Kind, text: String, sample: FieldSample) throws -> Episode {
        let conversation = conversation(bundleID: sample.bundleID, windowTitle: sample.windowTitle)
        let person = try conversation.contact.flatMap { try store.resolvePerson(named: $0, surface: conversation.surface) }
        return Episode(kind: kind, bundleID: sample.bundleID, appName: sample.appName, surface: conversation.surface,
                       entityID: person, contactRaw: conversation.contact, text: text, createdAt: sample.at)
    }

    public func conversation(bundleID: String?, windowTitle: String?) -> Conversation {
        var conversation = ContactResolver.resolve(bundleID: bundleID, windowTitle: windowTitle)
        if conversation.contact == nil {
            conversation.contact = learnedContacts[Self.windowKey(conversation.surface, windowTitle)]
        }
        return conversation
    }

    /// Generate read the contact from the screenshot; remember it for this window.
    public func learnContact(_ name: String, bundleID: String?, windowTitle: String?) {
        let surface = ContactResolver.resolve(bundleID: bundleID, windowTitle: windowTitle).surface
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        learnedContacts[Self.windowKey(surface, windowTitle)] = trimmed
    }

    private static func windowKey(_ surface: String, _ title: String?) -> String { "\(surface)|\(title ?? "")" }

    public func recordFix(fixed: String, target: TextTarget, at date: Date = Date()) {
        record(.fix, text: fixed, target: target, contact: nil, at: date)
    }

    public func recordGenerate(inserted: String, target: TextTarget, contact: String?, at date: Date = Date()) {
        if let contact { learnContact(contact, bundleID: target.bundleID, windowTitle: target.windowTitle) }
        record(.generate, text: inserted, target: target, contact: contact, at: date)
    }

    private func record(_ kind: Episode.Kind, text: String, target: TextTarget, contact: String?, at date: Date) {
        var conversation = conversation(bundleID: target.bundleID, windowTitle: target.windowTitle)
        if let contact { conversation.contact = contact }
        let text = SecretRedactor.redact(text)
        do {
            let person = try conversation.contact.flatMap { try store.resolvePerson(named: $0, surface: conversation.surface) }
            try store.insert(Episode(kind: kind, bundleID: target.bundleID, appName: target.appName, surface: conversation.surface,
                                     entityID: person, contactRaw: conversation.contact, text: text, createdAt: date))
        } catch {}
    }

    /// Memory to hand Generate for this conversation and instruction.
    public func context(instruction: String, target: TextTarget) -> String? {
        let conversation = conversation(bundleID: target.bundleID, windowTitle: target.windowTitle)
        return try? ContextBuilder.build(store: store, instruction: instruction, contact: conversation.contact, surface: conversation.surface)
    }
}

public enum ContextBuilder {
    static let maxCharacters = 1500
    static let maxLineCharacters = 220

    /// Recent messages with the person (from the window or named in the instruction),
    /// plus older messages that share words with the instruction.
    public static func build(store: MemoryStore, instruction: String, contact: String?, surface: String, now: Date = Date()) throws -> String? {
        var people: [Entity] = []
        if let contact, let id = try store.findPerson(named: contact), let entity = try store.person(id: id) {
            people.append(entity)
        }
        for entity in try store.peopleMentioned(in: instruction) where !people.contains(where: { $0.id == entity.id }) {
            people.append(entity)
        }

        var sections: [String] = []
        var seen = Set<Int64>()
        for person in people.prefix(2) {
            let episodes = try store.episodes(forPerson: person.id!, limit: 8).filter { $0.kind != .draft && $0.kind != .fix }
            guard !episodes.isEmpty else { continue }
            episodes.forEach { seen.insert($0.id!) }
            sections.append("Your recent messages with \(person.name):\n" + episodes.map { line($0, now: now) }.joined(separator: "\n"))
        }

        let related = try store.search(instruction, limit: 6).filter { !seen.contains($0.id!) && $0.kind != .draft }
        if !related.isEmpty {
            sections.append("Related things you wrote before:\n" + related.prefix(4).map { line($0, now: now) }.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return nil }
        let text = sections.joined(separator: "\n\n")
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "…" : text
    }

    static func line(_ e: Episode, now: Date) -> String {
        let text = e.text.count > maxLineCharacters ? String(e.text.prefix(maxLineCharacters)) + "…" : e.text
        let where_ = e.contactRaw.map { "to \($0), " } ?? ""
        return "- (\(where_)\(e.surface), \(relative(e.createdAt, now: now))) \(text.replacingOccurrences(of: "\n", with: " "))"
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<3600: return "\(max(1, Int(seconds / 60)))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}
