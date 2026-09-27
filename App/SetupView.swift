import AppKit
import KeybroKit
import SwiftUI

struct SetupView: View {
    @Bindable var state: AppState
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up keybro").font(.largeTitle.bold())
                Text("Three things and you're ready. Nothing leaves your Mac except the prompts you send to Claude.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                StepRow(
                    title: "Accessibility",
                    detail: "Reads and writes the text field you're typing in.",
                    done: state.accessibility
                ) {
                    Button("Grant") {
                        Permissions.requestAccessibility()
                        Permissions.openSettings(.accessibility)
                    }
                }
                Divider()
                StepRow(
                    title: "Screen Recording",
                    detail: "Used only when you press Generate, to see the conversation. macOS asks again about once a month.",
                    done: state.screenRecording,
                    optional: true
                ) {
                    Button("Grant") {
                        if !Permissions.requestScreenRecording() {
                            Permissions.openSettings(.screenRecording)
                        }
                    }
                }
                Divider()
                StepRow(
                    title: "Claude Code",
                    detail: claudeDetail,
                    done: state.claudeTest.isPassed
                ) {
                    HStack {
                        Button("Choose…", action: chooseClaude)
                        Button("Test") { state.testClaude() }
                            .disabled(state.claudePath == nil || state.claudeTest == .running)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            TestResult(state: state)

            Spacer(minLength: 0)

            HStack {
                Text("You can reopen this from the menu bar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.isReady)
            }
        }
        .padding(28)
        .frame(width: 520, height: 560)
        .task {
            // macOS doesn't notify permission changes, so poll while the window is open.
            while !Task.isCancelled {
                state.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var claudeDetail: String {
        if state.locatingClaude { return "Looking for Claude Code…" }
        guard let path = state.claudePath else { return "Not found. Install Claude Code, or choose the claude binary." }
        return "Uses your Claude login, no API keys. Found at \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
    }

    private func chooseClaude() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            state.setClaudePath(url.path)
        }
    }
}

private struct StepRow<Action: View>: View {
    var title: String
    var detail: String
    var done: Bool
    var optional = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if optional {
                        Text("for Generate").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { action() }
        }
        .padding(14)
    }
}

struct TestResult: View {
    var state: AppState

    var body: some View {
        switch state.claudeTest {
        case .idle:
            EmptyView()
        case .running:
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(state.testOutput.isEmpty ? "Asking Claude to fix a sentence…" : state.testOutput)
            }
        case .passed(let ms):
            VStack(alignment: .leading, spacing: 4) {
                Label("Claude answered in \(String(format: "%.1f", Double(ms) / 1000))s", systemImage: "checkmark")
                    .foregroundStyle(.green)
                Text(state.testOutput).font(.callout).textSelection(.enabled)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }
}
