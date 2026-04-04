// ViewModel for the Target Database catalog browser.
// Manages filtering, sorting, Frame History integration, and visibility data.

import Foundation
import Combine

@MainActor
class TargetDatabaseViewModel: ObservableObject {

    // MARK: - Filter State

    @Published var searchText: String = ""
    @Published var selectedType: String? = nil          // nil = all types
    @Published var selectedConstellation: String? = nil  // nil = all
    @Published var selectedDifficulty: String? = nil     // nil = all
    @Published var showTonightOnly: Bool = true  // default: show only tonight-visible targets
    @Published var showGapsOnly: Bool = false
    @Published var showOptimalFOV: Bool = false     // ≥30% FOV fill with current setup
    @Published var selectedDirections: Set<CompassDirection> = []  // empty = no filter
    @Published var selectedTarget: TargetCatalogService.CatalogTarget? = nil

    /// 8 compass directions for azimuth filtering
    enum CompassDirection: String, CaseIterable, Hashable {
        case n = "N", ne = "NE", e = "E", se = "SE"
        case s = "S", sw = "SW", w = "W", nw = "NW"

        /// Azimuth range for this direction (degrees)
        var azRange: ClosedRange<Double> {
            switch self {
            case .n:  return 337.5...360.0  // also 0...22.5, handled separately
            case .ne: return 22.5...67.5
            case .e:  return 67.5...112.5
            case .se: return 112.5...157.5
            case .s:  return 157.5...202.5
            case .sw: return 202.5...247.5
            case .w:  return 247.5...292.5
            case .nw: return 292.5...337.5
            }
        }

        static func from(azimuth: Double) -> CompassDirection {
            let az = azimuth.truncatingRemainder(dividingBy: 360)
            if az >= 337.5 || az < 22.5 { return .n }
            if az < 67.5 { return .ne }
            if az < 112.5 { return .e }
            if az < 157.5 { return .se }
            if az < 202.5 { return .s }
            if az < 247.5 { return .sw }
            if az < 292.5 { return .w }
            return .nw
        }
    }

    enum SortField: String, CaseIterable {
        case name = "Name"
        case type = "Type"
        case magnitude = "Magnitude"
        case size = "Size"
        case constellation = "Constellation"
        case altitude = "Tonight Alt"
        case integration = "Your Hours"
    }
    @Published var sortBy: SortField = .integration
    @Published var sortAscending: Bool = true

    // MARK: - Data

    @Published var allTargets: [TargetCatalogService.CatalogTarget] = []
    @Published var isLoading: Bool = false

    /// Per-target integration data from Frame History DB
    var targetHistory: [String: TargetIntegration] = [:]

    /// Tonight's visibility info per target
    var tonightVisibility: [String: AltAzCalculator.TonightInfo] = [:]

    /// Moon data for tonight
    @Published var moonIllumination: Double = 0  // 0-1
    @Published var moonDistance: [String: Double] = [:]  // canonical name → degrees
    @Published var moonAltitudeCurve: [AltAzCalculator.VisibilityPoint] = []

    /// Per-target compass directions: primary (at transit) + all directions while above 15°
    var targetPrimaryDirection: [String: CompassDirection] = [:]  // direction at max altitude
    var targetAllDirections: [String: Set<CompassDirection>] = [:]  // all directions above 15°

    /// Session targets (canonical names in current session)
    let sessionTargets: Set<String>

    /// Observer location from Frame History or user profile
    @Published var observerLocation: (lat: Double, lon: Double)?

    /// All known imaging locations from user profile (for picker)
    var allLocations: [AIsaacUserProfile.ImagingLocation] = []

    /// Selected location index (into allLocations). Changing this recomputes visibility.
    @Published var selectedLocationIndex: Int = 0 {
        didSet {
            guard selectedLocationIndex < allLocations.count else { return }
            let loc = allLocations[selectedLocationIndex]
            observerLocation = (lat: loc.latitude, lon: loc.longitude)
            // Also update equipment to match — pick the setup last used closest to this location's lastUsed date
            if let bestSetup = equipmentSetups.min(by: {
                Swift.abs($0.lastUsed.timeIntervalSince(loc.lastUsed)) < Swift.abs($1.lastUsed.timeIntervalSince(loc.lastUsed))
            }) {
                selectedSetupIndex = equipmentSetups.firstIndex(of: bestSetup) ?? 0
            }
            computeVisibility(latitude: loc.latitude, longitude: loc.longitude)
            fetchWeather(latitude: loc.latitude, longitude: loc.longitude)
        }
    }

