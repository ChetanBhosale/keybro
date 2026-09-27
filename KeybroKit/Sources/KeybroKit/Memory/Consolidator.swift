import Foundation

/// The nightly "sleep" job: reads new messages and turns them into facts, promises,
/// profiles and a daily digest. Uses whatever `TextModel` the user allows (local by default).
public actor Consolidator {
    public struct Report: Equatable, Sendable {
        public var processed = 0
        public var facts = 0
        public var loopsAdded = 0
        public var loopsClosed = 0
        public var profiles = 0
        public var merged = 0
        public var digest: String?
        public var errors: [String] = []
    }

    private let store: MemoryStore
    private let model: TextModel
    /// Messages per model call. Small local models lose track beyond this.
    private let chunkSize: Int

    public init(store: MemoryStore, model: TextModel, chunkSize: Int = 20) {
        self.store = store
        self.model = model
        self.chunkSize = chunkSize
    }

    public func run(now: Date = Date(), calendar: Calendar = .current) async -> Report {
        var report = Report()
        report.merged = (try? store.mergeDuplicatePeople()) ?? 0

        let pending = (try? store.unprocessedEpisodes(limit: 300)) ?? []
        for chunk in stride(from: 0, to: pending.count, by: chunkSize).map({ Array(pending[$0..<min($0 + chunkSize, pending.count)]) }) {
            do {
                let (facts, loops) = try await extract(chunk, now: now, calendar: calendar)
                report.facts += facts
                report.loopsAdded += loops
                try store.markProcessed(chunk.compactMap(\.id), at: now)
                report.processed += chunk.count
            } catch {
                report.errors.append(error.localizedDescription)
            }
        }

        if !pending.isEmpty {
            do { report.loopsClosed = try await closeLoops(recent: pending, now: now) } catch { report.errors.append(error.localizedDescription) }
            let people = Set(pending.compactMap(\.entityID)).sorted()
            for id in people.prefix(15) {
                do { if try await updateProfile(entityID: id, now: now) { report.profiles += 1 } } catch { report.errors.append(error.localizedDescription) }
            }
        }

        do { report.digest = try await writeDigest(for: now, calendar: calendar) } catch { report.errors.append(error.localizedDescription) }
        return report
    }

    // MARK: Extraction

    static let extractSystem = """
    You read messages a person SENT from their Mac and pull out lasting facts and promises.
    Return JSON: {"facts":[{"subject":"<person name, or me>","predicate":"<snake_case>","object":"<value>"}],
                  "promises":[{"to":"<person name>","text":"<what I promised, short, starting with a verb>","due":"<YYYY-MM-DD or null>"}]}
    Rules:
    - "me" is the person who sent the messages.
    - Facts must be stable and useful later: where someone lives or works, relationships, preferences, birthdays, plans with dates. Skip small talk.
    - Use predicates like lives_in, works_at, job_title, relationship, likes, dislikes, birthday, plans.
    - A promise is something I said I will do for someone ("I'll send the deck by Friday"). Not their promises, not questions.
    - Resolve dates with the calendar given. Use null if there is no date.
    - Only use information in the messages. Return {"facts":[],"promises":[]} if nothing qualifies.
    - A message "to X" is written BY me TO X. Congratulating X on something is a fact about X, not me.

    Example input:
    [.. to Sam, whatsapp] congrats on joining Stripe! miss you since you moved to Berlin
    [.. to Sam, whatsapp] ill call you tomorrow
    Example output:
    {"facts":[{"subject":"Sam","predicate":"works_at","object":"Stripe"},{"subject":"Sam","predicate":"lives_in","object":"Berlin"}],
     "promises":[{"to":"Sam","text":"Call Sam","due":"<tomorrow's date>"}]}
    """

    func extract(_ episodes: [Episode], now: Date, calendar: Calendar) async throws -> (facts: Int, loops: Int) {
        let prompt = Self.calendarLines(now: now, calendar: calendar) + "\n\nMessages:\n" + episodes.map(Self.describe).joined(separator: "\n")
        let reply = try await model.complete(system: Self.extractSystem, prompt: prompt, json: true)
        guard let json = JSONExtract.object(from: reply) else { throw TextModelError.badResponse(String(reply.prefix(120))) }
        let byContact = Dictionary(episodes.compactMap { e in e.contactRaw.map { (MemoryStore.normalize($0), e) } }, uniquingKeysWith: { a, _ in a })

        var factCount = 0
        for f in json["facts"] as? [[String: Any]] ?? [] {
            guard let subject = (f["subject"] as? String)?.trimmingCharacters(in: .whitespaces), !subject.isEmpty,
                  let predicate = f["predicate"] as? String, let object = Self.stringValue(f["object"]) else { continue }
            let isMe = ["me", "i", "myself", "user"].contains(subject.lowercased())
            let source = isMe ? episodes.last : byContact[MemoryStore.normalize(subject)] ?? episodes.last
            let entityID = isMe ? nil : try store.resolvePerson(named: subject, surface: source?.surface ?? "unknown")
            if try store.addFact(subject: isMe ? "me" : subject, entityID: entityID, predicate: predicate, object: object,
                                 validFrom: source?.createdAt ?? now, sourceEpisodeID: source?.id, now: now) != nil {
                factCount += 1
            }
        }

        var loopCount = 0
        for p in json["promises"] as? [[String: Any]] ?? [] {
            guard let text = (p["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 4 else { continue }
            let to = (p["to"] as? String)?.trimmingCharacters(in: .whitespaces)
            let source = to.flatMap { byContact[MemoryStore.normalize($0)] } ?? episodes.last
            let entityID = try to.flatMap { name in try store.findPerson(named: name) ?? store.resolvePerson(named: name, surface: source?.surface ?? "unknown") }
            let due = Self.date(from: p["due"], calendar: calendar).flatMap { d in d >= calendar.startOfDay(for: now).addingTimeInterval(-86_400) ? d : nil }
            let loop = OpenLoop(id: nil, entityID: entityID, person: to, text: text, dueAt: due, status: .open, createdAt: source?.createdAt ?? now,
                                sourceEpisodeID: source?.id, closedAt: nil, notifiedAt: nil)
            if try store.addLoop(loop) != nil { loopCount += 1 }
        }
        return (factCount, loopCount)
    }

    // MARK: Loops

    static let closeSystem = """
    You check which of my open promises are done, based on messages I sent later.
    Return JSON: {"done":[<loop ids>]}. Only include a loop if a later message clearly shows I did it. Return {"done":[]} if unsure.
    """

    func closeLoops(recent: [Episode], now: Date) async throws -> Int {
        let open = try store.openLoops()
        guard !open.isEmpty else { return 0 }
        let prompt = "Open promises:\n" + open.prefix(30).map { "#\($0.id!) to \($0.person ?? "someone"): \($0.text)" }.joined(separator: "\n")
            + "\n\nLater messages:\n" + recent.suffix(40).map(Self.describe).joined(separator: "\n")
        let reply = try await model.complete(system: Self.closeSystem, prompt: prompt, json: true)
        let ids = (JSONExtract.object(from: reply)?["done"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value ?? Int64("\($0)") }
        let valid = Set(open.compactMap(\.id))
        var closed = 0
        for id in ids where valid.contains(id) {
            try store.setLoop(id, status: .done, at: now)
            closed += 1
        }
        return closed
    }

    // MARK: Profiles

    static let profileSystem = """
    Write a short profile of one person in my life, from my messages to them and known facts.
    Return JSON: {"summary":"<2-3 sentences: who they are to me, what's going on with them>","patterns":["<habit or pattern, if clearly visible>"]}
    Plain, specific, no speculation. Patterns only when several messages show them; otherwise [].
    """

    func updateProfile(entityID: Int64, now: Date) async throws -> Bool {
        guard let person = try store.person(id: entityID) else { return false }
        let messages = try store.episodes(forPerson: entityID, limit: 25).filter { $0.kind != .draft && $0.kind != .fix }
        guard !messages.isEmpty else { return false }
        let facts = try store.facts(entityID: entityID)
        let prompt = "Person: \(person.name)\nKnown facts:\n" + (facts.isEmpty ? "(none)" : facts.map { "- \($0.predicate): \($0.object)" }.joined(separator: "\n"))
            + "\n\nMy recent messages with them (newest first):\n" + messages.map(Self.describe).joined(separator: "\n")
        let reply = try await model.complete(system: Self.profileSystem, prompt: prompt, json: true)
        guard let json = JSONExtract.object(from: reply), let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty
        else { throw TextModelError.badResponse(String(reply.prefix(120))) }
        let patterns = (json["patterns"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try store.setProfile(PersonProfile(entityID: entityID, summary: TextCleanup.removeDashes(summary),
                                           patterns: patterns.map { TextCleanup.removeDashes($0) }.joined(separator: "\n"), updatedAt: now))
        return true
    }

    // MARK: Digest

    static let digestSystem = """
    Summarise my day from the messages I sent. 3 to 6 short bullets, each starting with "- ".
    Group by person or topic. Mention decisions, plans and promises. Plain text, no headings.
    """

    func writeDigest(for now: Date, calendar: Calendar) async throws -> String? {
        let start = calendar.startOfDay(for: now)
        let messages = try store.episodes(from: start, to: start.addingTimeInterval(86_400))
        guard messages.count >= 2 else { return nil }
        let prompt = messages.suffix(80).map(Self.describe).joined(separator: "\n")
        let reply = try await model.complete(system: Self.digestSystem, prompt: prompt, json: false)
        let text = TextCleanup.removeDashes(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return nil }
        try store.setDigest(day: Self.dayKey(now, calendar: calendar), text: text, at: now)
        return text
    }

    // MARK: Helpers

    static func describe(_ e: Episode) -> String {
        let to = e.contactRaw.map { " to \($0)" } ?? ""
        let when = e.createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
        return "[\(when)\(to), \(e.surface)] \(e.text.replacingOccurrences(of: "\n", with: " ").prefix(400))"
    }

    /// Small models get dates wrong; give them the answers.
    static func calendarLines(now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE yyyy-MM-dd"
        let days = (0..<8).map { i -> String in
            let d = calendar.date(byAdding: .day, value: i, to: now)!
            return (i == 0 ? "Today: " : i == 1 ? "Tomorrow: " : "") + f.string(from: d)
        }
        return "Calendar:\n" + days.joined(separator: "\n")
    }

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func date(from value: Any?, calendar: Calendar) -> Date? {
        guard let s = value as? String, s.count == 10 else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 18))
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }
}
