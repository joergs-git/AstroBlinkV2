import SwiftUI
import Charts

// MARK: - Window Controller

class FrameHistoryController {
    static let shared = FrameHistoryController()
    private var window: NSWindow?
    let model = FrameHistoryModel()

    func toggleWindow() {
        if let w = window, w.isVisible {
            w.close()
            return
        }
        showWindow()
    }

    func showWindow() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        model.loadData()

        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let nightMode = AppSettings.loadBool(for: .nightMode) == true
        let view = FrameHistoryContentView(model: model, nightMode: nightMode)
            .environment(\.fontScale, savedScale)
        let hostingView = NSHostingView(rootView: view)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Frame History"
        win.contentView = hostingView
        win.minSize = NSSize(width: 600, height: 400)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

// MARK: - Main Content View

struct FrameHistoryContentView: View {
    @ObservedObject var model: FrameHistoryModel
    @ObservedObject var scanner: ArchiveScanner = .shared
    let nightMode: Bool
    @Environment(\.fontScale) private var fontScale

    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }
    private var fg: Color { AppColors.fg(nightMode) }
    private var fgDim: Color { AppColors.fgDim(nightMode) }
    private var bg: Color { AppColors.bg(nightMode) }
    private var chartBg: Color { AppColors.chartBg(nightMode) }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar with stats and filters
            headerBar

            Divider()

            if let stats = model.stats, stats.frameCount > 0 {
                // Summary cards
                summaryCardsRow
                    .padding(.horizontal, 12)
                    .padding(.top, 6)

                // Chart selector
                Picker("Chart", selection: $model.selectedChart) {
                    ForEach(FrameHistoryModel.ChartType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Chart area
                chartView
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                emptyState
            }

            // Archive scanner controls (bottom bar)
            if scanner.isScanning {
                Divider()
                scannerProgressBar
            }
        }
        .background(bg)
        .onChange(of: model.selectedSetupHash) { _, _ in model.loadNightlyTrend() }
        .onChange(of: model.selectedTarget) { _, _ in model.loadNightlyTrend() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Database stats
            if let stats = model.stats {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(stats.frameCount) frames")
                        .font(.system(size: fs(13), weight: .semibold))
                        .foregroundColor(fg)
                    Text("\(stats.sessionCount) sessions")
                        .font(.system(size: fs(11)))
                        .foregroundColor(fgDim)
                }

                if let first = stats.firstNight, let last = stats.lastNight {
                    Text("\(first) — \(last)")
                        .font(.system(size: fs(11), design: .monospaced))
                        .foregroundColor(fgDim)
                }
            }

            Spacer()

            // Setup picker (always show — "All Setups" is the consolidated view)
            Picker("Setup", selection: $model.selectedSetupHash) {
                Text("All Setups").tag(Optional<String>.none)
                ForEach(model.availableSetups, id: \.hash) { setup in
                    Text(setup.label).tag(Optional(setup.hash))
                }
            }
            .frame(maxWidth: 250)

            // Edit nickname button (only when a specific setup is selected)
            if model.selectedSetupHash != nil {
                Button(action: { showNicknameDialog() }) {
                    Image(systemName: "pencil")
                }
                .help("Set nickname for this setup")
            }

            // Target picker
            if model.availableTargets.count > 1 {
                Picker("Target", selection: $model.selectedTarget) {
                    Text("All").tag(Optional<String>.none)
                    ForEach(model.availableTargets, id: \.self) { target in
                        Text(target).tag(Optional(target))
                    }
                }
                .frame(maxWidth: 150)
            }

            // Build Archive button
            Button(action: { startArchiveScan() }) {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive.badge.plus")
                    Text("Scan")
                        .font(.system(size: fs(11)))
                }
            }
            .disabled(scanner.isScanning)
            .help("Scan a folder tree to build archive database")

