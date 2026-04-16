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
        // Solar system target exclusion — these cannot be quality-scored with deep-sky rules.
        // A homogeneous group of planetary frames would normalize to .good (z-scores = 0),
        // which is incorrect. Skip them entirely.
        let filteredEntries = entries.filter { !Self.isSolarSystemTarget($0.target) }
        let entries = filteredEntries

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
                            let dropThreshold = isNarrowband ? garbageDropFactor * 0.3 : garbageDropFactor * 0.5
                            if median > 10 && stars < median * dropThreshold {
                                garbageReasons.append(.noStars)
                            }
                        }
                        // (c) P90 floor — catches clouded frames in bimodal groups where
                        // CV > 1.0 disabled starWeight. If P90 is 5000 and frame has 500,
                        // that's 10% of the best frames → clearly clouded.
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

                // Rule 9: Star chain detection — tracking hops (mount jumps/PE)
                // Threshold scales smoothly with plate scale: narrow plate scales (long FL) use 8%,
                // wider plate scales (short FL, dense fields with coincidental close pairs) use up to 18%.
                // Smooth linear interpolation prevents discontinuous behavior across FL boundaries
                // (e.g. 450mm vs 550mm behaves predictably the same).
                // The directional consensus (R threshold also FL-adaptive in StarMetricsCalculator)
                // ensures these are systematic patterns, not random star clustering.
                if let chainFrac = entry.starChainFraction {
                    let chainThreshold: Double
                    if let scale = entry.arcsecPerPixel, scale > 0 {
                        let t = max(0.0, min(1.0, (scale - 0.5) / 2.0))  // 0..1 as scale 0.5 → 2.5 "/px
                        chainThreshold = 0.08 + t * 0.10  // 0.08 → 0.18
                    } else {
                        chainThreshold = 0.08
                    }
                    if chainFrac > chainThreshold {
                        garbageReasons.append(.trackingHop)
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
                let cap = zscoreCap

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
                    psfFluxZ: cappedZ(psfFluxZscores[localIdx]),
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
                    psfFluxZ: oldBD.psfFluxZ,
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

    // MARK: - Historical Baseline Check (Stage 1.5b)

    /// Compare frames against per-setup historical baselines from CalibrationDatabase.
    /// Catches uniformly-bad sessions where cross-group comparison (Stage 1.5) can't help
    /// because all groups in the current session are equally bad.
    /// Requires ≥30 historical frames (hasLearned) for reliable baselines.
    private static func historicalBaselineCheck(
        entries: [ImageEntry],
        result: inout [URL: QualityBreakdown],
        calibrationDB: CalibrationDatabase?,
        fingerprint: SetupFingerprint?
    ) {
        // Diagnostic logger — writes to Application Support/AstroBlinkV2/stage15b_diag.txt
        let diagLog = { (msg: String) in
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("AstroBlinkV2")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("stage15b_diag.txt").path
            let line = msg + "\n"
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
            }
        }
        diagLog("=== Stage 1.5b: \(entries.count) entries, fp=\(fingerprint?.telescope ?? "nil")+\(fingerprint?.camera ?? "nil") ===")

        // Build baselines from TWO sources:
        // 1. FrameHistoryDatabase (populated by Archive Scanner — always available after scan)
        // 2. CalibrationDatabase (populated by PRE-DELETE confirmation — learns over time)
        // Use whichever has data. FrameHistoryDB is primary (scan fills it).

        var baselineFWHM: Double?
        var baselineFWHMStdDev: Double?
        var baselineTrailing: Double?
        var baselineTrailingStdDev: Double?
        var baselineFrameCount = 0
        var isEquipmentWide = false  // true when no same-target data available

        // Source 1: FrameHistoryDatabase (direct SQL query for per-setup stats)
        // CRITICAL: exclude currently loaded frames to avoid self-contamination.
        // If January garbage frames were scanned, they'd be in the DB — including them
        // in the baseline would normalize the bad metrics and defeat the purpose.
        let currentNights = Set(entries.compactMap { $0.observingNight })
        let currentHashes = Set(entries.compactMap { $0.fileHash })

        if let fp = fingerprint {
            diagLog("fingerprint: telescope='\(fp.telescope)' camera='\(fp.camera)' hash=\(fp.hash.prefix(8))")
            diagLog("currentNights=\(currentNights) currentHashes=\(currentHashes.count)")

            // Query by telescope+camera (equipment match) instead of exact setupHash,
            // because plate-solve FL variations create different hashes for the same scope.
            if let allRecords = try? FrameHistoryDatabase.shared.historicalFramesByEquipment(
                telescope: fp.telescope, camera: fp.camera
            ) {
                // Exclude current session's nights + only use GOOD frames (tier >= 2)
                // to build a clean baseline. Bad historical frames would contaminate it.
                let records = allRecords.filter { record in
                    if let night = record.observingNight, currentNights.contains(night) { return false }
                    if currentHashes.contains(record.fileHash) { return false }
                    // Only use good/excellent frames for baseline (tier 2=good, 3=excellent)
                    guard let tier = record.qualityTier, tier >= 2 else { return false }
                    return true
                }

                // Prefer same-target baseline, fall back to all-target if not enough data
                // Normalize target names: strip spaces, lowercase for robust matching
                let targetRecords: [FrameRecord]
                let currentCanonical = entries.first(where: { $0.target != nil })
                    .map { TargetCatalog.canonicalName($0.target ?? "") } ?? ""
                let normalizedTarget = currentCanonical.lowercased().replacingOccurrences(of: " ", with: "")
                diagLog("currentTarget='\(currentCanonical)' normalized='\(normalizedTarget)'")
                if !normalizedTarget.isEmpty {
                    let sameTarget = records.filter { record in
                        // Use canonicalTarget if non-empty, else target
                        let raw = record.canonicalTarget?.isEmpty == false ? record.canonicalTarget! : (record.target ?? "")
                        let recTarget = raw.lowercased().replacingOccurrences(of: " ", with: "")
                        return !recTarget.isEmpty && (
                            recTarget == normalizedTarget ||
                            recTarget.contains(normalizedTarget) ||
                            normalizedTarget.contains(recTarget)
                        )
                    }
                    diagLog("same-target matches: \(sameTarget.count)")
                    if sameTarget.count >= 20 {
                        targetRecords = sameTarget
                    } else {
                        targetRecords = records
                        isEquipmentWide = true
                    }
                } else {
                    targetRecords = records
                    isEquipmentWide = true
                }

                diagLog("DB: \(allRecords.count) total → \(records.count) good (tier≥2, excl nights) → \(targetRecords.count) for baseline")

                let fwhms = targetRecords.compactMap { $0.computedFWHM }.filter { $0 > 0 && $0 < 50 }.sorted()
                let trails = targetRecords.compactMap { $0.trailingScore }.filter { $0 >= 0 }.sorted()

                if fwhms.count >= 20 {
                    // Use P25 (25th percentile) as baseline instead of mean.
                    // Mean is dragged up by mediocre nights. P25 represents "what good
                    // looks like" — frames clearly above P25 + margin are suspect.
                    let p25 = fwhms[fwhms.count / 4]
                    let median = fwhms[fwhms.count / 2]
                    // MAD computed around median (robust spread estimate).
                    // .magnitude instead of abs() disambiguates for Swift 6's stricter
                    // overload resolution inside the nested closure+sort+multiply chain.
                    let deviations: [Double] = fwhms.map { ($0 - median).magnitude }.sorted()
                    let mad: Double = deviations[fwhms.count / 2] * 1.4826
                    baselineFWHM = p25
                    baselineFWHMStdDev = max(mad, 0.3)
                    baselineFrameCount = fwhms.count
                    diagLog("FWHM P25=\(String(format: "%.2f", p25)) median=\(String(format: "%.2f", median)) MAD=\(String(format: "%.2f", mad))")
                }
                if trails.count >= 20 {
                    let p25 = trails[trails.count / 4]
                    let median = trails[trails.count / 2]
                    let deviations: [Double] = trails.map { ($0 - median).magnitude }.sorted()
                    let mad: Double = deviations[trails.count / 2] * 1.4826
                    baselineTrailing = p25
                    baselineTrailingStdDev = max(mad, 0.02)
                    diagLog("Trail P25=\(String(format: "%.3f", p25)) median=\(String(format: "%.3f", median)) MAD=\(String(format: "%.3f", mad))")
                }
                diagLog("FWHM baseline: \(baselineFWHM.map { String(format: "%.2f ± %.2f", $0, baselineFWHMStdDev ?? 0) } ?? "nil") from \(fwhms.count) values")
                diagLog("Trail baseline: \(baselineTrailing.map { String(format: "%.3f ± %.3f", $0, baselineTrailingStdDev ?? 0) } ?? "nil") from \(trails.count) values")
            } else {
                diagLog("DB query returned nil")
            }
        } else {
            diagLog("fingerprint is nil — skipping")
        }

        // Source 1b: Cross-equipment same-target query (trailing/ecc only)
        // When same-equipment same-target data is insufficient (isEquipmentWide), try
        // finding good frames for the SAME TARGET from ANY equipment. Trailing score and
        // eccentricity are FL-normalized → comparable across equipment.
        // A tighter same-target trailing baseline catches frames that slip through the
        // noisy equipment-wide baseline.
        if isEquipmentWide, let normalizedTarget = {
            let ct = entries.first(where: { $0.target != nil })
                .map { TargetCatalog.canonicalName($0.target ?? "") } ?? ""
            return ct.isEmpty ? nil : ct
        }() {
            if let crossRecords = try? FrameHistoryDatabase.shared.historicalFramesByTarget(
                canonicalTarget: normalizedTarget
            ) {
                let goodCross = crossRecords.filter { record in
                    if let night = record.observingNight, currentNights.contains(night) { return false }
                    if currentHashes.contains(record.fileHash) { return false }
                    guard let tier = record.qualityTier, tier >= 2 else { return false }
                    return true
                }
                diagLog("Cross-equipment '\(normalizedTarget)': \(crossRecords.count) total → \(goodCross.count) good")
                let crossTrails = goodCross.compactMap { $0.trailingScore }.filter { $0 >= 0 }.sorted()
                if crossTrails.count >= 10 {
                    let p25 = crossTrails[crossTrails.count / 4]
                    let median = crossTrails[crossTrails.count / 2]
                    let deviations: [Double] = crossTrails.map { ($0 - median).magnitude }.sorted()
                    let mad: Double = deviations[crossTrails.count / 2] * 1.4826
                    // Replace equipment-wide trailing baseline with tighter same-target data
                    baselineTrailing = p25
                    baselineTrailingStdDev = max(mad, 0.02)
                    diagLog("Cross-equipment trail baseline: P25=\(String(format: "%.3f", p25)) MAD=\(String(format: "%.3f", mad)) from \(crossTrails.count) frames (replaces equipment-wide)")
                }
            }
        }

        // Source 2: CalibrationDatabase fallback (if FrameHistoryDB didn't have enough data)
        if baselineFWHM == nil, let db = calibrationDB, let fp = fingerprint {
            let profile = db.profile(for: fp)
            if profile.hasLearned && profile.globalFWHM.count >= 30 && profile.globalFWHM.runningMAD > 0 {
                baselineFWHM = profile.globalFWHM.mean
                baselineFWHMStdDev = max(profile.globalFWHM.runningMAD, 0.3)
                baselineFrameCount = profile.globalFWHM.count
            }
            if baselineTrailing == nil && profile.globalTrailing.count >= 30 && profile.globalTrailing.runningMAD > 0 {
                baselineTrailing = profile.globalTrailing.mean
                baselineTrailingStdDev = max(profile.globalTrailing.runningMAD, 0.02)
            }
        }

        // Need at least FWHM baseline with ≥20 frames
        guard let refFWHM = baselineFWHM, let refFWHMDev = baselineFWHMStdDev,
              baselineFrameCount >= 20 else { return }

        diagLog("--- Per-frame evaluation (equipmentWide=\(isEquipmentWide), refFWHM=\(String(format: "%.2f±%.2f", refFWHM, refFWHMDev))) ---")

        var demotedCount = 0

        for entry in entries {
            guard var bd = result[entry.url] else { continue }
            if !bd.garbageReasons.isEmpty || bd.isLockedKeep || bd.isCommunityFloorLocked { continue }

            // Filter-aware thresholds: narrowband (Ha, OIII, SII) gets relaxed thresholds
            // because (1) narrowband PSFs are inherently bloated, (2) resolution matters less
            // for diffuse emission targets, (3) long exposures are expensive to discard.
            let canonical = ColorCombineEngine.canonicalFilterName(entry.filter ?? "")
            let trailMult = Self.filterTrailingMultiplier(for: canonical)
            let isNarrowband = trailMult < 0.5  // Ha, OIII, SII, Hbeta, NII

            // Narrowband: relax FWHM threshold (3→6 MADs), trailing (3→6 MADs),
            // combined (3.5→7 MADs), eccentricity (0.5→0.7), severe (5→10 MADs)
            let fwhmThreshold = isNarrowband ? 6.0 : 3.0
            let trailThreshold = isNarrowband ? 6.0 : 3.0
            let combinedThreshold = isNarrowband ? 7.0 : 3.5
            let eccThreshold = isNarrowband ? 0.7 : 0.5
            let eccMetricThreshold = isNarrowband ? 2.5 : 1.5
            let severeThreshold = isNarrowband ? 10.0 : 5.0

            // Compute deviation from baseline for each metric
            var fwhmDev = 0.0
            var trailDev = 0.0
            let ecc = entry.computedEccentricity ?? 0
            var flags: [String] = []

            if let fwhm = entry.computedFWHM ?? entry.fwhm {
                fwhmDev = max(0, (fwhm - refFWHM) / refFWHMDev)
                if fwhmDev > fwhmThreshold {
                    flags.append(String(format: "FWHM %.1f far above historical %.1f (%.1f MADs)",
                                       fwhm, refFWHM, fwhmDev))
                }
            }

            if let trail = entry.trailingScore,
               let refTrail = baselineTrailing, let refTrailDev = baselineTrailingStdDev {
                let rawTrailDev = max(0, (trail - refTrail) / refTrailDev)
                // Scale trailing deviation by filter multiplier: narrowband (0.3) trailing
                // is inherently noisier (fewer well-resolved stars, bloated PSFs) and the
                // historical baseline is typically dominated by broadband data. Same
                // principle as the filter-aware trailing penalty in Stage 2 scoring.
                trailDev = rawTrailDev * trailMult
                if trailDev > trailThreshold {
                    flags.append(String(format: "trailing %.2f far above historical %.2f (%.1f MADs, ×%.1f filter)",
                                       trail, refTrail, rawTrailDev, trailMult))
                }
            }

            // Combined deviation: catches frames where FWHM + trailing are both
            // moderately elevated but neither alone reaches the threshold. Mount jump frames
            // typically show both degraded FWHM AND trailing — the combination is
            // distinctive even when individual metrics stay below the single-metric threshold.
            let combinedDev = fwhmDev + trailDev
            if combinedDev > combinedThreshold && fwhmDev > 1.0 && trailDev > 1.0 {
                flags.append(String(format: "combined FWHM+trailing deviation %.1f (FWHM %.1f + trail %.1f MADs)",
                                   combinedDev, fwhmDev, trailDev))
            }

            // Eccentricity as evidence amplifier: high elongation combined with
            // ANY elevated metric is a strong tracking failure signal.
            if ecc > eccThreshold && (fwhmDev > eccMetricThreshold || trailDev > eccMetricThreshold) {
                flags.append(String(format: "eccentricity %.2f + elevated metrics (tracking failure)", ecc))
            }

            // Per-frame diagnostic: log all non-garbage frames with any deviation > 1.0
            if fwhmDev > 1.0 || trailDev > 1.0 || ecc > 0.4 {
                let fname = entry.url.lastPathComponent
                diagLog(String(format: "  %@ fwhmDev=%.2f trailDev=%.2f ecc=%.2f combined=%.2f flags=%d chain=%.2f nb=%d",
                               fname, fwhmDev, trailDev, ecc, combinedDev,
                               flags.count, entry.starChainFraction ?? -1, isNarrowband ? 1 : 0))
            }

            guard !flags.isEmpty else { continue }

            // Severe = any single metric far above baseline
            let isSevere = fwhmDev > severeThreshold || trailDev > severeThreshold

            // Very high eccentricity (>0.7) is auto-sufficient: normal optics produce
            // ecc 0.3-0.5 max (RASA f/2.2 at field edges), normal seeing < 0.3.
            // Only tracking failures reach 0.7+. Combined with any metric elevation
            // (already guaranteed by the ecc flag check above), this is unambiguous.
            let highEccAutoSufficient = ecc > 0.7 && flags.contains(where: { $0.contains("eccentricity") })

            // Demotion criteria:
            // 1) Two+ independent flags (any combination)
            // 2) Single severe flag (far above baseline)
            // 3) Very high eccentricity (>0.7) with elevated FWHM/trailing
            // The combined deviation flag counts as a flag on its own since it
            // represents clear multi-metric degradation.
            guard flags.count >= 2 || isSevere || highEccAutoSufficient else {
                bd.historicalBaselineReasons = flags
                result[entry.url] = bd
                continue
            }

            // Demote to trash (skip frames already trash)
            guard bd.tier != .trash else { continue }

            var demoted = QualityBreakdown(
                tier: .trash,
                combinedZScore: bd.combinedZScore,
                starsZ: bd.starsZ, fwhmZ: bd.fwhmZ, hfrZ: bd.hfrZ,
                noiseZ: bd.noiseZ, trailingZ: bd.trailingZ,
                psfFluxZ: bd.psfFluxZ,
                snrContribution: nil,
                snrSquared: bd.snrSquared,
                garbageReasons: [],
                isLockedKeep: false,
                reasoningText: "Historical baseline: \(flags.joined(separator: ", "))",
                filterTrailingMultiplier: bd.filterTrailingMultiplier
            )
            demoted.historicalBaselineReasons = flags
            result[entry.url] = demoted
            demotedCount += 1
        }
        diagLog("Stage 1.5b: demoted \(demotedCount)/\(entries.count) frames")
    }

    // MARK: - Session-Wide Sanity Check (Stage 1.5)

    /// Cross-group comparison: demote frames that are dramatically worse than the
    /// session norm across ALL groups with the same object and exposure.
    /// Only demotes — never promotes. isLockedKeep and community-locked frames are immune.
    private static func sessionSanityCheck(
        entries: [ImageEntry],
        result: inout [URL: QualityBreakdown]
    ) {
        // Build session pools: group by object+exposure (ignoring filter, night, AND focal length).
        // Session sanity deliberately pools across setups: if January RC12 frames at 2455mm are
        // all garbage but March RC12red08 frames at 1964mm are good, the cross-setup comparison
        // catches the bad night. Without this, uniformly bad FL-specific groups normalize via
        // z-scores and escape detection entirely.
        // Note: GroupKey includes FL (separate scoring groups), but PoolKey does NOT (cross-check).
        struct PoolKey: Hashable {
            let target: String
            let exposure: Int
        }
        var pools: [PoolKey: [Int]] = [:]
        for (i, entry) in entries.enumerated() {
            let key = PoolKey(
                target: entry.canonicalTarget ?? TargetCatalog.canonicalName(entry.target ?? ""),
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

            // Only run cross-group sanity when pool spans multiple nights.
            // Single-night sessions with multiple filters (e.g. H + OIII) have legitimate
            // FWHM differences between filters — that's optics, not a bad night.
            // Session sanity is designed to catch uniformly bad NIGHTS, not filter differences.
            let distinctNights = Set(indices.compactMap { entries[$0].observingNight })
            guard distinctNights.count >= 2 else { continue }

            // Detect plate-scale variation across the pool. When the pool mixes
            // configurations at different plate scales — e.g. the same scope with
            // and without a focal reducer, or two entirely different scopes that
            // both imaged this target — pixel FWHM is NOT a fair comparison across
            // the pool because the same physical seeing produces different pixel
            // FWHM at different arcsec/pixel values. In that case we compare in
            // arcseconds, which is the plate-scale-invariant representation of
            // the seeing disk. Single-plate-scale pools (the common case) are
            // unaffected because the conversion is a uniform multiplier — ratios
            // fwhm/P10 stay identical.
            var poolArcsecScales: [Double] = []
            for i in indices {
                if let aps = entries[i].arcsecPerPixel, aps > 0 {
                    poolArcsecScales.append(aps)
                }
            }
            let poolIsMixedPlateScale: Bool = {
                guard poolArcsecScales.count >= 2 else { return false }
                let minAPS = poolArcsecScales.min() ?? 0
                let maxAPS = poolArcsecScales.max() ?? 0
                // 10% ratio tolerates minor FL-reporting noise but catches real
                // configuration differences (e.g. 0.81× reducer → ~25% change).
                return minAPS > 0 && (maxAPS / minAPS) > 1.10
            }()
            // Require ALL frames in the pool to have plate scale before we can
            // switch to arcsec comparison. A partial switch would compare arcsec
            // values against pixel values, which is worse than the status quo.
            let useArcsecFWHM = poolIsMixedPlateScale && poolArcsecScales.count == indices.count

            // Collect metrics from ALL frames in the pool (across all filters/nights)
            var fwhms: [Double] = []
            var snrs: [Double] = []
            var stars: [Double] = []
            var eccs: [Double] = []
            var trails: [Double] = []

            for i in indices {
                let e = entries[i]
                // Skip Stage 1 garbage from benchmark computation — dome/dark frames
                // would contaminate session benchmarks with unrealistic metrics
                // (17000 hot pixel "stars", FWHM 3, SNR 113)
                if let bd = result[e.url], !bd.garbageReasons.isEmpty { continue }
                if let v = e.computedFWHM ?? e.fwhm {
                    // For mixed-plate-scale pools, compare in arcsec so native
                    // and reduced configurations of the same scope are judged on
                    // physical seeing rather than pixel-scale-biased pixel FWHM.
                    if useArcsecFWHM, let aps = e.arcsecPerPixel, aps > 0 {
                        fwhms.append(v * aps)
                    } else {
                        fwhms.append(v)
                    }
                }
                if let med = e.noiseMedian, let mad = e.noiseMAD, mad > 0 {
                    snrs.append(Double(med / mad))
                }
                if let v = e.computedStarCount { stars.append(Double(v)) }
                if let v = e.computedEccentricity { eccs.append(v) }
                if let v = e.trailingScore { trails.append(v) }
            }

            // Need enough data points for reliable medians
            guard fwhms.count >= 6 else { continue }

            fwhms.sort(); snrs.sort(); stars.sort(); eccs.sort(); trails.sort()
            // Use best-decile benchmarks instead of median to resist contamination
            // from uniformly-bad nights. The best 10% defines what "good" looks like.
            // FWHM/Ecc/Trailing: lower is better → use 10th percentile (P10)
            // SNR/Stars: higher is better → use 90th percentile (P90)
            let fwhmP10 = fwhms[max(0, fwhms.count / 10)]                         // Best 10% FWHM
            let snrP90 = snrs.isEmpty ? 0 : snrs[min(snrs.count - 1, snrs.count * 9 / 10)]  // Best 10% SNR
            let starsP90 = stars.isEmpty ? 0 : stars[min(stars.count - 1, stars.count * 9 / 10)]
            let eccP10 = eccs.isEmpty ? 0 : eccs[max(0, eccs.count / 10)]         // Best 10% Ecc
            let trailP10 = trails.isEmpty ? 0 : trails[max(0, trails.count / 10)] // Best 10% trailing

            // Target-type-aware FWHM threshold scaling.
            // Emission nebulae and IFN are diffuse — FWHM differences matter less.
            // Galaxies and clusters need tight PSFs — keep strict threshold.
            let poolTarget = entries[indices.first ?? 0].target
            let poolTargetType = DeepSkyTargetDatabase.targetType(for: poolTarget)
            let fwhmSanityMultiplier: Double = {
                switch poolTargetType {
                case .emissionNebula, .hiiRegion, .supernovaRemnant, .wolfRayetNebula:
                    return 1.6   // More lenient: 1.6x P10 instead of 1.3x
                case .ifn, .darkNebula, .starFormingRegion:
                    return 1.8   // Even more lenient for diffuse targets
                case .reflectionNebula:
                    return 1.5
                default:
                    return 1.3   // Standard: galaxies, clusters, unknown
                }
            }()
            let severeFwhmMultiplier = fwhmSanityMultiplier + 0.1  // Severe = slightly above normal threshold

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

                // FWHM: frame significantly above session's best-decile → worse seeing.
                // Threshold is target-type-aware: emission nebulae get 1.6x (diffuse, FWHM less critical),
                // galaxies/clusters get 1.3x (resolution critical).
                // When the pool mixes plate scales, both the pool P10 and the per-frame
                // value are in arcseconds — single-plate-scale pools stay in pixels.
                let frameFWHMForPool: Double? = {
                    guard let px = entry.computedFWHM ?? entry.fwhm else { return nil }
                    if useArcsecFWHM, let aps = entry.arcsecPerPixel, aps > 0 {
                        return px * aps
                    }
                    return px
                }()
                if let fwhm = frameFWHMForPool, fwhmP10 > 0 {
                    if fwhm > fwhmP10 * fwhmSanityMultiplier { flags.append("FWHM far above session norm") }
                }
                // SNR: frame < 0.4× the session's best-decile → dramatically lower signal
                if let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0, snrP90 > 3 {
                    let snr = Double(med / mad)
                    if snr < snrP90 * 0.4 { flags.append("SNR far below session norm") }
                }
                // Star count check is skipped on mixed-plate-scale pools because
                // star detection sensitivity varies with plate scale (more pixels
                // per arcsec → more detected stars for the same sky), and the
                // pool P90 would be dominated by the finer-scale frames. Without
                // a clean plate-scale normalization for star count (which would
                // require image area + detection model), skipping is safer than
                // false-flagging the coarser-scale frames.
                if let sc = entry.computedStarCount, starsP90 > 50, !poolIsMixedPlateScale {
                    if Double(sc) < starsP90 * 0.4 { flags.append("star count far below session norm") }
                }
                if let ecc = entry.computedEccentricity, eccP10 > 0.1 {
                    if ecc > eccP10 * 1.5 { flags.append("eccentricity far above session norm") }
                }
                // Trailing: frame significantly above session's best-decile → tracking error
                if let trail = entry.trailingScore, trailP10 >= 0 {
                    if trail > max(trailP10 * 2.0, trailP10 + 0.15) {
                        flags.append("trailing far above session norm")
                    }
                }

                // Severe single-metric outlier: FWHM so far above session P10 that
                // it's unambiguous garbage even without a second flag.
                // This catches L-filter frames where SNR is acceptable (L captures
                // more photons than RGB) but seeing is catastrophically worse.
                // Same arcsec/pixel unit convention as the normal FWHM check above.
                var isSevereOutlier = false
                if let fwhm = frameFWHMForPool, fwhmP10 > 0 {
                    if fwhm > fwhmP10 * severeFwhmMultiplier { isSevereOutlier = true }
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
                    psfFluxZ: bd.psfFluxZ,
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

    /// Practical significance MAD floors per metric.
    /// Prevents z-score amplification of tiny differences in tight sessions.
    /// A human would never reject a frame with FWHM 4.6 when median is 4.5 —
    /// these floors ensure the scoring system agrees.
    /// Only affects Stage 2 z-scores, NOT Stage 1 garbage rules (which use absolute thresholds).
    enum MetricType {
        case fwhm, hfr, starCount, noiseMAD, trailing, psfFlux, generic
    }

    /// Compute FL-aware FWHM practical MAD floor.
    /// At long FL (small plate scale), atmospheric seeing spreads across more pixels,
    /// so the "insignificant difference" threshold is wider in pixels.
    /// Base: 0.30px at 1.0"/px. Scales inversely with plate scale.
    /// Range: [0.20, 0.80] px to prevent extremes.
    static func fwhmMADFloor(arcsecPerPixel: Double?) -> Double {
        guard let scale = arcsecPerPixel, scale > 0 else { return 0.30 }
        // At 1.0"/px (reference): floor = 0.30px
        // At 0.32"/px (RC12 2423mm): floor = 0.30 * (1.0/0.32) = 0.94 → capped at 0.80
        // At 1.25"/px (RASA 620mm): floor = 0.30 * (1.0/1.25) = 0.24 → floored at 0.20
        // At 0.50"/px (EdgeHD 2032mm): floor = 0.30 * (1.0/0.50) = 0.60
        return min(0.80, max(0.20, 0.30 / scale))
    }

    /// Minimum effective MAD per metric. When natural variation is below this threshold,
    /// differences are considered physically insignificant and z-scores are compressed.
    private static func practicalMADFloor(for metric: MetricType, median: Double) -> Double {
        switch metric {
        case .fwhm:      return 0.30      // Default; overridden by FL-aware floor at call site
        case .hfr:       return 0.20      // Same principle as FWHM
        case .starCount: return max(20.0, median * 0.10)  // 10% variation is detection noise
        case .noiseMAD:  return 0.0008    // Measurement precision floor at 5% subsample
        case .trailing:  return 0.04      // Measurement noise from limited star sample (60 stars)
        case .psfFlux:   return max(1.0, median * 0.10)   // 10% flux variation is noise
        case .generic:   return 0.0       // No floor for unknown metrics
        }
    }

    /// Compute z-scores for an array of optional Doubles.
    /// Uses median/MAD instead of mean/stddev for robustness against outliers.
    /// One exceptional frame (superb seeing) won't skew the group statistics and
    /// cause merely-good frames to appear bad.
    /// The 1.4826 factor normalizes MAD to be equivalent to standard deviation
    /// for normal distributions, so existing z-score thresholds remain valid.
    /// Falls back to mean/stddev when MAD=0 (>50% of values identical — rare in
    /// real data but common in synthetic test groups).
    /// The practical MAD floor prevents penalization of insignificant differences.
    /// Optional floorOverride replaces the default practical floor for this metric.
    private static func zscores(values: [Double?], metric: MetricType = .generic, floorOverride: Double? = nil) -> [Double?] {
        let present = values.compactMap { $0 }.sorted()
        guard present.count >= 2 else {
            return Array(repeating: nil, count: values.count)
        }

        let median = present[present.count / 2]
        let deviations = present.map { Swift.abs($0 - median) }.sorted()
        let rawMAD = deviations[deviations.count / 2] * 1.4826  // normalized MAD → σ estimate

        // Apply practical significance floor: compress z-scores when variation
        // is below the threshold of physical significance for this metric.
        let floor = floorOverride ?? practicalMADFloor(for: metric, median: median)
        let effectiveMAD = max(rawMAD, floor)

        if effectiveMAD > 0 {
            return values.map { val -> Double? in
                guard let v = val else { return nil }
                return (v - median) / effectiveMAD
            }
        }

        // MAD = 0 AND floor = 0 (generic metric): Fall back to mean/stddev which
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
        fwhmZ: Double?, starsZ: Double?, psfFluxZ: Double?, noiseZ: Double?, trailingZ: Double?,
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
        // For stars/psfFlux: raw z < 0 means WORSE (fewer/weaker = worse)
        let fwhmPenalty: Double = fwhmZ ?? 0
        let noisePenalty: Double = noiseZ ?? 0
        let starsPenalty: Double = -(starsZ ?? 0)
        let psfFluxPenalty: Double = -(psfFluxZ ?? 0)
        let trailingPenalty: Double = trailingZ ?? 0

        var penalties: [(String, Double)] = []
        if fwhmPenalty > 0.5     { penalties.append(("FWHM", fwhmPenalty)) }
        if noisePenalty > 0.5    { penalties.append(("Noise", noisePenalty)) }
        if starsPenalty > 0.5    { penalties.append(("Stars", starsPenalty)) }
        if psfFluxPenalty > 0.5  { penalties.append(("PSF Flux", psfFluxPenalty)) }
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
                case "PSF Flux":
                    parts.append("Low total stellar signal (PSF flux)")
                default: break
                }

                // Secondary penalty — use correct wording per metric direction
                for penalty in sorted.dropFirst().prefix(1) {
                    switch penalty.0 {
                    case "Stars":
                        parts.append("star count also below average")
                    case "PSF Flux":
                        parts.append("PSF flux also below average")
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
    let filter:      String
    let object:      String
    let exposure:    Int
    let focalLength: Int     // Rounded FL in mm — prevents cross-setup comparison
    let night:       String? // observingNight for multi-night sessions, nil for single-night

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
    }
}
