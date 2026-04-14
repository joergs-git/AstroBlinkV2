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

    /// Maps a primary setup hash to all merged hashes (same scope, FL within tolerance).
    /// When a setup is selected, ALL merged hashes are queried together.
    private(set) var mergedSetupHashes: [String: [String]] = [:]
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
        case metrics = "Metrics"
        var id: String { rawValue }
    }

    @Published var selectedChart: ChartType = .sessionScore

    // MARK: - Metrics Chart State

    /// Selected night for per-frame detail view (nil = all nights longterm using nightly medians)
    @Published var selectedMetricsNight: String?
    @Published var metricsFilterScope: MetricsFilterScope = .all
    @Published var showMetricsTemperature: Bool = true
    @Published var showMeridianFlipMarkers: Bool = false  // Off by default — too noisy on longterm view
    @Published private(set) var metricsNights: [String] = []
    @Published private(set) var metricsFrameData: [MetricsFramePoint] = []
    @Published private(set) var metricsEvents: [MetricsEvent] = []

    /// True when showing nightly medians (All Nights), false when showing per-frame (single night)
    var isMetricsLongtermView: Bool { selectedMetricsNight == nil }

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

    /// Available filters in current metrics data
    var metricsAvailableFilters: [String] {
        let unique = Set(metricsFrameData.map { $0.filter }).subtracting(["Unknown", ""])
        return FrameHistoryModel.sortedFilters(Array(unique))
    }

    /// Filtered metrics points based on current filter scope
    var filteredMetricsPoints: [MetricsFramePoint] {
        switch metricsFilterScope {
        case .all:
            return metricsFrameData
        case .narrowband:
            return metricsFrameData.filter { QualityEstimator.narrowbandCanonical.contains($0.filter) }
        case .broadband:
            let broad = Set(["L", "R", "G", "B"])
            return metricsFrameData.filter { broad.contains($0.filter) }
        case .specific(let name):
            return metricsFrameData.filter { $0.filter == name }
        }
    }

    var metricsHFRPoints: [MetricsFramePoint] { filteredMetricsPoints.filter { $0.hfr != nil } }
    var metricsTempPoints: [MetricsFramePoint] { filteredMetricsPoints.filter { $0.ambientTemp != nil } }
    var hasMetricsHFR: Bool { !metricsHFRPoints.isEmpty }
    var hasMetricsTemp: Bool { !metricsTempPoints.isEmpty }

    /// Points that have BOTH HFR and temperature (for scatter plot)
    var metricsTempHFRPoints: [MetricsFramePoint] {
        filteredMetricsPoints.filter { $0.hfr != nil && $0.ambientTemp != nil }
    }

    /// Rolling average trend line: bin by 1°C temperature buckets, average HFR within each bin
    struct TrendPoint: Identifiable {
        let id = UUID()
        let temp: Double
        let hfr: Double
    }

    var metricsTrendLine: [TrendPoint] {
        let points = metricsTempHFRPoints
        guard points.count >= 3 else { return [] }

        // Bin by 1°C buckets
        var bins: [Int: [Double]] = [:]  // temp_rounded → [hfr values]
        for p in points {
            let bucket = Int(round(p.ambientTemp!))
            bins[bucket, default: []].append(p.hfr!)
        }

        // Only emit bins with data, sorted by temperature
        return bins.keys.sorted().compactMap { bucket in
            guard let values = bins[bucket], !values.isEmpty else { return nil }
            let avgHFR = values.reduce(0, +) / Double(values.count)
            return TrendPoint(temp: Double(bucket), hfr: avgHFR)
        }
    }

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

    // Re-analysis state
    @Published var isReAnalyzing: Bool = false
    @Published var reAnalysisProgress: Int = 0
    @Published var reAnalysisTotal: Int = 0

    // MARK: - Re-Analysis

    /// Re-score all stale records using current QualityEstimator algorithm.
    /// No image re-decode needed — uses stored metrics from FrameRecord.
    func reAnalyzeStaleRecords() {
        guard !isReAnalyzing else { return }
        isReAnalyzing = true
        reAnalysisProgress = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            guard let records = try? FrameHistoryDatabase.shared.fetchStaleRecords(),
                  !records.isEmpty else {
                DispatchQueue.main.async {
                    self.isReAnalyzing = false
                    self.staleRecordCount = 0
                }
                return
            }

            let total = records.count
            DispatchQueue.main.async {
                self.reAnalysisTotal = total
            }

            // Convert ALL stale FrameRecords to ImageEntries in one pass.
            // QualityEstimator groups internally by filter+target+exposure+night.
            let entries: [ImageEntry] = records.map { record in
                var entry = ImageEntry(url: URL(fileURLWithPath: record.filePath))
                entry.fileHash = record.fileHash
                entry.filter = record.filter
                entry.exposure = record.exposure
                entry.target = record.target
                entry.computedFWHM = record.computedFWHM
                entry.computedHFR = record.computedHFR
                entry.computedStarCount = record.computedStarCount
                entry.computedEccentricity = record.computedEccentricity
                entry.noiseMedian = record.noiseMedian.map { Float($0) }
                entry.noiseMAD = record.noiseMAD.map { Float($0) }
                entry.psfFluxSum = record.psfFlux
                entry.trailingScore = record.trailingScore
                entry.trailingPA = record.trailingPA
                entry.trailingAxisRatio = record.trailingAxisRatio
                entry.trailingConsensus = record.trailingConsensus
                entry.starChainFraction = record.starChainFraction
                entry.focalLength = record.focalLength
                entry.pixelSizeMicrons = record.pixelSizeMicrons
                entry.date = record.captureDate
                entry.time = record.captureTime
                entry.telescope = record.telescope
                entry.camera = record.camera
                return entry
            }

            DispatchQueue.main.async {
                self.reAnalysisProgress = total / 3  // ~33% — conversion done
            }

            // Run quality scoring — QualityEstimator groups internally
            let scores = QualityEstimator.computeScores(for: entries)

            DispatchQueue.main.async {
                self.reAnalysisProgress = total * 2 / 3  // ~66% — scoring done
            }

            // Build update list — re-scored frames get new tier + version bump
            var allUpdates: [(hash: String, tier: Int, zScore: Double)] = []
            var scoredHashes: Set<String> = []
            for (i, entry) in entries.enumerated() {
                if let bd = scores[entry.url] {
                    allUpdates.append((
                        hash: records[i].fileHash,
                        tier: bd.tier.rawValue,
                        zScore: bd.combinedZScore
                    ))
                    scoredHashes.insert(records[i].fileHash)
                }
            }

            // Frames that couldn't be re-scored (group too small) — bump version
            // with their existing tier so they're no longer flagged as stale
            var versionOnlyHashes: [String] = []
            for record in records {
                if !scoredHashes.contains(record.fileHash) {
                    versionOnlyHashes.append(record.fileHash)
                }
            }

            // Batch write re-scored results
            if !allUpdates.isEmpty {
                try? FrameHistoryDatabase.shared.updateQualityTiersAndVersion(allUpdates)
            }
            // Bump version for un-scorable frames (keeps existing tier)
            if !versionOnlyHashes.isEmpty {
                try? FrameHistoryDatabase.shared.bumpAlgorithmVersion(fileHashes: versionOnlyHashes)
            }

            // Refresh UI
            DispatchQueue.main.async {
                self.isReAnalyzing = false
                self.staleRecordCount = 0
                self.reAnalysisProgress = 0
                self.reAnalysisTotal = 0
                self.loadData()
            }
        }
    }

    // MARK: - Load Data

    func loadData() {
        // Clean orphaned session records (leftover from merge/delete operations)
        try? FrameHistoryDatabase.shared.cleanOrphanedSessions()

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
            var rawSetups: [(hash: String, equipment: String, nickname: String?, fl: Int?)] = []
            for session in sessions {
                guard let hash = session.setupHash, !seen.contains(hash) else { continue }
                seen.insert(hash)
                let equipment = [session.telescope, session.camera].compactMap { $0 }.joined(separator: " + ")
                let fl = FrameHistoryDatabase.shared.primaryFocalLength(for: hash)
                rawSetups.append((hash: hash, equipment: equipment, nickname: nicknames[hash], fl: fl))
            }

            // Merge setups with same telescope+camera and FL within 3% tolerance.
            // Minor plate-solve variations (903/904/905mm) are the same physical scope.
            var merged: [String: [String]] = [:]  // primaryHash → [all hashes in cluster]
            var primaryForHash: [String: String] = [:]  // hash → its primary hash

            // Group by normalized equipment string (ignore nicknames for grouping)
            var equipmentGroups: [String: [(hash: String, equipment: String, nickname: String?, fl: Int?)]] = [:]
            for s in rawSetups {
                let key = s.equipment.lowercased().trimmingCharacters(in: .whitespaces)
                equipmentGroups[key, default: []].append(s)
            }

            for (_, group) in equipmentGroups {
                // Cluster FLs within 3% tolerance using single-linkage clustering
                var clusters: [[(hash: String, equipment: String, nickname: String?, fl: Int?)]] = []
                for setup in group {
                    // Setups with nicknames stay standalone (user intentionally differentiated them)
                    if setup.nickname != nil && !setup.nickname!.isEmpty {
                        clusters.append([setup])
                        continue
                    }
                    var placed = false
                    for i in clusters.indices {
                        // Skip nickname clusters
                        if clusters[i].count == 1, let n = clusters[i][0].nickname, !n.isEmpty { continue }
                        // Check FL tolerance against any member of the cluster
                        if let existingFL = clusters[i].first(where: { $0.fl != nil })?.fl,
                           let newFL = setup.fl, existingFL > 0, newFL > 0 {
                            // Explicit types + .magnitude (instead of abs, which has many
                            // overloads) disambiguate the expression for Swift 6 inference.
                            let tolerance: Double = Double(max(existingFL, newFL)) * 0.03
                            let diff: Double = Double(existingFL - newFL)
                            if diff.magnitude <= tolerance {
                                clusters[i].append(setup)
                                placed = true
                                break
                            }
                        } else if setup.fl == nil || setup.fl == 0 {
                            // No FL data — check if this is the only entry without FL in this equipment group
                            // Don't auto-merge unknown FL with known FL setups
                            continue
                        }
                    }
                    if !placed {
                        clusters.append([setup])
                    }
                }

                // For each cluster, pick the hash with most frames as primary
                for cluster in clusters {
                    if cluster.count == 1 {
                        merged[cluster[0].hash] = [cluster[0].hash]
                        primaryForHash[cluster[0].hash] = cluster[0].hash
                    } else {
                        // Primary = hash with most frames (via primaryFocalLength query pattern)
                        let sorted = cluster.sorted { a, b in
                            let countA = (try? FrameHistoryDatabase.shared.frameCount(setupHash: a.hash)) ?? 0
                            let countB = (try? FrameHistoryDatabase.shared.frameCount(setupHash: b.hash)) ?? 0
                            return countA > countB
                        }
                        let primary = sorted[0].hash
                        let allHashes = sorted.map(\.hash)
                        merged[primary] = allHashes
                        for s in sorted {
                            primaryForHash[s.hash] = primary
                        }
                    }
                }
            }

            mergedSetupHashes = merged

            // Build final labels: always show FL when available
            var setups: [(hash: String, label: String)] = []
            for (primary, hashes) in merged {
                guard let firstSetup = rawSetups.first(where: { $0.hash == primary }) else { continue }
                let label: String
                if let nickname = firstSetup.nickname, !nickname.isEmpty {
                    label = nickname
                } else if firstSetup.equipment.isEmpty {
                    label = String(primary.prefix(8))
                } else {
                    // Use the mode FL across all merged hashes
                    let modeFL = FrameHistoryDatabase.shared.primaryFocalLength(for: hashes)
                    if let fl = modeFL, fl > 0 {
                        label = "\(firstSetup.equipment) (\(fl)mm)"
                    } else {
                        label = firstSetup.equipment
                    }
                }
                setups.append((hash: primary, label: label))
            }

            // Sort: alphabetically by label for consistent ordering
            // Filter out setups with 0 frames (orphaned after merge/delete)
            let nonEmpty = setups.filter { setup in
                let hashes = merged[setup.hash] ?? [setup.hash]
                let total = hashes.compactMap { try? FrameHistoryDatabase.shared.frameCount(setupHash: $0) }.reduce(0, +)
                return total > 0
            }
            availableSetups = nonEmpty.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        } catch {
            print("FrameHistoryModel: loadAvailableSetups failed: \(error)")
        }
    }

    func loadNightlyTrend() {
        do {
            if let setupHash = selectedSetupHash {
                // Query all merged hashes for this setup (e.g., 903mm + 904mm + 905mm)
                let hashes = mergedSetupHashes[setupHash] ?? [setupHash]
                if hashes.count == 1 {
                    nightlySummaries = try FrameHistoryDatabase.shared.nightlyTrend(
                        setupHash: hashes[0],
                        target: selectedTarget
                    )
                } else {
                    nightlySummaries = try FrameHistoryDatabase.shared.nightlyTrend(
                        setupHashes: hashes,
                        target: selectedTarget
                    )
                }
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

    // MARK: - Metrics Data Loading

    func loadMetricsData() {
        do {
            // Determine setup hashes
            let hashes: [String]?
            if let setupHash = selectedSetupHash {
                hashes = mergedSetupHashes[setupHash] ?? [setupHash]
            } else {
                hashes = nil
            }

            // Load available nights
            metricsNights = try FrameHistoryDatabase.shared.availableNights(
                setupHashes: hashes, target: selectedTarget
            )

            if let night = selectedMetricsNight {
                // Single night selected → per-frame detail view
                loadMetricsPerFrame(night: night, setupHashes: hashes)
            } else {
                // All Nights → nightly medians from NightSummary (much less data)
                loadMetricsNightlyMedians()
            }
        } catch {
            print("FrameHistoryModel: loadMetricsData failed: \(error)")
            metricsFrameData = []
            metricsEvents = []
        }
    }

    /// Longterm view: one point per night per filter from NightSummary medians.
    /// Each NightSummary already has per-filter data, so we keep separate lines per filter.
    /// Temperature is attached to each point (same value per night across filters).
    private func loadMetricsNightlyMedians() {
        let summaries = filteredSummaries
        var points: [MetricsFramePoint] = []

        // First, collect nightly temperature (average across filter entries for the same night)
        var nightTemp: [String: Double] = [:]
        for s in summaries {
            if let temp = s.medianAmbientTemp {
                if let existing = nightTemp[s.night] {
                    nightTemp[s.night] = (existing + temp) / 2
                } else {
                    nightTemp[s.night] = temp
                }
            }
        }

        // Create one point per NightSummary entry (per night per filter)
        for s in summaries {
            guard let date = Self.nightDateFormatter.date(from: s.night) else { continue }
            guard s.medianHFR != nil || nightTemp[s.night] != nil else { continue }

            let filter = s.filter.map { Self.normalizeFilterForChart($0) } ?? "Unknown"

            points.append(MetricsFramePoint(
                id: "\(s.night)-\(filter)",
                date: date,
                hfr: s.medianHFR,
                ambientTemp: nightTemp[s.night],
                filter: filter,
                filename: "\(s.night) \(filter)",
                qualityTier: nil,
                pierSide: nil
            ))
        }

        points.sort { $0.date < $1.date }
        metricsFrameData = points
        metricsEvents = []
    }

    /// Single night view: per-frame detail from FrameRecord
    private func loadMetricsPerFrame(night: String, setupHashes: [String]?) {
        let dtFormatter = DateFormatter()
        dtFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dtFormatter.locale = Locale(identifier: "en_US_POSIX")

        do {
            let frames = try FrameHistoryDatabase.shared.metricsFrames(
                night: night,
                setupHashes: setupHashes,
                target: selectedTarget
            )

            var points: [MetricsFramePoint] = []
            for f in frames {
                let dateStr: String
                if let d = f.captureDate, let t = f.captureTime {
                    dateStr = "\(d) \(t)"
                } else if let d = f.captureDate {
                    dateStr = "\(d) 00:00:00"
                } else {
                    continue
                }
                guard let date = dtFormatter.date(from: dateStr) else { continue }

                let canonical = f.filter.map { ColorCombineEngine.canonicalFilterName($0) } ?? "Unknown"

                points.append(MetricsFramePoint(
                    id: f.fileHash,
                    date: date,
                    hfr: f.computedHFR,
                    ambientTemp: f.ambientTemp,
                    filter: canonical,
                    filename: f.filename ?? "unknown",
                    qualityTier: f.qualityTier,
                    pierSide: f.pierSide
                ))
            }
            points.sort { $0.date < $1.date }
            metricsFrameData = points

            // Detect meridian flip events (pierSide changes between consecutive frames)
            var events: [MetricsEvent] = []
            if points.count >= 2 {
                for i in 1..<points.count {
                    if let prevSide = points[i-1].pierSide, let currSide = points[i].pierSide,
                       !prevSide.isEmpty, !currSide.isEmpty, prevSide != currSide {
                        events.append(MetricsEvent(date: points[i].date, type: .meridianFlip))
                    }
                }
            }
            metricsEvents = events
        } catch {
            print("FrameHistoryModel: loadMetricsPerFrame failed: \(error)")
            metricsFrameData = []
            metricsEvents = []
        }
    }

    // MARK: - Metrics Axis Ranges

    /// HFR Y-axis: P2-P98 with padding
    var metricsHFRRange: ClosedRange<Double> {
        let values = metricsHFRPoints.compactMap { $0.hfr }
        guard values.count >= 2 else {
            let v = values.first ?? 1.5
            return (v - 0.5)...(v + 0.5)
        }
        let sorted = values.sorted()
        let p2 = sorted[max(0, Int(Double(sorted.count) * 0.02))]
        let p98 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
        let padding = max((p98 - p2) * 0.1, 0.1)
        return (p2 - padding)...(p98 + padding)
    }

    /// Temperature Y-axis: P2-P98 with padding
    var metricsTempRange: ClosedRange<Double> {
        let values = metricsTempPoints.compactMap { $0.ambientTemp }
        guard values.count >= 2 else {
            let v = values.first ?? 15.0
            return (v - 5)...(v + 5)
        }
        let sorted = values.sorted()
        let p2 = sorted[max(0, Int(Double(sorted.count) * 0.02))]
        let p98 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
        let padding = max((p98 - p2) * 0.15, 1.0)
        return (p2 - padding)...(p98 + padding)
    }

    /// X-axis time range
    var metricsTimeRange: ClosedRange<Date> {
        guard let first = metricsFrameData.first?.date, let last = metricsFrameData.last?.date else {
            let now = Date()
            return now...now.addingTimeInterval(3600)
        }
        let padding = max(last.timeIntervalSince(first) * 0.02, 60)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
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

    // MARK: - Monthly Aggregation

    /// True when the filtered date range spans >6 months — charts switch to monthly buckets.
    var useMonthlyAggregation: Bool {
        let summaries = filteredSummaries
        guard summaries.count > 1 else { return false }
        let dates = summaries.compactMap { Self.nightDateFormatter.date(from: $0.night) }
        guard let first = dates.min(), let last = dates.max() else { return false }
        let months = Calendar.current.dateComponents([.month], from: first, to: last).month ?? 0
        return months > 6
    }

    /// Format a date as "YYYY-MM" for monthly grouping key.
    private static func monthKey(from date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return String(format: "%04d-%02d", y, m)
    }

    /// Parse "YYYY-MM" month key to a Date (1st of month) for chart x-axis.
    private static func dateFromMonthKey(_ key: String) -> Date? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: key)
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

    var nightlyQuality: [NightQuality] {
        let monthly = useMonthlyAggregation

        if monthly {
            // Aggregate by month
            var byMonth: [String: (exc: Int, good: Int, bord: Int, trash: Int)] = [:]
            for s in filteredSummaries {
                guard let date = Self.nightDateFormatter.date(from: s.night) else { continue }
                let key = Self.monthKey(from: date)
                var val = byMonth[key] ?? (0, 0, 0, 0)
                val.exc += s.excellentCount
                val.good += s.goodCount
                val.bord += s.borderlineCount
                val.trash += s.trashCount
                byMonth[key] = val
            }
            return byMonth.compactMap { (month, val) in
                guard let date = Self.dateFromMonthKey(month) else { return nil }
                return NightQuality(night: month, date: date, excellent: val.exc, good: val.good,
                            borderline: val.bord, trash: val.trash)
            }.sorted { $0.date < $1.date }
        } else {
            // Per-night (original)
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

    /// Compute per-night composite score for a set of summaries sharing the same night key.
    private func nightCompositeScore(summaries: [NightSummary], baselineFWHM: Double) -> (score: Double, frames: Int, retention: Double, fwhmRatio: Double, fwhm: Double?, moonPct: Double?, targets: [String], filters: [String]) {
        var frames = 0, kept = 0
        var fwhm: Double? = nil, trailing: Double? = nil
        for s in summaries {
            frames += s.frameCount
            kept += s.goodCount + s.excellentCount + s.borderlineCount
            if let f = s.medianFWHM { fwhm = max(fwhm ?? 0, f) }
            if let t = s.medianTrailing { trailing = max(trailing ?? 0, t) }
        }
        let retention = frames > 0 ? Double(kept) / Double(frames) : 0
        let fwhmRatio = (fwhm ?? baselineFWHM) / baselineFWHM
        let fwhmScore = max(0, min(1, 1.0 - (fwhmRatio - 1.0) / 2.0))
        let trailingScore = max(0, 1.0 - (trailing ?? 0) * 2.0)
        let composite = retention * 40 + fwhmScore * 30 + trailingScore * 20 + 10 // noiseScore = 1.0
        let targets = Array(Set(summaries.compactMap { $0.target.map { TargetCatalog.canonicalName($0) } })).sorted()
        let filters = Array(Set(summaries.compactMap { $0.filter.map { FrameHistoryModel.normalizeFilterForChart($0) } })).sorted()
        let moons = summaries.compactMap(\.medianMoonIllumination)
        let moonPct = moons.isEmpty ? nil : (moons.reduce(0, +) / Double(moons.count)) * 100
        return (min(100, composite), frames, retention, fwhmRatio, fwhm, moonPct, targets, filters)
    }

    /// Compute per-night Session Score. Always returns nightly data (never monthly aggregation).
    /// Combines retention rate (40%), FWHM quality (30%), trailing absence (20%), stability (10%).
    var sessionScores: [SessionScorePoint] {
        let allFWHMs = filteredSummaries.compactMap(\.medianFWHM)
        let baselineFWHM = allFWHMs.isEmpty ? 5.0 : allFWHMs.sorted()[allFWHMs.count / 2]

        var byKey: [String: [NightSummary]] = [:]
        for s in filteredSummaries {
            byKey[s.night, default: []].append(s)
        }

        return byKey.compactMap { key, summaries in
            guard let date = Self.nightDateFormatter.date(from: key) else { return nil }
            let result = nightCompositeScore(summaries: summaries, baselineFWHM: baselineFWHM)
            guard result.frames > 0 else { return nil }

            return SessionScorePoint(
                date: date, night: key, score: result.score,
                retentionRate: result.retention, fwhmNormalized: result.fwhmRatio,
                frameCount: result.frames,
                targets: result.targets, filters: result.filters,
                avgFWHM: result.fwhm, moonPct: result.moonPct,
                nightCount: nil
            )
        }.sorted { $0.date < $1.date }
    }

    /// Monthly median trend line data. Overlaid on the nightly bars when >6 months of data.
    /// Groups nightly scores by month and takes the median per month.
    var monthlyMedianScores: [SessionScorePoint] {
        guard useMonthlyAggregation else { return [] }
        let nightlyScores = sessionScores
        guard !nightlyScores.isEmpty else { return [] }

        var byMonth: [String: [Double]] = [:]
        for ns in nightlyScores {
            let mk = Self.monthKey(from: ns.date)
            byMonth[mk, default: []].append(ns.score)
        }

        return byMonth.compactMap { month, scores in
            guard let date = Self.dateFromMonthKey(month), !scores.isEmpty else { return nil }
            let sorted = scores.sorted()
            let median = sorted[sorted.count / 2]
            return SessionScorePoint(
                date: date, night: month, score: median,
                retentionRate: 0, fwhmNormalized: 1.0, frameCount: 0,
                targets: [], filters: [], avgFWHM: nil, moonPct: nil,
                nightCount: scores.count
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
        let monthly = useMonthlyAggregation
        return quality.compactMap { nq in
            // Gather context from filtered summaries for this period (night or month)
            let periodSummaries: [NightSummary]
            if monthly {
                periodSummaries = filteredSummaries.filter { s in
                    guard let d = Self.nightDateFormatter.date(from: s.night) else { return false }
                    return Self.monthKey(from: d) == nq.night
                }
            } else {
                periodSummaries = filteredSummaries.filter { $0.night == nq.night }
            }
            let nightSummaries = periodSummaries
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

    // MARK: - Chart Context Stats (shown in tooltips for comparison)

    /// Overall score stats for the filtered data
    var scoreChartStats: (avg: Double, median: Double)? {
        let scores = sessionScores.map(\.score)
        guard !scores.isEmpty else { return nil }
        let avg = scores.reduce(0, +) / Double(scores.count)
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        return (avg, median)
    }

    /// Overall efficiency stats
    var efficiencyChartStats: (avg: Double, median: Double)? {
        let vals = efficiencyData.map(\.retentionPct)
        guard !vals.isEmpty else { return nil }
        let avg = vals.reduce(0, +) / Double(vals.count)
        let sorted = vals.sorted()
        let median = sorted[sorted.count / 2]
        return (avg, median)
    }

    /// Overall FWHM stats
    var fwhmChartStats: (avg: Double, median: Double, mad: Double)? {
        let vals = equipmentHealthData.map(\.rawFWHM)
        guard vals.count >= 2 else { return nil }
        let avg = vals.reduce(0, +) / Double(vals.count)
        let sorted = vals.sorted()
        let median = sorted[sorted.count / 2]
        // .magnitude is unambiguous (single method on numeric types) where Swift 6
        // fails to resolve which abs() overload to use inside the closure.
        let deviations: [Double] = sorted.map { ($0 - median).magnitude }.sorted()
        let mad: Double = 1.4826 * deviations[sorted.count / 2]
        return (avg, median, mad)
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
            let hashes = mergedSetupHashes[setup.hash] ?? [setup.hash]
            guard let summary = try? FrameHistoryDatabase.shared.setupSummary(setupHashes: hashes) else {
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
