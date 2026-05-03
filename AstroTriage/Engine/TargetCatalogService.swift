// Supabase-backed target catalog service with offline disk cache.
// Fetches deep-sky target data from the target_catalog table.
// Pattern: identical to AIsaacKnowledgeService (TTL cache + background refresh).
// The catalog is the source for the Target Database browser window.
// The embedded DeepSkyTargetDatabase (229 targets) remains the scoring source.

import Foundation

class TargetCatalogService {
    static let shared = TargetCatalogService()

    // MARK: - Data Model

    struct CatalogTarget: Codable, Identifiable, Hashable {
        var id: String { canonicalName }

        let dbId: Int
        let canonicalName: String
        let commonName: String?
        let aliases: [String]?
        let targetType: String
        let raJ2000: Double
        let decJ2000: Double
        let angularSizeMajor: Double?
        let angularSizeMinor: Double?
        let positionAngle: Double?
        let magnitudeV: Double?
        let magnitudeB: Double?
        let surfaceBrightness: Double?
        let constellation: String
        let primaryFilter: FilterInfo?
        let secondaryFilter: FilterInfo?
        let filterNotes: String?
        let fwhmWeight: Double?
        let starWeight: Double?
        let noiseWeight: Double?
        let trailingWeight: Double?
        let description: String?
        let imagingNotes: String?
        let difficulty: String?
        let minFocalLength: Double?
        let maxFocalLength: Double?
        let minIntegrationHours: Double?
        let bestMonths: [Int]?
        let source: String?

        enum CodingKeys: String, CodingKey {
            case dbId = "id"
            case canonicalName = "canonical_name"
            case commonName = "common_name"
            case aliases
            case targetType = "target_type"
            case raJ2000 = "ra_j2000"
            case decJ2000 = "dec_j2000"
            case angularSizeMajor = "angular_size_major"
            case angularSizeMinor = "angular_size_minor"
            case positionAngle = "position_angle"
            case magnitudeV = "magnitude_v"
            case magnitudeB = "magnitude_b"
            case surfaceBrightness = "surface_brightness"
            case constellation
            case primaryFilter = "primary_filter"
            case secondaryFilter = "secondary_filter"
            case filterNotes = "filter_notes"
            case fwhmWeight = "fwhm_weight"
            case starWeight = "star_weight"
            case noiseWeight = "noise_weight"
            case trailingWeight = "trailing_weight"
            case description
            case imagingNotes = "imaging_notes"
            case difficulty
            case minFocalLength = "min_focal_length"
            case maxFocalLength = "max_focal_length"
            case minIntegrationHours = "min_integration_hours"
            case bestMonths = "best_months"
            case source
        }

