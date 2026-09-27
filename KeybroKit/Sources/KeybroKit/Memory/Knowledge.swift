import Foundation
import GRDB

/// A fact about a person (or you), valid for a period. Old values are closed, never deleted.
public struct Fact: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var entityID: Int64?
    /// Person name, or "me".
    public var subject: String
    public var predicate: String
    public var object: String
    public var validFrom: Date
    public var validTo: Date?
    public var recordedAt: Date
    public var supersededBy: Int64?
    public var sourceEpisodeID: Int64?

    public static let databaseTableName = "facts"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var isCurrent: Bool { validTo == nil }
}

public struct OpenLoop: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public enum Status: String, Codable, Sendable { case open, done, dropped }

    public var id: Int64?
    public var entityID: Int64?
    public var person: String?
    public var text: String
    public var dueAt: Date?
    public var status: Status
    public var createdAt: Date
    public var sourceEpisodeID: Int64?
    public var closedAt: Date?
    public var notifiedAt: Date?

    public static let databaseTableName = "loops"

    public init(id: Int64? = nil, entityID: Int64?, person: String?, text: String, dueAt: Date?, status: Status = .open,
                createdAt: Date, sourceEpisodeID: Int64? = nil, closedAt: Date? = nil, notifiedAt: Date? = nil) {
        self.id = id
        self.entityID = entityID
        self.person = person
        self.text = text
        self.dueAt = dueAt
        self.status = status
        self.createdAt = createdAt
        self.sourceEpisodeID = sourceEpisodeID
        self.closedAt = closedAt
        self.notifiedAt = notifiedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PersonProfile: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var entityID: Int64
    public var summary: String
    /// One pattern per line.
    public var patterns: String
    public var updatedAt: Date

    public static let databaseTableName = "profiles"

    public init(entityID: Int64, summary: String, patterns: String, updatedAt: Date) {
        self.entityID = entityID
        self.summary = summary
        self.patterns = patterns
        self.updatedAt = updatedAt
    }
}

extension MemoryStore {
    /// Facts where a new value replaces the old one. Anything else can hold several values.
    static let singleValued: Set<String> = [
        "lives_in", "works_at", "job", "job_title", "role", "relationship", "relationship_status",
        "phone", "email", "birthday", "age", "company", "city", "team", "manager",
    ]

    // MARK: Processing queue

    /// Messages the nightly job hasn't read yet. Drafts and fixes are skipped: they may never have been sent.
    public func unprocessedEpisodes(limit: Int = 200) throws -> [Episode] {
        try db.read { db in
            try Episode.fetchAll(db, sql: """
                SELECT * FROM episodes WHERE processedAt IS NULL AND kind IN ('sent', 'generate', 'note')
                ORDER BY createdAt LIMIT ?
                """, arguments: [limit])
        }
    }

    public func markProcessed(_ ids: [Int64], at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            try db.execute(sql: "UPDATE episodes SET processedAt = ? WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                           arguments: StatementArguments([date] + ids))
        }
    }

    // MARK: Facts

    /// Adds a fact, reconciling it with what's known:
    /// same value again does nothing; a new value for a single-valued predicate closes the old fact.
    @discardableResult
    public func addFact(subject: String, entityID: Int64?, predicate rawPredicate: String, object rawObject: String,
                        validFrom: Date, sourceEpisodeID: Int64? = nil, now: Date = Date()) throws -> Fact? {
        let predicate = Self.snakeCase(rawPredicate)
        let object = rawObject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty, !object.isEmpty else { return nil }
        return try db.write { db in
            let current = try Fact
                .filter(Column("predicate") == predicate && Column("validTo") == nil)
                .filter(entityID.map { Column("entityID") == $0 } ?? (Column("entityID") == nil && Column("subject") == subject))
                .fetchAll(db)
            if current.contains(where: { Self.normalize($0.object) == Self.normalize(object) }) { return nil }

            var fact = Fact(id: nil, entityID: entityID, subject: subject, predicate: predicate, object: object,
                            validFrom: validFrom, validTo: nil, recordedAt: now, supersededBy: nil, sourceEpisodeID: sourceEpisodeID)
            try fact.insert(db)
            if Self.singleValued.contains(predicate) {
                for var old in current {
                    old.validTo = validFrom
                    old.supersededBy = fact.id
                    try old.update(db)
                }
            }
            return fact
        }
    }

