// v4.3.0
import Foundation

// Five-tier quality system with sub-tiers for borderline:
// Stage 1 ("garbage"): absolute outlier → red (any single metric catastrophically bad)
// Stage 1.5 ("session sanity"): cross-group comparison → demote if far below session norm
// Stage 2 ("relative"): weighted z-score within group → excellent/good/borderline/poor
enum QualityTier: Int {
    case trash      = 0   // Red X: catastrophic garbage (Stage 1) or statistically worst
    case borderline = 1   // Orange: on the edge — worth visual inspection before keeping
    case good       = 2   // Half-green: slightly below the best but definitely usable
    case excellent  = 3   // Full green: clearly above average — best frames
    case uncertain  = 4   // Blue ?: small group, low confidence — visual inspection recommended
}

// Stage 1 garbage reason — explains WHY a frame was immediately flagged as trash
enum GarbageReason: String, Hashable {
    case noData            = "no signal detected"
    case noStars           = "zero/near-zero stars"
    case decenteredTarget  = "target shifted off sensor (mount recenter)"
    case lowSNR            = "SNR catastrophically low"
    case highFWHM          = "severe defocus/tracking"
    case highHFR           = "severe defocus"
    case elongated         = "star trailing/elongation"
    case starCountAnomaly  = "doubled stars (tracking jump)"
    case backgroundAnomaly = "abnormal background (clouds/gradient)"
    case trackingHop       = "tracking hops (star chains)"
    case starCountDrop     = "atmospheric attenuation (cloud/dew/fog)"
    case twilightExposure  = "captured during twilight/daylight"
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

    // All Stage 1 garbage reasons detected (empty if not garbage)
    let garbageReasons: [GarbageReason]

    // Primary garbage reason (first detected) — backward compatibility
    var garbageReason: GarbageReason? { garbageReasons.first }

    // Absolute quality floor: frame meets calibration baseline for ALL metrics.
    // When true, z-scores cannot override — this frame is locked as KEEP.
    // Only set when the setup has ≥30 learned frames.
    let isLockedKeep: Bool

    // Community floor: frame meets community baseline for similar setups.
    // Only set when local calibration has < 30 frames and community data exists.
    // Displayed as gray lock badge (distinct from blue local calibration lock).
    var isCommunityFloorLocked: Bool = false

    // Human-readable explanation of why this frame received its tier.
    // Generated during scoring when group context is available.
    let reasoningText: String?

    // Filter-aware trailing penalty multiplier applied during scoring.
    // 0.3 = narrowband (Ha/OIII/SII), 0.6 = RGB, 1.0 = luminance, 0.7 = unknown
    var filterTrailingMultiplier: Double = 1.0

    // Session-wide sanity check reasons (Stage 1.5) — explains why a frame was demoted
    // across groups. Empty if frame passed session sanity or check didn't apply.
    var sessionSanityReasons: [String] = []

    // Historical comparison (Phase 2) — how this frame compares to ALL previous sessions.
    // nil if no historical data available for this setup+filter+exposure combination.
    var historicalZScore: Double?       // Combined z-score against historical baselines
    var historicalPercentile: Double?   // 0-100, where in historical distribution this frame falls

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

        // Community floor lock — weaker than local, used during cold start
        if isCommunityFloorLocked {
            return "KEEP — within community baseline"
        }

        if !sessionSanityReasons.isEmpty && (tier == .trash || tier == .borderline) {
            return "REVIEW — \(sessionSanityReasons.joined(separator: ", "))"
        }

        if !garbageReasons.isEmpty {
            let reasons = garbageReasons.map { $0.rawValue }.joined(separator: ", ")
            return "DELETE — \(reasons)"
        }

        // Z-score based trash (no garbage reasons but combined z-score below threshold)
        if tier == .trash {
            return "DELETE — below quality threshold"
        }

        if tier == .uncertain {
            return "UNCERTAIN — small group, inspect visually"
        }

        guard tier == .borderline else { return "" }

        // Check eccentricity first — the critical differentiator
        // Filter-aware: narrowband (0.3) needs much higher z to trigger review
        let hasHighEcc = (trailingZ ?? 0) > (1.5 / max(filterTrailingMultiplier, 0.1))
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
        guard tier == .borderline || tier == .uncertain else { return 0 }
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

