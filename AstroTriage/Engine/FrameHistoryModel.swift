import Foundation

/// ViewModel for the Frame History window.
/// Queries FrameHistoryDatabase and prepares data for SwiftUI Charts.
class FrameHistoryModel: ObservableObject {

    // MARK: - Filters

    @Published var selectedSetupHash: String?
    @Published var selectedTarget: String?

    // MARK: - Data

    @Published var nightlySummaries: [NightSummary] = []
    @Published var availableSetups: [(hash: String, label: String)] = []
    @Published var availableTargets: [String] = []
    @Published var stats: (frameCount: Int, sessionCount: Int, firstNight: String?, lastNight: String?)?

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

    @Published var selectedMetric: MetricType = .fwhm

    enum ChartType: String, CaseIterable, Identifiable {
        case qualityTimeline = "Quality"
        case metricTrend = "Metrics"
        case moonImpact = "Moon"
        case setupComparison = "Setups"
        var id: String { rawValue }
    }

    @Published var selectedChart: ChartType = .qualityTimeline

    // MARK: - Load Data

    func loadData() {
        // Get database stats
        stats = try? FrameHistoryDatabase.shared.databaseStats()

        // Get available setups (distinct telescope+camera combos)
        loadAvailableSetups()

        // Load trend data for selected setup
        loadNightlyTrend()
    }

    private func loadAvailableSetups() {
        do {
            let sessions = try FrameHistoryDatabase.shared.sessions()
            let nicknames = FrameHistoryDatabase.shared.allNicknames()
            var seen: Set<String> = []
            var setups: [(hash: String, label: String)] = []
            for session in sessions {
                guard let hash = session.setupHash, !seen.contains(hash) else { continue }
                seen.insert(hash)
                let equipment = [session.telescope, session.camera].compactMap { $0 }.joined(separator: " + ")
                let label: String
                if let nickname = nicknames[hash] {
                    label = nickname + (equipment.isEmpty ? "" : " (\(equipment))")
                } else {
                    label = equipment.isEmpty ? hash.prefix(8).description : equipment
                }
                setups.append((hash: hash, label: label))
            }
            availableSetups = setups

            // Default: "All Setups" (nil) — shows consolidated view
        } catch {
            print("FrameHistoryModel: loadAvailableSetups failed: \(error)")
        }
    }

    func loadNightlyTrend() {
        do {
            if let setupHash = selectedSetupHash {
                nightlySummaries = try FrameHistoryDatabase.shared.nightlyTrend(
                    setupHash: setupHash,
                    target: selectedTarget
                )
            } else {
                // "All Setups" — query across all setups
                nightlySummaries = try FrameHistoryDatabase.shared.nightlyTrendAll(
                    target: selectedTarget
                )
            }

            // Build available targets from summaries
            let targets = Set(nightlySummaries.compactMap(\.target)).sorted()
            availableTargets = targets
        } catch {
            print("FrameHistoryModel: loadNightlyTrend failed: \(error)")
        }
    }

    // MARK: - Aggregated Chart Data

    /// Per-night quality tier breakdown (for stacked bar chart).
    struct NightQuality: Identifiable {
        let id = UUID()
        let night: String
        let excellent: Int
        let good: Int
        let borderline: Int
        let trash: Int
        var total: Int { excellent + good + borderline + trash }
    }

    var nightlyQuality: [NightQuality] {
        // Aggregate summaries by night (sum across filters)
        var byNight: [String: (exc: Int, good: Int, bord: Int, trash: Int)] = [:]
        for s in nightlySummaries {
            let key = s.night
            var val = byNight[key] ?? (0, 0, 0, 0)
            val.exc += s.excellentCount
            val.good += s.goodCount
            val.bord += s.borderlineCount
            val.trash += s.trashCount
            byNight[key] = val
        }
        return byNight.map { (night, val) in
            NightQuality(night: night, excellent: val.exc, good: val.good,
                        borderline: val.bord, trash: val.trash)
        }.sorted { $0.night < $1.night }
    }

    /// Per-night metric values by filter (for multi-line chart).
    struct MetricPoint: Identifiable {
        let id = UUID()
        let night: String
        let filter: String
        let value: Double
    }

    func metricPoints(for metric: MetricType) -> [MetricPoint] {
        nightlySummaries.compactMap { s in
            let value: Double?
            switch metric {
            case .fwhm:     value = s.medianFWHM
            case .hfr:      value = s.medianHFR
            case .starCount: value = s.medianStarCount
            case .noise:    value = s.medianNoise
            case .trailing: value = s.medianTrailing
            case .eccentricity: value = nil  // Not aggregated in NightSummary
            }
            guard let v = value else { return nil }
            return MetricPoint(night: s.night, filter: s.filter ?? "?", value: v)
        }
    }

    /// Moon impact data points (for scatter chart).
    struct MoonPoint: Identifiable {
        let id = UUID()
        let moonIllumination: Double
        let background: Double
        let filter: String
        let isBroadband: Bool
    }

    var moonPoints: [MoonPoint] {
        nightlySummaries.compactMap { s in
            guard let moon = s.medianMoonIllumination,
                  let noise = s.medianNoise,
                  let filter = s.filter else { return nil }
            let canonical = filter.uppercased()
            let isBroadband = ["L", "R", "G", "B"].contains(canonical)
            return MoonPoint(moonIllumination: moon * 100, background: noise,
                           filter: filter, isBroadband: isBroadband)
        }
    }

    /// Setup comparison data (all setups, one bar per setup per metric).
    struct SetupMetric: Identifiable {
        let id = UUID()
        let setupLabel: String
        let value: Double
    }

    // MARK: - Percentile Clamping

    /// Compute percentile-based Y-axis range for a set of values.
    /// Returns (min, max) where values outside P2–P98 are considered outliers.
    /// Adds 5% padding above for visual breathing room.
    static func percentileRange(_ values: [Double], lower: Double = 0.02, upper: Double = 0.98) -> (min: Double, max: Double)? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard sorted.count >= 3 else { return nil }

        let lowerIdx = Int(Double(sorted.count - 1) * lower)
        let upperIdx = Int(Double(sorted.count - 1) * upper)
        let pLow = sorted[lowerIdx]
        let pHigh = sorted[upperIdx]

        // Ensure non-zero range
        guard pHigh > pLow else { return nil }

        let padding = (pHigh - pLow) * 0.05
        let rangeMin = max(0, pLow - padding)  // Never go below 0 for counts/metrics
        let rangeMax = pHigh + padding
        return (rangeMin, rangeMax)
    }

    /// Count of outlier values above P98 for a given metric (for annotation display).
    func outlierCount(for metric: MetricType) -> Int {
        let points = metricPoints(for: metric)
        guard let range = Self.percentileRange(points.map(\.value)) else { return 0 }
        return points.filter { $0.value > range.max }.count
    }

    func setupComparisonPoints(for metric: MetricType) -> [SetupMetric] {
        availableSetups.compactMap { setup in
            guard let summary = try? FrameHistoryDatabase.shared.setupSummary(setupHash: setup.hash) else {
                return nil
            }
            let value: Double
            switch metric {
            case .fwhm:       value = summary.medianFWHM
            case .hfr:        value = summary.medianFWHM * 0.6  // approximate
            case .starCount:  value = summary.medianStarCount
            case .noise:      value = summary.medianNoise
            case .trailing:   value = summary.medianTrailing
            case .eccentricity: value = 0
            }
            guard value > 0 else { return nil }
            return SetupMetric(setupLabel: setup.label, value: value)
        }
    }
}
