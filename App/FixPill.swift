import AppKit
import KeybroKit
import SwiftUI

/// Small floating status next to the text being fixed. Never takes focus from the app
/// you're typing in, so clicking Undo doesn't move your cursor.
@MainActor
final class FixPillPanel {
    private let controller: FixController
    private let panel: NSPanel
    private var observer: Task<Void, Never>?

    init(controller: FixController) {
        self.controller = controller
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        let hosting = NSHostingView(rootView: FixPillView(controller: controller))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting

        observer = Task { [weak self] in
            for await state in Observations({ controller.state }) {
                self?.update(for: state)
            }
        }
    }

    private func update(for state: FixState) {
        guard state != .idle else {
            panel.orderOut(nil)
            return
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? CGSize(width: 240, height: 40)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, anchor: state.anchor))
        panel.orderFrontRegardless()
    }

    /// Just below the text, kept on screen. Above it if there's no room below.
    private func origin(for size: CGSize, anchor: CGRect?) -> CGPoint {
        let a = anchor ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: a.midX, y: a.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = a.minX
        var y = a.minY - size.height - 6
        if y < visible.minY { y = a.maxY + 6 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }
}

struct FixPillView: View {
    var controller: FixController

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .padding(6)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small)
            Text("Fixing…")
            Button("Cancel") { controller.dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        case .done(_, let changed):
            Image(systemName: changed ? "checkmark.circle.fill" : "hand.thumbsup.fill")
                .foregroundStyle(.green)
            Text(changed ? "Fixed" : "Already looks good")
            if changed {
                Button("Undo") { Task { await controller.undo() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        case .failed(_, let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
