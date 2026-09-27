import AppKit
import ApplicationServices

/// Reads the focused text field about once a second and feeds it to memory.
/// Polling rather than AX notifications: Electron and web views don't send them reliably.
/// Skips password fields, blocked apps, keybro itself, and anything while paused.
@MainActor
public final class TypingWatcher {
    public static let defaultBlockedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences",
        // Terminals: commands often carry tokens.
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
    ]

    private let recorder: MemoryRecorder
    private let isEnabled: @MainActor () -> Bool
    private let isBlocked: @MainActor (String?) -> Bool
    private var timer: Timer?
    private var manualAccessibilityPIDs: Set<pid_t> = []
    /// Native chat apps whose window title doesn't carry the conversation name.
    static let headerApps: Set<String> = ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS"]
    private var lastHeaderRead = Date.distantPast

    public init(recorder: MemoryRecorder, isEnabled: @escaping @MainActor () -> Bool, isBlocked: @escaping @MainActor (String?) -> Bool) {
        self.recorder = recorder
        self.isEnabled = isEnabled
        self.isBlocked = isBlocked
    }

    public func start(interval: TimeInterval = 1) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        let recorder = recorder
        Task { await recorder.observe(nil) }
    }

    private func tick() {
        let sample = isEnabled() && AXIsProcessTrusted() ? currentSample() : nil
        let recorder = recorder
        Task { await recorder.observe(sample) }
    }

    private func currentSample() -> FieldSample? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              !isBlocked(app.bundleIdentifier)
        else { return nil }
        let pid = app.processIdentifier
        if manualAccessibilityPIDs.insert(pid).inserted { AX.enableManualAccessibility(pid) }

        guard let element = AX.focusedElement(in: pid),
              let role = AX.string(element, "AXRole"), AX.textRoles.contains(role),
              AX.string(element, "AXSubrole") != "AXSecureTextField",
              let value = AX.string(element, "AXValue")
        else { return nil }

        let windowTitle = AX.focusedWindowTitle(in: pid)
        if let bundleID = app.bundleIdentifier, Self.headerApps.contains(bundleID) {
            // Switching chats keeps the same field and window title, so re-read every few seconds.
            if Date().timeIntervalSince(lastHeaderRead) >= 3 {
                lastHeaderRead = Date()
                if let name = AX.conversationHeader(in: pid, appName: app.localizedName) {
                    let recorder = recorder
                    Task { await recorder.noteHeader(name, bundleID: bundleID, windowTitle: windowTitle) }
                }
            }
        }

        return FieldSample(
            fieldKey: "\(pid)-\(CFHash(element))",
            bundleID: app.bundleIdentifier,
            appName: app.localizedName,
            windowTitle: windowTitle,
            value: value,
            at: Date()
        )
    }
}
