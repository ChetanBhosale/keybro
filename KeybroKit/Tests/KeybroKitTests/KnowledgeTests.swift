import Foundation
import Testing
@testable import KeybroKit

/// Deterministic bag-of-words embedder: shared words give similar vectors.
struct FakeEmbedder: Embedder {
    let modelID = "fake-v1"
    let vocabulary = ["party", "tonight", "come", "cant", "deck", "friday", "send", "staging", "migration", "deploy", "evening", "make"]
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted))
            return VectorMath.normalize(vocabulary.map { words.contains($0) ? 1 : 0 })
        }
    }
}

/// Replies from a script, in order; records prompts.
actor ScriptedModel: TextModel {
    nonisolated let name = "scripted"
    nonisolated let isLocal = true
    var replies: [String]
    var prompts: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(system: String, prompt: String, json: Bool) async throws -> String {
        prompts.append(prompt)
        return replies.isEmpty ? "{}" : replies.removeFirst()
    }
}

struct EmbeddingSearchTests {
    let store = try! MemoryStore()

    @Test func indexerEmbedsPendingOnceAndReembedsEditedText() async throws {
        let a = try store.insert(Episode(kind: .sent, surface: "slack", text: "staging migration failed"))
        try store.insert(Episode(kind: .sent, surface: "whatsapp", text: "party tonight"))
        let indexer = MemoryIndexer(store: store, embedder: FakeEmbedder())
        #expect(try await indexer.indexPending() == 2)
        #expect(try await indexer.indexPending() == 0)
        try store.update(episodeID: a.id!, text: "deploy on friday")
        #expect(try await indexer.indexPending() == 1)
        #expect(await indexer.index.count == 2)
    }

    @Test func hybridFindsByMeaningWhenWordsDiffer() async throws {
        try store.insert(Episode(kind: .sent, surface: "whatsapp", text: "cant come to the party tonight"))
        try store.insert(Episode(kind: .sent, surface: "slack", text: "staging migration fixed"))
        let embedder = FakeEmbedder()
        let indexer = MemoryIndexer(store: store, embedder: embedder)
        try await indexer.indexPending()
        let search = HybridSearch(store: store, embedder: embedder, index: indexer.index)
        // No shared keyword with FTS ("make" and "evening" aren't in the text), but vectors overlap on "tonight"/"party".
        let hits = try await search.search("can't make the party this evening", limit: 5)
        #expect(hits.first?.text == "cant come to the party tonight")
        #expect(try await HybridSearch(store: store).search("staging").first?.text == "staging migration fixed")
    }

    @Test func recentBeatsOldForEqualMatches() async throws {
        let now = Date()
        try store.insert(Episode(kind: .sent, surface: "x", text: "deploy notes", createdAt: now.addingTimeInterval(-200 * 86_400)))
        try store.insert(Episode(kind: .sent, surface: "x", text: "deploy notes", createdAt: now.addingTimeInterval(-86_400)))
        let hits = try await HybridSearch(store: store).search("deploy", limit: 2, now: now)
        #expect(hits.first!.createdAt > hits.last!.createdAt)
    }

    @Test func vectorsRoundTripThroughSQLite() throws {
        let e = try store.insert(Episode(kind: .sent, surface: "x", text: "hi"))
        try store.saveEmbedding(episodeID: e.id!, model: "m", vector: [0.25, -1, 3.5])
        #expect(try store.embeddings(model: "m").first?.1 == [0.25, -1, 3.5])
        try store.deleteEpisode(id: e.id!)
        #expect(try store.embeddings(model: "m").isEmpty)
    }
}

struct FactTests {
    let store = try! MemoryStore()
    let d = { (day: Int) in Date(timeIntervalSince1970: 1_780_000_000 + Double(day) * 86_400) }

    @Test func newValueSupersedesAndTimeTravelSeesTheOldOne() throws {
        let rahul = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
        try store.addFact(subject: "Rahul", entityID: rahul, predicate: "lives in", object: "Pune", validFrom: d(0))
        try store.addFact(subject: "Rahul", entityID: rahul, predicate: "lives_in", object: "Bangalore", validFrom: d(30))
        #expect(try store.facts(entityID: rahul).map(\.object) == ["Bangalore"])
        #expect(try store.facts(entityID: rahul, asOf: d(10)).map(\.object) == ["Pune"])
        let history = try store.factHistory(entityID: rahul!)
        #expect(history.count == 2)
        let old = try #require(history.first { $0.object == "Pune" })
        #expect(old.validTo == d(30))
        #expect(old.supersededBy != nil)
    }

