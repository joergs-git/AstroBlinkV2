// Shared color constants for night mode and standard mode.
// Use these across ALL windows for consistent appearance.
// Night mode: black background + red UI for dark-adapted vision at the telescope.

import SwiftUI

enum AppColors {

    // MARK: - Text

    static func fg(_ night: Bool) -> Color {
        night ? .red : Color(NSColor.labelColor)
    }

    static func fgDim(_ night: Bool) -> Color {
        night ? .red.opacity(0.7) : Color(NSColor.secondaryLabelColor)
    }

    static func fgVeryDim(_ night: Bool) -> Color {
        night ? .red.opacity(0.4) : Color(NSColor.tertiaryLabelColor)
    }

    // MARK: - Backgrounds

    static func bg(_ night: Bool) -> Color {
        night ? .black : Color(NSColor.windowBackgroundColor)
    }

    static func bgToolbar(_ night: Bool) -> Color {
        night ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor)
    }

    static func bgControl(_ night: Bool) -> Color {
        night ? Color(red: 0.08, green: 0, blue: 0) : Color(NSColor.controlBackgroundColor)
    }

    static func bgInput(_ night: Bool) -> Color {
        night ? Color(red: 0.12, green: 0, blue: 0) : Color(NSColor.textBackgroundColor)
    }

    // MARK: - Dividers

    static func divider(_ night: Bool) -> Color {
        night ? Color(red: 0.3, green: 0, blue: 0) : Color(NSColor.separatorColor)
    }

    // MARK: - Accents

    static func accent(_ night: Bool) -> Color {
        night ? Color(red: 0.7, green: 0, blue: 0) : .accentColor
    }

    static func green(_ night: Bool) -> Color {
        night ? Color(red: 0.5, green: 0, blue: 0) : .green
    }

    static func orange(_ night: Bool) -> Color {
        night ? Color(red: 0.5, green: 0.2, blue: 0) : .orange
    }

    // MARK: - Chart Colors (night-adapted)

    static func chartGrid(_ night: Bool) -> Color {
        night ? Color(red: 0.2, green: 0, blue: 0) : Color(NSColor.separatorColor).opacity(0.5)
    }

    static func chartBg(_ night: Bool) -> Color {
        night ? Color(red: 0.04, green: 0, blue: 0) : Color(NSColor.controlBackgroundColor)
    }
}
