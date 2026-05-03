// Curation upload service — mirrors every rated frame (userConfidence > 0)
// to the public.curated_frames Supabase table for remote regression analysis.
//
// Fire-and-forget pattern: network failures are silently swallowed, same as
// BenchmarkSharing.autoUploadSessionLoad. The source of truth is always the
// local Frame History DB; Supabase is just a mirror that I (Claude) can query
// from any session via MCP without needing your local machine to be online.
//
// Upsert semantics: Supabase PostgREST supports ON CONFLICT via the
// `Prefer: resolution=merge-duplicates` header paired with the table's
// UNIQUE (file_hash, machine_hash) constraint. Re-rating a frame overwrites
// the previous row.
//
// Clearing a rating (tap same key twice) DELETEs the row so stale labels
// don't accumulate when the user changes their mind.

import Foundation

enum CurationService {

    // MARK: - Entry payload

    /// Matches the column layout of public.curated_frames on Supabase.
    /// Snake_case to match PostgREST defaults — no custom CodingKeys needed.
    struct CuratedFrameEntry: Encodable {
        let file_hash: String
        let machine_hash: String
        let setup_hash: String?

        let filename: String?
        let capture_date: String?
        let capture_time: String?
        let observing_night: String?

        let telescope: String?
        let camera: String?
        let focal_length_mm: Double?
        let pixel_size_microns: Double?

        let target: String?
        let canonical_target: String?
        let filter: String?
        let exposure_s: Double?
        let gain: Int?

        let computed_fwhm: Double?
        let computed_hfr: Double?
        let computed_star_count: Int?
        let computed_eccentricity: Double?
        let noise_median: Double?
        let noise_mad: Double?
        let psf_flux: Double?
        let trailing_score: Double?
        let trailing_axis_ratio: Double?

        let moon_illumination: Double?
        let moon_distance: Double?
        let bortle_class: Double?
        let twilight_phase: String?

        let quality_tier: Int?
        let combined_z_score: Double?
        let garbage_reasons: String?

        let user_confidence: Int
        let quality_feedback: Int?
        let algorithm_version: Int
        let app_version: String?
    }

    // MARK: - Public entry points

    /// Async upsert for a single rated frame. Called from TriageViewModel
    /// when the user sets a non-zero confidence via 1/2/3 or the context menu.
    /// Silent failure on network error — local DB remains the source of truth.
    static func uploadCuratedFrame(_ entry: ImageEntry) {
        guard BenchmarkConfig.isConfigured else { return }
        guard entry.userConfidence > 0 else { return }
        guard let fileHash = entry.fileHash else { return }

        let payload = buildEntry(from: entry, fileHash: fileHash)

        Task.detached(priority: .utility) {
            try? await upsert(entry: payload)
        }
    }

    /// Delete a curated row (used when the user clears a rating by tapping
    /// the same number key twice). Silent failure on network error.
    static func deleteCuratedFrame(fileHash: String) {
        guard BenchmarkConfig.isConfigured else { return }
        let machineHash = MachineInfo.machineHash

        Task.detached(priority: .utility) {
            try? await delete(fileHash: fileHash, machineHash: machineHash)
        }
    }

    /// Bulk sync: iterate every userConfidence > 0 row from the local Frame
    /// History DB and upsert each to Supabase. Called from the Advanced menu
    /// as a backfill for frames rated while offline, or after a client-side
    /// DB migration. Returns (synced, failed) counts via the completion handler.
    @MainActor
    static func bulkSync(completion: @escaping (_ synced: Int, _ failed: Int) -> Void) {
        guard BenchmarkConfig.isConfigured else {
            completion(0, 0)
            return
        }

        Task.detached(priority: .utility) {
            var synced = 0
            var failed = 0

            guard let records = try? FrameHistoryDatabase.shared.curatedFrameRecords() else {
                await MainActor.run { completion(0, 0) }
                return
            }

            for record in records {
                let payload = buildEntry(from: record)
                do {
                    try await upsert(entry: payload)
                    synced += 1
                } catch {
                    failed += 1
                }
            }

            let finalSynced = synced
            let finalFailed = failed
            await MainActor.run { completion(finalSynced, finalFailed) }
        }
    }

    // MARK: - Entry builders

