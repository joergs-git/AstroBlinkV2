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

        // Reload data when iCloud import replaces the database
        NotificationCenter.default.addObserver(forName: .frameHistoryDidImport, object: nil, queue: .main) { [weak self] _ in
            self?.model.loadData()
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

    // Hover state for chart tooltips
    @State private var hoveredDate: Date?
    @State private var hoverLocation: CGPoint = .zero

    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }
    private var fg: Color { AppColors.fg(nightMode) }
    private var fgDim: Color { AppColors.fgDim(nightMode) }
    private var bg: Color { AppColors.bg(nightMode) }
    private var chartBg: Color { AppColors.chartBg(nightMode) }
    /// Theme bundle passed to extracted chart structs (SessionScoreChart etc.).
    /// As more charts move out, fewer of the local color/font helpers above will
    /// be needed and they'll shrink.
    private var chartTheme: FrameHistoryChartTheme {
        FrameHistoryChartTheme(nightMode: nightMode, fontScale: fontScale)
    }

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

                // Stale records indicator with re-analysis button
                if model.staleRecordCount > 0 || model.isReAnalyzing {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: fs(10)))
                            .foregroundColor(.orange)

                        if model.isReAnalyzing {
                            Text("Re-analyzing \(model.reAnalysisProgress)/\(model.reAnalysisTotal) frames...")
                                .font(.system(size: fs(10), design: .monospaced))
                                .foregroundColor(fgDim)
                            ProgressView(value: Double(model.reAnalysisProgress),
                                         total: max(1, Double(model.reAnalysisTotal)))
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 200)
                        } else {
                            Text("\(model.staleRecordCount) frames scored with older algorithm (v\(kAlgorithmVersion) is current)")
                                .font(.system(size: fs(10), design: .monospaced))
                                .foregroundColor(fgDim)
                        }

                        Spacer()

                        if !model.isReAnalyzing {
                            Button {
                                model.reAnalyzeStaleRecords()
                            } label: {
                                Label("Re-Analyze", systemImage: "arrow.clockwise")
                                    .font(.system(size: fs(10)))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(AppColors.bgControl(nightMode))
                }

                // Monthly aggregation indicator
                if model.useMonthlyAggregation {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: fs(9)))
                            .foregroundColor(.secondary)
                        Text("Showing monthly averages (date range >6 months)")
                            .font(.system(size: fs(9)))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
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
        .onChange(of: model.selectedSetupHash) { _, _ in model.loadNightlyTrend(); model.loadMetricsData() }
        .onChange(of: model.selectedTarget) { _, _ in model.loadNightlyTrend(); model.loadMetricsData() }
        .onChange(of: model.selectedChart) { _, newChart in
            if newChart == .metrics { model.loadMetricsData() }
        }
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

            // Setup management button (rename, merge, delete, fix FL)
            if model.selectedSetupHash != nil {
                Button(action: { showSetupManagement() }) {
                    Image(systemName: "gearshape")
                }
                .help("Manage setup: rename, merge, delete, fix focal length")
            }

            // Target picker (always visible, enriched with common names)
            Picker("Target", selection: $model.selectedTarget) {
                Text("All").tag(Optional<String>.none)
                ForEach(model.availableTargets, id: \.self) { target in
                    Text(TargetCatalog.displayName(target)).tag(Optional(target))
                }
            }
            .frame(maxWidth: 150)

            // Time range picker
            Picker("Range", selection: $model.selectedTimeRange) {
                ForEach(FrameHistoryModel.TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .frame(maxWidth: 80)
            .help("Filter data by time range")

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
            SessionScoreChart(model: model, theme: chartTheme)
        case .efficiency:
            EfficiencyChart(model: model, theme: chartTheme)
        case .performance:
            EquipmentHealthChart(model: model, theme: chartTheme)
        case .conditions:
            ConditionsChart(model: model, theme: chartTheme)
        case .progress:
            TargetProgressChart(model: model, theme: chartTheme)
        case .setups:
            setupComparisonChart
        case .metrics:
            metricsChart
        }
    }




    // KPI 4: Conditions — environmental factor impact on background noise


    // Chart 4: Setup Comparison — compare equipment performance
    @State private var hoveredSetup: String?

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
                .chartPlotStyle { plot in plot.background(chartBg).clipped() }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: fs(9)))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    hoverLocation = loc
                                    if let label: String = proxy.value(atX: loc.x) {
                                        hoveredSetup = points.first(where: {
                                            let truncated = $0.setupLabel.count > 25
                                                ? String($0.setupLabel.prefix(25)) + "…"
                                                : $0.setupLabel
                                            return truncated == label
                                        })?.setupLabel
                                    }
                                case .ended:
                                    hoveredSetup = nil
                                }
                            }
                    }
                }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    if let hLabel = hoveredSetup,
                       let point = points.first(where: { $0.setupLabel == hLabel }) {
                        chartTooltip {
                            Text(point.setupLabel).font(.system(size: fs(10), weight: .bold))
                            Text(String(format: "%@ = %.2f", model.selectedMetric.rawValue, point.value))
                                .font(.system(size: fs(10)))
                            Divider().frame(height: 1)
                            Text("\(point.totalFrames) frames")
                                .font(.system(size: fs(9))).foregroundColor(fgDim)
                            if let first = point.firstNight, let last = point.lastNight {
                                Text("\(first) — \(last)")
                                    .font(.system(size: fs(9), design: .monospaced)).foregroundColor(fgDim)
                            }
                            Text(String(format: "Trash: %.0f%%", point.trashRate * 100))
                                .font(.system(size: fs(9)))
                                .foregroundColor(point.trashRate > 0.3 ? .orange : fgDim)
                            if !point.targets.isEmpty {
                                Text(point.targets.prefix(5).map { TargetCatalog.displayName($0) }.joined(separator: ", ")
                                     + (point.targets.count > 5 ? " +\(point.targets.count - 5)" : ""))
                                    .font(.system(size: fs(9))).foregroundColor(fgDim)
                                    .lineLimit(2)
                            }
                            Divider().frame(height: 1)
                            Text("Compare setups side by side. Note: seeing conditions\nvary across nights — compare with matching date ranges.")
                                .font(.system(size: fs(8)))
                                .foregroundColor(fgDim.opacity(0.7))
                                .lineLimit(3)
                        }
                        .offset(tooltipOffset(x: hoverLocation.x, y: hoverLocation.y))
                    }
                }
            }
        }
    }

    // MARK: - Metrics Chart (Temperature vs HFR scatter plot)

    @State private var hoveredMetricsPoint: FrameHistoryModel.MetricsFramePoint?
    @State private var metricsHoverLocation: CGPoint = .zero

    private var metricsChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Controls bar
            HStack(spacing: 12) {
                Text("Temperature vs HFR")
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)

                // Night picker
                Picker("Night", selection: $model.selectedMetricsNight) {
                    Text("All Nights").tag(String?.none)
                    ForEach(model.metricsNights, id: \.self) { night in
                        Text(night).tag(Optional(night))
                    }
                }
                .frame(maxWidth: 180)

                // Filter scope picker
                if model.metricsAvailableFilters.count > 1 {
                    Picker("Filter", selection: $model.metricsFilterScope) {
                        Text("All").tag(FrameHistoryModel.MetricsFilterScope.all)
                        Text("Narrowband").tag(FrameHistoryModel.MetricsFilterScope.narrowband)
                        Text("Broadband").tag(FrameHistoryModel.MetricsFilterScope.broadband)
                        Divider()
                        ForEach(model.metricsAvailableFilters, id: \.self) { f in
                            Text(f).tag(FrameHistoryModel.MetricsFilterScope.specific(f))
                        }
                    }
                    .frame(maxWidth: 130)
                }

                Spacer()

                let label = model.isMetricsLongtermView ? "nights" : "frames"
                Text("\(model.metricsTempHFRPoints.count) \(label)")
                    .font(.system(size: fs(10), design: .monospaced))
                    .foregroundColor(fgDim)
            }

            if model.metricsTempHFRPoints.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "chart.dots.scatter")
                        .font(.system(size: 40))
                        .foregroundColor(fgDim)
                    Text("No data with both HFR and temperature.\nNeed AMBTEMP header in FITS/XISF files.")
                        .font(.system(size: fs(13)))
                        .foregroundColor(fgDim)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(minHeight: 250)
            } else {
                // Scatter plot: X=Temperature, Y=HFR
                Chart {
                    // Scatter points colored by filter
                    ForEach(model.metricsTempHFRPoints) { point in
                        PointMark(
                            x: .value("Temp (°C)", point.ambientTemp!),
                            y: .value("HFR (px)", point.hfr!)
                        )
                        .foregroundStyle(Self.filterColor(for: point.filter).opacity(0.6))
                        .symbolSize(model.isMetricsLongtermView ? 30 : 16)
                    }

                    // Rolling average trend line (sorted by temp, windowed)
                    ForEach(model.metricsTrendLine) { pt in
                        LineMark(
                            x: .value("Temp (°C)", pt.temp),
                            y: .value("HFR (px)", pt.hfr)
                        )
                        .foregroundStyle(AppColors.accent(nightMode).opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxisLabel(position: .bottom) {
                    Text("Ambient Temperature (°C)")
                        .font(.system(size: fs(10)))
                        .foregroundColor(fgDim)
                }
                .chartYAxisLabel(position: .leading) {
                    Text("HFR (px)")
                        .font(.system(size: fs(10)))
                        .foregroundColor(fg)
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            .foregroundStyle(fgDim.opacity(0.3))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%.0f°", v))
                                    .font(.system(size: fs(9), design: .monospaced))
                                    .foregroundColor(fgDim)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            .foregroundStyle(fgDim.opacity(0.2))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%.1f", v))
                                    .font(.system(size: fs(9), design: .monospaced))
                                    .foregroundColor(fg)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartPlotStyle { plot in
                    plot.background(chartBg)
                        .border(AppColors.divider(nightMode), width: 0.5)
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onAppear { chartPlotWidth = geo.size.width }
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    chartPlotWidth = geo.size.width
                                    metricsHoverLocation = location
                                    hoveredMetricsPoint = findNearestMetricsScatter(at: location, proxy: proxy)
                                case .ended:
                                    hoveredMetricsPoint = nil
                                }
                            }
                    }
                }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    if let pt = hoveredMetricsPoint {
                        metricsTooltip(for: pt)
                            .offset(tooltipOffset(x: metricsHoverLocation.x, y: metricsHoverLocation.y, yOffset: -60))
                    }
                }

                // Legend + trend info
                HStack(spacing: 16) {
                    ForEach(model.metricsAvailableFilters, id: \.self) { filter in
                        if model.metricsTempHFRPoints.contains(where: { $0.filter == filter }) {
                            HStack(spacing: 4) {
                                Circle().fill(Self.filterColor(for: filter)).frame(width: 8, height: 8)
                                Text(filter).font(.system(size: fs(9))).foregroundColor(fgDim)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AppColors.accent(nightMode))
                            .frame(width: 14, height: 2.5)
                        Text("Trend (avg)")
                            .font(.system(size: fs(9)))
                            .foregroundColor(fgDim)
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .onAppear { model.loadMetricsData() }
        .onChange(of: model.selectedMetricsNight) { _, _ in model.loadMetricsData() }
    }

    // Find nearest scatter point by normalized Euclidean distance
    private func findNearestMetricsScatter(at location: CGPoint, proxy: ChartProxy) -> FrameHistoryModel.MetricsFramePoint? {
        guard let temp: Double = proxy.value(atX: location.x),
              let hfr: Double = proxy.value(atY: location.y) else { return nil }
        let points = model.metricsTempHFRPoints
        guard !points.isEmpty else { return nil }

        let temps = points.compactMap { $0.ambientTemp }
        let hfrs = points.compactMap { $0.hfr }
        let tScale = max((temps.max() ?? 1) - (temps.min() ?? 0), 1)
        let hScale = max((hfrs.max() ?? 1) - (hfrs.min() ?? 0), 0.1)

        var nearest: FrameHistoryModel.MetricsFramePoint?
        var minDist = Double.infinity
        for p in points {
            let dt = (p.ambientTemp! - temp) / tScale
            let dh = (p.hfr! - hfr) / hScale
            let dist = dt * dt + dh * dh
            if dist < minDist { minDist = dist; nearest = p }
        }
        return minDist < 0.05 ? nearest : nil
    }

    // Metrics tooltip
    private func metricsTooltip(for point: FrameHistoryModel.MetricsFramePoint) -> some View {
        chartTooltip {
            Text(point.filename)
                .font(.system(size: fs(10), weight: .semibold, design: .monospaced))
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(Self.filterColor(for: point.filter)).frame(width: 6, height: 6)
                Text(String(format: "HFR: %.2f px  (%@)", point.hfr ?? 0, point.filter))
                    .font(.system(size: fs(9), design: .monospaced))
            }
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium").font(.system(size: 8)).foregroundColor(.orange)
                Text(String(format: "Temp: %.1f°C", point.ambientTemp ?? 0))
                    .font(.system(size: fs(9), design: .monospaced))
                    .foregroundColor(.orange)
            }
            if let tier = point.qualityTier {
                let tierName = tier == 3 ? "Excellent" : tier == 2 ? "Good" : tier == 1 ? "Borderline" : tier == 0 ? "Trash" : "Uncertain"
                let tierColor: Color = tier == 3 ? .green : tier == 2 ? Color(red: 0.5, green: 0.8, blue: 0.3) : tier == 1 ? .orange : tier == 0 ? .red : .blue
                Text(tierName).font(.system(size: fs(8), weight: .medium)).foregroundColor(tierColor)
            }
            Divider().frame(height: 1)
            // Overall stats for context
            let pts = model.metricsTempHFRPoints
            let hfrs = pts.compactMap { $0.hfr }
            let temps = pts.compactMap { $0.ambientTemp }
            if !hfrs.isEmpty {
                let avgH = hfrs.reduce(0, +) / Double(hfrs.count)
                let medH = hfrs.sorted()[hfrs.count / 2]
                let avgT = temps.isEmpty ? 0 : temps.reduce(0, +) / Double(temps.count)
                Text(String(format: "Overall: HFR avg %.2f, median %.2f (%d pts)\nTemp avg %.1f°C", avgH, medH, pts.count, avgT))
                    .font(.system(size: fs(9), design: .monospaced))
                    .foregroundColor(fgDim)
            }
            Text("Temp vs HFR: focus drift correlation.\nSteep slope → shorten AF interval.")
                .font(.system(size: fs(8)))
                .foregroundColor(fgDim.opacity(0.7))
                .lineLimit(3)
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

    // MARK: - Setup Management (rename, merge, delete, fix FL)

    private func showSetupManagement() {
        guard let hash = model.selectedSetupHash else { return }
        let allHashes = model.mergedSetupHashes[hash] ?? [hash]
        let currentNickname = FrameHistoryDatabase.shared.nickname(for: hash) ?? ""
        let currentFL = FrameHistoryDatabase.shared.primaryFocalLength(for: allHashes)
        let frameCount = allHashes.compactMap { try? FrameHistoryDatabase.shared.frameCount(setupHash: $0) }.reduce(0, +)
        let setupLabel = model.availableSetups.first(where: { $0.hash == hash })?.label ?? hash

        let alert = NSAlert()
        alert.messageText = "Manage Setup"
        alert.informativeText = "\(setupLabel)\n\(frameCount) frames, FL: \(currentFL ?? 0)mm"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Merge Into…")
        alert.addButton(withTitle: "Delete Setup")

        // Accessory view with nickname + FL override
        let container = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 70))
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        // Nickname row
        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        let nameLabel = NSTextField(labelWithString: "Nickname:")
        let nameInput = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameInput.stringValue = currentNickname
        nameInput.placeholderString = "e.g. Big Rig, Travel Scope"
        nameRow.addArrangedSubview(nameLabel)
        nameRow.addArrangedSubview(nameInput)
        container.addArrangedSubview(nameRow)

        // FL override row
        let flRow = NSStackView()
        flRow.orientation = .horizontal
        flRow.spacing = 8
        let flLabel = NSTextField(labelWithString: "Focal Length:")
        let flInput = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        flInput.stringValue = currentFL.map { "\($0)" } ?? ""
        flInput.placeholderString = "mm"
        let flHint = NSTextField(labelWithString: "mm (fix bad plate-solve values)")
        flHint.textColor = .secondaryLabelColor
        flHint.font = .systemFont(ofSize: 10)
        flRow.addArrangedSubview(flLabel)
        flRow.addArrangedSubview(flInput)
        flRow.addArrangedSubview(flHint)
        container.addArrangedSubview(flRow)

        alert.accessoryView = container
        alert.window.initialFirstResponder = nameInput

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Save nickname + FL override
            let nickname = nameInput.stringValue.trimmingCharacters(in: .whitespaces)
            for h in allHashes {
                try? FrameHistoryDatabase.shared.setNickname(nickname.isEmpty ? "" : nickname, for: h)
            }
            if let newFL = Double(flInput.stringValue.trimmingCharacters(in: .whitespaces)),
               newFL > 0, newFL != Double(currentFL ?? 0) {
                for h in allHashes {
                    try? FrameHistoryDatabase.shared.updateFocalLength(setupHash: h, newFL: newFL)
                }
            }
            model.loadData()

        case .alertThirdButtonReturn:
            // Merge Into — show picker for target setup
            showMergeDialog(sourceHash: hash, sourceLabel: setupLabel)

        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            // Delete Setup
            let confirm = NSAlert()
            confirm.messageText = "Delete Setup?"
            confirm.informativeText = "Permanently delete \(frameCount) frame records for \(setupLabel).\n\nThis cannot be undone."
            confirm.alertStyle = .critical
            confirm.addButton(withTitle: "Delete")
            confirm.addButton(withTitle: "Cancel")
            if confirm.runModal() == .alertFirstButtonReturn {
                for h in allHashes {
                    try? FrameHistoryDatabase.shared.deleteSetup(setupHash: h)
                }
                model.selectedSetupHash = nil
                model.loadData()
            }

        default:
            break
        }
    }

    private func showMergeDialog(sourceHash: String, sourceLabel: String) {
        let targets = model.availableSetups.filter { $0.hash != sourceHash }
        guard !targets.isEmpty else {
            let a = NSAlert()
            a.messageText = "No other setup to merge into."
            a.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Merge Setup"
        alert.informativeText = "Merge all frames from \"\(sourceLabel)\" into another setup.\nThe source setup will disappear."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        for target in targets {
            popup.addItem(withTitle: target.label)
            popup.lastItem?.representedObject = target.hash as NSString
        }
        alert.accessoryView = popup

        if alert.runModal() == .alertFirstButtonReturn,
           let targetHash = popup.selectedItem?.representedObject as? String {
            let allSourceHashes = model.mergedSetupHashes[sourceHash] ?? [sourceHash]
            for h in allSourceHashes {
                try? FrameHistoryDatabase.shared.mergeSetups(from: h, into: targetHash)
            }
            model.selectedSetupHash = nil
            model.loadData()
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


    // MARK: - Chart Scroll/Zoom Helpers

    // MARK: - Chart Hover Tooltip Helpers

    /// Transparent overlay that tracks mouse position and resolves to nearest date.
    private func chartHoverTracker(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onAppear { chartPlotWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in chartPlotWidth = w }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                        hoveredDate = proxy.value(atX: location.x, as: Date.self)
                    case .ended:
                        hoveredDate = nil
                    }
                }
        }
    }

    /// Tooltip offset that flips to left side when cursor is near right edge.
    /// Uses hoverLocation.x relative to chart overlay — flips at 55% of chart width.
    @State private var chartPlotWidth: CGFloat = 800

    private func tooltipOffset(x: CGFloat, y: CGFloat, yOffset: CGFloat = -40) -> CGSize {
        let flipsLeft = x > chartPlotWidth * 0.55
        let xOff = flipsLeft ? x - 340 : x + 16
        return CGSize(width: xOff, height: max(0, y + yOffset))
    }

    /// Tooltip container with consistent styling. Font scale doubled for readability.
    private func chartTooltip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
        .padding(8)
        .frame(maxWidth: 380, alignment: .leading)
        .scaleEffect(1.2, anchor: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppColors.bgControl(nightMode).opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 4)
        )
        .foregroundColor(fg)
        .allowsHitTesting(false)
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
