import Foundation

public enum KeybroPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "keybro", directoryHint: .isDirectory)
    }

    public static var claudeWorkingDirectory: URL {
        appSupport.appending(path: "claude-cwd", directoryHint: .isDirectory)
    }

    /// User-visible memory folder. `KEYBRO_MEMORY_DIR` points it elsewhere (tests, dev tools).
    public static var memory: URL {
        if let dir = ProcessInfo.processInfo.environment["KEYBRO_MEMORY_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "keybro-memory", directoryHint: .isDirectory)
    }
}
