import Testing
@testable import KeybroKit

struct ClaudeErrorTests {
    func classify(stderr: String = "", result: String? = nil, status: Int? = nil, timedOut: Bool = false, exit: Int32 = 1) -> ClaudeError {
        ClaudeError.classify(exitCode: exit, stderr: stderr, resultText: result, apiErrorStatus: status, timedOut: timedOut)
    }

    @Test func timeoutWinsOverEverything() {
        #expect(classify(stderr: "rate limit", timedOut: true) == .timedOut)
    }

    @Test(arguments: [
        "Invalid API key · Please run /login",
        "Not logged in",
        "OAuth token has expired",
    ])
    func loginProblems(_ text: String) {
        #expect(classify(result: text) == .notLoggedIn)
    }

    @Test func status401IsLogin() {
        #expect(classify(status: 401) == .notLoggedIn)
    }

    @Test func rateLimitKeepsFirstLineOfResult() {
        #expect(classify(result: "Claude usage limit reached. Resets 5pm\nmore", status: 429) == .rateLimited("Claude usage limit reached. Resets 5pm"))
    }

    @Test func otherFailuresPreferResultThenStderrThenExitCode() {
        #expect(classify(stderr: "boom", result: "model overloaded") == .failed("model overloaded"))
        #expect(classify(stderr: "\nboom\n") == .failed("boom"))
        #expect(classify(exit: 7) == .failed("exit code 7"))
    }
}
