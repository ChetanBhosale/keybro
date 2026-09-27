import Foundation
import KeybroKit
import Observation

/// What keybro may remember. Stored in UserDefaults.
@MainActor
@Observable
final class MemorySettings {
    private static let enabledKey = "memory.rememberTyping"
    private static let blockedKey = "memory.blockedApps"

    var rememberTyping: Bool {
        didSet { UserDefaults.standard.set(rememberTyping, forKey: Self.enabledKey) }
    }
    var blockedApps: Set<String> {
        didSet { UserDefaults.standard.set(Array(blockedApps).sorted(), forKey: Self.blockedKey) }
    }
    /// Not persisted: a pause ends when keybro quits.
    var pausedUntil: Date?

    init() {
        rememberTyping = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        blockedApps = (UserDefaults.standard.array(forKey: Self.blockedKey) as? [String]).map(Set.init) ?? TypingWatcher.defaultBlockedApps
    }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    /// Typing capture is on right now.
    var isCapturing: Bool { rememberTyping && !isPaused }

    func pause(for duration: TimeInterval) { pausedUntil = Date().addingTimeInterval(duration) }
    func resume() { pausedUntil = nil }

    func isBlocked(_ bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return blockedApps.contains(bundleID)
    }
}
