import Foundation

public enum KeybroPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "keybro", directoryHint: .isDirectory)
    }

    public static var claudeWorkingDirectory: URL {
        appSupport.appending(path: "claude-cwd", directoryHint: .isDirectory)
    }

    /// User-visible memory folder (plan section 4).
    public static var memory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "keybro-memory", directoryHint: .isDirectory)
    }
}
