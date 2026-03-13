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

// MARK: - Release notes data (shared between view and copy)

private let allReleases: [(version: String, date: String, items: [(ReleaseNotesView.ChangeType, String, String)])] = [
    ("3.10.0", "March 13, 2026", [
        (.added, "About / Splash Screen", "Custom About window with app info, social links, Tell a Friend share sheet, What's New, and App Store buttons. Shows as splash on launch."),
        (.added, "Tell a Friend", "Share AstroBlinkV2 via native macOS share sheet — available in About window and Release Notes."),
        (.fixed, "Star Column Empty", "GPU-detected star count now correctly shown in file list (displayStarCount includes computedStarCount)."),
        (.changed, "Quality Scoring", "Cross-night comparison — groups by filter + target + exposure only, so consistently bad nights score lower overall."),
        (.fixed, "Spacebar Marking", "Keyboard-highlighted rows now correctly toggle pre-delete marks, including multi-selection and filtered views."),
        (.fixed, "Benchmark Total Ready Time", "Total session duration now freezes once both caching and headers complete, instead of continuously recalculating."),
        (.fixed, "Lock STF Interaction", "Locking STF on cached previews no longer darkens images. Stretch slider works correctly when STF is locked."),
        (.changed, "Toggle Order", "Toolbar toggle order: Apply All → Debayer → Lock STF → MeridianFlip (consistent left-to-right workflow)."),
        (.changed, "Benchmark Icon", "Light blue speedometer icon, positioned right of Night toggle."),
        (.changed, "Leaderboard Chip Column", "Left-aligned header to match column content."),
        (.changed, "Toolbar Cleanup", "Removed MEM/CPU stats from toolbar — cleaner layout."),
    ]),
    ("3.9.0", "March 13, 2026", [
        (.added, "Anti-Moiré Trilinear Filtering", "GPU mipmap-based filtering eliminates shimmer on MacBook screens when zoomed out. Pixel-accurate zoom preserved when zoomed in."),
        (.added, "Leaderboard Copy Button", "Copy entire leaderboard as tab-separated text for spreadsheets or forums."),
        (.changed, "Leaderboard Layout", "Proper column alignment, larger fonts (11pt), consistent spacing, wider window."),
        (.changed, "Leaderboard Limit", "Fetches up to 1000 entries (was 200), ordered newest first."),
        (.fixed, "Calibration Filtering", "Flexible matching — any filename or folder containing dark/flat/bias is excluded, not just strict NINA patterns."),
    ]),
    ("3.8.0", "March 13, 2026", [
        (.added, "Lights-Only Folder Scan", "Calibration frames (DARK, FLAT, BIAS) are automatically excluded when opening folders. Works via filename tokens and subfolder names. Individual file selection is unaffected."),
    ]),
    ("3.7.0", "March 13, 2026", [
        (.added, "Benchmark Sharing & Community Leaderboard", "Share your stacking and session load benchmarks anonymously. See how your machine ranks against others. Privacy-first: only hardware specs and timing shared."),
        (.added, "Session Load Benchmarks", "New \"Session Load\" tab — compare file scanning, first image, header reading, and caching performance. Ranked by MB/s throughput, auto-detects SSD vs network."),
        (.added, "Sortable Leaderboard Columns", "Click any column header to sort. Secondary sort by primary metric on ties."),
        (.added, "Release Notes in App", "You're looking at it! Help > What's New."),
        (.added, "Speedometer Toolbar Icon", "Quick access to Benchmark Stats from the toolbar."),
        (.changed, "Toolbar Layout", "Separator between icons and sliders. Centered image settings. MeridianFlip moved to row 1."),
        (.changed, "Fair Ranking", "Stacking ranked by t/frame (seconds per frame) for fair comparison across frame counts."),
    ]),
    ("3.6.0", "March 12, 2026", [
        (.added, "GPU Star Metrics", "HFR and FWHM automatically computed during session load via GPU star detection + Gaussian fitting."),
        (.added, "ROTATOR Meridian Flip Detection", "Works with mounts that don't report PIERSIDE (e.g. ZWO ASIAIR on AM5)."),
        (.added, "Observing Night Grouping", "Sessions spanning midnight correctly attributed to the evening's date."),
        (.added, "Header Inspector Copy", "Multi-select + Cmd+C for header values."),
    ]),
    ("3.5.0", "March 10, 2026", [
        (.added, "Quality Scoring", "Automatic quality estimation with noiseMAD metric."),
    ]),
    ("3.4.0", "March 8, 2026", [
        (.added, "LightspeedStacker", "GPU-accelerated stacking — ~15s for 16 frames vs ~102s with NormalStacker."),
        (.added, "Benchmark Stats Window", "See session load phase timings and memory usage."),
        (.added, "Photoshop-style Zoom", "Click-drag horizontal zoom in stack result window."),
    ]),
    ("3.2.0", "March 6, 2026", [
        (.added, "Quick Stack", "Select 3+ subs, stack with star-alignment. Triangle matching, affine alignment."),
        (.added, "Save as PNG", "Export stacked results with current adjustments."),
        (.changed, "Doubled Slider Ranges", "Stretch 0-100%, Sharp -4/+4, Contrast -2/+2."),
    ]),
    ("3.0.0", "March 4, 2026", [
        (.added, "Spotlight-style Search", "Real-time filtering with column:value syntax."),
        (.added, "Cmd+M Move to Folder", "Move checkmarked files to any destination."),
        (.added, "GPU Post-Processing", "Real-time sharpening, contrast, dark level sliders."),
    ]),
]

// MARK: - Release Notes View

struct ReleaseNotesView: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(allReleases.enumerated()), id: \.offset) { idx, release in
                        releaseSection(
                            version: release.version,
                            date: release.date,
                            items: release.items,
                            showDivider: idx < allReleases.count - 1
                        )
                    }
                }
                .padding(20)
                .textSelection(.enabled)
            }

            Divider()

            HStack {
                Button(action: shareApp) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Tell a Friend")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .padding(10)

                Spacer()

                Button(action: copyAllToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy All")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .padding(10)
            }
        }
    }

    private func shareApp() {
        let shareText = "Check out AstroBlinkV2 — a fast astrophotography image triage & stacking tool for macOS with GPU-accelerated auto-stretch, quality scoring, and LightspeedStacker!\n\n\(appStoreURL)"
        let url = URL(string: appStoreURL)!
        let picker = NSSharingServicePicker(items: [shareText, url])
        if let contentView = NSApp.keyWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    private func copyAllToClipboard() {
        var text = "AstroBlinkV2 — Release Notes\n"
        text += String(repeating: "=", count: 40) + "\n\n"

        for release in allReleases {
            text += "v\(release.version) — \(release.date)\n"
            text += String(repeating: "-", count: 30) + "\n"
            for item in release.items {
                let tag: String
                switch item.0 {
                case .added: tag = "NEW"
                case .changed: tag = "CHG"
                case .fixed: tag = "FIX"
                }
                text += "[\(tag)] \(item.1): \(item.2)\n"
            }
            text += "\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
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

    private func releaseSection(version: String, date: String, items: [(ChangeType, String, String)], showDivider: Bool = true) -> some View {
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

            if showDivider {
                Divider()
            }
        }
    }
}
