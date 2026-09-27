import Foundation

/// What the browser extension last saw: which web app and who the conversation is with.
public struct WebContext: Codable, Equatable, Sendable {
    public var surface: String?
    public var contact: String?
    public var title: String?
    public var url: String?
    public var ts: Double

    public init(surface: String?, contact: String?, title: String?, url: String?, ts: Double) {
        self.surface = surface
        self.contact = contact
        self.title = title
        self.url = url
        self.ts = ts
    }

    public static var fileURL: URL { KeybroPaths.memory.appending(path: ".web-context.json") }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL = fileURL) -> WebContext? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WebContext.self, from: data)
    }

    /// Only trust it for the tab that's showing: the browser window title starts with the page title,
    /// and it's recent enough (content scripts report on every change).
    public func matches(windowTitle: String?, now: Date = Date(), maxAge: TimeInterval = 6 * 3600) -> Bool {
        guard let title, !title.isEmpty, let windowTitle, now.timeIntervalSince1970 - ts < maxAge else { return false }
        return windowTitle.hasPrefix(title) || windowTitle.contains(title)
    }
}

/// Chrome native messaging framing: 4-byte little-endian length, then UTF-8 JSON.
public enum NativeMessaging {
    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }

    /// Splits complete messages off the front of `buffer`.
    public static func unframe(_ buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length <= 1_048_576 else { buffer.removeAll(); break }
            guard buffer.count >= 4 + length else { break }
            messages.append(buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length))
            buffer.removeFirst(4 + length)
        }
        return messages
    }
}
