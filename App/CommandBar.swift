import AppKit
import KeybroKit
import SwiftUI

/// Borderless panels can't take keyboard input unless they say so.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating bar at the caret for Generate. It takes typing without activating keybro,
/// so the app you were in stays the active app and gets its focus back on insert.
@MainActor
final class CommandBarPanel {
    private let controller: GenerateController
    private let panel: KeyablePanel
    private var observer: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?

    init(controller: GenerateController) {
        self.controller = controller
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: CommandBarView(controller: controller))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting

        // Clicking somewhere else closes the bar, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                if controller.isOpen { controller.cancel() }
            }
        }

        observer = Task { [weak self] in
            var wasOpen = false
            for await isOpen in Observations({ controller.isOpen }) {
                guard let self else { return }
                if isOpen && !wasOpen { self.show() }
                if !isOpen { self.panel.orderOut(nil) }
                wasOpen = isOpen
            }
        }
    }

    private func show() {
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? CGSize(width: 460, height: 120)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, anchor: controller.target?.anchor))
        panel.makeKeyAndOrderFront(nil)
    }

    /// Below the caret and kept on screen; above it if there's no room below.
    private func origin(for size: CGSize, anchor: CGRect?) -> CGPoint {
        let a = anchor ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: a.midX, y: a.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = a.minX - 20
        // Keep the bar's top edge fixed while the draft grows downward.
        var y = a.minY - size.height - 8
        if y < visible.minY { y = a.maxY + 8 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }
}

struct CommandBarView: View {
    var controller: GenerateController
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            chips
            if !controller.draft.isEmpty || controller.phase == .generating {
                Divider().padding(.top, 10)
                draftArea
            }
            if case .failed(let message) = controller.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            Divider().padding(.top, 10)
            footer
        }
        .frame(width: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(8)
        .onAppear { focused = true }
        .onChange(of: controller.phase) { _, phase in
            if phase == .composing || phase == .ready { focused = true }
            if phase == .composing { input = "" }
        }
        .onKeyPress(.upArrow) { controller.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { controller.moveSelection(by: 1); return .handled }
        .onExitCommand { controller.cancel() }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Text("k")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            TextField(placeholder, text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit {
                    controller.submit(input)
                    input = ""
                }
                .disabled(controller.phase == .generating)
            if controller.phase == .generating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var placeholder: String {
        switch controller.phase {
        case .ready: "Ask for changes, or press ↵ to insert"
        case .generating: "Writing…"
        default: controller.target?.text.isEmpty == false ? "How should I rewrite the selection?" : "What do you want to say?"
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let app = controller.target?.appName {
                let who = controller.draft.contact.map { " (\($0))" } ?? ""
                chip(app + who, on: true)
            }
            if controller.phase != .composing {
                chip(controller.hasScreenshot ? "screen" : "no screen access", on: controller.hasScreenshot)
            }
            if controller.target?.text.isEmpty == false {
                chip("rewriting selection", on: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func chip(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .background(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1), in: Capsule())
    }

    private var draftArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(DraftVariant.allCases, id: \.self) { variant in
                    let available = controller.draft.variants[variant] != nil
                    Button(variant.title) { controller.select(variant) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .foregroundStyle(controller.selected == variant ? Color(nsColor: .windowBackgroundColor) : .secondary)
                        .background(controller.selected == variant ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .opacity(available ? 1 : 0.4)
                        .disabled(!available)
                }
            }
            Text(controller.currentText ?? "Writing…")
                .font(.system(size: 14.5))
                .foregroundStyle(controller.currentText == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if controller.phase == .ready {
                hint("↵", "Insert")
                hint("↑↓", "Version")
                Text("type to refine").foregroundStyle(.secondary)
            } else {
                hint("↵", controller.phase == .composing ? "Write" : "Retry")
            }
            Spacer()
            hint("esc", "Cancel")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
            Text(label).foregroundStyle(.secondary)
        }
    }
}