    /// Selected equipment setup index (for FOV simulation + history filtering)
    @Published var selectedSetupIndex: Int = 0 {
        didSet {
            computeFOVFillRatios()
            loadTargetHistory()
        }
    }

    /// Available equipment setups from user profile
    var equipmentSetups: [AIsaacUserProfile.EquipmentSetup] = []

    /// Currently selected setup (convenience)
    var currentSetup: AIsaacUserProfile.EquipmentSetup? {
        guard selectedSetupIndex < equipmentSetups.count else { return nil }
        return equipmentSetups[selectedSetupIndex]
    }

    /// Tonight's weather forecast (from 7Timer + Open-Meteo)
    @Published var weatherForecast: AIsaacWeatherService.AstroForecast?
    @Published var isLoadingWeather: Bool = false

    /// Per-target FOV fill ratio with current setup
    var fovFillRatios: [String: Double] = [:]

    // MARK: - Derived

    var allTypes: [(type: String, count: Int)] {
        let counts = Dictionary(grouping: allTargets, by: { $0.targetType })
        return counts.map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.type < $1.type }
    }

    var allConstellations: [String] {
        Array(Set(allTargets.map { $0.constellation })).sorted()
    }

    var filteredTargets: [TargetCatalogService.CatalogTarget] {
        var result = allTargets

        // Type filter
        if let type = selectedType {
            result = result.filter { $0.targetType == type }
        }

        // Constellation filter
        if let con = selectedConstellation {
            result = result.filter { $0.constellation == con }
        }

        // Difficulty filter
        if let diff = selectedDifficulty {
            result = result.filter { $0.difficulty == diff }
        }

        // Search text (name, common name, aliases)
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { target in
                target.canonicalName.lowercased().contains(query) ||
                (target.commonName?.lowercased().contains(query) ?? false) ||
                (target.aliases?.contains { $0.lowercased().contains(query) } ?? false) ||
                target.constellation.lowercased().contains(query)
            }
        }

        // Tonight visible filter (max alt > 30°)
        if showTonightOnly {
            result = result.filter { target in
                guard let info = tonightVisibility[target.canonicalName] else { return false }
                return info.maxAltitude >= 30.0
            }
        }

        // Filter gap filter — only targets with EXISTING history that have imbalanced filters
        if showGapsOnly {
            result = result.filter { target in
                guard let primary = target.primaryFilter,
                      let history = targetHistory[target.canonicalName] else { return false }
                return hasFilterGap(recommended: primary, actual: history.perFilterHours)
            }
        }

        // Compass direction filter — uses PRIMARY direction (at transit/max altitude)
        // Selected directions are OR-linked: show if primary direction matches ANY selected
        if !selectedDirections.isEmpty {
            result = result.filter { target in
                guard let primary = targetPrimaryDirection[target.canonicalName] else { return false }
                return selectedDirections.contains(primary)
            }
        }

        // Optimal FOV filter (≥30% fill with current setup)
        if showOptimalFOV {
            result = result.filter { target in
                guard let fill = fovFillRatios[target.canonicalName] else { return false }
                return fill >= 0.3
            }
        }

        // Sort
        result.sort { a, b in
            let cmp: Bool
            switch sortBy {
            case .name:
                cmp = a.canonicalName < b.canonicalName
            case .type:
                cmp = a.targetType < b.targetType
            case .magnitude:
                cmp = (a.magnitudeV ?? 99) < (b.magnitudeV ?? 99)
            case .size:
                cmp = (a.angularSizeMajor ?? 0) > (b.angularSizeMajor ?? 0)  // bigger first
            case .constellation:
                cmp = a.constellation < b.constellation
            case .altitude:
                let altA = tonightVisibility[a.canonicalName]?.maxAltitude ?? -90
                let altB = tonightVisibility[b.canonicalName]?.maxAltitude ?? -90
                cmp = altA > altB  // higher first
            case .integration:
                let hA = targetHistory[a.canonicalName]?.totalHours ?? 0
                let hB = targetHistory[b.canonicalName]?.totalHours ?? 0
                cmp = hA > hB  // more hours first
            }
            return sortAscending ? cmp : !cmp
        }

        return result
    }

    var targetCount: Int { filteredTargets.count }
    var totalCount: Int { allTargets.count }
    var historyCount: Int { targetHistory.count }

    // MARK: - Init

    init(sessionTargets: Set<String>) {
        self.sessionTargets = sessionTargets
    }

    private var refreshObserver: Any?

    // MARK: - Load

    func loadData() {
        isLoading = true

        // Load targets from Supabase cache (may be empty on first launch)
        allTargets = TargetCatalogService.shared.getTargets()

        // If cache is empty, force a synchronous-ish fetch and observe for refresh
        if allTargets.isEmpty {
            TargetCatalogService.shared.forceRefresh()
        }

        // Observe refresh notification to reload when Supabase data arrives
        refreshObserver = NotificationCenter.default.addObserver(
            forName: TargetCatalogService.didRefreshNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.allTargets = TargetCatalogService.shared.targets
                // Recompute visibility for new targets
                if let loc = self.observerLocation {
                    self.computeVisibility(latitude: loc.lat, longitude: loc.lon)
                }
            }
        }

        // Load equipment and locations from user profile
        let profile = AIsaacUserProfile.load()
        equipmentSetups = profile.equipmentSetups
        allLocations = profile.locations.sorted(by: { $0.lastUsed > $1.lastUsed })

        // Set initial location (most recently used)
        if let loc = allLocations.first {
            observerLocation = (lat: loc.latitude, lon: loc.longitude)
            selectedLocationIndex = 0
        } else {
            loadObserverLocationFromHistory()
        }

        // Load Frame History data for all known targets
        loadTargetHistory()

        // Compute FOV fill ratios for all targets with current setup
        computeFOVFillRatios()

        // Compute tonight's visibility for all targets
        if let loc = observerLocation {
            computeVisibility(latitude: loc.lat, longitude: loc.lon)
            fetchWeather(latitude: loc.lat, longitude: loc.lon)
        }

        isLoading = false
    }

    /// Try to get observer location from the most recent frame in history DB
    private func loadObserverLocationFromHistory() {
        let db = FrameHistoryDatabase.shared
        do {
            let summaries = try db.nightlyTrendAll()
            // nightlyTrendAll doesn't include lat/lon directly,
            // but we can try the user profile's locations which are populated from FITS headers
            // If no profile location, the visibility features are simply disabled
        } catch {
            // Non-critical
        }
    }

    // MARK: - Frame History Integration

    func reloadTargetHistory() {
        loadTargetHistory()
        objectWillChange.send()
    }

    private func loadTargetHistory() {
        let db = FrameHistoryDatabase.shared

        // Build setupHash from selected equipment for setup-specific filtering
        let setupHash: String?
        if let setup = currentSetup {
            let fp = SetupFingerprint(telescope: setup.telescope, camera: setup.camera,
                                      focalLength: setup.focalLength, pixelSizeMicrons: setup.pixelSize)
            setupHash = fp.hash
        } else {
            setupHash = nil
        }

        do {
            // Filter by selected setup if available
            let summaries: [NightSummary]
            if let hash = setupHash {
                summaries = try db.nightlyTrend(setupHash: hash)
            } else {
                summaries = try db.nightlyTrendAll()
            }

            // Aggregate NightSummary records into per-target integration structs
            var byTarget: [String: TargetIntegration] = [:]
            for summary in summaries {
                guard let target = summary.target, !target.isEmpty else { continue }
                let canonical = TargetCatalog.canonicalName(target)
                let filter = summary.filter ?? "?"
                let usable = summary.goodCount + summary.excellentCount
                guard usable > 0 else { continue }
                let hours = Double(usable) * (summary.medianExposure ?? 0) / 3600.0

                if var existing = byTarget[canonical] {
                    existing.totalHours += hours
                    existing.perFilterHours[filter, default: 0] += hours
                    existing.totalFrames += usable
                    existing.sessionCount += 1
                    if existing.lastImaged == nil || summary.night > existing.lastImaged! {
                        existing.lastImaged = summary.night
                    }
                    if let f = summary.medianFWHM, existing.medianFWHM == nil || f < existing.medianFWHM! {
                        existing.medianFWHM = f
                    }
                    byTarget[canonical] = existing
                } else {
                    byTarget[canonical] = TargetIntegration(
                        totalHours: hours,
                        perFilterHours: [filter: hours],
                        totalFrames: usable,
                        sessionCount: 1,
                        lastImaged: summary.night,
                        medianFWHM: summary.medianFWHM,
                        medianQualityTier: nil
                    )
                }
            }

            targetHistory = byTarget
        } catch {
            // Non-critical — catalog works without history
        }
    }

    // MARK: - Visibility

    private func computeVisibility(latitude: Double, longitude: Double) {
        let today = Date()

        // Compute in batches on background to not block UI
        let targets = allTargets
        Task.detached(priority: .utility) {
            var results: [String: AltAzCalculator.TonightInfo] = [:]
            var moonDists: [String: Double] = [:]

            // Moon data
            let moonIllum = MoonCalculator.illumination(utcDate: today)
            let moonPos = MoonCalculator.position(utcDate: today)

            // Moon altitude curve (same time window as targets)
            let moonCurve: [AltAzCalculator.VisibilityPoint]
            if let mp = moonPos {
                moonCurve = AltAzCalculator.visibilityCurve(
                    ra: mp.ra, dec: mp.dec,
                    latitude: latitude, longitude: longitude,
                    date: today
                )
            } else {
                moonCurve = []
            }

            var primaryDirs: [String: CompassDirection] = [:]
            var allDirs: [String: Set<CompassDirection>] = [:]

            for target in targets {
                let info = AltAzCalculator.tonightInfo(
                    ra: target.raJ2000, dec: target.decJ2000,
                    latitude: latitude, longitude: longitude,
                    date: today
                )
                results[target.canonicalName] = info

                // Compute compass directions: primary (at max alt) + all (while above 15°)
                var dirs = Set<CompassDirection>()
                var maxAltPoint: (alt: Double, time: Date) = (-99, today)
                for point in info.curve where point.altitude >= 15 {
                    let altAz = AltAzCalculator.compute(
                        ra: target.raJ2000, dec: target.decJ2000,
                        latitude: latitude, longitude: longitude,
                        utcDate: point.time
                    )
                    dirs.insert(CompassDirection.from(azimuth: altAz.azimuth))
                    if point.altitude > maxAltPoint.alt {
                        maxAltPoint = (point.altitude, point.time)
                    }
                }
                allDirs[target.canonicalName] = dirs

                // Primary direction = direction at maximum altitude (transit)
                if maxAltPoint.alt > 0 {
                    let transitAz = AltAzCalculator.compute(
                        ra: target.raJ2000, dec: target.decJ2000,
                        latitude: latitude, longitude: longitude,
                        utcDate: maxAltPoint.time
                    )
                    primaryDirs[target.canonicalName] = CompassDirection.from(azimuth: transitAz.azimuth)
                }

                // Moon-target angular separation
                if let mp = moonPos {
                    let dist = MoonCalculator.angularSeparation(
                        ra1: target.raJ2000, dec1: target.decJ2000,
                        ra2: mp.ra, dec2: mp.dec
                    )
                    moonDists[target.canonicalName] = dist
                }
            }
            await MainActor.run { [results, moonDists, moonCurve, moonIllum, primaryDirs, allDirs] in
                self.tonightVisibility = results
                self.moonDistance = moonDists
                self.moonAltitudeCurve = moonCurve
                self.moonIllumination = moonIllum
                self.targetPrimaryDirection = primaryDirs
                self.targetAllDirections = allDirs
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - FOV Fill

    func computeFOVFillRatios() {
        guard let setup = currentSetup, let fov = fovArcmin(setup: setup) else {
            fovFillRatios = [:]
            return
        }
        let fovDiag = (fov.width * fov.width + fov.height * fov.height).squareRoot()
        var ratios: [String: Double] = [:]
        for target in allTargets {
            guard let major = target.angularSizeMajor, let minor = target.angularSizeMinor else { continue }
            let targetDiag = (major * major + minor * minor).squareRoot()
            ratios[target.canonicalName] = targetDiag / fovDiag
        }
        fovFillRatios = ratios
    }

    // MARK: - Weather

    private func fetchWeather(latitude: Double, longitude: Double) {
        isLoadingWeather = true
        Task {
            let forecast = await AIsaacWeatherService.shared.getForecast(lat: latitude, lon: longitude)
            self.weatherForecast = forecast
            self.isLoadingWeather = false
        }
    }

    /// Tonight's summary: avg cloud, seeing (location-relative), temperature, humidity, wind
    var weatherSummary: (cloud: Int, seeing: String, seeingQuality: String, temp: Int?, humidity: Int?, wind: Int?)? {
        guard let forecast = weatherForecast else { return nil }
        let tz = TimeZone.current
        let cal = Calendar.current
        let nightHours = forecast.hours.filter { hour in
            let comps = cal.dateComponents(in: tz, from: hour.time)
            let h = comps.hour ?? 12
            return h >= 18 || h <= 6
        }
        guard !nightHours.isEmpty else { return nil }
        let n = min(8, nightHours.count)
        let avgCloud = nightHours.prefix(n).map { $0.cloudCover }.reduce(0, +) / n
        let avgSeeing = nightHours.prefix(n).map { $0.seeing }.reduce(0, +) / n

        // Absolute seeing description
        let seeingArcsec: String
        switch avgSeeing {
        case 1: seeingArcsec = "<0.5\""
        case 2: seeingArcsec = "0.5-0.75\""
        case 3: seeingArcsec = "0.75-1\""
        case 4: seeingArcsec = "1-1.25\""
        case 5: seeingArcsec = "1.25-1.5\""
        case 6: seeingArcsec = "1.5-2\""
        case 7: seeingArcsec = "2-2.5\""
        case 8: seeingArcsec = ">2.5\""
        default: seeingArcsec = "?"
        }

        // Location-relative seeing quality
        // Typical seeing baseline by latitude (rough but practical):
        // - Equatorial/subtropical high-altitude observatories (Chile, Hawaii, Canary Islands): 0.5-1.0"
        // - Mediterranean/subtropical (SW USA, S Europe): 1.0-1.5"
        // - Temperate (Central Europe, Northern US, 40-55°N): 1.5-2.5"
        // - High latitude (Scandinavia, UK): 2.0-3.0"
        let lat = Swift.abs(observerLocation?.lat ?? 50)
        let baselineSeeing: Int  // 7Timer scale baseline for this latitude
        if lat < 30 { baselineSeeing = 3 }       // ~1" typical
        else if lat < 40 { baselineSeeing = 4 }   // ~1.25" typical
        else if lat < 55 { baselineSeeing = 5 }   // ~1.5" typical (Central Europe)
        else { baselineSeeing = 6 }                // ~2" typical (Northern Europe)

        let seeingQuality: String
        if avgSeeing <= baselineSeeing - 2 { seeingQuality = "Exceptional" }
        else if avgSeeing <= baselineSeeing - 1 { seeingQuality = "Very good" }
        else if avgSeeing <= baselineSeeing { seeingQuality = "Good" }
        else if avgSeeing <= baselineSeeing + 1 { seeingQuality = "Average" }
        else { seeingQuality = "Below average" }

        let temps = nightHours.prefix(n).compactMap { $0.temperature }
        let avgTemp = temps.isEmpty ? nil : Int(temps.reduce(0, +) / Double(temps.count))
        let humids = nightHours.prefix(n).compactMap { $0.humidity }
        let avgHumidity = humids.isEmpty ? nil : humids.reduce(0, +) / humids.count
        let winds = nightHours.prefix(n).compactMap { $0.windSpeed }
        let avgWind = winds.isEmpty ? nil : Int(winds.reduce(0, +) / Double(winds.count))

        return (cloud: avgCloud, seeing: seeingArcsec, seeingQuality: seeingQuality,
                temp: avgTemp, humidity: avgHumidity, wind: avgWind)
    }

    // MARK: - Filter Gap Analysis

    func filterGapAnalysis(target: TargetCatalogService.CatalogTarget) -> FilterGapResult? {
        guard let primary = target.primaryFilter else { return nil }
        let actual = targetHistory[target.canonicalName]?.perFilterHours ?? [:]
        return analyzeGap(recommended: primary, actual: actual)
    }

    private func hasFilterGap(recommended: TargetCatalogService.FilterInfo, actual: [String: Double]) -> Bool {
        guard !recommended.ratios.isEmpty else { return false }
        if actual.isEmpty { return true }  // never imaged

        let totalActual = actual.values.reduce(0, +)
        guard totalActual > 0 else { return true }

        let totalRatio = Double(recommended.ratios.values.reduce(0, +))
        for (filter, ratio) in recommended.ratios {
            let expected = totalActual * (Double(ratio) / totalRatio)
            let actualHours = actual[filter] ?? 0
            if actualHours < expected * 0.4 { return true }  // < 40% of proportional share
        }
        return false
    }

    private func analyzeGap(recommended: TargetCatalogService.FilterInfo, actual: [String: Double]) -> FilterGapResult {
        let totalActual = actual.values.reduce(0, +)
        let totalRatio = Double(recommended.ratios.values.reduce(0, +))

        var filterStatus: [FilterStatus] = []
        for (filter, ratio) in recommended.ratios.sorted(by: { $0.key < $1.key }) {
            let proportion = Double(ratio) / totalRatio
            let expectedHours = max(totalActual * proportion, proportion * 4.0)  // at least 4h total baseline
            let actualHours = actual[filter] ?? 0
            let completion = expectedHours > 0 ? actualHours / expectedHours : 0
            let gapHours = max(0, expectedHours - actualHours)

            let status: GapLevel
            if completion >= 0.8 { status = .good }
            else if completion >= 0.4 { status = .partial }
            else { status = .gap }

            filterStatus.append(FilterStatus(
                filter: filter, ratio: ratio,
                actualHours: actualHours, expectedHours: expectedHours,
                completion: completion, gapHours: gapHours, level: status
            ))
        }

        return FilterGapResult(filterSet: recommended.set, filters: filterStatus, totalActualHours: totalActual)
    }

    // MARK: - FOV Computation

    /// Compute FOV in arcminutes for a given equipment setup.
    func fovArcmin(setup: AIsaacUserProfile.EquipmentSetup, sensorWidth: Int = 9576, sensorHeight: Int = 6388) -> (width: Double, height: Double)? {
        guard let fl = setup.focalLength, let px = setup.pixelSize, fl > 0 else { return nil }
        let plateScale = 206.265 * px / fl  // arcsec/pixel
        let fovW = plateScale * Double(sensorWidth) / 60.0   // arcminutes
        let fovH = plateScale * Double(sensorHeight) / 60.0
        return (width: fovW, height: fovH)
    }
}

// MARK: - Supporting Types

struct TargetIntegration {
    var totalHours: Double
    var perFilterHours: [String: Double]
    var totalFrames: Int
    var sessionCount: Int
    var lastImaged: String?
    var medianFWHM: Double?
    var medianQualityTier: Double?
}

enum GapLevel { case good, partial, gap }

struct FilterStatus {
    let filter: String
    let ratio: Int
    let actualHours: Double
    let expectedHours: Double
    let completion: Double  // 0.0 - 1.0+
    let gapHours: Double
    let level: GapLevel
}

struct FilterGapResult {
    let filterSet: String
    let filters: [FilterStatus]
    let totalActualHours: Double

    var hasGap: Bool { filters.contains { $0.level == .gap } }
    var worstGap: FilterStatus? { filters.min(by: { $0.completion < $1.completion }) }
}
