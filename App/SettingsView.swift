import AppKit
import KeybroKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var state: AppState
    var memory: MemorySettings
    var store: MemoryStore?
    var openMemory: () -> Void

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "keyboard") }
            MemorySettingsTab(memory: memory, store: store).tabItem { Label("Memory", systemImage: "brain") }
            PrivacySettings(memory: memory, store: store, openMemory: openMemory).tabItem { Label("Privacy", systemImage: "hand.raised") }
            EngineSettings(state: state).tabItem { Label("Engine", systemImage: "cpu") }
        }
        .frame(width: 560, height: 480)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                shortcutRow("Generate", .generate, detail: "Write a message from your instruction and what's on screen.")
                shortcutRow("Fix", .fix, detail: "Fix the selected text, or the whole field.")
            } header: {
                Text("Shortcuts")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KeyboardShortcuts.Recorder(title, name: name) { _ in refresh += 1 }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            let conflicts = KeyboardShortcuts.getShortcut(for: name).flatMap(ShortcutCombo.combo(for:)).map(HotkeyConflicts.apps(for:)) ?? []
            if !conflicts.isEmpty {
                Label("Also used by \(conflicts.joined(separator: ", ")). keybro wins while it runs.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(refresh)
            }
        }
    }
}

enum ShortcutCombo {
    private static let keys: [(KeyboardShortcuts.Key, String)] = {
        let letters: [(KeyboardShortcuts.Key, String)] = [
            (.a, "a"), (.b, "b"), (.c, "c"), (.d, "d"), (.e, "e"), (.f, "f"), (.g, "g"), (.h, "h"), (.i, "i"),
            (.j, "j"), (.k, "k"), (.l, "l"), (.m, "m"), (.n, "n"), (.o, "o"), (.p, "p"), (.q, "q"), (.r, "r"),
            (.s, "s"), (.t, "t"), (.u, "u"), (.v, "v"), (.w, "w"), (.x, "x"), (.y, "y"), (.z, "z"),
        ]
        let digits: [(KeyboardShortcuts.Key, String)] = [
            (.zero, "0"), (.one, "1"), (.two, "2"), (.three, "3"), (.four, "4"),
            (.five, "5"), (.six, "6"), (.seven, "7"), (.eight, "8"), (.nine, "9"),
        ]
        return letters + digits + [(.space, "space")]
    }()

    static func combo(for shortcut: KeyboardShortcuts.Shortcut) -> HotkeyConflicts.Combo? {
        guard let key = shortcut.key, let name = keys.first(where: { $0.0 == key })?.1 else { return nil }
        let m = shortcut.modifiers
        return .init(key: name, command: m.contains(.command), shift: m.contains(.shift), option: m.contains(.option), control: m.contains(.control))
    }
}

// MARK: - Memory

private struct MemorySettingsTab: View {
    @Bindable var memory: MemorySettings
    var store: MemoryStore?
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Remember what I type", isOn: $memory.rememberTyping)
                HStack {
                    if memory.isPaused {
                        Text("Paused until \(memory.pausedUntil!.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Button("Resume") { memory.resume() }
                    } else {
                        Button("Pause 1 hour") { memory.pause(for: 3600) }
                        Button("Pause until tomorrow") { memory.pause(for: Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400)).timeIntervalSinceNow) }
                    }
                }
                .disabled(!memory.rememberTyping)
            } header: {
                Text("Capture")
            } footer: {
                Text("keybro saves messages after you pause typing and when you send them. Password fields are never read.")
            }

            Section("Never read these apps") {
                ForEach(memory.blockedApps.sorted(by: { appName($0) < appName($1) }), id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { memory.blockedApps.remove(id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add a running app") {
                    ForEach(runningApps(), id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let id = app.bundleIdentifier { memory.blockedApps.insert(id) }
                        }
                    }
                }
                Button("Restore defaults") { memory.blockedApps = TypingWatcher.defaultBlockedApps }
                    .buttonStyle(.link)
            }

            Section("Forget") {
                HStack {
                    Button("Forget the last hour") {
                        let n = (try? store?.forget(since: Date().addingTimeInterval(-3600))) ?? 0
                        message = "Forgot \(n) \(n == 1 ? "item" : "items")."
                    }
                    Spacer()
                    if confirmDelete {
                        Text("Delete everything?").foregroundStyle(.red)
                        Button("Delete", role: .destructive) {
                            try? store?.deleteEverything()
                            confirmDelete = false
                            message = "All memory deleted."
                        }
                        Button("Keep") { confirmDelete = false }
                    } else {
                        Button("Delete all memory…", role: .destructive) { confirmDelete = true }
                    }
                }
                .disabled(store == nil)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !memory.blockedApps.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    var memory: MemorySettings
    var store: MemoryStore?
    var openMemory: () -> Void
    @State private var today: [MemoryStore.AppCount] = []
    @State private var week: [MemoryStore.AppCount] = []
    @State private var total = 0

    var body: some View {
        Form {
            Section("Captured today") { counts(today) }
            Section("Last 7 days") { counts(week) }
            Section {
                LabeledContent("Stored at", value: MemoryStore.defaultURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                LabeledContent("Items", value: "\(total)")
                LabeledContent("Never read", value: "Password fields, blocked apps, anything while paused")
                LabeledContent("Never saved", value: "API keys, tokens, card numbers, OTPs, sexual content")
                Button("Open Memory…", action: openMemory)
            } header: {
                Text("Where it lives")
            } footer: {
                Text("Everything stays in one file on this Mac, readable only by you. Nothing is uploaded, except what you send to Claude when you use Generate or Fix.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func counts(_ items: [MemoryStore.AppCount]) -> some View {
        if items.isEmpty {
            Text("Nothing").foregroundStyle(.secondary)
        } else {
            ForEach(items, id: \.surface) { item in
                LabeledContent(item.appName ?? item.surface) {
                    Text("\(item.count) · last \(item.last?.formatted(date: .omitted, time: .shortened) ?? "-")")
                }
            }
        }
    }

    private func load() {
        guard let store else { return }
        today = (try? store.capturedByApp(since: Calendar.current.startOfDay(for: Date()))) ?? []
        week = (try? store.capturedByApp(since: Date().addingTimeInterval(-7 * 86_400))) ?? []
        total = (try? store.episodeCount()) ?? 0
    }
}

// MARK: - Engine

private struct EngineSettings: View {
    var state: AppState

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code", value: state.claudePath?.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Not found")
                HStack {
                    Button("Test") { state.testClaude() }
                        .disabled(state.claudePath == nil || state.claudeTest == .running)
                    TestResult(state: state)
                }
            } header: {
                Text("Generate and Fix")
            } footer: {
                Text("Fix uses Haiku, Generate uses Sonnet, both through your Claude Code login. No API keys.")
            }
        }
        .formStyle(.grouped)
    }
}
