import ApplicationServices
import Foundation
import Observation

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
    public typealias FixedHandler = @Sendable (String, TextTarget) async -> Void

    private let driver: TextFieldDriver
    private let fixer: Fixer
    private let hideAfter: Duration
    private let onFixed: FixedHandler?
    private var runTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var last: (target: TextTarget, outcome: ReplaceOutcome, original: String, fixed: String)?

    public init(driver: TextFieldDriver, fixer: @escaping Fixer, hideAfter: Duration = .seconds(5), onFixed: FixedHandler? = nil) {
        self.driver = driver
        self.fixer = fixer
        self.hideAfter = hideAfter
        self.onFixed = onFixed
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

        let target: TextTarget
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
        await onFixed?(fixed, target)
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
