import ApplicationServices
import Foundation

/// A text field in another app: what's selected in it and how to write back.
/// Fix replaces `text`; Generate inserts at `range` (empty when nothing is selected).
public struct TextTarget: @unchecked Sendable {
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
    public var appName: String?
    public var bundleID: String?
    /// Title of the app's focused window; carries the conversation name in some apps.
    public var windowTitle: String?
    public var text: String
    public var source: Source
    /// UTF-16 range of `text` inside `fullValue` (Accessibility sources only).
    public var range: NSRange?
    /// Whole field value when captured, used to detect edits made while Claude runs.
    public var fullValue: String?
    /// Where to show the pill, in AppKit screen coordinates.
    public var anchor: CGRect?
    public var element: AXUIElement?

    public init(pid: pid_t, appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, text: String, source: Source, range: NSRange? = nil, fullValue: String? = nil, anchor: CGRect? = nil, element: AXUIElement? = nil) {
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.text = text
        self.source = source
        self.range = range
        self.fullValue = fullValue
        self.anchor = anchor
        self.element = element
    }
}

public enum CaptureResult: Sendable {
    case target(TextTarget)
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
    /// Fix: the selection, or the whole field.
    func capture() async -> CaptureResult
    /// Generate: where to insert (the caret), plus any selected text to rewrite. Never selects all.
    func captureForInsert() async -> CaptureResult
    /// Brings the app back to the front before writing. False if it didn't come back.
    func activate(pid: pid_t) async -> Bool
    func currentValue(of target: TextTarget) -> String?
    func frontmostPID() -> pid_t?
    func replace(_ target: TextTarget, with text: String) async -> ReplaceOutcome
    func undo(_ target: TextTarget, outcome: ReplaceOutcome, original: String, fixed: String) async
    func copyToClipboard(_ text: String)
}
