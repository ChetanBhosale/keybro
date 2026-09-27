import AppKit
import KeybroKit
import KeyboardShortcuts
import SwiftUI

@main
struct KeybroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: delegate.state, openSetup: delegate.showSetup)
        } label: {
            Image(systemName: "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var setupWindow: NSWindow?
    private var fixController: FixController?
    private var fixPill: FixPillPanel?
    private var generateController: GenerateController?
    private var commandBar: CommandBarPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = state
        let controller = FixController(driver: AXTextFieldDriver()) { text in
            guard let path = await state.claudePath else { throw ClaudeError.notFound }
            return try await ClaudeFixer(runner: ClaudeRunner(executablePath: path)).fix(text)
        }
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
            }
        )
        generateController = generate
        commandBar = CommandBarPanel(controller: generate)
        KeyboardShortcuts.onKeyDown(for: .generate) { Task { await generate.start() } }

        if !UserDefaults.standard.bool(forKey: "didFinishSetup") || !state.accessibility {
            showSetup()
        }
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
