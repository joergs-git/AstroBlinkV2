// v3.13.0
import SwiftUI

// MARK: - App Store URL (update when published)
let appStoreURL = "https://apps.apple.com/app/astroblinkv2/id6760241266?mt=12"

@main
struct AstroBlinkV2App: App {
    // Use NSApplicationDelegateAdaptor so we can customize the About panel
    @NSApplicationDelegateAdaptor(AstroBlinkV2AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            // Replace default About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About AstroBlinkV2") {
                    AstroBlinkV2AppDelegate.showAboutPanel()
                }
            }

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .openFolderRequest, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // View menu: Columns visibility + Reset Settings
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Reset Settings to Defaults") {
                    NotificationCenter.default.post(name: .resetSettingsRequest, object: nil)
                }
            }

            // Edit menu: Batch Rename
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Batch Rename & Header Edit...") {
                    NotificationCenter.default.post(name: .showBatchRename, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // Window menu: Benchmark Stats
            CommandGroup(after: .windowList) {
                Button("Benchmark Stats") {
                    NotificationCenter.default.post(name: .showBenchmarkStats, object: nil)
                }
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button("AstroBlinkV2 Help") {
                    HelpWindowController.shared.showWindow(nil)
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Button("What's New in v3.13.0") {
                    ReleaseNotesWindowController.shared.show()
                }
            }
        }
    }
}

// Custom app delegate for About panel and cleanup
class AstroBlinkV2AppDelegate: NSObject, NSApplicationDelegate {

    // Quit the app when the main window is closed (single-window app)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Clean up all caches when the app quits so nothing piles up on disk
    func applicationWillTerminate(_ notification: Notification) {
        SessionCache.cleanupAllCaches()
    }

    // Show splash screen on launch (unless user opted out)
    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppSettings.loadBool(for: .hideSplash) != true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AboutWindowController.shared.show(asSplash: true)
            }
        }
    }

    static func showAboutPanel() {
        AboutWindowController.shared.show(asSplash: false)
    }
}

// MARK: - Custom About / Splash Window

class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?
    private var splashClickMonitor: Any?
    private var splashDismissed = false

    func show(asSplash: Bool) {
        // If already visible, bring to front
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        splashDismissed = false
        let hostingView = NSHostingView(rootView: AboutView(
            dismissAction: { [weak self] in self?.close() },
            isSplash: asSplash
        ))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About AstroBlinkV2"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true
        win.makeKeyAndOrderFront(nil)
        self.window = win

        // Splash mode: auto-dismiss on click or after 6 seconds
        if asSplash {
            splashClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                // Dismiss splash on any click or key press, anywhere.
                // Button/link click handlers fire before this monitor,
                // so links still work — splash just closes after.
                self?.dismissSplash()
                return event
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.dismissSplash()
            }
        }
    }

    private func dismissSplash() {
        guard !splashDismissed else { return }
        splashDismissed = true
        if let monitor = splashClickMonitor {
            NSEvent.removeMonitor(monitor)
            splashClickMonitor = nil
        }
        window?.close()
    }

    func close() {
        if let monitor = splashClickMonitor {
            NSEvent.removeMonitor(monitor)
            splashClickMonitor = nil
        }
        window?.close()
    }
}

// MARK: - About View (SwiftUI)

