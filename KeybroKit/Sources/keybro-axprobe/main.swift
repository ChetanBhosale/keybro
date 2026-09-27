import AppKit
import KeybroKit

// Dev tool: runs Fix end to end against a scratch TextEdit document.
// Needs the terminal to have Accessibility access. Closes the document without saving.
// Don't touch the keyboard or mouse while it runs: it acts on whatever app is in front,
// so it stops as soon as TextEdit isn't frontmost.
// Usage: swift run keybro-axprobe

@MainActor
func osascript(_ source: String) -> String? {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { print("  applescript error: \(error)") }
    return result?.stringValue
}

@MainActor
func documentText() -> String {
    osascript(#"tell application "TextEdit" to get text of document "keybro-probe""#) ?? "<none>"
}

@MainActor
func requireTextEditInFront(_ step: String) {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
        print("STOP \(step): TextEdit isn't frontmost (did you click away?). Nothing else was touched.")
        _ = osascript(#"tell application "TextEdit" to close (every document whose name is "keybro-probe") saving no"#)
        exit(2)
    }
}

var failures = 0
@MainActor func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "PASS \(name)" : "FAIL \(name) \(detail())")
    if !ok { failures += 1 }
}

guard let claude = ClaudeLocator.live.locate() else { print("claude not found"); exit(1) }
let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
let original = "hey can u check the pr i think its braking the build"

_ = osascript("""
tell application "TextEdit"
    make new document with properties {name:"keybro-probe", text:"\(original)"}
    activate
end tell
""")
try await Task.sleep(for: .seconds(1.5))

let driver = AXTextFieldDriver()
let fixer = ClaudeFixer(runner: ClaudeRunner(executablePath: claude), style: nil)
let controller = FixController(driver: driver, fixer: { text, _ in try await fixer.fix(text) }, hideAfter: .seconds(60))

// 1. Nothing selected: fixes the whole field.
requireTextEditInFront("whole field")
if case .target(let t) = await driver.capture() {
    check("capture whole field", t.source == .axWholeValue && t.text == original, "source=\(t.source) text=\(t.text)")
    check("anchor found", t.anchor != nil)
} else {
    check("capture whole field", false, "no target")
}
let start = ContinuousClock.now
await controller.fix()
print("  fix took \(ContinuousClock.now - start), state=\(controller.state)")
let fixed = documentText()
print("  after fix: \(fixed)")
check("whole field fixed", fixed != original && fixed.lowercased().contains("breaking"), fixed)

requireTextEditInFront("undo")
await controller.undo()
try await Task.sleep(for: .milliseconds(200))
check("undo restores original", documentText() == original, documentText())

// 2. Selection only: select the second half, fix just that.
let tail = "i think its braking the build"
let tailStart = (original as NSString).range(of: tail).location
// Raise the probe window: TextEdit may also show its Open panel or other documents.
_ = osascript("""
tell application "TextEdit"
    activate
    set index of (first window whose name is "keybro-probe") to 1
end tell
""")
try await Task.sleep(for: .milliseconds(300))
if let app = NSWorkspace.shared.frontmostApplication {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var focused: CFTypeRef?
    AXUIElementCopyAttributeValue(element, "AXFocusedUIElement" as CFString, &focused)
    if let focused {
        var range = CFRange(location: tailStart, length: (tail as NSString).length)
        AXUIElementSetAttributeValue(focused as! AXUIElement, "AXSelectedTextRange" as CFString, AXValueCreate(.cfRange, &range)!)
    }
}
try await Task.sleep(for: .milliseconds(300))
requireTextEditInFront("selection")
let selectionCapture = await driver.capture()
if case .target(let t) = selectionCapture {
    check("capture selection", t.source == .axSelection && t.text == tail, "source=\(t.source) text=\(t.text)")
} else {
    check("capture selection", false, "\(selectionCapture)")
}
await controller.fix()
print("  state=\(controller.state)")
let partial = documentText()
print("  after selection fix: \(partial)")
check("prefix untouched", partial.hasPrefix("hey can u check the pr "), partial)
check("selection fixed", !partial.hasSuffix(tail), partial)

_ = osascript(#"tell application "TextEdit" to close document "keybro-probe" saving no"#)
if !wasRunning { _ = osascript(#"tell application "TextEdit" to quit"#) }

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
