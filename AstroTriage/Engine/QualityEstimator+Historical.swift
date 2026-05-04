// Historical context for QualityEstimator — annotates per-frame z-scores
// against the accumulated baseline from previous sessions, and the
// Stage 1.5b cross-session sanity check that demotes uniformly bad
// sessions where the in-session cross-group comparison can't help
// (because all groups in the current session are equally bad).
//
// Split out of QualityEstimator.swift to keep the main scoring entry
// point closer to its public API. Pure mechanical move — no logic
// changes. See QualityEstimator+Helpers.swift for the kAlgorithmVersion
// bump rationale.
import Foundation

extension QualityEstimator {
    // MARK: - Historical Annotation

    /// Compute historical z-scores by comparing each frame's metrics against
    /// the accumulated baseline from all previous sessions with the same setup.
    static func annotateHistorical(
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
    static func normalCDF(_ x: Double) -> Double {
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
    static func historicalBaselineCheck(
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
            // Data(_:utf8) is non-failing — Swift String guarantees a valid UTF-8
            // representation, unlike `String.data(using: .utf8)` which is Optional.
            let bytes = Data(line.utf8)
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(bytes); fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: bytes)
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
}
