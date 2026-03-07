// v0.9.4
import SwiftUI

// Root view: toolbar on top, optional side panels (inspector left, session right),
// image viewer + file list in center, status bar at bottom
struct ContentView: View {
    @StateObject private var viewModel = TriageViewModel()
    @State private var renderer: MetalRenderer?
    @State private var keyboardMonitor: Any?

    // Thin vertical divider for status bar separation
    private var statusDivider: some View {
        Text("|")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary.opacity(0.5))
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
                toolbarButton("🌟", "Stretch", "Toggle Stretch (S)") { viewModel.toggleStretchMode() }

                Spacer()

                toolbarButton("❓", "Help", "Help (⌘?)") { HelpWindowController.shared.showWindow(nil) }
                toolbarButton("ℹ️", "About", "About AstroBlinkV2") { AstroBlinkV2AppDelegate.showAboutPanel() }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main content area with optional side panels
            HStack(spacing: 0) {
                // LEFT: Header Inspector panel
                if viewModel.showInspector {
                    HeaderInspectorContentView(model: viewModel.headerInspectorModel)
                        .frame(width: 320)

                    Divider()
                }

                // CENTER: Image viewer + file list + status bars
                VStack(spacing: 0) {
                    VSplitView {
                        // Top: Image viewer (takes most space)
                        ImageViewerView(viewModel: viewModel, renderer: $renderer)
                            .frame(minHeight: 200)

                        // Bottom: File list (full width for more columns)
                        FileListView(viewModel: viewModel)
                            .frame(minHeight: 150, idealHeight: 250)
                    }

                    // Pre-cache progress bar with stop/continue controls
                    if viewModel.isCaching || viewModel.cachingStopped {
                        HStack(spacing: 8) {
                            if viewModel.isCaching {
                                VStack(spacing: 2) {
                                    ProgressView(value: viewModel.cacheProgress)
                                        .progressViewStyle(.linear)

                                    Text("Pre-caching \(viewModel.cachingCount)/\(viewModel.cachingTotal) images...")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("Caching paused — \(viewModel.prefetchCachedCount)/\(viewModel.images.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            if viewModel.isCaching {
                                Button(action: { viewModel.stopCaching() }) {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Stop caching")
                            }

                            if viewModel.cachingStopped {
                                Button(action: { viewModel.continueCaching() }) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Continue caching")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                    }

                    // Filter statistics bar
                    if !viewModel.filterStatistics.isEmpty {
                        HStack {
                            Text(viewModel.filterStatistics)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                    }

                    // Status bar with dividers between elements
                    HStack(spacing: 0) {
                        Text(viewModel.statusMessage)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)

                        Spacer()

                        // Marked count
                        if viewModel.markedCount > 0 {
                            Text("\(viewModel.markedCount) of \(viewModel.images.count) marked")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.red)

                            statusDivider
                        }

                        // Skip/Hide marked indicators
                        if viewModel.skipMarked {
                            Text("SKIP")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                                .help("Marked images are skipped during navigation (K)")

                            statusDivider
                        }

                        if viewModel.hideMarked {
                            Text("HIDE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                                .help("Marked images are hidden from the list (H)")

                            statusDivider
                        }

                        if let r = renderer {
                            Text(r.stretchMode.rawValue)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(r.stretchMode == .locked ? .orange : .secondary)
                                .help("Press S to toggle stretch mode")

                            statusDivider
                        }

                        if let image = viewModel.selectedImage {
                            Text("\(viewModel.selectedIndex + 1) / \(viewModel.images.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)

                            if let w = image.width, let h = image.height {
                                statusDivider

                                Text("\(w)x\(h)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.windowBackgroundColor))
                }

                // RIGHT: Session Overview panel
                if viewModel.showSessionOverview {
                    Divider()

                    SessionOverviewContentView(model: viewModel.sessionOverviewModel)
                        .frame(width: 380)
                }
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
        .navigationTitle("AstroBlinkV2 v0.9.4 — Fast Visual Culling for Astrophotography")
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
                    .foregroundColor(.secondary)
            }
            .frame(width: 50)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .contentShape(Rectangle())
    }
}
