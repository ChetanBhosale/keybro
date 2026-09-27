import AppKit
import KeybroKit
import KeyboardShortcuts
import SwiftUI

@main
struct KeybroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: delegate.state, memory: delegate.memorySettings, memoryAvailable: delegate.memoryStore != nil,
                        openSetup: delegate.showSetup, openMemory: delegate.showMemory, openSettings: delegate.showSettings)
        } label: {
            Image(systemName: "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let memorySettings = MemorySettings()
    /// nil if the database couldn't open; keybro still works, it just doesn't remember.
    let memoryStore = try? MemoryStore(url: MemoryStore.defaultURL)
    private var recorder: MemoryRecorder?
    private var typingWatcher: TypingWatcher?
    private var setupWindow: NSWindow?
    private var memoryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var fixController: FixController?
    private var fixPill: FixPillPanel?
    private var generateController: GenerateController?
    private var commandBar: CommandBarPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = state
        let settings = memorySettings
        let recorder = memoryStore.map { MemoryRecorder(store: $0) }
        self.recorder = recorder
        if let recorder {
            // Clear anything stored before the current content rules.
            Task { await recorder.purgeSensitive() }
            let watcher = TypingWatcher(recorder: recorder,
                                        isEnabled: { settings.isCapturing },
                                        isBlocked: { settings.isBlocked($0) })
            watcher.start()
            typingWatcher = watcher
        }

        let controller = FixController(
            driver: AXTextFieldDriver(),
            fixer: { text in
                guard let path = await state.claudePath else { throw ClaudeError.notFound }
                return try await ClaudeFixer(runner: ClaudeRunner(executablePath: path)).fix(text)
            },
            onFixed: { fixed, target in
                guard await settings.isCapturing, await !settings.isBlocked(target.bundleID) else { return }
                await recorder?.recordFix(fixed: fixed, target: target)
            }
        )
        fixController = controller
        fixPill = FixPillPanel(controller: controller)
        KeyboardShortcuts.onKeyDown(for: .fix) { controller.trigger() }

        let driver = AXTextFieldDriver()
        let generate = GenerateController(
            driver: driver,
            screenshotter: { pid in await ScreenCapture.frontWindow(of: pid) },
            generator: { input in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        guard let path = await state.claudePath else {
                            continuation.finish(throwing: ClaudeError.notFound)
                            return
                        }
                        do {
                            for try await draft in ClaudeGenerator(runner: ClaudeRunner(executablePath: path)).generate(input) {
                                continuation.yield(draft)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            memory: { instruction, target in
                await recorder?.context(instruction: instruction, target: target)
            },
            onInserted: { text, target, contact in
                guard await settings.isCapturing, await !settings.isBlocked(target.bundleID) else { return }
                await recorder?.recordGenerate(inserted: text, target: target, contact: contact)
            }
        )
        generateController = generate
        commandBar = CommandBarPanel(controller: generate)
        KeyboardShortcuts.onKeyDown(for: .generate) { Task { await generate.start() } }

        if !UserDefaults.standard.bool(forKey: "didFinishSetup") || !state.accessibility {
            showSetup()
        }
    }

    func showMemory() {
        guard let memoryStore else { return }
        if memoryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "keybro Memory"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MemoryWindowView(model: MemoryViewModel(store: memoryStore)))
            window.center()
            memoryWindow = window
        }
        NSApp.activate()
        memoryWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "keybro Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(state: state, memory: memorySettings, store: memoryStore, openMemory: { [weak self] in self?.showMemory() })
            )
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Set up keybro"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SetupView(state: state) { [weak self] in
                    UserDefaults.standard.set(true, forKey: "didFinishSetup")
                    self?.setupWindow?.close()
                }
            )
            window.center()
            setupWindow = window
        }
        // Menu bar apps have no Dock icon, so bring the window forward explicitly.
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }
}
