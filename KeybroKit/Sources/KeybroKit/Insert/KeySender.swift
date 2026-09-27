import CoreGraphics
import Foundation

/// Posts ⌘-shortcuts to the frontmost app. Needs Accessibility access.
public enum KeySender {
    /// ANSI virtual key codes.
    public enum Key: CGKeyCode, Sendable {
        case a = 0x00
        case c = 0x08
        case v = 0x09
        case z = 0x06
    }

    public static func command(_ key: Key) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The hotkey fires while ⌘⇧ are still held. Posting ⌘C then would arrive as ⌘⇧C,
    /// so wait (briefly) for the user to let go.
    public static func waitForModifierRelease(timeout: Duration = .milliseconds(800)) async {
        let held: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}
