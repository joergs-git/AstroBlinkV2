// v4.3.0
import Foundation

// Four-tier quality system with sub-tiers for borderline:
// Stage 1 ("garbage"): absolute outlier → red (any single metric catastrophically bad)
// Stage 2 ("relative"): weighted z-score within group → excellent/good/borderline/poor
enum QualityTier: Int {
    case trash      = 0   // Red X: catastrophic garbage (Stage 1) or statistically worst
    case borderline = 1   // Orange: on the edge — worth visual inspection before keeping
    case good       = 2   // Half-green: slightly below the best but definitely usable
    case excellent  = 3   // Full green: clearly above average — best frames
}

// Stage 1 garbage reason — explains WHY a frame was immediately flagged as trash
enum GarbageReason: String, Hashable {
    case noData            = "no signal detected"
    case noStars           = "zero/near-zero stars"
    case lowSNR            = "SNR catastrophically low"
    case highFWHM          = "severe defocus/tracking"
    case highHFR           = "severe defocus"
    case elongated         = "star trailing/elongation"
    case starCountAnomaly  = "doubled stars (tracking jump)"
    case backgroundAnomaly = "abnormal background (clouds/gradient)"
    case trackingHop       = "tracking hops (star chains)"
}

// Full quality breakdown per image — replaces the old (tier, zScore) tuple.
// Pre-computes everything needed for tooltips and live SNR retention bar.
struct QualityBreakdown: Hashable {
    let tier: QualityTier
    let combinedZScore: Double

    // Per-metric z-scores (nil = metric not available for this image)
    let starsZ: Double?
    let fwhmZ: Double?
    let hfrZ: Double?
    let noiseZ: Double?
    let trailingZ: Double?  // Trailing score z-score (higher = more trailing = worse)

    // SNR contribution: (SNR_i / SNR_best)^2 as percentage [0..100]
    // Shows how much this frame adds to a weighted stack relative to the best frame.
    let snrContribution: Double?

    // Cached SNR^2 for live SNR retention bar (avoids recomputation on every Space toggle)
    let snrSquared: Double?

    // Garbage reason (nil if not Stage 1 garbage)
    let garbageReason: GarbageReason?

    // Absolute quality floor: frame meets calibration baseline for ALL metrics.
    // When true, z-scores cannot override — this frame is locked as KEEP.
    // Only set when the setup has ≥30 learned frames.
    let isLockedKeep: Bool

    // Human-readable explanation of why this frame received its tier.
    // Generated during scoring when group context is available.
    let reasoningText: String?

    // Smart recommendation label based on per-metric analysis
    // Smart recommendation based on per-metric analysis and eccentricity.
    // Research shows: round stars = always keep (even with worse FWHM/noise).
    // FWHM of final stack barely changes when including softer-but-round frames.
    // Eccentricity is the one hard boundary — elongated stars can't be fixed by stacking.
    var recommendationLabel: String {
        // Locked keep from calibration floor — overrides z-score recommendations
        if isLockedKeep {
            return "KEEP — within calibrated baseline"
        }

        if let reason = garbageReason {
            return "DELETE — \(reason.rawValue)"
        }

        guard tier == .borderline else { return "" }

        // Check eccentricity first — the critical differentiator
        let hasHighEcc = (trailingZ ?? 0) > 1.5  // Significantly more trailing than group average
        if hasHighEcc {
            return "REVIEW — stars may be elongated"
        }

        // Stars are round (or eccentricity not available) — safe to keep
        let hasBadStars = (starsZ ?? 0) < -1.0
        let hasBadFWHM = (fwhmZ ?? 0) > 1.0       // fwhm z is raw (not negated) — higher = worse
        let hasBadNoise = (noiseZ ?? 0) > 1.0

        let badCount = [hasBadStars, hasBadFWHM, hasBadNoise].filter { $0 }.count

        if badCount == 0 {
            return "KEEP — useful for SNR"
        }

        if hasBadNoise && !hasBadFWHM {
            return "KEEP — noisy but round stars, adds integration"
        }

        if hasBadFWHM {
            // Softer seeing but round stars — research shows final stack FWHM barely changes
            return "KEEP — softer seeing, round stars still add SNR"
        }

        if hasBadStars && !hasBadFWHM && !hasBadNoise {
            return "KEEP — fewer stars but quality OK"
        }

        return "KEEP — round stars contribute to stack"
    }

