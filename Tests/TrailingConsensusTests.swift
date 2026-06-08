import XCTest
@testable import AstroTriage

// Regression tests for v31 trailing separation on the 85er M101 set (FL 468mm).
//
// The real defect was a MEASUREMENT collapse (severe trails read as ecc ~0.10 because the
// elliptical PSF fit converged round — fixed in StarMetricsCalculator). The FL baseline
// (0.52 @ 468mm) is correctly calibrated to this scope's NATURAL elongation: validated good
// frames sit at median ecc ~0.5–0.6 (with consensus 0.55–0.89, from fast-optics coma + mount
// periodic error present in every frame), while true trails sit at ecc ~0.95 / FWHM ~9 and
// clear the baseline by a wide margin.
//
// These tests lock the separation: severe trail → high score; natural short-FL elongation,
// optical aberration, round, and clean long-FL → low/zero. (An earlier draft dropped the
// baseline under strong consensus; that flagged the natural-elongation good frames as
// trailing and was reverted — `testNaturalShortFLElongationNotFlagged` guards against it.)
final class TrailingConsensusTests: XCTestCase {

    private func axisRatio(forEcc ecc: Double) -> Double {
        return (1.0 - ecc * ecc).squareRoot()   // axisRatio = √(1 − e²)
    }

    private func star(index i: Int, ecc: Double, pa: Double, ar: Double) -> StarDetail {
        let px: Float = Float(i) * 20.0
        let py: Float = Float(i) * 13.0
        return StarDetail(x: px, y: py,
                          eccentricity: ecc, hfr: 2.0, fwhm: 3.0,
                          positionAngle: pa, axisRatio: ar)
    }

    /// N stars with a realistic eccentricity DISTRIBUTION (ramp around `medianEcc`) and a
    /// tight PA cluster. Models a real trailed frame: only the more-elongated subset
    /// (axisRatio < 0.85 ⇔ ecc > ~0.527) qualifies for the consensus computation, while the
    /// session median ecc stays below the short-FL baseline — exactly the v30 miss.
    private func alignedTrail(count: Int, medianEcc: Double, pa: Double, spread: Double = 0.16) -> [StarDetail] {
        var out: [StarDetail] = []
        for i in 0..<count {
            // linear ramp [medianEcc-spread, medianEcc+spread] → median ≈ medianEcc
            let frac: Double = Double(i) / Double(max(count - 1, 1))
            let ecc: Double = (medianEcc - spread) + 2.0 * spread * frac
            let jitter: Double = (Double(i % 5) - 2.0) * 2.0   // ±4° spread, still clustered
            out.append(star(index: i, ecc: ecc, pa: pa + jitter, ar: axisRatio(forEcc: ecc)))
        }
        return out
    }

    /// N elongated stars with PAs spread across the half-circle (optical aberration).
    private func radialAberration(count: Int, ecc: Double) -> [StarDetail] {
        let ar = axisRatio(forEcc: ecc)
        var out: [StarDetail] = []
        for i in 0..<count {
            let pa: Double = Double(i) / Double(count) * 180.0
            out.append(star(index: i, ecc: ecc, pa: pa, ar: ar))
        }
        return out
    }

    private func roundStars(count: Int) -> [StarDetail] {
        var out: [StarDetail] = []
        for i in 0..<count {
            let pa: Double = Double((i * 37) % 180)
            out.append(star(index: i, ecc: 0.12, pa: pa, ar: 0.99))
        }
        return out
    }

    // FALSE-POSITIVE GUARD: a natural short-FL frame (ecc ~0.55, at/just above the 0.52
    // baseline) WITH strong consensus must NOT be flagged as trailing. This mirrors the real
    // 85er M101 good frames (0007/0083: ecc 0.575, consensus ~0.88) that an earlier
    // baseline-drop wrongly flagged. The score must stay well below the cull range.
    func testNaturalShortFLElongationNotFlagged() {
        let stars = alignedTrail(count: 40, medianEcc: 0.55, pa: 30.0)
        let r = TrailingAnalyzer.analyze(starDetails: stars, focalLength: 468, pixelSizeMicrons: 3.76)
        XCTAssertNotNil(r)
        XCTAssertLessThan(r!.trailingScore, 0.30,
            "Natural short-FL elongation (~0.55, just above the 0.52 baseline) must not score as trailing, even with consensus.")
    }

