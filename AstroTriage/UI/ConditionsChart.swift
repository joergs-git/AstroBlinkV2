// KPI 4 of the Frame History window: scatter of background noise vs.
// chosen environmental factor (moon, seeing, temperature, bortle).
// Color split by broadband vs narrowband filter type.
import SwiftUI
import Charts

struct ConditionsChart: View {
    @ObservedObject var model: FrameHistoryModel
    let theme: FrameHistoryChartTheme

    @State private var hoveredPoint: String?
    @State private var hoverLocation: CGPoint = .zero
    @State private var plotWidth: CGFloat = 800

    var body: some View {
        let allPoints = model.conditionsPoints
        let factor = model.selectedConditionsFactor
        let points = allPoints.filter { p in
            switch factor {
            case .moon: return p.moonPct != nil
            case .seeing: return p.fwhm != nil
            case .temperature: return p.ambientTemp != nil
            case .bortle: return p.bortle != nil
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Conditions Impact on Background")
                    .font(.system(size: theme.fs(13), weight: .semibold))
                    .foregroundColor(theme.fg)
                Spacer()
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
                        .font(.system(size: theme.fs(13))).foregroundColor(theme.fgDim)
                    Spacer()
                }
                .frame(minHeight: 200)
            } else {
                Chart(points) { point in
                    let xValue = xValue(for: point, factor: factor)
                    PointMark(
                        x: .value(factor.rawValue, xValue),
                        y: .value("Background", point.background)
                    )
                    .foregroundStyle(point.isBroadband ? Color.blue : Color.orange)
                    .symbolSize(hoveredPoint == point.id ? 80 : 30)
                }
                .chartXAxisLabel(factor.rawValue)
                .chartYAxisLabel("Background Noise (MAD)")
                .modifier(PercentileYScale(values: points.map(\.background)))
                .chartPlotStyle { plot in plot.background(theme.chartBg).clipped() }
                .chartOverlay { proxy in scatterHoverTracker(proxy: proxy, points: points, factor: factor) }
                .frame(minHeight: 300)
                .overlay(alignment: .topLeading) {
                    tooltipOverlay(points: points)
                }

                HStack(spacing: 16) {
                    HStack(spacing: 4) { Circle().fill(.blue).frame(width: 7); Text("Broadband (LRGB)").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
                    HStack(spacing: 4) { Circle().fill(.orange).frame(width: 7); Text("Narrowband").font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
                    Spacer()
                    Text("Each dot = one night+filter combo")
                        .font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                }
            }
        }
    }

    // MARK: - Subviews

    private func xValue(for p: FrameHistoryModel.ConditionsPoint, factor: FrameHistoryModel.ConditionsFactor) -> Double {
        switch factor {
        case .moon: return p.moonPct ?? 0
        case .seeing: return p.fwhm ?? 0
        case .temperature: return p.ambientTemp ?? 0
        case .bortle: return p.bortle ?? 0
        }
    }

    private func scatterHoverTracker(proxy: ChartProxy, points: [FrameHistoryModel.ConditionsPoint], factor: FrameHistoryModel.ConditionsFactor) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onAppear { plotWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in plotWidth = w }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        hoverLocation = loc
                        guard let xVal: Double = proxy.value(atX: loc.x),
                              let yVal: Double = proxy.value(atY: loc.y) else {
                            hoveredPoint = nil
                            return
                        }
                        let xRange = points.map { xValue(for: $0, factor: factor) }
                        let xSpan = (xRange.max() ?? 1) - (xRange.min() ?? 0)
                        let ySpan = (points.map(\.background).max() ?? 1) - (points.map(\.background).min() ?? 0)
                        guard xSpan > 0, ySpan > 0 else { hoveredPoint = nil; return }
                        let nearest = points.min(by: { a, b in
                            let ax = xValue(for: a, factor: factor)
                            let bx = xValue(for: b, factor: factor)
                            let da = pow((ax - xVal) / xSpan, 2) + pow((a.background - yVal) / ySpan, 2)
                            let db = pow((bx - xVal) / xSpan, 2) + pow((b.background - yVal) / ySpan, 2)
                            return da < db
                        })
                        hoveredPoint = nearest?.id
                    case .ended:
                        hoveredPoint = nil
                    }
                }
        }
    }

    @ViewBuilder
    private func tooltipOverlay(points: [FrameHistoryModel.ConditionsPoint]) -> some View {
        if let hid = hoveredPoint,
           let point = points.first(where: { $0.id == hid }) {
            theme.chartTooltip {
                Text(point.night).font(.system(size: theme.fs(10), weight: .bold))
                if let t = point.target {
                    Text(TargetCatalog.displayName(TargetCatalog.canonicalName(t)))
                        .font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                }
                Text("\(FrameHistoryModel.normalizeFilterForChart(point.filter)) — \(point.isBroadband ? "Broadband" : "Narrowband") (\(point.frameCount) frames)")
                    .font(.system(size: theme.fs(9)))
                Divider().frame(height: 1)
                if let m = point.moonPct { Text(String(format: "Moon: %.0f%%", m)).font(.system(size: theme.fs(9))).foregroundColor(m > 60 ? .orange : theme.fgDim) }
                if let f = point.fwhm { Text(String(format: "FWHM: %.1f px", f)).font(.system(size: theme.fs(9))).foregroundColor(f > 6 ? .orange : theme.fgDim) }
                if let t = point.ambientTemp { Text(String(format: "Temp: %.0f°C", t)).font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim) }
                if let b = point.bortle { Text(String(format: "Bortle: %.1f", b)).font(.system(size: theme.fs(9))).foregroundColor(b > 6 ? .orange : theme.fgDim) }
                Text(String(format: "Background: %.5f", point.background)).font(.system(size: theme.fs(9), design: .monospaced)).foregroundColor(theme.fgDim)
                Divider().frame(height: 1)
                Text("Background level = sky brightness. Higher = light pollution/moon.\nNarrowband is less affected than broadband by moonlight.")
                    .font(.system(size: theme.fs(8)))
                    .foregroundColor(theme.fgDim.opacity(0.7))
                    .lineLimit(3)
            }
            .offset(theme.tooltipOffset(x: hoverLocation.x, y: hoverLocation.y, plotWidth: plotWidth))
        }
    }
}
