import Foundation
import KeybroKit

// keybro memory for Claude Code:  claude mcp add keybro -- /path/to/keybro-mcp
// Reads ~/keybro-memory/memory.db within the scope in ~/keybro-memory/mcp.json.
// Logs to stderr only; stdout carries the protocol.
do {
    let store = try MemoryStore(url: MemoryStore.defaultURL)
    let embedder = AppleEmbedder()
    let search = HybridSearch(store: store, embedder: embedder, index: VectorIndex(store: store, modelID: embedder.modelID))
    await MCPServer(query: MemoryQuery(store: store, search: search, scope: MemoryScope.load())).serve()
} catch {
    FileHandle.standardError.write(Data("keybro-mcp: can't open memory: \(error.localizedDescription)\n".utf8))
    exit(1)
}
