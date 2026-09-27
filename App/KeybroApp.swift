import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
