import AppKit
import KeybroKit
import Observation
import UserNotifications

/// Background memory work: embeddings every minute, the nightly update, promise reminders.
@MainActor
@Observable
final class MemoryServices {
    private enum Keys {
        static let engine = "memory.engine"
        static let ollamaModel = "memory.ollamaModel"
        static let exportMarkdown = "memory.exportMarkdown"
        static let lastRun = "memory.lastConsolidation"
        static let lastReport = "memory.lastReport"
    }

    let store: MemoryStore
    let embedder = AppleEmbedder()
    let indexer: MemoryIndexer
    var search: HybridSearch { HybridSearch(store: store, embedder: embedder, index: indexer.index) }

    var engine: BackgroundEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine) }
    }
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Keys.ollamaModel) }
    }
    var exportMarkdown: Bool {
        didSet { UserDefaults.standard.set(exportMarkdown, forKey: Keys.exportMarkdown) }
    }
    private(set) var lastRun: Date? = UserDefaults.standard.object(forKey: Keys.lastRun) as? Date
    private(set) var lastReport: String = UserDefaults.standard.string(forKey: Keys.lastReport) ?? "Not run yet."
    private(set) var running = false
    private(set) var indexed = 0

    private let claudePath: @MainActor () -> String?
    private var loops: [Task<Void, Never>] = []

    init(store: MemoryStore, claudePath: @escaping @MainActor () -> String?) {
        self.store = store
        self.claudePath = claudePath
        indexer = MemoryIndexer(store: store, embedder: embedder)
        engine = UserDefaults.standard.string(forKey: Keys.engine).flatMap(BackgroundEngine.init(rawValue:)) ?? .localOnly
        ollamaModel = UserDefaults.standard.string(forKey: Keys.ollamaModel) ?? OllamaTextModel.defaultModel
        exportMarkdown = UserDefaults.standard.object(forKey: Keys.exportMarkdown) as? Bool ?? true
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let indexer = indexer
        // The indexer is an actor, so embedding runs off the main thread.
        loops.append(Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let count = (try? await indexer.indexPending()) ?? 0
                self?.indexed += count
                try? await Task.sleep(for: .seconds(60))
            }
        })
        loops.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(600))
            }
        })
    }

    /// Runs the nightly update once a day after 9 PM (or if a day was missed), and sends due reminders.
    private func tick(now: Date = Date()) async {
        remindDueLoops(now: now)
        let ninePM = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: now)!
        let due = now >= ninePM ? (lastRun ?? .distantPast) < ninePM : (lastRun ?? .distantPast) < now.addingTimeInterval(-26 * 3600)
        if due, engine != .off { await runNow(notify: now >= ninePM) }
    }

    func runNow(notify: Bool = false) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let ollama = OllamaTextModel(model: ollamaModel)
        guard let model = await engine.resolve(ollama: ollama, claudePath: claudePath()) else {
            setReport(engine == .off
                      ? "Background memory is off."
                      : "No model available. Turn on Apple Intelligence, or start Ollama with \(ollamaModel).")
            return
        }
        let report = await Consolidator(store: store, model: model).run()
        if exportMarkdown { _ = try? MarkdownExporter.export(store: store) }
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: Keys.lastRun)
        var summary = "\(model.name): read \(report.processed) messages, \(report.facts) facts, \(report.loopsAdded) new promises, \(report.loopsClosed) done, \(report.profiles) profiles."
        if !report.errors.isEmpty { summary += " \(report.errors.count) step\(report.errors.count == 1 ? "" : "s") failed: \(report.errors.first!)" }
        setReport(summary)
        if notify, let digest = report.digest {
            post(title: "Your day", body: digest.replacingOccurrences(of: "- ", with: "").replacingOccurrences(of: "\n", with: " · "))
        }
    }

    private func setReport(_ text: String) {
        lastReport = text
        UserDefaults.standard.set(text, forKey: Keys.lastReport)
    }

    private func remindDueLoops(now: Date) {
        guard let due = try? store.loopsToNotify(dueBy: now.addingTimeInterval(12 * 3600)) else { return }
        for loop in due {
            let whom = loop.person.map { " to \($0)" } ?? ""
            post(title: "Promise due\(whom)", body: loop.text)
            try? store.markNotified(loop.id!, at: now)
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Claude Code connection

    static var mcpBinary: URL { KeybroPaths.appSupport.appending(path: "bin/keybro-mcp") }

    static var mcpInstalled: Bool { FileManager.default.isExecutableFile(atPath: mcpBinary.path) }

    static var mcpAddCommand: String { "claude mcp add keybro -- \"\(mcpBinary.path)\"" }

    static func accessLog(lines: Int = 30) -> [String] {
        let url = KeybroPaths.memory.appending(path: "mcp-access.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(lines).reversed()).map(String.init)
    }
}
