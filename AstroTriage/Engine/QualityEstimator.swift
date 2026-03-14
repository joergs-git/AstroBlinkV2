// v3.12.0
import Foundation

// Four-tier quality system:
// Stage 1 ("garbage"): absolute outlier → red (any single metric catastrophically bad)
// Stage 2 ("relative"): weighted z-score within group → excellent/good/borderline/poor
enum QualityTier: Int {
    case trash      = 0   // Red X: catastrophic garbage (Stage 1) or statistically worst
    case borderline = 1   // Orange: on the edge — worth visual inspection before keeping
    case good       = 2   // Half-green: slightly below the best but definitely usable
    case excellent  = 3   // Full green: clearly above average — best frames
}

// MARK: -

struct QualityEstimator {

    // Minimum group size to produce scores
    static let minGroupSize = 20

    // Stage 2: z-score thresholds for 4-tier relative classification
    static let thresholdExcellent: Double =  0.5   // Top tier: clearly above average
    static let thresholdGood:      Double = -0.3   // Solid: near or slightly above average
    static let thresholdBorderline: Double = -1.2  // Edge: below average, check visually
    // Below borderline → trash (red) via Stage 2

    // Stage 1: absolute garbage detection thresholds (percentile of group)
    // If a metric is below this percentile of the group, it's garbage regardless of other metrics
    static let garbagePercentile: Double = 0.10  // Bottom 10% is suspicious
    static let garbageDropFactor: Double = 0.50  // Value < 50% of group median → definite garbage

    // Narrowband filter keywords
    static let narrowbandKeywords = ["ha", "hα", "h-alpha", "halpha",
                                     "oiii", "o3", "sii", "s2",
                                     "hbeta", "hb", "nii", "n2"]

    // MARK: - Public API

