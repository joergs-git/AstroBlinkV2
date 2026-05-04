// Private helpers for QualityEstimator — MAD floors, z-score computation,
// median/MAD utilities, and the human-readable reasoning string builder.
// Split out of QualityEstimator.swift to keep the main scoring entry point
// closer to its public API. Pure mechanical move — no logic changes.
//
// Step "QualityEstimator stages" of Patch 2: kAlgorithmVersion bumped 24 → 25
// per CLAUDE.md policy (every quality-critical file edit bumps even when the
// edit is purely organizational). Synthetic ScoringRegressionTests must stay
// green; the full real-data Golden Set is documented as manual.
//
// Visibility raised from `private static` to `static` (internal) so the main
// file's computeScores call site can reach methods declared in this extension.
import Foundation

extension QualityEstimator {
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
    static func practicalMADFloor(for metric: MetricType, median: Double) -> Double {
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
    static func zscores(values: [Double?], metric: MetricType = .generic, floorOverride: Double? = nil) -> [Double?] {
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
    static func sortedMedian(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }.sorted()
        guard !present.isEmpty else { return nil }
        return present[present.count / 2]
    }

    /// Compute MAD (median absolute deviation) from a median.
    /// Returns RAW MAD — NOT multiplied by 1.4826 for σ-equivalence.
    /// zscores() normalizes separately; callers of this function that want a σ
    /// estimate must multiply themselves. Rule 8 (background anomaly) deliberately
    /// compares against raw MADs.
    static func medianAbsoluteDeviation(_ values: [Double?], median: Double?) -> Double? {
        guard let med = median else { return nil }
        let deviations = values.compactMap { $0 }.map { Swift.abs($0 - med) }.sorted()
        guard !deviations.isEmpty else { return nil }
        return deviations[deviations.count / 2]
    }

    /// Generate human-readable reasoning for why a frame got its tier.
    /// Called during scoring with full group context available.
    /// - filterTrailingMultiplier: severity-adjusted effective multiplier (for threshold logic)
    /// - baseFilterMultiplier: raw filter multiplier (for label text — Ha always shows "narrowband")
    static func generateReasoning(
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
