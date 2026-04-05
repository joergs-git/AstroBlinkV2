// v4.3.0
import SwiftUI

// Root view: toolbar on top, optional side panels (inspector left, session right),
// image viewer + file list in center, status bar at bottom.
// Supports night mode (N key): black background + red UI for dark-adapted vision.
struct ContentView: View {
    @StateObject private var viewModel = TriageViewModel()
    @State private var renderer: MetalRenderer?
    @State private var keyboardMonitor: Any?
    @State private var sliderValue: Double = Double(AppSettings.loadFloat(for: .stretchStrength) ?? STFCalculator.defaultTargetBackground)

    // Night mode colors
    private var nightFg: Color { viewModel.nightMode ? .red : Color(NSColor.labelColor) }
    private var nightFgDim: Color { viewModel.nightMode ? .red.opacity(0.7) : Color(NSColor.secondaryLabelColor) }
    private var nightBg: Color { viewModel.nightMode ? .black : Color(NSColor.windowBackgroundColor) }
    private var nightToolbarBg: Color { viewModel.nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor) }
    private var nightControlBg: Color { viewModel.nightMode ? Color(red: 0.08, green: 0, blue: 0) : Color(NSColor.controlBackgroundColor) }
    private var nightDivider: Color { viewModel.nightMode ? Color(red: 0.3, green: 0, blue: 0) : Color(NSColor.separatorColor) }

    // Thin vertical divider for status bar separation
    private var statusDivider: some View {
        Text("|")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(nightFgDim.opacity(0.5))
            .padding(.horizontal, 4)
    }

    var body: some View {
        bodyContent
            .modifier(ContentViewModifiers(viewModel: viewModel, sliderValue: $sliderValue, renderer: $renderer, keyboardMonitor: $keyboardMonitor))
    }

    // MARK: - Toolbar Helpers

    // Top-level VStack: path bar + toolbar + banner + main content
    private var bodyContent: some View {
        VStack(spacing: 0) {
            pathBar
            toolbarArea
            Rectangle().fill(nightDivider).frame(height: 1)
            bannerArea
            mainContentArea
        }
    }

    // Path bar: shows current session directory
    @ViewBuilder
    private var pathBar: some View {
        if let rootURL = viewModel.sessionRootURL {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(nightFgDim.opacity(0.6))
                Text(rootURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(nightFg.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                Button(action: { viewModel.openFolder() }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(nightFg)
                .help("Open another folder (⌘O)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(nightToolbarBg)
            Rectangle().fill(nightDivider).frame(height: 1)
        }
    }

    // In-app message banner (fetched from Supabase)
    @ViewBuilder
    private var bannerArea: some View {
        if let message = viewModel.bannerMessage {
            AppMessageBannerView(
                message: message,
                nightMode: viewModel.nightMode,
                onDismiss: { viewModel.dismissBannerMessage() },
                onSnooze: { viewModel.snoozeBannerMessage() },
                onRespond: { actionType, value in
                    viewModel.respondToBannerMessage(actionType: actionType, value: value)
                }
            )
        }
    }

    // Main content: inspector panel + center (viewer + file list + status) + session overview
    private var mainContentArea: some View {
        HStack(spacing: 0) {
            if viewModel.showInspector {
                HeaderInspectorContentView(model: viewModel.headerInspectorModel)
                    .environment(\.fontScale, viewModel.fontScale)
                    .frame(width: 420)
                    .background(nightBg)
                Rectangle().fill(nightDivider).frame(width: 1)
            }

            centerColumn

            if viewModel.showSessionOverview {
                Rectangle().fill(nightDivider).frame(width: 1)
                SessionOverviewContentView(model: viewModel.sessionOverviewModel)
                    .environment(\.fontScale, viewModel.fontScale)
                    .frame(width: 480)
                    .background(nightBg)
            }
        }
    }

    // Center column: image viewer + file list + progress bars + status bar
    private var centerColumn: some View {
        VStack(spacing: 0) {
            VSplitView {
                imageViewerArea
                    .frame(minHeight: 200)

                fileListArea
                    .frame(minHeight: 150, idealHeight: 250)
            }

            progressBarsArea
            statusBarArea
        }
    }

    // Image viewer with overlays
    private var imageViewerArea: some View {
        ZStack(alignment: .center) {
            ImageViewerView(viewModel: viewModel, renderer: $renderer)

            if viewModel.isCaching,
               let image = viewModel.selectedImage,
               !viewModel.isImageCached(image.url),
               viewModel.currentDecodedImage == nil {
                Text("Caching this image...")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(viewModel.nightMode ? .red.opacity(0.8) : .white.opacity(0.8))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
            }

            if viewModel.showQuickStackV2, let engine = viewModel.quickStackEngineV2 {
                VStack {
                    HStack {
                        Spacer()
                        QuickStackV2ProgressView(engine: engine, nightMode: viewModel.nightMode, onDismiss: {
                            viewModel.showQuickStackV2 = false
                            viewModel.quickStackEngineV2?.cancel()
                        })
                        .padding(12)
                    }
                    Spacer()
                }
            }

            if viewModel.showColorCombine, let engine = viewModel.colorCombineEngine {
                VStack {
                    HStack {
                        Spacer()
                        ColorCombineSetupView(engine: engine, nightMode: viewModel.nightMode, onDismiss: {
                            viewModel.showColorCombine = false
                            viewModel.colorCombineEngine?.cancel()
                        }, debayerEnabled: viewModel.debayerEnabled)
                        .padding(12)
                    }
                    Spacer()
                }
            }

            // VLM Check: mosaic generation overlay
            if viewModel.isGeneratingMosaic {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .scaleEffect(1.2)
                    Text("Preparing VLM Check")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(viewModel.mosaicProgress)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                    Text("Assembling mosaic wallpaper for AI analysis...")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .shadow(radius: 20)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(.easeInOut(duration: 0.3), value: viewModel.isGeneratingMosaic)
            }
        }
    }

    // File list with loading overlay
    private var fileListArea: some View {
        ZStack {
            FileListView(viewModel: viewModel)

            if viewModel.loadingPhase != .none {
                VStack(spacing: 12) {
                    ProgressView(value: viewModel.headerProgress)
                        .progressViewStyle(.linear)
                        .tint(viewModel.nightMode ? .red : .accentColor)
                        .frame(width: 300)
                    Text(viewModel.loadingPhase.rawValue)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(viewModel.nightMode ? .red : .primary)
                    Text("\(viewModel.headerReadCount) / \(viewModel.headerReadTotal)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(viewModel.nightMode ? .red.opacity(0.7) : .secondary)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(viewModel.nightMode ? Color.black.opacity(0.9) : Color(NSColor.windowBackgroundColor).opacity(0.95))
                        .shadow(radius: 8)
                )
            }
        }
    }

    // Progress bars for loading/caching/downloading
    @ViewBuilder
    private var progressBarsArea: some View {
        if viewModel.loadingPhase != .none || viewModel.isDownloading || viewModel.isCaching || viewModel.cachingStopped {
            HStack(spacing: 6) {
                VStack(spacing: 1) {
                    if viewModel.isCaching || viewModel.cachingStopped {
                        fuelBar(
                            progress: viewModel.cacheProgress,
                            label: viewModel.isCaching
                                ? "Analyzing \(viewModel.cachingCount)/\(viewModel.cachingTotal)\(viewModel.cachingEstimatedSecondsRemaining.map { " — Est: \($0)s" } ?? "")"
                                : "Caching paused — \(viewModel.prefetchCachedCount)/\(viewModel.images.count)",
                            color: Color(red: 0.25, green: 0.5, blue: 0.9),
                            height: viewModel.isDownloading ? 11 : 22,
                            isNight: viewModel.nightMode
                        )
                    }
                    if viewModel.isDownloading {
                        fuelBar(
                            progress: viewModel.downloadProgress,
                            label: "Downloading \(viewModel.downloadCount)/\(viewModel.downloadTotal)\(viewModel.downloadEstimatedSecondsRemaining.map { " — Est: \($0)s" } ?? "")",
                            color: Color(red: 0.15, green: 0.35, blue: 0.7),
                            height: viewModel.isCaching ? 11 : 22,
                            isNight: viewModel.nightMode
                        )
                    } else if viewModel.loadingPhase == .scanning {
                        fuelBar(progress: 0, label: "Scanning folder...", color: Color(red: 0.15, green: 0.35, blue: 0.7), height: 22, isNight: viewModel.nightMode)
                    } else if viewModel.loadingPhase == .readingHeaders {
                        fuelBar(
                            progress: viewModel.headerProgress,
                            label: "Loading headers \(viewModel.headerReadCount)/\(viewModel.headerReadTotal)\(viewModel.headerEstimatedSecondsRemaining.map { " — Est: \($0)s" } ?? "")",
                            color: Color(red: 0.15, green: 0.35, blue: 0.7),
                            height: 22,
                            isNight: viewModel.nightMode
                        )
                    }
                }
                .cornerRadius(3)

                if viewModel.isCaching {
                    Button(action: { viewModel.stopCaching() }) {
                        Image(systemName: "stop.fill").font(.system(size: 12))
                            .foregroundColor(viewModel.nightMode ? .red : nil)
                    }
                    .buttonStyle(.bordered).controlSize(.small).help("Stop caching")
                }
                if viewModel.cachingStopped {
                    Button(action: { viewModel.continueCaching() }) {
                        Image(systemName: "play.fill").font(.system(size: 12))
                            .foregroundColor(viewModel.nightMode ? .red : nil)
                    }
                    .buttonStyle(.bordered).controlSize(.small).help("Continue caching")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3).background(nightBg)
        }
    }

    // Status bar with pills and stats
    private var statusBarArea: some View {
        HStack(spacing: 6) {
            statusBarLeftPills
            Spacer()
            statusBarRightStats
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(nightBg)
    }

    // Status bar left: mode pills
    private var statusBarLeftPills: some View {
        HStack(spacing: 6) {
            if !viewModel.images.isEmpty {
                statusPill(
                    "\(viewModel.markedCount) of \(viewModel.images.count) marked",
                    bg: viewModel.markedCount > 0
                        ? (viewModel.nightMode ? Color(red: 0.4, green: 0, blue: 0) : Color(red: 0.8, green: 0.25, blue: 0.25))
                        : (viewModel.nightMode ? Color(red: 0.15, green: 0, blue: 0) : Color(white: 0.35))
                )
                .help("Frames marked for deletion (Space to toggle, Cmd+Backspace to move to PRE-DELETE)")
            }
            if viewModel.hideMarked {
                statusPill("Hiding", bg: viewModel.nightMode ? Color(red: 0.3, green: 0, blue: 0) : Color(red: 0.15, green: 0.55, blue: 0.55))
                    .help("Marked frames are hidden from the file list (H to toggle)")
            }
            if viewModel.showOnlyMarked {
                statusPill("Only Marked", bg: viewModel.nightMode ? Color(red: 0.35, green: 0, blue: 0) : Color(red: 0.7, green: 0.4, blue: 0.1))
                    .help("Showing only marked frames — review before deleting (Shift+H to toggle)")
            }
            if viewModel.isSTFLocked {
                statusPill("Locked STF", bg: viewModel.nightMode ? Color(red: 0.35, green: 0.15, blue: 0) : Color.orange.opacity(0.85))
                    .help("Stretch is locked to current image's parameters — all images use the same brightness mapping for direct comparison (S to toggle)")
            }
            if viewModel.applyAllEnabled {
                statusPill(
                    viewModel.cacheMatchesCurrentSettings ? "Applied" : "Applying...",
                    bg: viewModel.nightMode ? Color(red: 0, green: 0, blue: 0.3)
                        : (viewModel.cacheMatchesCurrentSettings ? Color.blue.opacity(0.7) : Color.blue.opacity(0.5))
                )
                .help("Current stretch/sharp/contrast/dark settings are baked into all cached previews for consistent comparison")
            }
            if viewModel.skipMarked {
                statusPill("Skip", bg: viewModel.nightMode ? Color(red: 0.3, green: 0, blue: 0) : Color(red: 0.75, green: 0.55, blue: 0.15))
                    .help("Arrow keys skip over marked frames — navigate only unmarked images (K to toggle)")
            }
            if viewModel.nightMode {
                statusPill("Night", bg: Color(red: 0.35, green: 0, blue: 0))
                    .help("Night mode — red-only UI to preserve dark-adapted vision at the telescope (N to toggle)")
            }
            if viewModel.debayerEnabled && viewModel.hasOSCImages {
                statusPill("Debayer", bg: viewModel.nightMode ? Color(red: 0.3, green: 0, blue: 0) : Color(red: 0.15, green: 0.5, blue: 0.25))
                    .help("Color debayering active — one-shot-color (OSC) images shown in RGB instead of mono (D to toggle)")
            }
            if viewModel.autoMeridianEnabled && viewModel.hasMeridianFlip {
                statusPill("MeridianFlip", bg: viewModel.nightMode ? Color(red: 0.25, green: 0, blue: 0.15) : Color.purple.opacity(0.7))
                    .help("Meridian flip detected — images from the opposite pier side are rotated 180\u{00B0} for consistent orientation")
            }
            if viewModel.isPlaying {
                statusPill("Blink", bg: viewModel.nightMode ? Color(red: 0.4, green: 0, blue: 0) : Color.green.opacity(0.7))
                    .help("Blink playback active — ESC to stop")
            }
        }
    }

    // Status bar right: cache stats, SNR retention, status message, community, iCloud
    private var statusBarRightStats: some View {
        HStack(spacing: 6) {
            if !viewModel.images.isEmpty {
                statusDivider
                Text("\(viewModel.prefetchCachedCount) cached (\(formatBytes(viewModel.cacheMemoryBytes))) — Raw: \(formatBytes(viewModel.totalRawFileSize))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(nightFgDim)
            }
            if viewModel.selectedTableIndices.count > 1 {
                statusDivider
                Text("\(viewModel.selectedTableIndices.count) selected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(nightFgDim)
            }
            if viewModel.snrRetention < 99.95 && !viewModel.images.isEmpty {
                statusDivider
                SNRRetentionBarView(retention: viewModel.snrRetention, isNightMode: viewModel.nightMode)
                    .help(viewModel.snrRetentionDetail)
            }
            if viewModel.cullingStatus != nil && !viewModel.images.isEmpty {
                statusDivider
                CullingStatusView(viewModel: viewModel, isNightMode: viewModel.nightMode)
            }
            statusDivider
            Text(viewModel.statusMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(nightFgDim)
                .lineLimit(1)
                .textSelection(.enabled)
            statusBarCommunityAndCloud
        }
    }

    // Community learning + iCloud indicators
    private var statusBarCommunityAndCloud: some View {
        HStack(spacing: 6) {
            statusDivider
            let communityEnabled = AppSettings.defaults.bool(forKey: AppSettings.Key.communityLearning.rawValue)
            HStack(spacing: 2) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10))
                    .foregroundColor(communityEnabled ? (viewModel.nightMode ? .red : .green) : nightFgDim.opacity(0.4))
                Text("Community")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(communityEnabled ? nightFgDim.opacity(0.6) : nightFgDim.opacity(0.4))
            }
            .onTapGesture {
                let newValue = !AppSettings.defaults.bool(forKey: AppSettings.Key.communityLearning.rawValue)
                AppSettings.save(newValue, for: .communityLearning)
                viewModel.objectWillChange.send()
            }
            .help(communityEnabled
                ? "Community Learning is ON — You're helping improve quality detection for all AstroBlink users! Only anonymous metric averages (FWHM, SNR, trailing) are shared. No filenames, no images, no coordinates, no personal data — ever. New equipment? You'll get instant calibration from the community. Click to disable."
                : "Community Learning is OFF — Click to join! Share anonymous quality metrics to help improve detection accuracy for everyone. In return, you get instant calibration baselines when trying new equipment — no 30-frame warmup needed. No personal data is ever shared: no filenames, no images, no location, no equipment names.")

            statusDivider
            HStack(spacing: 2) {
                if FileManager.default.ubiquityIdentityToken != nil {
                    Image(systemName: "checkmark.icloud").font(.system(size: 10))
                        .foregroundColor(viewModel.nightMode ? .red : .green)
                    Text("iCloud").font(.system(size: 9, design: .monospaced))
                        .foregroundColor(nightFgDim.opacity(0.6))
                } else {
                    Image(systemName: "xmark.icloud").font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.7))
                    Text("iCloud").font(.system(size: 9, design: .monospaced))
                        .foregroundColor(nightFgDim.opacity(0.4))
                }
            }
            .help(FileManager.default.ubiquityIdentityToken != nil
                ? "iCloud is ON — Your settings, calibration profiles, and equipment memory sync privately across your Macs. All data stays in your personal iCloud account — nothing is shared publicly or with other users."
                : "iCloud is OFF — Settings and calibration data are stored locally only. Sign in to iCloud in System Settings to sync across your Macs. iCloud data is always private — never shared with anyone.")
        }
    }

    // Full toolbar: buttons row + separator + sliders row
    private var toolbarArea: some View {
        VStack(spacing: 2) {
            toolbarButtonsRow
                .padding(.bottom, 2)
            Rectangle().fill(nightDivider).frame(height: 1)
            imageSettingsRow
                .padding(.horizontal, 8)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .background(nightToolbarBg)
    }

    // Row 1: Icon buttons + toggles + search + stats
    private var toolbarButtonsRow: some View {
        HStack(spacing: 4) {
            // ── Group 1: File operations ──
            sfToolbarButton("folder", "Open", "Open Folder (⌘O)") { viewModel.openFolder() }
            sfToolbarButton("list.bullet.rectangle", "Inspector", "Show FITS/XISF header keywords for selected image (I)") { viewModel.toggleHeaderInspector() }
            sfToolbarButton("chart.bar", "Session", "Session overview — group stats by filter, night, and target") {
                viewModel.showSessionOverview.toggle()
            }
            sfToolbarButton("clock.arrow.circlepath", "History", "Frame history — quality trends across all sessions") {
                FrameHistoryController.shared.toggleWindow()
            }
            sfToolbarButton("books.vertical", "Catalog", "Browse 229+ deep-sky targets with visibility, FOV sim, and filter gap analysis") {
                let sessionTargets = Set(viewModel.images.compactMap { $0.canonicalTarget })
                TargetDatabaseWindowController.shared.show(sessionTargets: sessionTargets)
            }

            toolbarDivider

            // ── Group 2: Actions ──
            autoMarkToolbarButton
            sfToolbarButton("eye.trianglebadge.exclamationmark", "VLM\nCheck",
                "Generate mosaic wallpaper from remaining frames.\nRuns VLM anomaly detection (ice, dew, clouds, satellites)\nvia Claude Vision API.") {
                viewModel.startVisualValidation()
            }
            aisaacToolbarButton
            sfToolbarButton("square.and.arrow.up", "SSWEIGHT\nExport",
                "Export quality weights to FITS/XISF headers for WBPP.\nOperates on highlighted files (or all if none selected).\nAlso creates CSV backup.\nUse Batch Rename to remove SSWEIGHT keywords.") {
                viewModel.exportSSWEIGHT()
            }
            sfToolbarButton("trash", "Delete", "Move spacebar-marked files to _predel/ staging folder (⌘⌫)\nFiles are NOT permanently deleted") { viewModel.moveMarkedToPreDelete() }
            if viewModel.canUndoPreDelete {
                sfToolbarButton("arrow.uturn.backward", "Undo", "Undo last Pre-Delete (⌘Z)") { viewModel.undoPreDelete() }
            }

            toolbarDivider

            // ── Group 3: Stacking ──
            sfToolbarButton("bolt.fill", "Lightspeed\nStacker", "GPU-accelerated stacking with outlier rejection.\nSelect 3+ images first.") {
                viewModel.startQuickStackV2()
            }
            sfToolbarButton("paintpalette.fill", "Color\nCombine", "Combine mono filter stacks into RGB color image.\nNeeds 2+ filters with 3+ frames each.") {
                viewModel.startColorCombine()
            }

            toolbarDivider

            toolbarDisplayToggles
            toolbarDivider
            toolbarSearchBar
            toolbarFilterPresets

            Spacer()

            toolbarRightSide
        }
    }

    // Display toggles: Apply All, Debayer, Lock STF, Meridian Flip
    private var toolbarDisplayToggles: some View {
        HStack(spacing: 4) {
            VStack(spacing: 2) {
                Toggle("Apply\nAll", isOn: Binding(
                    get: { viewModel.applyAllEnabled },
                    set: { _ in viewModel.toggleApplyAll() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.blue)
                .help("Apply current settings to all cached previews")
            }
            .frame(width: 90)

            if viewModel.hasOSCImages {
                VStack(spacing: 2) {
                    Toggle("Debayer", isOn: Binding(
                        get: { viewModel.debayerEnabled },
                        set: { _ in viewModel.toggleDebayer() }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.green)
                    .help("Toggle OSC debayer (D)")
                }
                .frame(width: 90)
            }

            VStack(spacing: 2) {
                Toggle("Lock STF", isOn: Binding(
                    get: { viewModel.isSTFLocked },
                    set: { _ in viewModel.toggleLockSTF() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.orange)
                .help("Lock STF — same stretch for all images (S)")
            }
            .frame(width: 90)

            VStack(spacing: 2) {
                Toggle("Meridian\nFlip", isOn: Binding(
                    get: { viewModel.autoMeridianEnabled },
                    set: { _ in viewModel.toggleAutoMeridian() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.purple)
                .help("Auto-rotate images across meridian flip for consistent orientation")
            }
            .frame(width: 95)
        }
    }

    // Search bar with match count and mark/unmark/clear buttons
    private var toolbarSearchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(nightFgDim)

            TextField("Search... (e.g. Ha, filter:L, fwhm:>4)", text: $viewModel.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(nightFg)
                .onChange(of: viewModel.filterText) { _ in
                    viewModel.needsTableRefresh = true
                }

            if !viewModel.filterText.isEmpty {
                Text("\(viewModel.visibleImages.count)/\(viewModel.images.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(nightFgDim)

                Button(action: { viewModel.markFilteredImages() }) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(viewModel.nightMode ? .red : .accentColor)
                .help("Mark all filtered images")

                Button(action: { viewModel.unmarkFilteredImages() }) {
                    Image(systemName: "circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(viewModel.nightMode ? .red : .secondary)
                .help("Unmark all filtered images")

                Button(action: {
                    viewModel.filterText = ""
                    viewModel.needsTableRefresh = true
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(nightFgDim)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(viewModel.nightMode
                      ? Color(red: 0.05, green: 0, blue: 0)
                      : Color(NSColor.textBackgroundColor))
        )
        .frame(minWidth: 150, maxWidth: 300)
    }

    // Filter presets dropdown menu
    private var toolbarFilterPresets: some View {
        Menu {
            Section("Quality") {
                Button("Excellent") { viewModel.filterText = "q:excellent" }
                Button("Good") { viewModel.filterText = "q:good" }
                Button("Borderline") { viewModel.filterText = "q:borderline" }
                Button("Uncertain") { viewModel.filterText = "q:uncertain" }
                Button("Trash") { viewModel.filterText = "q:trash" }
                Button("Unscored") { viewModel.filterText = "q:unscored" }
            }
            Section("Common Filters") {
                Button("Luminance") { viewModel.filterText = "filter:L" }
                Button("Red") { viewModel.filterText = "filter:R" }
                Button("Green") { viewModel.filterText = "filter:G" }
                Button("Blue") { viewModel.filterText = "filter:B" }
                Button("Ha") { viewModel.filterText = "filter:Ha" }
                Button("OIII") { viewModel.filterText = "filter:OIII" }
                Button("SII") { viewModel.filterText = "filter:SII" }
            }
            Section("Metrics") {
                Button("FWHM > 5") { viewModel.filterText = "fwhm:>5" }
                Button("Stars < 100") { viewModel.filterText = "stars:<100" }
                Button("Trailing > 0.5") { viewModel.filterText = "trail:>0.5" }
            }
            Divider()
            Button("Clear Filter") { viewModel.filterText = "" }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 13))
                .foregroundColor(nightFg.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
        .help("Filter presets — click to apply a predefined filter")
    }

    // Night mode, Benchmark, Help, About
    private var toolbarRightSide: some View {
        HStack(spacing: 4) {
            VStack(spacing: 2) {
                Toggle("Night", isOn: Binding(
                    get: { viewModel.nightMode },
                    set: { _ in viewModel.toggleNightMode() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.red)
                .help("Toggle Night Mode (N)")
            }
            .frame(width: 80)

            sfToolbarButton("gauge.with.dots.needle.67percent", "Benchmark", "Session load & stacking performance stats.\nCompare with community leaderboard.", iconColor: Color(red: 0.25, green: 0.45, blue: 0.85)) {
                NotificationCenter.default.post(name: .showBenchmarkStats, object: nil)
            }

            toolbarDivider

            sfToolbarButton("questionmark.circle", "Help", "Help (⌘?)") { HelpWindowController.shared.showWindow(nil) }
            sfToolbarButton("info.circle", "About", "About") { AstroBlinkV2AppDelegate.showAboutPanel() }
        }
    }

    // Row 2: Sliders + blink controls + histogram
    private var imageSettingsRow: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(action: {
                viewModel.resetSlidersToDefaults()
                sliderValue = Double(viewModel.stretchStrength)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                    Text("Reset")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundColor(nightFg)
            }
            .buttonStyle(.plain)
            .help("Reset all sliders to defaults")
            .contentShape(Rectangle())

            compactSlider("Stretch", value: $sliderValue, range: 0.0...1.0, step: 0.01,
                display: { "\(Int($0 / 1.0 * 100))%" },
                onRelease: { viewModel.updateStretchStrength(Float(sliderValue)) })

            compactSlider("Sharp", value: Binding(
                get: { Double(viewModel.sharpening) },
                set: { viewModel.sharpening = Float($0); viewModel.updatePostProcessParams() }
            ), range: -4.0...4.0, step: 0.1,
                display: { String(format: "%+.1f", $0) })

            compactSlider("Contrast", value: Binding(
                get: { Double(viewModel.contrast) },
                set: { viewModel.contrast = Float($0); viewModel.updatePostProcessParams() }
            ), range: -2.0...2.0, step: 0.05,
                display: { String(format: "%+.1f", $0) })

            compactSlider("Dark", value: Binding(
                get: { Double(viewModel.darkLevel) },
                set: { viewModel.darkLevel = Float($0); viewModel.updatePostProcessParams() }
            ), range: 0.0...1.0, step: 0.01,
                display: { String(format: "%.2f", $0) })

            blinkPlaybackControls

            if !viewModel.histogramBins.isEmpty {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(viewModel.histogramBins.enumerated()), id: \.offset) { _, value in
                        Rectangle()
                            .fill(Color.white.opacity(0.6))
                            .frame(width: 1.5, height: CGFloat(value) * 20)
                    }
                }
                .frame(width: 96, height: 20)
                .background(Color.black.opacity(0.3))
                .cornerRadius(3)
                .help("Luminance histogram (pre-stretch, raw data)")
            }

            Spacer()
        }
    }

    // Blink playback play/stop + delay picker
    @State private var showExportPopover = false
    @State private var exportLoops: Int = 1
    @State private var exportScale: Int = 50
    @State private var exportFormat: TriageViewModel.BlinkExportFormat = .gif
    @State private var exportMaxSizeMB: Double = 5
    @State private var capturedHighlightedRows: IndexSet?
    @State private var exportCropToZoom: Bool = true

    private var blinkPlaybackControls: some View {
        HStack(spacing: 4) {
            Button(action: { togglePlayback() }) {
                Image(systemName: viewModel.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(viewModel.isPlaying ? .red : nightFg)
            }
            .buttonStyle(.plain)
            .help(viewModel.isPlaying ? "Stop blink (ESC)" : "Blink through images (selected or all)")

            Picker("", selection: $viewModel.playbackDelay) {
                Text("0.1s").tag(0.1)
                Text("0.2s").tag(0.2)
                Text("0.5s").tag(0.5)
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
            }
            .pickerStyle(.menu)
            .frame(width: 60)
            .help("Blink delay between images")
            .onChange(of: viewModel.playbackDelay) { _ in
                if viewModel.isPlaying {
                    viewModel.stopPlayback()
                    togglePlayback()
                }
            }

            Button(action: {
                capturedHighlightedRows = getHighlightedRows()
                showExportPopover.toggle()
            }) {
                if viewModel.isExportingVideo {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 13))
                        .foregroundColor(nightFg)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isExportingVideo || viewModel.images.isEmpty)
            .help("Export blink sequence as video")
            .popover(isPresented: $showExportPopover) {
                blinkExportPopover
            }
        }
    }

    private var blinkExportPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Blink")
                .font(.headline)

            HStack {
                Text("Format:")
                Picker("", selection: $exportFormat) {
                    Text("GIF").tag(TriageViewModel.BlinkExportFormat.gif)
                    Text("MOV").tag(TriageViewModel.BlinkExportFormat.mov)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            HStack {
                Text("Loops:")
                Picker("", selection: $exportLoops) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("5").tag(5)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            HStack {
                Text("Scale:")
                Picker("", selection: $exportScale) {
                    Text("25%").tag(25)
                    Text("50%").tag(50)
                    Text("75%").tag(75)
                    Text("100%").tag(100)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            if viewModel.renderer?.zoomScale ?? 1.0 > 1.01 {
                Toggle("Crop to current zoom", isOn: $exportCropToZoom)
                    .font(.caption)
            }

            if exportFormat == .gif {
                HStack {
                    Text("Max size:")
                    Picker("", selection: $exportMaxSizeMB) {
                        Text("2 MB").tag(2.0)
                        Text("5 MB").tag(5.0)
                        Text("10 MB").tag(10.0)
                        Text("No limit").tag(0.0)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                Text("Frames auto-dropped to fit size limit")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Speed:")
                Text(String(format: "%.1fs/frame", viewModel.playbackDelay))
                    .foregroundColor(.secondary)
            }

            let frameCount = capturedHighlightedRows.map { $0.count } ?? viewModel.visibleImages.count
            let source = capturedHighlightedRows != nil ? "selected" : "visible"
            Text("\(frameCount) \(source) frames × \(exportLoops) = \(frameCount * exportLoops) total")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Export") {
                    showExportPopover = false
                    let fps = 1.0 / viewModel.playbackDelay
                    viewModel.exportBlinkVideo(
                        format: exportFormat,
                        loops: exportLoops,
                        scalePercent: exportScale,
                        maxSizeMB: exportMaxSizeMB,
                        highlightedRows: capturedHighlightedRows,
                        fps: fps,
                        cropToZoom: exportCropToZoom
                    )
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(12)
        .frame(width: 270)
    }

    private func togglePlayback() {
        if viewModel.isPlaying {
            viewModel.stopPlayback()
        } else {
            let highlighted = getHighlightedRows()
            viewModel.startPlayback(highlightedRows: highlighted)
        }
    }

    private func getHighlightedRows() -> IndexSet? {
        guard let window = NSApp.keyWindow,
              let tableView = findFileListTable(in: window.contentView) else { return nil }
        let rows = tableView.selectedRowIndexes
        return rows.count > 1 ? rows : nil
    }

    // Find the file list NSTableView by identifier in the view hierarchy
    private func findFileListTable(in view: NSView?) -> NSTableView? {
        guard let view = view else { return nil }
        if let table = view as? NSTableView, table.identifier?.rawValue == "fileListTable" {
            return table
        }
        for sub in view.subviews {
            if let found = findFileListTable(in: sub) { return found }
        }
        return nil
    }

    // Thin vertical divider between toolbar sections
    private var toolbarDivider: some View {
        Rectangle()
            .fill(nightDivider)
            .frame(width: 1, height: 34)
            .padding(.horizontal, 6)
    }

    // SF Symbol toolbar button — monochrome, 24pt icons (50% bigger)
    private func sfToolbarButton(_ symbol: String, _ label: String, _ tooltip: String, iconColor: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(iconColor ?? nightFg)
                Spacer(minLength: 0)
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(nightFgDim)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 56, height: 48)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .contentShape(Rectangle())
    }


    // AIsaac toolbar button with continuous sparkle animation
    // Auto-Mark toolbar button — opens the 3-level autopilot popover
    @State private var showAutoMarkPopover = false
    private var autoMarkToolbarButton: some View {
        Button(action: { showAutoMarkPopover.toggle() }) {
            VStack(spacing: 2) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.green, .orange, .red],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Spacer(minLength: 0)
                Text("Auto-Mark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(nightFgDim)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 56, height: 48)
        }
        .buttonStyle(.plain)
        .help("Auto-mark frames for deletion — Conservative (Nebula), Balanced, or Aggressive (Stars)")
        .contentShape(Rectangle())
        .popover(isPresented: $showAutoMarkPopover, arrowEdge: .bottom) {
            AutoMarkPopover(viewModel: viewModel, isPresented: $showAutoMarkPopover)
                .frame(width: 320)
        }
    }

    @State private var aisaacGlow: Bool = false
    private var aisaacToolbarButton: some View {
        Button(action: {
            AIsaacWindowController.shared.updateContext(images: viewModel.images, viewModel: viewModel)
            AIsaacWindowController.shared.toggleWindow()
        }) {
            VStack(spacing: 2) {
                ZStack {
                    // Base sparkles icon
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.purple)

                    // Glow pulse overlay
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.purple)
                        .opacity(aisaacGlow ? 0.9 : 0.1)
                        .scaleEffect(aisaacGlow ? 1.25 : 0.9)
                        .blur(radius: aisaacGlow ? 3.5 : 0.0)
                }
                Spacer(minLength: 0)
                Text("Ask\nAIsaac")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(nightFgDim)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 56, height: 48)
        }
        .buttonStyle(.plain)
        .help("AI assistant for astrophotography session analysis")
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                aisaacGlow = true
            }
        }
    }

    // Wire AIsaac app control callbacks (static so ViewModifiers can call it)
    static func wireAIsaacCallbacksStatic(viewModel: TriageViewModel) {
        let aisaac = AIsaacWindowController.shared.model
        // Resolve session # (1-based) to array index (handles sort order)
        aisaac.resolveSessionIndex = { [weak viewModel] sessionNum in
            viewModel?.images.firstIndex(where: { $0.sessionIndex == sessionNum })
        }
        aisaac.onNavigateToImage = { [weak viewModel] idx in viewModel?.selectImage(at: idx) }
        aisaac.onNavigateToFirst = { [weak viewModel] in viewModel?.navigateToFirst() }
        aisaac.onNavigateToLast = { [weak viewModel] in viewModel?.navigateToLast() }
        aisaac.onSetFilter = { [weak viewModel] text in
            viewModel?.filterText = text
            // Safety: if filter results in zero visible images, auto-clear after a short delay
            if !text.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if viewModel?.visibleImages.isEmpty == true {
                        viewModel?.filterText = ""
                        AIsaacWindowController.shared.model.postStateComment(
                            "Oops, that filter didn't match anything — showing all files again."
                        )
                    }
                }
            }
        }
        aisaac.onOpenCompare = { [weak viewModel] in viewModel?.compareWithBest() }
        aisaac.onOpenFolder = { [weak viewModel] in viewModel?.openFolder() }
        aisaac.onStartStack = { [weak viewModel] in viewModel?.startQuickStackV2() }
        aisaac.onStackFrames = { [weak viewModel] indices in
            guard let vm = viewModel else { return }
            // Select the specified frames then start stacking
            let indexSet = IndexSet(indices.filter { $0 >= 0 && $0 < vm.images.count })
            vm.selectMultipleRows(indexSet)
            // Small delay to let selection take effect before stacking
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                vm.startQuickStackV2()
            }
        }
        aisaac.onHideMarked = { [weak viewModel] in
            viewModel?.hideMarked = true
            viewModel?.showOnlyMarked = false
        }
        aisaac.onShowOnlyMarked = { [weak viewModel] in
            viewModel?.hideMarked = false
            viewModel?.showOnlyMarked = true
        }
        aisaac.onShowAll = { [weak viewModel] in
            viewModel?.hideMarked = false
            viewModel?.showOnlyMarked = false
        }
        aisaac.onSkipMarked = { [weak viewModel] in viewModel?.skipMarked.toggle() }
        aisaac.onMarkCurrent = { [weak viewModel] in viewModel?.togglePreDelete() }
        aisaac.onUnmarkAll = { [weak viewModel] in viewModel?.unmarkAll() }
        aisaac.onMarkFrames = { [weak viewModel] indices in
            guard let vm = viewModel else { return }
            for idx in indices where idx >= 0 && idx < vm.images.count {
                if !vm.images[idx].isMarkedForDeletion {
                    vm.togglePreDelete(at: idx)
                }
            }
        }
        aisaac.onNightMode = { [weak viewModel] in viewModel?.nightMode.toggle() }
        aisaac.onHighlightFrames = { [weak viewModel] indices in
            guard let vm = viewModel else { return }
            // Select rows in the file list without marking them
            let indexSet = IndexSet(indices.filter { $0 >= 0 && $0 < vm.images.count })
            vm.selectMultipleRows(indexSet)
        }
        aisaac.onViewFrame = { [weak viewModel] idx in viewModel?.selectImage(at: idx) }
        aisaac.onRefreshContext = { [weak viewModel] in
            guard let vm = viewModel else { return }
            AIsaacWindowController.shared.updateContext(images: vm.images, viewModel: vm)
        }
        aisaac.onOpenPreview = { [weak viewModel] indices in
            guard let vm = viewModel, let device = vm.renderer?.device else { return }
            for idx in indices where idx >= 0 && idx < vm.images.count {
                let entry = vm.images[idx]
                ImagePreviewWindowController.open(
                    entry: entry, device: device,
                    nightMode: vm.nightMode, debayerEnabled: vm.debayerEnabled
                )
            }
        }
    }

    // Format byte count as human-readable string (e.g. "1.2 GB", "384 MB")
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }

    // Styled pill for status bar indicators — darker backgrounds for readability
    private func statusPill(_ text: String, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(bg)
            )
    }

    // Fuel bar: a colored progress bar with centered white text label
    private func fuelBar(progress: Double, label: String, color: Color, height: CGFloat, isNight: Bool) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isNight ? Color(red: 0.15, green: 0, blue: 0) : Color(white: 0.2))
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.9), color.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(min(progress, 1.0)))
            }
            HStack {
                Spacer()
                Text(label)
                    .font(.system(size: height > 15 ? 11 : 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
            }
        }
        .frame(height: height)
    }

    // Compact slider — uniform style for all sliders in the toolbar
    // onRelease is optional (for stretch slider which only applies on release)
    private func compactSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: @escaping (Double) -> String,
        onRelease: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(nightFgDim)
                .frame(width: 42, alignment: .trailing)

            if let onRelease = onRelease {
                Slider(value: value, in: range, step: step, onEditingChanged: { editing in
                    if !editing { onRelease() }
                })
                .frame(width: 100)
                .tint(viewModel.nightMode ? .red : nil)
            } else {
                Slider(value: value, in: range, step: step)
                    .frame(width: 100)
                    .tint(viewModel.nightMode ? .red : nil)
            }

            Text(display(value.wrappedValue))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(nightFg)
                .frame(width: 34, alignment: .leading)
        }
    }
}

// MARK: - Content View Modifiers (extracted to reduce type-check complexity)

struct ContentViewModifiers: ViewModifier {
    @ObservedObject var viewModel: TriageViewModel
    @Binding var sliderValue: Double
    @Binding var renderer: MetalRenderer?
    @Binding var keyboardMonitor: Any?

    func body(content: Content) -> some View {
        content
            .background(viewModel.nightMode ? Color.black : Color(NSColor.windowBackgroundColor))
            .preferredColorScheme(viewModel.nightMode ? .dark : nil)
            .onChange(of: viewModel.nightMode) { isNight in
                if let window = NSApp.keyWindow {
                    window.appearance = isNight ? NSAppearance(named: .darkAqua) : nil
                    window.invalidateShadow()
                    window.contentView?.needsDisplay = true
                }
            }
            .onAppear {
                keyboardMonitor = KeyboardHandler.install(viewModel: viewModel)
                ContentView.wireAIsaacCallbacksStatic(viewModel: viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolderRequest)) { _ in
                viewModel.openFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolderAtPath)) { notification in
                guard let folderURL = notification.object as? URL else { return }
                // Show NSOpenPanel pre-navigated to the folder — sandbox requires user selection
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = folderURL
                panel.message = "Confirm opening this session folder from PixInsight"
                panel.prompt = "Open Session"
                if panel.runModal() == .OK, let url = panel.url {
                    viewModel.loadSession(url: url)
                }
            }
            // PI handoff: clipboard check runs in AppDelegate.applicationDidBecomeActive
            .onReceive(NotificationCenter.default.publisher(for: .showBatchRename)) { _ in
                BatchRenameWindowController.shared.show(viewModel: viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showBenchmarkStats)) { _ in
                BenchmarkStatsWindowController.shared.show(stats: viewModel.benchmarkStats, sessionRootURL: viewModel.sessionRootURL)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showTargetDatabase)) { _ in
                let sessionTargets = Set(viewModel.images.compactMap { $0.canonicalTarget })
                TargetDatabaseWindowController.shared.show(sessionTargets: sessionTargets)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAIsaac)) { _ in
                AIsaacWindowController.shared.updateContext(images: viewModel.images, viewModel: viewModel)
                AIsaacWindowController.shared.toggleWindow()
            }
            .modifier(ContentViewModifiers2(viewModel: viewModel, sliderValue: $sliderValue, renderer: $renderer, keyboardMonitor: $keyboardMonitor))
    }
}

struct ContentViewModifiers2: ViewModifier {
    @ObservedObject var viewModel: TriageViewModel
    @Binding var sliderValue: Double
    @Binding var renderer: MetalRenderer?
    @Binding var keyboardMonitor: Any?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .resetFrameHistory)) { _ in
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Reset Frame History Database?"
                if let stats = try? FrameHistoryDatabase.shared.databaseStats() {
                    alert.informativeText = "This will permanently delete \(stats.frameCount) frame records from \(stats.sessionCount) sessions.\n\nThis cannot be undone."
                } else {
                    alert.informativeText = "This will permanently delete all frame history data.\n\nThis cannot be undone."
                }
                alert.addButton(withTitle: "Reset")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    try? FrameHistoryDatabase.shared.resetDatabase()
                    viewModel.statusMessage = "Frame History Database reset"
                }
            }
            .modifier(AIsaacStateObserver(viewModel: viewModel))
            .onReceive(NotificationCenter.default.publisher(for: .fontScaleIncrease)) { _ in
                viewModel.fontScale = min(1.5, viewModel.fontScale + 0.1)
                AppSettings.saveFloat(Float(viewModel.fontScale), for: .fontScale)
                viewModel.needsTableRefresh = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .fontScaleDecrease)) { _ in
                viewModel.fontScale = max(0.7, viewModel.fontScale - 0.1)
                AppSettings.saveFloat(Float(viewModel.fontScale), for: .fontScale)
                viewModel.needsTableRefresh = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .fontScaleReset)) { _ in
                viewModel.fontScale = 1.0
                AppSettings.saveFloat(1.0, for: .fontScale)
                viewModel.needsTableRefresh = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .checkAppMessages)) { _ in
                viewModel.checkForMessages()
                viewModel.startMessageCheckTimer()
            }
            .onReceive(NotificationCenter.default.publisher(for: .resetSettingsRequest)) { _ in
                let alert = NSAlert()
                alert.messageText = "Reset all settings to defaults?"
                alert.informativeText = "This will reset column order, slider values, and all toggle states."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Reset")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    viewModel.resetAllSettings()
                    sliderValue = Double(viewModel.stretchStrength)
                }
            }
            .onChange(of: viewModel.quickStackEngineV2?.phase) { newPhase in
                if newPhase == .done || newPhase == .failed {
                    viewModel.benchmarkStats.markQuickStackEnd()
                }
            }
            .onDisappear {
                KeyboardHandler.remove(monitor: keyboardMonitor)
            }
            .onChange(of: renderer) { newRenderer in
                viewModel.renderer = newRenderer
            }
            .onChange(of: viewModel.stretchStrength) { newValue in
                sliderValue = Double(newValue)
            }
            .navigationTitle("AstroBlink & AIsaac v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") — Fast Visual Culling for Astrophotography")
            .frame(minWidth: 800, minHeight: 500)
            .modifier(ZoomNotificationModifier(viewModel: viewModel))
    }
}

