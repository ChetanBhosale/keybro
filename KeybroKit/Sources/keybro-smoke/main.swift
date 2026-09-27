import AppKit
import KeybroKit

// Usage:
//   swift run keybro-smoke "prompt" [haiku|sonnet|opus]
//   swift run keybro-smoke --generate chat.png "sorry to rahul, cant come"
//   KEYBRO_MEMORY_DIR=/tmp/x swift run keybro-smoke --seed-and-consolidate   (uses local Ollama)
let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--seed-and-consolidate" {
    let store = try MemoryStore(url: MemoryStore.defaultURL)
    let now = Date()
    let priya = try store.resolvePerson(named: "Priya", surface: "whatsapp")
    let rahul = try store.resolvePerson(named: "Rahul", surface: "whatsapp")
    let seed: [(Int64?, String?, String, String, Double)] = [
        (priya, "Priya", "whatsapp", "ill send you the pitch deck by friday, promise", -5 * 3600),
        (rahul, "Rahul", "whatsapp", "congrats on the new job at Swiggy bro! how's bangalore treating you", -4 * 3600),
        (rahul, "Rahul", "whatsapp", "cant make it tonight, stuck with work. sunday brunch instead?", -3 * 3600),
        (nil, nil, "slack", "migration didn't run on staging, rerunning it now and adding a CI check before monday", -2 * 3600),
        (priya, "Priya", "whatsapp", "here's the deck, let me know what you think", -1 * 3600),
    ]
    for (entity, contact, surface, text, offset) in seed {
        try store.insert(Episode(kind: .sent, surface: surface, entityID: entity, contactRaw: contact, text: text, createdAt: now.addingTimeInterval(offset)))
    }
    if args.contains("--no-model") {
        try store.addFact(subject: "Rahul", entityID: rahul, predicate: "works_at", object: "Swiggy", validFrom: now)
        try store.addLoop(OpenLoop(id: nil, entityID: priya, person: "Priya", text: "Send pitch deck", dueAt: now.addingTimeInterval(4 * 86_400), status: .open, createdAt: now))
        print("seeded \(MemoryStore.defaultURL.path)")
        exit(0)
    }
    let model = OllamaTextModel()
    guard await model.isAvailable() else { print("Ollama \(model.model) not available"); exit(1) }
    let start = ContinuousClock.now
    let report = await Consolidator(store: store, model: model).run(now: now)
    print("took \(ContinuousClock.now - start)")
    print(report)
    for p in try store.people() {
        print("\n== \(p.name)")
        if let profile = try store.profile(entityID: p.id) { print("profile:", profile.summary, "| patterns:", profile.patterns) }
        for f in try store.factHistory(entityID: p.id) { print("fact:", f.predicate, "=", f.object, f.isCurrent ? "" : "(replaced)") }
    }
    for f in try store.facts(entityID: nil, subject: "me") { print("me:", f.predicate, "=", f.object) }
    for l in try store.loops(entityID: priya!) + (try store.openLoops()) { print("loop:", l.status, l.text, l.person ?? "", l.dueAt.map { "\($0)" } ?? "") }
    print("digest:", try store.digest(day: Consolidator.dayKey(now, calendar: .current)) ?? "-")
    exit(0)
}

guard let path = ClaudeLocator.live.locate() else {
    FileHandle.standardError.write(Data("claude not found\n".utf8))
    exit(1)
}
print("claude: \(path)")
let runner = ClaudeRunner(executablePath: path)
let start = ContinuousClock.now

if args.first == "--generate", args.count >= 3 {
    guard let cg = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let jpeg = ImageEncoder.jpeg(cg, maxDimension: 1280)
    else { print("can't read image"); exit(1) }
    let input = GenerateInput(appName: "WhatsApp", instruction: args[2], screenshot: ClaudeImage(data: jpeg, mediaType: "image/jpeg"))
    var firstText: Duration?
    do {
        var last = GenerateDraft()
        for try await draft in ClaudeGenerator(runner: runner, style: nil).generate(input) {
            if firstText == nil, !draft.isEmpty { firstText = ContinuousClock.now - start }
            if ProcessInfo.processInfo.environment["KB_TRACE"] != nil { print("  \(ContinuousClock.now - start) casual=\(draft.variants[.casual]?.count ?? 0)") }
            last = draft
        }
        print("first text after: \(firstText.map { "\($0)" } ?? "-")")
        print("contact: \(last.contact ?? "-")")
        for v in DraftVariant.allCases { print("\(v.title): \(last.variants[v] ?? "-")") }
        print("wall: \(ContinuousClock.now - start), jpeg \(jpeg.count / 1024) KB")
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

let prompt = args.first ?? "Reply with exactly: keybro is alive"
let model = args.dropFirst().first.flatMap(ClaudeRequest.Model.init(rawValue:)) ?? .haiku
do {
    for try await event in runner.run(ClaudeRequest(prompt: prompt, model: model)) {
        switch event {
        case .started(let id, let model): print("started \(id) \(model ?? "")")
        case .textDelta(let text): print(text, terminator: ""); fflush(stdout)
        case .result(let r): print("\nresult (\(r.durationMs ?? 0)ms): \(r.text)")
        default: break
        }
    }
    print("wall: \(ContinuousClock.now - start)")
} catch {
    print("\nerror: \(error.localizedDescription)")
    exit(1)
}
