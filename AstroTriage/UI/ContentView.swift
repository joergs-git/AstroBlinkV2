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
    @State private var showVlmAlphaWarning = false
    @State private var showTelemetryPopover = false
    @State private var telemetryPerformanceBenchmarks: Bool = AppSettings.defaults.bool(forKey: AppSettings.Key.telemetryPerformanceBenchmarks.rawValue)
    @State private var telemetryFrameQualityRatings: Bool = AppSettings.defaults.bool(forKey: AppSettings.Key.telemetryFrameQualityRatings.rawValue)
    @State private var telemetryCommunityBaselines: Bool = AppSettings.defaults.bool(forKey: AppSettings.Key.telemetryCommunityBaselines.rawValue)

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
                    Button("Cancel") {
                        viewModel.cancelVisualValidation()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
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
        .alert("ALPHA — Experimental Feature", isPresented: $showVlmAlphaWarning) {
            Button("Continue Anyway") {
                viewModel.startVisualValidation()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("VLM Check is an experimental thesis test.\n\nCurrent LLM vision models have not yet demonstrated sufficient accuracy for reliable detection of instrumental artifacts like ice, frost, or optical defects in astronomical sub-exposures.\n\nThis feature remains available for experimentation and further testing. Results should not be relied upon for culling decisions.")
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
                statusPill("AutoRotate", bg: viewModel.nightMode ? Color(red: 0.25, green: 0, blue: 0.15) : Color.purple.opacity(0.7))
                    .help("AutoRotate active — frames are aligned to the first image of each target for pixel-locked visual consistency (star-based, with 180\u{00B0} header flip fallback)")
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
            // Master state: green when ALL three sub-toggles on, dim-yellow when
            // partial, dim-grey when all off. The label tracks the same
            // tri-state so users immediately see at a glance how much they
            // share.
            let allOn = AppSettings.allTelemetryEnabled
            let allOff = AppSettings.noTelemetryEnabled
            let masterColor: Color = allOn
                ? (viewModel.nightMode ? .red : .green)
                : (allOff ? nightFgDim.opacity(0.4) : .orange.opacity(0.7))
            Button {
                // Sync popover @State from current persisted values before showing,
                // in case another window or iCloud sync changed them since launch.
                telemetryPerformanceBenchmarks = AppSettings.defaults.bool(forKey: AppSettings.Key.telemetryPerformanceBenchmarks.rawValue)
                telemetryFrameQualityRatings = AppSettings.defaults.bool(forKey: AppSettings.Key.telemetryFrameQualityRatings.rawValue)
                telemetryCommunityBaselines = AppSettings.defaults.bool(forKey: AppSettings.Key.telemetryCommunityBaselines.rawValue)
                showTelemetryPopover = true
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 10))
                        .foregroundColor(masterColor)
                    Text("Community")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(allOff ? nightFgDim.opacity(0.4) : nightFgDim.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .help(allOn
                ? "Community Learning is ON for all categories. Click to manage individual telemetry types."
                : (allOff
                    ? "Community Learning is OFF for all categories. Click to manage."
                    : "Community Learning is ON for some categories. Click to manage."))
            .popover(isPresented: $showTelemetryPopover, arrowEdge: .bottom) {
                telemetryPopover
            }

            // Side-by-side info button → opens the full PRIVACY.md on GitHub.
            // Lives outside the toggle's tap-area so curiosity clicks don't flip
            // Community Learning by accident.
            Button {
                if let url = URL(string: "https://github.com/joergs-git/AstroBlinkV2/blob/main/PRIVACY.md") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(nightFgDim.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Open the full Privacy Policy (PRIVACY.md) on GitHub")

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

    /// Popover presented when the status-bar Community indicator is clicked.
    /// Three independent toggles plus an "All on / All off" master row at the
    /// top for the common case. Persists each change to AppSettings (and the
    /// iCloud key-value store via `AppSettings.save`) immediately.
    private var telemetryPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Community Learning")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    if let url = URL(string: "https://github.com/joergs-git/AstroBlinkV2/blob/main/PRIVACY.md") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "info.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Open PRIVACY.md on GitHub")
            }

            Text("Anonymous, opt-in by default. No filenames, no images, no real names. Identifier is a non-reversible hardware hash. Toggle each category independently.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            telemetryToggleRow(
                isOn: $telemetryPerformanceBenchmarks,
                key: .telemetryPerformanceBenchmarks,
                title: "Performance Benchmarks",
                detail: "Anonymous hardware specs (chip, cores, RAM) and timing for stacking + session-load benchmarks. Powers the leaderboard.")

            telemetryToggleRow(
                isOn: $telemetryFrameQualityRatings,
                key: .telemetryFrameQualityRatings,
                title: "Frame Quality Ratings",
                detail: "Equipment + target metadata (telescope, camera, filter, target, date) sent with each star rating. Trains future detection improvements.")

            telemetryToggleRow(
                isOn: $telemetryCommunityBaselines,
                key: .telemetryCommunityBaselines,
                title: "Community Baselines",
                detail: "Aggregate-only quality metrics for community calibration. Lets you skip the 30-frame learning phase when trying new equipment.")

            Divider()

            HStack {
                Button("Disable all") {
                    telemetryPerformanceBenchmarks = false
                    telemetryFrameQualityRatings = false
                    telemetryCommunityBaselines = false
                    AppSettings.setAllTelemetry(false)
                    viewModel.objectWillChange.send()
                }
                Spacer()
                Button("Enable all") {
                    telemetryPerformanceBenchmarks = true
                    telemetryFrameQualityRatings = true
                    telemetryCommunityBaselines = true
                    AppSettings.setAllTelemetry(true)
                    viewModel.objectWillChange.send()
                }
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 360)
    }

    /// One row of the telemetry popover: checkbox + bold title + 2-line detail.
    /// Persists immediately on toggle so closing the popover isn't required to
    /// commit the change.
    private func telemetryToggleRow(
        isOn: Binding<Bool>,
        key: AppSettings.Key,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { newValue in
                    AppSettings.save(newValue, for: key)
                    viewModel.objectWillChange.send()
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Full toolbar: buttons row + separator + sliders row
    private var toolbarArea: some View {
        VStack(spacing: 2) {
            toolbarButtonsRow
                .padding(.top, 5)
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
                .padding(.leading, 4)
            sfToolbarButton("list.bullet.rectangle", "Inspector", "Show FITS/XISF header keywords for selected image (I)") { viewModel.toggleHeaderInspector() }
            sfToolbarButton("chart.bar", "Session", "Session overview — group stats by filter, night, and target") {
                viewModel.showSessionOverview.toggle()
                // Persist across sessions & iCloud so hiding the panel sticks.
                AppSettings.saveBool(viewModel.showSessionOverview, for: .showSessionOverviewPanel)
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
            sfToolbarButton("tablecells", "VLM\nCheck",
                "ALPHA — Generate mosaic for AI anomaly detection.\nHighlighted files: uses selection (any status).\nNo selection: uses all unmarked frames.",
                iconColor: .gray.opacity(0.5)) {
                showVlmAlphaWarning = true
            }
            autoMarkToolbarButton
            aisaacToolbarButton
            sfToolbarButton("square.and.arrow.up", "SSWEIGHT\nExport",
                "Export quality weights to FITS/XISF headers for WBPP.\nOperates on highlighted files (or all if none selected).\nAlso creates CSV backup.\nUse Batch Rename to remove SSWEIGHT keywords.") {
                viewModel.exportSSWEIGHT()
            }
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

    // Display toggles: Apply All, Debayer, Lock STF, AutoRotate
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
                Toggle("Auto\nRotate", isOn: Binding(
                    get: { viewModel.autoMeridianEnabled },
                    set: { _ in viewModel.toggleAutoMeridian() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.purple)
                .help("AutoRotate: star-based visual alignment keeps all frames pixel-locked to the first image of each target. Handles meridian flips, dithers, and pointing offsets. Falls back to 180° header flip when star matching fails.")
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
            .help(viewModel.isPlaying ? "Stop blink (ESC or P)" : "Blink through images (P key, selected or all)")

            Picker("", selection: $viewModel.playbackDelay) {
                Text("0.05s").tag(0.05)
                Text("0.1s").tag(0.1)
                Text("0.2s").tag(0.2)
                Text("0.5s").tag(0.5)
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
            }
            .pickerStyle(.menu)
            .frame(width: 72)
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
                Image(systemName: "flag.checkered")
                    .font(.system(size: 24, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.purple, .white)
                    .shadow(color: .white.opacity(0.6), radius: 3)
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
                    // AIsaac Newton icon
                    Image("AIsaacIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .foregroundColor(.purple)
                        .shadow(color: .white.opacity(0.6), radius: 3)

                    // Subtle pulse overlay (no blur/glow — just gentle scale)
                    Image("AIsaacIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .foregroundColor(.purple)
                        .opacity(aisaacGlow ? 0.4 : 0.0)
                        .scaleEffect(aisaacGlow ? 1.15 : 1.0)
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

