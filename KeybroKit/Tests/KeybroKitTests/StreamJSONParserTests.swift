import Foundation
import Testing
@testable import KeybroKit

struct StreamJSONParserTests {
    /// Real `claude -p` 2.1.283 output for a Fix call (init and result lines trimmed).
    func fixtureEvents() throws -> [ClaudeEvent] {
        let url = try #require(Bundle.module.url(forResource: "fix-success", withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { StreamJSONParser.parse(String($0)) }
    }

    @Test func fixtureStartsWithSessionAndEndsWithResult() throws {
        let events = try fixtureEvents()
        guard case .started(let sessionID, let model) = events.first else {
            Issue.record("first event should be .started, got \(String(describing: events.first))")
            return
        }
        #expect(sessionID == "62048c43-1890-4676-a3cf-026689754adb")
        #expect(model?.contains("haiku") == true)

        guard case .result(let result) = events.last else {
            Issue.record("last event should be .result")
            return
        }
        #expect(result.isError == false)
        #expect(result.text == "Hey, can you check the PR? It's breaking the build.")
        #expect(result.sessionID == sessionID)
    }

    @Test func textDeltasJoinToFinalResult() throws {
        let events = try fixtureEvents()
        let streamed = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        let final = events.compactMap { if case .result(let r) = $0 { r.text } else { nil } }.first
        #expect(streamed == final)
    }

    @Test func fixtureHasThinkingAndRateLimitEvents() throws {
        let events = try fixtureEvents()
        #expect(events.contains(.thinking))
        #expect(events.contains { if case .rateLimit(status: "allowed", _) = $0 { true } else { false } })
    }

    @Test func ignoresNoiseAndGarbage() {
        #expect(StreamJSONParser.parse("") == nil)
        #expect(StreamJSONParser.parse("not json") == nil)
        #expect(StreamJSONParser.parse(#"{"type":"system","subtype":"status","status":"requesting"}"#) == nil)
        #expect(StreamJSONParser.parse(#"{"type":"stream_event","event":{"type":"message_start"}}"#) == nil)
        #expect(StreamJSONParser.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"x"}}}"#) == nil)
    }

    @Test func errorResultWithoutIsErrorFallsBackToSubtype() {
        let event = StreamJSONParser.parse(#"{"type":"result","subtype":"error_during_execution","session_id":"s1","api_error_status":429}"#)
        #expect(event == .result(ClaudeResult(isError: true, text: "", sessionID: "s1", apiErrorStatus: 429)))
    }
}
