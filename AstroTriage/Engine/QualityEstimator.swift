// v4.3.0
import Foundation

// Five-tier quality system with sub-tiers for borderline.
//
// PIPELINE EXECUTION ORDER (note: numbering is historical, not strictly sequential):
//   1. Pre-processing: solar-system exclusion, group formation (combined + per-night)
//   2. Per-group loop iterates combined groups first, then per-night groups (overrides):
//      a. Dark-frame pre-pass (nulls hot-pixel frames from group statistics)
//      b. Stage 1 "garbage"   — absolute outliers (noData, noStars, trailing, etc.)
//      c. Absolute quality floor (isLockedKeep from CalibrationDatabase)
//      d. Stage 2 "relative"  — weighted z-score → excellent/good/borderline/trash
//      e. Stage 3 "rescue"    — promotion rules (never demotion) for borderline/trash
//      f. Community floor     — cold-start rescue to .good when local calibration absent
//      g. Uncertain override  — small group + ambiguous z-score → .uncertain
//   3. Session-wide post-passes (after all groups scored):
//      a. Stage 1.5  "session sanity"      — cross-group demote to trash
//      b. Stage 1.5b "historical baseline" — demote vs learned per-setup baselines
//      c. Low-confidence-scoring flag      — single-night + no history
//      d. Stage 4    "FWHM sanity rescue"  — lift z-score trash to borderline when
//                                            FWHM is within the good-frame P90
//      e. Historical annotation            — attach historical z-score to each breakdown
//
// Side-lane overrides: isLockedKeep (≥30 learned frames), isCommunityFloorLocked
// (community baseline), lowConfidenceScoring (no historical reference).
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
    case noisePeaks        = "noise peaks, not real stars (dome/cap)"
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
    let psfFluxZ: Double?   // PSF flux z-score (higher = more total star signal = better)

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

    // Historical baseline check (Stage 1.5b) — flags frames far above learned setup baselines
    var historicalBaselineReasons: [String] = []

    // Low confidence scoring warning — true when no historical reference data available
    // and session has only 1 distinct night (all-bad groups can't be detected)
    var lowConfidenceScoring: Bool = false

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

    // Stage 1: absolute garbage detection threshold (relative to group median).
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
    static let narrowbandCanonical: Set<String> = ["Ha", "OIII", "SII", "Hbeta", "NII"]
    private static let rgbCanonical: Set<String> = ["R", "G", "B"]

    /// Filter-aware trailing penalty multiplier (base value).
    /// Returns 0.3 for narrowband, 0.6 for RGB, 1.0 for luminance, 0.7 for unknown/exotic.
    static func filterTrailingMultiplier(for canonical: String) -> Double {
        if narrowbandCanonical.contains(canonical) { return 0.3 }
        if rgbCanonical.contains(canonical)        { return 0.6 }
        if canonical == "L"                         { return 1.0 }
        return 0.7  // Unknown or exotic filters — conservative default
    }

    // MARK: - Solar system exclusion

    /// Solar system targets that cannot be quality-scored with deep-sky rules.
    /// Planetary imaging uses fundamentally different techniques (lucky imaging,
    /// video capture, very short exposures) incompatible with deep-sky scoring.
    private static let solarSystemTargets: Set<String> = [
        "moon", "luna", "jupiter", "saturn", "mars", "venus", "mercury",
        "sun", "sol", "uranus", "neptune", "pluto",
        "io", "europa", "ganymede", "callisto", "titan", "enceladus",
        "deimos", "phobos", "lunar"
    ]

    /// Check if a target name refers to a solar system object.
    static func isSolarSystemTarget(_ target: String?) -> Bool {
        guard let t = target?.lowercased().trimmingCharacters(in: .whitespaces),
              !t.isEmpty else { return false }
        return solarSystemTargets.contains(t)
            || t.hasPrefix("solar") || t.hasPrefix("lunar")
            || t.hasPrefix("jupiter") || t.hasPrefix("saturn")
            || t.hasPrefix("mars") || t.hasPrefix("venus")
    }

    // Severity-dependent trailing multiplier thresholds (named constants for tuning)
    private static let severityExponent: Double = 2.0
    // Raised from 0.50 to 0.60 based on 4550-frame curation analysis (2026-04-16):
    // 33 false positives clustered at trailing 0.50-0.60 where human rated 3★.
    // True garbage median trailing is 0.98, so 0.60 retains strong separation.
    private static let absoluteTrailingCeilingScore: Double = 0.60
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
        historicalBaselines: HistoricalBaselines? = nil,
        learnedThresholds: LearnedThresholds? = nil,
        config: ScoringConfig = .default
    ) -> [URL: QualityBreakdown] {
        // Solar system target exclusion — these cannot be quality-scored with deep-sky rules.
        // A homogeneous group of planetary frames would normalize to .good (z-scores = 0),
        // which is incorrect. Skip them entirely.
        let filteredEntries = entries.filter { !Self.isSolarSystemTarget($0.target) }
        let entries = filteredEntries

        // Phase 2 — apply curation-driven offsets to the borderline z-score
        // and the absolute trailing ceiling, but only after enough curated
        // samples have been collected. Below the threshold the effective
        // values are the static defaults declared at the top of this file.
        let effectiveBorderline: Double = {
            guard let lt = learnedThresholds,
                  lt.sampleCount >= LearnedThresholds.learningThreshold else {
                return config.thresholdBorderline
            }
            return config.thresholdBorderline + lt.borderlineOffset
        }()
        let effectiveTrailingCeiling: Double = {
            guard let lt = learnedThresholds,
                  lt.sampleCount >= LearnedThresholds.learningThreshold else {
                return config.absoluteTrailingCeilingScore
            }
            return config.absoluteTrailingCeilingScore + lt.trailingCeilingOffset
        }()

        // Two-pass night-aware scoring for multi-night sessions:
        // Pass 1: combined groups (all nights merged) → every entry gets a baseline score
        // Pass 2: per-night groups (>= minGroupSize) → overwrite with per-night scores
        // This ensures frames in small per-night groups (e.g. 3 B frames from one night)
        // still get scored via the combined group, while large per-night groups get
        // more accurate per-night scoring.
        //
        // INTENTIONAL: The per-night pass overwrites the combined-pass breakdown
        // wholesale, including any Stage 1 garbage flags that were set from combined
        // medians but would NOT fire against the per-night medians. Empirical
        // validation on the 4540-frame curated dataset (2026-04-18) confirmed the
        // overwrite is net-correct: 49 affected frames split into 15 human-garbage
        // (where we'd correctly preserve the flag) vs 19 human-keep (where we'd
        // incorrectly keep the flag), net −4. Per-night normalization handles
        // legitimately-dim-but-OK nights better than merging. Absolute rules
        // (Rule 0/0b no-data, Rule 1a <10 stars, Rule 10 twilight) fire
        // deterministically in both passes — overwrite is irrelevant for those.
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

            // Target-type-aware weight modifiers:
            // Galaxy → resolution-critical (FWHM 1.4x), IFN → SNR-critical (noise 2.0x), etc.
            // Falls back to 1.0 (no modification) for unknown targets.
            let targetType = DeepSkyTargetDatabase.targetType(for: groupEntries.first?.target)
            let fwhmWeightMod = targetType?.fwhmWeightModifier ?? 1.0
            let starWeightMod = targetType?.starWeightModifier ?? 1.0
            let noiseWeightMod = targetType?.noiseWeightModifier ?? 1.0
            let trailWeightMod = targetType?.trailingWeightModifier ?? 1.0

            // FOV fill ratio modulation (secondary adjustment on top of target type).
            // Small target in large FOV → boost FWHM. Target fills FOV → boost noise.
            let fovMod: (fwhmMod: Double, noiseMod: Double) = {
                guard let target = DeepSkyTargetDatabase.lookup(
                    groupEntries.first?.canonicalTarget ?? TargetCatalog.canonicalName(groupEntries.first?.target ?? "")
                ),
                      let fl = groupEntries.first?.focalLength, fl > 0,
                      let px = groupEntries.first?.pixelSizeMicrons, px > 0,
                      let w = groupEntries.first?.width, let h = groupEntries.first?.height else {
                    return (fwhmMod: 1.0, noiseMod: 1.0)
                }
                let fillRatio = target.fovFillRatio(focalLength: fl, pixelSizeMicrons: px,
                                                     sensorWidth: w, sensorHeight: h)
                return DeepSkyTargetDatabase.fovWeightModulation(fillRatio: fillRatio)
            }()

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
            let psfFluxValues: [Double?] = groupEntries.map { $0.psfFluxSum }
            let snrValues: [Double?] = groupEntries.map { entry in
                guard let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return nil }
                return Double(med / mad)
            }

            // ── Pre-pass: identify dark frames that would contaminate group statistics ──
            // Dark frames (dome closed, lens cap) have 10000+ hot pixel "stars", near-zero
            // background, and extreme metric values. If they outnumber real frames in a group,
            // they BECOME the group median, making every real frame look like an outlier.
            // Detect them early and null out their metrics so they don't skew statistics.
            var darkFrameIndices: Set<Int> = []
            // FL-dependent star threshold for dark frame detection Path B.
            // Wide-field scopes (620mm, 468mm) can have 5000+ real stars at dark sites.
            // Long FL (2400mm) rarely exceeds 4000 real stars.
            // Scale threshold with FOV area: shorter FL = higher threshold.
            let darkStarThreshold: Double = {
                guard let fl = groupEntries.first?.focalLength, fl > 0 else { return 7500 }
                // Reference: 7500 at 1000mm. Scale inversely with FL² (FOV area ∝ 1/FL²)
                // Clamp to [5000, 10000] to stay within physical bounds.
                let scaled = 7500.0 * (1000.0 / fl) * (1000.0 / fl)
                return min(10000, max(5000, scaled))
            }()

            for (i, entry) in groupEntries.enumerated() {
                if let stars = starsValues[i] {
                    // Cross-check: real stars have measurable FWHM and background.
                    // Hot pixel noise peaks from dark/dome frames have tiny FWHM (~0.5px)
                    // and near-zero background. Bright nebulae and dense star fields can
                    // legitimately produce 10000+ star detections with normal FWHM and sky.
                    // FWHM threshold is plate-scale-aware: at 1.54"/px (e.g. 504mm FL,
                    // 3.76μm pixels), real stars have FWHM ~1.3px under typical 2" seeing.
                    // Hardcoded 3.0px would reject all stars at that plate scale.
                    let fwhmThreshold: Double = {
                        if let app = entry.arcsecPerPixel, app > 0 {
                            // Minimum expected FWHM under good seeing (1.5") at this plate scale.
                            // At 1.54"/px: max(0.8, min(3.0, 1.5/1.54)) = max(0.8, 0.97) = 0.97
                            // At 0.5"/px:  max(0.8, min(3.0, 1.5/0.5))  = max(0.8, 3.0)  = 3.0
                            return max(0.8, min(3.0, 1.5 / app))
                        }
                        return 3.0  // fallback for unknown plate scale
                    }()
                    let hasRealPSF = fwhmValues[i] != nil && fwhmValues[i]! > fwhmThreshold
                    let hasSignificantBackground = entry.noiseMedian != nil && entry.noiseMedian! >= 0.002
                    // SNR cross-check: dark/dome frames have near-zero SNR (noise only).
                    // Real light frames with sky signal have SNR >> 1. This catches cases
                    // where FWHM measurement fails on undersampled stars (e.g. full-frame
                    // ASI6200MM at 504mm FL with 52000+ real stars but FWHM ~1.3px).
                    let hasMeasurableSignal = snrValues[i] != nil && snrValues[i]! > 5.0

                    if stars >= 10000 && !(hasRealPSF && hasSignificantBackground) && !hasMeasurableSignal {
                        // Path A: Extreme star count, but only if stars don't look real
                        // AND no measurable sky signal (SNR). All three must fail.
                        darkFrameIndices.insert(i)
                    } else if stars >= darkStarThreshold, let bgLevel = entry.noiseMedian, bgLevel < 0.002,
                              !hasMeasurableSignal {
                        // Path B: FL-scaled star threshold + very low background + no signal.
                        // Wide-field (620mm): threshold ~9200 (wide FOV = many real stars)
                        // Long FL (2423mm): threshold ~5000 (narrow FOV = few real stars)
                        darkFrameIndices.insert(i)
                    }
                }
            }

            // Create cleaned metric arrays with dark frames nulled out
            let cleanStarsValues: [Double?] = starsValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }
            let cleanFwhmValues: [Double?] = fwhmValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }
            let cleanHfrValues: [Double?] = hfrValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }
            let cleanPsfFluxValues: [Double?] = psfFluxValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }
            let cleanSnrValues: [Double?] = snrValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }
            let noiseMadValues: [Double?] = groupEntries.map { $0.noiseMAD.map { Double($0) } }
            let cleanNoiseMadValues: [Double?] = noiseMadValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }
            let trailingValues: [Double?] = groupEntries.map { $0.trailingScore }
            let cleanTrailingValues: [Double?] = trailingValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }

            // SNR contribution: find best SNR in group (excluding dark frames)
            let validSNRs = cleanSnrValues.compactMap { $0 }
            let snrBest = validSNRs.max() ?? 0

            // Detect bimodal/unreliable star counts: if coefficient of variation > 1.0,
            // star counts span orders of magnitude — likely galaxy/nebula contamination
            // making the GPU detector threshold-sensitive. Ignore star count for scoring.
            let validStarCounts = cleanStarsValues.compactMap { $0 }
            if validStarCounts.count >= 2 {
                let scMean = validStarCounts.reduce(0, +) / Double(validStarCounts.count)
                if scMean > 0 {
                    let scVar = validStarCounts.map { ($0 - scMean) * ($0 - scMean) }.reduce(0, +) / Double(validStarCounts.count)
                    if scVar.squareRoot() / scMean > 1.0 {
                        starWeight = 0  // Star counts unreliable — skip in scoring
                    }
                }
            }

            // Compute group statistics excluding dark frames
            let starsMedian = sortedMedian(cleanStarsValues)
            let snrMedian = sortedMedian(cleanSnrValues)
            let fwhmMedian = sortedMedian(cleanFwhmValues)
            let hfrMedian = sortedMedian(cleanHfrValues)
            // Background level: detect clouds/gradient via anomalous background median
            let bgValues: [Double?] = groupEntries.map { $0.noiseMedian.map { Double($0) } }
            let cleanBgValues: [Double?] = bgValues.enumerated().map {
                darkFrameIndices.contains($0.offset) ? nil : $0.element
            }
            let bgMedian = sortedMedian(cleanBgValues)
            let bgMAD = medianAbsoluteDeviation(cleanBgValues, median: bgMedian)

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

            // Z-scores for relative scoring (computed from clean data).
            // FWHM MAD floor scales with focal length: at long FL (small plate scale),
            // atmospheric seeing spreads across more pixels, so larger pixel differences
            // are physically insignificant.
            let arcsecPP = groupEntries.first?.arcsecPerPixel
            let fwhmFloor = fwhmMADFloor(arcsecPerPixel: arcsecPP)
            let fwhmZscores  = zscores(values: cleanFwhmValues, metric: .fwhm, floorOverride: fwhmFloor)
            let hfrZscores   = zscores(values: cleanHfrValues, metric: .hfr, floorOverride: fwhmFloor * 0.65)
            let starsZscores = zscores(values: cleanStarsValues, metric: .starCount)
            let psfFluxZscores = zscores(values: cleanPsfFluxValues, metric: .psfFlux)
            let noiseMadZscores = zscores(values: cleanNoiseMadValues, metric: .noiseMAD)
            // Use trailing score (consensus-weighted, FL-adaptive) instead of raw eccentricity
            let trailingZscores = zscores(values: cleanTrailingValues, metric: .trailing)

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

                // Rule 0: No measurable PSF — if FWHM couldn't be computed, there are
                // no real stars to measure. Catches: pitch black frames, heavy clouds,
                // fog, lens cap, dome closed. Star detector may find noise peaks but
                // Gaussian fitting fails on them → FWHM is nil.
                // Exception: if SNR is measurable (> 5) and star count is meaningful (> 100),
                // the frame clearly has signal — FWHM nil means measurement failure on
                // undersampled stars, not absence of signal.
                let hasNoFWHM = fwhmValues[localIdx] == nil
                if hasNoFWHM {
                    let hasSignal = snr != nil && snr! > 5.0 && (starsValues[localIdx] ?? 0) > 100
                    if !hasSignal {
                        garbageReasons.append(.noData)
                    }
                }

                // Rule 0b: Dark frame / dome closed / lens cap detection.
                // Dark frames have near-zero sky background but hot pixels create thousands
                // of false star detections that survive even 16σ auto-escalation.
                // Detection paths:
                // (a) Stars ≥ 10000 AND no real PSF AND no sky signal (SNR ≤ 5).
                //     Bright nebulae (M42 H-alpha) and dense star fields (NGC 2251 at
                //     504mm FL) can have 14000-52000+ real star detections with measurable
                //     FWHM, significant background, and/or high SNR — these pass through.
                // (b) Stars ≥ FL-dependent threshold AND very low background AND no signal.
                // FWHM threshold is plate-scale-aware (see pre-pass for details).
                if let stars = starsValues[localIdx] {
                    let r0bFwhmThreshold: Double = {
                        if let app = entry.arcsecPerPixel, app > 0 {
                            return max(0.8, min(3.0, 1.5 / app))
                        }
                        return 3.0
                    }()
                    let hasRealPSF = fwhmValues[localIdx] != nil && fwhmValues[localIdx]! > r0bFwhmThreshold
                    let hasSignificantBackground = entry.noiseMedian != nil && entry.noiseMedian! >= 0.002
                    let hasMeasurableSignal = snr != nil && snr! > 5.0

                    if stars >= 10000 && !(hasRealPSF && hasSignificantBackground) && !hasMeasurableSignal {
                        garbageReasons.append(.noisePeaks)
                    } else if stars >= darkStarThreshold, let bgLevel = entry.noiseMedian, bgLevel < 0.002,
                              !hasMeasurableSignal {
                        garbageReasons.append(.noisePeaks)
                    }
                }

                // Rule 1: No stars or near-zero stars → garbage
                // Three checks, ALL run regardless of starWeight (CV check disables star
                // count for z-score weighting, but garbage detection must always work):
                // (a) absolute floor — <10 stars is unusable
                // (b) relative drop — far below group median (when starWeight > 0)
                // (c) P90 floor — far below group best (catches clouded frames even when
                //     many bad frames drag the median down and CV disables starWeight)
                if let stars = starsValues[localIdx] {
                    if stars < 10 {
                        garbageReasons.append(.noStars)
                    } else {
                        // (b) Relative to median — only when star counts are stable
                        if starWeight > 0, let median = starsMedian {
                            let dropThreshold = isNarrowband ? config.garbageDropFactor * 0.3 : config.garbageDropFactor * 0.5
                            if median > 10 && stars < median * dropThreshold {
                                garbageReasons.append(.noStars)
                            }
                        }
                        // (c) P90 floor — catches clouded frames in bimodal groups where
                        // CV > 1.0 disabled starWeight. If P90 is 5000 and frame has 500,
                        // that's 10% of the best frames → clearly clouded.
                        //
                        // Index note: Int(count * 0.9) collapses to the last element
                        // (i.e. max) for counts 5..10. The bound is thus effectively
                        // "15% of the group max" at small n. Empirical check on the
                        // 4540-frame curated set (2026-04-18) showed switching to an
                        // interpolated percentile changed only 3 classifications, 2 of
                        // which were correct catches that would be lost. Kept as-is.
                        let sortedStars = cleanStarsValues.compactMap { $0 }.sorted()
                        if sortedStars.count >= 5 {
                            let p90 = sortedStars[Int(Double(sortedStars.count) * 0.9)]
                            if p90 > 100 && stars < p90 * 0.15 {
                                if !garbageReasons.contains(.noStars) {
                                    garbageReasons.append(.noStars)
                                }
                            }
                        }
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
                    if median > 5 && snrVal < median * config.garbageDropFactor {
                        garbageReasons.append(.lowSNR)
                    }
                }

                // Rule 3: FWHM catastrophically high (severe tracking error, defocus)
                if let fwhm = fwhmValues[localIdx], let median = fwhmMedian {
                    if median > 0 && fwhm > median * (1.0 / config.garbageDropFactor) {
                        garbageReasons.append(.highFWHM)
                    }
                }

                // Rule 4: HFR catastrophically high
                if let hfr = hfrValues[localIdx], let median = hfrMedian {
                    if median > 0 && hfr > median * (1.0 / config.garbageDropFactor) {
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
                   let ts = entry.trailingScore, ts > effectiveTrailingCeiling,
                   let consensus = entry.trailingConsensus, consensus > config.absoluteTrailingCeilingConsensus {
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
                //
                // The `starWeight > 0` guard disables this rule when the CV check
                // (line ~496) marked star counts as bimodal (galaxy/nebula groups).
                // Empirical check on the 4540-frame curated dataset (2026-04-18):
                // only 4 bimodal groups exist, and Rule 7b would fire on 0 additional
                // frames if the guard were removed. Guard kept as a safety net against
                // false positives on genuinely variable-detection groups.
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
                //
                // UNITS: bgMAD comes from medianAbsoluteDeviation() which returns RAW
                // MAD (no 1.4826 σ-normalization — that's only applied in zscores()).
                // 5 raw MADs ≈ 7.4σ for normal distributions. Background levels are
                // non-normal (cloud tails skew them), so σ intuition doesn't fully
                // apply; threshold empirically calibrated. Empirical check on the
                // 4540-frame curated set (2026-04-18): lowering to 3.3 raw MADs
                // (≈5σ) added 26 human-garbage catches but 18/26 were already flagged
                // by other Stage 1 rules, and precision dropped from 54% to 34%.
                // Current 5.0 floor retained.
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

                // Rule 9: Star chain detection — tracking hops (mount jumps/PE)
                // Threshold scales smoothly with plate scale: narrow plate scales (long FL) use 10%,
                // wider plate scales (short FL, dense fields with coincidental close pairs) use up to 22%.
                // Base raised from 0.08→0.10 based on 4550-frame curation: 56 chain FPs at RC12/RASA.
                //
                // Cross-check: chain pattern + round stars = coincidental alignment, NOT tracking error.
                // Real tracking hops produce elongated stars (trailing > 0.15 or eccentricity above
                // FL baseline). Without this, dense star fields and optical aberrations false-positive.
                // Curation evidence: chain FPs had axis_ratio 0.844 (round) vs TG 0.626 (elongated).
                if let chainFrac = entry.starChainFraction {
                    let chainThreshold: Double
                    if let scale = entry.arcsecPerPixel, scale > 0 {
                        let t = max(0.0, min(1.0, (scale - 0.5) / 2.0))  // 0..1 as scale 0.5 → 2.5 "/px
                        chainThreshold = 0.10 + t * 0.12  // 0.10 → 0.22
                    } else {
                        chainThreshold = 0.10
                    }
                    if chainFrac > chainThreshold {
                        // Cross-check: stars must show SOME elongation to confirm tracking error.
                        // Chain pattern alone with round stars is coincidental (dense field, optics).
                        let hasElongation: Bool = {
                            if let ts = entry.trailingScore, ts > 0.15 { return true }
                            if let ecc = entry.computedEccentricity {
                                let fl = entry.focalLength ?? 0
                                let baseline = fl > 0
                                    ? min(0.70, max(0.15, 0.8 / (fl / 200.0).squareRoot()))
                                    : 0.40
                                if ecc > baseline + 0.15 { return true }
                            }
                            return false
                        }()
                        if hasElongation {
                            garbageReasons.append(.trackingHop)
                        }
                    }
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
                    return min(config.zscoreCap, max(-config.zscoreCap, z))
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
                        psfFluxZ: cappedZ(psfFluxZscores[localIdx]),
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
                let cap = config.zscoreCap

                // FWHM and HFR are ~95% correlated (both measure star sharpness).
                // Using both double-penalizes slightly-softer frames.
                // Use FWHM when available; HFR only as fallback.
                // Target-type + FOV fill ratio modifiers adjust weight: galaxy 1.4x, IFN 0.4x, etc.
                let fwhmW = 1.0 * fwhmWeightMod * fovMod.fwhmMod
                if let z = fwhmZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * fwhmW     // lower FWHM = better → negate
                    wSum += fwhmW
                } else if let z = hfrZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * fwhmW     // lower HFR = better → negate
                    wSum += fwhmW
                }
                // PSF flux replaces star count when available — it captures both
                // star count AND brightness (more robust, immune to hot pixel inflation).
                // Falls back to star count z-score when PSF flux is not computed.
                // Target-type modifier: cluster 0.2x (star count meaningless), galaxy 0.8x, etc.
                let starW = starWeight * starWeightMod
                if let z = psfFluxZscores[localIdx] {
                    zSum += min(cap, max(-cap, z)) * starW      // higher flux = better → keep sign
                    wSum += starW
                } else if let z = starsZscores[localIdx] {
                    zSum += min(cap, max(-cap, z)) * starW      // higher stars = better → keep sign
                    wSum += starW
                }
                // Noise weight: IFN 2.0x (every photon counts), emission nebula 1.4x, galaxy 0.8x
                let noiseW = 1.0 * noiseWeightMod * fovMod.noiseMod
                if let z = noiseMadZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * noiseW    // lower noise = better → negate
                    wSum += noiseW
                }
                // Trailing weight: galaxy 1.2x (elongation destroys detail), IFN 0.3x (irrelevant)
                let trailW = effectiveTrailMult * trailWeightMod
                if let z = trailingZscores[localIdx] {
                    zSum += -min(cap, max(-cap, z)) * trailW    // lower trailing = better → negate
                    wSum += trailW
                }

                // Frame has no comparable metric z-scores (all nil). This happens when the
                // frame is the only one in its group with any measured metric — zscores()
                // requires ≥2 values to produce anything non-nil. Instead of silently
                // dropping the frame from the result dict (which hides it from UI/downstream
                // stages), surface it as .uncertain with explicit "isolated" reasoning.
                guard wSum > 0 else {
                    result[entry.url] = QualityBreakdown(
                        tier: .uncertain,
                        combinedZScore: 0,
                        starsZ: nil, fwhmZ: nil, hfrZ: nil,
                        noiseZ: nil, trailingZ: nil, psfFluxZ: nil,
                        snrContribution: nil, snrSquared: snrSq,
                        garbageReasons: [],
                        isLockedKeep: false,
                        reasoningText: "No comparable frames in group — metrics unmeasured or isolated",
                        filterTrailingMultiplier: effectiveTrailMult
                    )
                    continue
                }

                let combinedZ = zSum / wSum

                var tier: QualityTier
                if lockedKeep {
                    // Absolute floor: z-scores cannot downgrade below .good
                    if combinedZ > config.thresholdExcellent {
                        tier = .excellent
                    } else {
                        tier = .good
                    }
                } else if combinedZ > config.thresholdExcellent {
                    tier = .excellent
                } else if combinedZ > config.thresholdGood {
                    tier = .good
                } else if combinedZ > effectiveBorderline {
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

                    // Rule A: Good FWHM + acceptable noise + normal star count → fundamentally sound.
                    // The !starsLow guard lets Rule B own the "star dip" narrative below
                    // (same .good tier, more accurate reasoning label for tooltips/telemetry).
                    if fwhmOK && noiseOK && trailingOK && !starsLow {
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
                    psfFluxZ: cappedZ(psfFluxZscores[localIdx]),
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
                    && combinedZ > -1.0 && combinedZ < config.thresholdExcellent {
                    tier = .uncertain
                }

                // `reasoning` was built with the pre-uncertain tier and may reference a
                // rescue that no longer applies (e.g. a borderline-→good rescue narrative
                // for a frame now downgraded to uncertain). Override in that narrow case
                // so the tooltip text matches the final tier.
                let finalReasoning: String? = (tier == .uncertain)
                    ? "Small group — low confidence"
                    : reasoning

                var breakdown = QualityBreakdown(
                    tier: tier,
                    combinedZScore: combinedZ,
                    starsZ: cappedZ(starsZscores[localIdx]),
                    fwhmZ: cappedZ(fwhmZscores[localIdx]),
                    hfrZ: cappedZ(hfrZscores[localIdx]),
                    noiseZ: cappedZ(noiseMadZscores[localIdx]),
                    trailingZ: cappedZ(trailingZscores[localIdx]),
                    psfFluxZ: cappedZ(psfFluxZscores[localIdx]),
                    snrContribution: displayContrib,
                    snrSquared: snrSq,
                    garbageReasons: [],
                    isLockedKeep: lockedKeep,
                    reasoningText: finalReasoning,
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

        // ── Stage 1.5b: Historical baseline check ──
        // Uses FrameHistoryDatabase/CalibrationDatabase learned baselines to detect frames
        // far above the setup's historical norms. Catches uniformly-bad sessions where
        // cross-group comparison (Stage 1.5) can't help because all groups are equally bad.
        // Uses combined FWHM+trailing deviation scoring for mount jump frames where neither
        // metric alone reaches the individual threshold.
        historicalBaselineCheck(
            entries: entries, result: &result,
            calibrationDB: calibrationDB, fingerprint: fingerprint
        )

        // ── Low-confidence scoring detection ──
        // Flag frames in setups with no historical baseline AND single-night data.
        // Users need to know when scoring accuracy is limited.
        if let fp = fingerprint {
            let profile = calibrationDB?.profile(for: fp)
            let hasBaseline = profile?.hasLearned ?? false
            let distinctNights = Set(entries.compactMap { $0.observingNight })
            if !hasBaseline && distinctNights.count <= 1 {
                for entry in entries {
                    if var bd = result[entry.url] {
                        bd.lowConfidenceScoring = true
                        result[entry.url] = bd
                    }
                }
            }
        }

        // ── Stage 4: FWHM sanity check for z-score trash ──
        // Lifts z-score-trash frames back to .borderline when their FWHM is within
        // the good-frame 90th percentile of the group — i.e. their "trash" label was
        // driven by an exceptional peak-quality block pulling down the median, not by
        // actual seeing degradation. Dawn/cloud frames have Stage 1 garbageReasons and
        // are NOT matched here (the `where` clause excludes them).
        //
        // Session-sanity-demoted (Stage 1.5) and historical-baseline-demoted (Stage 1.5b)
        // frames ALSO have empty garbageReasons — their reasons live in
        // sessionSanityReasons / historicalBaselineReasons. They WILL match the `.trash
        // where bd.garbageReasons.isEmpty` case and be promoted to borderline. Empirical
        // validation on the curated dataset (2026-04-18) showed this is net helpful
        // (87 human-keep vs 65 human-garbage among 220 candidates). The previous
        // implementation lost the reason strings when rebuilding the breakdown; the
        // `var demoted = oldBD` + mutate pattern below preserves them so the UI shows
        // "REVIEW — [session sanity reason]" via QualityBreakdown.recommendationLabel.
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

                // Preserve sessionSanityReasons / historicalBaselineReasons so the
                // recommendationLabel still shows "REVIEW — <reason>" (see
                // QualityBreakdown.recommendationLabel, lines 110-112).
                let hasSanityReason = !oldBD.sessionSanityReasons.isEmpty
                    || !oldBD.historicalBaselineReasons.isEmpty
                let rescueText: String? = hasSanityReason
                    ? nil   // Keep the sanity reasons visible via recommendationLabel
                    : "FWHM comparable to good frames — penalized by session peak quality, not actual degradation"

                var demoted = QualityBreakdown(
                    tier: .borderline,
                    combinedZScore: oldBD.combinedZScore,
                    starsZ: oldBD.starsZ,
                    fwhmZ: oldBD.fwhmZ,
                    hfrZ: oldBD.hfrZ,
                    noiseZ: oldBD.noiseZ,
                    trailingZ: oldBD.trailingZ,
                    psfFluxZ: oldBD.psfFluxZ,
                    snrContribution: oldBD.snrContribution,
                    snrSquared: oldBD.snrSquared,
                    garbageReasons: [],
                    isLockedKeep: oldBD.isLockedKeep,
                    reasoningText: rescueText,
                    filterTrailingMultiplier: oldBD.filterTrailingMultiplier
                )
                demoted.isCommunityFloorLocked = oldBD.isCommunityFloorLocked
                demoted.sessionSanityReasons = oldBD.sessionSanityReasons
                demoted.historicalZScore = oldBD.historicalZScore
                demoted.historicalPercentile = oldBD.historicalPercentile
                demoted.historicalBaselineReasons = oldBD.historicalBaselineReasons
                demoted.lowConfidenceScoring = oldBD.lowConfidenceScoring
                result[url] = demoted
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



}

// MARK: - Group key

struct GroupKey: Hashable {
    let filter:      String
    let object:      String
    let exposure:    Int
    let focalLength: Int     // Rounded FL in mm — prevents cross-setup comparison
    let night:       String? // observingNight for multi-night sessions, nil for single-night
    let sensorWidth: Int     // Image width — separates different camera sensors (e.g. ASI6200 vs ASI2600)
    let sensorHeight: Int    // Image height — prevents cross-sensor z-score contamination

    init(entry: ImageEntry, useNight: Bool = false) {
        filter      = (entry.filter   ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        // Use canonical target name to unify "NGC 7000", "NGC7000", "North America Nebula"
        object      = entry.canonicalTarget ?? TargetCatalog.canonicalName(entry.target ?? "")
        exposure    = entry.exposure.map { Int($0.rounded()) } ?? 0
        // Focal length discriminates setups: RASA 620mm vs RC12 1964mm must NEVER be
        // in the same group — they have completely different plate scales and FWHM expectations.
        // Round to nearest 50mm to tolerate minor FL reporting differences between sessions.
        focalLength = entry.focalLength.map { Int(($0 / 50).rounded()) * 50 } ?? 0
        night       = useNight ? entry.observingNight : nil
        // Sensor dimensions prevent cross-camera contamination: ASI6200 (9576×6388) and
        // ASI2600 (6248×4176) have vastly different star counts and FOV — comparing them
        // in one group produces false trash marks on the smaller sensor.
        sensorWidth  = entry.width ?? 0
        sensorHeight = entry.height ?? 0
    }
}
