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
        VStack(spacing: 0) {
            // Path bar: shows current session directory with Open button
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

            // Toolbar row — two lines: buttons on top, sliders below
            VStack(spacing: 2) {
                // Row 1: Icon buttons + toggles + stats
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

                    toolbarDivider

                    // ── Group 2: Actions ──
                    autoMarkToolbarButton
                    aisaacToolbarButton
                    sfToolbarButton("square.and.arrow.up", "SSWEIGHT\nExport", "Export quality weights to FITS/XISF headers for WBPP.\nAlso creates CSV backup.") {
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

                    // ── Group 4: Display settings ──
                    // Apply All toggle: bakes current settings into all cached previews
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

                    // Debayer toggle
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

                    // Lock STF toggle: freezes exact c0/mb from current image for all
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

                    // Auto Meridian toggle — rotates images across meridian flip
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

                    toolbarDivider

                    // ── Group 5: Search ──
                    // Spotlight-style search: filters file list in real time
                    // Supports plain text or "column:value" (e.g. "filter:Ha", "fwhm:>4")
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
                            // Match count
                            Text("\(viewModel.visibleImages.count)/\(viewModel.images.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(nightFgDim)

                            // Mark all filtered
                            Button(action: { viewModel.markFilteredImages() }) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(viewModel.nightMode ? .red : .accentColor)
                            .help("Mark all filtered images")

                            // Unmark all filtered
                            Button(action: { viewModel.unmarkFilteredImages() }) {
                                Image(systemName: "circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(viewModel.nightMode ? .red : .secondary)
                            .help("Unmark all filtered images")

                            // Clear search
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

                    // Filter presets dropdown
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

                    Spacer()

                    // ── Right side: Night, Benchmark, Help ──
                    // Night mode toggle
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
                .padding(.bottom, 2)

                // Thin separator between toolbar icons and image settings
                Rectangle().fill(nightDivider).frame(height: 1)

                // Row 2: Image settings — centered with the image frame below
                HStack(spacing: 12) {
                    Spacer()

                    // Reset all sliders to defaults
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

                    // Gradient removal toggle
                    Button(action: { viewModel.toggleGradientRemoval() }) {
                        Text("GBE")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(viewModel.gradientRemovalEnabled ? .cyan : nightFg.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Gradient Background Extraction — quick preview (re-decodes current image)")

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
            .background(nightToolbarBg)

            Rectangle().fill(nightDivider).frame(height: 1)

            // In-app message banner (fetched from Supabase)
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

            // Main content area with optional side panels
            HStack(spacing: 0) {
                // LEFT: Header Inspector panel
                if viewModel.showInspector {
                    HeaderInspectorContentView(model: viewModel.headerInspectorModel)
                        .environment(\.fontScale, viewModel.fontScale)
                        .frame(width: 420)
                        .background(nightBg)

                    Rectangle().fill(nightDivider).frame(width: 1)
                }

                // CENTER: Image viewer + file list + status bars
                VStack(spacing: 0) {
                    VSplitView {
                        // Top: Image viewer with optional caching overlay
                        ZStack(alignment: .center) {
                            ImageViewerView(viewModel: viewModel, renderer: $renderer)

                            // Show "still caching" text when current image has no cached preview
                            if viewModel.isCaching,
                               let image = viewModel.selectedImage,
                               !viewModel.isImageCached(image.url),
                               viewModel.currentDecodedImage == nil {
                                Text("Caching this image...")
                                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                                    .foregroundColor(viewModel.nightMode ? .red.opacity(0.8) : .white.opacity(0.8))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.black.opacity(0.6))
                                    )
                            }

                            // Quick Stack progress overlay (anchored top-right)
                            if viewModel.showQuickStackV2, let engine = viewModel.quickStackEngineV2 {
                                VStack {
                                    HStack {
                                        Spacer()
                                        QuickStackV2ProgressView(
                                            engine: engine,
                                            nightMode: viewModel.nightMode,
                                            onDismiss: {
                                                viewModel.showQuickStackV2 = false
                                                viewModel.quickStackEngineV2?.cancel()
                                            }
                                        )
                                        .padding(12)
                                    }
                                    Spacer()
                                }
                            }

                            // Color Combine setup overlay (anchored top-right)
                            if viewModel.showColorCombine, let engine = viewModel.colorCombineEngine {
                                VStack {
                                    HStack {
                                        Spacer()
                                        ColorCombineSetupView(
                                            engine: engine,
                                            nightMode: viewModel.nightMode,
                                            onDismiss: {
                                                viewModel.showColorCombine = false
                                                viewModel.colorCombineEngine?.cancel()
                                            },
                                            debayerEnabled: viewModel.debayerEnabled
                                        )
                                        .padding(12)
                                    }
                                    Spacer()
                                }
                            }

                            // AIsaac collapsed teaser bar — always visible unless dismissed
                            if !aisaacTeaserDismissed {
                                VStack {
                                    HStack {
                                        Spacer()
                                        aisaacTeaserBar
                                            .padding(.top, 8)
                                            .padding(.trailing, 12)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .frame(minHeight: 200)

                        // Bottom: File list with loading overlay
                        ZStack {
                            FileListView(viewModel: viewModel)

                            // Centered progress overlay during header reading
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
                                        .fill(viewModel.nightMode
                                              ? Color.black.opacity(0.9)
                                              : Color(NSColor.windowBackgroundColor).opacity(0.95))
                                        .shadow(radius: 8)
                                )
                            }
                        }
                        .frame(minHeight: 150, idealHeight: 250)
                    }

                    // Red fuel bar: shows during loading phases, NAS download, or caching
                    if viewModel.loadingPhase != .none || viewModel.isDownloading || viewModel.isCaching || viewModel.cachingStopped {
                        HStack(spacing: 6) {
                            VStack(spacing: 1) {
                                // Top bar: pre-caching (only when both download + cache are active, or cache-only)
                                if viewModel.isCaching || viewModel.cachingStopped {
                                    fuelBar(
                                        progress: viewModel.cacheProgress,
                                        label: {
                                            if viewModel.isCaching {
                                                let est = viewModel.cachingEstimatedSecondsRemaining.map { " — Est: \($0)s" } ?? ""
                                                return "Analyzing \(viewModel.cachingCount)/\(viewModel.cachingTotal)\(est)"
                                            } else {
                                                return "Caching paused — \(viewModel.prefetchCachedCount)/\(viewModel.images.count)"
                                            }
                                        }(),
                                        color: Color(red: 0.25, green: 0.5, blue: 0.9),
                                        height: (viewModel.isDownloading) ? 11 : 22,
                                        isNight: viewModel.nightMode
                                    )
                                }

                                // Bottom bar: download or loading phase
                                if viewModel.isDownloading {
                                    fuelBar(
                                        progress: viewModel.downloadProgress,
                                        label: {
                                            let est = viewModel.downloadEstimatedSecondsRemaining.map { " — Est: \($0)s" } ?? ""
                                            return "Downloading \(viewModel.downloadCount)/\(viewModel.downloadTotal)\(est)"
                                        }(),
                                        color: Color(red: 0.15, green: 0.35, blue: 0.7),
                                        height: viewModel.isCaching ? 11 : 22,
                                        isNight: viewModel.nightMode
                                    )
                                } else if viewModel.loadingPhase == .scanning {
                                    fuelBar(progress: 0, label: "Scanning folder...", color: Color(red: 0.15, green: 0.35, blue: 0.7), height: 22, isNight: viewModel.nightMode)
                                } else if viewModel.loadingPhase == .readingHeaders {
                                    fuelBar(
                                        progress: viewModel.headerProgress,
                                        label: {
                                            let est = viewModel.headerEstimatedSecondsRemaining.map { " — Est: \($0)s" } ?? ""
                                            return "Loading headers \(viewModel.headerReadCount)/\(viewModel.headerReadTotal)\(est)"
                                        }(),
                                        color: Color(red: 0.15, green: 0.35, blue: 0.7),
                                        height: 22,
                                        isNight: viewModel.nightMode
                                    )
                                }
                            }
                            .cornerRadius(3)

                            // Stop / Continue buttons
                            if viewModel.isCaching {
                                Button(action: { viewModel.stopCaching() }) {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(viewModel.nightMode ? .red : nil)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Stop caching")
                            }
                            if viewModel.cachingStopped {
                                Button(action: { viewModel.continueCaching() }) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(viewModel.nightMode ? .red : nil)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Continue caching")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(nightBg)
                    }

                    // Status bar: LEFT = styled pills, RIGHT = dimensions + status
                    HStack(spacing: 6) {
                        // Marked count — always visible, includes total
                        if !viewModel.images.isEmpty {
                            statusPill(
                                "\(viewModel.markedCount) of \(viewModel.images.count) marked",
                                bg: viewModel.markedCount > 0
                                    ? (viewModel.nightMode ? Color(red: 0.4, green: 0, blue: 0) : Color(red: 0.8, green: 0.25, blue: 0.25))
                                    : (viewModel.nightMode ? Color(red: 0.15, green: 0, blue: 0) : Color(white: 0.35))
                            )
                            .help("Frames marked for deletion (Space to toggle, Cmd+Backspace to move to PRE-DELETE)")
                        }

                        // Hiding pill
                        if viewModel.hideMarked {
                            statusPill("Hiding", bg: viewModel.nightMode
                                ? Color(red: 0.3, green: 0, blue: 0)
                                : Color(red: 0.15, green: 0.55, blue: 0.55))
                            .help("Marked frames are hidden from the file list (H to toggle)")
                        }

                        // Show only marked pill (inverted view)
                        if viewModel.showOnlyMarked {
                            statusPill("Only Marked", bg: viewModel.nightMode
                                ? Color(red: 0.35, green: 0, blue: 0)
                                : Color(red: 0.7, green: 0.4, blue: 0.1))
                            .help("Showing only marked frames — review before deleting (Shift+H to toggle)")
                        }

                        // Lock STF pill
                        if viewModel.isSTFLocked {
                            statusPill("Locked STF", bg: viewModel.nightMode
                                ? Color(red: 0.35, green: 0.15, blue: 0)
                                : Color.orange.opacity(0.85))
                            .help("Stretch is locked to current image's parameters — all images use the same brightness mapping for direct comparison (S to toggle)")
                        }

                        // Apply All pill
                        if viewModel.applyAllEnabled {
                            statusPill(
                                viewModel.cacheMatchesCurrentSettings ? "Applied" : "Applying...",
                                bg: viewModel.nightMode
                                    ? Color(red: 0, green: 0, blue: 0.3)
                                    : (viewModel.cacheMatchesCurrentSettings
                                        ? Color.blue.opacity(0.7)
                                        : Color.blue.opacity(0.5))
                            )
                            .help("Current stretch/sharp/contrast/dark settings are baked into all cached previews for consistent comparison")
                        }

                        // Skip pill
                        if viewModel.skipMarked {
                            statusPill("Skip", bg: viewModel.nightMode
                                ? Color(red: 0.3, green: 0, blue: 0)
                                : Color(red: 0.75, green: 0.55, blue: 0.15))
                            .help("Arrow keys skip over marked frames — navigate only unmarked images (K to toggle)")
                        }

                        // Night pill
                        if viewModel.nightMode {
                            statusPill("Night", bg: Color(red: 0.35, green: 0, blue: 0))
                            .help("Night mode — red-only UI to preserve dark-adapted vision at the telescope (N to toggle)")
                        }

                        // Debayer pill — only shown when session has OSC images
                        if viewModel.debayerEnabled && viewModel.hasOSCImages {
                            statusPill("Debayer", bg: viewModel.nightMode
                                ? Color(red: 0.3, green: 0, blue: 0)
                                : Color(red: 0.15, green: 0.5, blue: 0.25))
                            .help("Color debayering active — one-shot-color (OSC) images shown in RGB instead of mono (D to toggle)")
                        }

                        // Auto Meridian pill — shows when active and session has meridian flip
                        if viewModel.autoMeridianEnabled && viewModel.hasMeridianFlip {
                            statusPill("MeridianFlip", bg: viewModel.nightMode
                                ? Color(red: 0.25, green: 0, blue: 0.15)
                                : Color.purple.opacity(0.7))
                            .help("Meridian flip detected — images from the opposite pier side are rotated 180\u{00B0} for consistent orientation")
                        }

                        Spacer()

                        // RIGHT SIDE: cache/file stats, SNR retention, status

                        // Cache and file size info
                        if !viewModel.images.isEmpty {
                            statusDivider
                            Text("\(viewModel.prefetchCachedCount) cached (\(formatBytes(viewModel.cacheMemoryBytes))) — Raw: \(formatBytes(viewModel.totalRawFileSize))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(nightFgDim)
                        }

                        // Selection count (only when >1 highlighted)
                        if viewModel.selectedTableIndices.count > 1 {
                            statusDivider
                            Text("\(viewModel.selectedTableIndices.count) selected")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(nightFgDim)
                        }

                        // Live SNR retention bar — shows when frames are marked
                        if viewModel.snrRetention < 99.95 && !viewModel.images.isEmpty {
                            statusDivider
                            SNRRetentionBarView(retention: viewModel.snrRetention, isNightMode: viewModel.nightMode)
                                .help(viewModel.snrRetentionDetail)
                        }

                        // Culling status — actionable text + autopilot button
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

                        // Community learning toggle (clickable icon)
                        statusDivider
                        let communityEnabled = AppSettings.defaults.bool(forKey: AppSettings.Key.communityLearning.rawValue)
                        HStack(spacing: 2) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 10))
                                .foregroundColor(communityEnabled
                                    ? (viewModel.nightMode ? .red : .green)
                                    : nightFgDim.opacity(0.4))
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

                        // iCloud sync indicator (rightmost, always visible)
                        statusDivider
                        HStack(spacing: 2) {
                            if FileManager.default.ubiquityIdentityToken != nil {
                                Image(systemName: "checkmark.icloud")
                                    .font(.system(size: 10))
                                    .foregroundColor(viewModel.nightMode ? .red : .green)
                                Text("iCloud")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(nightFgDim.opacity(0.6))
                            } else {
                                Image(systemName: "xmark.icloud")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red.opacity(0.7))
                                Text("iCloud")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(nightFgDim.opacity(0.4))
                            }
                        }
                        .help(FileManager.default.ubiquityIdentityToken != nil
                            ? "iCloud is ON — Your settings, calibration profiles, and equipment memory sync privately across your Macs. All data stays in your personal iCloud account — nothing is shared publicly or with other users."
                            : "iCloud is OFF — Settings and calibration data are stored locally only. Sign in to iCloud in System Settings to sync across your Macs. iCloud data is always private — never shared with anyone.")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(nightBg)
                }

                // RIGHT: Session Overview panel
                if viewModel.showSessionOverview {
                    Rectangle().fill(nightDivider).frame(width: 1)

                    SessionOverviewContentView(model: viewModel.sessionOverviewModel)
                        .environment(\.fontScale, viewModel.fontScale)
                        .frame(width: 480)
                        .background(nightBg)
                }
            }
        }
        .background(nightBg)
        .preferredColorScheme(viewModel.nightMode ? .dark : nil)
        .onChange(of: viewModel.nightMode) { isNight in
            // Force NSWindow appearance update for AppKit views (NSTableView, scrollbars, etc.)
            if let window = NSApp.keyWindow {
                window.appearance = isNight
                    ? NSAppearance(named: .darkAqua)
                    : nil  // nil = follow system
                window.invalidateShadow()
                window.contentView?.needsDisplay = true
            }
        }
        .onAppear {
            keyboardMonitor = KeyboardHandler.install(viewModel: viewModel)
            wireAIsaacCallbacks(viewModel: viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBatchRename)) { _ in
            BatchRenameWindowController.shared.show(viewModel: viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBenchmarkStats)) { _ in
            BenchmarkStatsWindowController.shared.show(stats: viewModel.benchmarkStats, sessionRootURL: viewModel.sessionRootURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAIsaac)) { _ in
            AIsaacWindowController.shared.updateContext(images: viewModel.images, viewModel: viewModel)
            AIsaacWindowController.shared.toggleWindow()
        }
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
        // AIsaac state observers extracted to reduce type-check pressure
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
    }

    // MARK: - Toolbar Helpers

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

    // AIsaac collapsed teaser bar
    @State private var aisaacTeaserDismissed: Bool = false

    // AIsaac collapsed teaser bar — floating pill that opens the full chat window
    @State private var teaserGlow: Bool = false
    private var aisaacTeaserBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.purple)
                .opacity(teaserGlow ? 0.9 : 0.5)
                .scaleEffect(teaserGlow ? 1.15 : 1.0)

            Text("I am AIsaac — ask me about your stars")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))

            // Dismiss button
            Button(action: { withAnimation(.easeOut(duration: 0.3)) { aisaacTeaserDismissed = true } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Dismiss — reopen via Ask AIsaac button")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.20, green: 0.05, blue: 0.35).opacity(0.85),
                            Color(red: 0.10, green: 0.02, blue: 0.20).opacity(0.85)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .shadow(color: .purple.opacity(teaserGlow ? 0.5 : 0.2), radius: teaserGlow ? 8 : 4)
        )
        .onTapGesture {
            AIsaacWindowController.shared.updateContext(images: viewModel.images, viewModel: viewModel)
            AIsaacWindowController.shared.toggleWindow()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                teaserGlow = true
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
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

    // Wire AIsaac app control callbacks (extracted to reduce body complexity)
    private func wireAIsaacCallbacks(viewModel: TriageViewModel) {
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

        // Count what each level WOULD mark (total target state, not delta)
        let conservativeTarget = images.filter { $0.qualityTier == .trash }
        let balancedTarget = images.filter {
            $0.qualityTier == .trash ||
            ($0.qualityTier == .borderline && ($0.qualityBreakdown?.borderlineSeverity ?? 0) >= 2)
        }
        let aggressiveTarget = images.filter {
            $0.qualityTier == .trash || $0.qualityTier == .borderline || $0.qualityTier == .uncertain
        }

        let currentlyMarked = images.filter { $0.isMarkedForDeletion }.count
        let trashExp = conservativeTarget.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
        let balancedExp = balancedTarget.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
        let aggressiveExp = aggressiveTarget.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }

        // Show target count — user sees what the result will be
        let trashOnly = conservativeTarget
        let balanced = balancedTarget
        let aggressive = aggressiveTarget

        func lossStr(_ exp: Double) -> String {
            guard totalExposure > 0 else { return "" }
            let pct = exp / totalExposure * 100
            let time = exp >= 3600 ? String(format: "%.1fh", exp / 3600) : String(format: "%.0fm", exp / 60)
            return "-\(time) (\(String(format: "%.0f", pct))%)"
        }

        return [
            MarkOption(title: "Conservative", subtitle: "Nebula — maximize integration time.\nOnly removes definite garbage.",
                       count: trashOnly.count, integrationLoss: lossStr(trashExp), color: .green),
            MarkOption(title: "Balanced", subtitle: "General use — removes garbage\n+ worst borderline frames.",
                       count: balanced.count, integrationLoss: lossStr(balancedExp), color: .orange),
            MarkOption(title: "Aggressive", subtitle: "Stars/Galaxy — prioritize sharpness.\nRemoves all questionable frames.",
                       count: aggressive.count, integrationLoss: lossStr(aggressiveExp), color: .red),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto-Mark for Deletion")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 2)

            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(action: {
                    applyOption(option)
                    isPresented = false
                }) {
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
                .buttonStyle(.plain)
                .disabled(option.count == 0)
            }
        }
        .padding(12)
    }

    private func applyOption(_ option: MarkOption) {
        let title = option.title
        for i in viewModel.images.indices {
            let entry = viewModel.images[i]

            // Determine if this frame SHOULD be marked at this autopilot level
            let shouldMark: Bool
            if title == "Conservative" {
                shouldMark = entry.qualityTier == .trash
            } else if title == "Balanced" {
                shouldMark = entry.qualityTier == .trash ||
                    (entry.qualityTier == .borderline && (entry.qualityBreakdown?.borderlineSeverity ?? 0) >= 2)
            } else {
                // Aggressive: trash + borderline + uncertain
                shouldMark = entry.qualityTier == .trash || entry.qualityTier == .borderline || entry.qualityTier == .uncertain
            }

            // Bidirectional: mark what should be marked, UNMARK what shouldn't
            // (only unmark autopilot-eligible frames — don't touch manually marked excellent/good)
            let isAutopilotEligible = entry.qualityTier == .trash || entry.qualityTier == .borderline || entry.qualityTier == .uncertain
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
