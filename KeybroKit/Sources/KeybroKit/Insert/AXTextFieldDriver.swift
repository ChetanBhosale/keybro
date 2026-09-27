import AppKit
import ApplicationServices

/// Reads and writes the focused text field of the frontmost app.
///
/// Order of preference:
/// 1. Accessibility read and write (native apps). Writes are read back to confirm.
/// 2. Clipboard: ⌘C to read, paste to write, then restore the user's clipboard.
///    Covers Chrome, Electron and other apps that ignore Accessibility writes.
@MainActor
public final class AXTextFieldDriver: TextFieldDriver {
    /// Beyond this the target is probably a whole page, not a message.
    static let maxCharacters = 4000
    private var manualAccessibilityPIDs: Set<pid_t> = []

    public init() {}

    public func capture() async -> CaptureResult {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            return .nothingToFix(anchor: nil)
        }
        let pid = app.processIdentifier
        if manualAccessibilityPIDs.insert(pid).inserted {
            AX.enableManualAccessibility(pid)
        }

        let element = AX.focusedElement(in: pid)
        let role = element.flatMap { AX.string($0, "AXRole") }
        let subrole = element.flatMap { AX.string($0, "AXSubrole") }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .secureField
        }

        if let element, var target = axTarget(element: element, pid: pid, role: role) {
            target.appName = app.localizedName
            return target.text.count > Self.maxCharacters ? .tooLong(anchor: target.anchor) : .target(target)
        }

        // Accessibility couldn't read it. Fall back to copying.
        await KeySender.waitForModifierRelease()
        let anchor = element.flatMap(AX.frame(of:)) ?? mouseAnchor()
        let snapshot = PasteboardSnapshot.take()
        defer { snapshot.restore() }

        NSPasteboard.general.clearContents()
        var source = TextTarget.Source.clipboardSelection
        var copied = await copy()
        // Only select-all when we know focus is in a text field, never on a page or a file list.
        if (copied ?? "").isEmpty, let role, AX.textRoles.contains(role) {
            KeySender.command(.a)
            try? await Task.sleep(for: .milliseconds(40))
            copied = await copy()
            source = .clipboardSelectAll
        }
        guard let text = copied, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothingToFix(anchor: anchor)
        }
        if text.count > Self.maxCharacters { return .tooLong(anchor: anchor) }
        return .target(TextTarget(pid: pid, appName: app.localizedName, text: text, source: source, anchor: anchor, element: element))
    }

    public func captureForInsert() async -> CaptureResult {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            return .nothingToFix(anchor: nil)
        }
        let pid = app.processIdentifier
        if manualAccessibilityPIDs.insert(pid).inserted {
            AX.enableManualAccessibility(pid)
        }
        let element = AX.focusedElement(in: pid)
        let role = element.flatMap { AX.string($0, "AXRole") }
        let subrole = element.flatMap { AX.string($0, "AXSubrole") }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .secureField
        }

        if let element, let value = AX.string(element, "AXValue"),
           let selection = AX.range(element, "AXSelectedTextRange"),
           NSMaxRange(selection) <= (value as NSString).length {
            let selected = (value as NSString).substring(with: selection)
            let caret = NSRange(location: NSMaxRange(selection), length: 0)
            let anchor = AX.bounds(of: caret, in: element) ?? AX.frame(of: element)
            return .target(TextTarget(pid: pid, appName: app.localizedName, text: selected, source: .axSelection,
                                      range: selection, fullValue: value, anchor: anchor, element: element))
        }

        // Accessibility can't see the field: insert by pasting at the caret. No ⌘C probe here,
        // because some editors copy the whole line when nothing is selected.
        let anchor = element.flatMap(AX.frame(of:)) ?? mouseAnchor()
        return .target(TextTarget(pid: pid, appName: app.localizedName, text: "", source: .clipboardSelection, anchor: anchor, element: element))
    }

    public func activate(pid: pid_t) async -> Bool {
        if frontmostPID() == pid { return true }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        app.activate()
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(20))
            if frontmostPID() == pid { return true }
        }
        return false
    }

    private func axTarget(element: AXUIElement, pid: pid_t, role: String?) -> TextTarget? {
        guard let value = AX.string(element, "AXValue") else { return nil }
        let full = value as NSString

        if let selected = AX.string(element, "AXSelectedText"), !selected.isEmpty,
           let range = AX.range(element, "AXSelectedTextRange"),
           NSMaxRange(range) <= full.length,
           full.substring(with: range) == selected {
            let anchor = AX.bounds(of: range, in: element) ?? AX.frame(of: element)
            return TextTarget(pid: pid, text: selected, source: .axSelection, range: range, fullValue: value, anchor: anchor, element: element)
        }

        guard let role, AX.textRoles.contains(role),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let range = NSRange(location: 0, length: full.length)
        let caret = AX.range(element, "AXSelectedTextRange").map { NSRange(location: $0.location, length: 0) }
        let anchor = caret.flatMap { AX.bounds(of: $0, in: element) } ?? AX.frame(of: element)
        return TextTarget(pid: pid, text: value, source: .axWholeValue, range: range, fullValue: value, anchor: anchor, element: element)
    }

    public func currentValue(of target: TextTarget) -> String? {
        target.element.flatMap { AX.string($0, "AXValue") }
    }

    public func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func replace(_ target: TextTarget, with text: String) async -> ReplaceOutcome {
        switch target.source {
        case .axSelection, .axWholeValue:
            guard let element = target.element, let range = target.range, let before = target.fullValue else { return .failed }
            if AX.isSettable(element, "AXSelectedText") {
                AX.setRange(element, "AXSelectedTextRange", range)
                AX.setString(element, "AXSelectedText", text)
                let expected = (before as NSString).replacingCharacters(in: range, with: text)
                switch await readBack(element, expected: expected, unchanged: before) {
                case .matched: return .accessibility(NSRange(location: range.location, length: (text as NSString).length))
                case .changedDifferently: return .unverified
                case .unchanged: break // The app ignored the write. Paste instead.
                }
            }
            AX.setRange(element, "AXSelectedTextRange", range)
            return await paste(text)

        case .clipboardSelection, .clipboardSelectAll:
            // The selection from capture is still active, so paste replaces it.
            return await paste(text)
        }
    }

    public func undo(_ target: TextTarget, outcome: ReplaceOutcome, original: String, fixed: String) async {
        if case .accessibility(let range) = outcome, let element = target.element {
            AX.setRange(element, "AXSelectedTextRange", range)
            if AX.setString(element, "AXSelectedText", original) { return }
        }
        // Pasted or unverified: the app's own undo reverts the paste.
        KeySender.command(.z)
    }

    public func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Helpers

    private func copy() async -> String? {
        let count = NSPasteboard.general.changeCount
        KeySender.command(.c)
        return await Pasteboard.waitForString(after: count)
    }

    private func paste(_ text: String) async -> ReplaceOutcome {
        await KeySender.waitForModifierRelease()
        let snapshot = PasteboardSnapshot.take()
        Pasteboard.writeTransient(text)
        KeySender.command(.v)
        // Apps read the pasteboard asynchronously; Electron can take a few hundred ms.
        try? await Task.sleep(for: .milliseconds(350))
        snapshot.restore()
        return .pasted
    }

    private enum ReadBack { case matched, unchanged, changedDifferently }

    private func readBack(_ element: AXUIElement, expected: String, unchanged: String) async -> ReadBack {
        var latest: String?
        for _ in 0..<10 {
            latest = AX.string(element, "AXValue")
            if latest == expected { return .matched }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return latest == unchanged ? .unchanged : .changedDifferently
    }

    private func mouseAnchor() -> CGRect {
        let p = NSEvent.mouseLocation
        return CGRect(x: p.x, y: p.y, width: 1, height: 1)
    }
}
