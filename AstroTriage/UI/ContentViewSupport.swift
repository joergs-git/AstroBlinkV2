// Companion structs to ContentView — view modifiers, status indicators,
// AutoMark popover, and AIsaac state observer. Extracted out of ContentView.swift
// to keep the main view body focused on layout.
import SwiftUI
import AppKit

// MARK: - Content View Modifiers (extracted to reduce type-check complexity)

/// MCP-related observers split into their own ViewModifier so the parent
/// modifier chains stay below SwiftUI's type-check budget.
struct ContentViewMCPModifiers: ViewModifier {
    @ObservedObject var viewModel: TriageViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showMCPConnector)) { _ in
                MCPConnectorWindowController.shared.show()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mcpApplyGarbageMarks)) { notification in
                // MCP requested: mark these file hashes as PRE-DELETE in the
                // currently loaded session. Move-to-trash stays user-driven
                // (Cmd+Backspace) per non-negotiable rule #1.
                guard let info = notification.userInfo,
                      let commandId = info["commandId"] as? String,
                      let hashes = info["fileHashes"] as? [String] else { return }
                let result = viewModel.markByFileHashes(Set(hashes))
                let summary: [String: Any] = [
                    "dryRun": false,
                    "markedCount": result.marked,
                    "notFoundInSession": result.notFound,
                    "totalRequested": hashes.count,
                    "hint": result.marked == 0
                        ? "No matching frames in the active session. Open the relevant folder in AstroBlink first, or run scan_for_new_frames."
                        : "Press Cmd+Backspace in AstroBlink to move the marked frames to PRE-DELETE."
                ]
                let json = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let status = MCPCommandStatus(
                    commandId: commandId, verb: "mark-garbage", state: "completed",
                    startedAt: nil, completedAt: MCPCommandStatus.nowISO8601(),
                    progressCurrent: nil, progressTotal: nil,
                    resultSummary: json, errorMessage: nil
                )
                try? FrameHistoryDatabase.shared.saveMCPCommandStatus(status)
            }
    }
}

struct ContentViewModifiers: ViewModifier {
    @ObservedObject var viewModel: TriageViewModel
    @Binding var sliderValue: Double
    @Binding var renderer: MetalRenderer?
    @Binding var keyboardMonitor: Any?

