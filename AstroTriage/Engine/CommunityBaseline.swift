// v5.3.0 — Community Detection Learning: baseline models
//
// Anonymous community baselines for cold-start calibration.
// Downloaded from Supabase, cached locally for 7 days.
// Used when local CalibrationDatabase has < 30 frames for a setup.

import Foundation

// MARK: - Per-Filter Community Baseline

/// Aggregated quality baselines from community sessions with similar pixel scale.
/// All values are medians across contributing sessions (robust to outliers).
struct CommunityFilterBaseline: Codable {
    let medianFWHM: Double?
    let medianHFR: Double?
    let medianStars: Int?
    let medianNoiseMad: Double?
    let medianSNR: Double?
    let medianTrailing: Double?
    let medianEccentricity: Double?

    // Spread of retained frames (MAD) — used for floor checks
    let madFWHM: Double?
    let madSNR: Double?
    let madTrailing: Double?

    // Community behavior
    let avgRetentionRate: Double      // Fraction of frames kept [0..1]
    let contributingSessions: Int     // Number of sessions in this aggregate

    /// Check if a value is within N MADs of the community median
    func isWithinMAD(_ value: Double, median: Double?, mad: Double?, multiplier: Double = 1.0) -> Bool {
        guard let med = median, let m = mad, m > 0 else { return false }
        return Swift.abs(value - med) <= m * multiplier
    }
}

// MARK: - Community Baseline (per setup class)

/// Complete community baseline for a pixel-scale class.
/// Fetched from Supabase, cached locally with 7-day TTL.
struct CommunityBaseline: Codable {
    let pixelScaleCenter: Double      // Center of matched arcsec/pixel band
    let sessionCount: Int             // Total contributing sessions
    let machineCount: Int             // Unique machines contributing
    let filterBaselines: [String: CommunityFilterBaseline]  // Key: "FILTER|EXPOSURE"
    let fetchedAt: Date
    let expiresAt: Date               // fetchedAt + 7 days

    var isExpired: Bool {
        Date() > expiresAt
    }

    /// Get baseline for a filter+exposure group
    func baseline(filter: String, exposure: Int) -> CommunityFilterBaseline? {
        let key = CommunityBaseline.groupKey(filter: filter, exposure: exposure)
        return filterBaselines[key]
    }

    static func groupKey(filter: String, exposure: Int) -> String {
        let f = filter.uppercased().trimmingCharacters(in: .whitespaces)
        return "\(f.isEmpty ? "ALL" : f)|\(exposure)"
    }
}

// MARK: - Upload Model

/// Per-session group summary uploaded to Supabase after PRE-DELETE confirm.
/// One row per filter/exposure group. All data anonymized.
struct CommunitySessionEntry: Codable {
    let machine_hash: String
    let setup_hash: String
    let app_version: String

    // Setup class (anonymous — no equipment names)
    let focal_length_mm: Int
    let pixel_size_x10: Int
    let arcsec_per_pixel: Double
    let is_osc: Bool

    // Group context
    let filter_canonical: String
    let exposure_s: Int

    // Session statistics (aggregates of RETAINED frames only)
    let frame_count: Int
    let retained_count: Int

    // Metric medians of retained frames
    let median_fwhm: Double?
    let median_hfr: Double?
    let median_stars: Int?
    let median_noise_mad: Double?
    let median_snr: Double?
    let median_trailing: Double?
    let median_eccentricity: Double?

    // Metric spreads (MAD of retained frames)
    let mad_fwhm: Double?
    let mad_snr: Double?
    let mad_trailing: Double?

    // Algorithm performance
    let algo_flagged_trash: Int
    let user_overrode_keep: Int

    // Explicit user quality feedback counters (v5.22.0+).
    // Accumulated across all sessions for this setup — uploaded as a running total
    // so the server can track how often users agree/disagree with the algorithm's
    // tier assignments. Helps us tune thresholds over time.
    let user_agreed: Int
    let user_disagreed: Int
    let user_partly_agreed: Int

    // Algorithm version used when these metrics were computed.
    // Lets us correlate baseline drift with scoring algorithm changes.
    let algorithm_version: Int
}

// MARK: - Supabase RPC Response

/// Response from get_community_baseline RPC function.
/// Server-side aggregation returns medians across matching sessions.
struct CommunityBaselineResponse: Codable {
    let filter_canonical: String
    let exposure_s: Int
    let median_fwhm: Double?
    let median_hfr: Double?
    let median_stars: Int?
    let median_noise_mad: Double?
    let median_snr: Double?
    let median_trailing: Double?
    let median_eccentricity: Double?
    let mad_fwhm: Double?
    let mad_snr: Double?
    let mad_trailing: Double?
    let avg_retention_rate: Double?
    let session_count: Int
    let machine_count: Int
}