// Separate modifier to keep type-checker happy (zoom notification receivers)
struct ZoomNotificationModifier: ViewModifier {
    @ObservedObject var viewModel: TriageViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .zoomInStep)) { _ in
                viewModel.zoomIn()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOutStep)) { _ in
                viewModel.zoomOut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomReset)) { _ in
                viewModel.resetZoom()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomPresetSmall)) { _ in
                viewModel.zoomPresetSmall()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomPresetLarge)) { _ in
                viewModel.zoomPresetLarge()
            }
    }
}

// MARK: - SNR Retention Bar

/// Compact "health bar" showing how much stack SNR is retained after marking frames for deletion.
/// Green (>95%) → Yellow (90-95%) → Orange (80-90%) → Red (<80%).
struct SNRRetentionBarView: View {
    let retention: Double
    let isNightMode: Bool

    private var barColor: Color {
        if isNightMode {
            // Night mode: use red-shifted colors to preserve dark adaptation
            if retention > 95 { return Color(red: 0.3, green: 0.0, blue: 0.0) }
            if retention > 90 { return Color(red: 0.4, green: 0.0, blue: 0.0) }
            if retention > 80 { return Color(red: 0.5, green: 0.0, blue: 0.0) }
            return Color(red: 0.6, green: 0.0, blue: 0.0)
        }
        if retention > 95 { return .green }
        if retention > 90 { return .yellow }
        if retention > 80 { return .orange }
        return .red
    }

