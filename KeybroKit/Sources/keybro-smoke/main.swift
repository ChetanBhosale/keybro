import Foundation
import KeybroKit

// Usage: swift run keybro-smoke "prompt" [haiku|sonnet|opus]
let args = CommandLine.arguments.dropFirst()
let prompt = args.first ?? "Reply with exactly: keybro is alive"
let model = args.dropFirst().first.flatMap(ClaudeRequest.Model.init(rawValue:)) ?? .haiku

guard let path = ClaudeLocator.live.locate() else {
    FileHandle.standardError.write(Data("claude not found\n".utf8))
    exit(1)
}
print("claude: \(path)")

let runner = ClaudeRunner(executablePath: path)
let start = ContinuousClock.now
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
