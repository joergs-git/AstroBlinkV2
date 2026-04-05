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
    ("5.18.0", "April 5, 2026", [
        (.added, "VLM Check — Visual Anomaly Detection", "Toolbar button generates mosaic wallpapers from session frames grouped by target+filter+setup. Claude Vision AI analyzes for ice crystals, dew, clouds, obstructions, focus shifts, and light leaks — anomalies that metric-based scoring cannot catch."),
        (.added, "Deviation Map", "Waveform toggle shows per-tile deviation from group median. Bright areas highlight significant differences, making gradual degradation (e.g., slow dew buildup) easy to spot."),
        (.added, "Interactive Mosaic Tiles", "Click any tile to mark/unmark the corresponding frame for pre-deletion (blue overlay). Anomaly list with jump-to-frame on click."),
        (.added, "Mark Flagged / Unmark", "One-click marking of all VLM-flagged frames, or clear marks set by the VLM window."),
        (.added, "Re-Analyze", "Re-run VLM analysis on current mosaic pages after marking/unmarking frames."),
        (.added, "Free VLM Quota", "10 free VLM checks per day via Supabase edge function. Unlimited with own Claude API key."),
    ]),
    ("5.15.0", "April 4, 2026", [
        (.added, "Target Catalog Browser", "Browse 533+ deep-sky objects from a Supabase-backed catalog. Search by name, filter by type/constellation/difficulty. Sortable column headers, hover card on target names, azimuth direction arrows, setup-specific integration hours. Detail panel with coordinates, photometry, filter recommendations, scoring weights, and aliases."),
        (.added, "Alt/Az Visibility Chart", "See tonight's altitude curve for any target with moon altitude overlay (dashed). Red dot marks current time. Shows max altitude, transit time, and hours above 30°."),
        (.added, "Weather Forecast Bar", "Tonight's cloud cover, seeing, temperature, humidity, and wind from 7Timer + Open-Meteo. Seeing quality contextualized for your latitude. Hourly cloud mini-chart with current hour highlighted."),
        (.added, "FOV Simulation", "Proportional target-in-sensor rectangle using your actual equipment profile. Shows plate scale and fill ratio. Switch between equipment setups."),
        (.added, "Filter Gap Analysis", "Compare recommended filter ratios against your actual integration hours from Frame History. Traffic-light bars per filter. 'Need X more hours of FILTER' recommendations."),
        (.added, "Location & Setup Picker", "Switch between known imaging locations and equipment setups. Weather and visibility recompute automatically."),
        (.added, "Moon Distance in List", "Angular separation from moon shown per target (red <30°, orange <60°). Moon illumination in weather bar."),
        (.added, "DSS Sky Survey Thumbnails", "NASA public domain sky survey images in the detail panel. Disk-cached by coordinates for fast reload."),
    ]),
    ("5.14.0", "April 3, 2026", [
        (.added, "Target-Aware Quality Scoring", "Metric weights adjust by target type: galaxies prioritize FWHM (1.4×), emission nebulae prioritize noise (1.4×), IFN weights noise 2.0×. 229+ embedded deep-sky targets with type classification."),
        (.added, "FOV Fill Ratio Modulation", "Secondary weight adjustment based on target angular size vs sensor FOV. Small target boosts FWHM weight; target filling frame boosts noise weight."),
        (.added, "Practical Significance MAD Floor", "Prevents z-score amplification in tight sessions. FWHM floor scales with focal length. Differences like FWHM 4.6 vs 4.5 no longer cause tier demotions."),
        (.added, "Planet Exclusion", "Solar system objects (Jupiter, Saturn, Moon, etc.) excluded from quality scoring — short-exposure lucky imaging uses fundamentally different metrics."),
        (.added, "Scoring Regression Tests", "9 golden-set tests with real M82 metrics catch scoring regressions before manual testing. Runs in 0.014s."),
        (.fixed, "GroupKey Canonicalization", "\"NGC 7000\", \"NGC7000\", and \"North America Nebula\" now correctly land in the same scoring group. FL-bucketed to prevent cross-setup scoring."),
        (.fixed, "Compare Filter Matching", "Compare with Best now prioritizes same filter + same setup. Never compares Ha to L or different filter classes."),
        (.fixed, "Dark Frame FL-Scaling", "Wide-field dome detection threshold adjusted for focal length. Fixes false positive on L-eXtreme filter at low gain."),
    ]),
    ("5.13.0", "April 3, 2026", [
        (.added, "User Confidence Rating", "Press 1/2/3 to rate frames with 1-3 stars. Yellow star icons in the new ★ column. Same key toggles off. Persisted across sessions via Frame History DB. Filter with rating:1/2/3."),
        (.added, "Chart Scroll & Zoom", "Frame History date-axis charts now support horizontal scroll and pinch-to-zoom. 90-day visible window, auto-positioned at most recent data."),
        (.added, "PixInsight Bridge v1.2", "Enhanced PI script: 'Open in AstroBlink' launches the app from PixInsight with your session folder pre-selected. 'Prepare for WBPP' creates a kept-files list with SSWEIGHT instructions."),
    ]),
    ("5.12.0", "April 2, 2026", [
        (.added, "Elliptical PSF Fitting", "New 5-parameter GPU kernel (A, σx, σy, θ, B) derives eccentricity and position angle analytically from the PSF shape — more accurate than image moments."),
        (.added, "PSF Flux Z-Score", "PSF Flux z-score now shown in Quality Metrics panel and tooltip. Shows how total stellar signal compares to the group."),
        (.added, "Frame History Re-Analysis", "Re-Analyze button in History window re-scores stale records with current algorithm. One click to update all frames scored with older versions."),
        (.added, "Monthly Chart Aggregation", "History charts auto-switch to monthly buckets when date range exceeds 6 months for cleaner long-term trends."),
        (.added, "PixInsight Bridge", "New companion PJSR script imports AstroBlink triage results into PixInsight. Reads CSV, displays triage table, writes SSWEIGHT keywords."),
        (.fixed, "FWHM on Poor Seeing Frames", "CPU FWHM values now preserved as fallback when GPU fit fails. Fixes missing FWHM/trailing data on frames with bad seeing."),
    ]),
    ("5.11.0", "April 2, 2026", [
        (.added, "GPU PSF Fitting", "Metal compute kernel fits circular Gaussian PSF model per star using Gauss-Newton optimization. Replaces CPU linearized FWHM with proper nonlinear fit — gives accurate amplitude, sigma, and flux."),
        (.added, "PSFSignalWeight Export", "PixInsight 1.8.9+ compatible PSFSWGHT keyword written alongside SSWEIGHT. More robust than SNRWeight — PSF flux inherently rejects hot pixels and satellites."),
        (.added, "PSF Flux Column", "New hideable column showing total PSF signal per frame. Higher = more useful star signal. Enable via column picker."),
        (.added, "Dome/Dark Frame Detection", "Closed dome images now reliably detected by star count + background level. Hot pixel clusters no longer fool the detector even when they produce valid HFR."),
        (.added, "Batch Delete Keyword", "New 'Delete Key' scope in Batch Rename removes any FITS/XISF header keyword entirely. Use for SSWEIGHT removal."),
        (.added, "Filter Search Aliases", "filter:Ha now matches H, H2, HII, H-alpha and all other canonical aliases."),
        (.fixed, "Session Sanity False Positives", "Single-night multi-filter sessions no longer false-trash frames when filters have different FWHM characteristics."),
        (.fixed, "Batch Header Editing", "Case-insensitive matching, null pointer crash fix, selected-files-only safety."),
    ]),
    ("5.10.3", "April 2, 2026", [
        (.fixed, "Trailing False Positives on Long FL", "Trailing garbage rules now require the frame to be a trailing outlier (z > 1σ) within its group. Fixes mass false positives on RC12/long FL where normal optical eccentricity triggered trailing detection."),
    ]),
    ("5.10.2", "April 1, 2026", [
        (.added, "Severity-Dependent Trailing", "Narrowband trailing penalty now escalates with severity. Mild trailing stays reduced, severe trailing gets full penalty. Fixes missed trailing on Ha/OIII/SII."),
        (.added, "Star Count Drop Detection", "New Rule 7b: frames with <65% stars + <65% SNR flagged as atmospheric attenuation (cloud/dew/fog)."),
        (.added, "Aggressive Auto-Mark Upgrade", "Now also catches weak-good frames with <30% SNR contribution — negligible signal that degrades the stack."),
        (.fixed, "Narrowband Trailing Detection", "Severe trailing on narrowband was mathematically impossible to detect (threshold 2.33, score max 1.0). Now uses absolute ceiling + severity escalation."),
        (.fixed, "Missing Quality Scores", "Fixed race condition where cached preview frames skipped metric analysis. All frames now reliably scored."),
    ]),
    ("5.10.1", "April 1, 2026", [
        (.added, "Zoom Overlay", "True pixel zoom percentage bottom-right of image canvas. Updates live during drag, pinch, and keyboard zoom."),
        (.added, "Zoom Shortcuts", "Cmd+0: fit to view. Cmd+1: 100% actual pixels. Cmd+2: 200%. Cmd+/Cmd-: 25% step zoom. Font size moved to View menu."),
        (.added, "Option+Drag Pan", "Hold Option and drag to pan the image — faster and more precise than scroll wheel."),
        (.fixed, "iCloud Multi-Mac Sync", "Fixed race condition, evicted file downloads, and stale DB after import. Multi-Mac sync now works reliably."),
    ]),
    ("5.10.0", "March 31, 2026", [
        (.added, "Blink Playback", "Play/stop button with delay picker (0.1-2s) blinks through visible images endlessly. Multi-select blinks only selected frames. ESC to stop."),
        (.added, "Convergence Guard", "Autopilot warns before marking when quality spread is tight or SNR loss exceeds integration loss. Prevents over-culling with diminishing returns."),
        (.added, "Session Spread Stats", "Auto-Mark popover shows per-metric distribution with min/max, z-score spread, and stack readiness bar."),
        (.fixed, "File > Open Menu", "Menu item now works — was posting notification without observer."),
        (.fixed, "AIsaac 800-Frame Marking", "Increased max_tokens to 4096 — large batch mark commands no longer truncate."),
    ]),
    ("5.9.0", "March 30, 2026", [
        (.added, "AIsaac Collapsible Window", "AIsaac now starts as a compact floating strip with preset chips and input field. Click to expand full chat — 80% screen height. Always on top."),
        (.added, "AIsaac Weather-Aware", "Every AIsaac response now considers local weather, seeing, moon phase, and conditions — not just Plan Tonight. Ask anything and get weather-informed advice."),
        (.added, "AIsaac Knows Your History", "Ask 'What targets have I imaged?' or 'Where do I need more data?' — AIsaac queries your full Frame History database."),
        (.added, "Mini Histogram", "64-bin luminance histogram in the viewer toolbar, computed from raw pre-stretch data."),
        (.added, "Filter Totals", "Per-filter integration summary with hours, percentages, and color bars in Session Overview. Canonical sort order L R G B Ha OIII SII."),
        (.added, "Deletion Tracking", "AIsaac planner shows how much data you've deleted per target to prevent over-culling."),
        (.fixed, "Culling Spiral of Death", "Quality scores no longer recalculate after deletion — prevents iterative over-culling where good frames become 'relatively bad' in smaller groups."),
        (.fixed, "Meridian Flip XOR Logic", "Per-target orientation correction handles same-pierside + rotator change across nights. Both changed = cancel out."),
        (.fixed, "Quality 'Why' Text", "Full reason text visible — no longer truncated after 2 lines."),
    ]),
    ("5.8.3", "March 30, 2026", [
        (.fixed, "iCloud Sync Reliability", "Frame History sync dialog now runs at startup to detect diverging databases across Macs. Database also exported to iCloud on app quit — no more stale backups."),
    ]),
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