    // Filter categories for trailing penalty scaling.
    // Narrowband: slight trailing barely affects diffuse emission — very lenient.
    // RGB: star color matters, moderate resolution needs.
    // Luminance: the sharpness channel — full strictness.
    private static let narrowbandCanonical: Set<String> = ["Ha", "OIII", "SII", "Hbeta", "NII"]
    private static let rgbCanonical: Set<String> = ["R", "G", "B"]

    /// Filter-aware trailing penalty multiplier (base value).
    /// Returns 0.3 for narrowband, 0.6 for RGB, 1.0 for luminance, 0.7 for unknown/exotic.
    static func filterTrailingMultiplier(for canonical: String) -> Double {
        if narrowbandCanonical.contains(canonical) { return 0.3 }
        if rgbCanonical.contains(canonical)        { return 0.6 }
        if canonical == "L"                         { return 1.0 }
        return 0.7  // Unknown or exotic filters — conservative default
    }

    // Severity-dependent trailing multiplier thresholds (named constants for tuning)
    private static let severityExponent: Double = 2.0
    private static let absoluteTrailingCeilingScore: Double = 0.50
    private static let absoluteTrailingCeilingConsensus: Double = 0.5

    /// Severity-dependent trailing multiplier: escalates from baseMult toward 1.0
    /// as trailing severity increases. Preserves narrowband benefit for mild trailing
    /// while ensuring severe trailing is properly penalized regardless of filter.
    ///
    /// Formula: baseMult + (1.0 - baseMult) * trailingScore^severityExponent
    ///
    /// For narrowband (baseMult = 0.3):
    ///   trailingScore 0.0 → 0.30, 0.3 → 0.36, 0.5 → 0.48, 0.7 → 0.64, 1.0 → 1.00
    static func effectiveTrailingMultiplier(baseMult: Double, trailingScore: Double) -> Double {
        let severity = min(1.0, max(0.0, trailingScore))
        return baseMult + (1.0 - baseMult) * pow(severity, severityExponent)
    }

    // MARK: - Public API