        // Custom decoder: Supabase sends ints for whole numbers (6 not 6.0)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dbId = (try? c.decode(Int.self, forKey: .dbId)) ?? 0
            canonicalName = try c.decode(String.self, forKey: .canonicalName)
            commonName = try c.decodeIfPresent(String.self, forKey: .commonName)
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
            targetType = try c.decode(String.self, forKey: .targetType)
            raJ2000 = Self.flexDouble(c, .raJ2000) ?? 0
            decJ2000 = Self.flexDouble(c, .decJ2000) ?? 0
            angularSizeMajor = Self.flexDouble(c, .angularSizeMajor)
            angularSizeMinor = Self.flexDouble(c, .angularSizeMinor)
            positionAngle = Self.flexDouble(c, .positionAngle)
            magnitudeV = Self.flexDouble(c, .magnitudeV)
            magnitudeB = Self.flexDouble(c, .magnitudeB)
            surfaceBrightness = Self.flexDouble(c, .surfaceBrightness)
            constellation = try c.decode(String.self, forKey: .constellation)
            primaryFilter = try c.decodeIfPresent(FilterInfo.self, forKey: .primaryFilter)
            secondaryFilter = try c.decodeIfPresent(FilterInfo.self, forKey: .secondaryFilter)
            filterNotes = try c.decodeIfPresent(String.self, forKey: .filterNotes)
            fwhmWeight = Self.flexDouble(c, .fwhmWeight)
            starWeight = Self.flexDouble(c, .starWeight)
            noiseWeight = Self.flexDouble(c, .noiseWeight)
            trailingWeight = Self.flexDouble(c, .trailingWeight)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            imagingNotes = try c.decodeIfPresent(String.self, forKey: .imagingNotes)
            difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty)
            minFocalLength = Self.flexDouble(c, .minFocalLength)
            maxFocalLength = Self.flexDouble(c, .maxFocalLength)
            minIntegrationHours = Self.flexDouble(c, .minIntegrationHours)
            bestMonths = try c.decodeIfPresent([Int].self, forKey: .bestMonths)
            source = try c.decodeIfPresent(String.self, forKey: .source)
        }

        // Decode a number that might be Int or Double in JSON
        private static func flexDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
            if let d = try? c.decode(Double.self, forKey: key) { return d }
            if let i = try? c.decode(Int.self, forKey: key) { return Double(i) }
            return nil
        }

        // Hash/Equatable by canonical name only (stable identity)
        func hash(into hasher: inout Hasher) { hasher.combine(canonicalName) }
        static func == (lhs: CatalogTarget, rhs: CatalogTarget) -> Bool {
            lhs.canonicalName == rhs.canonicalName
        }

        // Convenience: display name with common name
        var displayName: String {
            if let common = commonName, !common.isEmpty {
                return "\(canonicalName) (\(common))"
            }
            return canonicalName
        }

        // Human-readable type
        var typeDisplayName: String {
            targetType.replacingOccurrences(of: "_", with: " ").capitalized
        }

        // NASA/STScI Digitized Sky Survey thumbnail URL (public domain, no API key).
        // Fixed 15 arcmin FOV keeps downloads small (~200-500KB). Shows central region for large targets.
        var dssThumbnailURL: URL? {
            let fov = min(15, max(5, angularSizeMajor ?? 10))
            let urlStr = "https://archive.stsci.edu/cgi-bin/dss_search" +
                "?v=poss2ukstu_red&r=\(raJ2000)&d=\(decJ2000)&e=J2000" +
                "&h=\(fov)&w=\(fov)&f=gif&c=none"
            return URL(string: urlStr)
        }

        // Angular size diagonal in arcminutes
        var angularSizeDiagonal: Double? {
            guard let major = angularSizeMajor, let minor = angularSizeMinor else { return nil }
            return (major * major + minor * minor).squareRoot()
        }
    }

    struct FilterInfo: Codable, Hashable {
        let set: String          // "SHO", "HOO", "LRGB", "HaLRGB", "RGB", "L"
        let ratios: [String: Int] // {"Ha": 4, "OIII": 3, "SII": 2}

        // Formatted description: "SHO (Ha:4 OIII:3 SII:2)"
        var formatted: String {
            let order = ["L", "R", "G", "B", "Ha", "OIII", "SII", "Hbeta", "NII"]
            let sorted = ratios.sorted { a, b in
                let ia = order.firstIndex(of: a.key) ?? 99
                let ib = order.firstIndex(of: b.key) ?? 99
                return ia < ib
            }
            let parts = sorted.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            return "\(set) (\(parts))"
        }
    }

    // MARK: - Cache

    private(set) var targets: [CatalogTarget] = []
    private var lastFetch: Date?
    private let refreshInterval: TimeInterval = 86400  // 24 hours — catalog changes rarely
    private let cacheFile: URL
    private var isFetching = false

    /// Notification posted when targets are refreshed from Supabase
    static let didRefreshNotification = Notification.Name("TargetCatalogDidRefresh")

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("AstroBlinkV2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheFile = dir.appendingPathComponent("target_catalog_cache.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// Get all targets. Returns cached data immediately.
    /// Triggers background refresh if stale.
    func getTargets() -> [CatalogTarget] {
        fetchIfNeeded()
        return targets
    }

    /// Trigger background fetch if cache is stale.
    func fetchIfNeeded() {
        guard shouldRefresh(), !isFetching else { return }
        isFetching = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchFromSupabase()
            await MainActor.run { self?.isFetching = false }
        }
    }

    /// Force refresh from Supabase (user-triggered).
    func forceRefresh() {
        isFetching = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchFromSupabase()
            await MainActor.run { self?.isFetching = false }
        }
    }

    // MARK: - Network

    private func shouldRefresh() -> Bool {
        guard let last = lastFetch else { return true }
        return Date().timeIntervalSince(last) > refreshInterval
    }

    private func fetchFromSupabase() async {
        guard BenchmarkConfig.isConfigured else { return }

        guard let url = SupabaseClient.restURL(
            table: "target_catalog",
            query: "select=*&is_active=eq.true&order=canonical_name"
        ) else { return }

        var request = SupabaseClient.makeRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            // Catalog can be large; default 30s timeout matches prior behavior.
            let (data, response) = try await SupabaseClient.send(request, retries: 2)
            guard response.statusCode == 200 else {
                return
            }
            let decoder = JSONDecoder()
            let fetched = try decoder.decode([CatalogTarget].self, from: data)

            guard !fetched.isEmpty else { return }  // don't replace cache with empty result

            await MainActor.run {
                self.targets = fetched
                self.lastFetch = Date()
                NotificationCenter.default.post(name: Self.didRefreshNotification, object: nil)
            }

            saveToDisk()
        } catch {
            // Silent failure — disk cache is the fallback
        }
    }

    // MARK: - Disk Cache

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFile.path) else { return }
        do {
            let data = try Data(contentsOf: cacheFile)
            let decoded = try JSONDecoder().decode(DiskCache.self, from: data)
            targets = decoded.targets
            lastFetch = decoded.lastFetch
        } catch {
            // Corrupted cache — will be rebuilt on next fetch
        }
    }

    private func saveToDisk() {
        let diskCache = DiskCache(targets: targets, lastFetch: lastFetch ?? Date())
        do {
            let data = try JSONEncoder().encode(diskCache)
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            // Non-critical
        }
    }

    private struct DiskCache: Codable {
        let targets: [CatalogTarget]
        let lastFetch: Date
    }
}
