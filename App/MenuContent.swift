import AppKit
import SwiftUI

struct MenuContent: View {
    var state: AppState
    var openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("keybro").font(.headline)
                Spacer()
                Text(state.isReady ? "Ready" : "Setup needed")
                    .font(.caption)
                    .foregroundStyle(state.isReady ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                StatusLine(label: "Accessibility", ok: state.accessibility)
                StatusLine(label: "Screen Recording", ok: state.screenRecording)
                StatusLine(label: "Claude Code", ok: state.claudeTest.isPassed, pending: state.claudePath != nil && !state.claudeTest.isPassed)
            }

            Button("Test Claude") { state.testClaude() }
                .disabled(state.claudePath == nil || state.claudeTest == .running)
            TestResult(state: state)
                .font(.callout)

            Divider()
            Button("Setup…", action: openSetup)
            Button("Quit keybro") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { state.refreshPermissions() }
    }
}

private struct StatusLine: View {
    var label: String
    var ok: Bool
    var pending = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : (pending ? "circle.dotted" : "xmark.circle"))
                .foregroundStyle(ok ? .green : (pending ? .secondary : .orange))
            Text(label)
        }
        .font(.callout)
    }
}
