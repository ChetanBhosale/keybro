import Foundation
import Testing
@testable import KeybroKit

struct MemoryStoreTests {
    let store = try! MemoryStore()

    @Test func samePersonAcrossWhatsAppDesktopAndWebAndSlack() throws {
        let a = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
        let b = try store.resolvePerson(named: "rahul ", surface: "whatsapp")
        let c = try store.resolvePerson(named: "Rahul", surface: "slack")
        let other = try store.resolvePerson(named: "Priya", surface: "whatsapp")
        #expect(a != nil && a == b && a == c)
        #expect(other != a)
        #expect(try store.resolvePerson(named: "  ", surface: "whatsapp") == nil)
        #expect(try store.people().first { $0.id == a }?.surfaces == ["slack", "whatsapp"])
    }

    @Test func findPersonNeverCreates() throws {
        #expect(try store.findPerson(named: "Nobody") == nil)
        #expect(try store.people().isEmpty)
    }

    @Test func draftUpdatesInPlaceThenBecomesSent() throws {
        let e = try store.insert(Episode(kind: .draft, surface: "whatsapp", text: "hey"))
        try store.update(episodeID: e.id!, text: "hey bro cant come", kind: .sent)
        let saved = try #require(try store.episode(id: e.id!))
        #expect(saved.kind == .sent)
        #expect(saved.text == "hey bro cant come")
        #expect(try store.episodeCount() == 1)
    }

    @Test func fullTextSearchFindsAnyWordAndStaysInSync() throws {
        try store.insert(Episode(kind: .sent, surface: "slack", text: "migration didn't run on staging"))
        try store.insert(Episode(kind: .sent, surface: "whatsapp", text: "party tonight at 8"))
        #expect(try store.search("staging deploy").map(\.text) == ["migration didn't run on staging"])
        let e = try store.insert(Episode(kind: .draft, surface: "x", text: "old words"))
        try store.update(episodeID: e.id!, text: "brand new words")
        #expect(try store.search("old").isEmpty)
        #expect(try store.search("brand").count == 1)
        #expect(try store.search("   ").isEmpty)
    }

    @Test func peopleMentionedByFirstName() throws {
        _ = try store.resolvePerson(named: "Rahul Sharma", surface: "whatsapp")
        _ = try store.resolvePerson(named: "Priya", surface: "whatsapp")
        #expect(try store.peopleMentioned(in: "sorry to rahul, cant come").map(\.name) == ["Rahul Sharma"])
        #expect(try store.peopleMentioned(in: "rahulx is here").isEmpty)
    }

    @Test func graphLinksPeopleWhoMentionEachOther() throws {
        let rahul = try #require(try store.resolvePerson(named: "Rahul", surface: "whatsapp"))
        let priya = try #require(try store.resolvePerson(named: "Priya", surface: "whatsapp"))
        _ = try store.resolvePerson(named: "Mom", surface: "whatsapp")
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: rahul, text: "is priya coming tonight?"))
        let graph = try store.graph()
        #expect(graph.people.count == 3)
        #expect(graph.edges == [.init(from: rahul, to: priya, weight: 1)])
    }

    @Test func persistsToDiskAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "kb-\(UUID().uuidString)/memory.db")
        try MemoryStore(url: url).insert(Episode(kind: .sent, surface: "whatsapp", text: "remember me"))
        #expect(try MemoryStore(url: url).search("remember").count == 1)
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
    }
}

struct SecretRedactorTests {
    @Test(arguments: [
        "my key is sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123",
        "token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "AKIAIOSFODNN7EXAMPLE",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "password: hunter22",
        "your OTP is 482913",
        "card 4242 4242 4242 4242 exp 12/30",
        "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8",
    ])
    func redactsSecrets(_ text: String) {
        #expect(SecretRedactor.redact(text).contains("[redacted]"), "\(text)")
    }

    @Test(arguments: [
        "bro party at my place tonight, 8pm",
        "call me at 9876543210",
        "PR #5559 and DEV-11581 are ready",
        "order 1234567890123 shipped",
        "https://github.com/ChetanBhosale/keybro",
    ])
    func keepsNormalText(_ text: String) {
        #expect(SecretRedactor.redact(text) == text)
    }
}

struct ContactResolverTests {
    @Test func appFamilies() {
        #expect(ContactResolver.resolve(bundleID: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp").surface == "whatsapp")
        #expect(ContactResolver.resolve(bundleID: "com.google.Chrome", windowTitle: "(3) WhatsApp").surface == "whatsapp")
        #expect(ContactResolver.resolve(bundleID: "com.apple.Safari", windowTitle: "Inbox (2) - me@x.com - Gmail").surface == "gmail")
        #expect(ContactResolver.resolve(bundleID: "com.google.Chrome", windowTitle: "Hacker News").surface == "web")
        #expect(ContactResolver.resolve(bundleID: "com.example.App", windowTitle: nil).surface == "com.example.App")
    }