    /// What was true about a person at `date` (default: now).
    public func facts(entityID: Int64?, subject: String? = nil, asOf date: Date? = nil) throws -> [Fact] {
        try db.read { db in
            var request = Fact.all()
            if let entityID { request = request.filter(Column("entityID") == entityID) } else if let subject { request = request.filter(Column("subject") == subject) }
            if let date {
                request = request.filter(Column("validFrom") <= date && (Column("validTo") == nil || Column("validTo") > date))
            } else {
                request = request.filter(Column("validTo") == nil)
            }
            return try request.order(Column("validFrom").desc).fetchAll(db)
        }
    }

    /// Every fact ever recorded for a person, including replaced ones.
    public func factHistory(entityID: Int64) throws -> [Fact] {
        try db.read { db in try Fact.filter(Column("entityID") == entityID).order(Column("validFrom").desc).fetchAll(db) }
    }

    // MARK: Loops

    @discardableResult
    public func addLoop(_ loop: OpenLoop) throws -> OpenLoop? {
        try db.write { db in
            let duplicate = try OpenLoop.filter(Column("status") == "open").fetchAll(db).contains {
                Self.normalize($0.text) == Self.normalize(loop.text) && $0.entityID == loop.entityID
            }
            guard !duplicate else { return nil }
            var l = loop
            try l.insert(db)
            return l
        }
    }

    public func openLoops() throws -> [OpenLoop] {
        try db.read { db in
            try OpenLoop.filter(Column("status") == "open")
                .order(sql: "dueAt IS NULL, dueAt, createdAt").fetchAll(db)
        }
    }

    public func loops(entityID: Int64) throws -> [OpenLoop] {
        try db.read { db in try OpenLoop.filter(Column("entityID") == entityID).order(Column("createdAt").desc).fetchAll(db) }
    }

    public func setLoop(_ id: Int64, status: OpenLoop.Status, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE loops SET status = ?, closedAt = ? WHERE id = ?",
                           arguments: [status.rawValue, status == .open ? nil : date, id])
        }
    }

    /// Open loops due by `date` that haven't been announced yet.
    public func loopsToNotify(dueBy date: Date) throws -> [OpenLoop] {
        try db.read { db in
            try OpenLoop.filter(Column("status") == "open" && Column("notifiedAt") == nil && Column("dueAt") != nil && Column("dueAt") <= date)
                .fetchAll(db)
        }
    }

    public func markNotified(_ id: Int64, at date: Date = Date()) throws {
        try db.write { db in try db.execute(sql: "UPDATE loops SET notifiedAt = ? WHERE id = ?", arguments: [date, id]) }
    }

    // MARK: Profiles and digests

    public func setProfile(_ profile: PersonProfile) throws {
        try db.write { db in try profile.save(db) }
    }

    public func profile(entityID: Int64) throws -> PersonProfile? {
        try db.read { db in try PersonProfile.fetchOne(db, key: entityID) }
    }

    public func setDigest(day: String, text: String, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO digests (day, text, createdAt) VALUES (?, ?, ?)", arguments: [day, text, date])
        }
    }

    public func digests(limit: Int = 60) throws -> [(day: String, text: String)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT day, text FROM digests ORDER BY day DESC LIMIT ?", arguments: [limit]).map { ($0["day"], $0["text"]) }
        }
    }

    public func allLoops(limit: Int = 200) throws -> [OpenLoop] {
        try db.read { db in
            try OpenLoop.order(sql: "status = 'open' DESC, dueAt IS NULL, dueAt, createdAt DESC").limit(limit).fetchAll(db)
        }
    }

    public func digest(day: String) throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT text FROM digests WHERE day = ?", arguments: [day]) }
    }

    public func episodes(from start: Date, to end: Date, kinds: [Episode.Kind] = [.sent, .generate, .note]) throws -> [Episode] {
        try db.read { db in
            try Episode.filter(Column("createdAt") >= start && Column("createdAt") < end)
                .filter(kinds.map(\.rawValue).contains(Column("kind")))
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Merges people that ended up as separate entities with the same name.
    @discardableResult
    public func mergeDuplicatePeople() throws -> Int {
        try db.write { db in
            let people = try Entity.filter(Column("type") == "person").order(Column("id")).fetchAll(db)
            var keep: [String: Int64] = [:]
            var merged = 0
            for person in people {
                let key = Self.normalize(person.name)
                guard let target = keep[key] else { keep[key] = person.id; continue }
                for table in ["episodes", "facts", "loops"] {
                    try db.execute(sql: "UPDATE \(table) SET entityID = ? WHERE entityID = ?", arguments: [target, person.id])
                }
                try db.execute(sql: "UPDATE OR IGNORE handles SET entityID = ? WHERE entityID = ?", arguments: [target, person.id])
                try Entity.deleteOne(db, key: person.id)
                merged += 1
            }
            return merged
        }
    }

    static func snakeCase(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