    @Test func repeatsAreIgnoredAndMultiValuedFactsAccumulate() throws {
        let priya = try store.resolvePerson(named: "Priya", surface: "slack")
        #expect(try store.addFact(subject: "Priya", entityID: priya, predicate: "likes", object: "coffee", validFrom: d(0)) != nil)
        #expect(try store.addFact(subject: "Priya", entityID: priya, predicate: "likes", object: "Coffee ", validFrom: d(1)) == nil)
        try store.addFact(subject: "Priya", entityID: priya, predicate: "likes", object: "cricket", validFrom: d(2))
        #expect(Set(try store.facts(entityID: priya).map(\.object)) == ["coffee", "cricket"])
    }

    @Test func factsAboutMeHaveNoEntity() throws {
        try store.addFact(subject: "me", entityID: nil, predicate: "works_at", object: "Linkrunner", validFrom: d(0))
        try store.addFact(subject: "me", entityID: nil, predicate: "works_at", object: "Respan", validFrom: d(100))
        #expect(try store.facts(entityID: nil, subject: "me").map(\.object) == ["Respan"])
    }

    @Test func loopsDedupeCloseAndNotify() throws {
        let priya = try store.resolvePerson(named: "Priya", surface: "whatsapp")
        let loop = OpenLoop(id: nil, entityID: priya, person: "Priya", text: "Send the deck", dueAt: d(3), status: .open, createdAt: d(0))
        let saved = try #require(try store.addLoop(loop))
        #expect(try store.addLoop(loop) == nil)
        #expect(try store.loopsToNotify(dueBy: d(2)).isEmpty)
        #expect(try store.loopsToNotify(dueBy: d(4)).count == 1)
        try store.markNotified(saved.id!)
        #expect(try store.loopsToNotify(dueBy: d(4)).isEmpty)
        try store.setLoop(saved.id!, status: .done)
        #expect(try store.openLoops().isEmpty)
    }

    @Test func mergeDuplicatePeopleMovesEverything() throws {
        let a = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
        // Force a duplicate the way an older build could have made one.
        var dup = Entity(id: nil, type: "person", name: "rahul", createdAt: Date())
        try store.db.write { try dup.insert($0) }
        try store.insert(Episode(kind: .sent, surface: "slack", entityID: dup.id, text: "hi"))
        #expect(try store.mergeDuplicatePeople() == 1)
        #expect(try store.people().count == 1)
        #expect(try store.episodes(forPerson: a!).count == 1)
    }
}

