// Metrics chart of the Frame History window: per-frame Temperature vs HFR
// scatter plot. Shows focus drift correlation with ambient temperature, with
// optional rolling-average trend line and per-night vs all-nights aggregation.
import SwiftUI
import Charts

struct MetricsChart: View {
    @ObservedObject var model: FrameHistoryModel
    let theme: FrameHistoryChartTheme

    @State private var hoveredPoint: FrameHistoryModel.MetricsFramePoint?
    @State private var hoverLocation: CGPoint = .zero
    @State private var plotWidth: CGFloat = 800

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            controlsBar

            if model.metricsTempHFRPoints.isEmpty {
                emptyState
            } else {
                scatterChart
                legendRow
            }
        }
        .onAppear { model.loadMetricsData() }
        .onChange(of: model.selectedMetricsNight) { _, _ in model.loadMetricsData() }
    }

    // MARK: - Subviews

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Text("Temperature vs HFR")
                .font(.system(size: theme.fs(13), weight: .semibold))
                .foregroundColor(theme.fg)

            Picker("Night", selection: $model.selectedMetricsNight) {
                Text("All Nights").tag(String?.none)
                ForEach(model.metricsNights, id: \.self) { night in
                    Text(night).tag(Optional(night))
                }
            }
            .frame(maxWidth: 180)

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
                .font(.system(size: theme.fs(10), design: .monospaced))
                .foregroundColor(theme.fgDim)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 40))
                .foregroundColor(theme.fgDim)
            Text("No data with both HFR and temperature.\nNeed AMBTEMP header in FITS/XISF files.")
                .font(.system(size: theme.fs(13)))
                .foregroundColor(theme.fgDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(minHeight: 250)
    }

    private var scatterChart: some View {
        Chart {
            ForEach(model.metricsTempHFRPoints) { point in
                PointMark(
                    x: .value("Temp (°C)", point.ambientTemp!),
                    y: .value("HFR (px)", point.hfr!)
                )
                .foregroundStyle(FrameHistoryContentView.filterColor(for: point.filter).opacity(0.6))
                .symbolSize(model.isMetricsLongtermView ? 30 : 16)
            }

            ForEach(model.metricsTrendLine) { pt in
                LineMark(
                    x: .value("Temp (°C)", pt.temp),
                    y: .value("HFR (px)", pt.hfr)
                )
                .foregroundStyle(AppColors.accent(theme.nightMode).opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxisLabel(position: .bottom) {
            Text("Ambient Temperature (°C)")
                .font(.system(size: theme.fs(10)))
                .foregroundColor(theme.fgDim)
        }
        .chartYAxisLabel(position: .leading) {
            Text("HFR (px)")
                .font(.system(size: theme.fs(10)))
                .foregroundColor(theme.fg)
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(theme.fgDim.opacity(0.3))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f°", v))
                            .font(.system(size: theme.fs(9), design: .monospaced))
                            .foregroundColor(theme.fgDim)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(theme.fgDim.opacity(0.2))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.1f", v))
                            .font(.system(size: theme.fs(9), design: .monospaced))
                            .foregroundColor(theme.fg)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(theme.chartBg)
                .border(AppColors.divider(theme.nightMode), width: 0.5)
        }
        .chartOverlay { proxy in hoverTracker(proxy: proxy) }
        .frame(minHeight: 300)
        .overlay(alignment: .topLeading) {
            if let pt = hoveredPoint {
                tooltip(for: pt)
                    .offset(theme.tooltipOffset(x: hoverLocation.x, y: hoverLocation.y, plotWidth: plotWidth, yOffset: -60))
            }
        }
    }

    private func hoverTracker(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onAppear { plotWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in plotWidth = w }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                        hoveredPoint = findNearest(at: location, proxy: proxy)
                    case .ended:
                        hoveredPoint = nil
                    }
                }
        }
    }

    private var legendRow: some View {
        HStack(spacing: 16) {
            ForEach(model.metricsAvailableFilters, id: \.self) { filter in
                if model.metricsTempHFRPoints.contains(where: { $0.filter == filter }) {
                    HStack(spacing: 4) {
                        Circle().fill(FrameHistoryContentView.filterColor(for: filter)).frame(width: 8, height: 8)
                        Text(filter).font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                    }
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(AppColors.accent(theme.nightMode))
                    .frame(width: 14, height: 2.5)
                Text("Trend (avg)")
                    .font(.system(size: theme.fs(9)))
                    .foregroundColor(theme.fgDim)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Hover helpers

    /// Find nearest scatter point by normalized Euclidean distance.
    /// Threshold chosen empirically (0.05 in unit-square space) to avoid showing
    /// tooltips for points far from the cursor.
    private func findNearest(at location: CGPoint, proxy: ChartProxy) -> FrameHistoryModel.MetricsFramePoint? {
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

    private func tooltip(for point: FrameHistoryModel.MetricsFramePoint) -> some View {
        theme.chartTooltip {
            Text(point.filename)
                .font(.system(size: theme.fs(10), weight: .semibold, design: .monospaced))
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(FrameHistoryContentView.filterColor(for: point.filter)).frame(width: 6, height: 6)
                Text(String(format: "HFR: %.2f px  (%@)", point.hfr ?? 0, point.filter))
                    .font(.system(size: theme.fs(9), design: .monospaced))
            }
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium").font(.system(size: 8)).foregroundColor(.orange)
                Text(String(format: "Temp: %.1f°C", point.ambientTemp ?? 0))
                    .font(.system(size: theme.fs(9), design: .monospaced))
                    .foregroundColor(.orange)
            }
            if let tier = point.qualityTier {
                let tierName = tier == 3 ? "Excellent" : tier == 2 ? "Good" : tier == 1 ? "Borderline" : tier == 0 ? "Trash" : "Uncertain"
                let tierColor: Color = tier == 3 ? .green : tier == 2 ? Color(red: 0.5, green: 0.8, blue: 0.3) : tier == 1 ? .orange : tier == 0 ? .red : .blue
                Text(tierName).font(.system(size: theme.fs(8), weight: .medium)).foregroundColor(tierColor)
            }
            Divider().frame(height: 1)
            let pts = model.metricsTempHFRPoints
            let hfrs = pts.compactMap { $0.hfr }
            let temps = pts.compactMap { $0.ambientTemp }
            if !hfrs.isEmpty {
                let avgH = hfrs.reduce(0, +) / Double(hfrs.count)
                let medH = hfrs.sorted()[hfrs.count / 2]
                let avgT = temps.isEmpty ? 0 : temps.reduce(0, +) / Double(temps.count)
                Text(String(format: "Overall: HFR avg %.2f, median %.2f (%d pts)\nTemp avg %.1f°C", avgH, medH, pts.count, avgT))
                    .font(.system(size: theme.fs(9), design: .monospaced))
                    .foregroundColor(theme.fgDim)
            }
            Text("Temp vs HFR: focus drift correlation.\nSteep slope → shorten AF interval.")
                .font(.system(size: theme.fs(8)))
                .foregroundColor(theme.fgDim.opacity(0.7))
                .lineLimit(3)
        }
    }
}