    /// Build an upload entry from an in-memory ImageEntry. Used from the live
    /// 1/2/3 rating path, where the entry has the most up-to-date metric values.
    /// Internal (not private) so CurationServiceTests can exercise field mapping.
    static func buildEntry(from entry: ImageEntry, fileHash: String) -> CuratedFrameEntry {
        // Derive the setup hash the same way currentSetupFingerprint does,
        // from the entry's own equipment fields.
        let setupHash = SetupFingerprint(
            telescope: entry.telescope,
            camera: entry.camera,
            focalLength: entry.focalLength,
            pixelSizeMicrons: entry.pixelSizeMicrons
        ).hash

        let qb = entry.qualityBreakdown
        let garbageJSON: String? = {
            guard let reasons = qb?.garbageReasons, !reasons.isEmpty else { return nil }
            let arr = reasons.map(\.rawValue)
            return (try? JSONEncoder().encode(arr)).flatMap { String(data: $0, encoding: .utf8) }
        }()

        return CuratedFrameEntry(
            file_hash: fileHash,
            machine_hash: MachineInfo.machineHash,
            setup_hash: setupHash,

            filename: entry.filename,
            capture_date: entry.date,
            capture_time: entry.time,
            observing_night: entry.observingNight,

            telescope: entry.telescope,
            camera: entry.camera,
            focal_length_mm: entry.focalLength,
            pixel_size_microns: entry.pixelSizeMicrons,

            target: entry.target,
            canonical_target: entry.canonicalTarget,
            filter: entry.filter,
            exposure_s: entry.exposure,
            gain: entry.gain,

            computed_fwhm: entry.computedFWHM,
            computed_hfr: entry.computedHFR,
            computed_star_count: entry.computedStarCount,
            computed_eccentricity: entry.computedEccentricity,
            noise_median: entry.noiseMedian.map(Double.init),
            noise_mad: entry.noiseMAD.map(Double.init),
            psf_flux: entry.psfFluxSum,
            trailing_score: entry.trailingScore,
            trailing_axis_ratio: entry.trailingAxisRatio,

            moon_illumination: entry.moonIllumination,
            moon_distance: entry.moonDistance,
            bortle_class: entry.bortleClass,
            twilight_phase: entry.twilightPhase?.rawValue,

            quality_tier: qb?.tier.rawValue,
            combined_z_score: qb?.combinedZScore,
            garbage_reasons: garbageJSON,

            user_confidence: entry.userConfidence,
            quality_feedback: entry.qualityFeedback == .none ? nil : entry.qualityFeedback.rawValue,
            algorithm_version: kAlgorithmVersion,
            app_version: MachineInfo.appVersion
        )
    }

    /// Build an upload entry from a stored FrameRecord. Used from the bulk
    /// sync path, which operates on whatever the DB currently holds (may be
    /// slightly stale relative to the live session state, but that's fine —
    /// the auto-upload path covers every fresh rating).
    /// Internal (not private) so CurationServiceTests can exercise field mapping.
    static func buildEntry(from record: FrameRecord) -> CuratedFrameEntry {
        CuratedFrameEntry(
            file_hash: record.fileHash,
            machine_hash: MachineInfo.machineHash,
            setup_hash: record.setupHash,

            filename: record.filename,
            capture_date: record.captureDate,
            capture_time: record.captureTime,
            observing_night: record.observingNight,

            telescope: record.telescope,
            camera: record.camera,
            focal_length_mm: record.focalLength,
            pixel_size_microns: record.pixelSizeMicrons,

            target: record.target,
            canonical_target: record.canonicalTarget,
            filter: record.filter,
            exposure_s: record.exposure,
            gain: record.gain,

            computed_fwhm: record.computedFWHM,
            computed_hfr: record.computedHFR,
            computed_star_count: record.computedStarCount,
            computed_eccentricity: record.computedEccentricity,
            noise_median: record.noiseMedian,
            noise_mad: record.noiseMAD,
            psf_flux: record.psfFlux,
            trailing_score: record.trailingScore,
            trailing_axis_ratio: record.trailingAxisRatio,

            moon_illumination: record.moonIllumination,
            moon_distance: record.moonDistance,
            bortle_class: record.bortleClass,
            twilight_phase: record.twilightPhase,

            quality_tier: record.qualityTier,
            combined_z_score: record.combinedZScore,
            garbage_reasons: record.garbageReasons,

            user_confidence: record.userConfidence,
            quality_feedback: record.qualityFeedback == 0 ? nil : record.qualityFeedback,
            algorithm_version: record.algorithmVersion,
            app_version: MachineInfo.appVersion
        )
    }

    // MARK: - HTTP

    private enum CurationError: Error {
        case badURL, badResponse(Int), encoding
    }

    /// UPSERT via PostgREST: `Prefer: resolution=merge-duplicates` pairs with
    /// the UNIQUE (file_hash, machine_hash) constraint so the same frame can
    /// be re-rated without creating duplicate rows.
    private static func upsert(entry: CuratedFrameEntry) async throws {
        guard var request = SupabaseClient.jsonInsertRequest(
            table: "curated_frames",
            prefer: "resolution=merge-duplicates,return=minimal"
        ) else {
            throw CurationError.badURL
        }

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(entry)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CurationError.badResponse(code)
        }
    }

    /// DELETE the row for this (file_hash, machine_hash) pair. Called when
    /// the user clears a rating by tapping the same number key twice.
    private static func delete(fileHash: String, machineHash: String) async throws {
        // URL-encode in case a hash ever contains special chars (shouldn't, but defensive).
        let allowed = CharacterSet.urlQueryAllowed
        let fhEnc = fileHash.addingPercentEncoding(withAllowedCharacters: allowed) ?? fileHash
        let mhEnc = machineHash.addingPercentEncoding(withAllowedCharacters: allowed) ?? machineHash

        guard let url = SupabaseClient.restURL(
            table: "curated_frames",
            query: "file_hash=eq.\(fhEnc)&machine_hash=eq.\(mhEnc)"
        ) else { throw CurationError.badURL }

        var request = SupabaseClient.makeRequest(url: url, method: "DELETE", withBearer: true)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CurationError.badResponse(code)
        }
    }
}
