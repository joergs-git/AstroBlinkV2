// v4.0.0
import SwiftUI

// MARK: - App Store URL (update when published)
let appStoreURL = "https://apps.apple.com/app/astroblinkv2/id6760241266?mt=12"

// Singleton handler registered before SwiftUI takes over the event pipeline
class URLSchemeHandler: NSObject {
    static let shared = URLSchemeHandler()
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "astroblink",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "open",
              let folderPath = components.queryItems?.first(where: { $0.name == "folder" })?.value else { return }
        let folderURL = URL(fileURLWithPath: folderPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NotificationCenter.default.post(name: .openFolderAtPath, object: folderURL)
        }
    }
}

@main
struct AstroBlinkV2App: App {
    // Use NSApplicationDelegateAdaptor so we can customize the About panel
    @NSApplicationDelegateAdaptor(AstroBlinkV2AppDelegate.self) var appDelegate

    init() {
        // Make stdout line-buffered so print() output is visible live when redirected
        // to a file (debug runs). Default block-buffering hides log output until exit.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Register URL scheme handler BEFORE SwiftUI steals the event pipeline
        NSAppleEventManager.shared().setEventHandler(
            URLSchemeHandler.shared,
            andSelector: #selector(URLSchemeHandler.handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            // Replace default About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About AstroBlink & AIsaac") {
                    AstroBlinkV2AppDelegate.showAboutPanel()
                }
            }

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .openFolderRequest, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Open Database Directory") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let dbDir = appSupport.appendingPathComponent("AstroBlinkV2", isDirectory: true)
                    NSWorkspace.shared.open(dbDir)
                }

                Button("Open iCloud Directory") {
                    if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.joergsflow.AstroBlinkV2") {
                        let docsURL = iCloudURL.appendingPathComponent("Documents", isDirectory: true)
                        NSWorkspace.shared.open(docsURL)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "iCloud Not Available"
                        alert.informativeText = "iCloud Drive is not enabled for this app, or you are not signed in to iCloud."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }

            // View menu: Zoom + Font size + Columns visibility + Reset Settings
            CommandGroup(after: .toolbar) {
                Button("Zoom In (25%)") {
                    NotificationCenter.default.post(name: .zoomInStep, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out (25%)") {
                    NotificationCenter.default.post(name: .zoomOutStep, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Fit to View") {
                    NotificationCenter.default.post(name: .zoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Actual Pixels (100%)") {
                    NotificationCenter.default.post(name: .zoomPresetSmall, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Double Size (200%)") {
                    NotificationCenter.default.post(name: .zoomPresetLarge, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button("Show Image Overlay") {
                    NotificationCenter.default.post(name: .toggleViewerOverlay, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Increase Font Size") {
                    NotificationCenter.default.post(name: .fontScaleIncrease, object: nil)
                }

                Button("Decrease Font Size") {
                    NotificationCenter.default.post(name: .fontScaleDecrease, object: nil)
                }

                Button("Reset Font Size") {
                    NotificationCenter.default.post(name: .fontScaleReset, object: nil)
                }

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

            // Window menu: Benchmark Stats + Target Catalog
            CommandGroup(after: .windowList) {
                Button("Benchmark Stats") {
                    NotificationCenter.default.post(name: .showBenchmarkStats, object: nil)
                }
                Button("Target Catalog") {
                    NotificationCenter.default.post(name: .showTargetDatabase, object: nil)
                }
            }

            // Advanced menu (safety net for Frame History Database)
            CommandGroup(after: .windowList) {
                Divider()
                Menu("Advanced") {
                    Button("Toggle Blind Curation") {
                        NotificationCenter.default.post(name: .toggleBlindCuration, object: nil)
                    }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button("Sync Curated Dataset to Supabase...") {
                        NotificationCenter.default.post(name: .syncCuratedToSupabase, object: nil)
                    }
                    Button("Export Curated Dataset to File...") {
                        NotificationCenter.default.post(name: .exportCuratedDataset, object: nil)
                    }
                    Divider()
                    Button("Reset Frame History Database...") {
                        NotificationCenter.default.post(name: .resetFrameHistory, object: nil)
                    }
                    Divider()
                    Menu("AIsaac Profile") {
                        Button("Export Profile (JSON)...") {
                            exportAIsaacProfile()
                        }
                        Button("Delete Profile...") {
                            deleteAIsaacProfile()
                        }
                    }
                    Divider()
                    Button("Destroy All DB Data...") {
                        NotificationCenter.default.post(name: .destroyAllData, object: nil)
                    }
                }
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button("AstroBlink Help") {
                    HelpWindowController.shared.showWindow(nil)
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Button("What's New") {
                    ReleaseNotesWindowController.shared.show()
                }
            }
        }
    }
}

// MARK: - AIsaac Profile Menu Helpers

/// Export the current AIsaac profile JSON to a user-chosen location.
/// Reaches the file via AIsaacUserProfile.load() so we don't need a reference
/// to the in-memory copy held by AIsaacContextBuilder.
@MainActor
private func exportAIsaacProfile() {
    let panel = NSSavePanel()
    panel.title = "Export AIsaac Profile"
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "aisaac_profile.json"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try AIsaacUserProfile.load().exportTo(url)
    } catch {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Delete the local + iCloud copies of the AIsaac profile after explicit
/// user confirmation. The next AIsaac query starts from a fresh blank profile.
@MainActor
private func deleteAIsaacProfile() {
    let alert = NSAlert()
    alert.messageText = "Delete AIsaac profile?"
    alert.informativeText = "Removes the local profile in Application Support and the iCloud copy. Equipment, filters and imaging history kept in the profile will be cleared. This does not affect Frame History or your local image files."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    AIsaacUserProfile.delete()
}

// Custom app delegate for About panel and cleanup
class AstroBlinkV2AppDelegate: NSObject, NSApplicationDelegate {

    // Quit the app when the main window is closed (single-window app)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Handle astroblink:// URL scheme via Apple Events (most reliable on macOS)
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue

        guard let urlString, let url = URL(string: urlString),
              url.scheme == "astroblink" else { return }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.host == "open",
           let folderPath = components.queryItems?.first(where: { $0.name == "folder" })?.value {
            let folderURL = URL(fileURLWithPath: folderPath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NotificationCenter.default.post(name: .openFolderAtPath, object: folderURL)
            }
        }
    }

    // PI handoff: timer checks clipboard for ASTROBLINK_PI_OPEN: marker.
    // Uses @objc selector + strong target reference — guaranteed to fire on main RunLoop.
    @objc private func checkPIClipboard() {
        guard let content = NSPasteboard.general.string(forType: .string),
              content.hasPrefix("ASTROBLINK_PI_OPEN:") else { return }
        let folderPath = String(content.dropFirst("ASTROBLINK_PI_OPEN:".count))
        NSPasteboard.general.clearContents()
        guard !folderPath.isEmpty, FileManager.default.fileExists(atPath: folderPath) else { return }
        NotificationCenter.default.post(name: .openFolderAtPath, object: URL(fileURLWithPath: folderPath))
    }

    // Clean up caches and ensure iCloud has latest data before quitting
    func applicationWillTerminate(_ notification: Notification) {
        // Export Frame History to iCloud so other Macs get the latest data
        FrameHistoryDatabase.shared.exportToICloud()
        SessionCache.cleanupAllCaches()
    }

    // Show splash screen on launch (unless user opted out)
    func applicationDidFinishLaunching(_ notification: Notification) {
        // PI handoff: check clipboard every 2s for ASTROBLINK_PI_OPEN: marker
        // (delayed start to ensure RunLoop is running)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            Timer.scheduledTimer(timeInterval: 2.0, target: self,
                                 selector: #selector(self.checkPIClipboard),
                                 userInfo: nil, repeats: true)
        }

        // Skip heavy init when running as test host
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        // Register defaults (community learning on for new installs) + start iCloud sync
        if !isTestHost {
            AppSettings.registerDefaults()
            AppSettings.startCloudSync()
        }

        // Initialize Frame History database (local SQLite only — instant)
        if !isTestHost {
            _ = FrameHistoryDatabase.shared
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if AppSettings.loadBool(for: .hideSplash) != true {
                AboutWindowController.shared.showOnboarding()
            }
        }

        // Check for incomplete archive scans (deferred to after window is ready)
        if !isTestHost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.checkIncompleteArchiveScans()
            }
        }

        // Check for in-app messages (deferred to after main window is rendered)
        if !isTestHost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.triggerMessageCheck()
            }
        }

        // Anonymous app start telemetry (fire-and-forget, never blocks)
        if !isTestHost {
            AppMessageService.recordAppStart()
        }

        // Show AIsaac floating window collapsed (preset chips visible on startup)
        if !isTestHost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AIsaacWindowController.shared.ensureVisible()
            }
        }

        // Check iCloud for newer Frame History DB (waits for iCloud resolution, no fixed timer)
        if !isTestHost {
            FrameHistoryDatabase.shared.onICloudResolved { [weak self] _ in
                self?.checkFrameHistoryICloudSync()
            }
        }
    }

    /// Trigger in-app message check on the TriageViewModel that owns the ContentView.
    private func triggerMessageCheck() {
        // Post notification — ContentView's viewModel picks it up
        NotificationCenter.default.post(name: .checkAppMessages, object: nil)
    }

    /// Check iCloud for a newer/different Frame History database and prompt user.
    private func checkFrameHistoryICloudSync() {
        FrameHistoryDatabase.shared.checkICloudForNewerDBAsync { [weak self] result in
            guard let (localMeta, iCloudMeta) = result else { return }
            self?.showICloudSyncAlert(localMeta: localMeta, iCloudMeta: iCloudMeta)
        }
    }

    private func showICloudSyncAlert(localMeta: FrameHistoryMeta, iCloudMeta: FrameHistoryMeta) {
        // Format file sizes
        let localMB = String(format: "%.1f MB", Double(localMeta.dbSizeBytes) / (1024 * 1024))
        let iCloudMB = String(format: "%.1f MB", Double(iCloudMeta.dbSizeBytes) / (1024 * 1024))

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Frame History Database Sync"

        // Safety: warn if local is larger
        let localIsLarger = localMeta.frameCount > iCloudMeta.frameCount

        var infoText = "Your local and iCloud databases differ:\n\n"
        infoText += "Local: \(localMeta.frameCount) frames (\(localMB))\n"
        infoText += "iCloud: \(iCloudMeta.frameCount) frames (\(iCloudMB))\n"

        if localIsLarger {
            infoText += "\nYour local database has more frames than iCloud.\nDownloading would lose local data."
        }

        alert.informativeText = infoText

        if localIsLarger {
            // Default to Keep Local when local is larger
            alert.addButton(withTitle: "Keep Local")
            alert.addButton(withTitle: "Use iCloud")
            alert.addButton(withTitle: "Cancel")
        } else {
            // Default to Use iCloud when iCloud is larger
            alert.addButton(withTitle: "Use iCloud")
            alert.addButton(withTitle: "Keep Local")
            alert.addButton(withTitle: "Cancel")
        }

        let response = alert.runModal()
        let useICloud = localIsLarger
            ? (response == .alertSecondButtonReturn)
            : (response == .alertFirstButtonReturn)

        if useICloud {
            FrameHistoryDatabase.shared.importFromICloudAsync { result in
                switch result {
                case .success(let count):
                    print("FrameHistory: imported \(count) frames from iCloud")
                case .failure(let error):
                    let errorAlert = NSAlert()
                    errorAlert.alertStyle = .warning
                    errorAlert.messageText = "iCloud Import Failed"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.runModal()
                }
            }
        }
    }

    static func showAboutPanel() {
        AboutWindowController.shared.showOnboarding()
    }

    /// Check for incomplete archive scans and offer to resume.
    private func checkIncompleteArchiveScans() {
        let incomplete = ArchiveScanner.incompleteScanPaths()
        guard let scan = incomplete.first else { return }

        // Check if the root path is still accessible
        guard FileManager.default.fileExists(atPath: scan.rootPath) else { return }

        let folderName = URL(fileURLWithPath: scan.rootPath).lastPathComponent
        let percent = scan.total > 0 ? Int(Double(scan.processed) / Double(scan.total) * 100) : 0

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Resume Archive Scan?"
        alert.informativeText = """
            Previous scan of "\(folderName)" stopped at \(scan.processed)/\(scan.total) files (\(percent)%).
            Last updated: \(scan.lastUpdated.prefix(16))

            Resume scanning from where it stopped?
            """
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Discard")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Resume — open History window and start scan
            FrameHistoryController.shared.showWindow()
            ArchiveScanner.shared.resumeScan(rootPath: scan.rootPath)
        case .alertThirdButtonReturn:
            // Discard — mark as complete to stop asking
            let progress = ScanProgress(
                rootPath: scan.rootPath,
                lastScannedPath: nil,
                totalFound: scan.total,
                totalProcessed: scan.processed,
                startedAt: scan.lastUpdated,
                lastUpdatedAt: ISO8601DateFormatter().string(from: Date()),
                isComplete: 1
            )
            try? FrameHistoryDatabase.shared.saveScanProgress(progress)
        default:
            break  // "Later" — do nothing, ask again next launch
        }
    }
}


