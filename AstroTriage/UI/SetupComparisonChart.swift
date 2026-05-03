// Setup Comparison chart of the Frame History window: bar chart comparing
// the selected metric (FWHM/HFR/eccentricity/etc.) across equipment setups.
import SwiftUI
import Charts

struct SetupComparisonChart: View {
    @ObservedObject var model: FrameHistoryModel
    let theme: FrameHistoryChartTheme

    @State private var hoveredSetup: String?
    @State private var hoverLocation: CGPoint = .zero
    @State private var plotWidth: CGFloat = 800

    private let maxLabelLen = 25

    var body: some View {
        let points = model.setupComparisonPoints(for: model.selectedMetric)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Setup Comparison")
                    .font(.system(size: theme.fs(13), weight: .semibold))
                    .foregroundColor(theme.fg)
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
                        .foregroundColor(theme.fgDim)
                    Text("Need at least 2 setups to compare.\nLoad sessions from different telescope/camera combos.")
                        .font(.system(size: theme.fs(13)))
                        .foregroundColor(theme.fgDim)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(minHeight: 200)
            } else {
                Chart(points) { point in
                    let label = truncate(point.setupLabel)
                    BarMark(
                        x: .value("Setup", label),
                        y: .value(model.selectedMetric.rawValue, point.value),
                        width: .fixed(min(80, max(30, 400 / CGFloat(points.count))))
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .annotation(position: .top) {
                        Text(String(format: "%.1f", point.value))
                            .font(.system(size: theme.fs(10)))
                            .foregroundColor(theme.fgDim)
                    }
                }
                .chartYAxisLabel(model.selectedMetric.rawValue)
                .modifier(PercentileYScale(values: points.map(\.value)))
                .chartPlotStyle { plot in plot.background(theme.chartBg).clipped() }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: theme.fs(9)))
                    }
                }
                .chartOverlay { proxy in hoverTracker(proxy: proxy, points: points) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    tooltipOverlay(points: points)
                }
            }
        }
    }

    // MARK: - Subviews

    private func truncate(_ label: String) -> String {
        label.count > maxLabelLen ? String(label.prefix(maxLabelLen)) + "…" : label
    }

    private func hoverTracker(proxy: ChartProxy, points: [FrameHistoryModel.SetupMetric]) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onAppear { plotWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in plotWidth = w }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        hoverLocation = loc
                        if let label: String = proxy.value(atX: loc.x) {
                            hoveredSetup = points.first(where: {
                                truncate($0.setupLabel) == label
                            })?.setupLabel
                        }
                    case .ended:
                        hoveredSetup = nil
                    }
                }
        }
    }

    @ViewBuilder
    private func tooltipOverlay(points: [FrameHistoryModel.SetupMetric]) -> some View {
        if let hLabel = hoveredSetup,
           let point = points.first(where: { $0.setupLabel == hLabel }) {
            theme.chartTooltip {
                Text(point.setupLabel).font(.system(size: theme.fs(10), weight: .bold))
                Text(String(format: "%@ = %.2f", model.selectedMetric.rawValue, point.value))
                    .font(.system(size: theme.fs(10)))
                Divider().frame(height: 1)
                Text("\(point.totalFrames) frames")
                    .font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                if let first = point.firstNight, let last = point.lastNight {
                    Text("\(first) — \(last)")
                        .font(.system(size: theme.fs(9), design: .monospaced)).foregroundColor(theme.fgDim)
                }
                Text(String(format: "Trash: %.0f%%", point.trashRate * 100))
                    .font(.system(size: theme.fs(9)))
                    .foregroundColor(point.trashRate > 0.3 ? .orange : theme.fgDim)
                if !point.targets.isEmpty {
                    Text(point.targets.prefix(5).map { TargetCatalog.displayName($0) }.joined(separator: ", ")
                         + (point.targets.count > 5 ? " +\(point.targets.count - 5)" : ""))
                        .font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                        .lineLimit(2)
                }
                Divider().frame(height: 1)
                Text("Compare setups side by side. Note: seeing conditions\nvary across nights — compare with matching date ranges.")
                    .font(.system(size: theme.fs(8)))
                    .foregroundColor(theme.fgDim.opacity(0.7))
                    .lineLimit(3)
            }
            .offset(theme.tooltipOffset(x: hoverLocation.x, y: hoverLocation.y, plotWidth: plotWidth))
        }
    }
}
