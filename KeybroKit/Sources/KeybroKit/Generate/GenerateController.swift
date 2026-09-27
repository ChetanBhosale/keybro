import Foundation
import Observation

@MainActor
@Observable
public final class GenerateController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Command bar open, waiting for the instruction.
        case composing
        case generating
        /// Draft ready: ↵ inserts, typing refines.
        case ready
        case inserting
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var target: TextTarget?
    public private(set) var draft = GenerateDraft()
    public var selected: DraftVariant = .casual
    public private(set) var hasScreenshot = false
    public private(set) var instruction = ""

    public typealias Screenshotter = @Sendable (pid_t) async -> ClaudeImage?
    public typealias Generator = @Sendable (GenerateInput) -> AsyncThrowingStream<GenerateDraft, Error>

    private let driver: TextFieldDriver
    private let screenshotter: Screenshotter
    private let generator: Generator
    private var screenshotTask: Task<ClaudeImage?, Never>?
    private var generateTask: Task<Void, Never>?

    public init(driver: TextFieldDriver, screenshotter: @escaping Screenshotter, generator: @escaping Generator) {
        self.driver = driver
        self.screenshotter = screenshotter
        self.generator = generator
    }

    public var isOpen: Bool { phase != .idle && phase != .inserting }

    /// The version ↵ would insert.
    public var currentText: String? {
        draft.variants[selected] ?? DraftVariant.allCases.lazy.compactMap { self.draft.variants[$0] }.first
    }

    /// Hotkey entry point.
    public func start() async {
        if phase != .idle { cancel() }
        switch await driver.captureForInsert() {
        case .target(let t):
            target = t
        case .noAccess:
            return fail("keybro needs Accessibility access. Open Setup from the menu bar.")
        case .secureField:
            return fail("Password fields are skipped.")
        case .nothingToFix, .tooLong:
            return fail("Click into a text field first.")
        }
        let pid = target!.pid
        let screenshotter = screenshotter
        screenshotTask = Task { await screenshotter(pid) }
        phase = .composing
    }

    /// ↵ in the command bar. Empty text on a ready draft inserts it; anything else generates.
    public func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .composing:
            guard !text.isEmpty else { return }
            instruction = text
            run(GenerateInput(appName: target?.appName, instruction: text, selectedText: target?.text))
        case .ready:
            if text.isEmpty {
                Task { await insert() }
            } else {
                run(GenerateInput(appName: target?.appName, instruction: instruction, selectedText: target?.text,
                                  previousDraft: currentText, change: text))
            }
        case .failed where target != nil && !instruction.isEmpty:
            // Retry after an error, keeping the context.
            run(GenerateInput(appName: target?.appName, instruction: text.isEmpty ? instruction : text, selectedText: target?.text))
        default:
            return
        }
    }

    public func select(_ variant: DraftVariant) {
        guard draft.variants[variant] != nil else { return }
        selected = variant
    }

    public func moveSelection(by offset: Int) {
        let available = DraftVariant.allCases.filter { draft.variants[$0] != nil }
        guard let index = available.firstIndex(of: selected) else {
            if let first = available.first { selected = first }
            return
        }
        selected = available[(index + offset + available.count) % available.count]
    }

    public func cancel() {
        generateTask?.cancel()
        screenshotTask?.cancel()
        generateTask = nil
        screenshotTask = nil
        reset()
    }

    private func run(_ baseInput: GenerateInput) {
        generateTask?.cancel()
        phase = .generating
        let previous = draft
        draft = GenerateDraft()
        generateTask = Task {
            var input = baseInput
            input.screenshot = await screenshotTask?.value
            hasScreenshot = input.screenshot != nil
            do {
                for try await update in generator(input) {
                    try Task.checkCancellation()
                    draft = update
                    if let contact = update.contact { draft.contact = contact }
                    if draft.variants[selected] == nil, let first = DraftVariant.allCases.first(where: { update.variants[$0] != nil }) {
                        selected = first
                    }
                }
                phase = .ready
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if draft.isEmpty { draft = previous }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    public func insert() async {
        guard phase == .ready, let target, let text = currentText, !text.isEmpty else { return }
        phase = .inserting

        guard await driver.activate(pid: target.pid) else {
            driver.copyToClipboard(text)
            return fail("Couldn't switch back to \(target.appName ?? "the app"). The message is on your clipboard.", keepOpen: false)
        }

        var destination = target
        if target.source == .axSelection {
            // Re-read the caret: the field may have scrolled or changed while the bar was open.
            if case .target(let fresh) = await driver.captureForInsert(), fresh.pid == target.pid {
                if !target.text.isEmpty && fresh.text != target.text {
                    driver.copyToClipboard(text)
                    return fail("The selection changed, so nothing was replaced. The message is on your clipboard.", keepOpen: false)
                }
                destination = fresh
            }
        }

        if await driver.replace(destination, with: text) == .failed {
            driver.copyToClipboard(text)
            return fail("Couldn't type into \(target.appName ?? "this app"). The message is on your clipboard.", keepOpen: false)
        }
        reset()
    }

    private func fail(_ message: String, keepOpen: Bool = true) {
        phase = .failed(message)
        if !keepOpen { target = nil }
    }

    private func reset() {
        phase = .idle
        target = nil
        draft = GenerateDraft()
        selected = .casual
        hasScreenshot = false
        instruction = ""
    }
}
