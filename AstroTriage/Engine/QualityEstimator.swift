// v3.5.0
import Foundation

// Three-level quality tier assigned per image relative to its group.
// "Group" = same filter + object + night + exposure time (min 20 frames required).
// Score is always relative (z-score within group), never based on absolute thresholds.
enum QualityTier: Int {
    case trash     = 0   // Statistically worse than group average (z < −1.0)
    case uncertain = 1   // Near group average (−1.0 ≤ z ≤ 0.5)
    case good      = 2   // Statistically above average (z > 0.5)
}

// MARK: -

struct QualityEstimator {

    // Minimum group size to produce scores.
    // Below this threshold, quality tier stays nil ("not enough data").
    static let minGroupSize = 20

    // Z-score thresholds for tier classification
    static let thresholdGood:  Double = 0.5
    static let thresholdTrash: Double = -1.0

    // Narrowband filter keywords: star count is suppressed by the bandpass → lower weight
    static let narrowbandKeywords = ["ha", "hα", "h-alpha", "halpha",
                                     "oiii", "o3", "sii", "s2",
                                     "hbeta", "hb", "nii", "n2"]

    // MARK: - Public API

    /// Compute quality tiers for all images in `entries`.
    /// Returns a mapping URL → QualityTier for images where a tier can be assigned.
    /// Images in groups with < minGroupSize members receive no tier (not included in result).
    ///
    /// Metrics used (in order of availability):
    ///   Tier 1 — from FITS/XISF headers or NINA filename tokens (if present):
    ///     FWHM, HFR (lower = better), StarCount (higher = better)
    ///   Always available — from prefetch STF subsample:
    ///     noiseMAD (lower = better; reflects noise floor, cloud scatter, bad seeing)
    static func computeScores(for entries: [ImageEntry]) -> [URL: QualityTier] {
        // Group images by (filter, object, night, exposure)
        var groups: [GroupKey: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            let key = GroupKey(entry: entry)
            groups[key, default: []].append(index)
        }

        var result: [URL: QualityTier] = [:]

        for (_, indices) in groups {
            guard indices.count >= minGroupSize else { continue }

            let groupEntries = indices.map { entries[$0] }

            // Determine star-count weight from filter name
            let filterName = (groupEntries.first?.filter ?? "").lowercased()
            let isNarrowband = narrowbandKeywords.contains(where: { filterName.contains($0) })
            let starWeight: Double = isNarrowband ? 0.3 : 1.0

            // Tier-1 metrics from headers / filename tokens (not always present)
            let fwhmZscores  = zscores(values: groupEntries.map { $0.fwhm })
            let hfrZscores   = zscores(values: groupEntries.map { $0.hfr })
            let starsZscores = zscores(values: groupEntries.map { $0.starCount.map { Double($0) } })

            // noiseMAD from STF subsample — always available once prefetch has run.
            // Lower noiseMAD = less noise scatter = better frame (clouds/bad seeing raise it).
            let noiseMadZscores = zscores(values: groupEntries.map { $0.noiseMAD.map { Double($0) } })

            for (localIdx, globalIdx) in indices.enumerated() {
                let entry = entries[globalIdx]

                // Collect available per-image weighted z-scores.
                // FWHM, HFR, noiseMAD: lower = better → negate.
                // StarCount: higher = better → keep sign.
                var zSum: Double = 0
                var wSum: Double = 0

                if let z = fwhmZscores[localIdx] {
                    zSum += -z * 1.0
                    wSum += 1.0
                }
                if let z = hfrZscores[localIdx] {
                    zSum += -z * 1.0
                    wSum += 1.0
                }
                if let z = starsZscores[localIdx] {
                    zSum += z * starWeight
                    wSum += starWeight
                }
                if let z = noiseMadZscores[localIdx] {
                    zSum += -z * 1.0
                    wSum += 1.0
                }

                // No metrics available for this image → skip
                guard wSum > 0 else { continue }

                let combinedZ = zSum / wSum

                let tier: QualityTier
                if combinedZ > thresholdGood {
                    tier = .good
                } else if combinedZ < thresholdTrash {
                    tier = .trash
                } else {
                    tier = .uncertain
                }

                result[entry.url] = tier
            }
        }

        return result
    }

    // MARK: - Private helpers

    /// Compute z-scores for an array of optional Doubles.
    /// Returns an array parallel to `values`: nil where the input was nil, Double otherwise.
    private static func zscores(values: [Double?]) -> [Double?] {
        let present = values.compactMap { $0 }
        guard present.count >= 2 else {
            return Array(repeating: nil, count: values.count)
        }

        let mean = present.reduce(0, +) / Double(present.count)
        let variance = present.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(present.count)
        let std = variance.squareRoot()

        guard std > 0 else {
            return values.map { $0 != nil ? 0.0 : nil }
        }

        return values.map { val -> Double? in
            guard let v = val else { return nil }
            return (v - mean) / std
        }
    }
}

// MARK: - Group key

/// Identifies a comparable group of images for relative quality scoring.
/// Groups are defined by: filter + object + acquisition night + exposure duration.
private struct GroupKey: Hashable {
    let filter:   String   // Uppercase filter name, "" if unknown
    let object:   String   // Target object name, "" if unknown
    let night:    String   // First 10 chars of DATE-LOC/DATE-OBS (YYYY-MM-DD), "" if unknown
    let exposure: Int      // Exposure time rounded to nearest second, 0 if unknown

    init(entry: ImageEntry) {
        filter   = (entry.filter   ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        object   = (entry.target   ?? "").trimmingCharacters(in: .whitespaces)
        night    = String((entry.date ?? "").prefix(10))
        exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
    }
}