    private var textColor: Color {
        isNightMode ? Color.red.opacity(0.8) : .secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("SNR")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(textColor)

            // Bar background + fill
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(isNightMode ? 0.15 : 0.2))
                    .frame(width: 60, height: 8)

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: CGFloat(max(0, min(retention, 100)) / 100.0) * 60, height: 8)
            }

            Text(String(format: "%.1f%%", retention))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
        }
    }
}

// MARK: - Culling Status View (replaces RDY bar)

/// Actionable culling status + autopilot button.
/// Shows how many trash frames remain, convergence state, and SNR warnings.
/// Click to open auto-mark popover with Conservative/Balanced/Aggressive options.
struct CullingStatusView: View {
    @ObservedObject var viewModel: TriageViewModel
    let isNightMode: Bool
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            if let status = viewModel.cullingStatus {
                Text(status.text)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(isNightMode ? .red.opacity(0.9) : status.color(isNightMode: false))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(status.color(isNightMode: isNightMode), lineWidth: 1.5)
                    )
            }
        }
        .buttonStyle(.plain)
        .help("Click for auto-mark options — Conservative (Nebula), Balanced, or Aggressive (Stars)")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            AutoMarkPopover(viewModel: viewModel, isPresented: $showPopover)
                .frame(width: 320)
        }
    }
}

