import Foundation
import KeybroKit

// Measures memory retrieval: does search put the right conversation in the top 5 / top 10?
//
//   swift run -c release keybro-eval --demo                 small built-in set
//   swift run -c release keybro-eval longmemeval_s.json      LongMemEval format (download it yourself)
//
// Each question gets a fresh in-memory store holding its "haystack" sessions (your side of each
// chat as one memory). Compares keyword search with hybrid (keyword + meaning) search.
// Retrieval only: answer accuracy needs a judge model and isn't measured here.

struct Instance: Decodable {
    struct Turn: Decodable { let role: String; let content: String }
    let question_id: String
    let question: String
    let haystack_session_ids: [String]
    let haystack_sessions: [[Turn]]
    let answer_session_ids: [String]
}

let demo: [(question: String, sessions: [(id: String, text: String)], answer: String)] = [
    ("Where does my friend Rahul work now?", [("a", "congrats on joining Swiggy bro, bangalore life!"), ("b", "the migration didn't run on staging"), ("c", "happy birthday mom")], "a"),
    ("What did I promise Priya?", [("a", "ill send you the pitch deck by friday"), ("b", "lunch tomorrow?"), ("c", "can you review PR 5559")], "a"),
    ("Why were authenticated requests failing?", [("a", "party at 8 tonight"), ("b", "the migration never ran on staging, that's why auth broke"), ("c", "new phone who dis")], "b"),
    ("When is the team offsite?", [("a", "offsite is on the 14th in Goa"), ("b", "send me the invoice"), ("c", "gym at 7?")], "a"),
    ("Which laptop did I decide to buy?", [("a", "going with the 14 inch MacBook Pro, M5"), ("b", "dinner plans?"), ("c", "the build is flaky again")], "a"),
    ("What's the name of my dentist?", [("a", "appointment with Dr. Mehta moved to Tuesday"), ("b", "see you at the match"), ("c", "deploy after lunch")], "a"),
    ("Did I agree to go to the wedding?", [("a", "cant make it to the sangeet but I'll be there for the wedding"), ("b", "pricing sheet attached"), ("c", "ok")], "a"),
    ("What was the budget for the party?", [("a", "keep the party budget under 5k"), ("b", "call me later"), ("c", "the cron job failed")], "a"),
    ("Who is handling the Apple developer account?", [("a", "Furaak's team manages the apple dev account"), ("b", "movie tonight"), ("c", "revenue mismatch in exports")], "a"),
    ("What time is brunch on Sunday?", [("a", "sunday brunch at 11:30 works"), ("b", "migrations are done"), ("c", "happy diwali")], "a"),
]

/// Everyday noise every demo question has to search through.
let distractors = [
    "ok see you soon", "lol", "can you send the invoice", "the build is green now", "happy new year!", "running 10 min late",
    "did you eat?", "let's sync tomorrow", "call me when free", "pushed the fix", "which cafe?", "movie tonight?",
    "the meeting moved to 4", "thanks bro", "sure, works for me", "PR looks good, merging", "gym tomorrow at 7",
    "reminder to pay rent", "coffee later?", "the dashboard numbers look off", "sending the doc now", "haha nice",
]

/// Demo: every question searches the same pool (all demo memories plus noise).
func demoItems() -> [(question: String, sessions: [(id: String, text: String)], answers: Set<String>)] {
    var pool: [(id: String, text: String)] = []
    var answers: [Set<String>] = []
    for (q, item) in demo.enumerated() {
        for s in item.sessions { pool.append((id: "\(q)\(s.id)", text: s.text)) }
        answers.append(["\(q)\(item.answer)"])
    }
    for (i, text) in distractors.enumerated() { pool.append((id: "d\(i)", text: text)) }
    return demo.enumerated().map { (q, item) in (item.question, pool, answers[q]) }
}

func evaluate(_ items: [(question: String, sessions: [(id: String, text: String)], answers: Set<String>)]) async throws {
    let embedder = AppleEmbedder()
    var hits: [String: (at1: Int, at5: Int, at10: Int)] = ["keyword": (0, 0, 0), "hybrid": (0, 0, 0)]
    for (n, item) in items.enumerated() {
        let store = try MemoryStore()
        for s in item.sessions {
            try store.insert(Episode(kind: .sent, surface: "s:\(s.id)", text: String(s.text.prefix(4000))))
        }
        let indexer = MemoryIndexer(store: store, embedder: embedder)
        try await indexer.indexPending()
        let modes: [(String, HybridSearch)] = [
            ("keyword", HybridSearch(store: store)),
            ("hybrid", HybridSearch(store: store, embedder: embedder, index: indexer.index)),
        ]
        for (name, search) in modes {
            let found = try await search.search(item.question, limit: 10).map { String($0.surface.dropFirst(2)) }
            let at1 = found.prefix(1).contains(where: item.answers.contains) ? 1 : 0
            let at5 = found.prefix(5).contains(where: item.answers.contains) ? 1 : 0
            let at10 = found.contains(where: item.answers.contains) ? 1 : 0
            let h = hits[name]!
            hits[name] = (h.at1 + at1, h.at5 + at5, h.at10 + at10)
        }
        if (n + 1) % 25 == 0 { FileHandle.standardError.write(Data("\(n + 1)/\(items.count)\n".utf8)) }
    }
    let total = Double(items.count)
    print("questions: \(items.count), memories per question: \(items.first?.sessions.count ?? 0)")
    for name in ["keyword", "hybrid"] {
        let h = hits[name]!
        print(String(format: "%-8@ recall@1 %5.1f%%   recall@5 %5.1f%%   recall@10 %5.1f%%", name as NSString,
                     Double(h.at1) / total * 100, Double(h.at5) / total * 100, Double(h.at10) / total * 100))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--demo" || args.isEmpty {
    try await evaluate(demoItems())
} else {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[0]))
    let instances = try JSONDecoder().decode([Instance].self, from: data)
    let limit = args.count > 1 ? Int(args[1]) ?? instances.count : instances.count
    try await evaluate(instances.prefix(limit).map { inst in
        let sessions = zip(inst.haystack_session_ids, inst.haystack_sessions).map { id, turns in
            (id: id, text: turns.filter { $0.role == "user" }.map(\.content).joined(separator: "\n"))
        }
        return (inst.question, sessions, Set(inst.answer_session_ids))
    })
}
