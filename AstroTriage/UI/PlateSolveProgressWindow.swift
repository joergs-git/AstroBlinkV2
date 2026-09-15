// Plate-solve progress panel.
//
// Solving a session is minutes of work in a separate process, with nothing to see. A line in
// the status bar is too easy to miss: the user starts a run over 200 frames, the window does
// not visibly change, and it is not obvious anything is happening at all.
//
// Fixed size on purpose, so the hard `.frame(width:height:)` is correct here — unlike the
// result table, which must be resizable (see PlateSolveWindowTests).
//
// v6.9.0

import SwiftUI
import AppKit

@MainActor
final class PlateSolveProgressWindowController {
    static let shared = PlateSolveProgressWindowController()

    private var window: NSWindow?
    private let model = PlateSolveProgressModel()

    /// Show the panel and report progress into it. `onCancel` is called once, from the main
    /// thread, when the user asks to stop.
    func show(total: Int, onCancel: @escaping () -> Void) {
        model.reset(total: total, onCancel: onCancel)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: PlateSolveProgressView(model: model)
            .frame(width: 420, height: 150))
        controller.preferredContentSize = NSSize(width: 420, height: 150)

        let win = NSWindow(contentViewController: controller)
        // No close button: the run is stopped with Cancel, not by hiding the panel.
        win.styleMask = [.titled]
        win.title = "Plate Solving"
        win.isRestorable = false
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func update(completed: Int, total: Int, filename: String) {
        model.update(completed: completed, total: total, filename: filename)
    }

    /// Switch the panel to the write-back phase, which has no per-frame count of its own.
    func showWriting() {
        model.beginWriting()
    }

    func dismiss() {
        window?.orderOut(nil)
    }
}

@MainActor
final class PlateSolveProgressModel: ObservableObject {
    @Published var completed = 0
    @Published var total = 0
    @Published var filename = ""
    @Published var isWriting = false
    @Published var isCancelling = false

    private var onCancel: (() -> Void)?

    func reset(total: Int, onCancel: @escaping () -> Void) {
        self.total = total
        self.onCancel = onCancel
        completed = 0
        filename = ""
        isWriting = false
        isCancelling = false
    }

    func update(completed: Int, total: Int, filename: String) {
        self.completed = completed
        self.total = total
        self.filename = filename
    }

    func beginWriting() {
        isWriting = true
        filename = ""
    }

    func cancel() {
        guard !isCancelling else { return }
        isCancelling = true
        onCancel?()
    }
}

private struct PlateSolveProgressView: View {
    @ObservedObject var model: PlateSolveProgressModel

    private var fraction: Double {
        guard model.total > 0 else { return 0 }
        return min(1, Double(model.completed) / Double(model.total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(headline)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
            }

            // Determinate while solving — the user can see how far a long run has to go.
            if model.isWriting {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }

            // Shows WHICH frame is being worked on, so a stall is visible as a stuck name
            // rather than as an unchanging bar.
            Text(model.filename.isEmpty ? " " : model.filename)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(model.isCancelling ? "Stopping…" : "Cancel") { model.cancel() }
                    .disabled(model.isCancelling || model.isWriting)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }

    private var headline: String {
        if model.isCancelling { return "Finishing the frames already started…" }
        if model.isWriting    { return "Writing WCS into the files…" }
        if model.total == 0   { return "Preparing…" }
        return "Solving \(model.completed) of \(model.total)…"
    }
}