/// Auto-mark popover with 3 modes: Conservative (Nebula), Balanced, Aggressive (Stars).
struct AutoMarkPopover: View {
    @ObservedObject var viewModel: TriageViewModel
    @Binding var isPresented: Bool
    @State private var showConvergenceWarning = false
    @State private var pendingOption: MarkOption?
    @State private var showSpread = false

    private struct MarkOption {
        let title: String
        let subtitle: String
        let count: Int
        let integrationLoss: String
        let color: Color
    }

    private var options: [MarkOption] {
        let images = viewModel.images
        let totalExposure = images.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }

        let conservativeTarget = images.filter { $0.qualityTier == .trash }
        let balancedTarget = images.filter {
            $0.qualityTier == .trash ||
            ($0.qualityTier == .borderline && ($0.qualityBreakdown?.borderlineSeverity ?? 0) >= 2)
        }
        let aggressiveTarget = images.filter {
            $0.qualityTier == .trash || $0.qualityTier == .borderline || $0.qualityTier == .uncertain ||
            // Weak-good: tier is .good but SNR contribution is < 30% of best frame.
            // These frames add negligible signal (<55% SNR of best) and degrade the stack.
            ($0.qualityTier == .good && ($0.qualityBreakdown?.snrContribution ?? 100) < 30)
        }