    /// Compute quality scores with optional calibration data for absolute quality floor.
    /// When calibrationDB and fingerprint are provided, frames that meet the learned baseline
    /// for ALL metrics are locked as KEEP — z-scores cannot override them.
    static func computeScores(
        for entries: [ImageEntry],
        calibrationDB: CalibrationDatabase? = nil,
        fingerprint: SetupFingerprint? = nil,
        communityBaseline: CommunityBaseline? = nil,
        historicalBaselines: HistoricalBaselines? = nil
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
            let trailMult = filterTrailingMultiplier(for: canonical)

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

            // Plate-solved center coordinates for pointing offset detection
            // Compute group median RA/Dec and FOV (degrees) for decentered-target check
            let solvedRAs: [Double] = groupEntries.compactMap { $0.solvedRA }
            let solvedDecs: [Double] = groupEntries.compactMap { $0.solvedDec }
            let medianSolvedRA: Double? = solvedRAs.count >= 3 ? solvedRAs.sorted()[solvedRAs.count / 2] : nil
            let medianSolvedDec: Double? = solvedDecs.count >= 3 ? solvedDecs.sorted()[solvedDecs.count / 2] : nil
            // FOV in degrees: use first entry with pixel size + focal length + image dimensions
            let fovDeg: Double? = {
                guard let first = groupEntries.first(where: { $0.focalLength != nil && $0.pixelSizeMicrons != nil && $0.width != nil }),
                      let fl = first.focalLength, fl > 0,
                      let px = first.pixelSizeMicrons, px > 0,
                      let w = first.width, let h = first.height else { return nil }
                let sensorWidthMM = Double(max(w, h)) * px / 1000.0
                return (sensorWidthMM / fl) * (180.0 / .pi)  // radians → degrees
            }()

            // Z-scores for relative scoring
            let fwhmZscores  = zscores(values: fwhmValues)
            let hfrZscores   = zscores(values: hfrValues)
            let starsZscores = zscores(values: starsValues)
            let noiseMadZscores = zscores(values: groupEntries.map { $0.noiseMAD.map { Double($0) } })
            // Use trailing score (consensus-weighted, FL-adaptive) instead of raw eccentricity
            let trailingZscores = zscores(values: groupEntries.map { $0.trailingScore })

            for (localIdx, globalIdx) in indices.enumerated() {
                let entry = entries[globalIdx]

                // Skip frames that haven't been cached/measured yet — noiseMAD is populated
                // during pre-caching and is the definitive signal that the image was analyzed.
                // Without this guard, frames show misleading quality icons before analysis.
                if entry.noiseMAD == nil && entry.computedStarCount == nil {
                    continue
                }

                // Per-frame severity-dependent trailing multiplier: escalates from baseMult
                // toward 1.0 as trailing worsens. Mild narrowband trailing stays ~0.3,
                // severe trailing approaches luminance penalty (1.0).
                let frameTrailingScore = entry.trailingScore ?? 0.0
                let effectiveTrailMult = Self.effectiveTrailingMultiplier(baseMult: trailMult, trailingScore: frameTrailingScore)

                // Compute SNR² for this frame (cached for live retention bar)
                let snr = snrValues[localIdx]
                let snrSq = snr.map { $0 * $0 }

                // SNR contribution relative to best
                let contribution: Double? = {
                    guard let s = snr, snrBest > 0 else { return nil }
                    return (s / snrBest) * (s / snrBest) * 100.0
                }()

                // ── Stage 1: Absolute garbage detection ──
                // Collect ALL matching reasons — multiple issues shown to user
                var garbageReasons: [GarbageReason] = []

                // Rule 0: Pitch black / no data — no stars AND no noise stats.
                let hasBeenMeasured = entry.noiseMAD != nil
                let hasNoStars = starsValues[localIdx] == nil || starsValues[localIdx] == 0
                let hasNoNoise = (entry.noiseMAD ?? 0) == 0
                if hasBeenMeasured && hasNoStars && hasNoNoise {
                    garbageReasons.append(.noData)
                }

                // Rule 1: No stars or near-zero stars → garbage
                if starWeight > 0, let stars = starsValues[localIdx], let median = starsMedian {
                    let dropThreshold = isNarrowband ? garbageDropFactor * 0.3 : garbageDropFactor * 0.5
                    if stars < 1 || (median > 10 && stars < median * dropThreshold) {
                        garbageReasons.append(.noStars)
                    }
                }

                // Rule 1b: Decentered target — plate-solved center offset > 30% of FOV.
                // Runs independently of star count: a frame can be both "low stars" AND "decentered".
                if let ra = entry.solvedRA, let dec = entry.solvedDec,
                   let medRA = medianSolvedRA, let medDec = medianSolvedDec,
                   let fov = fovDeg, fov > 0 {
                    let dRA = (ra - medRA) * cos(medDec * .pi / 180.0)
                    let dDec = dec - medDec
                    let separation = (dRA * dRA + dDec * dDec).squareRoot()
                    if separation > fov * 0.3 {
                        garbageReasons.append(.decenteredTarget)
                    }
                }

                // Rule 2: SNR catastrophically low compared to group
                if let snrVal = snrValues[localIdx], let median = snrMedian {
                    if median > 5 && snrVal < median * garbageDropFactor {
                        garbageReasons.append(.lowSNR)
                    }
                }

                // Rule 3: FWHM catastrophically high (severe tracking error, defocus)
                if let fwhm = fwhmValues[localIdx], let median = fwhmMedian {
                    if median > 0 && fwhm > median * (1.0 / garbageDropFactor) {
                        garbageReasons.append(.highFWHM)
                    }
                }

                // Rule 4: HFR catastrophically high
                if let hfr = hfrValues[localIdx], let median = hfrMedian {
                    if median > 0 && hfr > median * (1.0 / garbageDropFactor) {
                        garbageReasons.append(.highHFR)
                    }
                }

                // FWHM cross-check: sharp frames (FWHM ≤ median×1.15) rule out trailing.
                // Moved before Rules 5/6/6a so all trailing rules can use it.
                let fwhmRulesOutTrailing: Bool = {
                    guard let fwhm = fwhmValues[localIdx], let median = fwhmMedian else { return false }
                    return fwhm <= median * 1.15
                }()

                // Trailing outlier guard: trailing garbage rules (5, 6, 6a) require the frame
                // to be a trailing OUTLIER within its group (trailingZ > 1.0σ). If the frame's
                // trailing is at the group average (z ≈ 0), it's the telescope's optical
                // characteristic, not a tracking defect. This prevents mass false positives on
                // long FL telescopes (RC12 at 1964mm, baseline 0.25) where even normal frames
                // have high absolute eccentricity. If trailing z is nil (not computed), default
                // to permissive (allow the rule to fire) since we have no group context.
                let isTrailingOutlier = (trailingZscores[localIdx] ?? 99) > 1.0

                // Rule 6a: Absolute trailing ceiling — severe trailing is garbage regardless
                // of filter. Catches cases where the flat narrowband multiplier made Rules 5/6
                // thresholds unreachable.
                //
                // NOTE: fwhmRulesOutTrailing is intentionally NOT checked here.
                // Tracking error produces normal FWHM (good seeing) + high eccentricity
                // (mount drift). The consensus requirement already guards against optical
                // aberrations (which produce random PA, not consensus).
                if isTrailingOutlier, !garbageReasons.contains(.elongated),
                   let ts = entry.trailingScore, ts > absoluteTrailingCeilingScore,
                   let consensus = entry.trailingConsensus, consensus > absoluteTrailingCeilingConsensus {
                    garbageReasons.append(.elongated)
                }

                // Rule 5: Extreme eccentricity — raw ecc far above FL baseline.
                // Fully FL-adaptive via baseline = 0.8 / sqrt(FL / 200).
                // Severity-dependent: effectiveTrailMult escalates for worse trailing.
                // Outlier guard: only fires on trailing outliers within the group.
                if isTrailingOutlier, let ecc = entry.computedEccentricity {
                    let fl = entry.focalLength ?? 0
                    let baseline = fl > 0
                        ? min(0.70, max(0.15, 0.8 / (fl / 200.0).squareRoot()))
                        : 0.40
                    let excessRatio = (ecc - baseline) / max(baseline, 0.01)
                    if excessRatio > (1.0 / effectiveTrailMult) && !garbageReasons.contains(.elongated) {
                        garbageReasons.append(.elongated)
                    }
                }

                // Rule 6: Star trailing — consensus-weighted, FL-adaptive score.
                // Cross-check: fwhmRulesOutTrailing prevents false positives on sharp frames.
                // Outlier guard: only fires on trailing outliers within the group.
                if isTrailingOutlier, !fwhmRulesOutTrailing, !garbageReasons.contains(.elongated) {
                    if let ts = entry.trailingScore, ts > (0.7 / effectiveTrailMult) {
                        garbageReasons.append(.elongated)
                    } else if let ts = entry.trailingScore, ts > (0.5 / effectiveTrailMult),
                              let consensus = entry.trailingConsensus, consensus > 0.8 {
                        garbageReasons.append(.elongated)
                    }
                }

                // Rule 7: Star count anomaly — doubled stars from tracking/dithering jump
                if starWeight > 0, let stars = starsValues[localIdx], let median = starsMedian {
                    if median > 20 && stars > median * 1.8 {
                        let fwhmElevated = fwhmValues[localIdx] != nil && fwhmMedian != nil &&
                            fwhmValues[localIdx]! > fwhmMedian! * 1.3
                        let hfrElevated = hfrValues[localIdx] != nil && hfrMedian != nil &&
                            hfrValues[localIdx]! > hfrMedian! * 1.3
                        if fwhmElevated || hfrElevated {
                            garbageReasons.append(.starCountAnomaly)
                        }
                    }
                }

                // Rule 7b: Star count drop — atmospheric attenuation (thin cloud, dew, fog).
                // If star count drops >35% below median AND SNR also drops >35%,
                // the frame has atmospheric issues regardless of FWHM.
                // Cross-check: FWHM must be normal (< median×1.3) to confirm it's NOT defocus.
                // Requires ≥8 frames for reliable median.
                if starWeight > 0, let stars = starsValues[localIdx], let median = starsMedian,
                   indices.count >= 8, median > 20 {
                    let starRatio = stars / median
                    if starRatio < 0.65 {
                        let fwhmOK = fwhmValues[localIdx] == nil || fwhmMedian == nil
                            || fwhmValues[localIdx]! < fwhmMedian! * 1.3
                        // SNR cross-check: confirms signal attenuation (not just different star detection).
                        // Requires actual SNR value (nil = no data, don't assume low).
                        let snr = snrValues[localIdx]
                        let snrMed = snrMedian ?? 0
                        let snrLow = snr != nil && snrMed > 0 && snr! < snrMed * 0.65
                        if fwhmOK && snrLow {
                            garbageReasons.append(.starCountDrop)
                        }
                    }
                }

                // Rule 8: Background anomaly — clouds, light pollution gradient, or fog
                // Moon-aware: bright moon near target raises legitimate background for broadband.
                // Narrowband is mostly immune to moonlight — don't relax threshold.
                if let bg = bgValues[localIdx],
                   let median = bgMedian, let mad = bgMAD, mad > 0 {
                    var bgThreshold = max(5.0, 5.0 + (20.0 - Double(min(groupEntries.count, 20))) * 0.15)

                    // Relax threshold when bright moon is close and filter is broadband
                    if let moonIll = entry.moonIllumination, moonIll > 0.4,
                       let moonDist = entry.moonDistance, moonDist < 60,
                       broadbandCanonical.contains(ColorCombineEngine.canonicalFilterName(entry.filter ?? "")) {
                        // Closer moon + brighter = more background expected
                        // Scale: 50% moon at 60° = +20%, full moon at 10° = +100%
                        let moonFactor = moonIll * (1.0 - moonDist / 90.0)
                        bgThreshold *= (1.0 + moonFactor)
                    }

                    let deviation = (bg - median) / mad
                    if deviation > bgThreshold {
                        garbageReasons.append(.backgroundAnomaly)
                    }
                }

                // Rule 9: Star chain detection — tracking hops
                if let chainFrac = entry.starChainFraction, chainFrac > 0.25 {
                    garbageReasons.append(.trackingHop)
                }

                // Rule 10: Twilight/daylight exposure — filter-aware thresholds.
                // Narrowband filters (3-7nm bandpass) reject most broadband sky glow,
                // so they tolerate twilight much better than RGB/L.
                // Thresholds:
                //   Narrowband (Ha/OIII/SII): garbage at civil twilight and daylight (sun > -6°)
                //   RGB/Broadband:            garbage at nautical twilight and above (sun > -12°)
                //   Astronomical twilight (-18° to -12°): safe for all filters
                if let phase = entry.twilightPhase {
                    let twilightGarbagePhase: TwilightPhase = isNarrowband ? .civil : .nautical
                    if phase >= twilightGarbagePhase {
                        garbageReasons.append(.twilightExposure)
                    }
                }

                // Cap individual z-scores at ±3 for display consistency.
                // The cap is already applied during combinedZ computation (lines below),
                // but storing raw values caused extreme display values (e.g. noiseZ=10922
                // when group MAD is near-zero). Cap stored values for tooltip sanity.
                func cappedZ(_ z: Double?) -> Double? {
                    guard let z = z else { return nil }
                    return min(zscoreCap, max(-zscoreCap, z))
                }

                if !garbageReasons.isEmpty {
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
                        garbageReasons: garbageReasons,
                        isLockedKeep: false,
                        reasoningText: nil,  // Garbage reasons already shown via garbageReasons
                        filterTrailingMultiplier: effectiveTrailMult
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
                    zSum += -min(cap, max(-cap, z)) * effectiveTrailMult  // lower trailing = better → negate
                    wSum += effectiveTrailMult    // Severity-dependent: escalates from baseMult toward 1.0
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
                    let trailingOK = (entry.trailingScore ?? 0) < (0.3 / effectiveTrailMult)

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
                    rescueReason: rescueReason,
                    filterTrailingMultiplier: effectiveTrailMult,
                    baseFilterMultiplier: trailMult
                )

                // Hide SNR contribution for trash tier — misleading to show high % on garbage frames
                let displayContrib = tier == .trash ? nil : contribution

                // ── Community Floor (cold-start) ──
                // When local calibration has < 30 frames, check community baseline.
                // Only promotes to .good minimum (same as local floor) — never overrides local.
                var communityLocked = false
                if !lockedKeep && (tier == .borderline || tier == .trash) {
                    if let cb = communityBaseline, let db = calibrationDB, let fp = fingerprint,
                       !db.profile(for: fp).hasLearned {
                        if CommunityDetectionService.meetsCommunityFloor(entry: entry, baseline: cb) {
                            tier = .good
                            communityLocked = true
                        }
                    }
                }

                // ── Uncertain tier for small groups ──
                // When group has < 8 frames and z-score is ambiguous (not clearly good or bad),
                // mark as uncertain instead of potentially misleading good/borderline.
                // Does not apply to locked, garbage, trash, or excellent frames.
                if !lockedKeep && !communityLocked && garbageReasons.isEmpty
                    && indices.count < 8
                    && (tier == .good || tier == .borderline)
                    && combinedZ > -1.0 && combinedZ < thresholdExcellent {
                    tier = .uncertain
                }

                var breakdown = QualityBreakdown(
                    tier: tier,
                    combinedZScore: combinedZ,
                    starsZ: cappedZ(starsZscores[localIdx]),
                    fwhmZ: cappedZ(fwhmZscores[localIdx]),
                    hfrZ: cappedZ(hfrZscores[localIdx]),
                    noiseZ: cappedZ(noiseMadZscores[localIdx]),
                    trailingZ: cappedZ(trailingZscores[localIdx]),
                    snrContribution: displayContrib,
                    snrSquared: snrSq,
                    garbageReasons: [],
                    isLockedKeep: lockedKeep,
                    reasoningText: reasoning,
                    filterTrailingMultiplier: effectiveTrailMult
                )
                breakdown.isCommunityFloorLocked = communityLocked
                result[entry.url] = breakdown
            }
        }

