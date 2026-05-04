// Domain types for FrameHistoryModel — split from the aggregation logic
// in FrameHistoryModel.swift so a reader can scan the data carriers
// (chart point structs, picker enums, summary structs) without paging
// through the SQLite-query and percentile-clamp methods that drive them.
//
// These were originally nested inside the FrameHistoryModel class body;
// declaring them in an `extension FrameHistoryModel` keeps every existing
// reference site (`FrameHistoryModel.MetricType`, `FrameHistoryModel.SessionScorePoint`,
// etc.) working unchanged — Swift looks nested types up by enclosing
// type, not by declaration file.
//
// Pure mechanical move. No behavior changes; no @Published properties move
// here (those stay on the class because they require ObservableObject).
import Foundation

extension FrameHistoryModel {

    // MARK: - Chart Configuration

    enum MetricType: String, CaseIterable, Identifiable {
        case fwhm = "FWHM"
        case hfr = "HFR"
        case starCount = "Stars"
        case noise = "Noise"
        case trailing = "Trailing"
        case eccentricity = "Ecc"
        var id: String { rawValue }
    }

    enum ChartType: String, CaseIterable, Identifiable {
        case sessionScore = "Score"
        case efficiency = "Efficiency"
        case performance = "Performance"
        case conditions = "Conditions"
        case progress = "Progress"
        case setups = "Setups"
        case metrics = "Metrics"
        var id: String { rawValue }
    }

    // MARK: - Metrics Chart Domain

    enum MetricsFilterScope: Hashable {
        case all
        case narrowband
        case broadband
        case specific(String)
    }

    /// Per-frame data point for the metrics chart
    struct MetricsFramePoint: Identifiable {
        let id: String       // fileHash
        let date: Date
        let hfr: Double?
        let ambientTemp: Double?
        let filter: String
        let filename: String
        let qualityTier: Int?
        let pierSide: String?
    }

    /// AF/MF event marker
    struct MetricsEvent: Identifiable {
        let id = UUID()
        let date: Date
        let type: MetricsEventType
    }
    enum MetricsEventType { case meridianFlip }

    /// Rolling average trend line: bin by 1°C temperature buckets, average HFR within each bin
    struct TrendPoint: Identifiable {
        let id = UUID()
        let temp: Double
        let hfr: Double
    }

    // MARK: - Time Range Filter

    enum TimeRange: String, CaseIterable, Identifiable {
        case all = "All"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case nineMonths = "9M"
        case twelveMonths = "12M"
        case twoYears = "24M"
        case threeYears = "36M"
        var id: String { rawValue }

        /// Cutoff date for filtering (nil = no filter)
        var cutoffDate: Date? {
            guard self != .all else { return nil }
            let months: Int
            switch self {
            case .all: return nil
            case .threeMonths: months = 3
            case .sixMonths: months = 6
            case .nineMonths: months = 9
            case .twelveMonths: months = 12
            case .twoYears: months = 24
            case .threeYears: months = 36
            }
            return Calendar.current.date(byAdding: .month, value: -months, to: Date())
        }
    }

    // MARK: - Aggregated Chart Data

    /// Per-night (or per-month) quality tier breakdown (for stacked bar chart).
    struct NightQuality: Identifiable {
        var id: String { night }  // Stable ID — night string is unique per entry
        let night: String
        let date: Date
        let excellent: Int
        let good: Int
        let borderline: Int
        let trash: Int
        var total: Int { excellent + good + borderline + trash }
    }

    /// Per-night metric values by filter (for multi-line chart).
    struct MetricPoint: Identifiable {
        var id: String { "\(night)_\(filter)" }  // Stable ID
        let night: String
        let date: Date        // Parsed date for proper X-axis sorting
        let filter: String    // Normalized filter name
        let value: Double
    }