        let trashExp = conservativeTarget.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
        let balancedExp = balancedTarget.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
        let aggressiveExp = aggressiveTarget.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }

        func lossStr(_ exp: Double) -> String {
            guard totalExposure > 0 else { return "" }
            let pct = exp / totalExposure * 100
            let time = exp >= 3600 ? String(format: "%.1fh", exp / 3600) : String(format: "%.0fm", exp / 60)
            return "-\(time) (\(String(format: "%.0f", pct))%)"
        }

        return [
            MarkOption(title: "Conservative", subtitle: "Nebula — maximize integration time.\nOnly removes definite garbage.",
                       count: conservativeTarget.count, integrationLoss: lossStr(trashExp), color: .green),
            MarkOption(title: "Balanced", subtitle: "General use — removes garbage\n+ worst borderline frames.",
                       count: balancedTarget.count, integrationLoss: lossStr(balancedExp), color: .orange),
            MarkOption(title: "Aggressive", subtitle: "Stars/Galaxy — prioritize sharpness.\nRemoves questionable + weak frames (<30% SNR).",
                       count: aggressiveTarget.count, integrationLoss: lossStr(aggressiveExp), color: .red),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto-Mark for Deletion")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 2)

            // Convergence warning banner
            if let cr = viewModel.convergenceResult, (cr.isConverged || cr.snrStopReached) {
                convergenceWarningBanner(cr)
            }

            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(action: { handleOptionClick(option) }) {
                    autoMarkOptionRow(option)
                }
                .buttonStyle(.plain)
                .disabled(option.count == 0)
            }

            // Session spread section
            sessionSpreadSection
        }
        .padding(12)
        .alert("Diminishing Returns", isPresented: $showConvergenceWarning) {
            Button("Mark Anyway", role: .destructive) {
                if let option = pendingOption {
                    applyOption(option)
                    isPresented = false
                }
            }
            Button("Cancel", role: .cancel) { pendingOption = nil }
        } message: {
            if let cr = viewModel.convergenceResult {
                let spreadStr = String(format: "%.2f", cr.qualitySpread)
                let snrLoss = String(format: "%.1f", 100.0 - viewModel.snrRetention)
                if cr.isConverged {
                    Text("Remaining frames are already very uniform (spread: \(spreadStr)). Further culling loses integration time without meaningful quality improvement.\n\nSNR impact: -\(snrLoss)%")
                } else {
                    Text("You're losing more SNR (-\(snrLoss)%) than integration time. Consider keeping remaining frames to preserve signal depth.")
                }
            }
        }
    }

    // Convergence/SNR warning banner at top of popover
    private func convergenceWarningBanner(_ cr: ConvergenceResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: cr.isConverged ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(cr.isConverged ? .green : .yellow)
                .font(.system(size: 12))
            Text(cr.isConverged
                ? "Session is uniform — further culling has diminishing returns"
                : "SNR loss exceeds integration loss — consider stopping")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            cr.isConverged ? Color.green.opacity(0.1) : Color.yellow.opacity(0.1)
        ))
    }

    // Single option row
    private func autoMarkOptionRow(_ option: MarkOption) -> some View {
        HStack(spacing: 8) {
            Circle().fill(option.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(option.title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if option.count > 0 {
                        Text("\(option.count) frames  \(option.integrationLoss)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("nothing to mark")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Text(option.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    // Session spread: per-metric distribution info
    private var sessionSpreadSection: some View {
        DisclosureGroup("Session Spread", isExpanded: $showSpread) {
            VStack(alignment: .leading, spacing: 6) {
                let stats = computeMetricStats()
                ForEach(stats, id: \.name) { stat in
                    metricSpreadRow(stat)
                }

                if let cr = viewModel.convergenceResult {
                    Divider()
                    HStack {
                        Text("Overall spread:")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", cr.qualitySpread))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                        Text("— \(spreadLabel(cr.qualitySpread))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(spreadColor(cr.qualitySpread))
                    }
                    // Readiness bar
                    HStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.gray.opacity(0.2))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(readinessColor(cr.readinessPercent))
                                    .frame(width: geo.size.width * min(1, cr.readinessPercent / 100))
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int(cr.readinessPercent))% \(cr.readinessLabel)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11, weight: .medium))
    }

    // Single metric spread row with range bar
    private func metricSpreadRow(_ stat: MetricStat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(stat.name)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 45, alignment: .leading)
                Text(stat.minStr)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.15))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(spreadColor(stat.zSpread).opacity(0.6))
                    }
                }
                .frame(height: 6)
                Text(stat.maxStr)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
            }
            Text("spread: \(String(format: "%.2f", stat.zSpread)) (\(spreadLabel(stat.zSpread)))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(spreadColor(stat.zSpread))
                .padding(.leading, 47)
        }
    }

    // Handle option click — show warning if converged/SNR-stop
    private func handleOptionClick(_ option: MarkOption) {
        guard option.count > 0 else { return }

        // Check if convergence guard should trigger (only for Balanced/Aggressive)
        if option.title != "Conservative",
           let cr = viewModel.convergenceResult,
           (cr.isConverged || cr.snrStopReached) {
            pendingOption = option
            showConvergenceWarning = true
        } else {
            applyOption(option)
            isPresented = false
        }
    }

    private func applyOption(_ option: MarkOption) {
        let title = option.title
        for i in viewModel.images.indices {
            let entry = viewModel.images[i]

            let shouldMark: Bool
            if title == "Conservative" {
                shouldMark = entry.qualityTier == .trash
            } else if title == "Balanced" {
                shouldMark = entry.qualityTier == .trash ||
                    (entry.qualityTier == .borderline && (entry.qualityBreakdown?.borderlineSeverity ?? 0) >= 2)
            } else {
                // Aggressive: trash + borderline + uncertain + weak-good (<30% SNR contribution)
                shouldMark = entry.qualityTier == .trash || entry.qualityTier == .borderline || entry.qualityTier == .uncertain ||
                    (entry.qualityTier == .good && (entry.qualityBreakdown?.snrContribution ?? 100) < 30)
            }

            let isAutopilotEligible = entry.qualityTier == .trash || entry.qualityTier == .borderline || entry.qualityTier == .uncertain ||
                (entry.qualityTier == .good && (entry.qualityBreakdown?.snrContribution ?? 100) < 30)
            if shouldMark && !entry.isMarkedForDeletion {
                viewModel.images[i].isMarkedForDeletion = true
            } else if !shouldMark && entry.isMarkedForDeletion && isAutopilotEligible {
                viewModel.images[i].isMarkedForDeletion = false
            }
        }
        viewModel.needsTableRefresh = true
        viewModel.recomputeSNRRetention()
        viewModel.updateConvergence()
        viewModel.statusMessage = "Auto-marked \(option.count) frames (\(option.title))"
    }

    // MARK: - Metric Stats Computation

    private struct MetricStat: Identifiable {
        let name: String
        let minVal: Double
        let maxVal: Double
        let minStr: String
        let maxStr: String
        let zSpread: Double  // Std dev of z-scores for this metric
        var id: String { name }
    }

    private func computeMetricStats() -> [MetricStat] {
        let retained = viewModel.images.filter { !$0.isMarkedForDeletion && $0.qualityBreakdown != nil }
        guard retained.count >= 2 else { return [] }

        var stats: [MetricStat] = []

        // FWHM (from ImageEntry: fwhm or computedFWHM)
        let fwhms = retained.compactMap { $0.fwhm ?? $0.computedFWHM }
        if fwhms.count >= 2 {
            let zs = retained.compactMap { $0.qualityBreakdown?.fwhmZ }
            stats.append(MetricStat(
                name: "FWHM", minVal: fwhms.min()!, maxVal: fwhms.max()!,
                minStr: String(format: "%.1f\"", fwhms.min()!),
                maxStr: String(format: "%.1f\"", fwhms.max()!),
                zSpread: stdDev(zs)
            ))
        }

        // Stars (from ImageEntry: starCount or computedStarCount)
        let stars = retained.compactMap { ($0.starCount ?? $0.computedStarCount).map { Double($0) } }
        if stars.count >= 2 {
            let zs = retained.compactMap { $0.qualityBreakdown?.starsZ }
            stats.append(MetricStat(
                name: "Stars", minVal: stars.min()!, maxVal: stars.max()!,
                minStr: String(format: "%.0f", stars.min()!),
                maxStr: String(format: "%.0f", stars.max()!),
                zSpread: stdDev(zs)
            ))
        }

        // Noise (from ImageEntry: noiseMAD)
        let noises = retained.compactMap { $0.noiseMAD.map { Double($0) } }
        if noises.count >= 2 {
            let zs = retained.compactMap { $0.qualityBreakdown?.noiseZ }
            stats.append(MetricStat(
                name: "Noise", minVal: noises.min()!, maxVal: noises.max()!,
                minStr: String(format: "%.4f", noises.min()!),
                maxStr: String(format: "%.4f", noises.max()!),
                zSpread: stdDev(zs)
            ))
        }

        // Trailing (from ImageEntry: trailingScore)
        let trails = retained.compactMap { $0.trailingScore }
        if trails.count >= 2, trails.max()! > 0.01 {
            let zs = retained.compactMap { $0.qualityBreakdown?.trailingZ }
            stats.append(MetricStat(
                name: "Trail", minVal: trails.min()!, maxVal: trails.max()!,
                minStr: String(format: "%.2f", trails.min()!),
                maxStr: String(format: "%.2f", trails.max()!),
                zSpread: stdDev(zs)
            ))
        }

        return stats
    }

    private func stdDev(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }

    private func spreadLabel(_ spread: Double) -> String {
        if spread < 0.3 { return "tight" }
        if spread < 0.8 { return "normal" }
        return "wide"
    }

    private func spreadColor(_ spread: Double) -> Color {
        if spread < 0.3 { return .green }
        if spread < 0.8 { return .orange }
        return .red
    }

    private func readinessColor(_ pct: Double) -> Color {
        if pct >= 95 { return .green }
        if pct >= 80 { return .yellow }
        if pct >= 60 { return .orange }
        return .red
    }
}

// MARK: - AIsaac State Observer (extracted to reduce type-check complexity)

struct AIsaacStateObserver: ViewModifier {
    @ObservedObject var viewModel: TriageViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.isCaching) { isCaching in
                AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
                if !isCaching {
                    AIsaacWindowController.shared.updateContext(images: viewModel.images, viewModel: viewModel)
                    AIsaacWindowController.shared.model.detectLanguageFromLocation()
                }
            }
            .onChange(of: viewModel.cacheProgress) { progress in
                if progress > 0.99 || Int(progress * 10) > Int((progress - 0.1) * 10) {
                    AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
                }
            }
            .onChange(of: viewModel.images.count) { _ in
                AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
            }
            .onChange(of: viewModel.needsTableRefresh) { _ in
                AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
            }
    }
}
