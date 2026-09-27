import Foundation
import Testing
@testable import KeybroKit

struct ForgetTests {
    let store = try! MemoryStore()

    @Test func forgetLastHourKeepsOlderMemories() throws {
        let now = Date()
        try store.insert(Episode(kind: .sent, surface: "whatsapp", text: "old one", createdAt: now.addingTimeInterval(-7200)))
        try store.insert(Episode(kind: .sent, surface: "whatsapp", text: "recent one", createdAt: now.addingTimeInterval(-600)))
        #expect(try store.forget(since: now.addingTimeInterval(-3600)) == 1)
        #expect(try store.recentEpisodes().map(\.text) == ["old one"])
        #expect(try store.search("recent").isEmpty)
    }

    @Test func draftEditedRecentlyIsForgottenToo() throws {
        let now = Date()
        let e = try store.insert(Episode(kind: .draft, surface: "slack", text: "started long ago", createdAt: now.addingTimeInterval(-7200)))
        try store.update(episodeID: e.id!, text: "started long ago, edited now", at: now)
        #expect(try store.forget(since: now.addingTimeInterval(-3600)) == 1)
    }

    @Test func deleteEverythingEmptiesPeopleAndSearch() throws {
        let id = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
        try store.insert(Episode(kind: .sent, surface: "whatsapp", entityID: id, text: "hello rahul"))
        try store.deleteEverything()
        #expect(try store.episodeCount() == 0)
        #expect(try store.people().isEmpty)
        #expect(try store.search("hello").isEmpty)
        #expect(try store.findPerson(named: "Rahul") == nil)
    }

    @Test func capturedByAppCountsPerSurface() throws {
        let now = Date()
        try store.insert(Episode(kind: .sent, appName: "WhatsApp", surface: "whatsapp", text: "a", createdAt: now))
        try store.insert(Episode(kind: .draft, appName: "WhatsApp", surface: "whatsapp", text: "b", createdAt: now))
        try store.insert(Episode(kind: .sent, appName: "Slack", surface: "slack", text: "c", createdAt: now))
        try store.insert(Episode(kind: .sent, appName: "Slack", surface: "slack", text: "d", createdAt: now.addingTimeInterval(-86_400 * 3)))
        let counts = try store.capturedByApp(since: now.addingTimeInterval(-86_400))
        #expect(counts.map(\.surface) == ["whatsapp", "slack"])
        #expect(counts.map(\.count) == [2, 1])
        #expect(counts.first?.appName == "WhatsApp")
    }
}

struct HotkeyConflictTests {
    @Test func defaultsAreFlagged() {
        #expect(HotkeyConflicts.apps(for: .init(key: "K", command: true, shift: true)).contains { $0.hasPrefix("Slack") })
        #expect(HotkeyConflicts.apps(for: .init(key: "l", command: true, shift: true)).contains { $0.hasPrefix("Safari") })
    }

    @Test func unusualCombosAreClear() {
        #expect(HotkeyConflicts.apps(for: .init(key: "k", command: true, option: true, control: true)).isEmpty)
    }
}