    // Borderline severity for orange gradient icons (0-3, 0 = nearly good, 3 = nearly trash)
    // Only meaningful when tier == .borderline
    var borderlineSeverity: Int {
        guard tier == .borderline else { return 0 }
        // Range is thresholdGood (-0.5) to thresholdBorderline (-2.0), span = 1.5
        // Split into 4 sub-tiers
        let z = combinedZScore
        if z > -0.875 { return 0 }       // Nearly good
        if z > -1.25  { return 1 }       // Middle borderline
        if z > -1.625 { return 2 }       // Leaning towards trash
        return 3                          // Nearly trash
    }
}

// MARK: -

struct QualityEstimator {

    // Minimum group size to produce meaningful z-scores (median/MAD needs at least ~6 samples)
    static let minGroupSize = 6

    // Stage 2: z-score thresholds for 4-tier relative classification
    // Widened from original (-0.3/-1.2/-1.5) after validation on 1457 frames/6 setups.
    // Sessions with exceptional quality blocks (e.g. peak seeing mid-session) can have
    // wide z-score distributions. At -1.5, frames that are "normal by absolute standards"
    // but "below average for this excellent session" get trashed. -2.0 ensures only
    // frames that are clearly degraded (2σ below average) become z-score trash.
    // Stage 1 garbage detection catches truly catastrophic frames regardless.
    // The Autopilot button gives users control: Conservative keeps borderline,
    // Balanced removes severe borderline, Aggressive removes all borderline.
    static let thresholdExcellent: Double =  0.5   // Top tier: clearly above average
    static let thresholdGood:      Double = -0.5   // Solid: within normal session variation
    static let thresholdBorderline: Double = -2.0  // Edge: noticeably below average (was -1.5)
    // Below -2.0 → trash (red) via Stage 2

    // Stage 2: z-score cap — prevents extreme scores from normal variation.
    // In homogeneous groups (tight MAD), a 10-15% difference can produce z > 4.
    // Cap at ±3.0 so multiple metrics must agree for trash classification.
    // Genuinely bad frames are already caught by Stage 1 garbage detection.
    static let zscoreCap: Double = 3.0

    // Stage 1: absolute garbage detection thresholds (percentile of group)
    // If a metric is below this percentile of the group, it's garbage regardless of other metrics
    static let garbagePercentile: Double = 0.10  // Bottom 10% is suspicious
    static let garbageDropFactor: Double = 0.50  // Value < 50% of group median → definite garbage

    // Broadband filters where star count is a reliable quality indicator.
    // Everything else — narrowband (Ha, OIII, SII...), dual-band (L-eXtreme, L-Ultimate),
    // tri-band (L-Quadband, NBZ), or unknown — gets reduced star weight (0.5).
    // This handles all current and future filter types without maintaining a narrowband list.
    static let broadbandCanonical: Set<String> = ["L", "R", "G", "B"]

    // MARK: - Public API

