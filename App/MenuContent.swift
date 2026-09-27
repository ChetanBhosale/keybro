import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuContent: View {
    var state: AppState
    @Bindable var memory: MemorySettings
    var memoryAvailable: Bool
    var services: MemoryServices?
    var openSetup: () -> Void
    var openMemory: () -> Void
    var openSettings: () -> Void

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
            VStack(alignment: .leading, spacing: 6) {
                KeyboardShortcuts.Recorder("Generate", name: .generate)
                KeyboardShortcuts.Recorder("Fix", name: .fix)
                Text("Generate writes a message from what you type and what's on screen. Fix cleans up the selected text, or the whole field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Memory").font(.headline)
                    Spacer()
                    Text(memoryStatus).font(.caption).foregroundStyle(memory.isCapturing && memoryAvailable ? .green : .secondary)
                }
                Toggle("Remember what I type", isOn: $memory.rememberTyping)
                    .disabled(!memoryAvailable)
                HStack {
                    if memory.isPaused {
                        Button("Resume") { memory.resume() }
                    } else {
                        Button("Pause 1 hour") { memory.pause(for: 3600) }
                            .disabled(!memory.rememberTyping)
                    }
                    Button("Open Memory…", action: openMemory)
                        .disabled(!memoryAvailable)
                }
                if let services {
                    let open = (try? services.store.openLoops().count) ?? 0
                    if open > 0 {
                        Text("\(open) open promise\(open == 1 ? "" : "s")").font(.caption)
                    }
                    Button(services.running ? "Updating memory…" : "Update memory now") {
                        Task { await services.runNow() }
                    }
                    .disabled(services.running)
                }
                Text("Stays on this Mac. Password fields, password managers and terminals are never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",")
            Button("Setup…", action: openSetup)
            Button("Quit keybro") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { state.refreshPermissions() }
    }
}

extension MenuContent {
    var memoryStatus: String {
        if !memoryAvailable { return "Unavailable" }
        if !memory.rememberTyping { return "Off" }
        if let until = memory.pausedUntil, memory.isPaused {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "On"
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
