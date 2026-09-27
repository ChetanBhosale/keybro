import ApplicationServices
import Foundation
import Testing
@testable import KeybroKit

@MainActor
final class FakeDriver: TextFieldDriver {
    var captureResult: CaptureResult
    var value: String?
    var pid: pid_t? = 42
    var replaceOutcome: ReplaceOutcome = .accessibility(NSRange(location: 0, length: 0))
    var replaced: [String] = []
    var copied: [String] = []
    var undone: [(ReplaceOutcome, String)] = []

    init(_ capture: CaptureResult, value: String? = nil) {
        captureResult = capture
        self.value = value
    }

    var insertCapture: CaptureResult?
    var activateResult = true
    var activated: [pid_t] = []
    var replacedTargets: [TextTarget] = []

    func capture() async -> CaptureResult { captureResult }
    func captureForInsert() async -> CaptureResult { insertCapture ?? captureResult }
    func activate(pid: pid_t) async -> Bool {
        activated.append(pid)
        return activateResult
    }
    func currentValue(of target: TextTarget) -> String? { value }
    func frontmostPID() -> pid_t? { pid }
    func replace(_ target: TextTarget, with text: String) async -> ReplaceOutcome {
        replaced.append(text)
        replacedTargets.append(target)
        return replaceOutcome
    }
    func undo(_ target: TextTarget, outcome: ReplaceOutcome, original: String, fixed: String) async {
        undone.append((outcome, original))
    }
    func copyToClipboard(_ text: String) { copied.append(text) }
}

actor FixerCalls {
    var inputs: [String] = []
    func record(_ s: String) { inputs.append(s) }
}

@MainActor
struct FixControllerTests {
    let calls = FixerCalls()

    func target(_ text: String, source: TextTarget.Source = .axSelection, full: String? = nil) -> CaptureResult {
        .target(TextTarget(pid: 42, text: text, source: source, range: NSRange(location: 0, length: (text as NSString).length), fullValue: full ?? text))
    }

    func controller(_ driver: FakeDriver, reply: String = "Hey, can you check the PR?", error: Error? = nil) -> FixController {
        let calls = calls
        return FixController(driver: driver, fixer: { text in
            await calls.record(text)
            if let error { throw error }
            return reply
        }, hideAfter: .seconds(60))
    }

    @Test func fixesSelectionAndReplaces() async {
        let driver = FakeDriver(target("hey can u check the pr"), value: "hey can u check the pr")
        let c = controller(driver)
        await c.fix()
        #expect(await calls.inputs == ["hey can u check the pr"])
        #expect(driver.replaced == ["Hey, can you check the PR?"])
        #expect(c.state == .done(anchor: nil, changed: true))
        #expect(c.canUndo)
    }

    @Test func passwordFieldNeverReachesClaude() async {
        let driver = FakeDriver(.secureField)
        let c = controller(driver)
        await c.fix()
        #expect(await calls.inputs.isEmpty)
        #expect(driver.replaced.isEmpty)
        #expect(c.state == .failed(anchor: nil, message: "Password fields are skipped."))
    }

    @Test func alreadyCorrectTextIsNotRewritten() async {
        let driver = FakeDriver(target("Looks good."), value: "Looks good.")
        let c = controller(driver, reply: "Looks good.")
        await c.fix()
        #expect(driver.replaced.isEmpty)
        #expect(c.state == .done(anchor: nil, changed: false))
    }

    @Test func switchingAppsCopiesInsteadOfTypingIntoTheWrongApp() async {
        let driver = FakeDriver(target("hey"), value: "hey")
        driver.pid = 99
        let c = controller(driver, reply: "Hey.")
        await c.fix()
        #expect(driver.replaced.isEmpty)
        #expect(driver.copied == ["Hey."])
        guard case .failed(_, let message) = c.state else { Issue.record("expected failure"); return }
        #expect(message.contains("clipboard"))
    }

    @Test func editsDuringTheFixAreNotOverwritten() async {
        let driver = FakeDriver(target("hey", full: "hey"), value: "hey there")
        let c = controller(driver, reply: "Hey.")
        await c.fix()
        #expect(driver.replaced.isEmpty)
        guard case .failed(_, let message) = c.state else { Issue.record("expected failure"); return }
        #expect(message.contains("changed"))
    }

    @Test func failedReplaceFallsBackToClipboard() async {
        let driver = FakeDriver(target("hey", source: .clipboardSelection), value: nil)
        driver.replaceOutcome = .failed
        let c = controller(driver, reply: "Hey.")
        await c.fix()
        #expect(driver.copied == ["Hey."])
        #expect(!c.canUndo)
    }

    @Test func claudeErrorsShowTheirMessage() async {
        let driver = FakeDriver(target("hey"), value: "hey")
        let c = controller(driver, error: ClaudeError.notLoggedIn)
        await c.fix()
        #expect(driver.replaced.isEmpty)
        #expect(c.state == .failed(anchor: nil, message: ClaudeError.notLoggedIn.localizedDescription))
    }

    @Test func modelOutputIsCleanedBeforeWriting() async {
        let driver = FakeDriver(target("im stuck cant come "), value: "im stuck cant come ")
        let c = controller(driver, reply: "<text>I'm stuck \u{2014} can't come.</text>")
        await c.fix()
        #expect(driver.replaced == ["I'm stuck, can't come. "])
    }

    @Test func undoRestoresTheOriginal() async {
        let driver = FakeDriver(target("hey"), value: "hey")
        driver.replaceOutcome = .accessibility(NSRange(location: 0, length: 4))
        let c = controller(driver, reply: "Hey.")
        await c.fix()
        await c.undo()
        #expect(driver.undone.count == 1)
        #expect(driver.undone.first?.0 == .accessibility(NSRange(location: 0, length: 4)))
        #expect(driver.undone.first?.1 == "hey")
        #expect(c.state == .idle)
        #expect(!c.canUndo)
    }

    @Test func nothingToFixAndTooLongExplainWhatToDo() async {
        let empty = controller(FakeDriver(.nothingToFix(anchor: nil)))
        await empty.fix()
        guard case .failed(_, let m1) = empty.state else { Issue.record("expected failure"); return }
        #expect(m1.contains("Type or select"))

        let long = controller(FakeDriver(.tooLong(anchor: nil)))
        await long.fix()
        guard case .failed(_, let m2) = long.state else { Issue.record("expected failure"); return }
        #expect(m2.contains("Select the part"))
        #expect(await calls.inputs.isEmpty)
    }

    @Test func stateAutoHides() async throws {
        let driver = FakeDriver(target("hey"), value: "hey")
        let c = FixController(driver: driver, fixer: { _ in "Hey." }, hideAfter: .milliseconds(50))
        await c.fix()
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.state == .idle)
    }
}
