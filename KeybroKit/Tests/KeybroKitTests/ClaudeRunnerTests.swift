import Foundation
import Testing
@testable import KeybroKit

/// Runs ClaudeRunner against fake `claude` shell scripts, so no network or login is needed.
struct ClaudeRunnerTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "keybro-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func fakeClaude(_ body: String) throws -> ClaudeRunner {
        let script = dir.appending(path: "claude")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ClaudeRunner(executablePath: script.path, workingDirectory: dir.appending(path: "cwd"))
    }

    func collect(_ runner: ClaudeRunner, _ request: ClaudeRequest = ClaudeRequest(prompt: "x")) async -> (events: [ClaudeEvent], error: Error?) {
        var events: [ClaudeEvent] = []
        do {
            for try await event in runner.run(request) { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    @Test func streamsFixtureAndFinishesCleanly() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "fix-success", withExtension: "jsonl", subdirectory: "Fixtures"))
        let runner = try fakeClaude("cat '\(fixture.path)'")
        let (events, error) = await collect(runner)
        #expect(error == nil)
        #expect(events.first.map { if case .started = $0 { true } else { false } } == true)
        #expect(events.last.map { if case .result(let r) = $0 { !r.isError } else { false } } == true)
    }

    @Test func errorResultThrowsClassifiedError() async throws {
        let runner = try fakeClaude(#"""
        echo '{"type":"result","subtype":"success","is_error":true,"result":"Claude usage limit reached","session_id":"s","api_error_status":429}'
        exit 1
        """#)
        let (events, error) = await collect(runner)
        #expect(events.count == 1)
        #expect(error as? ClaudeError == .rateLimited("Claude usage limit reached"))
    }

    @Test func crashWithoutResultUsesStderr() async throws {
        let runner = try fakeClaude("echo 'Not logged in. Please run /login' >&2; exit 1")
        let (_, error) = await collect(runner)
        #expect(error as? ClaudeError == .notLoggedIn)
    }

    @Test func slowProcessTimesOut() async throws {
        let runner = try fakeClaude("exec sleep 30")
        let start = ContinuousClock.now
        let (_, error) = await collect(runner, ClaudeRequest(prompt: "x", timeout: .milliseconds(300)))
        #expect(error as? ClaudeError == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellingTheConsumerKillsTheProcess() async throws {
        let pidFile = dir.appending(path: "pid")
        let runner = try fakeClaude("echo $$ > '\(pidFile.path)'; exec sleep 30")
        let task = Task { await collect(runner) }
        // Wait for the fake process to actually start before cancelling.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0, "fake claude should be running before cancel")
        task.cancel()
        _ = await task.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(pid, 0) != 0, "fake claude should be dead after cancel")
    }

    @Test func missingBinaryIsLaunchFailure() async {
        let runner = ClaudeRunner(executablePath: "/nope/claude", workingDirectory: dir)
        let (_, error) = await collect(runner)
        guard case .launchFailed = error as? ClaudeError else {
            Issue.record("expected launchFailed, got \(String(describing: error))")
            return
        }
    }
}
