import Foundation
import Synchronization

/// Runs `claude -p` and streams its events.
public struct ClaudeRunner: Sendable {
    public let executablePath: String
    /// Neutral folder so Claude doesn't pick up a project's CLAUDE.md.
    public let workingDirectory: URL

    public init(executablePath: String, workingDirectory: URL = KeybroPaths.claudeWorkingDirectory) {
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
    }

    public func run(_ request: ClaudeRequest) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let run = RunningProcess(
                executablePath: executablePath,
                workingDirectory: workingDirectory,
                arguments: request.arguments,
                environment: Self.environment(executablePath: executablePath).merging(request.environment) { $1 }
            )

            let work = Task {
                do {
                    try run.start()
                } catch {
                    continuation.finish(throwing: ClaudeError.launchFailed(error.localizedDescription))
                    return
                }

                let timeout = Task {
                    try await Task.sleep(for: request.timeout)
                    run.terminate(timedOut: true)
                }
                let stderrTask = Task { await run.readAllStderr() }

                var result: ClaudeResult?
                do {
                    for try await line in run.stdoutLines {
                        guard let event = StreamJSONParser.parse(line) else { continue }
                        if case .result(let r) = event { result = r }
                        continuation.yield(event)
                    }
                } catch {
                    // Pipe closed early; fall through to exit handling.
                }

                await run.exited()
                timeout.cancel()
                let stderr = await stderrTask.value

                if let result, !result.isError {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ClaudeError.classify(
                        exitCode: run.exitCode,
                        stderr: stderr,
                        resultText: result?.text,
                        apiErrorStatus: result?.apiErrorStatus,
                        timedOut: run.timedOut
                    ))
                }
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason { run.terminate(timedOut: false) }
                work.cancel()
            }
        }
    }

    /// GUI apps get a minimal PATH, so add the usual install locations.
    static func environment(executablePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Launched from inside a Claude Code terminal during development.
        env.removeValue(forKey: "CLAUDECODE")
        let dir = (executablePath as NSString).deletingLastPathComponent
        let extra = [dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let current = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        env["PATH"] = (extra + current).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        return env
    }
}

/// Owns the non-Sendable Process and pipes; shared state goes through the mutex.
/// Nothing here blocks a thread: the cooperative pool is shared with the UI.
private final class RunningProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let state = Mutex(State())

    private struct State {
        var timedOut = false
        var exitCode: Int32?
        var exitWaiters: [CheckedContinuation<Void, Never>] = []
    }

    init(executablePath: String, workingDirectory: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            self?.didExit(p.terminationStatus)
        }
    }

    private func didExit(_ code: Int32) {
        let waiters = state.withLock { s in
            s.exitCode = code
            defer { s.exitWaiters = [] }
            return s.exitWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: process.currentDirectoryURL!, withIntermediateDirectories: true)
        try process.run()
    }

    var stdoutLines: AsyncLineSequence<FileHandle.AsyncBytes> {
        stdout.fileHandleForReading.bytes.lines
    }

    func readAllStderr() async -> String {
        var data = Data()
        do {
            for try await byte in stderr.fileHandleForReading.bytes { data.append(byte) }
        } catch {}
        return String(decoding: data, as: UTF8.self)
    }

    func exited() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { s in
                if s.exitCode != nil { return true }
                s.exitWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    var exitCode: Int32 { state.withLock { $0.exitCode ?? -1 } }

    var timedOut: Bool { state.withLock { $0.timedOut } }

    func terminate(timedOut: Bool) {
        if timedOut { state.withLock { $0.timedOut = true } }
        if process.isRunning { process.terminate() }
    }
}
