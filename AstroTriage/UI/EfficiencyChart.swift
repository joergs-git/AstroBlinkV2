// KPI 2 of the Frame History window: per-night frame retention rate
// (excellent+good / total) bar chart with cause hints for bad nights.
import SwiftUI
import Charts

struct EfficiencyChart: View {
    @ObservedObject var model: FrameHistoryModel
    let theme: FrameHistoryChartTheme

    @State private var hoveredDate: Date?
    @State private var hoverLocation: CGPoint = .zero
    @State private var plotWidth: CGFloat = 800

    var body: some View {
        let data = model.efficiencyData
        VStack(alignment: .leading, spacing: 4) {
            Text("Imaging Efficiency — Frames Kept vs Lost")
                .font(.system(size: theme.fs(13), weight: .semibold))
                .foregroundColor(theme.fg)

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
                    if let hd = hoveredDate, point.date.timeIntervalSince(hd).magnitude < 30 * 86400 {
                        RuleMark(x: .value("Hover", point.date, unit: .day))
                            .foregroundStyle(theme.fg.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Frames Kept %")
                .chartPlotStyle { plot in plot.background(theme.chartBg).clipped() }
                .chartOverlay { proxy in hoverTracker(proxy: proxy) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    tooltipOverlay(data: data)
                }

                legendRow(data: data)
                Text("Excellent + Good frames / Total frames per night")
                    .font(.system(size: theme.fs(9)))
                    .foregroundColor(theme.fgDim)
            }
        }
    }

    // MARK: - Subviews

    private func hoverTracker(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onAppear { plotWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in plotWidth = w }
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

    @ViewBuilder
    private func tooltipOverlay(data: [FrameHistoryModel.EfficiencyPoint]) -> some View {
        if let hd = hoveredDate,
           let point = data.min(by: { $0.date.timeIntervalSince(hd).magnitude < $1.date.timeIntervalSince(hd).magnitude }),
           point.date.timeIntervalSince(hd).magnitude < 30 * 86400 {
            theme.chartTooltip {
                Text(point.night).font(.system(size: theme.fs(10), weight: .bold))
                Text(String(format: "%.0f%% kept — %d frames", point.retentionPct, point.total))
                    .font(.system(size: theme.fs(10)))
                Text("\(point.excellent) excellent, \(point.good) good, \(point.borderline) borderline, \(point.trash) trash")
                    .font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                if !point.targets.isEmpty {
                    Text(point.targets.map { TargetCatalog.displayName($0) }.joined(separator: ", "))
                        .font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                }
                HStack(spacing: 8) {
                    if !point.filters.isEmpty {
                        Text(point.filters.joined(separator: "/")).font(.system(size: theme.fs(9)))
                    }
                    if let fwhm = point.avgFWHM {
                        Text(String(format: "FWHM %.1f px", fwhm)).font(.system(size: theme.fs(9)))
                            .foregroundColor(fwhm > 6 ? .orange : theme.fgDim)
                    }
                    if let moon = point.moonPct {
                        Text(String(format: "Moon %.0f%%", moon)).font(.system(size: theme.fs(9)))
                            .foregroundColor(moon > 60 ? .orange : theme.fgDim)
                    }
                }
                .foregroundColor(theme.fgDim)
                if point.retentionPct < 50 {
                    let causes = Self.badNightCauses(point)
                    if !causes.isEmpty {
                        Text("Likely: " + causes.joined(separator: ", "))
                            .font(.system(size: theme.fs(9), weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
                Divider().frame(height: 1)
                if let s = model.efficiencyChartStats {
                    Text(String(format: "Overall: avg %.0f%%, median %.0f%%", s.avg, s.median))
                        .font(.system(size: theme.fs(9), design: .monospaced))
                        .foregroundColor(theme.fgDim)
                }
                Text("Retention = usable frames kept after culling.\n<50% often means clouds, wind, or equipment issues.")
                    .font(.system(size: theme.fs(8)))
                    .foregroundColor(theme.fgDim.opacity(0.7))
                    .lineLimit(3)
            }
            .offset(theme.tooltipOffset(x: hoverLocation.x, y: hoverLocation.y, plotWidth: plotWidth))
        }
    }

    private func legendRow(data: [FrameHistoryModel.EfficiencyPoint]) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) { Circle().fill(.green).frame(width: 6); Text("80%+").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            HStack(spacing: 3) { Circle().fill(.yellow).frame(width: 6); Text("60-79%").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            HStack(spacing: 3) { Circle().fill(.orange).frame(width: 6); Text("40-59%").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            HStack(spacing: 3) { Circle().fill(.red).frame(width: 6); Text("<40%").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            Spacer()
            let avgEfficiency = data.map(\.retentionPct).reduce(0, +) / Double(data.count)
            let totalFrames = data.reduce(0) { $0 + $1.total }
            let totalKept = data.reduce(0) { $0 + $1.excellent + $1.good }
            Text("Avg: \(String(format: "%.0f%%", avgEfficiency))")
                .font(.system(size: theme.fs(11), weight: .medium, design: .monospaced))
                .foregroundColor(theme.fg)
            Text("\(totalKept)/\(totalFrames) kept overall")
                .font(.system(size: theme.fs(11), design: .monospaced))
                .foregroundColor(theme.fgDim)
        }
    }

    private var noDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundColor(theme.fgDim.opacity(0.4))
            Text("No data yet")
                .font(.system(size: theme.fs(12)))
                .foregroundColor(theme.fgDim)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    /// Heuristic cause hint for sub-50% retention nights.
    static func badNightCauses(_ point: FrameHistoryModel.EfficiencyPoint) -> [String] {
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
}
