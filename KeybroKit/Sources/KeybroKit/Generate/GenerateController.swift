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
    /// The current request is a question about the screen; ↵ copies the answer.
    public private(set) var isQuestion = false
    /// Set after ↵ on an answer, so the UI can say "Copied".
    public private(set) var copiedAnswer = false
    /// "/..." typed in the field itself: replaced by the draft on insert.
    private var slashCommand: (range: NSRange, text: String)?

    public typealias Screenshotter = @Sendable (pid_t) async -> ClaudeImage?
    public typealias Generator = @Sendable (GenerateInput) -> AsyncThrowingStream<GenerateDraft, Error>
    /// Memory for this instruction and field, if any.
    public typealias MemoryLookup = @Sendable (String, TextTarget) async -> String?
    /// Called after a draft is inserted: (text, where, contact Claude saw).
    public typealias InsertedHandler = @Sendable (String, TextTarget, String?) async -> Void
    /// Per-app writing instructions for this field.
    public typealias ModeLookup = @Sendable (TextTarget) async -> String?

    private let driver: TextFieldDriver
    private let screenshotter: Screenshotter
    private let generator: Generator
    private let memory: MemoryLookup?
    private let onInserted: InsertedHandler?
    private let modeFor: ModeLookup?
    private var modeText: String??
    public var commands: SavedCommands
    private var screenshotTask: Task<ClaudeImage?, Never>?
    private var generateTask: Task<Void, Never>?
    private var memoryText: String??

    public init(driver: TextFieldDriver, screenshotter: @escaping Screenshotter, generator: @escaping Generator,
                memory: MemoryLookup? = nil, onInserted: InsertedHandler? = nil,
                modeFor: ModeLookup? = nil, commands: SavedCommands = SavedCommands()) {
        self.driver = driver
        self.screenshotter = screenshotter
        self.generator = generator
        self.memory = memory
        self.onInserted = onInserted
        self.modeFor = modeFor
        self.commands = commands
    }

    public var isOpen: Bool { phase != .idle && phase != .inserting }

    /// The version ↵ would insert (or the answer, for questions).
    public var currentText: String? {
        if isQuestion { return draft.answer }
        return draft.variants[selected] ?? DraftVariant.allCases.lazy.compactMap { self.draft.variants[$0] }.first
    }

    /// Hotkey entry point.
    public func start() async {
        if phase != .idle { cancel() }
        copiedAnswer = false
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

        // "/sorry to rahul" typed in the field + hotkey: run it right away.
        if let command = Self.slashLine(in: target!) {
            slashCommand = command
            submit(command.text)
        }
    }

    /// The line before the caret, if it starts with "/" and nothing is selected.
    static func slashLine(in target: TextTarget) -> (range: NSRange, text: String)? {
        guard target.source == .axSelection, target.text.isEmpty, let full = target.fullValue, let caret = target.range?.location else { return nil }
        let ns = full as NSString
        guard caret <= ns.length else { return nil }
        let before = ns.substring(to: caret)
        let newline = (before as NSString).range(of: "\n", options: .backwards)
        let lineStart = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        let line = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), trimmed.count > 2, !trimmed.hasPrefix("//") else { return nil }
        return (NSRange(location: lineStart, length: caret - lineStart), line)
    }

    /// ↵ in the command bar. Empty text on a ready draft inserts it; anything else generates.
    public func submit(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .composing:
            guard !text.isEmpty else { return }
            start(instruction: text)
        case .ready:
            if text.isEmpty {
                Task { await insert() }
            } else if text.hasPrefix("?") || isQuestion {
                start(instruction: text)
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

    /// Expands saved commands, spots questions, then generates.
    private func start(instruction text: String) {
        var instruction = text
        isQuestion = text.hasPrefix("?")
        if isQuestion {
            instruction = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if let expanded = commands.expand(text) {
            instruction = expanded
        } else if text.hasPrefix("/") {
            instruction = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !instruction.isEmpty else { return }
        self.instruction = instruction
        var input = GenerateInput(appName: target?.appName, instruction: instruction, selectedText: target?.text)
        input.isQuestion = isQuestion
        run(input)
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
            if memoryText == nil, let memory, let target {
                memoryText = .some(await memory(baseInput.instruction, target))
            }
            input.memory = memoryText ?? nil
            if modeText == nil, let modeFor, let target {
                modeText = .some(await modeFor(target))
            }
            input.mode = modeText ?? nil
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
        if isQuestion {
            // Answers are for you, not for the field.
            driver.copyToClipboard(text)
            copiedAnswer = true
            reset()
            return
        }
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
                if let slash = slashCommand {
                    // Replace the "/..." line with the message, if it's still there.
                    let full = (fresh.fullValue ?? "") as NSString
                    let end = NSMaxRange(slash.range)
                    let lineEnds = end == full.length || full.substring(with: NSRange(location: end, length: 1)) == "\n"
                    guard end <= full.length, full.substring(with: slash.range) == slash.text, lineEnds else {
                        driver.copyToClipboard(text)
                        return fail("The /command text changed, so nothing was replaced. The message is on your clipboard.", keepOpen: false)
                    }
                    destination.range = slash.range
                }
            }
        }

        if await driver.replace(destination, with: text) == .failed {
            driver.copyToClipboard(text)
            return fail("Couldn't type into \(target.appName ?? "this app"). The message is on your clipboard.", keepOpen: false)
        }
        let contact = draft.contact
        reset()
        await onInserted?(text, destination, contact)
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
        memoryText = nil
        modeText = nil
        isQuestion = false
        slashCommand = nil
    }
}
