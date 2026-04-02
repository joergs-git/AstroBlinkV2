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
                    if let hd = hoveredDate, Calendar.current.isDate(hd, inSameDayAs: point.date) {
                        RuleMark(x: .value("Hover", point.date, unit: .day))
                            .foregroundStyle(fg.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Score (0-100)")
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: Self.scrollVisibleDomain)
                .chartScrollPosition(initialX: scores.last?.date.addingTimeInterval(-Self.scrollVisibleDomain) ?? Date())
                .chartPlotStyle { plot in plot.background(chartBg).clipped() }
                .chartOverlay { proxy in chartHoverTracker(proxy: proxy) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    if let hd = hoveredDate,
                       let point = scores.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }) {
                        chartTooltip {
                            Text(point.night).font(.system(size: fs(10), weight: .bold))
                            Text(String(format: "Score: %.0f — %d frames, %.0f%% kept", point.score, point.frameCount, point.retentionRate * 100))
                                .font(.system(size: fs(10)))
                            if !point.targets.isEmpty {
                                Text(point.targets.map { TargetCatalog.displayName($0) }.joined(separator: ", "))
                                    .font(.system(size: fs(9))).foregroundColor(fgDim)
                            }
                            HStack(spacing: 8) {
                                if !point.filters.isEmpty {
                                    Text(point.filters.joined(separator: "/")).font(.system(size: fs(9)))
                                }
                                if let fwhm = point.avgFWHM {
                                    Text(String(format: "FWHM %.1f", fwhm)).font(.system(size: fs(9)))
                                }
                                if let moon = point.moonPct {
                                    Text(String(format: "Moon %.0f%%", moon)).font(.system(size: fs(9)))
                                        .foregroundColor(moon > 60 ? .orange : fgDim)
                                }
                            }
                            .foregroundColor(fgDim)
                        }
                        .offset(x: hoverLocation.x + 12, y: max(0, hoverLocation.y - 40))
                    }
                }

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
                    if let hd = hoveredDate, Calendar.current.isDate(hd, inSameDayAs: point.date) {
                        RuleMark(x: .value("Hover", point.date, unit: .day))
                            .foregroundStyle(fg.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Frames Kept %")
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: Self.scrollVisibleDomain)
                .chartScrollPosition(initialX: data.last?.date.addingTimeInterval(-Self.scrollVisibleDomain) ?? Date())
                .chartPlotStyle { plot in plot.background(chartBg).clipped() }
                .chartOverlay { proxy in chartHoverTracker(proxy: proxy) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    if let hd = hoveredDate,
                       let point = data.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hd) }) {
                        chartTooltip {
                            Text(point.night).font(.system(size: fs(10), weight: .bold))
                            Text(String(format: "%.0f%% kept — %d frames", point.retentionPct, point.total))
                                .font(.system(size: fs(10)))
                            Text("\(point.excellent) excellent, \(point.good) good, \(point.borderline) borderline, \(point.trash) trash")
                                .font(.system(size: fs(9))).foregroundColor(fgDim)
                            if !point.targets.isEmpty {
                                Text(point.targets.map { TargetCatalog.displayName($0) }.joined(separator: ", "))
                                    .font(.system(size: fs(9))).foregroundColor(fgDim)
                            }
                            HStack(spacing: 8) {
                                if !point.filters.isEmpty {
                                    Text(point.filters.joined(separator: "/")).font(.system(size: fs(9)))
                                }
                                if let fwhm = point.avgFWHM {
                                    Text(String(format: "FWHM %.1f px", fwhm)).font(.system(size: fs(9)))
                                        .foregroundColor(fwhm > 6 ? .orange : fgDim)
                                }
                                if let moon = point.moonPct {
                                    Text(String(format: "Moon %.0f%%", moon)).font(.system(size: fs(9)))
                                        .foregroundColor(moon > 60 ? .orange : fgDim)
                                }
                            }
                            .foregroundColor(fgDim)
                            // Highlight likely cause for bad nights
                            if point.retentionPct < 50 {
                                let causes = badNightCauses(point)
                                if !causes.isEmpty {
                                    Text("Likely: " + causes.joined(separator: ", "))
                                        .font(.system(size: fs(9), weight: .medium))
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .offset(x: hoverLocation.x + 12, y: max(0, hoverLocation.y - 40))
                    }
                }

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
                // Rolling average window picker
                Picker("Window", selection: $model.rollingWindowSize) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("20").tag(20)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("Rolling average window (sessions)")
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
                    if let hd = hoveredDate {
                        RuleMark(x: .value("Hover", hd))
                            .foregroundStyle(fg.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYAxisLabel("FWHM (px)")
                .modifier(PercentileYScale(values: data.map(\.rawFWHM)))
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: Self.scrollVisibleDomain)
                .chartScrollPosition(initialX: data.last?.date.addingTimeInterval(-Self.scrollVisibleDomain) ?? Date())
                .chartPlotStyle { plot in plot.background(chartBg).clipped() }
                .chartOverlay { proxy in chartHoverTracker(proxy: proxy) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    if let hd = hoveredDate,
                       let point = data.min(by: { Swift.abs($0.date.timeIntervalSince(hd)) < Swift.abs($1.date.timeIntervalSince(hd)) }),
                       Swift.abs(point.date.timeIntervalSince(hd)) < 86400 * 3 {
                        chartTooltip {
                            Text(point.night).font(.system(size: fs(10), weight: .bold))
                            Text(String(format: "FWHM: %.2f px  (rolling: %.2f)", point.rawFWHM, point.rollingFWHM))
                                .font(.system(size: fs(10)))
                            // Per-setup breakdown when "All Setups" selected
                            if model.selectedSetupHash == nil {
                                let perSetup = (try? FrameHistoryDatabase.shared.perSetupFWHM(night: point.night)) ?? []
                                if perSetup.count > 1 {
                                    Divider().frame(height: 1)
                                    ForEach(Array(perSetup.prefix(5).enumerated()), id: \.offset) { _, entry in
                                        HStack(spacing: 4) {
                                            Text(entry.setup).font(.system(size: fs(9)))
                                                .lineLimit(1).foregroundColor(fgDim)
                                            Spacer()
                                            Text(String(format: "%.2f px", entry.fwhm))
                                                .font(.system(size: fs(9), weight: .medium, design: .monospaced))
                                                .foregroundColor(entry.fwhm > point.rawFWHM * 1.2 ? .orange : fg)
                                        }
                                    }
                                }
                            }
                        }
                        .offset(x: hoverLocation.x + 12, y: max(0, hoverLocation.y - 40))
                    }
                }

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(fgDim.opacity(0.4)).frame(width: 6)
                        Text("Per-night FWHM").font(.system(size: fs(9))).foregroundColor(fgDim)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(AppColors.accent(nightMode)).frame(width: 16, height: 2)
                        Text("\(model.rollingWindowSize)-session rolling avg").font(.system(size: fs(9))).foregroundColor(fgDim)
                    }
                }
            }
        }
    }

    // KPI 4: Conditions — environmental factor impact on background noise
    @State private var hoveredConditionsPoint: String?  // ID of hovered point

    private var conditionsChart: some View {
        let allPoints = model.conditionsPoints
        // Filter to points that have the selected X-axis factor
        let factor = model.selectedConditionsFactor
        let points = allPoints.filter { p in
            switch factor {
            case .moon: return p.moonPct != nil
            case .seeing: return p.fwhm != nil
            case .temperature: return p.ambientTemp != nil
            case .bortle: return p.bortle != nil
            }
        }

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Conditions Impact on Background")
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)
                Spacer()
                // Factor selector
                Picker("Factor", selection: $model.selectedConditionsFactor) {
                    ForEach(FrameHistoryModel.ConditionsFactor.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 350)
            }

            if points.isEmpty {
                VStack {
                    Spacer()
                    Text("No \(factor.rawValue) data available for selected filters")
                        .font(.system(size: fs(13))).foregroundColor(fgDim)
                    Spacer()
                }
                .frame(minHeight: 200)
            } else {
                Chart(points) { point in
                    let xValue: Double = {
                        switch factor {
                        case .moon: return point.moonPct ?? 0
                        case .seeing: return point.fwhm ?? 0
                        case .temperature: return point.ambientTemp ?? 0
                        case .bortle: return point.bortle ?? 0
                        }
                    }()
                    PointMark(
                        x: .value(factor.rawValue, xValue),
                        y: .value("Background", point.background)
                    )
                    .foregroundStyle(point.isBroadband ? Color.blue : Color.orange)
                    .symbolSize(hoveredConditionsPoint == point.id ? 80 : 30)
                }
                .chartXAxisLabel(factor.rawValue)
                .chartYAxisLabel("Background Noise (MAD)")
                .modifier(PercentileYScale(values: points.map(\.background)))
                .chartPlotStyle { plot in plot.background(chartBg).clipped() }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    hoverLocation = loc
                                    // Find nearest point by distance
                                    guard let xVal: Double = proxy.value(atX: loc.x),
                                          let yVal: Double = proxy.value(atY: loc.y) else {
                                        hoveredConditionsPoint = nil
                                        return
                                    }
                                    let xRange = points.compactMap({ p -> Double? in
                                        switch factor {
                                        case .moon: return p.moonPct
                                        case .seeing: return p.fwhm
                                        case .temperature: return p.ambientTemp
                                        case .bortle: return p.bortle
                                        }
                                    })
                                    let xSpan = (xRange.max() ?? 1) - (xRange.min() ?? 0)
                                    let ySpan = (points.map(\.background).max() ?? 1) - (points.map(\.background).min() ?? 0)
                                    guard xSpan > 0, ySpan > 0 else { hoveredConditionsPoint = nil; return }

                                    let nearest = points.min(by: { a, b in
                                        let ax: Double = { switch factor { case .moon: return a.moonPct ?? 0; case .seeing: return a.fwhm ?? 0; case .temperature: return a.ambientTemp ?? 0; case .bortle: return a.bortle ?? 0 } }()
                                        let bx: Double = { switch factor { case .moon: return b.moonPct ?? 0; case .seeing: return b.fwhm ?? 0; case .temperature: return b.ambientTemp ?? 0; case .bortle: return b.bortle ?? 0 } }()
                                        let da = pow((ax - xVal) / xSpan, 2) + pow((a.background - yVal) / ySpan, 2)
                                        let db = pow((bx - xVal) / xSpan, 2) + pow((b.background - yVal) / ySpan, 2)
                                        return da < db
                                    })
                                    hoveredConditionsPoint = nearest?.id
                                case .ended:
                                    hoveredConditionsPoint = nil
                                }
                            }
                    }
                }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    if let hid = hoveredConditionsPoint,
                       let point = points.first(where: { $0.id == hid }) {
                        chartTooltip {
                            Text(point.night).font(.system(size: fs(10), weight: .bold))
                            if let t = point.target { Text(TargetCatalog.displayName(TargetCatalog.canonicalName(t))).font(.system(size: fs(9))).foregroundColor(fgDim) }
                            Text("\(FrameHistoryModel.normalizeFilterForChart(point.filter)) — \(point.isBroadband ? "Broadband" : "Narrowband") (\(point.frameCount) frames)")
                                .font(.system(size: fs(9)))
                            Divider().frame(height: 1)
                            if let m = point.moonPct { Text(String(format: "Moon: %.0f%%", m)).font(.system(size: fs(9))).foregroundColor(m > 60 ? .orange : fgDim) }
                            if let f = point.fwhm { Text(String(format: "FWHM: %.1f px", f)).font(.system(size: fs(9))).foregroundColor(f > 6 ? .orange : fgDim) }
                            if let t = point.ambientTemp { Text(String(format: "Temp: %.0f°C", t)).font(.system(size: fs(9))).foregroundColor(fgDim) }
                            if let b = point.bortle { Text(String(format: "Bortle: %.1f", b)).font(.system(size: fs(9))).foregroundColor(b > 6 ? .orange : fgDim) }
                            Text(String(format: "Background: %.5f", point.background)).font(.system(size: fs(9), design: .monospaced)).foregroundColor(fgDim)
                        }
                        .offset(x: hoverLocation.x + 12, y: max(0, hoverLocation.y - 40))
                    }
                }

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) { Circle().fill(.blue).frame(width: 7); Text("Broadband (LRGB)").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    HStack(spacing: 4) { Circle().fill(.orange).frame(width: 7); Text("Narrowband").font(.system(size: fs(9))).foregroundColor(fgDim) }
                    Spacer()
                    Text("Each dot = one night+filter combo")
                        .font(.system(size: fs(9))).foregroundColor(fgDim)
                }
            }
        }
    }

    // KPI 5: Target Progress — integration hours per target with per-filter breakdown
    // Hover state for progress chart
    @State private var hoveredTarget: String?

    private var targetProgressChart: some View {
        let data = Array(model.targetProgressData.prefix(15))  // Top 15 targets
        // Stable max — always use absolute max regardless of sort direction
        let maxHours = data.map(\.usableIntegrationHours).max() ?? 1

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Integration Progress by Target")
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundColor(fg)
                Spacer()
                // Sort toggle
                Button(action: { model.progressSortAscending.toggle() }) {
                    HStack(spacing: 2) {
                        Image(systemName: model.progressSortAscending ? "arrow.up" : "arrow.down")
                        Text("Hours")
                    }
                    .font(.system(size: fs(10)))
                }
                .buttonStyle(.plain)
                .foregroundColor(fgDim)
                .help(model.progressSortAscending ? "Sorted: least hours first" : "Sorted: most hours first")

                let totalHours = data.reduce(0.0) { $0 + $1.usableIntegrationHours }
                Text(String(format: "Total: %.1fh usable", totalHours))
                    .font(.system(size: fs(11), design: .monospaced))
                    .foregroundColor(fgDim)
            }

            if data.isEmpty {
                noDataView
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(data) { target in
                            progressRow(target: target, maxHours: maxHours)
                        }
                    }
                }
                .frame(minHeight: min(500, max(300, CGFloat(data.count) * 44)))

                // Filter legend
                HStack(spacing: 10) {
                    let allFilters = FrameHistoryModel.sortedFilters(Array(Set(data.flatMap { $0.filterBreakdown.map(\.filter) })))
                    ForEach(allFilters, id: \.self) { filter in
                        HStack(spacing: 3) {
                            Circle().fill(Self.filterColor(for: filter)).frame(width: 7, height: 7)
                            Text(filter).font(.system(size: fs(9))).foregroundColor(fgDim)
                        }
                    }
                    Spacer()
                    Text("Usable frames only (excellent + good + borderline)")
                        .font(.system(size: fs(9)))
                        .foregroundColor(fgDim)
                }
            }
        }
    }

    /// Single target progress row with label, stacked bar, and hover detail.
    private func progressRow(target: FrameHistoryModel.TargetProgress, maxHours: Double) -> some View {
        let displayName = TargetCatalog.displayName(target.target)
        let isHovered = hoveredTarget == target.target
        let barFraction = maxHours > 0 ? target.usableIntegrationHours / maxHours : 0

        return VStack(alignment: .leading, spacing: 2) {
            // Target name + hours
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: fs(11), weight: .medium))
                    .foregroundColor(fg)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1fh", target.usableIntegrationHours))
                    .font(.system(size: fs(11), weight: .bold, design: .monospaced))
                    .foregroundColor(fg)
                Text(String(format: "/ %.1fh (%.0f%%)", target.totalIntegrationHours, target.avgRetention * 100))
                    .font(.system(size: fs(9), design: .monospaced))
                    .foregroundColor(fgDim)
            }

            // Stacked filter bar
            GeometryReader { geo in
                let totalWidth = geo.size.width * barFraction
                HStack(spacing: 0) {
                    ForEach(target.filterBreakdown) { fi in
                        let segWidth = target.usableIntegrationHours > 0
                            ? totalWidth * (fi.hours / target.usableIntegrationHours)
                            : 0
                        Rectangle()
                            .fill(Self.filterColor(for: fi.filter))
                            .frame(width: max(segWidth, segWidth > 0 ? 2 : 0), height: 14)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)

            // Hover detail: per-filter breakdown
            if isHovered {
                HStack(spacing: 12) {
                    ForEach(target.filterBreakdown) { fi in
                        HStack(spacing: 3) {
                            Circle().fill(Self.filterColor(for: fi.filter)).frame(width: 6, height: 6)
                            Text(String(format: "%@ %.1fh (%d)", fi.filter, fi.hours, fi.frameCount))
                                .font(.system(size: fs(9), design: .monospaced))
                                .foregroundColor(fgDim)
                        }
                    }
                    if target.nightCount > 0 {
                        Text("\(target.nightCount) nights")
                            .font(.system(size: fs(9)))
                            .foregroundColor(fgDim)
                    }
                    if let fwhm = target.bestFWHM {
                        Text(String(format: "Best FWHM: %.1f", fwhm))
                            .font(.system(size: fs(9)))
                            .foregroundColor(fgDim)
                    }
                }
                .padding(.top, 1)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? AppColors.bgControl(nightMode).opacity(0.5) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredTarget = hovering ? target.target : nil
            }
        }
    }

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
                        }
                        .offset(x: hoverLocation.x + 12, y: max(0, hoverLocation.y - 40))
                    }
                }
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

    // MARK: - Bad Night Cause Analysis

    /// Analyze an efficiency data point and suggest likely causes for poor retention.
    private func badNightCauses(_ point: FrameHistoryModel.EfficiencyPoint) -> [String] {
        var causes: [String] = []
        if let fwhm = point.avgFWHM, fwhm > 8 { causes.append("bad seeing (FWHM \(String(format: "%.1f", fwhm)))") }
        else if let fwhm = point.avgFWHM, fwhm > 5 { causes.append("mediocre seeing") }
        if let moon = point.moonPct, moon > 70 {
            let hasBroadband = point.filters.contains(where: { ["L", "R", "G", "B"].contains($0) })
            if hasBroadband { causes.append("bright moon + broadband") }
        }
        if point.trash > point.total / 2 { causes.append("high trash rate") }
        if point.total < 10 { causes.append("very few frames") }
        return causes
    }

    // MARK: - Chart Scroll/Zoom Helpers

    /// Visible window for scrollable date-axis charts (90 days in seconds).
    /// Charts with date > 90 days can be scrolled horizontally to see older data.
    private static let scrollVisibleDomain: TimeInterval = 90 * 24 * 3600

    // MARK: - Chart Hover Tooltip Helpers

    /// Transparent overlay that tracks mouse position and resolves to nearest date.
    private func chartHoverTracker(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
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

    /// Tooltip container with consistent styling.
    private func chartTooltip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .padding(6)
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