    func body(content: Content) -> some View {
        content
            .background(viewModel.nightMode ? Color.black : Color(NSColor.windowBackgroundColor))
            .preferredColorScheme(viewModel.nightMode ? .dark : nil)
            .onChange(of: viewModel.nightMode) { _, isNight in
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
            .onReceive(NotificationCenter.default.publisher(for: .toggleViewerOverlay)) { _ in
                viewModel.toggleViewerOverlay()
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
            .onReceive(NotificationCenter.default.publisher(for: .showAstroRootsSettings)) { _ in
                AstroRootsSettingsWindowController.shared.show()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAIsaac)) { _ in
                AIsaacWindowController.shared.updateContext(images: viewModel.images, viewModel: viewModel)
                AIsaacWindowController.shared.toggleWindow()
            }
            .onReceive(NotificationCenter.default.publisher(for: .askAIsaacAboutQuality)) { notification in
                // Auto-open AIsaac, refresh context, and fire the question
                let ctrl = AIsaacWindowController.shared
                ctrl.updateContext(images: viewModel.images, viewModel: viewModel)
                ctrl.showWindow(nil)
                ctrl.window?.makeKeyAndOrderFront(nil)
                if let question = notification.object as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        ctrl.model.sendQuickReply(question)
                    }
                }
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
            .modifier(ContentViewMCPModifiers(viewModel: viewModel))
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
            .onReceive(NotificationCenter.default.publisher(for: .destroyAllData)) { _ in
                // First confirmation
                let alert1 = NSAlert()
                alert1.alertStyle = .critical
                alert1.messageText = "Destroy All Database Data?"
                if let stats = try? FrameHistoryDatabase.shared.databaseStats() {
                    alert1.informativeText = "This will permanently destroy:\n\n• \(stats.frameCount) frame records from \(stats.sessionCount) sessions\n• All iCloud backups\n• All calibration data\n• All setup nicknames\n\nThis cannot be undone."
                } else {
                    alert1.informativeText = "This will permanently destroy all local data, iCloud backups, and calibration files.\n\nThis cannot be undone."
                }
                alert1.addButton(withTitle: "Destroy Everything")
                alert1.addButton(withTitle: "Cancel")
                guard alert1.runModal() == .alertFirstButtonReturn else { return }

                // Second confirmation
                let alert2 = NSAlert()
                alert2.alertStyle = .critical
                alert2.messageText = "Are you really sure?"
                alert2.informativeText = "All historical frame data, quality scores, calibration baselines, and iCloud backups will be permanently deleted.\n\nYou will need to re-scan all sessions to rebuild."
                alert2.addButton(withTitle: "Yes, Destroy All Data")
                alert2.addButton(withTitle: "Cancel")
                guard alert2.runModal() == .alertFirstButtonReturn else { return }

                try? FrameHistoryDatabase.shared.destroyAllData()
                viewModel.statusMessage = "All database data destroyed"
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleBlindCuration)) { _ in
                viewModel.toggleBlindCurationMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportCuratedDataset)) { _ in
                CuratedExport.runInteractive(viewModel: viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .syncCuratedToSupabase)) { _ in
                // Bulk backfill for curated frames that never made it to Supabase
                // (rated while offline, or created before CurationService existed).
                viewModel.statusMessage = "Syncing curated dataset to Supabase…"
                CurationService.bulkSync { synced, failed in
                    if synced == 0 && failed == 0 {
                        viewModel.statusMessage = "No curated frames to sync (rate some with 1/2/3 first)"
                    } else if failed == 0 {
                        viewModel.statusMessage = "Synced \(synced) curated frame\(synced == 1 ? "" : "s") to Supabase"
                    } else {
                        viewModel.statusMessage = "Synced \(synced) curated frames, \(failed) failed (check network)"
                    }
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
            .onChange(of: viewModel.quickStackEngineV2?.phase) { _, newPhase in
                if newPhase == .done || newPhase == .failed {
                    viewModel.benchmarkStats.markQuickStackEnd()
                }
            }
            .onDisappear {
                KeyboardHandler.remove(monitor: keyboardMonitor)
            }
            .onChange(of: renderer) { _, newRenderer in
                viewModel.renderer = newRenderer
            }
            .onChange(of: viewModel.stretchStrength) { _, newValue in
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

    // Per-filter impact of a single Auto-Mark option.
    // Used to show the user WHICH filters suffer — not just the overall total —
    // so they can judge risk per-channel before confirming.
    private struct FilterImpact: Hashable {
        let filter: String     // display label, e.g. "Ha", "R", or "—" when unknown
        let count: Int
        let exposure: Double   // seconds
    }

    private struct MarkOption {
        let title: String
        let subtitle: String
        let count: Int
        let integrationLoss: String
        let color: Color
        // Sorted by exposure desc (biggest loss first). Empty or 1-entry = row hides this line.
        let filterBreakdown: [FilterImpact]
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

        // Group a target list by filter, summing exposure per filter.
        // nil/empty filter is bucketed as "—" so the user still sees those frames accounted for.
        func filterBreakdown(_ frames: [ImageEntry]) -> [FilterImpact] {
            let grouped = Dictionary(grouping: frames) { entry -> String in
                if let f = entry.filter?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
                    return f
                }
                return "—"
            }
            return grouped
                .map { name, items in
                    FilterImpact(
                        filter: name,
                        count: items.count,
                        exposure: items.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
                    )
                }
                .sorted { $0.exposure > $1.exposure }
        }

        return [
            MarkOption(title: "Conservative", subtitle: "Nebula — maximize integration time.\nOnly removes definite garbage.",
                       count: conservativeTarget.count, integrationLoss: lossStr(trashExp), color: .green,
                       filterBreakdown: filterBreakdown(conservativeTarget)),
            MarkOption(title: "Balanced", subtitle: "General use — removes garbage\n+ worst borderline frames.",
                       count: balancedTarget.count, integrationLoss: lossStr(balancedExp), color: .orange,
                       filterBreakdown: filterBreakdown(balancedTarget)),
            MarkOption(title: "Aggressive", subtitle: "Stars/Galaxy — prioritize sharpness.\nRemoves questionable + weak frames (<30% SNR).",
                       count: aggressiveTarget.count, integrationLoss: lossStr(aggressiveExp), color: .red,
                       filterBreakdown: filterBreakdown(aggressiveTarget)),
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
                // Per-filter loss breakdown — only when the option would hit 2+ distinct filters,
                // otherwise the line is redundant with the main count/loss total above.
                if option.filterBreakdown.count >= 2 {
                    Text(filterBreakdownString(option.filterBreakdown))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    // Formats a per-filter loss list as a compact single-string readable line.
    // Example output: "33 Ha = 2.0h   56 R = 1.0h   22 B = 30m"
    // Time format matches the main lossStr() convention (hours with one decimal above 1h, minutes below).
    private func filterBreakdownString(_ breakdown: [FilterImpact]) -> String {
        return breakdown.map { impact in
            let time: String
            if impact.exposure >= 3600 {
                time = String(format: "%.1fh", impact.exposure / 3600)
            } else if impact.exposure > 0 {
                time = String(format: "%.0fm", impact.exposure / 60)
            } else {
                time = "—"
            }
            return "\(impact.count) \(impact.filter) = \(time)"
        }.joined(separator: "   ")
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
            .onChange(of: viewModel.isCaching) { _, isCaching in
                AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
                if !isCaching {
                    AIsaacWindowController.shared.updateContext(images: viewModel.images, viewModel: viewModel)
                    AIsaacWindowController.shared.model.detectLanguageFromLocation()
                }
            }
            .onChange(of: viewModel.cacheProgress) { _, progress in
                if progress > 0.99 || Int(progress * 10) > Int((progress - 0.1) * 10) {
                    AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
                }
            }
            .onChange(of: viewModel.images.count) {
                AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
            }
            .onChange(of: viewModel.needsTableRefresh) {
                AIsaacWindowController.shared.pushStateUpdate(from: viewModel)
            }
    }
}
