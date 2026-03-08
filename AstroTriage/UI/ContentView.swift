// v2.0.0
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
    private var nightFg: Color { viewModel.nightMode ? .red : .secondary }
    private var nightBg: Color { viewModel.nightMode ? .black : Color(NSColor.windowBackgroundColor) }
    private var nightControlBg: Color { viewModel.nightMode ? Color(red: 0.08, green: 0, blue: 0) : Color(NSColor.controlBackgroundColor) }
    private var nightAccent: Color { viewModel.nightMode ? .red : .orange }
    private var nightDivider: Color { viewModel.nightMode ? Color(red: 0.3, green: 0, blue: 0) : Color(NSColor.separatorColor) }

    // Thin vertical divider for status bar separation
    private var statusDivider: some View {
        Text("|")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(nightFg.opacity(0.5))
            .padding(.horizontal, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Emoji toolbar row — large icons with tiny labels
            HStack(spacing: 0) {
                toolbarButton("📂", "Open", "Open Folder (⌘O)") { viewModel.openFolder() }
                toolbarButton("🔍", "Inspector", "Header Inspector (I)") { viewModel.toggleHeaderInspector() }
                toolbarButton("📊", "Session", "Session Overview") {
                    viewModel.showSessionOverview.toggle()
                }
                toolbarButton("🗑️", "Delete", "Pre-Delete Marked (⌘⌫)") { viewModel.moveMarkedToPreDelete() }
                if viewModel.canUndoPreDelete {
                    toolbarButton("↩️", "Undo", "Undo last Pre-Delete (⌘Z)") { viewModel.undoPreDelete() }
                }
                toolbarButton("🌟", "STF", "Toggle Auto/Locked Stretch (S)") { viewModel.toggleStretchMode() }

                Rectangle()
                    .fill(nightDivider)
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 6)

                // Stretch strength slider: 0% (linear) → 100% (max stretch)
                // Affects ONLY the currently displayed image, applied on release
                VStack(spacing: 1) {
                    Slider(
                        value: $sliderValue,
                        in: 0.0...0.50,
                        step: 0.01,
                        onEditingChanged: { editing in
                            if !editing {
                                // Apply stretch only when user releases the slider
                                viewModel.updateStretchStrength(Float(sliderValue))
                            }
                        }
                    )
                    .frame(width: 280)
                    .tint(viewModel.nightMode ? .red : nil)

                    Text("Stretch \(Int(sliderValue / 0.50 * 100))%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(nightFg)
                }
                .frame(width: 300)
                .help("Adjust stretch for current image (0%=linear, 50%=default, 100%=max)")

                Rectangle()
                    .fill(nightDivider)
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 6)

                Rectangle()
                    .fill(nightDivider)
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 6)

                // Native toggle controls
                VStack(spacing: 4) {
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

                // Debayer toggle — only shown when session has OSC images
                if viewModel.hasOSCImages {
                    VStack(spacing: 4) {
                        Toggle("Debayer", isOn: Binding(
                            get: { viewModel.debayerEnabled },
                            set: { _ in viewModel.toggleDebayer() }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(.green)
                        .help("Toggle OSC debayer (D) — Bayer interpolation to RGB color")
                    }
                    .frame(width: 90)
                }

                Spacer()

                toolbarButton("❓", "Help", "Help (⌘?)") { HelpWindowController.shared.showWindow(nil) }
                toolbarButton("ℹ️", "About", "About AstroBlinkV2") { AstroBlinkV2AppDelegate.showAboutPanel() }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(nightBg)

            Rectangle().fill(nightDivider).frame(height: 1)

            // Main content area with optional side panels
            HStack(spacing: 0) {
                // LEFT: Header Inspector panel
                if viewModel.showInspector {
                    HeaderInspectorContentView(model: viewModel.headerInspectorModel)
                        .frame(width: 320)
                        .background(nightBg)

                    Rectangle().fill(nightDivider).frame(width: 1)
                }

                // CENTER: Image viewer + file list + status bars
                VStack(spacing: 0) {
                    VSplitView {
                        // Top: Image viewer (takes most space)
                        ImageViewerView(viewModel: viewModel, renderer: $renderer)
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
                                        .foregroundColor(nightFg)
                                }
                            } else {
                                Text("Caching paused — \(viewModel.prefetchCachedCount)/\(viewModel.images.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(nightFg)
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

                    // Filter statistics bar
                    if !viewModel.filterStatistics.isEmpty {
                        HStack {
                            Text(viewModel.filterStatistics)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(nightFg)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(nightControlBg)
                    }

                    // Status bar: LEFT = selection/file info, RIGHT = session/mode indicators
                    HStack(spacing: 0) {
                        // LEFT SIDE: file index, marked count, dimensions (close to filename column)
                        if let image = viewModel.selectedImage {
                            Text("\(viewModel.selectedIndex + 1) / \(viewModel.images.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(nightFg)

                            if let w = image.width, let h = image.height {
                                statusDivider

                                Text("\(w)x\(h)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(nightFg)
                            }
                        }

                        if viewModel.markedCount > 0 {
                            statusDivider

                            Text("\(viewModel.markedCount) of \(viewModel.images.count) marked")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.red)
                        }

                        statusDivider

                        Text(viewModel.statusMessage)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(nightFg)
                            .lineLimit(1)
                            .textSelection(.enabled)

                        Spacer()

                        // RIGHT SIDE: mode indicators + filter stats (general info)
                        if viewModel.skipMarked {
                            Text("SKIP")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(nightAccent)
                                .help("Marked images are skipped during navigation (K)")

                            statusDivider
                        }

                        if viewModel.hideMarked {
                            Text("HIDE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(nightAccent)
                                .help("Marked images are hidden from the list (H)")

                            statusDivider
                        }

                        if let r = renderer {
                            Text(r.stretchMode.rawValue)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(r.stretchMode == .locked ? nightAccent : nightFg)
                                .help("Press S to toggle stretch mode")

                            statusDivider
                        }

                        if viewModel.nightMode {
                            Text("NIGHT")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.red)

                            statusDivider
                        }

                        if viewModel.debayerEnabled {
                            Text("DEBAYER")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(viewModel.nightMode ? .red : .green)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(nightBg)
                }

                // RIGHT: Session Overview panel
                if viewModel.showSessionOverview {
                    Rectangle().fill(nightDivider).frame(width: 1)

                    SessionOverviewContentView(model: viewModel.sessionOverviewModel)
                        .frame(width: 380)
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
        .onDisappear {
            KeyboardHandler.remove(monitor: keyboardMonitor)
        }
        .onChange(of: renderer) { newRenderer in
            viewModel.renderer = newRenderer
        }
        .onChange(of: viewModel.stretchStrength) { newValue in
            sliderValue = Double(newValue)
        }
        .navigationTitle("AstroBlinkV2 v2.0.0 — Fast Visual Culling for Astrophotography")
        .frame(minWidth: 800, minHeight: 500)
    }

    // Emoji toolbar button with large icon and tiny label below
    private func toolbarButton(_ emoji: String, _ label: String, _ tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(emoji)
                    .font(.system(size: 28))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(nightFg)
            }
            .frame(width: 50)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .contentShape(Rectangle())
    }
}
