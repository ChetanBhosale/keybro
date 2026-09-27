import AppKit
import KeybroKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var state: AppState
    var memory: MemorySettings
    var store: MemoryStore?
    var services: MemoryServices?
    var openMemory: () -> Void

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "keyboard") }
            MemorySettingsTab(memory: memory, store: store).tabItem { Label("Memory", systemImage: "brain") }
            PrivacySettings(memory: memory, store: store, openMemory: openMemory).tabItem { Label("Privacy", systemImage: "hand.raised") }
            EngineSettings(state: state, services: services).tabItem { Label("Engine", systemImage: "cpu") }
            ClaudeCodeSettings().tabItem { Label("Claude Code", systemImage: "terminal") }
        }
        .frame(width: 600, height: 540)
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
    var services: MemoryServices?
    @State private var appleAvailable = AppleTextModel.isAvailable
    @State private var ollamaAvailable: Bool?

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

            if let services {
                BackgroundSection(services: services, appleAvailable: appleAvailable, ollamaAvailable: ollamaAvailable)
            }
        }
        .formStyle(.grouped)
        .task(id: services?.ollamaModel) {
            guard let model = services?.ollamaModel else { return }
            ollamaAvailable = await OllamaTextModel(model: model).isAvailable()
        }
    }
}

private struct BackgroundSection: View {
    @Bindable var services: MemoryServices
    var appleAvailable: Bool
    var ollamaAvailable: Bool?

    var body: some View {
        Section {
            Picker("Model", selection: $services.engine) {
                ForEach(BackgroundEngine.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Apple on-device") {
                Text(appleAvailable ? "Available" : "Off (turn on Apple Intelligence)").foregroundStyle(appleAvailable ? .green : .secondary)
            }
            LabeledContent("Ollama") {
                HStack {
                    TextField("Model", text: $services.ollamaModel).frame(width: 140)
                    Text(ollamaAvailable == nil ? "Checking…" : ollamaAvailable! ? "Ready" : "Not running or not pulled")
                        .foregroundStyle(ollamaAvailable == true ? .green : .secondary)
                }
            }
            Toggle("Export Markdown for Obsidian after each update", isOn: $services.exportMarkdown)
            HStack {
                Button(services.running ? "Updating…" : "Update memory now") { Task { await services.runNow() } }
                    .disabled(services.running)
                Button("Open export folder") {
                    try? FileManager.default.createDirectory(at: MarkdownExporter.defaultFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(MarkdownExporter.defaultFolder)
                }
            }
            Text(services.lastReport).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let last = services.lastRun {
                Text("Last run \(last.formatted(date: .abbreviated, time: .shortened)). Runs daily after 9 PM.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Background memory")
        } footer: {
            Text("Each night keybro reads the day's messages and saves facts, promises, profiles and a digest. \"On this Mac only\" never sends them anywhere. Search by meaning uses Apple's on-device embeddings (\(services.indexed) indexed this session).")
        }
    }
}

// MARK: - Claude Code

private struct ClaudeCodeSettings: View {
    @State private var scope = MemoryScope.load()
    @State private var saved = false
    @State private var copied = false
    @State private var log: [String] = MemoryServices.accessLog()
    private let surfaces = ["whatsapp", "imessage", "telegram", "discord", "slack", "gmail", "mail", "linkedin", "x", "web", "note"]

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    Text(MemoryServices.mcpInstalled ? "Installed" : "Not built yet: run make mcp")
                        .foregroundStyle(MemoryServices.mcpInstalled ? .green : .orange)
                }
                HStack {
                    Text(MemoryServices.mcpAddCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MemoryServices.mcpAddCommand, forType: .string)
                        copied = true
                    }
                }
            } header: {
                Text("Connect")
            } footer: {
                Text("Run this once in Terminal. Then any Claude Code session can search your memory, look up people, and see open promises.")
            }

            Section {
                Stepper("Only the last \(scope.maxDays) days", value: $scope.maxDays, in: 1...3650, step: scope.maxDays < 30 ? 1 : 30)
                Toggle("Allow saving notes (remember)", isOn: $scope.allowWrite)
                VStack(alignment: .leading) {
                    Text("Hide these apps from Claude Code")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading) {
                        ForEach(surfaces, id: \.self) { surface in
                            Toggle(surface, isOn: Binding(
                                get: { scope.excludedSurfaces.contains(surface) },
                                set: { on in
                                    scope.excludedSurfaces.removeAll { $0 == surface }
                                    if on { scope.excludedSurfaces.append(surface) }
                                }))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                HStack {
                    Button("Save") {
                        try? FileManager.default.createDirectory(at: KeybroPaths.memory, withIntermediateDirectories: true)
                        saved = (try? scope.save()) != nil
                    }
                    if saved { Text("Saved. Applies to new Claude Code sessions.").font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("What Claude Code can see")
            }

            Section("Recent access") {
                if log.isEmpty {
                    Text("No requests yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(log, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).lineLimit(1) }
                }
                Button("Refresh") { log = MemoryServices.accessLog() }
            }
        }
        .formStyle(.grouped)
    }
}
