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

        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let hostingView = NSHostingView(rootView: ReleaseNotesView().environment(\.fontScale, savedScale))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "What's New — AstroBlinkV2"
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
    ("5.8.2", "March 29, 2026", [
        (.added, "AIsaac Remote Knowledge", "AIsaac's knowledge can now be updated from the server without app releases. New features, tips, and corrections appear automatically within an hour."),
        (.added, "AIsaac Bortle Awareness", "AIsaac now understands fractional Bortle sky quality from VIIRS 2024 satellite data and can advise on filter choice based on your light pollution."),
    ]),
    ("5.8.1", "March 29, 2026", [
        (.added, "Rich Tooltips Everywhere", "All 6 History charts show full context on hover: targets, filters, FWHM, moon %, cause analysis for bad nights. Performance shows per-setup FWHM breakdown."),
        (.added, "Conditions Chart Redesign", "Toggleable X-axis: Moon / FWHM / Temperature / Bortle. Nearest-point hover shows all environmental factors. See what really impacts your background noise."),
        (.added, "Setups Tooltip", "Hover Setup Comparison bars to see frame count, date range, trash rate, and target list per equipment combo."),
        (.fixed, "GRDB Crash", "Fixed reentrant database access crash when hovering Performance chart with All Setups selected."),
    ]),
    ("5.8.0", "March 29, 2026", [
        (.added, "Chart Hover Tooltips", "Mouse over Score, Efficiency, and Performance charts to see per-night details — score, retention, FWHM with dashed crosshair."),
        (.added, "Time Range Filter", "All / 3M / 6M / 9M / 12M / 24M / 36M picker filters all History charts and summary cards by date range."),
        (.added, "Rolling Average Picker", "5 / 10 / 20 session window selector on Performance chart for smoother or more responsive FWHM trending."),
        (.added, "Integration Progress Redesign", "Hours instead of frames, per-filter stacked bars with hover detail showing filter breakdown, nights, best FWHM. Sortable asc/desc."),
        (.added, "AIsaac Session Planner", "Plan Tonight now includes moon phase, twilight times, per-target filter gaps, recent performance trends, and weather-adaptive exposure advice."),
        (.added, "Target Catalog Expansion", "300+ targets with common names — all Messier, major NGC/IC, Sharpless, Barnard, Abell, vdB, LDN objects and cross-references."),
        (.fixed, "Chart Bar Overflow", "Bars no longer bleed through header, tabs, or summary cards. Global clipping on all chart plot areas."),
        (.fixed, "Chart Flickering", "Stable content-based IDs replace UUID() in all chart data structs. No more animation jitter on re-render."),
        (.fixed, "Flexible Catalog Matching", "IC1848 = IC 1848 = IC-1848 = iC18 48. Handles any separator/spacing combo for NGC, IC, M, SH2, and 20+ catalog prefixes."),
        (.fixed, "Target Deduplication", "M 82 and M82 now merge into one entry in Progress chart, target picker, and summary stats."),
    ]),
    ("5.7.1", "March 29, 2026", [
        (.added, "Bortle Sky Quality (VIIRS 2024)", "Real satellite-measured light pollution for every frame. Fractional Bortle (B4.8) from NOAA VIIRS 2024 via Supabase. Offline fallback via embedded Falchi atlas."),
        (.added, "In-App Messaging", "Server-driven announcements and feedback collection without app updates. Rich actions, targeting, email collection with AIsaac boost."),
        (.added, "Target Clustering", "Canonical target names for cross-session grouping. \"NGC 7000\" = \"NGC7000\", \"Orion Nebula\" = \"M42\". ~150 aliases."),
        (.added, "Chart Summary Cards", "Frames, Nights, Best FWHM, Trash Rate, Targets at a glance above History charts."),
        (.added, "Algorithm Versioning", "DB records track scoring algorithm version for future re-analysis detection."),
        (.changed, "UI Consistency", "Night mode and Cmd+/- font scaling now work in ALL windows (Benchmark, Stack, Color Combine, Release Notes)."),
        (.fixed, "Archive Scanner Calibration", "FLAT/DARK/BIAS frames no longer scanned into Frame History. 1,792 calibration records cleaned up."),
    ]),
    ("5.5.0", "March 27, 2026", [
        (.added, "Session-Wide Sanity Check", "Cross-group quality comparison catches uniformly bad nights. Uses P10/P90 benchmarks — 2+ metrics far below session norm = trash."),
        (.added, "Uncertain Quality Tier", "Blue ? icon for small groups (<8 frames) with ambiguous quality. Visual inspection recommended."),
        (.added, "Filter-Aware Twilight", "Narrowband tolerates nautical twilight (sun -12° to -6°). RGB/L flagged as garbage. Context shown in quality metrics."),
        (.fixed, "Chain Detection Timing", "Fixed race condition where starChainFraction was nil during scoring. Tracking hops now reliably detected."),
        (.fixed, "Compare Cross-Group Fallback", "Compare with Best now searches across all filters when same-group best is also garbage."),
    ]),
    ("5.4.0", "March 27, 2026", [
        (.added, "Font Size Scaling", "Cmd+/Cmd-/Cmd+0 to adjust UI font size across file list, inspector, session overview, and compare window. Persisted via iCloud."),
        (.added, "Auto-Mark Toolbar Button", "Culling autopilot promoted to main toolbar with colorful gradient icon. One-click Conservative/Balanced/Aggressive auto-marking."),
        (.added, "Toolbar Reorganization", "Buttons grouped by function with visual dividers. Toggle labels reformatted to two-line layout."),
        (.fixed, "False Satellite Trail Detection", "Edge-on galaxies (M82, NGC 4565) no longer trigger false 'zero/near-zero stars' garbage. Axis ratio verification rejects false positives."),
        (.fixed, "What's New Version Drift", "Button no longer shows hardcoded version number."),
    ]),
    ("5.3.0", "March 23, 2026", [
        (.added, "Community Detection Learning", "Opt-in anonymous sharing of quality metrics to improve detection for everyone. No filenames, images, or personal data shared — only metric averages like FWHM, SNR, and retention rate."),
        (.added, "Instant Community Calibration", "New equipment gets instant quality baselines from the community — no 30-frame warmup needed. Gray lock badge for community-locked frames."),
        (.added, "Community Status Bar Toggle", "Clickable icon next to iCloud. Green = active. Hover for privacy explanation."),
    ]),
    ("5.2.1", "March 23, 2026", [
        (.fixed, "Compare Window Trash Recommendation", "Z-score-based trash frames now correctly show \"DELETE — below quality threshold\" in the Compare window instead of no recommendation."),
        (.fixed, "Compare Best Selection Consistency", "Context menu \"Compare with Best\" now uses fine-grained z-score ranking, matching keyboard shortcut behavior."),
        (.fixed, "Compare Window Readability", "Quality metrics and recommendation text size increased from 10pt to 13pt."),
    ]),
    ("5.2.0", "March 22, 2026", [
        (.added, "FL-Adaptive Eccentricity Detection", "New Rule 5: frames with eccentricity > 2× the focal-length baseline are flagged as garbage. Adapts automatically to any optics — no fixed thresholds."),
        (.added, "Multi-Reason Garbage Display", "Quality panel now shows ALL detected issues per frame, not just the first one. Multiple reasons displayed on separate lines."),
        (.added, "Twilight/Dawn Detection", "Sun position computed from capture time + site coordinates. Frames shot during civil twilight or daylight are auto-flagged. Twilight phase shown for all frames."),
        (.added, "Decentered Target Detection", "When plate-solved coordinates show the frame center shifted off sensor (mount recenter), a specific garbage reason is shown."),
        (.fixed, "Trailing Detection False Negatives", "Frames with extreme star elongation but normal FWHM (e.g., long focal length setups) were incorrectly rated as Good. Now caught by direct eccentricity check."),
    ]),
    ("5.1.3", "March 22, 2026", [
        (.fixed, "Splash Screen Checkbox", "\"Don't show on startup\" checkbox now works correctly — clicking it no longer immediately dismisses the splash window."),
        (.fixed, "Background Anomaly False Positives", "Quality scoring no longer flags the best frames as \"abnormal background\". Only elevated background (clouds/gradient) is flagged — lower background (clearer sky) is correctly treated as good."),
    ]),
    ("4.0.0", "March 15, 2026", [
        (.added, "Star Eccentricity Detection", "2D image moment analysis (SExtractor method) detects star elongation from tracking errors. Eccentricity > 0.6 = immediate trash. Weight 1.5x in quality scoring (highest)."),
        (.added, "SNR Contribution Score", "Shows how much each frame adds to a weighted stack relative to the best frame: (SNR_i/SNR_best)^2. Hidden for trash frames to avoid misleading display."),
        (.added, "Per-Metric Quality Tooltip", "Hover quality icon for per-metric z-score breakdown (Stars, FWHM, HFR, Noise, Ecc) with arrows, SNR contribution %, and bold KEEP/DELETE recommendation."),
        (.added, "Orange Gradient Icons", "Borderline tier split into 4 visual sub-levels from light amber (nearly good) to deep orange (nearly trash)."),
        (.added, "Live SNR Retention Bar", "Status bar shows real-time SNR retention % as you mark frames. Green (>95%) to red (<80%). Updates on every Space toggle."),
        (.added, "Deletion Impact Summary", "Pre-delete dialog shows integration time lost, SNR impact %, and quality tier breakdown before moving files."),
        (.added, "Smart Keep/Delete Recommendations", "Research-backed labels: round stars = always KEEP (even with worse seeing). Elongated = DELETE. Based on stacking SNR physics."),
        (.changed, "Compare with Best", "Now picks the truly best frame by z-score, not an arbitrary one from the same quality tier."),
        (.changed, "Quality Sort", "Re-applies after every quality recomputation (not just initial load). Sort persists after Reset."),
        (.fixed, "Metric Bar Scroll Bug", "Fixed constraint accumulation causing cell values to disappear after scrolling. Proportional width constraints now properly removed on reuse."),
        (.fixed, "Stretch Slider Sync", "Slider initial value now loads from saved settings instead of hardcoded 0.25."),
    ]),
    ("3.13.0", "March 14, 2026", [
        (.added, "Help: Background Tab", "Comprehensive FAQ-style documentation covering quality scoring, metric bars, smart sorting, STF stretching, debayering, denoise, deconvolution, and triage tips."),
        (.added, "4-Tier Quality Icons", "Full green (excellent), half-green (good), orange (borderline), red (garbage). Z-score shown on hover. Fine-grained sorting within tiers."),
        (.added, "Compare with Best (C key)", "Side-by-side synchronized zoom/pan comparison with the best frame from the same group. Opens at 300% zoom. ESC to close."),
        (.added, "Metric Bar Indicators", "Tiny red-to-green bars below Stars/FWHM/HFR/SNR show per-group relative ranking at a glance."),
        (.added, "Context Menu", "Right-click: Open With... (PixInsight etc.), Show in Finder, Compare with Best, Copy paths."),
        (.changed, "Smart Column Sorting", "4-case auto-sort by session type with exposure as grouping element. Fires once after precache completes."),
        (.changed, "Quality Scoring", "Two-stage detection: Stage 1 catches garbage (< 50% of median), pitch-black frames. Stage 2 ranks by weighted z-score. Star weight 1.2x."),
        (.fixed, "FITS Special Characters", "Files with brackets/parentheses in names now open correctly (cfitsio diskfile API)."),
        (.fixed, "Initial Sort Timing", "Sort now applies correctly after first precache, using recommended column order regardless of saved layout."),
    ]),
    ("3.12.0", "March 14, 2026", [
        (.added, "Double-Click Image Preview", "Double-click any image in the file list to open it in a floating window with Stretch, Sharpen, Contrast, Dark Level, Color, Denoise, and Deconvolution controls. Open multiple images for side-by-side comparison."),
        (.added, "GPU Bilateral Denoise", "Two-pass noise reduction: bilateral filter for pixel noise + chrominance denoise in YCbCr space to remove green/magenta color patches. Slider 0-200%."),
        (.added, "Richardson-Lucy Deconvolution", "Iterative ML deconvolution with Gaussian PSF for recovering star and nebula detail. Toggle between RL and multi-scale USM. GPU-accelerated, 5-20 iterations."),
        (.added, "OSC Debayer in Stacking", "Color camera (OSC) images are now debayered before stacking, producing full-color stacked results instead of monochrome."),
        (.added, "Hot/Cold Pixel Rejection", "GPU-based cosmetic correction before stacking: detects and replaces hot/cold pixels using 3x3 median + sigma-clipped MAD threshold."),
        (.added, "Color Saturation Slider", "Adjustable color saturation (0-3x) in all result windows. Only appears for RGB/OSC images."),
        (.changed, "True Star Count", "Stars column now shows the actual total number of detected stars (not capped at 50). GPU atomic counter reads the true count."),
        (.changed, "Dynamic Column Order", "Columns auto-reorder based on session content: single-object sessions prioritize quality metrics, multi-object sessions move Object column to front."),
        (.changed, "Center-Crop Quality", "HFR, FWHM, and noise measurements use center 70% of image, excluding edge stars affected by optical aberrations, vignetting, and dithering."),
        (.changed, "Per-Channel STF Stretch", "Unlinked stretch with per-channel shadow clip and midtone balance. Linked toggle available. Fixed vDSP bug that caused color casts."),
        (.fixed, "PNG Export Colors", "Save PNG now correctly handles RGBA vs BGRA textures — red channel no longer swapped with blue."),
        (.fixed, "Splash Dismiss", "Splash screen now dismisses on any click, including inside the splash window."),
    ]),
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
    @Environment(\.fontScale) private var fontScale
    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }
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
                    .font(.system(size: fs(12)))
                }
                .buttonStyle(.borderedProminent)
                .padding(10)

                Spacer()

                Button(action: copyAllToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy All")
                    }
                    .font(.system(size: fs(12)))
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
                    .font(.system(size: fs(18), weight: .bold, design: .monospaced))
                Text("—")
                    .foregroundColor(.secondary)
                Text(date)
                    .font(.system(size: fs(13)))
                    .foregroundColor(.secondary)
            }

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.0.icon)
                        .font(.system(size: fs(12)))
                        .foregroundColor(item.0.color)
                        .frame(width: 16, alignment: .center)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1)
                            .font(.system(size: fs(13), weight: .semibold))
                        Text(item.2)
                            .font(.system(size: fs(12)))
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
