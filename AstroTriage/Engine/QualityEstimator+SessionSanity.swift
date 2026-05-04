// Stage 1.5 session-wide sanity check for QualityEstimator.
// Cross-group comparison: demote frames that are dramatically worse than
// the session norm across all groups with the same object and exposure.
// Only demotes — never promotes; isLockedKeep + community-locked frames
// are immune.
//
// Split out of QualityEstimator.swift to keep the main scoring entry
// point closer to its public API. Pure mechanical move — no logic
// changes. See QualityEstimator+Helpers.swift for the kAlgorithmVersion
// bump rationale.
import Foundation

extension QualityEstimator {
    // MARK: - Session-Wide Sanity Check (Stage 1.5)

    /// Cross-group comparison: demote frames that are dramatically worse than the
    /// session norm across ALL groups with the same object and exposure.
    /// Only demotes — never promotes. isLockedKeep and community-locked frames are immune.
    static func sessionSanityCheck(
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
            // Index note: fwhms.count / 10 collapses to 0 (minimum) for count < 10
            // and to floor-n/10 elsewhere. Strictly a "best sample" estimate at small
            // counts, not mathematical P10. Empirical check on the 4540-frame curated
            // set (2026-04-18) showed switching to interpolated P10 produced tiny
            // deltas (median 0.02px FWHM) with no clear accuracy gain. Kept as-is.
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

                // Demote criterion: require 2+ independent flags.
                //
                // Earlier versions also fired on a single flag when FWHM exceeded
                // fwhmSanityMultiplier + 0.1 (the "severe single-FWHM-outlier" path).
                // Empirical validation on a 4540-frame curated dataset (2026-04-18)
                // showed that path uniquely triggered on frames where FWHM was the
                // ONLY flag; precision on those was ~34% and removing it netted +32
                // correctly-classified frames (33 TP lost / 65 FP avoided). Frames
                // with catastrophic seeing that are genuinely bad almost always fail
                // another metric too, so the 2-flag rule catches them anyway.
                guard flags.count >= 2 else { continue }

                // 2+ session sanity flags = unambiguous garbage.
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
}
