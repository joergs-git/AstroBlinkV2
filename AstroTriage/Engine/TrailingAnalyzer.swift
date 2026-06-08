// v4.2.0 — Star Trailing Detection via Orientation Consensus
//
// Core insight: tracking errors cause ALL stars to elongate in the SAME direction.
// Optical aberrations (coma, astigmatism) have POSITION-DEPENDENT elongation.
// By checking whether star position angles (PAs) agree, we distinguish tracking
// errors from normal optical characteristics — the strongest possible signal.
//
// Focal-length-adaptive baseline: short FL optics naturally produce more optical
// elongation (coma, field curvature). We model the expected "normal" eccentricity
// as a function of focal length and only flag EXCESS elongation as trailing.
//
// Unique approach: no other astrophotography tool uses orientation consensus
// for automated quality scoring. PixInsight SubframeSelector, Siril, APP, and
// MaximDL all use global thresholds on raw eccentricity.

import Foundation

// Result of trailing analysis for one image
struct TrailingAnalysis: Hashable {
    let trailingScore: Double      // 0 = no trailing, 1 = severe trailing
    let consensusPA: Double?       // Direction of trailing [0..180) degrees, nil if no consensus
    let consensusFraction: Double  // Fraction of stars agreeing on PA direction [0..1]
    let medianAxisRatio: Double    // Median minor/major across measured stars [0..1], 1 = round
    let medianEccentricity: Double // Median ecc for backward compatibility
}

enum TrailingAnalyzer {

    // Minimum stars with valid PA to attempt consensus analysis
    private static let minStarsForConsensus = 5

    // PA tolerance for consensus: stars within this range of the mean PA count as "agreeing"
    private static let consensusToleranceDeg = 20.0

    // Axis ratio threshold: stars rounder than this are excluded from consensus analysis
    // (perfectly round stars have random PA and would dilute the signal)
    private static let minElongationForConsensus = 0.85  // axisRatio < 0.85 means some elongation