        // ── Stage 1.5: Session-wide sanity check ──
        // Cross-group comparison: demote frames that are dramatically worse than the
        // session norm. Catches uniformly-bad groups where z-scores normalize away.
        // Groups by object+exposure (ignoring filter and night) to create session pools.
        // Only demotes — never promotes. isLockedKeep/community frames are immune.
        sessionSanityCheck(entries: entries, result: &result)

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
                case .trash where bd.garbageReasons.isEmpty:
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
                    garbageReasons: [],
                    isLockedKeep: oldBD.isLockedKeep,
                    reasoningText: "FWHM comparable to good frames — penalized by session peak quality, not actual degradation",
                    filterTrailingMultiplier: oldBD.filterTrailingMultiplier
                )
            }
        }

        // ── Historical Comparison (Phase 2) ──
        // Annotate each breakdown with historical z-score if baselines available.
        // Does NOT change tier assignment — purely informational for charts and AIsaac.
        if let hist = historicalBaselines {
            annotateHistorical(entries: entries, result: &result, baselines: hist)
        }

        return result
    }

    // MARK: - Historical Annotation

    /// Compute historical z-scores by comparing each frame's metrics against
    /// the accumulated baseline from all previous sessions with the same setup.
    private static func annotateHistorical(
        entries: [ImageEntry],
        result: inout [URL: QualityBreakdown],
        baselines: HistoricalBaselines
    ) {
        for entry in entries {
            guard var bd = result[entry.url] else { continue }
            let filter = (entry.filter ?? "").uppercased()
            let exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
            let key = "\(filter)|\(exposure)"
            guard let baseline = baselines.baselines[key], baseline.frameCount >= 10 else { continue }

            // Compute per-metric z-scores against historical baselines
            var zScores: [Double] = []

            if let fwhm = entry.computedFWHM, baseline.fwhmMAD > 0 {
                zScores.append((fwhm - baseline.fwhmMedian) / baseline.fwhmMAD)
            }
            if let stars = entry.computedStarCount, baseline.starCountMAD > 0 {
                // Stars: higher = better, so negate
                zScores.append(-(Double(stars) - baseline.starCountMedian) / baseline.starCountMAD)
            }
            if let noise = entry.noiseMAD, baseline.noiseMAD > 0 {
                zScores.append((Double(noise) - baseline.noiseMedian) / baseline.noiseMAD)
            }
            if let trailing = entry.trailingScore, baseline.trailingMAD > 0 {
                zScores.append((trailing - baseline.trailingMedian) / baseline.trailingMAD)
            }

            guard !zScores.isEmpty else { continue }

            // Combined historical z-score (simple mean — all metrics weighted equally)
            let historicalZ = zScores.reduce(0, +) / Double(zScores.count)
            bd.historicalZScore = historicalZ

            // Percentile: approximate using normal CDF
            // Higher z = worse, so percentile = 100 × P(Z > z) = 100 × (1 - Phi(z))
            bd.historicalPercentile = 100.0 * (1.0 - normalCDF(historicalZ))

            result[entry.url] = bd
        }
    }

    /// Standard normal CDF approximation (Abramowitz & Stegun, max error 1.5e-7).
    private static func normalCDF(_ x: Double) -> Double {
        let a1 =  0.254829592
        let a2 = -0.284496736
        let a3 =  1.421413741
        let a4 = -1.453152027
        let a5 =  1.061405429
        let p  =  0.3275911
        let sign = x < 0 ? -1.0 : 1.0
        let absX = Swift.abs(x)
        let t = 1.0 / (1.0 + p * absX)
        let y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-absX * absX / 2.0)
        return 0.5 * (1.0 + sign * y)
    }

    // MARK: - Session-Wide Sanity Check (Stage 1.5)

    /// Cross-group comparison: demote frames that are dramatically worse than the
    /// session norm across ALL groups with the same object and exposure.
    /// Only demotes — never promotes. isLockedKeep and community-locked frames are immune.
    private static func sessionSanityCheck(
        entries: [ImageEntry],
        result: inout [URL: QualityBreakdown]
    ) {
        // Build session pools: group by object+exposure (ignoring filter and night)
        struct PoolKey: Hashable {
            let target: String
            let exposure: Int
        }
        var pools: [PoolKey: [Int]] = [:]
        for (i, entry) in entries.enumerated() {
            let key = PoolKey(
                target: (entry.target ?? "").trimmingCharacters(in: .whitespaces),
                exposure: entry.exposure.map { Int($0.rounded()) } ?? 0
            )
            pools[key, default: []].append(i)
        }

        // Session sanity only makes sense when there are multiple groups in a pool.
        // Single-group sessions are already handled by within-group z-scoring.
        // Count distinct filter+night combos per pool to detect multi-group sessions.
        for (poolKey, indices) in pools {
            // Need at least 6 frames in the session pool for meaningful comparison
            guard indices.count >= minGroupSize else { continue }

            // Only run cross-group sanity when pool contains multiple filter/night groups
            let distinctGroups = Set(indices.map { i -> String in
                let e = entries[i]
                let f = (e.filter ?? "").uppercased()
                let n = e.observingNight ?? ""
                return "\(f)|\(n)"
            })
            guard distinctGroups.count >= 2 else { continue }

            // Collect metrics from ALL frames in the pool (across all filters/nights)
            var fwhms: [Double] = []
            var snrs: [Double] = []
            var stars: [Double] = []
            var eccs: [Double] = []

            for i in indices {
                let e = entries[i]
                if let v = e.computedFWHM ?? e.fwhm { fwhms.append(v) }
                if let med = e.noiseMedian, let mad = e.noiseMAD, mad > 0 {
                    snrs.append(Double(med / mad))
                }
                if let v = e.computedStarCount { stars.append(Double(v)) }
                if let v = e.computedEccentricity { eccs.append(v) }
            }

            // Need enough data points for reliable medians
            guard fwhms.count >= 6 else { continue }

            fwhms.sort(); snrs.sort(); stars.sort(); eccs.sort()
            // Use best-decile benchmarks instead of median to resist contamination
            // from uniformly-bad nights. The best 10% defines what "good" looks like.
            // FWHM/Ecc: lower is better → use 10th percentile (P10)
            // SNR/Stars: higher is better → use 90th percentile (P90)
            let fwhmP10 = fwhms[max(0, fwhms.count / 10)]                         // Best 10% FWHM
            let snrP90 = snrs.isEmpty ? 0 : snrs[min(snrs.count - 1, snrs.count * 9 / 10)]  // Best 10% SNR
            let starsP90 = stars.isEmpty ? 0 : stars[min(stars.count - 1, stars.count * 9 / 10)]
            let eccP10 = eccs.isEmpty ? 0 : eccs[max(0, eccs.count / 10)]         // Best 10% Ecc

            // Check each frame against session-wide best-decile benchmarks
            // Tighter than median: P10 for FWHM/Ecc (lower=better), P90 for SNR/Stars (higher=better)
            for i in indices {
                let entry = entries[i]
                guard let bd = result[entry.url] else { continue }

                // Never touch locked frames
                if bd.isLockedKeep || bd.isCommunityFloorLocked { continue }
                // Don't re-demote Stage 1 garbage (already trash with reasons)
                if !bd.garbageReasons.isEmpty { continue }

                var flags: [String] = []

                // FWHM: frame > 1.3× the session's best-decile → significantly worse seeing
                if let fwhm = entry.computedFWHM ?? entry.fwhm, fwhmP10 > 0 {
                    if fwhm > fwhmP10 * 1.3 { flags.append("FWHM far above session norm") }
                }
                // SNR: frame < 0.4× the session's best-decile → dramatically lower signal
                if let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0, snrP90 > 3 {
                    let snr = Double(med / mad)
                    if snr < snrP90 * 0.4 { flags.append("SNR far below session norm") }
                }
                if let sc = entry.computedStarCount, starsP90 > 50 {
                    if Double(sc) < starsP90 * 0.4 { flags.append("star count far below session norm") }
                }
                if let ecc = entry.computedEccentricity, eccP10 > 0.1 {
                    if ecc > eccP10 * 1.5 { flags.append("eccentricity far above session norm") }
                }

                // Severe single-metric outlier: FWHM so far above session P10 that
                // it's unambiguous garbage even without a second flag.
                // This catches L-filter frames where SNR is acceptable (L captures
                // more photons than RGB) but seeing is catastrophically worse.
                var isSevereOutlier = false
                if let fwhm = entry.computedFWHM ?? entry.fwhm, fwhmP10 > 0 {
                    if fwhm > fwhmP10 * 1.4 { isSevereOutlier = true }
                }

                guard flags.count >= 2 || (flags.count >= 1 && isSevereOutlier) else { continue }

                // 2+ session sanity flags = unambiguous garbage.
                // Also: a single extreme outlier (>1.6× P10) is trash by itself.
                let newTier: QualityTier = .trash

                // Only demote (never promote)
                let currentTierValue: Int
                switch bd.tier {
                case .trash: currentTierValue = 0
                case .borderline: currentTierValue = 1
                case .uncertain: currentTierValue = 1  // treat like borderline
                case .good: currentTierValue = 2
                case .excellent: currentTierValue = 3
                }
                let newTierValue = newTier == .trash ? 0 : 1
                guard newTierValue < currentTierValue else { continue }

                var demoted = QualityBreakdown(
                    tier: newTier,
                    combinedZScore: bd.combinedZScore,
                    starsZ: bd.starsZ, fwhmZ: bd.fwhmZ, hfrZ: bd.hfrZ,
                    noiseZ: bd.noiseZ, trailingZ: bd.trailingZ,
                    snrContribution: newTier == .trash ? nil : bd.snrContribution,
                    snrSquared: bd.snrSquared,
                    garbageReasons: [],
                    isLockedKeep: false,
                    reasoningText: "Session sanity: \(flags.joined(separator: ", "))",
                    filterTrailingMultiplier: bd.filterTrailingMultiplier
                )
                demoted.sessionSanityReasons = flags
                result[entry.url] = demoted
            }
        }
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
    /// - filterTrailingMultiplier: severity-adjusted effective multiplier (for threshold logic)
    /// - baseFilterMultiplier: raw filter multiplier (for label text — Ha always shows "narrowband")
    private static func generateReasoning(
        fwhmZ: Double?, starsZ: Double?, noiseZ: Double?, trailingZ: Double?,
        tier: QualityTier,
        isLockedKeep: Bool,
        rescueReason: String?,
        filterTrailingMultiplier: Double = 1.0,
        baseFilterMultiplier: Double = 1.0
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
        if trailingPenalty > 0.5 {
            // Use base filter multiplier for label (Ha always shows "narrowband")
            // even when effective multiplier is escalated due to severity
            let label = baseFilterMultiplier < 0.5 ? "Trailing (reduced — narrowband)" :
                        baseFilterMultiplier < 0.8 ? "Trailing (moderate — RGB)" : "Trailing"
            penalties.append((label, trailingPenalty))
        }

        let sorted = penalties.sorted { $0.1 > $1.1 }

        if tier == .excellent || tier == .good {
            if sorted.isEmpty && rescueReason == nil {
                parts.append("All metrics within normal range")
            } else if rescueReason == nil {
                // Good tier but with a notable penalty — explain what was compensated
                if let worst = sorted.first {
                    let direction = worst.0 == "Stars" ? "below" : "above"
                    parts.append("\(worst.0) slightly \(direction) average, compensated by other metrics")
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

                // Secondary penalty — use correct wording per metric direction
                for penalty in sorted.dropFirst().prefix(1) {
                    switch penalty.0 {
                    case "Stars":
                        parts.append("star count also below average")
                    case "Noise":
                        parts.append("noise also elevated")
                    case "FWHM":
                        parts.append("FWHM also elevated")
                    case "Trailing":
                        parts.append("some trailing detected")
                    default:
                        parts.append("\(penalty.0.lowercased()) also degraded")
                    }
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
