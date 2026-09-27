import AppKit
import ApplicationServices
import CoreGraphics

public enum Permissions {
    public enum Kind: Sendable {
        case accessibility, screenRecording

        var settingsURL: URL {
            switch self {
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    /// Needed to read and write the focused text field.
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Needed only for the Generate screenshot.
    public static var isScreenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; later calls just return the state.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // kAXTrustedCheckOptionPrompt's value; the global isn't concurrency safe in Swift 6.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    public static func openSettings(_ kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
