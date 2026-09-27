import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Lets Claude Code, Cursor and other agents read keybro's memory, within `MemoryScope`.
public struct MCPServer: Sendable {
    public static let name = "keybro-memory"
    public static let version = "0.1.0"

    let query: MemoryQuery
    let logURL: URL?

    public init(query: MemoryQuery, logURL: URL? = KeybroPaths.memory.appending(path: "mcp-access.log")) {
        self.query = query
        self.logURL = logURL
    }

    static var tools: [[String: Any]] { [
        tool("search_memory", "Search what the user wrote across their Mac (chats, email, Slack, notes). Matches words and meaning, recent first.",
             ["query": ["type": "string", "description": "What to look for"],
              "days": ["type": "integer", "description": "Only the last N days"],
              "limit": ["type": "integer", "description": "Max results, default 10"]], required: ["query"]),
        tool("get_person", "Everything known about a person: profile, current facts, what changed, open promises, recent messages.",
             ["name": ["type": "string"],
              "as_of": ["type": "string", "description": "YYYY-MM-DD to see what was true then"]], required: ["name"]),
        tool("timeline", "What the user wrote over the last N days, optionally for one person or app.",
             ["days": ["type": "integer", "description": "Default 1"],
              "person": ["type": "string"],
              "app": ["type": "string", "description": "App family, e.g. slack, whatsapp, gmail"]], required: []),
        tool("open_loops", "Promises the user made that aren't done yet, with due dates.", [:], required: []),
        tool("today_context", "Today at a glance: digest, messages written today, promises due soon.", [:], required: []),
        tool("remember", "Save a note to the user's memory.",
             ["text": ["type": "string"], "person": ["type": "string", "description": "Who it's about, if anyone"]], required: ["text"]),
    ] }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    /// Handles one incoming line. Returns the response line, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]) }

        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return reply(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.name, "version": Self.version],
                "instructions": "Personal memory from the user's Mac (keybro). Use it for context about people, recent work and promises. It's the user's private data: quote only what's needed.",
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            log(tool: name, args: args)
            do {
                let text = try await call(name, args)
                return reply(id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                return reply(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    enum CallError: Error, LocalizedError {
        case missing(String), unknown(String)
        var errorDescription: String? {
            switch self {
            case .missing(let a): "Missing argument: \(a)"
            case .unknown(let t): "Unknown tool: \(t)"
            }
        }
    }

    func call(_ name: String, _ args: [String: Any]) async throws -> String {
        func string(_ key: String) -> String? { (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue ?? (args[key] as? String).flatMap(Int.init) }
        switch name {
        case "search_memory":
            guard let q = string("query") else { throw CallError.missing("query") }
            return try await query.searchMemory(q, days: int("days"), limit: min(int("limit") ?? 10, 50))
        case "get_person":
            guard let n = string("name") else { throw CallError.missing("name") }
            let asOf = string("as_of").flatMap { Consolidator.date(from: $0, calendar: .current) }
            return try query.person(named: n, asOf: asOf)
        case "timeline":
            return try query.timeline(days: min(int("days") ?? 1, query.scope.maxDays), person: string("person"), surface: string("app"))
        case "open_loops":
            return try query.openLoops()
        case "today_context":
            return try query.today()
        case "remember":
            guard let t = string("text") else { throw CallError.missing("text") }
            return try query.remember(t, person: string("person"))
        default:
            throw CallError.unknown(name)
        }
    }

    func reply(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func encode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Who read what, for the privacy view. Arguments only, never results.
    func log(tool: String, args: [String: Any]) {
        guard let logURL else { return }
        let argText = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])).map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? "{}"
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(tool)\t\(argText)\n"
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }

    /// Reads stdin until it closes, answering each request on stdout.
    public func serve() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let response = await handle(line: line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            }
        } catch {}
    }
}
