// v3.12.0
import Foundation

// Quality tier: two-stage detection.
// Stage 1 ("garbage"): absolute outlier detection — any single metric catastrophically bad → red
// Stage 2 ("relative"): weighted z-score comparison within group → green/orange/red
enum QualityTier: Int {
    case trash     = 0   // Red: garbage (absolute outlier) or statistically worst
    case uncertain = 1   // Orange: below average but not catastrophic
    case good      = 2   // Green: above average
}

// MARK: -

struct QualityEstimator {

    // Minimum group size to produce scores
    static let minGroupSize = 20

    // Stage 2: z-score thresholds for relative classification
    // Orange zone is intentionally wide — with 2x star weight, moderate differences
    // in star count can push z-scores down significantly. Only truly poor combined
    // scores should be red.
    static let thresholdGood:  Double = 0.5
    static let thresholdTrash: Double = -1.5

    // Stage 1: absolute garbage detection thresholds (percentile of group)
    // If a metric is below this percentile of the group, it's garbage regardless of other metrics
    static let garbagePercentile: Double = 0.10  // Bottom 10% is suspicious
    static let garbageDropFactor: Double = 0.50  // Value < 50% of group median → definite garbage

    // Narrowband filter keywords
    static let narrowbandKeywords = ["ha", "hα", "h-alpha", "halpha",
                                     "oiii", "o3", "sii", "s2",
                                     "hbeta", "hb", "nii", "n2"]

    // MARK: - Public API

    static func computeScores(for entries: [ImageEntry]) -> [URL: QualityTier] {
        var groups: [GroupKey: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            let key = GroupKey(entry: entry)
            groups[key, default: []].append(index)
        }

        var result: [URL: QualityTier] = [:]

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
                    result[entry.url] = .trash
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
                if combinedZ > thresholdGood {
                    tier = .good       // Green: above average
                } else if combinedZ < thresholdTrash {
                    tier = .trash      // Red: statistically worst
                } else {
                    tier = .uncertain  // Orange: below average but not terrible
                }

                result[entry.url] = tier
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