    /// Compute quality scores with optional calibration data for absolute quality floor.
    /// When calibrationDB and fingerprint are provided, frames that meet the learned baseline
    /// for ALL metrics are locked as KEEP — z-scores cannot override them.
    static func computeScores(
        for entries: [ImageEntry],
        calibrationDB: CalibrationDatabase? = nil,
        fingerprint: SetupFingerprint? = nil
    ) -> [URL: QualityBreakdown] {
        // Two-pass night-aware scoring for multi-night sessions:
        // Pass 1: combined groups (all nights merged) → every entry gets a baseline score
        // Pass 2: per-night groups (>= minGroupSize) → overwrite with per-night scores
        // This ensures frames in small per-night groups (e.g. 3 B frames from one night)
        // still get scored via the combined group, while large per-night groups get
        // more accurate per-night scoring.
        let uniqueNights = Set(entries.compactMap { $0.observingNight })
        let useNight = uniqueNights.count > 1

        // Ordered list: combined groups first, per-night overrides second
        var groupsList: [(key: GroupKey, indices: [Int])] = []

        // Combined groups (session-wide, ignoring night) — baseline for all entries
        var combinedGroups: [GroupKey: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            let key = GroupKey(entry: entry, useNight: false)
            combinedGroups[key, default: []].append(index)
        }
        groupsList.append(contentsOf: combinedGroups.map { ($0.key, $0.value) })

        if useNight {
            // Per-night groups for large enough subsets — override combined scores
            var nightGroups: [GroupKey: [Int]] = [:]
            for (index, entry) in entries.enumerated() {
                let key = GroupKey(entry: entry, useNight: true)
                nightGroups[key, default: []].append(index)
            }
            for (key, indices) in nightGroups where indices.count >= minGroupSize {
                groupsList.append((key, indices))
            }
        }

        var result: [URL: QualityBreakdown] = [:]

        for (_, indices) in groupsList {
            guard indices.count >= minGroupSize else { continue }

            let groupEntries = indices.map { entries[$0] }

            let rawFilter = groupEntries.first?.filter ?? ""
            let canonical = ColorCombineEngine.canonicalFilterName(rawFilter)
            // Broadband (L/R/G/B): star count is reliable → weight 1.2
            // Everything else (narrowband, dual/tri-band, unknown filters): star count
            // varies with detection threshold → weight 0.5
            let isBroadband = broadbandCanonical.contains(canonical)
                || canonical.isEmpty || canonical.lowercased() == "none"
            let isNarrowband = !isBroadband
            var starWeight: Double = isNarrowband ? 0.5 : 1.2

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

            // SNR contribution: find best SNR in group for relative scoring
            let validSNRs = snrValues.compactMap { $0 }
            let snrBest = validSNRs.max() ?? 0

            // Detect bimodal/unreliable star counts: if coefficient of variation > 1.0,
            // star counts span orders of magnitude — likely galaxy/nebula contamination
            // making the GPU detector threshold-sensitive. Ignore star count for scoring.
            let validStarCounts = starsValues.compactMap { $0 }
            if validStarCounts.count >= 2 {
                let scMean = validStarCounts.reduce(0, +) / Double(validStarCounts.count)
                if scMean > 0 {
                    let scVar = validStarCounts.map { ($0 - scMean) * ($0 - scMean) }.reduce(0, +) / Double(validStarCounts.count)
                    if scVar.squareRoot() / scMean > 1.0 {
                        starWeight = 0  // Star counts unreliable — skip in scoring
                    }
                }
            }

            // Compute group statistics for absolute garbage detection
            let starsMedian = sortedMedian(starsValues)
            let snrMedian = sortedMedian(snrValues)
            let fwhmMedian = sortedMedian(fwhmValues)
            let hfrMedian = sortedMedian(hfrValues)
            // Background level: detect clouds/gradient via anomalous background median
            let bgValues: [Double?] = groupEntries.map { $0.noiseMedian.map { Double($0) } }
            let bgMedian = sortedMedian(bgValues)
            let bgMAD = medianAbsoluteDeviation(bgValues, median: bgMedian)

            // Z-scores for relative scoring
            let fwhmZscores  = zscores(values: fwhmValues)
            let hfrZscores   = zscores(values: hfrValues)
            let starsZscores = zscores(values: starsValues)
            let noiseMadZscores = zscores(values: groupEntries.map { $0.noiseMAD.map { Double($0) } })
            // Use trailing score (consensus-weighted, FL-adaptive) instead of raw eccentricity
            let trailingZscores = zscores(values: groupEntries.map { $0.trailingScore })

            for (localIdx, globalIdx) in indices.enumerated() {
                let entry = entries[globalIdx]

                // Compute SNR² for this frame (cached for live retention bar)
                let snr = snrValues[localIdx]
                let snrSq = snr.map { $0 * $0 }

                // SNR contribution relative to best
                let contribution: Double? = {
                    guard let s = snr, snrBest > 0 else { return nil }
                    return (s / snrBest) * (s / snrBest) * 100.0
                }()

                // ── Stage 1: Absolute garbage detection ──
                // Any single metric catastrophically bad → immediate red
                var garbageReason: GarbageReason? = nil

                // Rule 0: Pitch black / no data — no stars AND no noise stats
                let hasNoStars = starsValues[localIdx] == nil || starsValues[localIdx] == 0
                let hasNoNoise = entry.noiseMAD == nil || entry.noiseMAD == 0
                if hasNoStars && hasNoNoise {
                    garbageReason = .noData
                }

                // Rule 1: No stars or near-zero stars → garbage
                // Skip when star counts are unreliable (bimodal distribution from
                // galaxy/nebula contamination — starWeight == 0).
                // Broadband: < 25% of median, Narrowband: < 15% of median
                if garbageReason == nil, starWeight > 0, let stars = starsValues[localIdx], let median = starsMedian {
                    let dropThreshold = isNarrowband ? garbageDropFactor * 0.3 : garbageDropFactor * 0.5
                    if stars < 1 || (median > 10 && stars < median * dropThreshold) {
                        garbageReason = .noStars
                    }
                }

                // Rule 2: SNR catastrophically low compared to group
                if garbageReason == nil, let snrVal = snrValues[localIdx], let median = snrMedian {
                    if median > 5 && snrVal < median * garbageDropFactor {
                        garbageReason = .lowSNR
                    }
                }

                // Rule 3: FWHM catastrophically high (severe tracking error, defocus)
                if garbageReason == nil, let fwhm = fwhmValues[localIdx], let median = fwhmMedian {
                    if median > 0 && fwhm > median * (1.0 / garbageDropFactor) {
                        garbageReason = .highFWHM
                    }
                }

                // Rule 4: HFR catastrophically high
                if garbageReason == nil, let hfr = hfrValues[localIdx], let median = hfrMedian {
                    if median > 0 && hfr > median * (1.0 / garbageDropFactor) {
                        garbageReason = .highHFR
                    }
                }

                // Rule 5: Star trailing — uses consensus-weighted, focal-length-adaptive score.
                // Cross-check: real trailing always degrades FWHM. If a frame's FWHM is at or
                // below the group median, the stars are sharp and CAN'T be genuinely trailed.
                // This prevents false positives from the PA consensus detector on sharp frames.
                let fwhmRulesOutTrailing: Bool = {
                    guard let fwhm = fwhmValues[localIdx], let median = fwhmMedian else { return false }
                    return fwhm <= median * 1.15  // Within 15% of median = not degraded by trailing
                }()

                if garbageReason == nil, !fwhmRulesOutTrailing,
                   let ts = entry.trailingScore, ts > 0.7 {
                    garbageReason = .elongated
                }
                // Strong consensus variant: require BOTH high trailing AND high consensus AND
                // FWHM above median (confirming the trailing actually degraded star sharpness).
                if garbageReason == nil, !fwhmRulesOutTrailing,
                   let ts = entry.trailingScore, ts > 0.5,
                   let consensus = entry.trailingConsensus, consensus > 0.8 {
                    garbageReason = .elongated
                }

                // Rule 6: Star count anomaly — doubled stars from tracking/dithering jump
                // If star count is >1.8× the group median, stars may be doubled from movement.
                // BUT: satellite/plane trails also inflate star count without affecting star quality.
                // Distinguish: tracking jumps degrade FWHM/HFR (doubled PSFs are wider),
                // while satellite trails leave real star metrics normal. Only flag if FWHM or HFR
                // is also elevated (>1.3× median), confirming the PSFs themselves are degraded.
                if garbageReason == nil, starWeight > 0, let stars = starsValues[localIdx], let median = starsMedian {
                    if median > 20 && stars > median * 1.8 {
                        let fwhmElevated = fwhmValues[localIdx] != nil && fwhmMedian != nil &&
                            fwhmValues[localIdx]! > fwhmMedian! * 1.3
                        let hfrElevated = hfrValues[localIdx] != nil && hfrMedian != nil &&
                            hfrValues[localIdx]! > hfrMedian! * 1.3
                        if fwhmElevated || hfrElevated {
                            garbageReason = .starCountAnomaly
                        }
                        // Otherwise: likely satellite trail — frame is usable (sigma clipping removes trail)
                    }
                }

                // Rule 7: Background anomaly — clouds, light pollution gradient, or fog
                // If background level deviates by >5 MADs from group median, it's anomalous.
                // Clouds raise background level significantly; only flag strong deviations.
                // Scale threshold for small groups: tight MAD in <20 frames causes false positives.
                // 20+ frames → 5.0 MAD, 15 → 5.75, 10 → 6.5 (linear interpolation)
                if garbageReason == nil, let bg = bgValues[localIdx],
                   let median = bgMedian, let mad = bgMAD, mad > 0 {
                    let bgThreshold = max(5.0, 5.0 + (20.0 - Double(min(groupEntries.count, 20))) * 0.15)
                    let deviation = Swift.abs(bg - median) / mad
                    if deviation > bgThreshold {
                        garbageReason = .backgroundAnomaly
                    }
                }

                // Rule 8: Star chain detection — tracking hops create parallel chains of discrete dots.
                // Each dot looks like a real star (round, good FWHM), but the spatial pattern
                // (many parallel short chains scattered across the frame) is unmistakable.
                // Detection runs in StarMetricsCalculator on all refined star positions.
                if garbageReason == nil, let chainFrac = entry.starChainFraction, chainFrac > 0.25 {
                    garbageReason = .trackingHop
                }

                // Cap individual z-scores at ±3 for display consistency.
                // The cap is already applied during combinedZ computation (lines below),
                // but storing raw values caused extreme display values (e.g. noiseZ=10922
                // when group MAD is near-zero). Cap stored values for tooltip sanity.
                func cappedZ(_ z: Double?) -> Double? {
                    guard let z = z else { return nil }
                    return min(zscoreCap, max(-zscoreCap, z))
                }

                if garbageReason != nil {
                    // Don't show SNR contribution for Stage 1 garbage — their signal is
                    // irrelevant since they'd ruin the stack (elongation, no stars, etc.).
                    // Showing "100%" next to a red X is misleading.
                    result[entry.url] = QualityBreakdown(
                        tier: .trash,
                        combinedZScore: -99.0,
                        starsZ: cappedZ(starsZscores[localIdx]),
                        fwhmZ: cappedZ(fwhmZscores[localIdx]),
                        hfrZ: cappedZ(hfrZscores[localIdx]),
                        noiseZ: cappedZ(noiseMadZscores[localIdx]),
                        trailingZ: cappedZ(trailingZscores[localIdx]),
                        snrContribution: nil,
                        snrSquared: snrSq,
                        garbageReason: garbageReason,
                        isLockedKeep: false,
                        reasoningText: garbageReason?.rawValue
                    )
                    continue
                }

                // ── Absolute Quality Floor (calibration-aware) ──
                // If frame meets the learned baseline for ALL metrics, lock as KEEP.
                // Prevents death spiral: z-scores always find "the worst" even in excellent sets.
                let lockedKeep: Bool
                if let db = calibrationDB, let fp = fingerprint, db.meetsAbsoluteFloor(entry: entry, fingerprint: fp) {
                    lockedKeep = true
                } else {
                    lockedKeep = false
                }

                // ── Stage 2: Relative weighted z-score comparison ──
                // Z-scores capped at ±zscoreCap to prevent one metric from dominating
                // in homogeneous groups where MAD is tiny.
                var zSum: Double = 0
                var wSum: Double = 0
                let cap = zscoreCap

                // FWHM and HFR are ~95% correlated (both measure star sharpness).
                // Using both double-penalizes slightly-softer frames.
                // Use FWHM when available; HFR only as fallback.
                if let z = fwhmZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * 1.0     // lower FWHM = better → negate
                    wSum += 1.0
                } else if let z = hfrZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * 1.0     // lower HFR = better → negate
                    wSum += 1.0
                }
                if let z = starsZscores[localIdx] {
                    zSum += min(cap, max(-cap, z)) * starWeight  // higher stars = better → keep sign
                    wSum += starWeight
                }
                if let z = noiseMadZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * 1.0     // lower noise = better → negate
                    wSum += 1.0
                }
                if let z = trailingZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * 1.0     // lower trailing = better → negate
                    wSum += 1.0          // Same weight as other metrics; Stage 1 catches severe trailing
                }

                guard wSum > 0 else { continue }

                let combinedZ = zSum / wSum

                var tier: QualityTier
                if lockedKeep {
                    // Absolute floor: z-scores cannot downgrade below .good
                    if combinedZ > thresholdExcellent {
                        tier = .excellent
                    } else {
                        tier = .good
                    }
                } else if combinedZ > thresholdExcellent {
                    tier = .excellent
                } else if combinedZ > thresholdGood {
                    tier = .good
                } else if combinedZ > thresholdBorderline {
                    tier = .borderline
                } else {
                    tier = .trash
                }

                // ── Stage 3: Pattern-based rescue rules ──
                // Rescue borderline/z-score-trash frames that have compensating qualities.
                // Only promotes, never demotes. Only for Stage 2 classified frames.
                var rescueReason: String? = nil

                if !lockedKeep && (tier == .borderline || tier == .trash) {
                    let fwhmOK = fwhmValues[localIdx] != nil && fwhmMedian != nil
                        && fwhmValues[localIdx]! <= fwhmMedian! * 1.05
                    let noiseOK = noiseMadZscores[localIdx] != nil
                        && noiseMadZscores[localIdx]! <= 0.5
                    let starsLow = starsValues[localIdx] != nil && starsMedian != nil
                        && starsValues[localIdx]! < starsMedian! * 0.75
                    let trailingOK = (entry.trailingScore ?? 0) < 0.3

                    // Rule A: Good FWHM + acceptable noise → frame is fundamentally sound
                    if fwhmOK && noiseOK && trailingOK {
                        tier = .good
                        rescueReason = "FWHM and noise within group norm"
                    }
                    // Rule B: Star dip with good FWHM → transient event (cloud, dew), not bad data
                    else if starsLow && fwhmOK && trailingOK {
                        tier = .good
                        rescueReason = "Star count dip with normal FWHM — likely transient event"
                    }
                    // Rule C: Only FWHM penalty, nothing else wrong → don't trash, keep as borderline
                    else if tier == .trash {
                        let badNoise = (noiseMadZscores[localIdx] ?? 0) > 0.5
                        let badStars = (starsZscores[localIdx] ?? 0) < -0.5
                        let badTrailing = (trailingZscores[localIdx] ?? 0) > 0.5
                        if !badNoise && !badStars && !badTrailing {
                            tier = .borderline
                            rescueReason = "Only FWHM slightly elevated — no other issues"
                        }
                    }
                }

                // ── Generate reasoning text ──
                let reasoning = generateReasoning(
                    fwhmZ: cappedZ(fwhmZscores[localIdx]),
                    starsZ: cappedZ(starsZscores[localIdx]),
                    noiseZ: cappedZ(noiseMadZscores[localIdx]),
                    trailingZ: cappedZ(trailingZscores[localIdx]),
                    tier: tier,
                    isLockedKeep: lockedKeep,
                    rescueReason: rescueReason
                )

                // Hide SNR contribution for trash tier — misleading to show high % on garbage frames
                let displayContrib = tier == .trash ? nil : contribution

                result[entry.url] = QualityBreakdown(
                    tier: tier,
                    combinedZScore: combinedZ,
                    starsZ: cappedZ(starsZscores[localIdx]),
                    fwhmZ: cappedZ(fwhmZscores[localIdx]),
                    hfrZ: cappedZ(hfrZscores[localIdx]),
                    noiseZ: cappedZ(noiseMadZscores[localIdx]),
                    trailingZ: cappedZ(trailingZscores[localIdx]),
                    snrContribution: displayContrib,
                    snrSquared: snrSq,
                    garbageReason: nil,
                    isLockedKeep: lockedKeep,
                    reasoningText: reasoning
                )
            }
        }

        // ── Stage 4: FWHM sanity check for z-score trash ──
        // Z-score trash frames (not Stage 1 garbage) may have FWHM comparable to
        // GOOD frames. This happens when a peak-quality block in the session pulls
        // the median down, making "normal" frames look worse than they are.
        // If a z-score-trash frame's FWHM falls within the range of GOOD frames,
        // its seeing was comparable — rescue to borderline.
        // Dawn/cloud frames are unaffected (they have Stage 1 garbage reasons).
        for (_, indices) in groupsList {
            guard indices.count >= minGroupSize else { continue }

            let groupEntries = indices.map { entries[$0] }
            let allHaveHeaderFWHM = groupEntries.allSatisfy { $0.fwhm != nil }

            // Collect FWHM of GOOD/EXCELLENT frames as reference
            var goodFWHMs: [Double] = []
            var zScoreTrash: [(url: URL, fwhm: Double)] = []
            var borderlineFrames: [(url: URL, fwhm: Double)] = []

            for globalIdx in indices {
                let entry = entries[globalIdx]
                guard let bd = result[entry.url] else { continue }
                let fwhm = allHaveHeaderFWHM ? entry.fwhm : entry.computedFWHM
                guard let fwhmVal = fwhm else { continue }

                switch bd.tier {
                case .excellent, .good:
                    goodFWHMs.append(fwhmVal)
                case .trash where bd.garbageReason == nil:
                    zScoreTrash.append((entry.url, fwhmVal))
                case .borderline:
                    borderlineFrames.append((entry.url, fwhmVal))
                default:
                    break
                }
            }

            guard !goodFWHMs.isEmpty, !zScoreTrash.isEmpty else { continue }

            // Use 90th percentile of GOOD FWHM as the comparison ceiling
            let sorted = goodFWHMs.sorted()
            let goodFWHM90th = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]

            for (url, fwhm) in zScoreTrash {
                guard fwhm <= goodFWHM90th else { continue }
                guard let oldBD = result[url] else { continue }

                result[url] = QualityBreakdown(
                    tier: .borderline,
                    combinedZScore: oldBD.combinedZScore,
                    starsZ: oldBD.starsZ,
                    fwhmZ: oldBD.fwhmZ,
                    hfrZ: oldBD.hfrZ,
                    noiseZ: oldBD.noiseZ,
                    trailingZ: oldBD.trailingZ,
                    snrContribution: oldBD.snrContribution,
                    snrSquared: oldBD.snrSquared,
                    garbageReason: nil,
                    isLockedKeep: oldBD.isLockedKeep,
                    reasoningText: "FWHM comparable to good frames — penalized by session peak quality, not actual degradation"
                )
            }
        }

        return result
    }

    // MARK: - Private helpers

    /// Compute z-scores for an array of optional Doubles.
    /// Uses median/MAD instead of mean/stddev for robustness against outliers.
    /// One exceptional frame (superb seeing) won't skew the group statistics and
    /// cause merely-good frames to appear bad.
    /// The 1.4826 factor normalizes MAD to be equivalent to standard deviation
    /// for normal distributions, so existing z-score thresholds remain valid.
    /// Falls back to mean/stddev when MAD=0 (>50% of values identical — rare in
    /// real data but common in synthetic test groups).
    private static func zscores(values: [Double?]) -> [Double?] {
        let present = values.compactMap { $0 }.sorted()
        guard present.count >= 2 else {
            return Array(repeating: nil, count: values.count)
        }

        let median = present[present.count / 2]
        let deviations = present.map { Swift.abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2] * 1.4826  // normalized MAD → σ estimate

        if mad > 0 {
            return values.map { val -> Double? in
                guard let v = val else { return nil }
                return (v - median) / mad
            }
        }

        // MAD = 0: majority of values identical. Fall back to mean/stddev which
        // handles this case correctly (the few different values become clear outliers).
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

    /// Compute MAD (median absolute deviation) from a median
    private static func medianAbsoluteDeviation(_ values: [Double?], median: Double?) -> Double? {
        guard let med = median else { return nil }
        let deviations = values.compactMap { $0 }.map { Swift.abs($0 - med) }.sorted()
        guard !deviations.isEmpty else { return nil }
        return deviations[deviations.count / 2]
    }

    /// Generate human-readable reasoning for why a frame got its tier.
    /// Called during scoring with full group context available.
    private static func generateReasoning(
        fwhmZ: Double?, starsZ: Double?, noiseZ: Double?, trailingZ: Double?,
        tier: QualityTier,
        isLockedKeep: Bool,
        rescueReason: String?
    ) -> String {
        if isLockedKeep {
            return "Within calibrated baseline — all metrics match learned profile"
        }

        var parts: [String] = []

        // Rescue reason takes priority — explains the Stage 3 override
        if let rescue = rescueReason {
            parts.append(rescue)
        }

        // For FWHM/noise/trailing: raw z > 0 means WORSE (higher value = worse)
        // For stars: raw z < 0 means WORSE (fewer stars = worse)
        let fwhmPenalty: Double = fwhmZ ?? 0
        let noisePenalty: Double = noiseZ ?? 0
        let starsPenalty: Double = -(starsZ ?? 0)
        let trailingPenalty: Double = trailingZ ?? 0

        var penalties: [(String, Double)] = []
        if fwhmPenalty > 0.5     { penalties.append(("FWHM", fwhmPenalty)) }
        if noisePenalty > 0.5    { penalties.append(("Noise", noisePenalty)) }
        if starsPenalty > 0.5    { penalties.append(("Stars", starsPenalty)) }
        if trailingPenalty > 0.5 { penalties.append(("Trailing", trailingPenalty)) }

        let sorted = penalties.sorted { $0.1 > $1.1 }

        if tier == .excellent || tier == .good {
            if sorted.isEmpty && rescueReason == nil {
                parts.append("All metrics within normal range")
            } else if rescueReason == nil {
                // Good tier but with a notable penalty — explain what was compensated
                if let worst = sorted.first {
                    parts.append("\(worst.0) slightly below average, compensated by other metrics")
                }
            }
        } else {
            // Borderline or trash: explain what is dragging it down
            if let worst = sorted.first {
                switch worst.0 {
                case "FWHM":
                    if worst.1 > 2.0 {
                        parts.append("FWHM worst in group")
                    } else if worst.1 > 1.0 {
                        parts.append("FWHM below average")
                    } else {
                        parts.append("FWHM slightly elevated")
                    }
                case "Noise":
                    parts.append("Elevated noise (background brightening)")
                case "Stars":
                    if let fz = fwhmZ, fz <= 0.5 {
                        parts.append("Fewer stars but FWHM OK — possible transient")
                    } else {
                        parts.append("Fewer stars detected")
                    }
                case "Trailing":
                    parts.append("Star elongation detected")
                default: break
                }

                // Secondary penalty
                for penalty in sorted.dropFirst().prefix(1) {
                    parts.append("\(penalty.0.lowercased()) also below average")
                }
            }
        }

        return parts.isEmpty ? "" : parts.joined(separator: " — ")
    }
}

// MARK: - Group key

struct GroupKey: Hashable {
    let filter:   String
    let object:   String
    let exposure: Int
    let night:    String?   // observingNight for multi-night sessions, nil for single-night

    init(entry: ImageEntry, useNight: Bool = false) {
        filter   = (entry.filter   ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        object   = (entry.target   ?? "").trimmingCharacters(in: .whitespaces)
        exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
        night    = useNight ? entry.observingNight : nil
    }
}
