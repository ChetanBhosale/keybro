import Foundation

/// What outside agents (Claude Code over MCP) may read. Lives in ~/keybro-memory/mcp.json.
public struct MemoryScope: Codable, Equatable, Sendable {
    /// Nothing older than this is visible.
    public var maxDays: Int = 90
    /// App families hidden from agents, e.g. ["whatsapp", "imessage"] to keep personal chats out of work sessions.
    public var excludedSurfaces: [String] = []
    /// Allows `remember`.
    public var allowWrite: Bool = true

    public init(maxDays: Int = 90, excludedSurfaces: [String] = [], allowWrite: Bool = true) {
        self.maxDays = maxDays
        self.excludedSurfaces = excludedSurfaces
        self.allowWrite = allowWrite
    }

    public static var fileURL: URL { KeybroPaths.memory.appending(path: "mcp.json") }

    public static func load(from url: URL = fileURL) -> MemoryScope {
        guard let data = try? Data(contentsOf: url) else { return MemoryScope() }
        return (try? JSONDecoder().decode(MemoryScope.self, from: data)) ?? MemoryScope()
    }

    public func save(to url: URL = fileURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    func allows(_ e: Episode, now: Date) -> Bool {
        e.createdAt >= now.addingTimeInterval(-Double(maxDays) * 86_400) && !excludedSurfaces.contains(e.surface)
    }
}

/// Plain-text answers about memory, shared by the MCP server and anything else that asks.
public struct MemoryQuery: Sendable {
    public let store: MemoryStore
    public let search: HybridSearch
    public let scope: MemoryScope

    public init(store: MemoryStore, search: HybridSearch? = nil, scope: MemoryScope = MemoryScope()) {
        self.store = store
        self.search = search ?? HybridSearch(store: store)
        self.scope = scope
    }

    public func searchMemory(_ query: String, days: Int? = nil, limit: Int = 10, now: Date = Date()) async throws -> String {
        let since = days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let hits = try await search.search(query, limit: limit * 2, since: since, now: now)
            .filter { scope.allows($0, now: now) && $0.kind != .draft }
            .prefix(limit)
        guard !hits.isEmpty else { return "Nothing in memory matches \"\(query)\"." }
        return hits.map { line($0, now: now) }.joined(separator: "\n")
    }