    @Test func contactsOnlyFromTitlesThatCarryThem() {
        #expect(ContactResolver.resolve(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "Rahul (DM) - Linkrunner - Slack").contact == "Rahul")
        #expect(ContactResolver.resolve(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "#eng (Channel) - Linkrunner - Slack").contact == "#eng")
        #expect(ContactResolver.resolve(bundleID: "com.hnc.Discord", windowTitle: "@rahul - Discord").contact == "rahul")
        #expect(ContactResolver.resolve(bundleID: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp").contact == nil)
        #expect(ContactResolver.resolve(bundleID: "com.google.Chrome", windowTitle: "WhatsApp").contact == nil)
    }
}

struct TypingTrackerTests {
    var tracker = TypingTracker(debounce: 2)
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func s(_ value: String, _ seconds: Double, key: String = "f1") -> FieldSample {
        FieldSample(fieldKey: key, bundleID: "net.whatsapp.WhatsApp", value: value, at: t0.addingTimeInterval(seconds))
    }

    @Test mutating func savesDraftAfterPauseOnlyOnce() {
        #expect(tracker.observe(s("hey bro", 0)).isEmpty)
        #expect(tracker.observe(s("hey bro cant", 1)).isEmpty)
        #expect(tracker.observe(s("hey bro cant", 2)).isEmpty)       // 1s since last change
        let events = tracker.observe(s("hey bro cant", 3.1))
        #expect(events.count == 1)
        guard case .draft(_, let text, _) = events.first else { Issue.record("expected draft"); return }
        #expect(text == "hey bro cant")
        #expect(tracker.observe(s("hey bro cant", 6)).isEmpty)       // unchanged, not saved again
    }

    @Test mutating func suddenEmptyIsSent() {
        _ = tracker.observe(s("sorry cant come tonight", 0))
        let events = tracker.observe(s("", 0.8))
        guard case .sent(_, let text, _) = events.first else { Issue.record("expected sent, got \(events)"); return }
        #expect(text == "sorry cant come tonight")
    }

    @Test mutating func backspacingIsNotSending() {
        _ = tracker.observe(s("abc", 0))
        #expect(tracker.observe(s("ab", 0.5)).isEmpty)
        #expect(tracker.observe(s("a", 1)).isEmpty)
        #expect(tracker.observe(s("", 1.5)).isEmpty)                 // "a" is below the minimum length
    }

    @Test mutating func switchingFieldsKeepsTheDraft() {
        _ = tracker.observe(s("half written email", 0))
        let events = tracker.observe(s("other", 0.5, key: "f2"))
        guard case .draft(let key, let text, _) = events.first else { Issue.record("expected draft"); return }
        #expect(key == "f1")
        #expect(text == "half written email")
    }

    @Test mutating func leavingTextFieldsKeepsTheDraft() {
        _ = tracker.observe(s("going somewhere", 0))
        #expect(tracker.observe(nil).count == 1)
        #expect(tracker.observe(nil).isEmpty)
    }

    @Test mutating func skipsTinyAndHugeText() {
        _ = tracker.observe(s("ok", 0))
        #expect(tracker.observe(s("ok", 5)).isEmpty)
        let doc = String(repeating: "a", count: 5000)
        _ = tracker.observe(s(doc, 10, key: "doc"))
        #expect(tracker.observe(s(doc, 20, key: "doc")).isEmpty)
    }
}

struct MemoryRecorderTests {
    let store = try! MemoryStore()
    let t0 = Date()

    func sample(_ value: String, _ seconds: Double, title: String = "Rahul (DM) - Linkrunner - Slack") -> FieldSample {
        FieldSample(fieldKey: "f", bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: title, value: value, at: t0.addingTimeInterval(seconds))
    }

    @Test func typingThenSendingStoresOneSentMessageLinkedToThePerson() async throws {
        let recorder = MemoryRecorder(store: store)
        await recorder.observe(sample("migration didnt run", 0))
        await recorder.observe(sample("migration didnt run", 3))   // draft saved
        await recorder.observe(sample("migration didnt run on staging", 4))
        await recorder.observe(sample("", 5))                       // sent
        let all = try store.recentEpisodes()
        #expect(all.count == 1)
        #expect(all.first?.kind == .sent)
        #expect(all.first?.text == "migration didnt run on staging")
        #expect(all.first?.surface == "slack")
        #expect(all.first?.contactRaw == "Rahul")
        #expect(all.first?.entityID == (try store.findPerson(named: "Rahul")))
    }

