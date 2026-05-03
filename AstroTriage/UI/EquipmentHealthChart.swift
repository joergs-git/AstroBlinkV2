// KPI 3 of the Frame History window: rolling FWHM trend per setup.
// Per-night raw FWHM (faint dots) + rolling average line + an Improving/
// Degrading hint based on first-vs-last 3 sessions.
import SwiftUI
import Charts

struct EquipmentHealthChart: View {
    @ObservedObject var model: FrameHistoryModel
    let theme: FrameHistoryChartTheme

    @State private var hoveredDate: Date?
    @State private var hoverLocation: CGPoint = .zero
    @State private var plotWidth: CGFloat = 800

    var body: some View {
        let data = model.equipmentHealthData
        let setupLabel = model.selectedSetupHash == nil ? "All Setups" : "This Setup"
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Equipment Health — FWHM Trend (\(setupLabel))")
                    .font(.system(size: theme.fs(13), weight: .semibold))
                    .foregroundColor(theme.fg)
                Spacer()
                if model.selectedSetupHash == nil {
                    Text("Select a setup above for accurate tracking")
                        .font(.system(size: theme.fs(9)))
                        .foregroundColor(.orange)
                }
                Picker("Window", selection: $model.rollingWindowSize) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("20").tag(20)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("Rolling average window (sessions)")
                if data.count >= 5 {
                    let recent = data.suffix(3).map(\.rollingFWHM).reduce(0, +) / 3.0
                    let earlier = data.prefix(3).map(\.rollingFWHM).reduce(0, +) / 3.0
                    let improving = recent < earlier
                    HStack(spacing: 4) {
                        Image(systemName: improving ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundColor(improving ? .green : .orange)
                        Text(improving ? "Improving" : "Degrading")
                            .font(.system(size: theme.fs(11)))
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
                        .foregroundStyle(theme.fgDim.opacity(0.4))
                        .symbolSize(15)
                    }
                    ForEach(data) { point in
                        LineMark(
                            x: .value("Night", point.date),
                            y: .value("Rolling Avg", point.rollingFWHM)
                        )
                        .foregroundStyle(AppColors.accent(theme.nightMode))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let hd = hoveredDate {
                        RuleMark(x: .value("Hover", hd))
                            .foregroundStyle(theme.fg.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYAxisLabel("FWHM (px)")
                .modifier(PercentileYScale(values: data.map(\.rawFWHM)))
                .chartPlotStyle { plot in plot.background(theme.chartBg).clipped() }
                .chartOverlay { proxy in hoverTracker(proxy: proxy) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    tooltipOverlay(data: data)
                }

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(theme.fgDim.opacity(0.4)).frame(width: 6)
                        Text("Per-night FWHM").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(AppColors.accent(theme.nightMode)).frame(width: 16, height: 2)
                        Text("\(model.rollingWindowSize)-session rolling avg").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                    }
                }
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
    private func tooltipOverlay(data: [FrameHistoryModel.HealthTrendPoint]) -> some View {
        if let hd = hoveredDate,
           let point = data.min(by: { $0.date.timeIntervalSince(hd).magnitude < $1.date.timeIntervalSince(hd).magnitude }),
           point.date.timeIntervalSince(hd).magnitude < 86400 * 3 {
            theme.chartTooltip {
                Text(point.night).font(.system(size: theme.fs(10), weight: .bold))
                Text(String(format: "FWHM: %.2f px  (rolling: %.2f)", point.rawFWHM, point.rollingFWHM))
                    .font(.system(size: theme.fs(10)))
                if model.selectedSetupHash == nil {
                    let perSetup = (try? FrameHistoryDatabase.shared.perSetupFWHM(night: point.night)) ?? []
                    if perSetup.count > 1 {
                        Divider().frame(height: 1)
                        ForEach(Array(perSetup.prefix(5).enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 4) {
                                Text(entry.setup).font(.system(size: theme.fs(9)))
                                    .lineLimit(1).foregroundColor(theme.fgDim)
                                Spacer()
                                Text(String(format: "%.2f px", entry.fwhm))
                                    .font(.system(size: theme.fs(9), weight: .medium, design: .monospaced))
                                    .foregroundColor(entry.fwhm > point.rawFWHM * 1.2 ? .orange : theme.fg)
                            }
                        }
                    }
                }
                Divider().frame(height: 1)
                if let s = model.fwhmChartStats {
                    Text(String(format: "Overall: avg %.2f, median %.2f, MAD %.2f px", s.avg, s.median, s.mad))
                        .font(.system(size: theme.fs(9), design: .monospaced))
                        .foregroundColor(theme.fgDim)
                }
                Text("FWHM = star width in pixels. Lower = sharper.\nRising trend → collimation drift, tilt, or dew.")
                    .font(.system(size: theme.fs(8)))
                    .foregroundColor(theme.fgDim.opacity(0.7))
                    .lineLimit(3)
            }
            .offset(theme.tooltipOffset(x: hoverLocation.x, y: hoverLocation.y, plotWidth: plotWidth))
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
