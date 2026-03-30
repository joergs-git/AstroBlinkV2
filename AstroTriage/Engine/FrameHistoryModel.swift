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
        case sessionScore = "Score"
        case efficiency = "Efficiency"
        case performance = "Performance"
        case conditions = "Conditions"
        case progress = "Progress"
        case setups = "Setups"
        var id: String { rawValue }
    }

    @Published var selectedChart: ChartType = .sessionScore

    // Time range filter
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

    @Published var selectedTimeRange: TimeRange = .all

    // Rolling average window size for Performance chart
    @Published var rollingWindowSize: Int = 5

    // Stale records indicator (older algorithm version)
    @Published var staleRecordCount: Int = 0

    // MARK: - Load Data

    func loadData() {
        // Get database stats
        stats = try? FrameHistoryDatabase.shared.databaseStats()

        // Check for stale records
        staleRecordCount = (try? FrameHistoryDatabase.shared.staleRecordCount()) ?? 0

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

            // Build available targets from summaries (canonicalized for deduplication)
            let targets = Set(nightlySummaries.compactMap { $0.target.map { TargetCatalog.canonicalName($0) } }).sorted()
            availableTargets = targets
        } catch {
            print("FrameHistoryModel: loadNightlyTrend failed: \(error)")
        }
    }

    // MARK: - Time-Filtered Summaries

    /// Summaries filtered by the selected time range. All chart computations use this.
    var filteredSummaries: [NightSummary] {
        guard let cutoff = selectedTimeRange.cutoffDate else { return nightlySummaries }
        return nightlySummaries.filter { s in
            guard let date = Self.nightDateFormatter.date(from: s.night) else { return false }
            return date >= cutoff
        }
    }

    // MARK: - Aggregated Chart Data

    /// Per-night quality tier breakdown (for stacked bar chart).
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

    var nightlyQuality: [NightQuality] {
        var byNight: [String: (exc: Int, good: Int, bord: Int, trash: Int)] = [:]
        for s in filteredSummaries {
            var val = byNight[s.night] ?? (0, 0, 0, 0)
            val.exc += s.excellentCount
            val.good += s.goodCount
            val.bord += s.borderlineCount
            val.trash += s.trashCount
            byNight[s.night] = val
        }
        return byNight.compactMap { (night, val) in
            guard let date = Self.nightDateFormatter.date(from: night) else { return nil }
            return NightQuality(night: night, date: date, excellent: val.exc, good: val.good,
                        borderline: val.bord, trash: val.trash)
        }.sorted { $0.date < $1.date }
    }

    /// Per-night metric values by filter (for multi-line chart).
    struct MetricPoint: Identifiable {
        var id: String { "\(night)_\(filter)" }  // Stable ID
        let night: String
        let date: Date        // Parsed date for proper X-axis sorting
        let filter: String    // Normalized filter name
        let value: Double
    }

    // Date parser for "YYYY-MM-DD" night strings
    private static let nightDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    /// Normalize filter name for chart display — group variants under canonical names.
    /// L/LE/Lext/Lextr/Lcle/Lenh/Lqua → "L", H/Ha → "Ha", etc.
    static func normalizeFilterForChart(_ raw: String) -> String {
        let upper = raw.uppercased().trimmingCharacters(in: .whitespaces)
        // Luminance variants — L-Enhance, L-Extreme, L-Pro, etc. all → "L"
        let luminanceVariants = ["L", "LE", "LEXT", "LEXTR", "LCLE", "LENH", "LQUA", "LBOO",
                                  "LENHANCE", "LEXTREME", "LPRO", "LUMA", "LUM", "EXTR"]
        if luminanceVariants.contains(upper) { return "L" }
        // Ha variants
        if ["H", "HA", "HALPHA", "H-ALPHA"].contains(upper) { return "Ha" }
        // OIII variants
        if ["O", "OIII", "O3"].contains(upper) { return "OIII" }
        // SII variants
        if ["S", "SII", "S2"].contains(upper) { return "SII" }
        // Standard broadband
        if ["R", "G", "B"].contains(upper) { return upper }
        // Infrared
        if ["IR", "IRPASS", "IR-PASS", "IRCUT"].contains(upper) { return "IR" }
        // Quad-band (dual narrowband) — keep distinct
        if upper.contains("QUAD") || upper.contains("DUOBAND") { return "Quad" }
        // Unknown / special — group minor variants
        if upper == "NOFILTER" || upper == "NONE" || upper == "NO FILTER" { return "NoFilter" }
        if upper == "FILTER1" || upper == "?" || upper.isEmpty { return "?" }
        // Pass through others (Hbeta, NII, Spec, etc.)
        return raw
    }

    /// Canonical filter sort order: L R G B Ha OIII SII HBeta NII, then others alphabetically.
    /// Standard astrophotography convention: broadband first (LRGB), then narrowband (HOS).
    static func filterSortOrder(_ filter: String) -> Int {
        let order: [String: Int] = [
            "L": 0, "R": 1, "G": 2, "B": 3,
            "Ha": 4, "OIII": 5, "SII": 6,
            "HBeta": 7, "HB": 7, "NII": 8,
            "IR": 9, "Quad": 10, "NoFilter": 11, "?": 12
        ]
        return order[filter] ?? order[normalizeFilterForChart(filter)] ?? 50
    }

    /// Sort filter names by astrophotography convention: L R G B Ha OIII SII ...
    static func sortedFilters(_ filters: [String]) -> [String] {
        filters.sorted { filterSortOrder($0) < filterSortOrder($1) }
    }

    func metricPoints(for metric: MetricType) -> [MetricPoint] {
        filteredSummaries.compactMap { s in
            let value: Double?
            switch metric {
            case .fwhm:     value = s.medianFWHM
            case .hfr:      value = s.medianHFR
            case .starCount: value = s.medianStarCount
            case .noise:    value = s.medianNoise
            case .trailing: value = s.medianTrailing
            case .eccentricity: value = nil
            }
            guard let v = value else { return nil }
            guard let date = Self.nightDateFormatter.date(from: s.night) else { return nil }
            let filter = Self.normalizeFilterForChart(s.filter ?? "?")
            return MetricPoint(night: s.night, date: date, filter: filter, value: v)
        }.sorted { $0.date < $1.date }
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

    @Published var selectedConditionsFactor: ConditionsFactor = .moon

    var conditionsPoints: [ConditionsPoint] {
        filteredSummaries.compactMap { s in
            guard let noise = s.medianNoise,
                  let filter = s.filter else { return nil }
            let canonical = FrameHistoryModel.normalizeFilterForChart(filter).uppercased()
            let isBroadband = ["L", "R", "G", "B"].contains(canonical)
            let moon = s.medianMoonIllumination.map { $0 * 100 }
            return ConditionsPoint(
                id: "\(s.night)_\(filter)", night: s.night,
                target: s.target, filter: filter, isBroadband: isBroadband,
                background: noise, moonPct: moon, fwhm: s.medianFWHM,
                ambientTemp: s.medianAmbientTemp, bortle: s.medianBortle,
                frameCount: s.frameCount
            )
        }
    }

    // Keep backward compat for any code referencing moonPoints
    var moonPoints: [ConditionsPoint] { conditionsPoints }

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

    // MARK: - KPI 1: Session Score (0-100)

    struct SessionScorePoint: Identifiable {
        var id: String { night }  // Stable ID
        let date: Date
        let night: String
        let score: Double       // 0-100 composite score
        let retentionRate: Double  // % kept
        let fwhmNormalized: Double // relative to setup median (1.0 = average, <1 = better)
        let frameCount: Int
        // Context for tooltip
        let targets: [String]
        let filters: [String]
        let avgFWHM: Double?
        let moonPct: Double?
    }

    /// Compute per-night Session Score. Combines retention rate (40%), FWHM quality (30%),
    /// trailing absence (20%), and background stability (10%).
    var sessionScores: [SessionScorePoint] {
        // Get setup baseline FWHM for normalization
        let allFWHMs = filteredSummaries.compactMap(\.medianFWHM)
        let baselineFWHM = allFWHMs.isEmpty ? 5.0 : allFWHMs.sorted()[allFWHMs.count / 2]

        // Aggregate by night (across filters)
        var byNight: [String: (frames: Int, kept: Int, fwhm: Double?, trailing: Double?, noise: Double?)] = [:]
        for s in filteredSummaries {
            var v = byNight[s.night] ?? (0, 0, nil, nil, nil)
            v.frames += s.frameCount
            v.kept += s.goodCount + s.excellentCount + s.borderlineCount
            // Use the worst (highest) FWHM across filters for this night
            if let f = s.medianFWHM { v.fwhm = max(v.fwhm ?? 0, f) }
            if let t = s.medianTrailing { v.trailing = max(v.trailing ?? 0, t) }
            if let n = s.medianNoise { v.noise = v.noise.map { ($0 + n) / 2 } ?? n }
            byNight[s.night] = v
        }

        return byNight.compactMap { night, v in
            guard let date = Self.nightDateFormatter.date(from: night), v.frames > 0 else { return nil }
            let retention = Double(v.kept) / Double(v.frames)

            // FWHM score: 1.0 when at baseline, 0.0 when 3x worse
            let fwhmRatio = (v.fwhm ?? baselineFWHM) / baselineFWHM
            let fwhmScore = max(0, min(1, 1.0 - (fwhmRatio - 1.0) / 2.0))

            // Trailing score: 1.0 = no trailing, 0.0 = severe
            let trailingScore = max(0, 1.0 - (v.trailing ?? 0) * 2.0)

            // Background stability: 1.0 = stable, lower = noisy (inverse of noise variance)
            let noiseScore = 1.0  // Simplified — would need variance across frames

            // Composite: retention 40%, FWHM 30%, trailing 20%, background 10%
            let composite = retention * 40 + fwhmScore * 30 + trailingScore * 20 + noiseScore * 10

            // Context from summaries for this night
            let nightSummaries = filteredSummaries.filter { $0.night == night }
            let targets = Array(Set(nightSummaries.compactMap { $0.target.map { TargetCatalog.canonicalName($0) } })).sorted()
            let filters = Array(Set(nightSummaries.compactMap { $0.filter.map { FrameHistoryModel.normalizeFilterForChart($0) } })).sorted()
            let moons = nightSummaries.compactMap(\.medianMoonIllumination)
            let moonPct = moons.isEmpty ? nil : (moons.reduce(0, +) / Double(moons.count)) * 100

            return SessionScorePoint(
                date: date, night: night, score: min(100, composite),
                retentionRate: retention, fwhmNormalized: fwhmRatio, frameCount: v.frames,
                targets: targets, filters: filters, avgFWHM: v.fwhm, moonPct: moonPct
            )
        }.sorted { $0.date < $1.date }
    }

    // MARK: - KPI 2: Imaging Efficiency

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

    var efficiencyData: [EfficiencyPoint] {
        let quality = nightlyQuality
        return quality.compactMap { nq in
            // Gather context from filtered summaries for this night
            let nightSummaries = filteredSummaries.filter { $0.night == nq.night }
            let targets = Array(Set(nightSummaries.compactMap { $0.target.map { TargetCatalog.canonicalName($0) } })).sorted()
            let filters = Array(Set(nightSummaries.compactMap { $0.filter.map { FrameHistoryModel.normalizeFilterForChart($0) } })).sorted()
            let fwhms = nightSummaries.compactMap(\.medianFWHM)
            let avgFWHM = fwhms.isEmpty ? nil : fwhms.reduce(0, +) / Double(fwhms.count)
            let moons = nightSummaries.compactMap(\.medianMoonIllumination)
            let moonPct = moons.isEmpty ? nil : (moons.reduce(0, +) / Double(moons.count)) * 100

            return EfficiencyPoint(
                date: nq.date, night: nq.night,
                total: nq.total, excellent: nq.excellent,
                good: nq.good, borderline: nq.borderline, trash: nq.trash,
                targets: targets, filters: filters, avgFWHM: avgFWHM, moonPct: moonPct
            )
        }
    }

    // MARK: - KPI 3: Seeing Index

    struct SeeingPoint: Identifiable {
        var id: String { "\(night)_\(filter)" }  // Stable ID
        let date: Date
        let night: String
        let seeingIndex: Double   // theoretical/actual — 1.0 = diffraction limited
        let actualFWHM: Double    // arcseconds
        let filter: String
    }

    /// Seeing Index = theoretical FWHM / actual FWHM.
    /// theoretical_arcsec = 1.22 × wavelength_nm / aperture_mm × 206265 / 1e6
    /// Requires focal length + pixel size for arcsec conversion.
    func seeingPoints(focalLength: Double?, pixelSize: Double?) -> [SeeingPoint] {
        guard let fl = focalLength, fl > 0, let px = pixelSize, px > 0 else { return [] }
        let arcsecPerPixel = 206.265 * px / fl

        return nightlySummaries.compactMap { s in
            guard let fwhm = s.medianFWHM, fwhm > 0 else { return nil }
            guard let date = Self.nightDateFormatter.date(from: s.night) else { return nil }
            let fwhmArcsec = fwhm * arcsecPerPixel
            // Theoretical FWHM (Dawes limit at 550nm for the aperture)
            // aperture_mm ≈ focalLength / f-ratio, but we don't always know f-ratio
            // Use a fixed 2.0 arcsec as "good seeing" reference instead
            let referenceFWHM = 2.0  // arcsec — good seeing conditions
            let index = referenceFWHM / fwhmArcsec
            let filter = Self.normalizeFilterForChart(s.filter ?? "?")
            return SeeingPoint(date: date, night: s.night, seeingIndex: min(2, index),
                              actualFWHM: fwhmArcsec, filter: filter)
        }.sorted { $0.date < $1.date }
    }

    // MARK: - KPI 4: Integration Progress

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

    var targetProgressData: [TargetProgress] {
        // Group summaries by canonical target, then by filter
        struct TargetAccum {
            var totalSeconds: Double = 0
            var usableSeconds: Double = 0
            var nights: Set<String> = []
            var bestFWHM: Double? = nil
            var totalFrames: Int = 0
            var keptFrames: Int = 0
            var filterData: [String: (seconds: Double, frames: Int)] = [:]
        }

        var byTarget: [String: TargetAccum] = [:]
        for s in filteredSummaries {
            guard let rawTarget = s.target, !rawTarget.isEmpty else { continue }
            let target = TargetCatalog.canonicalName(rawTarget)
            var v = byTarget[target] ?? TargetAccum()
            let exposure = s.medianExposure ?? 120  // Default 120s if unknown
            let totalFrames = s.frameCount
            let keptFrames = s.excellentCount + s.goodCount + s.borderlineCount
            let totalSec = Double(totalFrames) * exposure
            let usableSec = Double(keptFrames) * exposure
            v.totalSeconds += totalSec
            v.usableSeconds += usableSec
            v.nights.insert(s.night)
            if let f = s.medianFWHM { v.bestFWHM = min(v.bestFWHM ?? f, f) }
            v.totalFrames += totalFrames
            v.keptFrames += keptFrames

            // Per-filter accumulation
            let filter = FrameHistoryModel.normalizeFilterForChart(s.filter ?? "?")
            var fd = v.filterData[filter] ?? (0, 0)
            fd.seconds += usableSec
            fd.frames += keptFrames
            v.filterData[filter] = fd

            byTarget[target] = v
        }

        return byTarget.map { target, v in
            let retention = v.totalFrames > 0 ? Double(v.keptFrames) / Double(v.totalFrames) : 0
            let filters = v.filterData.map { filter, data in
                FilterIntegration(id: "\(target)_\(filter)", filter: filter, hours: data.seconds / 3600.0, frameCount: data.frames)
            }.sorted { $0.hours > $1.hours }
            return TargetProgress(
                target: target,
                totalIntegrationHours: v.totalSeconds / 3600.0,
                usableIntegrationHours: v.usableSeconds / 3600.0,
                nightCount: v.nights.count,
                bestFWHM: v.bestFWHM,
                avgRetention: retention,
                filterBreakdown: filters
            )
        }.sorted {
            // Stable sort: by hours descending, then alphabetically as tiebreaker
            if $0.usableIntegrationHours != $1.usableIntegrationHours {
                return progressSortAscending
                    ? $0.usableIntegrationHours < $1.usableIntegrationHours
                    : $0.usableIntegrationHours > $1.usableIntegrationHours
            }
            return $0.target < $1.target
        }
    }

    // Progress chart sort direction
    @Published var progressSortAscending: Bool = false

    // MARK: - KPI 5: Equipment Health (rolling FWHM trend)

    struct HealthTrendPoint: Identifiable {
        var id: String { night }  // Stable ID
        let date: Date
        let night: String
        let rollingFWHM: Double     // Configurable rolling average
        let rawFWHM: Double
    }

    var equipmentHealthData: [HealthTrendPoint] {
        // Per-night average FWHM (across all filters)
        let nightly: [(date: Date, fwhm: Double)] = filteredSummaries.compactMap { s in
            guard let fwhm = s.medianFWHM, let date = Self.nightDateFormatter.date(from: s.night) else { return nil }
            return (date, fwhm)
        }.sorted { $0.date < $1.date }

        // Deduplicate by night (take average if multiple filter entries per night)
        var byDate: [Date: [Double]] = [:]
        for n in nightly { byDate[n.date, default: []].append(n.fwhm) }
        let sorted = byDate.map { (date: $0.key, fwhm: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.date < $1.date }

        // Configurable rolling average
        return sorted.enumerated().compactMap { idx, item in
            let start = max(0, idx - rollingWindowSize + 1)
            let window = sorted[start...idx]
            let rolling = window.map(\.fwhm).reduce(0, +) / Double(window.count)
            let night = Self.nightDateFormatter.string(from: item.date)
            return HealthTrendPoint(date: item.date, night: night, rollingFWHM: rolling, rawFWHM: item.fwhm)
        }
    }

    // MARK: - Summary Statistics (for cards above charts)

    struct SummaryStats {
        let totalFrames: Int
        let totalNights: Int
        let bestFWHM: Double?        // Best (lowest) median FWHM across all nights
        let avgTrashRate: Double     // Percentage of frames that are trash
        let totalTargets: Int
    }

    var summaryStats: SummaryStats {
        let data = filteredSummaries
        let nights = Set(data.map(\.night))
        let totalFrames = data.reduce(0) { $0 + $1.frameCount }
        let totalTrash = data.reduce(0) { $0 + $1.trashCount }
        let trashRate = totalFrames > 0 ? Double(totalTrash) / Double(totalFrames) : 0
        let bestFWHM = data.compactMap(\.medianFWHM).min()
        let targets = Set(data.compactMap { $0.target.map { TargetCatalog.canonicalName($0) } })
        return SummaryStats(
            totalFrames: totalFrames,
            totalNights: nights.count,
            bestFWHM: bestFWHM,
            avgTrashRate: trashRate,
            totalTargets: targets.count
        )
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
            return SetupMetric(
                setupLabel: setup.label, value: value,
                totalFrames: summary.totalFrames,
                firstNight: summary.firstNight,
                lastNight: summary.lastNight,
                trashRate: summary.trashRate,
                targets: summary.targets
            )
        }
    }
}
