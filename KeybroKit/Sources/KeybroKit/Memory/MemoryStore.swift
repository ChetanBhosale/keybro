import Foundation
import GRDB

/// One thing that happened: a message you sent, a draft, a fix, a generated reply.
/// Stored verbatim (L0 in the plan); facts and profiles are derived from these later.
public struct Episode: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public enum Kind: String, Codable, Sendable {
        case sent, draft, fix, generate
    }

    public var id: Int64?
    public var kind: Kind
    public var bundleID: String?
    public var appName: String?
    /// App family, so WhatsApp desktop and WhatsApp Web count as one place ("whatsapp").
    public var surface: String
    public var entityID: Int64?
    public var contactRaw: String?
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    public static let databaseTableName = "episodes"

    public init(id: Int64? = nil, kind: Kind, bundleID: String? = nil, appName: String? = nil, surface: String,
                entityID: Int64? = nil, contactRaw: String? = nil, text: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.bundleID = bundleID
        self.appName = appName
        self.surface = surface
        self.entityID = entityID
        self.contactRaw = contactRaw
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Entity: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var type: String
    public var name: String
    public var createdAt: Date

    public static let databaseTableName = "entities"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PersonSummary: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var name: String
    public var episodeCount: Int
    public var lastSeen: Date?
    public var surfaces: [String]
}

public struct MemoryGraph: Equatable, Sendable {
    public struct Edge: Equatable, Sendable {
        public var from: Int64
        public var to: Int64
        public var weight: Int
    }
    public var people: [PersonSummary]
    /// Person-to-person links: one mentioned the other by name.
    public var edges: [Edge]

    public init(people: [PersonSummary], edges: [Edge]) {
        self.people = people
        self.edges = edges
    }
}

/// Local SQLite memory at ~/keybro-memory/memory.db.
public final class MemoryStore: Sendable {
    let db: DatabaseQueue