    /// Analyze star trailing from per-star shape measurements.
    ///
    /// - Parameters:
    ///   - starDetails: Per-star eccentricity, PA, and axis ratio from StarMetricsCalculator
    ///   - focalLength: From FOCALLEN header (mm), nil if not available
    ///   - pixelSizeMicrons: From XPIXSZ header, nil if not available
    /// - Returns: TrailingAnalysis, or nil if insufficient data
    static func analyze(
        starDetails: [StarDetail],
        focalLength: Double?,
        pixelSizeMicrons: Double?
    ) -> TrailingAnalysis? {
        guard starDetails.count >= 3 else { return nil }

        // Compute median eccentricity and axis ratio across all measured stars
        let allEcc = starDetails.map { $0.eccentricity }
        let allAR = starDetails.compactMap { $0.axisRatio }
        let medianEcc = sortedMedian(allEcc)
        let medianAR = sortedMedian(allAR)

        // Filter to stars with measurable elongation (round stars have random PA)
        let elongated = starDetails.filter {
            $0.positionAngle != nil && ($0.axisRatio ?? 1.0) < minElongationForConsensus
        }

        // If fewer than minStarsForConsensus are elongated, stars are mostly round → no trailing
        guard elongated.count >= minStarsForConsensus else {
            return TrailingAnalysis(
                trailingScore: 0,
                consensusPA: nil,
                consensusFraction: 0,
                medianAxisRatio: medianAR,
                medianEccentricity: medianEcc
            )
        }

        // ── Circular statistics on position angles ──
        // PA is in [0..180), a half-circle. To compute circular mean, use the doubled-angle
        // trick: map PA → 2×PA (range 0..360), compute standard circular mean, then halve.
        let angles = elongated.compactMap { $0.positionAngle }
        let doubled = angles.map { $0 * 2.0 * .pi / 180.0 }  // Convert to radians, doubled

        let sumSin = doubled.map { sin($0) }.reduce(0, +)
        let sumCos = doubled.map { cos($0) }.reduce(0, +)
        let n = Double(doubled.count)

        // Resultant length R: 0 = uniformly distributed (random), 1 = all same direction
        let R = ((sumSin * sumSin + sumCos * sumCos).squareRoot()) / n

        // Circular mean PA (halve back from doubled angle)
        var meanDoubled = atan2(sumSin / n, sumCos / n)
        if meanDoubled < 0 { meanDoubled += 2.0 * .pi }
        let consensusPA = meanDoubled * 0.5 * 180.0 / .pi

        // Count stars within tolerance of consensus PA
        let agreeing = angles.filter { angleDiff180($0, consensusPA) < consensusToleranceDeg }.count
        let consensusFraction = Double(agreeing) / Double(angles.count)

        // ── Focal-length-adaptive baseline ──
        // Expected "normal" eccentricity varies by optical setup:
        //   Short FL / fast optics → more coma, field curvature → higher baseline ecc
        //   Long FL / slow optics → tighter PSF → lower baseline ecc
        //
        // Empirical model from 4-setup test data:
        //   468mm (85mm f/5.5):  good ecc ~0.65 → baseline ~0.52
        //   620mm (RASA f/2.2):  good ecc ~0.58 → baseline ~0.45
        //   904mm (140mm f/6.5): good ecc ~0.28 → baseline ~0.30
        //   2423mm (RC12 f/8):   good ecc ~0.22 → baseline ~0.23
        //
        // Model: baseline = 0.8 / sqrt(focalLength / 200)
        // Clamped to [0.15, 0.70] for safety
        let baselineEcc: Double
        if let fl = focalLength, fl > 0 {
            baselineEcc = min(0.70, max(0.15, 0.8 / (fl / 200.0).squareRoot()))
        } else {
            // Conservative default when no focal length info available
            baselineEcc = 0.40
        }

        // How much worse than baseline? Normalized to [0..1]
        //
        // NOTE (v31): an earlier draft dropped the baseline to 0.20 under strong consensus,
        // on the theory that high consensus proves systematic trailing the lenient short-FL
        // baseline should not excuse. Validation on the real 85er M101 set (FL 468mm) refuted
        // this: GOOD frames there naturally sit at median ecc ~0.5–0.6 with consensus
        // 0.55–0.89 (mild systematic elongation from the fast f/5.5 optics + AM5 periodic
        // error is present in EVERY frame, good and bad). Dropping the baseline flagged those
        // good frames as trailing. The real defect was the MEASUREMENT collapse (severe trails
        // read as ecc ~0.10 — fixed in StarMetricsCalculator), not the baseline: once measured
        // correctly, true trails sit at ecc ~0.95 / FWHM ~9 and clear the 0.52 baseline by a
        // wide margin while good frames (ecc ~0.55) stay well below. So the FL baseline is
        // kept as-is — it is correctly calibrated to this scope's natural elongation.
        let excessEcc = max(0, medianEcc - baselineEcc) / max(1.0 - baselineEcc, 0.01)

        // ── Trailing score: combines elongation excess with consensus evidence ──
        // Strong consensus (R > 0.7, fraction > 0.5) = definitely tracking error → boost score
        // Weak consensus = might be optical aberration → reduce score
        let consensusMultiplier: Double
        if R > 0.7 && consensusFraction > 0.5 {
            consensusMultiplier = 1.5  // Strong: all stars trail same direction
        } else if R > 0.4 && consensusFraction > 0.3 {
            consensusMultiplier = 1.0  // Moderate evidence
        } else {
            consensusMultiplier = 0.5  // Weak: might be optical, don't penalize heavily
        }

        // Also consider axis ratio directly: very elongated stars (AR < 0.5) are concerning
        // even without strong consensus (e.g., if only a few stars are measurable)
        let axisRatioBoost = medianAR < 0.5 ? 0.2 : 0.0

        let trailingScore = min(1.0, excessEcc * consensusMultiplier + axisRatioBoost)

        return TrailingAnalysis(
            trailingScore: trailingScore,
            consensusPA: consensusFraction > 0.3 ? consensusPA : nil,
            consensusFraction: consensusFraction,
            medianAxisRatio: medianAR,
            medianEccentricity: medianEcc
        )
    }

    // MARK: - Helpers

    /// Angular difference for angles in [0..180) — accounts for wraparound at 180°
    private static func angleDiff180(_ a: Double, _ b: Double) -> Double {
        let d = Swift.abs(a - b)
        return min(d, 180.0 - d)
    }

    /// Sorted median of an array of Doubles
    private static func sortedMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}