struct AboutView: View {
    var dismissAction: (() -> Void)?
    var isSplash: Bool = false
    @State private var shareAnchor: NSPoint = .zero
    @State private var hideSplash: Bool = AppSettings.loadBool(for: .hideSplash) ?? false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 12) {
            // App icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            // App name and version
            Text("AstroBlinkV2")
                .font(.system(size: 22, weight: .bold))
            Text("v\(version) (Build \(build))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Tagline
            Text("Enhanced and Inspired by PixInsight's Blink Tool")
                .font(.system(size: 11).italic())
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 20)

            // Author and links
            Text("by joergsflow")
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 16) {
                linkButton("GitHub", url: "https://github.com/joergs-git/AstroBlinkV2")
                linkButton("Instagram", url: "https://www.instagram.com/joergsflow/")
                linkButton("AstroBin", url: "https://app.astrobin.com/u/joergsflow#gallery")
            }
            .font(.system(size: 11))

            Divider()
                .padding(.horizontal, 20)

            // Action buttons — stacked vertically for readability
            VStack(spacing: 8) {
                Button(action: shareApp) {
                    Label("Tell a Friend", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 10) {
                    Button(action: {
                        dismissAction?()
                        ReleaseNotesWindowController.shared.show()
                    }) {
                        Label("What's New", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        dismissAction?()
                        if let url = URL(string: appStoreURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("App Store", systemImage: "arrow.down.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.system(size: 12))
            .padding(.top, 2)

            if isSplash {
                Toggle("Don't show on startup", isOn: $hideSplash)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .onChange(of: hideSplash) { newValue in
                        AppSettings.saveBool(newValue, for: .hideSplash)
                    }
            }

            Spacer()
                .frame(height: 4)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .padding(.horizontal, 24)
        .frame(width: 360)
    }

    private func linkButton(_ title: String, url: String) -> some View {
        Button(title) {
            if let link = URL(string: url) {
                NSWorkspace.shared.open(link)
            }
        }
        .buttonStyle(.link)
    }

    private func shareApp() {
        let shareText = "Check out AstroBlinkV2 — a fast astrophotography image triage & stacking tool for macOS with GPU-accelerated auto-stretch, quality scoring, and LightspeedStacker!\n\n\(appStoreURL)"
        let url = URL(string: appStoreURL)!
        let picker = NSSharingServicePicker(items: [shareText, url])
        // Show the share picker anchored to the key window
        if let contentView = NSApp.keyWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}

// Notifications for menu bar actions
extension Notification.Name {
    static let openFolderRequest = Notification.Name("openFolderRequest")
    static let resetSettingsRequest = Notification.Name("resetSettingsRequest")
    static let showBenchmarkStats = Notification.Name("showBenchmarkStats")
    static let showBatchRename = Notification.Name("showBatchRename")
}

// AppDelegate extension for help window
class AppDelegate: NSObject {
    @objc static func showHelpWindow() {
        HelpWindowController.shared.showWindow(nil)
    }
}

// Dedicated help window with all features and shortcuts
class HelpWindowController: NSWindowController {
    static let shared = HelpWindowController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        window.title = "AstroBlinkV2 v\(appVersion) — Help"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 500)
        super.init(window: window)

        let hostingView = NSHostingView(rootView: HelpTabView())
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// Two-tab help view: Usage (shortcuts & features) + Background (how & why)
enum HelpTab: String, CaseIterable {
    case usage = "Usage"
    case background = "Background"
}

struct HelpTabView: View {
    @State private var selectedTab: HelpTab = .usage

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(HelpTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            switch selectedTab {
            case .usage:
                HelpContentView()
            case .background:
                HelpBackgroundView()
            }
        }
    }
}

// SwiftUI content for the help window
struct HelpContentView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(spacing: 4) {
                    Text("AstroBlinkV2")
                        .font(.system(size: 28, weight: .bold))
                    Text("Fast Visual Culling for Astrophotography Sessions")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text("Enhanced and Inspired by PixInsight's Blink Tool")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .italic()
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                Divider()

                // How to Work with AstroBlinkV2 — shown first so users see workflow immediately
                sectionHeader("How to Use AstroBlinkV2")

                Text("Open a folder with your FITS or XISF subs and blink through them using the arrow keys — fast key repeat lets you scan hundreds of frames in seconds. When you spot a bad sub (clouds, tracking errors, planes), hit Space to mark it for deletion. Use K to skip over already-marked frames so you can focus on the remaining candidates. When you're done, press Cmd+⌫ to move all marked files into a PRE-DELETE subfolder — nothing is ever permanently deleted, so you can always recover. Check the Session Overview for a quick integration summary and copy the Fact Sheet for your Astrobin or social media post. Have fun and clear skies!")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Keyboard Shortcuts
                sectionHeader("Keyboard Shortcuts")

                shortcutRow("←  →", "Navigate previous / next image")
                shortcutRow("Page Up / Home", "Jump to first image")
                shortcutRow("Page Down / End", "Jump to last image")
                shortcutRow("Space", "Toggle pre-delete mark (single or multi-selection)")
                shortcutRow("Cmd + ⌫", "Move marked files to PRE-DELETE folder")
                shortcutRow("Cmd + M", "Move marked files to a chosen folder")
                shortcutRow("Cmd + Z", "Undo last pre-delete operation")
                shortcutRow("K", "Toggle skip-marked: arrow keys skip over marked images")
                shortcutRow("H", "Cycle view: all → hide marked → only marked → all")
                shortcutRow("I", "Toggle FITS/XISF header inspector (floating window)")
                shortcutRow("S", "Toggle Lock STF (freeze stretch params from current image)")
                shortcutRow("D", "Toggle debayer for OSC (one-shot-color) images")
                shortcutRow("N", "Toggle night mode (red-on-black for dark-adapted vision)")
                shortcutRow("C", "Compare with Best — side-by-side with best frame in group")
                shortcutRow("Double-click row", "Open image in floating preview with stretch/denoise/deconv")
                shortcutRow("Cmd + O", "Open folder containing FITS/XISF images")

                Divider()

                // Zoom & Navigation
                sectionHeader("Zoom & Pan")

                featureRow("Click + drag right", "Zoom in (Photoshop-style)")
                featureRow("Click + drag left", "Zoom out")
                featureRow("Double-click image", "Reset to fit-to-view")
                featureRow("Trackpad pinch", "Zoom in/out")
                featureRow("Scroll wheel", "Pan when zoomed in")

                Divider()

                // STF Stretch
                sectionHeader("STF Auto-Stretch")

                Text("PixInsight-compatible Screen Transfer Function makes raw linear data visible.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                featureRow("Stretch slider", "STF target background (0–50%, default 25%)")
                featureRow("Sharpening slider", "GPU unsharp mask (-2 blur to +2 sharpen)")
                featureRow("Contrast slider", "S-curve contrast adjustment (-1 to +1)")
                featureRow("Dark Level slider", "Shadows clip threshold (0 to 0.5)")
                featureRow("Lock STF (S)", "Freeze exact stretch from current image for all — compare brightness")
                featureRow("Apply All", "Toggle: bake current settings into all cached previews for fast navigation")
                featureRow("Reset ↺", "Reset all sliders and toggles to defaults")
                Text("Sliders update the current image live. Lock STF freezes the exact c0/mb stretch params for brightness comparison. Apply All re-caches all images with your current slider settings.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()

                Divider()

                // Debayer (OSC)
                sectionHeader("OSC Debayer")

                Text("One-shot-color (OSC) cameras capture raw Bayer-pattern data. When OSC images are detected (via BAYERPAT header), a debayer toggle appears in the toolbar.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                featureRow("Debayer OFF (default)", "Fastest caching — images shown as grayscale")
                featureRow("Debayer ON (press D)", "Bayer interpolation to RGB — slower caching but color preview")
                Text("Toggle only appears when session contains OSC images.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()

                Divider()

                // Night Mode
                sectionHeader("Night Mode")

                featureRow("Press N", "Toggle black background + red UI for dark-adapted vision")
                Text("All UI elements switch to red-on-black to preserve night vision at the telescope.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()

                Divider()

                // File List
                sectionHeader("File List & Sorting")

                featureRow("Click column header", "Sort by that column (toggle asc/desc)")
                featureRow("Drag column to reorder", "Column order = sort priority (left to right)")
                featureRow("Shift/Cmd + click rows", "Multi-select for bulk marking")
                featureRow("Checkbox / Space", "Mark files for pre-deletion")
                featureRow("Right-click row", "Copy, Show in Finder, Open With..., Compare with Best")
                featureRow("Double-click row", "Open image preview with stretch/denoise/deconv controls")
                featureRow("Metric bars", "Tiny colored bars below Stars/FWHM/HFR/SNR values show relative ranking within group")

                Divider()

                // Triage Workflow
                sectionHeader("Triage Workflow")

                featureRow("Space — Mark/Unmark", "Toggle pre-delete mark on selected images")
                featureRow("Cmd+⌫ — Move to PRE-DELETE", "Move all marked files to PRE-DELETE folder")
                featureRow("Cmd+M — Move to folder", "Move marked files to any folder (create or select)")
                featureRow("Cmd+Z — Undo", "Undo last move operation (PRE-DELETE or Cmd+M)")
                featureRow("K — Skip marked", "Arrow keys skip over marked images during blinking")
                featureRow("H — Cycle view", "All files → hide marked → show only marked → all")
                featureRow("Session Overview", "Floating window with per-filter statistics + forum copy")

                Text("Files are never permanently deleted. All move operations support full undo.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()

                Divider()

                sectionHeader("Search & Filter")

                Text("The search field in the toolbar filters the file list in real time. Type any text to search across all columns, or use column:value syntax for targeted filtering.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                featureRow("Plain text", "Searches filename, object, filter, camera, and all other columns")
                featureRow("file:xyz", "Search filename only (e.g. file:Veil, file:bias)")
                featureRow("filter:Ha", "Search by filter name (also: fil:Ha)")
                featureRow("object:M42", "Search by target/object name (also: obj:M42)")
                featureRow("type:LIGHT", "Search by frame type (LIGHT, FLAT, DARK, BIAS)")
                featureRow("fwhm:>4", "Numeric filter with operators: >, <, >=, <=")
                featureRow("stars:<500", "Find images with fewer than 500 detected stars")
                featureRow("exp:300", "Find images with specific exposure time")
                featureRow("Mark / Unmark buttons", "Mark or unmark all filtered images at once")
                Text("After filtering, use Mark to checkmark all matches, then Cmd+M to move them or Cmd+⌫ for pre-delete.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()

                Divider()

                // Supported Formats
                sectionHeader("Supported Formats")

                featureRow("XISF", "Uncompressed, LZ4, LZ4HC, zlib, ByteShuffle")
                featureRow("FITS", "Uncompressed, fpack (Rice, GZIP)")
                Text("Metadata parsed from NINA filenames and FITS/XISF headers.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Divider()

                // Network
                sectionHeader("Network Volumes")

                Text("Images from network drives (NAS, SMB) are automatically downloaded to a local cache for fast browsing. A progress indicator shows download status.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Divider()

                // Author / Copyright
                VStack(spacing: 4) {
                    Text("by joergsflow")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)

                    Text("joergsflow@gmail.com")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack(spacing: 16) {
                        Link("GitHub", destination: URL(string: "https://github.com/joergs-git/AstroBlinkV2")!)
                            .font(.system(size: 11))
                        Link("Instagram", destination: URL(string: "https://www.instagram.com/joergsflow/")!)
                            .font(.system(size: 11))
                        Link("Astrobin", destination: URL(string: "https://app.astrobin.com/u/joergsflow#gallery")!)
                            .font(.system(size: 11))
                    }

                    Text("© 2026 joergsflow. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

                Spacer(minLength: 16)
            }
            .padding(24)
            .textSelection(.enabled)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 120, alignment: .trailing)
                .foregroundColor(.accentColor)
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
    }

    private func featureRow(_ feature: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(feature)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 160, alignment: .trailing)
                .foregroundColor(.primary)
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Background Tab (How & Why)

struct HelpBackgroundView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 4) {
                    Text("Background & FAQ")
                        .font(.system(size: 28, weight: .bold))
                    Text("How things work and why they matter")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                Divider()

                // Quality Scoring
                faqSection("Quality Scoring — The 4-Tier System",
                    """
                    AstroBlinkV2 automatically scores every image relative to its group (same target + filter + exposure). \
                    This means a 30s Ha sub is only compared to other 30s Ha subs — never to 180s Luminance frames.

                    The scoring uses two stages:
                    """)

                faqItem("Stage 1 — Garbage Detection",
                    """
                    Before any statistics, obvious failures are flagged red immediately. If any single metric \
                    drops below 50% of the group median, the image is garbage — regardless of how the other \
                    metrics look. For example: 200 stars when the group median is 4000 means something went \
                    very wrong (clouds, tracking failure, dew).
                    """)

                faqItem("Stage 2 — Relative Ranking",
                    """
                    Images that pass Stage 1 are ranked by a weighted z-score combining multiple metrics. \
                    The z-score tells you how many standard deviations each metric is from the group average.
                    """)

                qualityIconRow("circle.fill", .systemGreen, "Excellent (z > 0.5)",
                    "Best frames — clearly above average in the combined score. Keep these.")
                qualityIconRow("circle.lefthalf.filled", .systemGreen, "Good (-0.3 to 0.5)",
                    "Solid frames — near average. Definitely usable, keep unless you have plenty.")
                qualityIconRow("exclamationmark.circle", .systemOrange, "Borderline (-1.2 to -0.3)",
                    "Below average — worth a quick visual check. May still be usable.")
                qualityIconRow("xmark.circle.fill", .systemRed, "Trash (< -1.2 or Stage 1)",
                    "Either catastrophically bad (Stage 1) or statistically worst in group.")

                Text("Hover over any quality icon to see its exact z-score for fine-grained comparison.")
                    .font(.system(size: 11)).foregroundColor(.secondary).italic()

                Divider()

                // Metric Bars
                faqSection("Metric Bar Indicators",
                    """
                    The tiny colored bars below Stars, FWHM, HFR, and SNR values show at a glance how each \
                    image ranks within its group. Longer bar = better. Color goes from red (worst) through \
                    orange to green (best).
                    """)

                faqItem("Why per-group?",
                    """
                    Bars are scoped to each target + filter + exposure group. Ha images typically have \
                    fewer stars than Luminance — comparing them globally would make all Ha bars tiny red. \
                    Per-group bars show you the relative ranking within apples-to-apples comparisons.
                    """)

                Divider()

                // What the metrics mean
                faqSection("Understanding the Metrics",
                    """
                    Each metric captures a different aspect of image quality. Together they paint a complete \
                    picture of whether a sub is worth stacking.
                    """)

                faqItem("Stars — How many stars were detected",
                    """
                    The total star count from GPU detection. Fewer stars than usual often indicates clouds, \
                    fog, high humidity, or tracking issues that smeared stars below the detection threshold. \
                    A sudden drop in star count is the most reliable single indicator of a problem. \
                    Weight in quality score: 1.2x (slightly elevated).
                    """)

                faqItem("FWHM — Full Width at Half Maximum",
                    """
                    Measures how wide star profiles are (in pixels). Lower FWHM = sharper stars = better seeing \
                    and focus. FWHM is affected by atmospheric turbulence (seeing), focus accuracy, and tracking. \
                    Measured from the center 70% of the image to exclude edge optical effects (coma, tilt). \
                    Sorted ascending by default (lowest = best first).
                    """)

                faqItem("HFR — Half-Flux Radius",
                    """
                    Similar to FWHM but measures the radius containing half the total flux of a star. \
                    More robust against non-Gaussian star profiles. Lower = tighter stars = better focus. \
                    Also measured from center 70% crop. HFR from NINA filename tokens or CSV takes priority \
                    over GPU-computed values for consistency.
                    """)

                faqItem("SNR — Signal-to-Noise Ratio",
                    """
                    Computed as median pixel value / noise (MAD). Higher SNR = cleaner signal. \
                    Low SNR frames have more noise scatter — caused by clouds, light pollution, \
                    short exposures, or high ambient temperature increasing sensor noise. \
                    Measured from center 70% crop to avoid edge vignetting effects.
                    """)

                faqItem("How they relate",
                    """
                    A good sub has: many stars (clear sky), low FWHM (good seeing/focus), \
                    low HFR (tight stars), and high SNR (clean signal). If stars are low but FWHM is fine, \
                    it's probably thin clouds. If FWHM is high but stars are normal, it's likely poor seeing \
                    or focus drift. If SNR drops while stars and FWHM stay normal, it could be increasing \
                    light pollution or dew forming on the optics.
                    """)

                Divider()

                // Smart Column Sorting
                faqSection("Smart Column Sorting",
                    """
                    When you open a session, AstroBlinkV2 detects the session type and automatically sorts \
                    the file list for optimal triage. The sort fires once after the initial precache completes \
                    (when all quality scores are available).
                    """)

                faqItem("Case A: Single Target, Multiple Filters",
                    """
                    Most common setup (e.g. NGC 2024 with L, R, G, B, Ha). \
                    Sort: Filter → Exposure → Quality → Stars → FWHM. \
                    Groups all L subs together sorted by quality, then all Ha subs, etc. \
                    This lets you quickly mark the worst subs in each filter.
                    """)

                faqItem("Case B: Single Target, Single Filter",
                    """
                    Pure integration run (e.g. 90x 180s Luminance on M31). \
                    Sort: Exposure → Quality → Stars → FWHM → HFR. \
                    Since all images are the same filter, quality is the primary differentiator. \
                    Best subs at top, worst at bottom.
                    """)

                faqItem("Case C: Multiple Targets, Multiple Filters",
                    """
                    Mosaic or multi-target session (e.g. NGC 2024 LRGB + M42 Ha/OIII). \
                    Sort: Target → Filter → Exposure → Quality → Stars. \
                    Groups by object first, then filter within each object.
                    """)

                faqItem("Case D: Multiple Targets, Single Filter",
                    """
                    Survey session (e.g. many targets all in Luminance). \
                    Sort: Target → Exposure → Quality → Stars → FWHM. \
                    Groups by target, quality ranking within each.
                    """)

                Divider()

                // STF Stretching
                faqSection("STF Auto-Stretch — How It Works",
                    """
                    Raw astro data is linear — all detail is crammed into the bottom 1% of the brightness \
                    range, making images appear nearly black. The Screen Transfer Function (STF) applies a \
                    non-linear stretch to make detail visible without modifying the original file.
                    """)

                faqItem("The Algorithm",
                    """
                    Based on PixInsight's AutoSTF by Juan Conejero. For each channel: \
                    (1) Subsample 5% of pixels for statistics. \
                    (2) Compute median and MAD (median absolute deviation). \
                    (3) Shadow clip: c0 = median + (-1.25) × MAD. \
                    (4) Midtone balance: mb computed from target background level (default 25%). \
                    (5) Apply Midtones Transfer Function per pixel on GPU. \
                    Entire process takes < 8ms on Apple Silicon for a 50MP image.
                    """)

                faqItem("Per-Channel (Unlinked) Stretch",
                    """
                    For color (OSC) images, each R/G/B channel gets independent c0 and mb values. \
                    This compensates for the Bayer pattern's green bias (2x green pixels) and produces \
                    neutral-looking previews. The Linked toggle applies identical stretch to all channels, \
                    which preserves raw color ratios but may show a green cast.
                    """)

                Divider()

                // Debayering
                faqSection("OSC Debayering",
                    """
                    One-shot-color cameras use a Bayer color filter array (CFA) where each pixel only \
                    captures one color (R, G, or B). Debayering interpolates the missing colors to produce \
                    a full RGB image. AstroBlinkV2 uses GPU-accelerated bilinear interpolation.
                    """)

                faqItem("When to use debayer",
                    """
                    Toggle debayer ON (D key) when you want to see color previews of OSC data. \
                    Leave it OFF for faster caching when you only need to check star quality and tracking. \
                    Debayer state is remembered across sessions.
                    """)

                Divider()

                // Image Preview & Post-Processing
                faqSection("Image Preview & Post-Processing",
                    """
                    Double-click any image to open it in a floating window with real-time GPU controls:
                    """)

                faqItem("Denoise (0–200%)",
                    """
                    Two-pass GPU noise reduction. Pass 1: bilateral filter preserves edges while smoothing \
                    pixel noise. Pass 2: chrominance denoise in YCbCr color space removes green/magenta \
                    color patches without affecting luminance detail.
                    """)

                faqItem("Deconvolution (USM / RL)",
                    """
                    USM: Multi-scale unsharp mask at 3 spatial scales (1.5, 3.0, 5.0 pixel radii). \
                    Fast (~15ms) but approximate. \
                    RL: Richardson-Lucy iterative deconvolution with Gaussian PSF. True maximum-likelihood \
                    deconvolution, 5–20 iterations. Better quality, slower (~30–60ms). \
                    Both operate on luminance only to prevent color fringing.
                    """)

                faqItem("Compare with Best (C key)",
                    """
                    Opens a side-by-side comparison window showing the best-quality frame from the same \
                    group (target + filter + exposure) next to the selected frame. Zoom and pan are \
                    synchronized — drag in one image to zoom, both follow. Opens at 300% zoom for \
                    immediate detail inspection. Press ESC to close.
                    """)

                Divider()

                // Stacking
                faqSection("Quick Stack & LightspeedStacker",
                    """
                    Built-in GPU-accelerated stacking for quick preview of your integration result. \
                    Not a replacement for dedicated stacking software, but useful for checking session \
                    quality and sharing quick previews. Includes hot/cold pixel rejection before stacking.
                    """)

                Divider()

                // Tips
                faqSection("Tips for Efficient Triage",
                    """
                    1. Open folder → wait for precache to complete (quality scores appear). \
                    2. Scroll through the sorted list — red/orange icons at top need attention. \
                    3. Press C on borderline images to compare with the group's best. \
                    4. Space to mark bad ones, then Cmd+⌫ to move to PRE-DELETE. \
                    5. Use filter search (e.g. filter:Ha) to focus on one filter at a time. \
                    6. Check the Session Overview for per-filter integration totals.
                    """)

                Divider()

                VStack(spacing: 4) {
                    Text("by joergsflow")
                        .font(.system(size: 12, weight: .medium))
                    Text("© 2026 joergsflow. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

                Spacer(minLength: 16)
            }
            .padding(24)
            .textSelection(.enabled)
        }
    }

    private func faqSection(_ title: String, _ intro: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(intro)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func faqItem(_ question: String, _ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor)
            Text(answer)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
    }

    private func qualityIconRow(_ symbol: String, _ color: NSColor, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(Color(color))
                .font(.system(size: 14))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 12)
    }
}
