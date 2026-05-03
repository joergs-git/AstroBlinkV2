// Theme + tooltip helpers shared by every chart in the Frame History window.
// Carved out so individual charts can be extracted into their own structs
// (one per session, in priority order) without each one re-deriving colors
// or duplicating the tooltip styling.
import SwiftUI

/// Lightweight theme bundle. Constructed by FrameHistoryContentView once and
/// passed to each extracted chart struct so charts only depend on the theme,
/// not on the parent view's @State.
struct FrameHistoryChartTheme {
    let nightMode: Bool
    let fontScale: CGFloat

    /// Scaled font size — round to whole points so SwiftUI doesn't sub-pixel.
    func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

    var fg: Color       { AppColors.fg(nightMode) }
    var fgDim: Color    { AppColors.fgDim(nightMode) }
    var bg: Color       { AppColors.bg(nightMode) }
    var chartBg: Color  { AppColors.chartBg(nightMode) }
    var bgControl: Color { AppColors.bgControl(nightMode) }

    /// Tooltip container with consistent styling. Font scale 1.2× for readability.
    func chartTooltip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
        .padding(8)
        .frame(maxWidth: 380, alignment: .leading)
        .scaleEffect(1.2, anchor: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(bgControl.opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 4)
        )
        .foregroundColor(fg)
        .allowsHitTesting(false)
    }

    /// Tooltip offset that flips to the left side when cursor is past 55% of chart width.
    /// Caller passes the current plot width (captured per-chart via GeometryReader).
    func tooltipOffset(x: CGFloat, y: CGFloat, plotWidth: CGFloat, yOffset: CGFloat = -40) -> CGSize {
        let flipsLeft = x > plotWidth * 0.55
        let xOff = flipsLeft ? x - 340 : x + 16
        return CGSize(width: xOff, height: max(0, y + yOffset))
    }
}