    /// Multi-factor conditions data point — carries all environmental factors per night+filter.
    struct ConditionsPoint: Identifiable {
        let id: String              // Stable ID from night+filter
        let night: String
        let target: String?
        let filter: String
        let isBroadband: Bool
        let background: Double      // Y-axis: background noise (MAD)
        // X-axis factors (user selects which one via toggle)
        let moonPct: Double?        // Moon illumination %
        let fwhm: Double?           // FWHM (proxy for seeing)
        let ambientTemp: Double?    // Temperature (°C)
        let bortle: Double?         // Bortle sky quality
        let frameCount: Int
    }

    /// Selected X-axis factor for the Conditions chart
    enum ConditionsFactor: String, CaseIterable, Identifiable {
        case moon = "Moon %"
        case seeing = "FWHM (seeing)"
        case temperature = "Temperature"
        case bortle = "Bortle"
        var id: String { rawValue }
    }

    /// Setup comparison data (all setups, one bar per setup per metric).
    struct SetupMetric: Identifiable {
        var id: String { setupLabel }  // Stable ID
        let setupLabel: String
        let value: Double
        // Rich context for tooltip
        let totalFrames: Int
        let firstNight: String?
        let lastNight: String?
        let trashRate: Double
        let targets: [String]
    }

    // MARK: - KPI Domain Types

    /// KPI 1: Session Score (0-100) — composite quality + retention + FWHM index
    struct SessionScorePoint: Identifiable {
        var id: String { night }  // Stable ID
        let date: Date
        let night: String
        let score: Double       // 0-100 composite score (median when monthly)
        let retentionRate: Double  // % kept
        let fwhmNormalized: Double // relative to setup median (1.0 = average, <1 = better)
        let frameCount: Int
        // Context for tooltip
        let targets: [String]
        let filters: [String]
        let avgFWHM: Double?
        let moonPct: Double?
        let nightCount: Int?    // Number of nights in this month (nil for daily view)
    }

    /// KPI 2: Imaging Efficiency — per-night kept/trash breakdown
    struct EfficiencyPoint: Identifiable {
        var id: String { night }  // Stable ID
        let date: Date
        let night: String
        let total: Int
        let excellent: Int
        let good: Int
        let borderline: Int
        let trash: Int
        var retentionPct: Double { total > 0 ? Double(excellent + good) / Double(total) * 100 : 0 }
        // Context for tooltip
        let targets: [String]       // Targets imaged that night
        let filters: [String]       // Filters used
        let avgFWHM: Double?        // Average FWHM
        let moonPct: Double?        // Moon illumination %
    }

    /// KPI 3: Seeing Index — theoretical-FWHM / actual-FWHM (1.0 = diffraction limited)
    struct SeeingPoint: Identifiable {
        var id: String { "\(night)_\(filter)" }  // Stable ID
        let date: Date
        let night: String
        let seeingIndex: Double   // theoretical/actual — 1.0 = diffraction limited
        let actualFWHM: Double    // arcseconds
        let filter: String
    }

    /// KPI 4: Integration Progress — per-target hours rollup
    struct TargetProgress: Identifiable {
        var id: String { target }  // Stable ID — target name is unique per entry
        let target: String
        let totalIntegrationHours: Double     // Total integration time in hours
        let usableIntegrationHours: Double    // Excluding trash, in hours
        let nightCount: Int
        let bestFWHM: Double?
        let avgRetention: Double              // % kept
        let filterBreakdown: [FilterIntegration]  // Per-filter detail
    }

    struct FilterIntegration: Identifiable {
        let id: String  // Stable ID — set at creation as "target_filter"
        let filter: String
        let hours: Double                     // Usable integration hours
        let frameCount: Int
    }

    /// KPI 5: Equipment Health — rolling-average FWHM trend
    struct HealthTrendPoint: Identifiable {
        var id: String { night }  // Stable ID
        let date: Date
        let night: String
        let rollingFWHM: Double     // Configurable rolling average
        let rawFWHM: Double
    }

    /// Summary statistics shown in the cards above charts
    struct SummaryStats {
        let totalFrames: Int
        let totalNights: Int
        let bestFWHM: Double?        // Best (lowest) median FWHM across all nights
        let avgTrashRate: Double     // Percentage of frames that are trash
        let totalTargets: Int
    }
}
