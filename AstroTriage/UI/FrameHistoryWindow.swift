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

                // Stale records indicator
                if model.staleRecordCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: fs(10)))
                            .foregroundColor(.orange)
                        Text("\(model.staleRecordCount) frames scored with older algorithm (v\(kAlgorithmVersion) is current)")
                            .font(.system(size: fs(10), design: .monospaced))
                            .foregroundColor(fgDim)
                        Spacer()
                        Text("Re-analysis available in future update")
                            .font(.system(size: fs(9)))
                            .foregroundColor(fgDim)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(AppColors.bgControl(nightMode))
                }

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
        case .sessionScore:
            sessionScoreChart
        case .efficiency:
            efficiencyChart
        case .performance:
            equipmentHealthChart
        case .conditions:
            conditionsChart
        case .progress:
            targetProgressChart
        case .setups:
            setupComparisonChart
        }
    }

    // KPI 1: Session Score — composite quality score per night
    private var sessionScoreChart: some View {
        let scores = model.sessionScores
        return VStack(alignment: .leading, spacing: 4) {
            Text("Session Score by Night")
                .font(.system(size: fs(13), weight: .semibold))
                .foregroundColor(fg)

            if scores.isEmpty {
                noDataView
            } else {
                Chart(scores) { point in
                    BarMark(
                        x: .value("Night", point.date, unit: .day),
                        y: .value("Score", point.score)
                    )
                    .foregroundStyle(
                        point.score >= 75 ? Color.green :
                        point.score >= 50 ? Color.yellow :
                        point.score >= 25 ? Color.orange : Color.red
                    )
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Score (0-100)")
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: 300)

                // Legend + stats
                HStack(spacing: 12) {
                    HStack(spacing: 3) { Circle().fill(.green).frame(width: 6); Text("75+").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    HStack(spacing: 3) { Circle().fill(.yellow).frame(width: 6); Text("50-74").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    HStack(spacing: 3) { Circle().fill(.orange).frame(width: 6); Text("25-49").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    HStack(spacing: 3) { Circle().fill(.red).frame(width: 6); Text("<25").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    Spacer()
                    let avg = scores.map(\.score).reduce(0, +) / Double(scores.count)
                    Text("Avg: \(String(format: "%.0f", avg))")
                        .font(.system(size: fs(11), weight: .medium, design: .monospaced))
                        .foregroundColor(fg)
                    if let best = scores.max(by: { $0.score < $1.score }) {
                        Text("Best: \(String(format: "%.0f", best.score)) (\(best.night))")
                            .font(.system(size: fs(11), design: .monospaced))
                            .foregroundColor(fgDim)
                    }
                }
                Text("Score = 40% retention + 30% FWHM quality + 20% trailing + 10% stability")
                    .font(.system(size: fs(9)))
                    .foregroundColor(fgDim)
            }
        }
    }

    // KPI 2: Imaging Efficiency — retention rate per night with tier breakdown
    private var efficiencyChart: some View {
        let data = model.efficiencyData
        return VStack(alignment: .leading, spacing: 4) {
            Text("Imaging Efficiency — Frames Kept vs Lost")
                .font(.system(size: fs(13), weight: .semibold))
                .foregroundColor(fg)

            if data.isEmpty {
                noDataView
            } else {
                Chart(data) { point in
                    BarMark(
                        x: .value("Night", point.date, unit: .day),
                        y: .value("Kept %", point.retentionPct)
                    )
                    .foregroundStyle(
                        point.retentionPct >= 80 ? Color.green :
                        point.retentionPct >= 60 ? Color.yellow :
                        point.retentionPct >= 40 ? Color.orange : Color.red
                    )
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Frames Kept %")
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: 300)

                // Legend + stats
                HStack(spacing: 12) {
                    HStack(spacing: 3) { Circle().fill(.green).frame(width: 6); Text("80%+").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    HStack(spacing: 3) { Circle().fill(.yellow).frame(width: 6); Text("60-79%").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    HStack(spacing: 3) { Circle().fill(.orange).frame(width: 6); Text("40-59%").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    HStack(spacing: 3) { Circle().fill(.red).frame(width: 6); Text("<40%").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    Spacer()
                    let avgEfficiency = data.map(\.retentionPct).reduce(0, +) / Double(data.count)
                    let totalFrames = data.reduce(0) { $0 + $1.total }
                    let totalKept = data.reduce(0) { $0 + $1.excellent + $1.good }
                    Text("Avg: \(String(format: "%.0f%%", avgEfficiency))")
                        .font(.system(size: fs(11), weight: .medium, design: .monospaced))
                        .foregroundColor(fg)
                    Text("\(totalKept)/\(totalFrames) kept overall")
                        .font(.system(size: fs(11), design: .monospaced))
                        .foregroundColor(fgDim)
                }
                Text("Excellent + Good frames / Total frames per night")
                    .font(.system(size: fs(9)))
                    .foregroundColor(fgDim)
            }
        }
    }

    // KPI 3: Equipment Health — rolling FWHM trend per setup
    private var equipmentHealthChart: some View {
        let data = model.equipmentHealthData
        let setupLabel = model.selectedSetupHash == nil ? "All Setups" : "This Setup"
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Equipment Health — FWHM Trend (\(setupLabel))")
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)
                Spacer()
                if model.selectedSetupHash == nil {
                    Text("Select a setup above for accurate tracking")
                        .font(.system(size: fs(9)))
                        .foregroundColor(.orange)
                }
                // Trend arrow
                if data.count >= 5 {
                    let recent = data.suffix(3).map(\.rollingFWHM).reduce(0, +) / 3.0
                    let earlier = data.prefix(3).map(\.rollingFWHM).reduce(0, +) / 3.0
                    let improving = recent < earlier
                    HStack(spacing: 4) {
                        Image(systemName: improving ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundColor(improving ? .green : .orange)
                        Text(improving ? "Improving" : "Degrading")
                            .font(.system(size: fs(11)))
                            .foregroundColor(improving ? .green : .orange)
                    }
                }
            }

            if data.isEmpty {
                noDataView
            } else {
                Chart {
                    ForEach(data) { point in
                        PointMark(
                            x: .value("Night", point.date),
                            y: .value("FWHM", point.rawFWHM)
                        )
                        .foregroundStyle(fgDim.opacity(0.4))
                        .symbolSize(15)
                    }
                    ForEach(data) { point in
                        LineMark(
                            x: .value("Night", point.date),
                            y: .value("Rolling Avg", point.rollingFWHM)
                        )
                        .foregroundStyle(AppColors.accent(nightMode))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYAxisLabel("FWHM (px)")
                .modifier(PercentileYScale(values: data.map(\.rawFWHM)))
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: 300)

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(fgDim.opacity(0.4)).frame(width: 6)
                        Text("Per-night FWHM").font(.system(size: fs(9))).foregroundColor(fgDim)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(AppColors.accent(nightMode)).frame(width: 16, height: 2)
                        Text("5-session rolling avg").font(.system(size: fs(9))).foregroundColor(fgDim)
                    }
                }
            }
        }
    }

    // KPI 4: Conditions vs Results — Moon impact by filter type
    private var conditionsChart: some View {
        let moonData = model.moonPoints

        // Separate broadband (L/R/G/B) vs narrowband (Ha/OIII/SII)
        struct MoonScorePoint: Identifiable {
            let id = UUID()
            let moonPct: Double
            let noise: Double
            let filterType: String  // "Broadband" or "Narrowband"
        }
        let points: [MoonScorePoint] = moonData.map { p in
            let filterType = p.isBroadband ? "Broadband (LRGB)" : "Narrowband (Ha/OIII/SII)"
            return MoonScorePoint(moonPct: p.moonIllumination, noise: p.background, filterType: filterType)
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text("Moon Impact by Filter Type")
                .font(.system(size: fs(13), weight: .semibold))
                .foregroundColor(fg)

            if points.isEmpty {
                noDataView
            } else {
                Chart(points) { point in
                    PointMark(
                        x: .value("Moon %", point.moonPct),
                        y: .value("Background", point.noise)
                    )
                    .foregroundStyle(by: .value("Filter", point.filterType))
                    .symbolSize(30)
                }
                .chartForegroundStyleScale([
                    "Broadband (LRGB)": Color.blue,
                    "Narrowband (Ha/OIII/SII)": Color.orange
                ])
                .chartXScale(domain: 0...100)
                .chartXAxisLabel("Moon Illumination %")
                .chartYAxisLabel("Background Noise (MAD)")
                .modifier(PercentileYScale(values: points.map(\.noise)))
                .chartPlotStyle { plot in plot.background(chartBg) }
                .chartLegend(.visible)
                .frame(minHeight: 300)

                Text("Broadband rises with moon — narrowband stays flat (immune to moonlight)")
                    .font(.system(size: fs(9)))
                    .foregroundColor(fgDim)
            }
        }
    }

    // KPI 5: Target Progress — integration time per target
    private var targetProgressChart: some View {
        let data = model.targetProgressData.prefix(15) // Top 15 targets
        return VStack(alignment: .leading, spacing: 4) {
            Text("Integration Progress by Target")
                .font(.system(size: fs(13), weight: .semibold))
                .foregroundColor(fg)

            if data.isEmpty {
                noDataView
            } else {
                Chart(Array(data)) { target in
                    BarMark(
                        x: .value("Frames", target.usableIntegrationMinutes),
                        y: .value("Target", target.target)
                    )
                    .foregroundStyle(
                        target.avgRetention >= 0.8 ? Color.green.gradient :
                        target.avgRetention >= 0.6 ? Color.yellow.gradient :
                        Color.orange.gradient
                    )
                    .annotation(position: .trailing) {
                        Text("\(Int(target.usableIntegrationMinutes)) kept")
                            .font(.system(size: fs(9), design: .monospaced))
                            .foregroundColor(fgDim)
                    }
                }
                .chartXAxisLabel("Usable Frames")
                .chartPlotStyle { plot in plot.background(chartBg) }
                .frame(minHeight: max(300, CGFloat(data.count) * 28))
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
                // Truncate long setup labels for readability
                let maxLabelLen = 25
                Chart(points) { point in
                    let label = point.setupLabel.count > maxLabelLen
                        ? String(point.setupLabel.prefix(maxLabelLen)) + "…"
                        : point.setupLabel
                    BarMark(
                        x: .value("Setup", label),
                        y: .value(model.selectedMetric.rawValue, point.value),
                        width: .fixed(min(80, max(30, 400 / CGFloat(points.count))))
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
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: fs(9)))
                    }
                }
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