    public init(url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only you can read your memory. SQLite's side files inherit the database's mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        db = try DatabaseQueue(path: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.migrator.migrate(db)
    }

    /// For tests.
    public init() throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    public static var defaultURL: URL { KeybroPaths.memory.appending(path: "memory.db") }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "entities") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "handles") { t in
                t.column("entityID", .integer).notNull().references("entities", onDelete: .cascade)
                t.column("surface", .text).notNull()
                t.column("value", .text).notNull()
                t.uniqueKey(["surface", "value"])
            }
            try db.create(table: "episodes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("bundleID", .text)
                t.column("appName", .text)
                t.column("surface", .text).notNull()
                t.column("entityID", .integer).references("entities", onDelete: .setNull).indexed()
                t.column("contactRaw", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(virtualTable: "episodes_fts", using: FTS5()) { t in
                t.synchronize(withTable: "episodes")
                t.tokenizer = .unicode61()
                t.column("text")
                t.column("contactRaw")
            }
        }
        return migrator
    }

    // MARK: - Writing

    @discardableResult
    public func insert(_ episode: Episode) throws -> Episode {
        try db.write { db in
            var e = episode
            try e.insert(db)
            return e
        }
    }

    /// Drafts are updated in place while you type, then promoted to `sent`.
    public func update(episodeID: Int64, text: String, kind: Episode.Kind? = nil, at date: Date = Date()) throws {
        try db.write { db in
            guard var e = try Episode.fetchOne(db, key: episodeID) else { return }
            e.text = text
            if let kind { e.kind = kind }
            e.updatedAt = date
            try e.update(db)
        }
    }

    /// Deletes every episode matching `shouldDelete`. Returns how many went.
    @discardableResult
    public func deleteEpisodes(where shouldDelete: (Episode) -> Bool) throws -> Int {
        try db.write { db in
            let ids = try Episode.fetchAll(db).filter(shouldDelete).compactMap(\.id)
            return try Episode.deleteAll(db, keys: ids)
        }
    }

    /// "Forget the last hour": deletes everything created or edited since `date`.
    @discardableResult
    public func forget(since date: Date) throws -> Int {
        try db.write { db in
            try Episode.filter(Column("createdAt") >= date || Column("updatedAt") >= date).deleteAll(db)
        }
    }

    /// Deletes all episodes and people. The file stays, empty.
    public func deleteEverything() throws {
        try db.write { db in
            try Episode.deleteAll(db)
            try Entity.deleteAll(db)
        }
        try db.vacuum()
    }

    public struct AppCount: Equatable, Sendable {
        public var surface: String
        public var appName: String?
        public var count: Int
        public var last: Date?
    }

    /// What was captured since `date`, per app. For the privacy view.
    public func capturedByApp(since date: Date) throws -> [AppCount] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT surface, MAX(appName) AS appName, COUNT(*) AS count, MAX(createdAt) AS last
                FROM episodes WHERE createdAt >= ? GROUP BY surface ORDER BY count DESC
                """, arguments: [date]).map {
                AppCount(surface: $0["surface"], appName: $0["appName"], count: $0["count"], last: $0["last"])
            }
        }
    }

    public func deleteEpisode(id: Int64) throws {
        _ = try db.write { db in try Episode.deleteOne(db, key: id) }
    }

    /// Finds or creates the person behind a name seen in an app.
    /// Same name on another surface links to the same person (WhatsApp desktop and web, or Slack and WhatsApp).
    public func resolvePerson(named rawName: String, surface: String) throws -> Int64? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        return try db.write { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT entityID FROM handles WHERE surface = ? AND value = ?", arguments: [surface, key]) {
                return id
            }
            let existing = try Int64.fetchOne(db, sql: """
                SELECT e.id FROM entities e JOIN handles h ON h.entityID = e.id
                WHERE e.type = 'person' AND h.value = ? ORDER BY e.id LIMIT 1
                """, arguments: [key])
            let id: Int64
            if let existing {
                id = existing
            } else {
                var entity = Entity(id: nil, type: "person", name: name, createdAt: Date())
                try entity.insert(db)
                id = entity.id!
            }
            try db.execute(sql: "INSERT OR IGNORE INTO handles (entityID, surface, value) VALUES (?, ?, ?)", arguments: [id, surface, key])
            return id
        }
    }

    /// Lookup only; never creates a person.
    public func findPerson(named name: String) throws -> Int64? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        return try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT entityID FROM handles WHERE value = ? ORDER BY entityID LIMIT 1", arguments: [key])
        }
    }

    static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Reading

    public func episode(id: Int64) throws -> Episode? {
        try db.read { db in try Episode.fetchOne(db, key: id) }
    }

    public func recentEpisodes(limit: Int = 200, before: Date? = nil) throws -> [Episode] {
        try db.read { db in
            var request = Episode.order(Column("createdAt").desc).limit(limit)
            if let before { request = request.filter(Column("createdAt") < before) }
            return try request.fetchAll(db)
        }
    }

    public func episodes(forPerson id: Int64, limit: Int = 50) throws -> [Episode] {
        try db.read { db in
            try Episode.filter(Column("entityID") == id).order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// Full-text search over what you've written. Any word can match; best matches first.
    public func search(_ query: String, limit: Int = 10) throws -> [Episode] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: query) else { return [] }
        return try db.read { db in
            try Episode.fetchAll(db, sql: """
                SELECT episodes.* FROM episodes
                JOIN episodes_fts ON episodes_fts.rowid = episodes.id AND episodes_fts MATCH ?
                ORDER BY bm25(episodes_fts), episodes.createdAt DESC
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    public func person(id: Int64) throws -> Entity? {
        try db.read { db in try Entity.fetchOne(db, key: id) }
    }

    /// People whose name appears as a whole word in `text` (e.g. "sorry to rahul").
    public func peopleMentioned(in text: String) throws -> [Entity] {
        let words = Set(Self.normalize(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 })
        guard !words.isEmpty else { return [] }
        return try db.read { db in
            try Entity.filter(Column("type") == "person").fetchAll(db).filter { entity in
                let first = Self.normalize(entity.name).components(separatedBy: " ").first ?? ""
                return words.contains(first) || words.contains(Self.normalize(entity.name))
            }
        }
    }

    public func people() throws -> [PersonSummary] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id, e.name,
                       (SELECT COUNT(*) FROM episodes WHERE entityID = e.id) AS count,
                       (SELECT MAX(createdAt) FROM episodes WHERE entityID = e.id) AS lastSeen,
                       (SELECT GROUP_CONCAT(DISTINCT surface) FROM handles WHERE entityID = e.id) AS surfaces
                FROM entities e WHERE e.type = 'person'
                ORDER BY lastSeen DESC NULLS LAST, e.name
                """).map { row in
                PersonSummary(
                    id: row["id"], name: row["name"], episodeCount: row["count"], lastSeen: row["lastSeen"],
                    surfaces: (row["surfaces"] as String?)?.split(separator: ",").map(String.init).sorted() ?? []
                )
            }
        }
    }

    public func graph() throws -> MemoryGraph {
        let people = try people()
        let firstNames = Dictionary(uniqueKeysWithValues: people.map { ($0.id, Self.normalize($0.name).components(separatedBy: " ").first ?? "") })
        let textsByPerson: [Int64: [String]] = try db.read { db in
            var result: [Int64: [String]] = [:]
            for person in people {
                result[person.id] = try String.fetchAll(db, sql: "SELECT text FROM episodes WHERE entityID = ? ORDER BY createdAt DESC LIMIT 500", arguments: [person.id])
                    .map { Self.normalize($0) }
            }
            return result
        }
        func mentions(_ texts: [String], _ name: String) -> Int {
            guard name.count >= 2 else { return 0 }
            return texts.filter { $0.components(separatedBy: CharacterSet.alphanumerics.inverted).contains(name) }.count
        }
        var edges: [MemoryGraph.Edge] = []
        for a in people {
            for b in people where a.id < b.id {
                let weight = mentions(textsByPerson[a.id] ?? [], firstNames[b.id] ?? "") + mentions(textsByPerson[b.id] ?? [], firstNames[a.id] ?? "")
                if weight > 0 { edges.append(.init(from: a.id, to: b.id, weight: weight)) }
            }
        }
        return MemoryGraph(people: people, edges: edges)
    }

    public func episodeCount() throws -> Int {
        try db.read { db in try Episode.fetchCount(db) }
    }
}