// Notifications for menu bar actions
extension Notification.Name {
    static let openFolderRequest = Notification.Name("openFolderRequest")
    static let resetSettingsRequest = Notification.Name("resetSettingsRequest")
    static let showBenchmarkStats = Notification.Name("showBenchmarkStats")
    static let showBatchRename = Notification.Name("showBatchRename")
    static let showAIsaac = Notification.Name("showAIsaac")
    static let askAIsaacAboutQuality = Notification.Name("askAIsaacAboutQuality")
    static let fontScaleIncrease = Notification.Name("fontScaleIncrease")
    static let fontScaleDecrease = Notification.Name("fontScaleDecrease")
    static let fontScaleReset = Notification.Name("fontScaleReset")
    static let resetFrameHistory = Notification.Name("resetFrameHistory")
    static let destroyAllData = Notification.Name("destroyAllData")
    static let toggleBlindCuration = Notification.Name("toggleBlindCuration")
    static let toggleViewerOverlay = Notification.Name("toggleViewerOverlay")
    static let exportCuratedDataset = Notification.Name("exportCuratedDataset")
    static let syncCuratedToSupabase = Notification.Name("syncCuratedToSupabase")
    static let checkAppMessages = Notification.Name("checkAppMessages")
    static let frameHistoryDidImport = Notification.Name("frameHistoryDidImport")
    static let zoomInStep = Notification.Name("zoomInStep")
    static let zoomOutStep = Notification.Name("zoomOutStep")
    static let zoomReset = Notification.Name("zoomReset")
    static let zoomPresetSmall = Notification.Name("zoomPresetSmall")
    static let zoomPresetLarge = Notification.Name("zoomPresetLarge")
    static let openFolderAtPath = Notification.Name("openFolderAtPath")  // URL scheme: astroblink://open?folder=...
    static let showTargetDatabase = Notification.Name("showTargetDatabase")
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
        window.title = "AstroBlink v\(appVersion) — Help"
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
                    Text("AstroBlink & AIsaac")
                        .font(.system(size: 28, weight: .bold))
                    Text("Fast Visual Culling & AI-Powered Session Analysis")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text("Inspired by PixInsight's Blink & SubframeSelector")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .italic()
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                Divider()

