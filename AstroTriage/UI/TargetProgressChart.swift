// KPI 5 of the Frame History window: integration hours per target with
// per-filter breakdown. Top-15 targets shown as horizontal stacked bars
// (each filter colored). Hover reveals per-filter exact hours + nights.
import SwiftUI

struct TargetProgressChart: View {
    @ObservedObject var model: FrameHistoryModel
    let theme: FrameHistoryChartTheme

    @State private var hoveredTarget: String?

    var body: some View {
        let data = Array(model.targetProgressData.prefix(15))
        let maxHours = data.map(\.usableIntegrationHours).max() ?? 1

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Integration Progress by Target")
                    .font(.system(size: theme.fs(13), weight: .semibold))
                    .foregroundColor(theme.fg)
                Spacer()
                Button(action: { model.progressSortAscending.toggle() }) {
                    HStack(spacing: 2) {
                        Image(systemName: model.progressSortAscending ? "arrow.up" : "arrow.down")
                        Text("Hours")
                    }
                    .font(.system(size: theme.fs(10)))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.fgDim)
                .help(model.progressSortAscending ? "Sorted: least hours first" : "Sorted: most hours first")

                let totalHours = data.reduce(0.0) { $0 + $1.usableIntegrationHours }
                Text(String(format: "Total: %.1fh usable", totalHours))
                    .font(.system(size: theme.fs(11), design: .monospaced))
                    .foregroundColor(theme.fgDim)
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

                HStack(spacing: 10) {
                    let allFilters = FrameHistoryModel.sortedFilters(Array(Set(data.flatMap { $0.filterBreakdown.map(\.filter) })))
                    ForEach(allFilters, id: \.self) { filter in
                        HStack(spacing: 3) {
                            Circle().fill(FrameHistoryContentView.filterColor(for: filter)).frame(width: 7, height: 7)
                            Text(filter).font(.system(size: theme.fs(9))).foregroundColor(theme.fgDim)
                        }
                    }
                    Spacer()
                    Text("Usable frames only (excellent + good + borderline)")
                        .font(.system(size: theme.fs(9)))
                        .foregroundColor(theme.fgDim)
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
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: theme.fs(11), weight: .medium))
                    .foregroundColor(theme.fg)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1fh", target.usableIntegrationHours))
                    .font(.system(size: theme.fs(11), weight: .bold, design: .monospaced))
                    .foregroundColor(theme.fg)
                Text(String(format: "/ %.1fh (%.0f%%)", target.totalIntegrationHours, target.avgRetention * 100))
                    .font(.system(size: theme.fs(9), design: .monospaced))
                    .foregroundColor(theme.fgDim)
            }

            GeometryReader { geo in
                let totalWidth = geo.size.width * barFraction
                HStack(spacing: 0) {
                    ForEach(target.filterBreakdown) { fi in
                        let segWidth = target.usableIntegrationHours > 0
                            ? totalWidth * (fi.hours / target.usableIntegrationHours)
                            : 0
                        Rectangle()
                            .fill(FrameHistoryContentView.filterColor(for: fi.filter))
                            .frame(width: max(segWidth, segWidth > 0 ? 2 : 0), height: 14)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)

            if isHovered {
                HStack(spacing: 12) {
                    ForEach(target.filterBreakdown) { fi in
                        HStack(spacing: 3) {
                            Circle().fill(FrameHistoryContentView.filterColor(for: fi.filter)).frame(width: 6, height: 6)
                            Text(String(format: "%@ %.1fh (%d)", fi.filter, fi.hours, fi.frameCount))
                                .font(.system(size: theme.fs(9), design: .monospaced))
                                .foregroundColor(theme.fgDim)
                        }
                    }
                    if target.nightCount > 0 {
                        Text("\(target.nightCount) nights")
                            .font(.system(size: theme.fs(9)))
                            .foregroundColor(theme.fgDim)
                    }
                    if let fwhm = target.bestFWHM {
                        Text(String(format: "Best FWHM: %.1f", fwhm))
                            .font(.system(size: theme.fs(9)))
                            .foregroundColor(theme.fgDim)
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
                .fill(isHovered ? AppColors.bgControl(theme.nightMode).opacity(0.5) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredTarget = hovering ? target.target : nil
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
