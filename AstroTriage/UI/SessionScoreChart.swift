// KPI 1 of the Frame History window: composite session score per night.
// Bars colored by score band (red < 25, orange 25-49, yellow 50-74, green 75+),
// optional monthly-median trend line overlaid when ≥6 months of data exist.
//
// Self-contained hover state — each chart owns its own tooltip rather than
// sharing one across all charts (which was the previous behavior and caused
// hover artifacts to ripple between unrelated charts).
import SwiftUI
import Charts

struct SessionScoreChart: View {
    @ObservedObject var model: FrameHistoryModel
    let theme: FrameHistoryChartTheme

    @State private var hoveredDate: Date?
    @State private var hoverLocation: CGPoint = .zero
    @State private var plotWidth: CGFloat = 800

    var body: some View {
        let scores = model.sessionScores
        let medians = model.monthlyMedianScores
        let showTrend = !medians.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            Text("Session Score by Night")
                .font(.system(size: theme.fs(13), weight: .semibold))
                .foregroundColor(theme.fg)

            if scores.isEmpty {
                noDataView
            } else {
                let allTimeMedian = model.allTimeMedianSessionScore
                Chart {
                    ForEach(scores) { point in
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
                    if let median = allTimeMedian {
                        // Long-term baseline: lets the user read tonight's bar
                        // against their cumulative median at a glance. Only
                        // drawn when ≥5 sessions exist (computed in the model)
                        // so the line is statistically meaningful.
                        RuleMark(y: .value("All-time median", median))
                            .foregroundStyle(theme.fg.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("median \(Int(median.rounded()))")
                                    .font(.system(size: theme.fs(9), design: .monospaced))
                                    .foregroundColor(theme.fgDim)
                                    .padding(.trailing, 2)
                            }
                    }
                    if showTrend {
                        ForEach(medians) { point in
                            LineMark(
                                x: .value("Month", point.date, unit: .month),
                                y: .value("Median", point.score),
                                series: .value("Trend", "median")
                            )
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.catmullRom)
                            PointMark(
                                x: .value("Month", point.date, unit: .month),
                                y: .value("Median", point.score)
                            )
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .symbolSize(30)
                        }
                    }
                    if let hd = hoveredDate {
                        RuleMark(x: .value("Hover", hd, unit: .day))
                            .foregroundStyle(theme.fg.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Score (0-100)")
                .chartPlotStyle { plot in plot.background(theme.chartBg).clipped() }
                .chartOverlay { proxy in hoverTracker(proxy: proxy) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    tooltipOverlay(scores: scores)
                }

                legendRow(showTrend: showTrend, scores: scores)
                Text("Score = 40% retention + 30% FWHM quality + 20% trailing + 10% stability\(allTimeMedian != nil ? " · Dashed line = all-time median" : "")\(showTrend ? " · White line = monthly median" : "")")
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
    private func tooltipOverlay(scores: [FrameHistoryModel.SessionScorePoint]) -> some View {
        if let hd = hoveredDate,
           let point = scores.min(by: { $0.date.timeIntervalSince(hd).magnitude < $1.date.timeIntervalSince(hd).magnitude }),
           point.date.timeIntervalSince(hd).magnitude < 30 * 86400 {
            theme.chartTooltip {
                Text(point.night).font(.system(size: theme.fs(10), weight: .bold))
                Text(String(format: "Score: %.0f — %d frames, %.0f%% kept", point.score, point.frameCount, point.retentionRate * 100))
                    .font(.system(size: theme.fs(10)))
                if !point.targets.isEmpty {
                    Text(point.targets.map { TargetCatalog.displayName($0) }.joined(separator: ", "))
                        .font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                }
                HStack(spacing: 8) {
                    if !point.filters.isEmpty {
                        Text(point.filters.joined(separator: "/")).font(.system(size: theme.fs(9)))
                    }
                    if let fwhm = point.avgFWHM {
                        Text(String(format: "FWHM %.1f", fwhm)).font(.system(size: theme.fs(9)))
                    }
                    if let moon = point.moonPct {
                        Text(String(format: "Moon %.0f%%", moon)).font(.system(size: theme.fs(9)))
                            .foregroundColor(moon > 60 ? .orange : theme.fgDim)
                    }
                }
                .foregroundColor(theme.fgDim)
                Divider().frame(height: 1)
                if let s = model.scoreChartStats {
                    Text(String(format: "Overall: avg %.0f, median %.0f", s.avg, s.median))
                        .font(.system(size: theme.fs(9), design: .monospaced))
                        .foregroundColor(theme.fgDim)
                }
                Text("Composite score: FWHM, retention, seeing.\nHigher = better. Watch for seasonal patterns.")
                    .font(.system(size: theme.fs(8)))
                    .foregroundColor(theme.fgDim.opacity(0.7))
                    .lineLimit(3)
            }
            .offset(theme.tooltipOffset(x: hoverLocation.x, y: hoverLocation.y, plotWidth: plotWidth))
        }
    }

    private func legendRow(showTrend: Bool, scores: [FrameHistoryModel.SessionScorePoint]) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) { Circle().fill(.green).frame(width: 6); Text("75+").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            HStack(spacing: 3) { Circle().fill(.yellow).frame(width: 6); Text("50-74").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            HStack(spacing: 3) { Circle().fill(.orange).frame(width: 6); Text("25-49").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            HStack(spacing: 3) { Circle().fill(.red).frame(width: 6); Text("<25").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
            if showTrend {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.7)).frame(width: 14, height: 2)
                    Text("Median").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                }
            }
            Spacer()
            let avg = scores.map(\.score).reduce(0, +) / Double(scores.count)
            Text("Avg: \(String(format: "%.0f", avg))")
                .font(.system(size: theme.fs(11), weight: .medium, design: .monospaced))
                .foregroundColor(theme.fg)
            if let best = scores.max(by: { $0.score < $1.score }) {
                Text("Best: \(String(format: "%.0f", best.score)) (\(best.night))")
                    .font(.system(size: theme.fs(11), design: .monospaced))
                    .foregroundColor(theme.fgDim)
            }
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
}
