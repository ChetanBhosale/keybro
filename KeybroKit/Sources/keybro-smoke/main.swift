import AppKit
import KeybroKit

// Usage:
//   swift run keybro-smoke "prompt" [haiku|sonnet|opus]
//   swift run keybro-smoke --generate chat.png "sorry to rahul, cant come"
let args = Array(CommandLine.arguments.dropFirst())

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
