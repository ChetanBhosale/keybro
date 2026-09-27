import ApplicationServices
import Foundation
import Observation

/// Text grabbed from the focused field.
public struct FixTarget: @unchecked Sendable {
    public enum Source: Equatable, Sendable {
        /// Selected text read through Accessibility.
        case axSelection
        /// The whole field read through Accessibility (nothing selected).
        case axWholeValue
        /// Selection copied with ⌘C because Accessibility couldn't read it.
        case clipboardSelection
        /// ⌘A then ⌘C inside a text field Accessibility couldn't read.
        case clipboardSelectAll
    }

    public var pid: pid_t
    public var text: String
    public var source: Source
    /// UTF-16 range of `text` inside `fullValue` (Accessibility sources only).
    public var range: NSRange?
    /// Whole field value when captured, used to detect edits made while Claude runs.
    public var fullValue: String?
    /// Where to show the pill, in AppKit screen coordinates.
    public var anchor: CGRect?
    public var element: AXUIElement?

    public init(pid: pid_t, text: String, source: Source, range: NSRange? = nil, fullValue: String? = nil, anchor: CGRect? = nil, element: AXUIElement? = nil) {
        self.pid = pid
        self.text = text
        self.source = source
        self.range = range
        self.fullValue = fullValue
        self.anchor = anchor
        self.element = element
    }
}

public enum CaptureResult: Sendable {
    case target(FixTarget)
    case noAccess
    case secureField
    case nothingToFix(anchor: CGRect?)
    case tooLong(anchor: CGRect?)
}

public enum ReplaceOutcome: Equatable, Sendable {
    /// Written through Accessibility and read back. Range is the inserted text.
    case accessibility(NSRange)
    /// Written through Accessibility but the app didn't report the expected value back.
    case unverified
    case pasted
    case failed
}

/// Reads and writes the focused text field. The real one uses Accessibility; tests use a fake.
@MainActor
public protocol TextFieldDriver: AnyObject {
    func capture() async -> CaptureResult
    func currentValue(of target: FixTarget) -> String?
    func frontmostPID() -> pid_t?
    func replace(_ target: FixTarget, with text: String) async -> ReplaceOutcome
    func undo(_ target: FixTarget, outcome: ReplaceOutcome, original: String, fixed: String) async
    func copyToClipboard(_ text: String)
}

public enum FixState: Equatable, Sendable {
    case idle
    case working(anchor: CGRect?)
    case done(anchor: CGRect?, changed: Bool)
    case failed(anchor: CGRect?, message: String)

    public var anchor: CGRect? {
        switch self {
        case .idle: nil
        case .working(let a), .done(let a, _), .failed(let a, _): a
        }
    }
}

@MainActor
@Observable
public final class FixController {
    public private(set) var state: FixState = .idle

    public typealias Fixer = @Sendable (String) async throws -> String

    private let driver: TextFieldDriver
    private let fixer: Fixer
    private let hideAfter: Duration
    private var runTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var last: (target: FixTarget, outcome: ReplaceOutcome, original: String, fixed: String)?

    public init(driver: TextFieldDriver, fixer: @escaping Fixer, hideAfter: Duration = .seconds(5)) {
        self.driver = driver
        self.fixer = fixer
        self.hideAfter = hideAfter
    }

    /// Hotkey entry point.
    public func trigger() {
        guard runTask == nil else { return }
        runTask = Task {
            await fix()
            runTask = nil
        }
    }

    public func cancel() {
        runTask?.cancel()
    }

    public func fix() async {
        if case .working = state { return }
        hideTask?.cancel()
        last = nil

        let target: FixTarget
        switch await driver.capture() {
        case .target(let t):
            target = t
        case .noAccess:
            return finish(.failed(anchor: nil, message: "keybro needs Accessibility access. Open Setup from the menu bar."))
        case .secureField:
            return finish(.failed(anchor: nil, message: "Password fields are skipped."))
        case .nothingToFix(let anchor):
            return finish(.failed(anchor: anchor, message: "Nothing to fix. Type or select some text first."))
        case .tooLong(let anchor):
            return finish(.failed(anchor: anchor, message: "That's a lot of text. Select the part you want fixed."))
        }

        state = .working(anchor: target.anchor)

        let raw: String
        do {
            raw = try await fixer(target.text)
        } catch is CancellationError {
            return finish(.idle)
        } catch {
            if Task.isCancelled { return finish(.idle) }
            return finish(.failed(anchor: target.anchor, message: error.localizedDescription))
        }
        if Task.isCancelled { return finish(.idle) }

        let fixed = FixOutput.clean(raw, original: target.text)
        if fixed == target.text {
            return finish(.done(anchor: target.anchor, changed: false))
        }

        guard driver.frontmostPID() == target.pid else {
            driver.copyToClipboard(fixed)
            return finish(.failed(anchor: nil, message: "You switched apps, so nothing was replaced. The fixed text is on your clipboard."))
        }
        if let before = target.fullValue, let now = driver.currentValue(of: target), now != before {
            return finish(.failed(anchor: target.anchor, message: "The text changed while fixing, so nothing was replaced."))
        }

        let outcome = await driver.replace(target, with: fixed)
        if outcome == .failed {
            driver.copyToClipboard(fixed)
            return finish(.failed(anchor: target.anchor, message: "Couldn't replace the text in this app. The fixed text is on your clipboard."))
        }
        last = (target, outcome, target.text, fixed)
        finish(.done(anchor: target.anchor, changed: true))
    }

    public var canUndo: Bool { last != nil }

    public func undo() async {
        guard let last else { return }
        self.last = nil
        hideTask?.cancel()
        state = .idle
        await driver.undo(last.target, outcome: last.outcome, original: last.original, fixed: last.fixed)
    }

    public func dismiss() {
        hideTask?.cancel()
        if case .working = state { cancel(); return }
        state = .idle
    }

    private func finish(_ newState: FixState) {
        state = newState
        guard newState != .idle else { return }
        hideTask?.cancel()
        hideTask = Task { [hideAfter] in
            try? await Task.sleep(for: hideAfter)
            guard !Task.isCancelled else { return }
            self.state = .idle
            self.last = nil
        }
    }
}
