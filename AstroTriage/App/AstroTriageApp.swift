// v2.2.0
import SwiftUI

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

            // Help menu
            CommandGroup(replacing: .help) {
                Button("AstroBlinkV2 Help") {
                    HelpWindowController.shared.showWindow(nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

// Custom app delegate for About panel and cleanup
class AstroBlinkV2AppDelegate: NSObject, NSApplicationDelegate {

    // Clean up all caches when the app quits so nothing piles up on disk
    func applicationWillTerminate(_ notification: Notification) {
        SessionCache.cleanupAllCaches()
    }

    // Click monitor for dismissing splash screen
    private var splashClickMonitor: Any?

    // Show splash screen (about panel) briefly on launch
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Small delay so the main window appears first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AstroBlinkV2AppDelegate.showAboutPanel()

            // Dismiss on any mouse click or key press anywhere
            self.splashClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                self?.dismissSplash()
                return event
            }

            // Auto-dismiss after 4 seconds if no interaction
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.dismissSplash()
            }
        }
    }

    private func dismissSplash() {
        // Remove click monitor
        if let monitor = splashClickMonitor {
            NSEvent.removeMonitor(monitor)
            splashClickMonitor = nil
        }
        // Close the about panel if it's still showing
        for window in NSApp.windows where window.title == "About AstroBlinkV2" {
            window.close()
        }
    }

    static func showAboutPanel() {
        let credits = NSMutableAttributedString()

        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand
        ]

        credits.append(NSAttributedString(string: "by joergsflow\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]))
        credits.append(NSAttributedString(string: "joergsflow@gmail.com\n\n", attributes: normalAttrs))

        let githubLink = NSMutableAttributedString(string: "GitHub", attributes: linkAttrs)
        githubLink.addAttribute(.link, value: URL(string: "https://github.com/joergs-git/AstroBlinkV2")!, range: NSRange(location: 0, length: githubLink.length))
        credits.append(githubLink)
        credits.append(NSAttributedString(string: "  ·  ", attributes: normalAttrs))

        let instaLink = NSMutableAttributedString(string: "Instagram", attributes: linkAttrs)
        instaLink.addAttribute(.link, value: URL(string: "https://www.instagram.com/joergsflow/")!, range: NSRange(location: 0, length: instaLink.length))
        credits.append(instaLink)
        credits.append(NSAttributedString(string: "  ·  ", attributes: normalAttrs))

        let astrobinLink = NSMutableAttributedString(string: "Astrobin", attributes: linkAttrs)
        astrobinLink.addAttribute(.link, value: URL(string: "https://app.astrobin.com/u/joergsflow#gallery")!, range: NSRange(location: 0, length: astrobinLink.length))
        credits.append(astrobinLink)

        let italicDescriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body).withSymbolicTraits(.italic)
        let italicFont = NSFont(descriptor: italicDescriptor, size: 10) ?? NSFont.systemFont(ofSize: 10)
        credits.append(NSAttributedString(string: "\n\nEnhanced and Inspired by PixInsight's Blink Tool", attributes: [
            .font: italicFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        // Center all text
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: credits.length))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "AstroBlinkV2",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            .version: "Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")",
            .credits: credits
        ])
    }
}

// Notifications for menu bar actions
extension Notification.Name {
    static let openFolderRequest = Notification.Name("openFolderRequest")
    static let resetSettingsRequest = Notification.Name("resetSettingsRequest")
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        window.title = "AstroBlinkV2 v\(appVersion) — Quick Reference"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let hostingView = NSHostingView(rootView: HelpContentView())
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
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
                shortcutRow("Cmd + Z", "Undo last pre-delete operation")
                shortcutRow("K", "Toggle skip-marked: arrow keys skip over marked images")
                shortcutRow("H", "Toggle hide-marked: hide marked images from the list")
                shortcutRow("I", "Toggle FITS/XISF header inspector (floating window)")
                shortcutRow("S", "Toggle Lock STF (freeze stretch params from current image)")
                shortcutRow("D", "Toggle debayer for OSC (one-shot-color) images")
                shortcutRow("N", "Toggle night mode (red-on-black for dark-adapted vision)")
                shortcutRow("Double-click", "Reset zoom to fit-to-view")
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
                featureRow("Right-click row", "Copy filename, path, or full path")

                Divider()

                // Triage Workflow
                sectionHeader("Triage Workflow")

                featureRow("Space — Mark/Unmark", "Toggle pre-delete mark on selected images")
                featureRow("Cmd+⌫ — Move to PRE-DELETE", "Move all marked files to PRE-DELETE folder")
                featureRow("K — Skip marked", "Arrow keys skip over marked images during blinking")
                featureRow("H — Hide marked", "Completely hide marked images from the file list")
                featureRow("Session Overview", "Floating window with per-filter statistics + forum copy")
                featureRow("Filter statistics", "Bottom bar shows per-filter count and total exposure")

                Text("Files are never permanently deleted. Marked files are moved to a PRE-DELETE subfolder for manual review.")
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