    // SAFETY: optical aberration (same ecc, but radial/spread PAs) must NOT be flagged.
    func testRadialAberrationStaysLow() {
        let stars = radialAberration(count: 40, ecc: 0.46)
        let r = TrailingAnalyzer.analyze(starDetails: stars, focalLength: 468, pixelSizeMicrons: 3.76)
        XCTAssertNotNil(r)
        XCTAssertLessThan(r!.consensusFraction, 0.5, "Spread PAs → no consensus")
        XCTAssertLessThan(r!.trailingScore, 0.10,
            "Sub-baseline ecc with NO consensus is optical aberration — baseline stays full, score ~0.")
    }

    // SAFETY: clean round frame → too few elongated stars → score 0.
    func testRoundFrameScoresZero() {
        let r = TrailingAnalyzer.analyze(starDetails: roundStars(count: 40), focalLength: 468, pixelSizeMicrons: 3.76)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.trailingScore, 0.0, accuracy: 1e-9)
    }

    // SAFETY: long-FL setup essentially unchanged (baseline 0.23 → min(0.23,0.20)=0.20).
    func testLongFocalLengthCleanStaysZero() {
        let r = TrailingAnalyzer.analyze(starDetails: roundStars(count: 40), focalLength: 2423, pixelSizeMicrons: 3.76)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.trailingScore, 0.0, accuracy: 1e-9)
    }

    // Severe aligned trail (the 0029-0033 case once 2a feeds the true ecc to the analyzer).
    func testSevereAlignedTrailScoresHigh() {
        let stars = alignedTrail(count: 40, medianEcc: 0.85, pa: 120.0, spread: 0.10)
        let r = TrailingAnalyzer.analyze(starDetails: stars, focalLength: 468, pixelSizeMicrons: 3.76)
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r!.trailingScore, 0.7, "Severe unanimous trailing must score high.")
    }

    // SAFETY (validator coverage gap #1): a long-FL frame with elongated, high-consensus
    // stars must still be detected — the min(baselineEcc, 0.20) clamp must not break the
    // strong-consensus path at long focal length (where baselineEcc ≈ 0.23).
    func testLongFLElongatedConsensusStillScores() {
        let stars = alignedTrail(count: 40, medianEcc: 0.45, pa: 90.0)
        let r = TrailingAnalyzer.analyze(starDetails: stars, focalLength: 2423, pixelSizeMicrons: 3.76)
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r!.consensusFraction, 0.7)
        XCTAssertGreaterThan(r!.trailingScore, 0.3,
            "Long-FL systematic trailing well above the 0.23 baseline must score; clamp must not break it.")
    }

    // 2a boundary tests (validator coverage gap #2): the moment-vs-fit override window.
    func testEllipticalFitOverrideBoundaries() {
        // (a) trail-collapse signature: moment elongated, fit round → prefer moment
        XCTAssertTrue(StarMetricsCalculator.ellipticalFitUnderestimatesTrail(momentEcc: 0.83, fitEcc: 0.10))
        // (b) moment below 0.55 gate → trust fit (no override)
        XCTAssertFalse(StarMetricsCalculator.ellipticalFitUnderestimatesTrail(momentEcc: 0.50, fitEcc: 0.10))
        // (c) fit above 0.35 gate (fit already sees elongation) → trust fit
        XCTAssertFalse(StarMetricsCalculator.ellipticalFitUnderestimatesTrail(momentEcc: 0.83, fitEcc: 0.40))
        // (d) both round (clean star) → trust fit, no spurious ecc raise
        XCTAssertFalse(StarMetricsCalculator.ellipticalFitUnderestimatesTrail(momentEcc: 0.15, fitEcc: 0.12))
    }
}
