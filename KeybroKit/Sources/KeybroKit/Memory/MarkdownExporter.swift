import Foundation

/// Writes memory as plain Markdown notes with [[links]], so any Obsidian vault can open it.
/// Generated files only; the database stays the source of truth.
public enum MarkdownExporter {
    public static var defaultFolder: URL { KeybroPaths.memory.appending(path: "export", directoryHint: .isDirectory) }

    @discardableResult
    public static func export(store: MemoryStore, to folder: URL = defaultFolder, days: Int = 60, now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        let fm = FileManager.default
        let peopleDir = folder.appending(path: "people", directoryHint: .isDirectory)
        let dailyDir = folder.appending(path: "daily", directoryHint: .isDirectory)
        for dir in [peopleDir, dailyDir] {
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)

        let people = try store.people()
        let names = people.map(\.name)
        var written = 0

        for person in people {
            var md = "# \(person.name)\n\n"
            md += "Seen on: \(person.surfaces.joined(separator: ", "))\n\n"
            if let profile = try store.profile(entityID: person.id) {
                md += "## Summary\n\n\(profile.summary)\n\n"
                if !profile.patterns.isEmpty {
                    md += "## Patterns\n\n" + profile.patterns.split(separator: "\n").map { "- \($0)" }.joined(separator: "\n") + "\n\n"
                }
            }
            let history = try store.factHistory(entityID: person.id)
            if !history.isEmpty {
                md += "## Facts\n\n" + history.map { f in
                    let range = f.validTo.map { " (until \(day($0, calendar)))" } ?? " (since \(day(f.validFrom, calendar)))"
                    return f.isCurrent ? "- \(f.predicate): \(f.object)\(range)" : "- ~~\(f.predicate): \(f.object)~~\(range)"
                }.joined(separator: "\n") + "\n\n"
            }
            let loops = try store.loops(entityID: person.id)
            if !loops.isEmpty {
                md += "## Promises\n\n" + loops.map { "- [\($0.status == .open ? " " : "x")] \($0.text)\($0.dueAt.map { " (due \(day($0, calendar)))" } ?? "")" }.joined(separator: "\n") + "\n\n"
            }
            let messages = try store.episodes(forPerson: person.id, limit: 40).filter { $0.kind != .draft && $0.kind != .fix }
            if !messages.isEmpty {
                md += "## Recent messages\n\n" + messages.map { "- [[\(day($0.createdAt, calendar))]] \(link(names, in: $0.text, except: person.name))" }.joined(separator: "\n") + "\n"
            }
            try md.write(to: peopleDir.appending(path: fileName(person.name) + ".md"), atomically: true, encoding: .utf8)
            written += 1
        }

        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        let episodes = try store.episodes(from: start, to: now.addingTimeInterval(1))
        let byDay = Dictionary(grouping: episodes) { day($0.createdAt, calendar) }
        for (key, items) in byDay {
            var md = "# \(key)\n\n"
            if let digest = try store.digest(day: key) { md += "## Digest\n\n\(digest)\n\n" }
            md += "## Messages\n\n" + items.map { e in
                let who = e.contactRaw.map { " to [[\(fileName($0))|\($0)]]" } ?? ""
                return "- \(e.createdAt.formatted(date: .omitted, time: .shortened))\(who) (\(e.surface)): \(link(names, in: e.text, except: e.contactRaw))"
            }.joined(separator: "\n") + "\n"
            try md.write(to: dailyDir.appending(path: "\(key).md"), atomically: true, encoding: .utf8)
            written += 1
        }

        let loops = try store.openLoops()
        var index = "# keybro memory\n\nGenerated \(now.formatted()). Edit in keybro, not here: this folder is rewritten on export.\n\n"
        index += "## People\n\n" + people.map { "- [[\(fileName($0.name))|\($0.name)]] (\($0.episodeCount))" }.joined(separator: "\n") + "\n\n"
        index += "## Open promises\n\n" + (loops.isEmpty ? "None." : loops.map { "- [ ] \($0.text)\($0.person.map { " to [[\(fileName($0))|\($0)]]" } ?? "")" }.joined(separator: "\n")) + "\n"
        try index.write(to: folder.appending(path: "index.md"), atomically: true, encoding: .utf8)
        return written + 1
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        Consolidator.dayKey(date, calendar: calendar)
    }

    static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")).joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "unknown" : cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// Turns mentions of known people into [[links]] so the graph connects them.
    static func link(_ names: [String], in text: String, except: String?) -> String {
        var result = text.replacingOccurrences(of: "\n", with: " ")
        for name in names where name != except && name.count >= 3 {
            let first = name.components(separatedBy: " ").first ?? name
            let pattern = "(?i)(?<![\\p{L}\\[])\(NSRegularExpression.escapedPattern(for: first))(?![\\p{L}\\]])"
            result = result.replacingOccurrences(of: pattern, with: "[[\(fileName(name))|$0]]", options: .regularExpression)
        }
        return result
    }
}