            // Refresh button
            Button(action: { model.loadData() }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh data")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Chart Views

    @ViewBuilder
    private var chartView: some View {
        switch model.selectedChart {
        case .qualityTimeline:
            qualityTimelineChart
        case .metricTrend:
            metricTrendChart
        case .moonImpact:
            moonImpactChart
        case .setupComparison:
            setupComparisonChart
        }
    }

    // Flat data point for stacked bar chart (SwiftUI Charts needs flat list for stacking)
    private struct TierBar: Identifiable {
        let id = UUID()
        let night: String
        let tier: String
        let count: Int
        let order: Int  // Sort order for stacking: trash bottom, excellent top
    }

    // Chart 1: Quality Timeline — stacked bars per night
    private var qualityTimelineChart: some View {
        let data = model.nightlyQuality
        // Flatten into individual tier bars for proper stacking
        let bars: [TierBar] = data.flatMap { night -> [TierBar] in
            [
                TierBar(night: night.night, tier: "Trash", count: night.trash, order: 0),
                TierBar(night: night.night, tier: "Borderline", count: night.borderline, order: 1),
                TierBar(night: night.night, tier: "Good", count: night.good, order: 2),
                TierBar(night: night.night, tier: "Excellent", count: night.excellent, order: 3),
            ].filter { $0.count > 0 }
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text("Quality Distribution by Night")
                .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)

            if bars.isEmpty {
                noDataView
            } else {
                Chart(bars) { bar in
                    BarMark(
                        x: .value("Night", bar.night),
                        y: .value("Frames", bar.count)
                    )
                    .foregroundStyle(by: .value("Tier", bar.tier))
                }
                .chartForegroundStyleScale([
                    "Excellent": Color.green,
                    "Good": Color.green.opacity(0.5),
                    "Borderline": Color.orange,
                    "Trash": Color.red
                ])
                .chartYAxisLabel("Frames")
                .chartLegend(.visible)
                // Fixed to window width — no horizontal scrolling
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: 300)
            }
        }
    }

    // Chart 2: Metric Trend — lines per filter
    private var metricTrendChart: some View {
        let points = model.metricPoints(for: model.selectedMetric)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Metric Trend by Night")
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)
                Spacer()
                Picker("Metric", selection: $model.selectedMetric) {
                    ForEach(FrameHistoryModel.MetricType.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .frame(maxWidth: 120)
            }

            if points.isEmpty {
                noDataView
            } else {
                // Group points by filter and draw each with explicit color
                let filterGroups = Dictionary(grouping: points, by: \.filter)
                Chart {
                    ForEach(filterGroups.keys.sorted(), id: \.self) { filter in
                        let color = Self.filterColor(for: filter)
                        ForEach(filterGroups[filter]!) { point in
                            LineMark(
                                x: .value("Night", point.night),
                                y: .value(model.selectedMetric.rawValue, point.value),
                                series: .value("Filter", filter)
                            )
                            .foregroundStyle(color)

                            PointMark(
                                x: .value("Night", point.night),
                                y: .value(model.selectedMetric.rawValue, point.value)
                            )
                            .foregroundStyle(color)
                            .symbolSize(30)
                        }
                    }
                }
                .chartYAxisLabel(model.selectedMetric.rawValue)
                .chartLegend(.hidden)
                // Fixed to window width — no horizontal scrolling
                .modifier(PercentileYScale(values: points.map(\.value)))
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: 300)

                // Outlier indicator
                let outliers = model.outlierCount(for: model.selectedMetric)
                if outliers > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("\(outliers) outlier\(outliers == 1 ? "" : "s") beyond P98 not shown")
                            .font(.system(size: fs(10)))
                            .foregroundColor(fgDim)
                    }
                }
                filterLegend(filters: filterGroups.keys.sorted())
            }
        }
    }

    // Chart 3: Moon Impact — scatter
    private var moonImpactChart: some View {
        let points = model.moonPoints
        return VStack(alignment: .leading, spacing: 4) {
            Text("Moon Impact on Background")
                .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)

            if points.isEmpty {
                noDataView
            } else {
                Chart(points) { point in
                    PointMark(
                        x: .value("Moon %", point.moonIllumination),
                        y: .value("Background", point.background)
                    )
                    .foregroundStyle(Self.filterColor(for: point.filter))
                    .symbolSize(40)
                }
                .chartXAxisLabel("Moon Illumination %")
                .chartYAxisLabel("Background Noise (MAD)")
                .modifier(PercentileYScale(values: points.map(\.background)))
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: 300)
                filterLegend(filters: Array(Set(points.map(\.filter))).sorted())
            }
        }
    }

    // Chart 4: Setup Comparison — compare equipment performance
    private var setupComparisonChart: some View {
        let points = model.setupComparisonPoints(for: model.selectedMetric)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Setup Comparison")
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)
                Spacer()
                Picker("Metric", selection: $model.selectedMetric) {
                    ForEach(FrameHistoryModel.MetricType.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .frame(maxWidth: 120)
            }

            if points.count < 2 {
                VStack {
                    Spacer()
                    Image(systemName: "camera.2")
                        .font(.system(size: 40))
                        .foregroundColor(fgDim)
                    Text("Need at least 2 setups to compare.\nLoad sessions from different telescope/camera combos.")
                        .font(.system(size: fs(13)))
                        .foregroundColor(fgDim)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(minHeight: 200)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Setup", point.setupLabel),
                        y: .value(model.selectedMetric.rawValue, point.value)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .annotation(position: .top) {
                        Text(String(format: "%.1f", point.value))
                            .font(.system(size: fs(10)))
                            .foregroundColor(fgDim)
                    }
                }
                .chartYAxisLabel(model.selectedMetric.rawValue)
                .modifier(PercentileYScale(values: points.map(\.value)))
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: 300)
            }
        }
    }

    // MARK: - Summary Cards

    private var summaryCardsRow: some View {
        let s = model.summaryStats
        return HStack(spacing: 8) {
            summaryCard(icon: "photo.stack", label: "Frames", value: "\(s.totalFrames)")
            summaryCard(icon: "moon.stars", label: "Nights", value: "\(s.totalNights)")
            if let fwhm = s.bestFWHM {
                summaryCard(icon: "sparkle", label: "Best FWHM", value: String(format: "%.1f\"", fwhm))
            }
            summaryCard(icon: "xmark.circle", label: "Trash Rate",
                       value: String(format: "%.0f%%", s.avgTrashRate * 100),
                       color: s.avgTrashRate > 0.3 ? .red : (s.avgTrashRate > 0.15 ? .orange : AppColors.green(nightMode)))
            summaryCard(icon: "scope", label: "Targets", value: "\(s.totalTargets)")
        }
    }

    private func summaryCard(icon: String, label: String, value: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: fs(10)))
                    .foregroundColor(fgDim)
                Text(value)
                    .font(.system(size: fs(14), weight: .bold, design: .monospaced))
                    .foregroundColor(color ?? fg)
            }
            Text(label)
                .font(.system(size: fs(9)))
                .foregroundColor(fgDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(chartBg)
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(fgDim)
            Text("No Frame History Yet")
                .font(.system(size: fs(16), weight: .semibold))
            Text("Load and score sessions to build your history.\nQuality data is saved automatically after scoring.")
                .font(.system(size: fs(13)))
                .foregroundColor(fgDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var noDataView: some View {
        VStack {
            Spacer()
            Text("No data for selected filters")
                .font(.system(size: fs(13)))
                .foregroundColor(fgDim)
            Spacer()
        }
        .frame(minHeight: 200)
    }

    // MARK: - Setup Nickname

    private func showNicknameDialog() {
        guard let hash = model.selectedSetupHash else { return }
        let current = FrameHistoryDatabase.shared.nickname(for: hash) ?? ""

        let alert = NSAlert()
        alert.messageText = "Setup Nickname"
        alert.informativeText = "Enter a name for this setup (e.g. \"Big Rig\", \"Travel Scope\")"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = current
        input.placeholderString = "e.g. Big Rig"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let nickname = input.stringValue.trimmingCharacters(in: .whitespaces)
            if nickname.isEmpty {
                // Clear nickname — use raw equipment name
                try? FrameHistoryDatabase.shared.setNickname("", for: hash)
            } else {
                try? FrameHistoryDatabase.shared.setNickname(nickname, for: hash)
            }
            model.loadData()  // Refresh setup labels
        }
    }

    // MARK: - Archive Scanner

    private func startArchiveScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select root folder to scan for FITS/XISF images"
        panel.prompt = "Scan"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanner.startScan(rootURL: url)
    }

    private var scannerProgressBar: some View {
        HStack(spacing: 8) {
            // Folder indicator
            Image(systemName: "folder.badge.gearshape")
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(scanner.currentFolder)
                    .font(.system(size: fs(11)))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    // Progress
                    let progress = scanner.totalFound > 0
                        ? Double(scanner.totalProcessed) / Double(scanner.totalFound) : 0
                    ProgressView(value: progress)
                        .frame(width: 200)

                    Text("\(scanner.totalProcessed)/\(scanner.totalFound)")
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(fgDim)

                    if scanner.filesPerSecond > 0 {
                        Text(String(format: "%.1f/s", scanner.filesPerSecond))
                            .font(.system(size: fs(10), design: .monospaced))
                            .foregroundColor(fgDim)
                    }

                    if let eta = scanner.estimatedSecondsRemaining {
                        let min = eta / 60
                        let sec = eta % 60
                        Text(min > 0 ? "~\(min)m \(sec)s" : "~\(sec)s")
                            .font(.system(size: fs(10), design: .monospaced))
                            .foregroundColor(fgDim)
                    }
                }
            }

            Spacer()

            // Pause/Resume
            Button(action: {
                if scanner.isPaused { scanner.unpauseScan() } else { scanner.pauseScan() }
            }) {
                Image(systemName: scanner.isPaused ? "play.fill" : "pause.fill")
            }
            .help(scanner.isPaused ? "Resume" : "Pause")

            // Cancel
            Button(action: { scanner.cancelScan(); model.loadData() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            .help("Cancel scan")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Custom Filter Legend

    private func filterLegend(filters: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(filters, id: \.self) { filter in
                HStack(spacing: 4) {
                    Circle()
                        .fill(Self.filterColor(for: filter))
                        .frame(width: 8, height: 8)
                    Text(filter)
                        .font(.system(size: fs(10)))
                        .foregroundColor(fgDim)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Filter Colors

    /// Canonical filter color mapping — consistent across all charts and views.
    /// R=red, G=green, B=blue, L=grey, Ha/H=orange, OIII/O=teal, SII/S=yellow
    static func filterColor(for filter: String) -> Color {
        switch filter.uppercased() {
        case "R":                return .red
        case "G":                return .green
        case "B":                return .blue
        case "L":                return Color(white: 0.6)
        case "HA", "H":         return .orange
        case "OIII", "O":       return .teal
        case "SII", "S":        return .yellow
        case "HBETA", "HB":     return .cyan
        case "NII":             return .pink
        default:                return .purple
        }
    }

    /// Build chartForegroundStyleScale from the filters present in the data.
    static func filterColorScale(for filters: [String]) -> KeyValuePairs<String, Color> {
        // KeyValuePairs can't be built dynamically — use the chart modifier approach instead
        // This is handled by applying .foregroundStyle directly per mark
        return [:]
    }
}

// MARK: - Percentile Y-Axis Clamping

/// ViewModifier that clamps chart Y-axis to P2–P98 range, preventing outliers
/// from crushing the scale. Falls back to auto-scaling when data is insufficient.
struct PercentileYScale: ViewModifier {
    let values: [Double]

    func body(content: Content) -> some View {
        if let range = FrameHistoryModel.percentileRange(values) {
            content
                .chartYScale(domain: range.min...range.max)
        } else {
            content
        }
    }
}