    public func person(named name: String, asOf: Date? = nil, now: Date = Date()) throws -> String {
        guard let id = try store.findPerson(named: name), let entity = try store.person(id: id),
              try isVisible(personID: id)
        else {
            return "No one called \(name) in memory."
        }
        var out = "# \(entity.name)\n"
        if let asOf { out += "(as of \(asOf.formatted(date: .abbreviated, time: .omitted)))\n" }
        if asOf == nil, let profile = try store.profile(entityID: id) {
            out += "\n\(profile.summary)\n"
            if !profile.patterns.isEmpty { out += "Patterns: " + profile.patterns.replacingOccurrences(of: "\n", with: "; ") + "\n" }
        }
        let facts = try visible(try store.facts(entityID: id, asOf: asOf))
        if !facts.isEmpty {
            out += "\nFacts:\n" + facts.map { "- \($0.predicate): \($0.object) (since \($0.validFrom.formatted(date: .abbreviated, time: .omitted)))" }.joined(separator: "\n") + "\n"
        }
        let replaced = try visible(try store.factHistory(entityID: id)).filter { !$0.isCurrent }
        if asOf == nil, !replaced.isEmpty {
            out += "\nNo longer true:\n" + replaced.prefix(10).map { "- \($0.predicate): \($0.object) (until \($0.validTo!.formatted(date: .abbreviated, time: .omitted)))" }.joined(separator: "\n") + "\n"
        }
        let loops = try visible(try store.loops(entityID: id)).filter { $0.status == .open }
        if !loops.isEmpty {
            out += "\nOpen promises:\n" + loops.map { "- \($0.text)\($0.dueAt.map { " (due \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? "")" }.joined(separator: "\n") + "\n"
        }
        let messages = try store.episodes(forPerson: id, limit: 30)
            .filter { e in scope.allows(e, now: now) && e.kind != .draft && (asOf.map { e.createdAt <= $0 } ?? true) }
            .prefix(12)
        if !messages.isEmpty {
            out += "\nRecent messages:\n" + messages.map { line($0, now: now) }.joined(separator: "\n") + "\n"
        }
        return out
    }

    public func timeline(days: Int = 1, person: String? = nil, surface: String? = nil, now: Date = Date()) throws -> String {
        let personID = try person.flatMap { try store.findPerson(named: $0) }
        if person != nil && personID == nil { return "No one called \(person!) in memory." }
        let items = try store.episodes(from: now.addingTimeInterval(-Double(days) * 86_400), to: now.addingTimeInterval(1))
            .filter { scope.allows($0, now: now) }
            .filter { personID == nil || $0.entityID == personID }
            .filter { surface == nil || $0.surface == surface }
        guard !items.isEmpty else { return "Nothing in the last \(days) day\(days == 1 ? "" : "s")." }
        return items.suffix(80).map { line($0, now: now) }.joined(separator: "\n")
    }

    public func openLoops(now: Date = Date()) throws -> String {
        let loops = try visible(try store.openLoops())
        guard !loops.isEmpty else { return "No open promises." }
        return loops.map { l in
            let due = l.dueAt.map { $0 < now ? " (OVERDUE, was due \($0.formatted(date: .abbreviated, time: .omitted)))" : " (due \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""
            return "- #\(l.id!) \(l.text)\(l.person.map { " to \($0)" } ?? "")\(due)"
        }.joined(separator: "\n")
    }

    public func today(now: Date = Date(), calendar: Calendar = .current) throws -> String {
        let start = calendar.startOfDay(for: now)
        var out = "# Today, \(now.formatted(date: .complete, time: .omitted))\n"
        // A digest mixes every app, so it's only shown when nothing is hidden.
        if scope.excludedSurfaces.isEmpty, let digest = try store.digest(day: Consolidator.dayKey(now, calendar: calendar)) {
            out += "\nDigest:\n\(digest)\n"
        }
        let items = try store.episodes(from: start, to: now.addingTimeInterval(1), kinds: [.sent, .generate, .note, .fix])
            .filter { scope.allows($0, now: now) }
        out += items.isEmpty ? "\nNothing sent yet today.\n" : "\nWhat I wrote today:\n" + items.suffix(60).map { line($0, now: now) }.joined(separator: "\n") + "\n"
        let due = try visible(try store.openLoops()).filter { ($0.dueAt ?? .distantFuture) < start.addingTimeInterval(2 * 86_400) }
        if !due.isEmpty { out += "\nPromises due soon:\n" + due.map { "- \($0.text)\($0.person.map { " to \($0)" } ?? "")" }.joined(separator: "\n") + "\n" }
        return out
    }

    public func remember(_ text: String, person: String? = nil, now: Date = Date()) throws -> String {
        guard scope.allowWrite else { return "Writing to memory is turned off in ~/keybro-memory/mcp.json." }
        let clean = SecretRedactor.redact(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty else { return "Nothing to remember." }
        guard !SensitiveContent.shouldSkip(text: clean, windowTitle: nil, contact: person) else { return "Not saved: keybro doesn't store that kind of content." }
        let entityID = try person.flatMap { try store.findPerson(named: $0) ?? store.resolvePerson(named: $0, surface: "note") }
        try store.insert(Episode(kind: .note, appName: "Claude Code", surface: "note", entityID: entityID, contactRaw: person, text: clean, createdAt: now))
        return "Saved."
    }

    // MARK: Scope

    /// Hidden when every app this person appears in is excluded.
    func isVisible(personID: Int64) throws -> Bool {
        guard !scope.excludedSurfaces.isEmpty else { return true }
        let surfaces = try store.people().first { $0.id == personID }?.surfaces ?? []
        return surfaces.isEmpty || !surfaces.allSatisfy { scope.excludedSurfaces.contains($0) }
    }

    /// Drops facts learned from hidden apps.
    func visible(_ facts: [Fact]) throws -> [Fact] {
        guard !scope.excludedSurfaces.isEmpty else { return facts }
        let sources = Dictionary(uniqueKeysWithValues: try store.episodes(ids: facts.compactMap(\.sourceEpisodeID)).map { ($0.id!, $0.surface) })
        return facts.filter { f in f.sourceEpisodeID.flatMap { sources[$0] }.map { !scope.excludedSurfaces.contains($0) } ?? true }
    }

    /// Drops promises made in hidden apps.
    func visible(_ loops: [OpenLoop]) throws -> [OpenLoop] {
        guard !scope.excludedSurfaces.isEmpty else { return loops }
        let sources = Dictionary(uniqueKeysWithValues: try store.episodes(ids: loops.compactMap(\.sourceEpisodeID)).map { ($0.id!, $0.surface) })
        return loops.filter { l in l.sourceEpisodeID.flatMap { sources[$0] }.map { !scope.excludedSurfaces.contains($0) } ?? true }
    }

    func line(_ e: Episode, now: Date) -> String {
        let when = e.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let who = e.contactRaw.map { " to \($0)" } ?? ""
        let kind = e.kind == .sent ? "" : " [\(e.kind.rawValue)]"
        return "- \(when)\(who) (\(e.surface))\(kind): \(e.text.replacingOccurrences(of: "\n", with: " ").prefix(500))"
    }
}