    @Test func secretsNeverReachTheDatabase() async throws {
        let recorder = MemoryRecorder(store: store)
        await recorder.observe(sample("here is the key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", 0))
        await recorder.observe(sample("", 1))
        #expect(try store.recentEpisodes().first?.text == "here is the key [redacted]")
    }

    @Test func generatedThenSentIsStoredOnce() async throws {
        let recorder = MemoryRecorder(store: store)
        let target = TextTarget(pid: 1, appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp", text: "", source: .axSelection)
        await recorder.recordGenerate(inserted: "cant make it bro", target: target, contact: "Rahul", at: t0)
        let s = { (v: String, sec: Double) in FieldSample(fieldKey: "w", bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", windowTitle: "WhatsApp", value: v, at: self.t0.addingTimeInterval(sec)) }
        await recorder.observe(s("cant make it bro", 1))
        await recorder.observe(s("", 2))
        let all = try store.recentEpisodes()
        #expect(all.count == 1)
        #expect(all.first?.kind == .sent)
        // The contact Claude saw is remembered for this window, so later typing is attributed too.
        #expect(all.first?.contactRaw == "Rahul")
        await recorder.observe(s("see you sunday then", 10))
        await recorder.observe(s("", 11))
        #expect(try store.recentEpisodes().first?.contactRaw == "Rahul")
    }

    @Test func contextHasRecentMessagesWithThePersonAndRelatedOnes() async throws {
        let recorder = MemoryRecorder(store: store)
        let rahul = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: rahul, contactRaw: "Rahul", text: "bro sunday brunch?", createdAt: t0.addingTimeInterval(-7200)))
        try store.insert(Episode(kind: .sent, surface: "slack", text: "the party budget is 5k", createdAt: t0.addingTimeInterval(-86_400 * 3)))
        try store.insert(Episode(kind: .draft, surface: "slack", text: "party draft never sent"))
        let target = TextTarget(pid: 1, bundleID: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp", text: "", source: .axSelection)
        let context = try #require(await recorder.context(instruction: "sorry to rahul cant come to the party", target: target))
        #expect(context.contains("Your recent messages with Rahul"))
        #expect(context.contains("bro sunday brunch?"))
        #expect(context.contains("the party budget is 5k"))
        #expect(!context.contains("never sent"))
        #expect(context.count <= ContextBuilder.maxCharacters + 1)
    }

    @Test func noMemoryMeansNoContext() async throws {
        let recorder = MemoryRecorder(store: store)
        let target = TextTarget(pid: 1, text: "", source: .axSelection)
        #expect(await recorder.context(instruction: "hello", target: target) == nil)
    }
}

@MainActor
struct MemoryHookTests {
    @Test func generatePassesMemoryAndReportsInsert() async throws {
        let target = TextTarget(pid: 42, appName: "WhatsApp", text: "", source: .axSelection, range: NSRange(location: 0, length: 0), fullValue: "")
        let driver = FakeDriver(.target(target))
        let inputs = InputLog()
        let inserted = InsertLog()
        let c = GenerateController(
            driver: driver,
            screenshotter: { _ in nil },
            generator: { input in
                AsyncThrowingStream { cont in
                    Task { await inputs.record(input); cont.yield(GenerateDraft(contact: "Rahul", variants: [.casual: "hi"])); cont.finish() }
                }
            },
            memory: { _, _ in "Your recent messages with Rahul:\n- hey" },
            onInserted: { text, _, contact in await inserted.add(text, contact) }
        )
        await c.start()
        c.submit("say hi")
        for _ in 0..<200 where c.phase != .ready { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await inputs.all.first?.memory?.contains("Rahul") == true)
        await c.insert()
        #expect(await inserted.items.first?.0 == "hi")
        #expect(await inserted.items.first?.1 == "Rahul")
        let prompt = GeneratePrompt.userPrompt(await inputs.all.first!)
        #expect(prompt.contains("<memory>"))
    }

    @Test func fixReportsTheFixedText() async throws {
        let target = TextTarget(pid: 42, text: "hey", source: .axSelection, range: NSRange(location: 0, length: 3), fullValue: "hey")
        let driver = FakeDriver(.target(target), value: "hey")
        let log = InsertLog()
        let c = FixController(driver: driver, fixer: { _ in "Hey." }, hideAfter: .seconds(60), onFixed: { text, _ in await log.add(text, nil) })
        await c.fix()
        #expect(await log.items.map(\.0) == ["Hey."])
    }
}

actor InsertLog {
    var items: [(String, String?)] = []
    func add(_ text: String, _ contact: String?) { items.append((text, contact)) }
}
