// v5.3.0 — Community Detection Learning Service
//
// Uploads anonymized session summaries after PRE-DELETE confirm.
// Downloads community baselines for cold-start calibration.
// Follows BenchmarkSharing.swift pattern: Supabase REST API, fire-and-forget uploads.
//
// Privacy guarantees:
// - No filenames, paths, coordinates, dates/times, target names, equipment names
// - Only SHA256 setup hash + numeric metrics
// - RLS: INSERT + SELECT only (no UPDATE/DELETE)

import Foundation

// MARK: - Community Detection Service

final class CommunityDetectionService {

    static let shared = CommunityDetectionService()

    // Local cache directory for downloaded baselines
    private let cacheDirectory: URL
    private static let cacheTTLDays = 7

    // In-memory cache of fetched baselines (keyed by pixel-scale bucket string)
    private var baselineCache: [String: CommunityBaseline] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectory = appSupport.appendingPathComponent("AstroBlinkV2/Community", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Upload (after PRE-DELETE confirm)

    /// Upload session group summaries. Called after CalibrationDatabase.commitSession().
    /// Async, fire-and-forget — errors are silently ignored (no user impact).
    func uploadSessionData(entries: [ImageEntry], fingerprint: SetupFingerprint) {
        guard AppSettings.defaults.bool(forKey: AppSettings.Key.communityLearning.rawValue) else { return }
        guard BenchmarkConfig.isConfigured else { return }

        let retained = entries.filter { !$0.isMarkedForDeletion }
        guard retained.count >= 6 else { return }  // Minimum upload threshold

        // Determine if OSC (any image has bayer pattern)
        let isOSC = entries.contains { $0.bayerPattern != nil }

        // Compute arcsec/pixel
        let fl = Double(fingerprint.focalLength)
        let px = Double(fingerprint.pixelSizeMicrons) / 10.0
        let arcsecPerPixel = (fl > 0 && px > 0) ? 206.265 * px / fl : 0

        // Group retained frames by canonical filter + exposure
        var groups: [String: [ImageEntry]] = [:]
        for entry in retained {
            let filter = ColorCombineEngine.canonicalFilterName(entry.filter ?? "")
            let exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
            let key = "\(filter)|\(exposure)"
            groups[key, default: []].append(entry)
        }

        // Build upload entries per group.
        //
        // v5.22.1 fix: feedback & algorithm-agreement counters are scoped to each
        // filter/exposure group individually, NOT session-wide. Prior versions
        // computed them once across all entries and stamped the same total onto
        // every group row, which inflated server-side aggregates by a factor of
        // (number of groups per session).
        var uploadEntries: [CommunitySessionEntry] = []
        for (key, groupEntries) in groups {
            guard groupEntries.count >= 6 else { continue }
            let parts = key.split(separator: "|")
            guard parts.count == 2 else { continue }
            let filterCanonical = String(parts[0])
            let exposureS = Int(parts[1]) ?? 0

            // Full group population (retained + marked-for-deletion) —
            // algo_flagged_trash & user_overrode_keep are defined over this set.
            // Explicit [ImageEntry] annotation keeps the Swift type-checker fast,
            // otherwise the chained filter closures below stress inference.
            let groupAll: [ImageEntry] = entries.filter { e in
                let entryFilter = ColorCombineEngine.canonicalFilterName(e.filter ?? "")
                let entryExposure: Int
                if let exp = e.exposure {
                    entryExposure = Int(exp.rounded())
                } else {
                    entryExposure = 0
                }
                return entryFilter == filterCanonical && entryExposure == exposureS
            }
            let totalInGroup = groupAll.count

            // Per-group algorithm agreement counters
            let groupAlgoFlagged = groupAll.filter {
                $0.qualityTier == .trash && $0.qualityBreakdown?.garbageReasons.isEmpty == false
            }.count
            let groupUserOverrode = groupAll.filter {
                $0.qualityTier == .trash && !$0.isMarkedForDeletion
            }.count

            // Per-group explicit quality feedback (from the A-key cycle).
            // Counts every frame in this group — retained AND marked — because
            // feedback reflects the user's opinion of the algorithm's tier, which
            // applies regardless of whether the frame ended up being deleted.
            let groupAgreed = groupAll.filter { $0.qualityFeedback == .agree }.count
            let groupDisagreed = groupAll.filter { $0.qualityFeedback == .disagree }.count
            let groupPartly = groupAll.filter { $0.qualityFeedback == .partly }.count

            let entry = CommunitySessionEntry(
                machine_hash: MachineInfo.machineHash,
                setup_hash: fingerprint.hash,
                app_version: MachineInfo.appVersion,
                focal_length_mm: fingerprint.focalLength,
                pixel_size_x10: fingerprint.pixelSizeMicrons,
                arcsec_per_pixel: arcsecPerPixel,
                is_osc: isOSC,
                filter_canonical: filterCanonical,
                exposure_s: exposureS,
                frame_count: totalInGroup,
                retained_count: groupEntries.count,
                median_fwhm: Self.median(groupEntries.compactMap(\.displayFWHM)),
                median_hfr: Self.median(groupEntries.compactMap(\.displayHFR)),
                median_stars: Self.medianInt(groupEntries.compactMap(\.displayStarCount)),
                median_noise_mad: Self.median(groupEntries.compactMap { $0.noiseMAD.map(Double.init) }),
                median_snr: Self.median(groupEntries.compactMap { self.snr(for: $0) }),
                median_trailing: Self.median(groupEntries.compactMap(\.trailingScore)),
                median_eccentricity: Self.median(groupEntries.compactMap(\.computedEccentricity)),
                mad_fwhm: Self.mad(groupEntries.compactMap(\.displayFWHM)),
                mad_snr: Self.mad(groupEntries.compactMap { self.snr(for: $0) }),
                mad_trailing: Self.mad(groupEntries.compactMap(\.trailingScore)),
                algo_flagged_trash: groupAlgoFlagged,
                user_overrode_keep: groupUserOverrode,
                user_agreed: groupAgreed,
                user_disagreed: groupDisagreed,
                user_partly_agreed: groupPartly,
                algorithm_version: kAlgorithmVersion
            )
            uploadEntries.append(entry)
        }

        guard !uploadEntries.isEmpty else { return }

        // Fire-and-forget async upload
        Task.detached(priority: .utility) {
            for entry in uploadEntries {
                do {
                    // Duplicate check: same machine + setup + filter + exposure + frame count
                    let isDupe = try await self.checkDuplicate(entry: entry)
                    if !isDupe {
                        try await self.upload(entry: entry)
                    }
                } catch {
                    // Silent failure — community upload must never affect user workflow
                }
            }
        }
    }

    // MARK: - Download (on session load)

    /// Fetch community baseline for the current setup's pixel scale.
    /// Returns cached data if available and not expired.
    func fetchCommunityBaseline(fingerprint: SetupFingerprint) async -> CommunityBaseline? {
        guard AppSettings.defaults.bool(forKey: AppSettings.Key.communityLearning.rawValue) else { return nil }
        guard BenchmarkConfig.isConfigured else { return nil }

        let fl = Double(fingerprint.focalLength)
        let px = Double(fingerprint.pixelSizeMicrons) / 10.0
        guard fl > 0, px > 0 else { return nil }
        let pixelScale = 206.265 * px / fl
        let cacheKey = String(format: "%.2f", pixelScale)

        // Check in-memory cache first
        if let cached = baselineCache[cacheKey], !cached.isExpired {
            return cached
        }

        // Check disk cache
        if let diskCached = loadFromDisk(cacheKey: cacheKey), !diskCached.isExpired {
            baselineCache[cacheKey] = diskCached
            return diskCached
        }

        // Fetch from Supabase RPC
        do {
            let responses = try await fetchFromSupabase(pixelScale: pixelScale)
            guard !responses.isEmpty else { return nil }

            // Build CommunityBaseline from responses
            var filterBaselines: [String: CommunityFilterBaseline] = [:]
            var totalSessions = 0
            var totalMachines = 0

            for r in responses {
                let key = CommunityBaseline.groupKey(filter: r.filter_canonical, exposure: r.exposure_s)

                // Sanity bounds — reject physically impossible values
                if let fwhm = r.median_fwhm, (fwhm < 0.5 || fwhm > 30) { continue }
                if let snr = r.median_snr, snr < 1.0 { continue }
                if let trail = r.median_trailing, (trail < 0 || trail > 1) { continue }
                if let retention = r.avg_retention_rate, retention < 0.1 { continue }

                // Minimum contributors: ≥5 sessions from ≥3 machines
                guard r.session_count >= 5, r.machine_count >= 3 else { continue }

                filterBaselines[key] = CommunityFilterBaseline(
                    medianFWHM: r.median_fwhm,
                    medianHFR: r.median_hfr,
                    medianStars: r.median_stars,
                    medianNoiseMad: r.median_noise_mad,
                    medianSNR: r.median_snr,
                    medianTrailing: r.median_trailing,
                    medianEccentricity: r.median_eccentricity,
                    madFWHM: r.mad_fwhm,
                    madSNR: r.mad_snr,
                    madTrailing: r.mad_trailing,
                    avgRetentionRate: r.avg_retention_rate ?? 0.8,
                    contributingSessions: r.session_count
                )
                totalSessions = max(totalSessions, r.session_count)
                totalMachines = max(totalMachines, r.machine_count)
            }

            guard !filterBaselines.isEmpty else { return nil }

            let now = Date()
            let baseline = CommunityBaseline(
                pixelScaleCenter: pixelScale,
                sessionCount: totalSessions,
                machineCount: totalMachines,
                filterBaselines: filterBaselines,
                fetchedAt: now,
                expiresAt: now.addingTimeInterval(Double(Self.cacheTTLDays) * 86400)
            )

            // Cache in memory and on disk
            baselineCache[cacheKey] = baseline
            saveToDisk(baseline: baseline, cacheKey: cacheKey)

            return baseline
        } catch {
            return nil
        }
    }

    // MARK: - Community Floor Check

    /// Check if a frame meets the community quality floor.
    /// Same logic as CalibrationDatabase.meetsAbsoluteFloor but using community medians/MADs.
    /// Only use when local calibration has < 30 frames.
    static func meetsCommunityFloor(entry: ImageEntry, baseline: CommunityBaseline) -> Bool {
        let filter = ColorCombineEngine.canonicalFilterName(entry.filter ?? "")
        let exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
        guard let fb = baseline.baseline(filter: filter, exposure: exposure) else { return false }

        var checksPerformed = 0
        var checksPassed = 0

        if let fwhm = entry.displayFWHM {
            if fb.isWithinMAD(fwhm, median: fb.medianFWHM, mad: fb.madFWHM) {
                checksPerformed += 1
                checksPassed += 1
            } else if fb.medianFWHM != nil && fb.madFWHM != nil {
                checksPerformed += 1
            }
        }

        if let snr = Self.computeSNR(entry: entry) {
            if fb.isWithinMAD(snr, median: fb.medianSNR, mad: fb.madSNR) {
                checksPerformed += 1
                checksPassed += 1
            } else if fb.medianSNR != nil && fb.madSNR != nil {
                checksPerformed += 1
            }
        }

        if let trail = entry.trailingScore {
            if fb.isWithinMAD(trail, median: fb.medianTrailing, mad: fb.madTrailing) {
                checksPerformed += 1
                checksPassed += 1
            } else if fb.medianTrailing != nil && fb.madTrailing != nil {
                checksPerformed += 1
            }
        }

        // Must have checked at least 2 metrics and ALL must pass
        return checksPerformed >= 2 && checksPassed == checksPerformed
    }

    // MARK: - Private: Supabase API

    private func checkDuplicate(entry: CommunitySessionEntry) async throws -> Bool {
        var urlString = "\(BenchmarkConfig.supabaseURL)/rest/v1/community_sessions?select=id&limit=1"
        urlString += "&machine_hash=eq.\(entry.machine_hash)"
        urlString += "&setup_hash=eq.\(entry.setup_hash)"
        urlString += "&filter_canonical=eq.\(entry.filter_canonical)"
        urlString += "&exposure_s=eq.\(entry.exposure_s)"
        urlString += "&frame_count=eq.\(entry.frame_count)"
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
        let results = try JSONDecoder().decode([[String: String]].self, from: data)
        return !results.isEmpty
    }

    private func upload(entry: CommunitySessionEntry) async throws {
        guard let url = URL(string: "\(BenchmarkConfig.supabaseURL)/rest/v1/community_sessions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.timeoutInterval = 30

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        request.httpBody = try encoder.encode(entry)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return  // Silent failure
        }
    }

    private func fetchFromSupabase(pixelScale: Double) async throws -> [CommunityBaselineResponse] {
        // Query with pixel-scale ±10% tolerance
        let minScale = pixelScale * 0.9
        let maxScale = pixelScale * 1.1

        // Use Supabase RPC for server-side aggregation
        guard let url = URL(string: "\(BenchmarkConfig.supabaseURL)/rest/v1/rpc/get_community_baseline") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "min_scale": minScale,
            "max_scale": maxScale
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }

        return try JSONDecoder().decode([CommunityBaselineResponse].self, from: data)
    }

    // MARK: - Private: Disk Cache

    private func diskCacheURL(cacheKey: String) -> URL {
        cacheDirectory.appendingPathComponent("community_\(cacheKey).json")
    }

    private func loadFromDisk(cacheKey: String) -> CommunityBaseline? {
        let url = diskCacheURL(cacheKey: cacheKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CommunityBaseline.self, from: data)
    }

    private func saveToDisk(baseline: CommunityBaseline, cacheKey: String) {
        let url = diskCacheURL(cacheKey: cacheKey)
        guard let data = try? JSONEncoder().encode(baseline) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Private: Statistics

    private func snr(for entry: ImageEntry) -> Double? {
        guard let median = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return nil }
        return Double(median) / Double(mad)
    }

    static func computeSNR(entry: ImageEntry) -> Double? {
        guard let median = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return nil }
        return Double(median) / Double(mad)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private static func medianInt(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func mad(_ values: [Double]) -> Double? {
        guard let med = median(values), values.count >= 3 else { return nil }
        let deviations = values.map { Swift.abs($0 - med) }
        return median(deviations).map { $0 * 1.4826 }  // Scale factor for normal distribution
    }
}