struct ConsolidatorTests {
    let store = try! MemoryStore()
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    // Sunday 27 Sep 2026, 21:00 IST
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 21))! }

    func seed() throws {
        let priya = try store.resolvePerson(named: "Priya", surface: "whatsapp")
        let rahul = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: priya, contactRaw: "Priya", text: "ill send you the deck by friday", createdAt: now.addingTimeInterval(-3600)))
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: rahul, contactRaw: "Rahul", text: "congrats on moving to bangalore bro", createdAt: now.addingTimeInterval(-1800)))
        try store.insert(Episode(kind: .draft, surface: "whatsapp", text: "never sent draft about a promise"))
    }

    @Test func extractsFactsPromisesProfilesAndDigest() async throws {
        try seed()
        let model = ScriptedModel([
            #"{"facts":[{"subject":"Rahul","predicate":"lives_in","object":"Bangalore"},{"subject":"","predicate":"x","object":"y"}],"promises":[{"to":"Priya","text":"Send the deck","due":"2026-10-02"}]}"#,
            #"{"done":[]}"#,
            #"{"summary":"Colleague waiting on a deck.","patterns":["Asks for updates on Fridays"]}"#,
            #"{"summary":"Close friend — just moved to Bangalore.","patterns":[]}"#,
            "- Promised Priya the deck by Friday\n- Congratulated Rahul on the move",
        ])
        let report = await Consolidator(store: store, model: model).run(now: now, calendar: calendar)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.processed == 2)                       // the draft is skipped
        #expect(report.facts == 1)                           // invalid fact dropped
        #expect(report.loopsAdded == 1)
        #expect(report.profiles == 2)
        let loop = try #require(try store.openLoops().first)
        #expect(loop.person == "Priya")
        #expect(calendar.component(.day, from: loop.dueAt!) == 2)
        let rahul = try store.findPerson(named: "Rahul")!
        #expect(try store.facts(entityID: rahul).first?.object == "Bangalore")
        let summary = try store.profile(entityID: rahul)?.summary
        #expect(summary == "Close friend, just moved to Bangalore.")
        #expect(try store.digest(day: "2026-09-27")?.contains("deck") == true)
        #expect(try store.unprocessedEpisodes().isEmpty)
        // The model is told the real dates so "friday" resolves correctly.
        #expect(await model.prompts.first?.contains("Friday 2026-10-02") == true)
    }

    @Test func closesLoopsTheModelConfirms() async throws {
        let priya = try store.resolvePerson(named: "Priya", surface: "whatsapp")
        let loop = try #require(try store.addLoop(OpenLoop(id: nil, entityID: priya, person: "Priya", text: "Send the deck", dueAt: nil, status: .open, createdAt: now.addingTimeInterval(-86_400))))
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: priya, contactRaw: "Priya", text: "here's the deck", createdAt: now.addingTimeInterval(-60)))
        let model = ScriptedModel([#"{"facts":[],"promises":[]}"#, "{\"done\":[\(loop.id!), 999]}", #"{"summary":"Colleague.","patterns":[]}"#, ""])
        let report = await Consolidator(store: store, model: model).run(now: now, calendar: calendar)
        #expect(report.loopsClosed == 1)
        #expect(try store.openLoops().isEmpty)
    }

    @Test func garbageFromTheModelLeavesMessagesForNextTime() async throws {
        try seed()
        let report = await Consolidator(store: store, model: ScriptedModel(["not json at all"])).run(now: now, calendar: calendar)
        #expect(!report.errors.isEmpty)
        #expect(report.processed == 0)
        #expect(try store.unprocessedEpisodes().count == 2)
    }

    @Test func pastDueDatesAreDropped() async throws {
        try seed()
        let model = ScriptedModel([#"{"facts":[],"promises":[{"to":"Priya","text":"Call her","due":"2020-01-01"}]}"#])
        _ = await Consolidator(store: store, model: model).run(now: now, calendar: calendar)
        #expect(try store.openLoops().first?.dueAt == nil)
    }
}

struct ExportAndQueryTests {
    let store = try! MemoryStore()

    func seed() throws -> Int64 {
        let rahul = try store.resolvePerson(named: "Rahul", surface: "whatsapp")!
        _ = try store.resolvePerson(named: "Priya", surface: "slack")
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: rahul, contactRaw: "Rahul", text: "is priya coming sunday?"))
        try store.insert(Episode(kind: .sent, surface: "slack", text: "staging deploy done"))
        try store.addFact(subject: "Rahul", entityID: rahul, predicate: "lives_in", object: "Pune", validFrom: Date().addingTimeInterval(-86_400 * 60))
        try store.addFact(subject: "Rahul", entityID: rahul, predicate: "lives_in", object: "Bangalore", validFrom: Date().addingTimeInterval(-86_400 * 5))
        try store.setProfile(PersonProfile(entityID: rahul, summary: "College friend.", patterns: "Plans on Sundays", updatedAt: Date()))
        try store.addLoop(OpenLoop(id: nil, entityID: rahul, person: "Rahul", text: "Book the table", dueAt: nil, status: .open, createdAt: Date()))
        return rahul
    }

    @Test func exportWritesLinkedMarkdown() throws {
        _ = try seed()
        let folder = FileManager.default.temporaryDirectory.appending(path: "kb-export-\(UUID().uuidString)")
        try MarkdownExporter.export(store: store, to: folder)
        let rahul = try String(contentsOf: folder.appending(path: "people/Rahul.md"), encoding: .utf8)
        #expect(rahul.contains("College friend."))
        #expect(rahul.contains("~~lives_in: Pune~~"))
        #expect(rahul.contains("- [ ] Book the table"))
        #expect(rahul.contains("[[Priya|priya]]"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "index.md").path))
        let days = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "daily").path)
        #expect(days.count == 1)
    }

    @Test func personShowsCurrentAndReplacedFactsAndTimeTravels() throws {
        _ = try seed()
        let q = MemoryQuery(store: store)
        let now = try q.person(named: "rahul")
        #expect(now.contains("lives_in: Bangalore"))
        #expect(now.contains("No longer true"))
        #expect(now.contains("Book the table"))
        let then = try q.person(named: "Rahul", asOf: Date().addingTimeInterval(-86_400 * 30))
        #expect(then.contains("lives_in: Pune"))
        #expect(!then.contains("Bangalore"))
        #expect(try q.person(named: "Nobody").contains("No one called"))
    }

    @Test func scopeHidesExcludedAppsEverywhere() async throws {
        _ = try seed()
        let q = MemoryQuery(store: store, scope: MemoryScope(excludedSurfaces: ["whatsapp"]))
        #expect(try q.person(named: "Rahul").contains("No one called"))
        #expect(!(try q.timeline(days: 1)).contains("sunday"))
        #expect(try q.timeline(days: 1).contains("staging"))
        #expect(!(try await q.searchMemory("sunday")).contains("is priya coming"))
    }

    @Test func rememberRespectsScopeAndContentRules() throws {
        let open = MemoryQuery(store: store)
        #expect(try open.remember("Rahul prefers calls after 8pm", person: "Rahul") == "Saved.")
        #expect(try open.remember("send nudes") != "Saved.")
        #expect(try open.remember("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz") == "Saved.")
        #expect(try store.search("key").first?.text == "key [redacted]")
        let readOnly = MemoryQuery(store: store, scope: MemoryScope(allowWrite: false))
        #expect(try readOnly.remember("x").contains("turned off"))
    }
}

