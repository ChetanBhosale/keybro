import Foundation
import NaturalLanguage

/// Turns text into vectors, on this Mac.
public protocol Embedder: Sendable {
    /// Stored next to each vector, so switching models re-embeds.
    var modelID: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Apple's on-device contextual embedding (BERT style), mean-pooled and normalized.
/// About 13ms per message on Apple Silicon. Assets download once from Apple, then it's offline.
public actor AppleEmbedder: Embedder {
    public nonisolated let modelID = "apple-contextual-en-v1"
    private var model: NLContextualEmbedding?

    public init() {}

    private func loaded() async throws -> NLContextualEmbedding {
        if let model { return model }
        guard let embedding = NLContextualEmbedding(language: .english) else {
            throw EmbedderError.unavailable("No on-device embedding model for English.")
        }
        if !embedding.hasAvailableAssets {
            _ = try await embedding.requestAssets()
        }
        try embedding.load()
        model = embedding
        return embedding
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        let model = try await loaded()
        return try texts.map { text in
            let input = String(text.prefix(1000))
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return [Float](repeating: 0, count: model.dimension)
            }
            let result = try model.embeddingResult(for: input, language: .english)
            var sum = [Double](repeating: 0, count: model.dimension)
            var count = 0.0
            result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
                for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
                count += 1
                return true
            }
            return VectorMath.normalize(sum.map { Float($0 / max(count, 1)) })
        }
    }
}

public enum EmbedderError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let m): m }
    }
}

public enum VectorMath {
    public static func normalize(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Dot product; equals cosine similarity for normalized vectors.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }
}

/// Brute-force vector search over all episodes, kept in memory.
/// Fine for a personal memory (tens of thousands of messages); sqlite-vec can replace it later.
public actor VectorIndex {
    private let store: MemoryStore
    private let modelID: String
    private var vectors: [Int64: [Float]] = [:]
    private var lastID: Int64 = 0

    public init(store: MemoryStore, modelID: String) {
        self.store = store
        self.modelID = modelID
    }

    /// Picks up vectors written since the last call (by this process or another).
    public func refresh() throws {
        for (id, vector) in try store.embeddings(model: modelID, afterID: lastID) {
            vectors[id] = vector
            lastID = max(lastID, id)
        }
    }

    public func add(_ id: Int64, _ vector: [Float]) {
        vectors[id] = vector
    }

    public func remove(_ id: Int64) {
        vectors[id] = nil
    }

    public var count: Int { vectors.count }

    public func nearest(to query: [Float], limit: Int) -> [(id: Int64, score: Float)] {
        vectors.map { ($0.key, VectorMath.dot(query, $0.value)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { (id: $0.0, score: $0.1) }
    }
}

/// Embeds episodes that don't have a vector yet. Runs in the background every minute.
public actor MemoryIndexer {
    private let store: MemoryStore
    private let embedder: Embedder
    public nonisolated let index: VectorIndex

    public init(store: MemoryStore, embedder: Embedder) {
        self.store = store
        self.embedder = embedder
        self.index = VectorIndex(store: store, modelID: embedder.modelID)
    }

    @discardableResult
    public func indexPending(batch: Int = 64) async throws -> Int {
        try await index.refresh()
        var total = 0
        while true {
            let pending = try store.episodesNeedingEmbedding(model: embedder.modelID, limit: batch)
            guard !pending.isEmpty else { return total }
            let vectors = try await embedder.embed(pending.map(\.text))
            for (episode, vector) in zip(pending, vectors) {
                guard let id = episode.id else { continue }
                try store.saveEmbedding(episodeID: id, model: embedder.modelID, vector: vector)
                await index.add(id, vector)
            }
            total += pending.count
            if pending.count < batch { return total }
        }
    }
}

/// Keyword and meaning search, merged with reciprocal rank fusion and a small recency boost.
public struct HybridSearch: Sendable {
    public let store: MemoryStore
    public let embedder: Embedder?
    public let index: VectorIndex?

    public init(store: MemoryStore, embedder: Embedder? = nil, index: VectorIndex? = nil) {
        self.store = store
        self.embedder = embedder
        self.index = index
    }

    /// Recent messages count a bit more; the boost halves every 30 days.
    static let recencyHalfLife: TimeInterval = 30 * 86_400
    static let rrfK = 60.0
    /// Exact words are a stronger signal than Apple's small embedding model.
    /// keybro-eval --demo: weight 1 gives recall@1 50%, weight 3 gives 60% (same as keyword alone)
    /// while keeping hybrid's better recall@5/10. Override with KEYBRO_KEYWORD_WEIGHT to experiment.
    static var keywordWeight: Double {
        ProcessInfo.processInfo.environment["KEYBRO_KEYWORD_WEIGHT"].flatMap(Double.init) ?? 3.0
    }

    public func search(_ query: String, limit: Int = 10, since: Date? = nil, now: Date = Date()) async throws -> [Episode] {
        var scores: [Int64: Double] = [:]
        for (rank, e) in try store.search(query, limit: limit * 3).enumerated() {
            if let id = e.id { scores[id, default: 0] += Self.keywordWeight / (Self.rrfK + Double(rank)) }
        }
        if let embedder, let index,
           let vector = try? await embedder.embed([query]).first, vector.contains(where: { $0 != 0 }) {
            try? await index.refresh()
            // Weak matches add noise; keep only reasonably close ones.
            for (rank, hit) in await index.nearest(to: vector, limit: limit * 3).enumerated() where hit.score > 0.5 {
                scores[hit.id, default: 0] += 1 / (Self.rrfK + Double(rank))
            }
        }
        let candidates = try store.episodes(ids: Array(scores.keys))
        return candidates
            .filter { e in since.map { e.createdAt >= $0 } ?? true }
            .map { e -> (Episode, Double) in
                let age = max(0, now.timeIntervalSince(e.createdAt))
                let recency = pow(0.5, age / Self.recencyHalfLife)
                return (e, (scores[e.id!] ?? 0) * (1 + 0.5 * recency))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