                // How to Work with AstroBlink — shown first so users see workflow immediately
                sectionHeader("How to Use AstroBlink")

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
                shortcutRow("Cmd + / Cmd -", "Zoom in / out by 25% steps")
                shortcutRow("Cmd + 0", "Fit image to view (reset zoom)")
                shortcutRow("Cmd + 1", "Zoom to 100% (actual pixels)")
                shortcutRow("Cmd + 2", "Zoom to 200%")
                shortcutRow("1 / 2 / 3", "Set confidence rating (1-3 stars, same key clears)")

                Divider()

                // Zoom & Navigation
                sectionHeader("Zoom & Pan")

                featureRow("Click + drag right", "Zoom in (Photoshop-style)")
                featureRow("Click + drag left", "Zoom out")
                featureRow("Double-click image", "Reset to fit-to-view")
                featureRow("Option + drag", "Pan image (hand tool — fast and precise)")
                featureRow("Trackpad pinch", "Zoom in/out")
                featureRow("Scroll wheel", "Pan when zoomed in")
                featureRow("Zoom overlay", "Bottom-right corner shows true pixel zoom %")

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

                // AutoRotate
                sectionHeader("AutoRotate")

                Text("Pixel-locks every frame of a target to a single reference so you can blink through a session without stars visually jumping between frames. Uses the WCS plate-solve data (CD matrix + CRPIX + CRVAL) that ASIAir, NINA and most capture software already write to the FITS/XISF headers. Alignment is mathematically exact via direct matrix algebra — microseconds per frame, regardless of filter, exposure, night, or camera rotator angle.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                featureRow("AutoRotate toggle (toolbar)", "Turn on to align all frames of each target to the smart-picked reference")
                featureRow("Primary path", "WCS plate-solve data (CD matrix) — exact, filter-independent")
                featureRow("Fallback path", "Rotator-based synthetic rotation for frames without plate-solve data")
                featureRow("Reference frame", "Auto-picked: the frame closest to the median pointing of the target group")
                featureRow("Covers", "Meridian flips, dithers, re-centering between nights, polar drift, camera rotation between sessions")
                Text("Blink mode is where it shines — with stars pixel-locked, any tracking errors, focus drift, or trailing pop out immediately as the only things that move.")
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

                sectionHeader("Autopilot Culling")

                Text("Click the culling status indicator in the bottom bar to open the auto-mark menu. Three modes are available:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                featureRow("Conservative (Nebula)", "Only marks trash-tier frames. Maximizes integration time for faint targets.")
                featureRow("Balanced", "Marks trash + worst borderline frames. Good general-purpose choice.")
                featureRow("Aggressive (Stars)", "Marks trash + all borderline. Prioritizes sharpness for star fields and galaxies.")

                Text("Each option shows the frame count and integration time impact before applying. The status bar shows \"Culling complete\" when no more trash frames remain.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Divider()

                sectionHeader("SSWEIGHT Export")

                Text("The SSWEIGHT Export button writes PixInsight-compatible quality weights (0-100) into each FITS/XISF file header. WBPP can use these weights for optimal integration. A CSV backup is also created.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Divider()

                sectionHeader("VLM Check — Visual Anomaly Detection")

                Text("The VLM Check toolbar button generates mosaic wallpapers from your session frames and sends them to Claude Vision AI for visual anomaly detection. It catches problems that metrics alone cannot: ice crystals, dew, clouds, obstructions, focus shifts, and light leaks.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                featureRow("VLM Check button", "Generates mosaic from remaining frames, grouped by target+filter")
                featureRow("Deviation map toggle", "Waveform button shows per-tile deviation from group median")
                featureRow("Click any tile", "Mark/unmark the corresponding frame (blue overlay)")
                featureRow("Anomaly list", "Click any flagged anomaly to jump to that frame in the file list")
                featureRow("Mark Flagged", "Marks all VLM-flagged frames for pre-deletion at once")
                featureRow("Re-Analyze", "Re-runs VLM analysis on current mosaic pages")
                featureRow("Free quota", "10 VLM checks/day via Supabase — unlimited with own Claude API key")
                Text("Satellite trails are handled by the separate trailing metric detector, not VLM. VLM focuses on visual anomalies that are hard to quantify numerically.")
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
                featureRow("rating:1 / rating:2 / rating:3", "Filter by confidence rating")
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
                faqSection("Quality Scoring — The 5-Tier System",
                    """
                    AstroBlink automatically scores every image relative to its group (same target + filter + exposure). \
                    This means a 30s Ha sub is only compared to other 30s Ha subs — never to 180s Luminance frames.

                    The scoring uses a 5-stage pipeline (SmartCull):
                    """)

                faqItem("Stage 1 — Garbage Detection",
                    """
                    Before any statistics, obvious failures are flagged red immediately: star count < 50% \
                    of group median, SNR < 50%, FWHM > 2x median, star trailing (severity-dependent — \
                    escalates from mild to severe regardless of filter), atmospheric attenuation (star count \
                    drop + SNR drop = cloud/dew/fog), or twilight (filter-aware: narrowband tolerates \
                    nautical twilight, broadband does not). Any single catastrophic metric = immediate red.
                    """)

                faqItem("Stage 2 — Relative Ranking",
                    """
                    Images that pass Stage 1 are ranked by a weighted z-score combining PSF Flux / Stars \
                    (1.2x broadband, 0.5x narrowband), FWHM (1.0x), Noise (1.0x), and Trailing \
                    (filter-aware: 0.3x narrowband, 0.6x RGB, 1.0x luminance). PSF Flux replaces star \
                    count when GPU fitting is available. Target-aware weights adjust by object type \
                    (e.g. galaxies boost FWHM weight, nebulae boost noise weight). Z-scores are capped \
                    at ±3.0 to prevent one extreme metric from dominating.
                    """)

                qualityIconRow("circle.fill", .systemGreen, "Excellent (z > 0.5)",
                    "Best frames — clearly above average in the combined score. Keep these.")
                qualityIconRow("circle.lefthalf.filled", .systemGreen, "Good (-0.5 to 0.5)",
                    "Solid frames — near average. Definitely usable, keep unless you have plenty.")
                qualityIconRow("exclamationmark.circle", .systemOrange, "Borderline (-2.0 to -0.5)",
                    "Below average — 4 orange gradient levels from light (nearly good) to deep (nearly trash). Hover for per-metric breakdown and SNR contribution.")
                qualityIconRow("xmark.circle.fill", .systemRed, "Trash (< -2.0 or Stage 1)",
                    "Either catastrophically bad (Stage 1) or statistically worst in group. Hover for reason.")
                qualityIconRow("questionmark.circle", .systemBlue, "Uncertain (small group)",
                    "Group has fewer than 8 frames with ambiguous quality — not enough data for confident ranking.")

                Text("Hover over any quality icon to see per-metric z-scores, SNR contribution %, and a keep/delete recommendation.")
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

                // Eccentricity & SNR Contribution
                faqSection("Star Eccentricity (Ecc)",
                    """
                    Eccentricity measures star shape using 2D image moments (the same method used by \
                    SExtractor and DAOPHOT in professional astronomy). It ranges from 0.0 (perfect circle) \
                    to 1.0 (extreme elongation). Detection is focal-length-adaptive: the expected baseline \
                    eccentricity scales with focal length (short FL / fast optics naturally produce rounder \
                    stars at higher baseline ecc, while long FL / slow optics expect tighter PSFs). \
                    A frame with eccentricity more than 2× the FL baseline is flagged as garbage regardless \
                    of other metrics.
                    """)

                faqItem("Why eccentricity matters most",
                    """
                    Elongated stars are the one defect that stacking cannot fix. Noise, FWHM variations, \
                    and star count differences are all handled by sigma clipping and weighted stacking. \
                    But elongated stars create systematic artifacts that persist in the final stack. \
                    The trailing score (which incorporates eccentricity) uses filter-aware weights: \
                    full strictness for luminance (1.0x), moderate for RGB (0.6x), lenient for narrowband \
                    (0.3x) since diffuse emission targets tolerate slight elongation.
                    """)

                Divider()

                faqSection("SNR Contribution (Contrib)",
                    """
                    Shows how much each frame contributes to a weighted stack relative to the best frame \
                    in its group. Based on the stacking formula: contribution = (SNR_i / SNR_best)^2. \
                    A frame with 70% of the best SNR still contributes 49% to the stack. \
                    Hidden for trash frames (their signal is irrelevant due to fatal flaws).
                    """)

                faqItem("When to keep borderline frames",
                    """
                    Research shows: round stars = always keep. Stacking SNR improves with the square root \
                    of frame count. Removing 20 of 100 frames loses ~11% SNR. Tests by multiple astrophotographers \
                    confirm that including soft-but-round frames barely affects final FWHM while significantly \
                    boosting SNR. The keep/delete recommendation in the quality tooltip reflects this: \
                    frames with round stars get KEEP, only elongated stars get DELETE.
                    """)

                faqItem("Live SNR Retention Bar",
                    """
                    The status bar shows a real-time health bar as you mark frames for deletion. \
                    Green (>95%) = safe, cutting mostly garbage. Yellow (90-95%) = moderate impact. \
                    Orange (80-90%) = significant loss. Red (<80%) = cutting too deep. \
                    Hover for per-group breakdown showing exactly which filter groups are affected.
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
                    Weight in quality score: 1.2x broadband, 0.5x narrowband. When GPU PSF fitting is \
                    available, PSF Flux replaces star count (captures both count AND brightness). \
                    Note: a low star count can also occur when the mount recenters mid-session and shifts \
                    the target partially off the sensor. In this case the visible portion may look perfectly \
                    fine, but half the field is empty. If your images have plate-solved coordinates (CRVAL1/CRVAL2), \
                    comparing center positions across frames can reveal pointing offsets.
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
                    When you open a session, AstroBlink detects the session type and automatically sorts \
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
                    a full RGB image. AstroBlink uses GPU-accelerated bilinear interpolation.
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
                    group (target + filter + exposure) next to the selected frame. If no same-group match \
                    is available, falls back to the best frame in the entire session. Zoom and pan are \
                    synchronized — drag in one image to zoom, both follow. \
                    Star overlay shows circles color-coded by eccentricity (green=round, orange=borderline, \
                    red=elongated). Elongated stars show PA direction lines. When trailing consensus \
                    exists, a yellow arrow indicates the trailing direction. \
                    The recommendation (KEEP/DELETE/REVIEW) is shown in bold color at the bottom.
                    """)

                faqItem("Self-Calibration",
                    """
                    AstroBlink silently learns your equipment's quality baseline as you work. Every \
                    mark/unmark action and PRE-DELETE confirmation trains the system. After 30+ frames \
                    with the same setup (telescope + camera + focal length), an absolute quality floor \
                    activates: frames meeting the learned baseline are locked as KEEP — z-scores cannot \
                    override them. This prevents the \"death spiral\" where repeated culling removes \
                    good frames. Calibration data is stored per-setup in Application Support.
                    """)

                Divider()

                // SmartCull
                faqSection("SmartCull — Multi-Stage Quality Engine",
                    """
                    SmartCull is a 5-stage pipeline that handles ~99% of quality decisions \
                    automatically, leaving only genuine edge cases for you. Validated on 1,638 frames \
                    across 7 setups (4 telescopes, mono+OSC, narrowband+broadband).
                    """)

                faqItem("Stage 1 — Garbage Detection",
                    """
                    Absolute thresholds catch catastrophic failures immediately: near-zero stars, \
                    SNR below 50% of group median, FWHM/HFR over 2x median, extreme eccentricity \
                    (more than 2x the focal-length baseline — adapts automatically to your optics), \
                    severe trailing (cross-checked against FWHM), star count anomalies from tracking \
                    jumps, background anomalies from clouds or fog, and twilight detection. \
                    Twilight is filter-aware: narrowband (Ha/OIII/SII) tolerates nautical twilight \
                    (sun -12° to -6°) since narrow bandpass rejects sky glow. Broadband and \
                    luminance are flagged as garbage at nautical twilight.
                    """)

                faqItem("Stage 1.5 — Session Sanity Check",
                    """
                    Cross-group comparison using session-wide P10/P90 benchmarks. If 2+ metrics \
                    (FWHM, SNR, stars, eccentricity) are dramatically worse than the session's \
                    best-decile values, the frame is demoted to trash — even if it looked acceptable \
                    within its own (weak) group. Catches uniformly bad groups where every frame is poor.
                    """)

                faqItem("Stage 2 — Z-Score Ranking",
                    """
                    Per-group (target + filter + exposure + night) robust z-scores using median/MAD. \
                    Metrics: PSF Flux / Stars (1.2x broadband, 0.5x narrowband), FWHM (1.0x), \
                    Noise (1.0x), Trailing (filter-aware: 0.3x NB, 0.6x RGB, 1.0x luminance). \
                    Target-aware weights adjust by object type (v5.14.0). \
                    Individual z-scores capped at ±3.0 to prevent one extreme value from dominating.
                    """)

                faqItem("Stage 3 — Rescue Rules",
                    """
                    Pattern-based rules rescue frames that z-scores unfairly penalize: \
                    (A) Good FWHM + acceptable noise → rescued to Good, even if stars dipped. \
                    (B) Star count dip with sharp stars → recognized as transient event (clouds, dew). \
                    (C) FWHM-only penalty → promoted to Borderline with lower SSWEIGHT \
                    (softer seeing still adds signal in weighted stacking).
                    """)

                faqItem("Stage 4 — Sanity Check",
                    """
                    Z-score trash frames with FWHM within the Good range are promoted to Borderline. \
                    This catches the rare case where overall z-score dips below threshold but the \
                    frame has perfectly sharp stars worth keeping.
                    """)

                faqItem("Quality Reasoning (\"Why?\")",
                    """
                    Hover any quality icon to see a human-readable explanation of why the frame \
                    received its tier. The tooltip shows per-metric z-scores, the SNR contribution, \
                    and a specific reason like \"FWHM worst in group\" or \"Star count dip — \
                    likely transient event\". SmartCull is not a black box.
                    """)

                faqItem("Culling Autopilot",
                    """
                    Click the auto-mark button (wand icon) in the toolbar for one-click auto-marking: \
                    Conservative (only Stage 1 garbage), Balanced (+ severe borderline), \
                    Aggressive (+ all borderline). Each mode shows frame count and integration \
                    impact before applying.
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

                // Target Catalog Browser
                faqSection("Target Catalog Browser (v5.15.0)",
                    """
                    Browse 533+ deep-sky objects with planning tools. Open via Window menu \u{2192} Target Catalog \
                    or the Catalog toolbar button.
                    """)

                faqItem("Search & Filter",
                    """
                    Search by name (common names, catalog IDs, aliases), filter by object type \
                    (galaxy, nebula, cluster, etc.), constellation, or difficulty level. \
                    Results update in real time as you type.
                    """)

                faqItem("Alt/Az Visibility Chart",
                    """
                    Altitude/Azimuth chart shows target visibility throughout the night with a \
                    moon position overlay, current time marker, and azimuth direction arrows \
                    (compass bearings showing where the target is headed). Plan your imaging \
                    session around the best visibility window.
                    """)

                faqItem("Weather & Cloud Bars",
                    """
                    Integrated weather data: cloud cover (1-hourly bars with midnight gap and \
                    current hour highlight), seeing conditions, temperature, humidity, \
                    and wind speed. Auto-refreshes when you change location.
                    """)

                faqItem("FOV Simulation",
                    """
                    Field-of-view overlay using your equipment profiles. See how the target fits \
                    your sensor and focal length before you go outside.
                    """)

                faqItem("Filter Gap Analysis",
                    """
                    Shows which filters need more integration time based on your existing data \
                    from Frame History. Helps prioritize your next imaging session.
                    """)

                faqItem("Location & Setup Picker",
                    """
                    Select your observing location and equipment setup. Integration hours \
                    are filtered by the selected equipment, so you can track progress per rig. \
                    Weather forecast auto-refreshes when location changes. Hover over a target \
                    name for a compact datasheet card. DSS thumbnails enlarge on hover.
                    """)

                faqItem("DSS Sky Survey Thumbnails",
                    """
                    Preview images from the Digitized Sky Survey (NASA public domain) for \
                    each target, so you know what to expect before imaging.
                    """)

                Divider()

                // VLM Check
                faqSection("VLM Check — Visual Anomaly Detection (v5.18.0)",
                    """
                    VLM Check uses Claude Vision AI to inspect your session frames for visual anomalies \
                    that metric-based scoring cannot detect: ice crystals forming on the corrector plate, \
                    dew buildup, passing clouds, physical obstructions, focus shifts, and light leaks.
                    """)

                faqItem("How it works",
                    """
                    Frames are grouped by target + filter + setup and arranged into a chronological \
                    mosaic grid (center-cropped tiles with frame number and capture time). The mosaic \
                    is sent to Claude Vision, which compares tiles against each other to spot anomalies. \
                    A deviation map (computed locally before sending) highlights tiles that differ from \
                    the group median — bright areas mean significant deviation.
                    """)

                faqItem("Why not satellite trails?",
                    """
                    Satellite trails are already handled by the star trailing metric detector, which \
                    measures elongation consensus across multiple stars. VLM focuses on anomalies that \
                    are visually obvious but hard to capture in a single number: a frost halo forming \
                    over 3 frames, a tree branch entering the field, or gradual dew accumulation.
                    """)

                faqItem("Interacting with results",
                    """
                    Click any tile in the mosaic to mark/unmark its frame for pre-deletion (blue overlay). \
                    The anomaly list shows all flagged frames with a description — click to jump to that \
                    frame in the main file list. Use Mark Flagged to mark all VLM-detected anomalies at once, \
                    or Unmark to clear marks set by the VLM window.
                    """)

                faqItem("Usage quota",
                    """
                    10 free VLM checks per day via the built-in Supabase edge function — no setup required. \
                    For unlimited checks, enter your own Claude API key in the app preferences. Each mosaic \
                    page counts as one check.
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