struct MCPServerTests {
    let store = try! MemoryStore()
    var server: MCPServer { MCPServer(query: MemoryQuery(store: store), logURL: nil) }

    func call(_ json: String) async throws -> [String: Any] {
        let line = try #require(await server.handle(line: json))
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func handshakeAndToolList() async throws {
        let initResult = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#)
        let result = try #require(initResult["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "keybro-memory")
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = try await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["search_memory", "get_person", "timeline", "open_loops", "today_context", "remember"])
    }

    @Test func toolCallsReturnText() async throws {
        try store.insert(Episode(kind: .sent, surface: "slack", text: "migration fixed on staging"))
        let r = try await call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"staging"}}}"#)
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("migration fixed") == true)
    }

    @Test func errorsAreReportedNotThrown() async throws {
        let missing = try await call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_memory","arguments":{}}}"#)
        #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknown = try await call(#"{"jsonrpc":"2.0","id":5,"method":"nope"}"#)
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = try await call("not json")
        #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func accessLogRecordsToolAndArgs() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "kb-mcp-\(UUID().uuidString).log")
        let server = MCPServer(query: MemoryQuery(store: store), logURL: log)
        _ = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"open_loops","arguments":{}}}"#)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("\topen_loops\t{}"))
        #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int == 0o600)
    }
}

struct ContextKnowledgeTests {
    @Test func generateContextIncludesFactsAndPromises() async throws {
        let store = try MemoryStore()
        let rahul = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: rahul, contactRaw: "Rahul", text: "sunday brunch?"))
        try store.addFact(subject: "Rahul", entityID: rahul, predicate: "works_at", object: "Swiggy", validFrom: Date())
        try store.addLoop(OpenLoop(entityID: rahul, person: "Rahul", text: "Book the table", dueAt: nil, createdAt: Date()))
        let recorder = MemoryRecorder(store: store, search: HybridSearch(store: store))
        let target = TextTarget(pid: 1, bundleID: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp", text: "", source: .axSelection)
        let context = try #require(await recorder.context(instruction: "tell rahul im running late", target: target))
        #expect(context.contains("works_at Swiggy"))
        #expect(context.contains("You promised Rahul: Book the table"))
        #expect(context.contains("sunday brunch?"))
    }
}
