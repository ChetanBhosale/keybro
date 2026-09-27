import Testing
@testable import KeybroKit

struct ClaudeRequestTests {
    @Test func oneShotUsesLeanFlagsAndSkipsPersistence() {
        let args = ClaudeRequest(prompt: "fix this").arguments
        #expect(Array(args.prefix(2)) == ["-p", "fix this"])
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        #expect(!args.contains("--bare")) // --bare drops the Claude login
        let i = try! #require(args.firstIndex(of: "--setting-sources"))
        #expect(args[i + 1] == "")
        #expect(!args.contains("--resume"))
        #expect(!args.contains("--allowedTools"))
    }

    @Test func generateFirstCallPersistsSession() {
        let args = ClaudeRequest(prompt: "p", model: .sonnet, allowedTools: ["Read"], addDirs: ["/m"], persistSession: true).arguments
        #expect(!args.contains("--no-session-persistence"))
        #expect(args.contains("sonnet"))
        let t = try! #require(args.firstIndex(of: "--allowedTools"))
        #expect(args[t + 1] == "Read")
        let d = try! #require(args.firstIndex(of: "--add-dir"))
        #expect(args[d + 1] == "/m")
    }

    @Test func refineResumesSession() {
        let args = ClaudeRequest(prompt: "shorter", resumeSessionID: "abc").arguments
        let r = try! #require(args.firstIndex(of: "--resume"))
        #expect(args[r + 1] == "abc")
        #expect(!args.contains("--no-session-persistence"))
    }

    @Test func fixRequestIsLeanNoToolsNoThinking() {
        let request = ClaudeFixer(runner: ClaudeRunner(executablePath: "/x"), style: nil).request(for: "hey")
        let args = request.arguments
        #expect(args[1] == "<text>hey</text>")
        let s = try! #require(args.firstIndex(of: "--system-prompt"))
        #expect(args[s + 1].contains("You fix the English"))
        let t = try! #require(args.firstIndex(of: "--tools"))
        #expect(args[t + 1] == "")
        let st = try! #require(args.firstIndex(of: "--settings"))
        #expect(args[st + 1] == #"{"alwaysThinkingEnabled":false}"#)
        #expect(request.environment == ["MAX_THINKING_TOKENS": "0"])
        #expect(args.contains("haiku"))
    }

    @Test func defaultsKeepClaudeCodeBehaviour() {
        let request = ClaudeRequest(prompt: "p")
        #expect(!request.arguments.contains("--system-prompt"))
        #expect(!request.arguments.contains("--tools"))
        #expect(!request.arguments.contains("--settings"))
        #expect(request.environment.isEmpty)
    }

    @Test func environmentPutsClaudeDirFirstAndDropsNestedMarker() {
        let env = ClaudeRunner.environment(executablePath: "/Users/x/.local/bin/claude")
        #expect(env["PATH"]?.hasPrefix("/Users/x/.local/bin:") == true)
        #expect(env["CLAUDECODE"] == nil)
        let parts = env["PATH"]!.split(separator: ":")
        #expect(parts.count == Set(parts).count)
    }
}
