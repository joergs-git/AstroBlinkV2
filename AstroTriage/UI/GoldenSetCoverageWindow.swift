// Golden-set coverage window — shows how much curated material exists in a golden-set root
// (per case, per scope × defect), answering "do we have enough yet?". Read-only.
// Window plumbing mirrors MCPConnectorWindowController (singleton + contentRect-capped NSHostingView).

import SwiftUI
import AppKit

final class GoldenSetCoverageWindowController {
    static let shared = GoldenSetCoverageWindowController()
    private var window: NSWindow?

    /// Show coverage for a specific root. If no root is given, prompt for one.
    func show(root: URL? = nil) {
        let chosen: URL?
        if let root = root {
            chosen = root
        } else {
            let panel = NSOpenPanel()
            panel.title = "Golden Set Coverage"
            panel.message = "Choose the golden-set ROOT folder to inspect"
            panel.prompt = "Inspect"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return }
            chosen = panel.url
        }
        guard let root = chosen else { return }

        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let report = GoldenSetCoverage.scan(root: root)

        if let w = window, w.isVisible {
            w.contentView = NSHostingView(rootView: GoldenSetCoverageView(report: report))
            w.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Golden Set Coverage"
        win.contentView = NSHostingView(rootView: GoldenSetCoverageView(report: report))
        win.center()
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.minSize = NSSize(width: 520, height: 400)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

private struct GoldenSetCoverageView: View {
    let report: GoldenSetCoverage.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Golden Set Coverage")
                .font(.title2).bold()
            Text(report.root.path)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)

            if report.isEmpty {
                Spacer()
                Text("No cases found. Label frames (right-click → Golden Set ▸) and export first.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 20) {
                    stat("Cases", "\(report.cases.count)")
                    stat("Good", "\(report.totalGood)")
                    stat("Bad", "\(report.totalBad)")
                    stat("Scopes", "\(report.scopes.count)")
                }
                Text("Targets: ≥\(GoldenSetCoverage.minGoodPerCase) good, ≥\(GoldenSetCoverage.minBadPerCase) bad per case (baseline = good only).")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.cases.sorted(by: { $0.name < $1.name }), id: \.name) { c in
                            HStack(spacing: 8) {
                                Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(c.ok ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                                    Text("scope \(c.scope) · \(c.token)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("good \(c.good)")
                                    .foregroundStyle(c.good >= GoldenSetCoverage.minGoodPerCase ? Color.primary : Color.orange)
                                Text("bad \(c.bad)")
                                    .foregroundStyle(c.isBaseline || c.bad >= GoldenSetCoverage.minBadPerCase ? Color.primary : Color.orange)
                            }
                            .font(.callout)
                            .padding(.vertical, 3)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 400)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).bold().monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
