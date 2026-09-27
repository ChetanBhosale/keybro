import Foundation
import KeybroKit
import Observation

@MainActor
@Observable
final class AppState {
    enum ClaudeTest: Equatable {
        case idle
        case running
        case passed(ms: Int)
        case failed(String)
    }

    private(set) var accessibility = Permissions.isAccessibilityTrusted
    private(set) var screenRecording = Permissions.isScreenRecordingGranted
    private(set) var claudePath: String?
    private(set) var locatingClaude = true
    private(set) var claudeTest: ClaudeTest = .idle
    private(set) var testOutput = ""

    private static let claudePathKey = "claudePath"
    private var testTask: Task<Void, Never>?

    init() {
        Task { await locateClaude() }
    }

    /// Ready for M1: text access plus a working Claude. Screen Recording is only needed for Generate.
    var isReady: Bool { accessibility && claudeTest.isPassed }

    func refreshPermissions() {
        accessibility = Permissions.isAccessibilityTrusted
        screenRecording = Permissions.isScreenRecordingGranted
    }

    func locateClaude() async {
        locatingClaude = true
        defer { locatingClaude = false }
        if let saved = UserDefaults.standard.string(forKey: Self.claudePathKey),
           FileManager.default.isExecutableFile(atPath: saved) {
            claudePath = saved
            return
        }
        let found = await Task.detached { ClaudeLocator.live.locate() }.value
        setClaudePath(found)
    }

    func setClaudePath(_ path: String?) {
        claudePath = path
        UserDefaults.standard.set(path, forKey: Self.claudePathKey)
        claudeTest = .idle
    }

    func testClaude() {
        guard let claudePath else {
            claudeTest = .failed(ClaudeError.notFound.localizedDescription)
            return
        }
        testTask?.cancel()
        testOutput = ""
        claudeTest = .running
        let runner = ClaudeRunner(executablePath: claudePath)
        let request = ClaudeRequest(
            prompt: "Fix the grammar and output only the fixed text: hey can u check the pr i think its braking the build",
            model: .haiku,
            timeout: .seconds(45)
        )
        let start = ContinuousClock.now
        testTask = Task {
            do {
                for try await event in runner.run(request) {
                    switch event {
                    case .textDelta(let text): testOutput += text
                    case .result(let result): testOutput = result.text
                    default: break
                    }
                }
                let elapsed = ContinuousClock.now - start
                claudeTest = .passed(ms: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
            } catch is CancellationError {
                claudeTest = .idle
            } catch {
                claudeTest = .failed(error.localizedDescription)
            }
        }
    }
}

extension AppState.ClaudeTest {
    var isPassed: Bool { if case .passed = self { true } else { false } }
}
