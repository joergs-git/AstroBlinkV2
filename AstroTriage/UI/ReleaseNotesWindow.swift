// Release Notes window — shows what's new in each version.
// Accessible from Help > What's New menu item.

import SwiftUI

class ReleaseNotesWindowController {
    static let shared = ReleaseNotesWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: ReleaseNotesView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        win.title = "What's New — AstroBlinkV2 v\(version)"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 420, height: 400)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Release Notes View

struct ReleaseNotesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                releaseSection(
                    version: "3.7.0",
                    date: "March 13, 2026",
                    items: [
                        (.added, "Benchmark Sharing & Community Leaderboard", "Share your stacking and session load benchmarks anonymously. See how your machine ranks against others. Privacy-first: only hardware specs and timing shared."),
                        (.added, "Session Load Benchmarks", "New \"Session Load\" tab — compare file scanning, first image, header reading, and caching performance. Ranked by MB/s throughput, auto-detects SSD vs network."),
                        (.added, "Sortable Leaderboard Columns", "Click any column header to sort. Secondary sort by primary metric on ties."),
                        (.added, "Release Notes in App", "You're looking at it! Help > What's New."),
                        (.added, "Speedometer Toolbar Icon", "Quick access to Benchmark Stats from the toolbar."),
                        (.changed, "Toolbar Layout", "Separator between icons and sliders. Centered image settings. MeridianFlip moved to row 1."),
                        (.changed, "Fair Ranking", "Stacking ranked by t/frame (seconds per frame) for fair comparison across frame counts."),
                    ]
                )

                releaseSection(
                    version: "3.6.0",
                    date: "March 12, 2026",
                    items: [
                        (.added, "GPU Star Metrics", "HFR and FWHM automatically computed during session load via GPU star detection + Gaussian fitting."),
                        (.added, "ROTATOR Meridian Flip Detection", "Works with mounts that don't report PIERSIDE (e.g. ZWO ASIAIR on AM5)."),
                        (.added, "Observing Night Grouping", "Sessions spanning midnight correctly attributed to the evening's date."),
                        (.added, "Header Inspector Copy", "Multi-select + Cmd+C for header values."),
                    ]
                )

                releaseSection(
                    version: "3.5.0",
                    date: "March 10, 2026",
                    items: [
                        (.added, "Quality Scoring", "Automatic quality estimation with noiseMAD metric."),
                    ]
                )

                releaseSection(
                    version: "3.4.0",
                    date: "March 8, 2026",
                    items: [
                        (.added, "LightspeedStacker", "GPU-accelerated stacking — ~15s for 16 frames vs ~102s with NormalStacker."),
                        (.added, "Benchmark Stats Window", "See session load phase timings and memory usage."),
                        (.added, "Photoshop-style Zoom", "Click-drag horizontal zoom in stack result window."),
                    ]
                )

                releaseSection(
                    version: "3.2.0",
                    date: "March 6, 2026",
                    items: [
                        (.added, "Quick Stack", "Select 3+ subs, stack with star-alignment. Triangle matching, affine alignment."),
                        (.added, "Save as PNG", "Export stacked results with current adjustments."),
                        (.changed, "Doubled Slider Ranges", "Stretch 0-100%, Sharp -4/+4, Contrast -2/+2."),
                    ]
                )

                releaseSection(
                    version: "3.0.0",
                    date: "March 4, 2026",
                    items: [
                        (.added, "Spotlight-style Search", "Real-time filtering with column:value syntax."),
                        (.added, "Cmd+M Move to Folder", "Move checkmarked files to any destination."),
                        (.added, "GPU Post-Processing", "Real-time sharpening, contrast, dark level sliders."),
                    ]
                )
            }
            .padding(20)
        }
    }

    enum ChangeType {
        case added, changed, fixed

        var icon: String {
            switch self {
            case .added: return "plus.circle.fill"
            case .changed: return "arrow.triangle.2.circlepath.circle.fill"
            case .fixed: return "wrench.and.screwdriver.fill"
            }
        }

        var color: Color {
            switch self {
            case .added: return .green
            case .changed: return .blue
            case .fixed: return .orange
            }
        }
    }

    private func releaseSection(version: String, date: String, items: [(ChangeType, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("v\(version)")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Text("—")
                    .foregroundColor(.secondary)
                Text(date)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.0.icon)
                        .font(.system(size: 12))
                        .foregroundColor(item.0.color)
                        .frame(width: 16, alignment: .center)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1)
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.2)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if version != "3.0.0" {
                Divider()
            }
        }
    }
}
