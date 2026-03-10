// v3.2.0
import SwiftUI

// Root view: toolbar on top, optional side panels (inspector left, session right),
// image viewer + file list in center, status bar at bottom.
// Supports night mode (N key): black background + red UI for dark-adapted vision.
struct ContentView: View {
    @StateObject private var viewModel = TriageViewModel()
    @State private var renderer: MetalRenderer?
    @State private var keyboardMonitor: Any?
    @State private var sliderValue: Double = 0.25  // Local slider state, synced on navigation

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
                HStack(spacing: 0) {
                    sfToolbarButton("folder", "Open", "Open Folder (⌘O)") { viewModel.openFolder() }
                    sfToolbarButton("list.bullet.rectangle", "Inspector", "Header Inspector (I)") { viewModel.toggleHeaderInspector() }
                    sfToolbarButton("chart.bar", "Session", "Session Overview") {
                        viewModel.showSessionOverview.toggle()
                    }
                    sfToolbarButton("trash", "Delete", "Pre-Delete Marked (⌘⌫)") { viewModel.moveMarkedToPreDelete() }
                    if viewModel.canUndoPreDelete {
                        sfToolbarButton("arrow.uturn.backward", "Undo", "Undo last Pre-Delete (⌘Z)") { viewModel.undoPreDelete() }
                    }
                    sfToolbarButton("square.3.layers.3d.down.right", "QuickStack", "Quick Stack selected images (select 3+)") {
                        viewModel.startQuickStack()
                    }
                    toolbarDivider

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

                    // Apply All toggle: bakes current settings into all cached previews
                    VStack(spacing: 2) {
                        Toggle("Apply All", isOn: Binding(
                            get: { viewModel.applyAllEnabled },
                            set: { _ in viewModel.toggleApplyAll() }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(.blue)
                        .help("Apply current settings to all cached previews")
                    }
                    .frame(width: 95)

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

                    toolbarDivider

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

                    Spacer()

                    // System stats — stacked vertically, readable size
                    if let stats = viewModel.systemStats {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(stats.memory)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(nightFgDim)
                            Text(stats.cpu)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(nightFgDim)
                        }
                        .help("App memory / CPU usage")
                        .padding(.trailing, 4)
                    }

                    // Night mode toggle — right side near Help/About
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

                    toolbarDivider

                    sfToolbarButton("questionmark.circle", "Help", "Help (⌘?)") { HelpWindowController.shared.showWindow(nil) }
                    sfToolbarButton("info.circle", "About", "About") { AstroBlinkV2AppDelegate.showAboutPanel() }
                }

                // Row 2: Reset button + all sliders in a single horizontal strip
                HStack(spacing: 12) {
                    // Reset all sliders to defaults
                    Button(action: {
                        viewModel.resetSlidersToDefaults()
                        sliderValue = Double(viewModel.stretchStrength)
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
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

                    // Auto Meridian toggle — always visible, rotates images across meridian flip
                    VStack(spacing: 2) {
                        Toggle("MeridianFlip", isOn: Binding(
                            get: { viewModel.autoMeridianEnabled },
                            set: { _ in viewModel.toggleAutoMeridian() }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(.purple)
                        .help("Auto-rotate images across meridian flip for consistent orientation")
                    }
                    .frame(width: 120)

                    Spacer()
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 4)
            .background(nightToolbarBg)

            Rectangle().fill(nightDivider).frame(height: 1)

            // Main content area with optional side panels
            HStack(spacing: 0) {
                // LEFT: Header Inspector panel
                if viewModel.showInspector {
                    HeaderInspectorContentView(model: viewModel.headerInspectorModel)
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
                            if viewModel.showQuickStack, let engine = viewModel.quickStackEngine {
                                VStack {
                                    HStack {
                                        Spacer()
                                        QuickStackProgressView(
                                            engine: engine,
                                            nightMode: viewModel.nightMode,
                                            onDismiss: {
                                                viewModel.showQuickStack = false
                                                viewModel.quickStackEngine?.cancel()
                                            }
                                        )
                                        .padding(12)
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

                    // Pre-cache progress bar with stop/continue controls
                    if viewModel.isCaching || viewModel.cachingStopped {
                        HStack(spacing: 8) {
                            if viewModel.isCaching {
                                VStack(spacing: 2) {
                                    ProgressView(value: viewModel.cacheProgress)
                                        .progressViewStyle(.linear)
                                        .tint(viewModel.nightMode ? .red : nil)

                                    Text("Pre-caching \(viewModel.cachingCount)/\(viewModel.cachingTotal) images...")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(nightFgDim)
                                }
                            } else {
                                Text("Caching paused — \(viewModel.prefetchCachedCount)/\(viewModel.images.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(nightFgDim)
                            }

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
                        .padding(.vertical, 4)
                        .background(nightControlBg)
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
                        }

                        // Hiding pill
                        if viewModel.hideMarked {
                            statusPill("Hiding", bg: viewModel.nightMode
                                ? Color(red: 0.3, green: 0, blue: 0)
                                : Color(red: 0.15, green: 0.55, blue: 0.55))
                        }

                        // Show only marked pill (inverted view)
                        if viewModel.showOnlyMarked {
                            statusPill("Only Marked", bg: viewModel.nightMode
                                ? Color(red: 0.35, green: 0, blue: 0)
                                : Color(red: 0.7, green: 0.4, blue: 0.1))
                        }

                        // Lock STF pill
                        if viewModel.isSTFLocked {
                            statusPill("Locked STF", bg: viewModel.nightMode
                                ? Color(red: 0.35, green: 0.15, blue: 0)
                                : Color.orange.opacity(0.85))
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
                        }

                        // Skip pill
                        if viewModel.skipMarked {
                            statusPill("Skip", bg: viewModel.nightMode
                                ? Color(red: 0.3, green: 0, blue: 0)
                                : Color(red: 0.75, green: 0.55, blue: 0.15))
                        }

                        // Night pill
                        if viewModel.nightMode {
                            statusPill("Night", bg: Color(red: 0.35, green: 0, blue: 0))
                        }

                        // Debayer pill — only shown when session has OSC images
                        if viewModel.debayerEnabled && viewModel.hasOSCImages {
                            statusPill("Debayer", bg: viewModel.nightMode
                                ? Color(red: 0.3, green: 0, blue: 0)
                                : Color(red: 0.15, green: 0.5, blue: 0.25))
                        }

                        // Auto Meridian pill — shows when active and session has meridian flip
                        if viewModel.autoMeridianEnabled && viewModel.hasMeridianFlip {
                            statusPill("MeridianFlip", bg: viewModel.nightMode
                                ? Color(red: 0.25, green: 0, blue: 0.15)
                                : Color.purple.opacity(0.7))
                        }

                        Spacer()

                        // RIGHT SIDE: dimensions, filter, status
                        if let image = viewModel.selectedImage {
                            if let w = image.width, let h = image.height {
                                Text("\(w)x\(h)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(nightFgDim)
                            }

                            if let filter = image.filter {
                                statusDivider
                                Text(filter)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(nightFgDim)
                            }
                        }

                        statusDivider

                        Text(viewModel.statusMessage)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(nightFgDim)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(nightBg)
                }

                // RIGHT: Session Overview panel
                if viewModel.showSessionOverview {
                    Rectangle().fill(nightDivider).frame(width: 1)

                    SessionOverviewContentView(model: viewModel.sessionOverviewModel)
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
        .onDisappear {
            KeyboardHandler.remove(monitor: keyboardMonitor)
        }
        .onChange(of: renderer) { newRenderer in
            viewModel.renderer = newRenderer
        }
        .onChange(of: viewModel.stretchStrength) { newValue in
            sliderValue = Double(newValue)
        }
        .navigationTitle("AstroBlinkV2 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") — Fast Visual Culling for Astrophotography")
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
    private func sfToolbarButton(_ symbol: String, _ label: String, _ tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(nightFg)
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(nightFgDim)
            }
            .frame(width: 56, height: 42)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .contentShape(Rectangle())
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
