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
                Button("Astrofile Locations…") {
                    NotificationCenter.default.post(name: .showAstroRootsSettings, object: nil)
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
    static let showAstroRootsSettings = Notification.Name("showAstroRootsSettings")
}

// AppDelegate extension for help window
class AppDelegate: NSObject {
    @objc static func showHelpWindow() {
        HelpWindowController.shared.showWindow(nil)
    }
}