    static func computeScores(for entries: [ImageEntry]) -> [URL: (tier: QualityTier, zScore: Double)] {
        var groups: [GroupKey: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            let key = GroupKey(entry: entry)
            groups[key, default: []].append(index)
        }

        var result: [URL: (tier: QualityTier, zScore: Double)] = [:]

        for (_, indices) in groups {
            guard indices.count >= minGroupSize else { continue }

            let groupEntries = indices.map { entries[$0] }

            let filterName = (groupEntries.first?.filter ?? "").lowercased()
            let isNarrowband = narrowbandKeywords.contains(where: { filterName.contains($0) })
            // Stage 1 already catches catastrophic star count drops (< 50% of median).
            // Stage 2 only ranks remaining reasonable images — slight elevation is enough.
            let starWeight: Double = isNarrowband ? 0.5 : 1.2

            // Per-group source consistency
            let allHaveHeaderFWHM = groupEntries.allSatisfy { $0.fwhm != nil }
            let allHaveHeaderHFR = groupEntries.allSatisfy { $0.hfr != nil }
            let allHaveHeaderStars = groupEntries.allSatisfy { $0.starCount != nil }

            let fwhmValues: [Double?] = groupEntries.map { entry in
                allHaveHeaderFWHM ? entry.fwhm : entry.computedFWHM
            }
            let hfrValues: [Double?] = groupEntries.map { entry in
                allHaveHeaderHFR ? entry.hfr : entry.computedHFR
            }
            let starsValues: [Double?] = groupEntries.map { entry in
                let count = allHaveHeaderStars ? entry.starCount : entry.computedStarCount
                return count.map { Double($0) }
            }
            let snrValues: [Double?] = groupEntries.map { entry in
                guard let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return nil }
                return Double(med / mad)
            }

            // Compute group statistics for absolute garbage detection
            let starsMedian = sortedMedian(starsValues)
            let snrMedian = sortedMedian(snrValues)
            let fwhmMedian = sortedMedian(fwhmValues)
            let hfrMedian = sortedMedian(hfrValues)

            // Z-scores for relative scoring
            let fwhmZscores  = zscores(values: fwhmValues)
            let hfrZscores   = zscores(values: hfrValues)
            let starsZscores = zscores(values: starsValues)
            let noiseMadZscores = zscores(values: groupEntries.map { $0.noiseMAD.map { Double($0) } })

            for (localIdx, globalIdx) in indices.enumerated() {
                let entry = entries[globalIdx]

                // ── Stage 1: Absolute garbage detection ──
                // Any single metric catastrophically bad → immediate red
                var isGarbage = false

                // Rule 1: No stars or near-zero stars → garbage
                // (clouds, heavy fog, tracking failure, shutter issue)
                // Narrowband: star count naturally varies more due to bandpass → relax threshold
                if let stars = starsValues[localIdx], let median = starsMedian {
                    let dropThreshold = isNarrowband ? garbageDropFactor * 0.5 : garbageDropFactor  // 25% for NB, 50% for broadband
                    if stars < 1 || (median > 10 && stars < median * dropThreshold) {
                        isGarbage = true
                    }
                }

                // Rule 2: SNR catastrophically low compared to group
                // (clouds passing, dew on lens, light leak)
                if let snr = snrValues[localIdx], let median = snrMedian {
                    if median > 5 && snr < median * garbageDropFactor {
                        isGarbage = true
                    }
                }

                // Rule 3: FWHM catastrophically high (severe tracking error, defocus)
                // FWHM is "lower = better", so garbage = much higher than median
                if let fwhm = fwhmValues[localIdx], let median = fwhmMedian {
                    if median > 0 && fwhm > median * (1.0 / garbageDropFactor) {
                        isGarbage = true
                    }
                }

                // Rule 4: HFR catastrophically high (same logic as FWHM)
                if let hfr = hfrValues[localIdx], let median = hfrMedian {
                    if median > 0 && hfr > median * (1.0 / garbageDropFactor) {
                        isGarbage = true
                    }
                }

                if isGarbage {
                    result[entry.url] = (tier: .trash, zScore: -99.0)
                    continue
                }

                // ── Stage 2: Relative weighted z-score comparison ──
                var zSum: Double = 0
                var wSum: Double = 0

                if let z = fwhmZscores[localIdx] {
                    zSum += -z * 1.0     // lower FWHM = better → negate
                    wSum += 1.0
                }
                if let z = hfrZscores[localIdx] {
                    zSum += -z * 1.0     // lower HFR = better → negate
                    wSum += 1.0
                }
                if let z = starsZscores[localIdx] {
                    zSum += z * starWeight  // higher stars = better → keep sign
                    wSum += starWeight
                }
                if let z = noiseMadZscores[localIdx] {
                    zSum += -z * 1.0     // lower noise = better → negate
                    wSum += 1.0
                }

                guard wSum > 0 else { continue }

                let combinedZ = zSum / wSum

                let tier: QualityTier
                if combinedZ > thresholdExcellent {
                    tier = .excellent    // Full green: clearly above average
                } else if combinedZ > thresholdGood {
                    tier = .good         // Half-green: solid, near average
                } else if combinedZ > thresholdBorderline {
                    tier = .borderline   // Orange: on the edge, check visually
                } else {
                    tier = .trash        // Red: statistically worst
                }

                result[entry.url] = (tier: tier, zScore: combinedZ)
            }
        }

        return result
    }

    // MARK: - Private helpers

    /// Compute z-scores for an array of optional Doubles.
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

    /// Compute median of non-nil values
    private static func sortedMedian(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }.sorted()
        guard !present.isEmpty else { return nil }
        return present[present.count / 2]
    }
}

// MARK: - Group key

private struct GroupKey: Hashable {
    let filter:   String
    let object:   String
    let exposure: Int

    init(entry: ImageEntry) {
        filter   = (entry.filter   ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        object   = (entry.target   ?? "").trimmingCharacters(in: .whitespaces)
        exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
    }
}
