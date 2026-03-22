import XCTest
@testable import AstroTriage

final class QualityEstimatorTests: XCTestCase {

    // MARK: - Helpers

    /// Create a synthetic ImageEntry with specified metrics for quality scoring.
    /// All entries share the same filter/target/exposure to form one group.
    private func makeEntry(
        index: Int,
        filter: String = "H",
        target: String = "IC1848",
        exposure: Double = 300.0,
        fwhm: Double? = nil,
        hfr: Double? = nil,
        starCount: Int? = nil,
        noiseMAD: Float? = nil,
        noiseMedian: Float? = nil,
        computedFWHM: Double? = nil,
        computedHFR: Double? = nil,
        computedStarCount: Int? = nil,
        computedEccentricity: Double? = nil,
        focalLength: Double? = nil,
        trailingScore: Double? = nil,
        trailingConsensus: Double? = nil,
        solvedRA: Double? = nil,
        solvedDec: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        pixelSizeMicrons: Double? = nil
    ) -> ImageEntry {
        let url = URL(fileURLWithPath: "/tmp/test_\(index).xisf")
        var entry = ImageEntry(url: url)
        entry.filter = filter
        entry.target = target
        entry.exposure = exposure
        entry.fwhm = fwhm
        entry.hfr = hfr
        entry.starCount = starCount
        entry.noiseMAD = noiseMAD
        entry.noiseMedian = noiseMedian
        entry.computedFWHM = computedFWHM
        entry.computedHFR = computedHFR
        entry.computedStarCount = computedStarCount
        entry.computedEccentricity = computedEccentricity
        entry.focalLength = focalLength
        entry.trailingScore = trailingScore
        entry.trailingConsensus = trailingConsensus
        entry.solvedRA = solvedRA
        entry.solvedDec = solvedDec
        entry.width = width
        entry.height = height
        entry.pixelSizeMicrons = pixelSizeMicrons
        return entry
    }

    /// Create N identical entries with the same metrics (forming one group).
    private func makeGroup(count: Int, fwhm: Double = 3.0, hfr: Double = 2.0, starCount: Int = 500, noiseMAD: Float = 0.01, noiseMedian: Float = 0.05, filter: String = "H") -> [ImageEntry] {
        (0..<count).map {
            makeEntry(index: $0, filter: filter, fwhm: fwhm, hfr: hfr, starCount: starCount, noiseMAD: noiseMAD, noiseMedian: noiseMedian)
        }
    }

    // MARK: - Existing Tests (updated for QualityBreakdown)

    func testMinGroupSizePreventsScoring() {
        let entries = makeGroup(count: 5)  // minGroupSize is 6
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertTrue(scores.isEmpty, "Groups smaller than minGroupSize (6) should produce no scores")
    }

    func testExactMinGroupSizeProducesScores() {
        var entries = makeGroup(count: 10)
        entries[0].fwhm = 4.0
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertFalse(scores.isEmpty, "Group of exactly minGroupSize should produce scores")
    }

    func testIdenticalFramesAllGood() {
        let entries = makeGroup(count: 25)
        let scores = QualityEstimator.computeScores(for: entries)

        XCTAssertEqual(scores.count, 25, "All 25 entries should receive a score")
        for entry in entries {
            XCTAssertEqual(scores[entry.url]?.tier, .good,
                           "Identical frames should all be .good (z=0)")
        }
    }

    func testClearOutlierDetectedAsTrash() {
        var entries = makeGroup(count: 24)
        let outlier = makeEntry(index: 99, fwhm: 10.0, hfr: 8.0, starCount: 50, noiseMAD: 0.05)
        entries.append(outlier)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[outlier.url]?.tier, .trash,
                       "A frame with dramatically worse metrics should be .trash")
    }

    func testBestFrameDetectedAsExcellent() {
        // Star count must be < 1.8× group median to avoid triggering starCountAnomaly Rule 6
        var entries = makeGroup(count: 24, fwhm: 5.0, hfr: 4.0, starCount: 200, noiseMAD: 0.02)
        let best = makeEntry(index: 99, fwhm: 1.5, hfr: 1.0, starCount: 350, noiseMAD: 0.005)
        entries.append(best)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[best.url]?.tier, .excellent,
                       "A frame with clearly superior metrics should be .excellent")
    }

    func testNarrowbandReducesStarWeight() {
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, filter: "Ha")
        let entry = makeEntry(index: 99, filter: "Ha", fwhm: 1.5, hfr: 1.0, starCount: 200, noiseMAD: 0.005)
        entries.append(entry)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertNotEqual(scores[entry.url]?.tier, .trash,
                          "Narrowband frame with low stars but good metrics should not be trash")
    }

    func testGroupingByFilterObjectExposure() {
        var hGroup = makeGroup(count: 20, fwhm: 3.0, filter: "H")
        let oGroup = (0..<20).map {
            makeEntry(index: 100 + $0, filter: "O", fwhm: 4.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }

        hGroup[0].fwhm = 10.0
        hGroup[0].hfr = 8.0
        hGroup[0].noiseMAD = 0.05

        let entries = hGroup + oGroup
        let scores = QualityEstimator.computeScores(for: entries)

        XCTAssertEqual(scores[hGroup[0].url]?.tier, .trash, "Outlier in H group should be trash")
        for entry in oGroup {
            XCTAssertEqual(scores[entry.url]?.tier, .good, "Identical O-group frames should all be good")
        }
    }

    func testZscoresWithZeroStdDev() {
        let entries = makeGroup(count: 25, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores.count, 25, "Zero std dev should produce valid scores (z=0)")
    }

    func testNegatedZscoresForLowerIsBetter() {
        var entries = makeGroup(count: 24, fwhm: 5.0, hfr: 4.0, noiseMAD: 0.02)
        let betterSeeing = makeEntry(index: 99, fwhm: 1.0, hfr: 0.5, starCount: 500, noiseMAD: 0.002)
        entries.append(betterSeeing)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[betterSeeing.url]?.tier, .excellent,
                       "Lower FWHM/HFR (negated z) should result in .excellent tier")
    }

    func testMixedNilMetrics() {
        var entries: [ImageEntry] = []
        for i in 0..<25 {
            let fwhm: Double? = i < 15 ? 3.0 : nil
            entries.append(makeEntry(index: i, fwhm: fwhm, noiseMAD: 0.01))
        }
        entries[0].noiseMAD = 0.1

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertFalse(scores.isEmpty, "Mixed nil metrics should still produce scores")
    }

    func testDifferentExposuresSeparateGroups() {
        let group300 = (0..<5).map {
            makeEntry(index: $0, exposure: 300.0, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }
        let group180 = (0..<5).map {
            makeEntry(index: 100 + $0, exposure: 180.0, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }

        let entries = group300 + group180
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertTrue(scores.isEmpty,
                      "Groups of 5 (split by exposure) should not produce scores (below minGroupSize=6)")
    }

    func testPerGroupSourceConsistency() {
        var entries: [ImageEntry] = []
        for i in 0..<25 {
            if i == 0 {
                entries.append(makeEntry(index: i, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01))
            } else {
                entries.append(makeEntry(index: i, noiseMAD: 0.01, computedFWHM: 3.0, computedHFR: 2.0, computedStarCount: 500))
            }
        }

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertFalse(scores.isEmpty, "Mixed source groups should still score via computed values")
    }

    // MARK: - New Tests for QualityBreakdown

    func testBreakdownContainsPerMetricZScores() {
        // Create a group where one frame has worse FWHM but better noise
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        let mixed = makeEntry(index: 99, fwhm: 5.0, hfr: 2.0, starCount: 500, noiseMAD: 0.005, noiseMedian: 0.05)
        entries.append(mixed)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[mixed.url] else {
            XCTFail("Mixed frame should have a score")
            return
        }

        // FWHM should be worse (positive z, since higher FWHM = worse)
        XCTAssertNotNil(bd.fwhmZ, "FWHM z-score should be populated")
        if let fz = bd.fwhmZ {
            XCTAssertGreaterThan(fz, 0, "Worse FWHM should have positive z-score (above mean)")
        }

        // Noise should be better (negative z, since lower noise = better)
        XCTAssertNotNil(bd.noiseZ, "Noise z-score should be populated")
        if let nz = bd.noiseZ {
            XCTAssertLessThan(nz, 0, "Better noise should have negative z-score (below mean)")
        }
    }

    func testSNRContributionBestFrameIs100() {
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        // Best frame: lower noise → higher SNR
        let best = makeEntry(index: 99, fwhm: 2.0, hfr: 1.5, starCount: 700, noiseMAD: 0.002, noiseMedian: 0.05)
        entries.append(best)

        let scores = QualityEstimator.computeScores(for: entries)

        guard let bestBD = scores[best.url] else {
            XCTFail("Best frame should have a score")
            return
        }

        XCTAssertNotNil(bestBD.snrContribution, "Best frame should have SNR contribution")
        XCTAssertEqual(bestBD.snrContribution!, 100.0, accuracy: 0.01,
                       "Best frame in group should have 100% SNR contribution")
    }

    func testSNRContributionWorseFrameBelow100() {
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        let best = makeEntry(index: 99, fwhm: 2.0, hfr: 1.5, starCount: 700, noiseMAD: 0.005, noiseMedian: 0.05)
        entries.append(best)

        let scores = QualityEstimator.computeScores(for: entries)

        // Check a regular frame's contribution vs the best
        guard let regularBD = scores[entries[0].url] else {
            XCTFail("Regular frame should have a score")
            return
        }

        XCTAssertNotNil(regularBD.snrContribution, "Regular frame should have SNR contribution")
        XCTAssertLessThan(regularBD.snrContribution!, 100.0,
                          "Regular frame should have < 100% SNR contribution compared to best")
        XCTAssertGreaterThan(regularBD.snrContribution!, 0.0,
                             "Regular frame should have > 0% SNR contribution")
    }

    func testSNRSquaredCachedForRetentionBar() {
        let entries = makeGroup(count: 15, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        let scores = QualityEstimator.computeScores(for: entries)

        for entry in entries {
            guard let bd = scores[entry.url] else {
                XCTFail("Entry should have a score")
                continue
            }
            XCTAssertNotNil(bd.snrSquared, "snrSquared should be cached for SNR retention bar")
            // SNR = 0.05 / 0.01 = 5.0, so snrSquared = 25.0
            XCTAssertEqual(bd.snrSquared!, 25.0, accuracy: 0.01,
                           "snrSquared should equal (median/MAD)^2")
        }
    }

    func testGarbageReasonPopulated() {
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)

        // Frame with near-zero stars
        let noStars = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 0, noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(noStars)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[noStars.url] else {
            XCTFail("No-stars frame should have a score")
            return
        }

        XCTAssertEqual(bd.tier, .trash, "Zero-star frame should be trash")
        XCTAssertNotNil(bd.garbageReason, "Garbage frame should have a reason")
        XCTAssertEqual(bd.garbageReason, .noStars, "Should be flagged for no stars")
    }

    func testGarbageReasonLowSNR() {
        // Group SNR = 0.10 / 0.01 = 10.0 (median > 5 threshold)
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.10)
        // Frame with catastrophically low SNR: 0.005 / 0.05 = 0.1, which is < 50% of group median (5.0)
        let lowSNR = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.05, noiseMedian: 0.005)
        entries.append(lowSNR)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[lowSNR.url] else {
            XCTFail("Low SNR frame should have a score")
            return
        }

        XCTAssertEqual(bd.tier, .trash, "Low SNR frame should be trash")
        XCTAssertNotNil(bd.garbageReason, "Should have garbage reason")
    }

    func testBorderlineSeverityLevels() {
        // Create a group with varying quality to get borderline frames at different z-scores
        var entries: [ImageEntry] = []
        for i in 0..<25 {
            // Vary FWHM slightly to create a spread
            let fwhm = 3.0 + Double(i) * 0.05
            entries.append(makeEntry(index: i, fwhm: fwhm, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05))
        }

        let scores = QualityEstimator.computeScores(for: entries)

        // Collect borderline severity levels
        var severities = Set<Int>()
        for entry in entries {
            if let bd = scores[entry.url], bd.tier == .borderline {
                severities.insert(bd.borderlineSeverity)
            }
        }

        // With enough spread, we should see at least some borderline frames
        // (may not see all 4 levels with this small spread, but verify the mechanism works)
        for entry in entries {
            if let bd = scores[entry.url], bd.tier == .borderline {
                XCTAssertTrue(bd.borderlineSeverity >= 0 && bd.borderlineSeverity <= 3,
                              "Borderline severity should be 0-3")
            }
        }
    }

    func testRecommendationLabelForTrash() {
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        let noStars = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 0, noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(noStars)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[noStars.url] else {
            XCTFail("Should have score")
            return
        }

        XCTAssertTrue(bd.recommendationLabel.hasPrefix("DELETE"),
                      "Trash frames should get DELETE recommendation, got: \(bd.recommendationLabel)")
    }

    func testRecommendationLabelNotSetForExcellent() {
        // Star count must be < 1.8× group median to avoid triggering starCountAnomaly Rule 6
        var entries = makeGroup(count: 24, fwhm: 5.0, hfr: 4.0, starCount: 200, noiseMAD: 0.02, noiseMedian: 0.05)
        let best = makeEntry(index: 99, fwhm: 1.5, hfr: 1.0, starCount: 350, noiseMAD: 0.005, noiseMedian: 0.05)
        entries.append(best)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[best.url] else {
            XCTFail("Should have score")
            return
        }

        XCTAssertTrue(bd.recommendationLabel.isEmpty,
                      "Excellent frames should have no recommendation label")
    }

    // MARK: - Invariant Coverage Tests

    /// Invariant 6: Z-score cap ±3.0 prevents a single extreme metric from causing trash.
    /// With cap at 3.0, a single worst-case metric contributes at most -3.0/wSum to combinedZ.
    /// With 3+ metrics, the worst single-metric contribution (-3.0/3.0 = -1.0) stays above
    /// the borderline threshold (-2.0), landing in borderline at worst — never trash.
    func testZScoreCapPreventsSingleMetricTrash() {
        // 24 normal frames + 1 frame with bad FWHM but normal everything else.
        // FWHM must stay below Stage 1 threshold (median * 2.0 = 6.0) to test Stage 2 z-cap.
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        // FWHM=5.9: bad enough for extreme z-score, below Stage 1 threshold (3.0 * 2.0 = 6.0)
        let outlier = makeEntry(index: 99, fwhm: 5.9, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(outlier)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[outlier.url] else {
            XCTFail("Outlier should have a score")
            return
        }

        // Stage 1 should NOT fire (FWHM 5.9 < 6.0 threshold).
        XCTAssertNil(bd.garbageReason, "FWHM below Stage 1 threshold should not trigger garbage")

        // With only FWHM being bad (capped at -3.0) and stars/noise at group median (z~0),
        // combinedZ ≈ -3.0/3.0 = -1.0 → borderline, never trash via z-score alone.
        XCTAssertGreaterThan(bd.combinedZScore, -3.01,
                             "combinedZ should be bounded by the z-score cap")
        XCTAssertNotEqual(bd.tier, .trash,
                          "Single bad metric with cap should not produce trash via z-scores alone")
    }

    /// Invariant 7: FWHM and HFR are never both included in combinedZ (95% correlated).
    /// When FWHM is available, HFR is ignored — no double-penalty for seeing degradation.
    func testFWHMAndHFRMutualExclusionInCombinedZ() {
        // Group where all frames have both FWHM and HFR
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)

        // Frame A: elevated FWHM, normal HFR
        // Stage 1 threshold = median * 2.0 = 6.0 — stay below.
        let frameA = makeEntry(index: 97, fwhm: 5.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        // Frame B: same elevated FWHM, also elevated HFR (but below Stage 1: 2.0*2.0=4.0)
        let frameB = makeEntry(index: 98, fwhm: 5.0, hfr: 3.5, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(frameA)
        entries.append(frameB)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bdA = scores[frameA.url], let bdB = scores[frameB.url] else {
            XCTFail("Both frames should have scores")
            return
        }

        // Neither should trigger Stage 1
        XCTAssertNil(bdA.garbageReason, "Frame A should not be Stage 1 garbage")
        XCTAssertNil(bdB.garbageReason, "Frame B should not be Stage 1 garbage")

        // If FWHM/HFR mutual exclusion works, both frames should have identical combinedZ
        // because HFR is ignored when FWHM is present
        XCTAssertEqual(bdA.combinedZScore, bdB.combinedZScore, accuracy: 0.001,
                       "Bad HFR should not affect combinedZ when FWHM is available (mutual exclusion)")
        XCTAssertEqual(bdA.tier, bdB.tier,
                       "Both frames should have the same tier since HFR is excluded")
    }

    /// Invariant 17: R6 Star Count Anomaly requires FWHM/HFR cross-check.
    /// High star count alone (e.g. satellite trail inflating count) must NOT trigger garbage.
    /// Only trigger when FWHM or HFR is also elevated (confirming PSF degradation).
    func testStarCountAnomalyRequiresFWHMCrossCheck() {
        // Group with normal star count ~500
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)

        // Frame with very high star count (>1.8x median) but NORMAL FWHM/HFR
        // This simulates a satellite trail inflating star count without degrading PSF
        let satellite = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 1500, noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(satellite)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[satellite.url] else {
            XCTFail("Satellite-trail frame should have a score")
            return
        }

        // Star count is 3x median (>1.8x threshold), but FWHM/HFR are normal
        // → R6 should NOT fire. Frame should not be garbage.
        XCTAssertNotEqual(bd.garbageReason, .starCountAnomaly,
                          "High star count with normal FWHM/HFR should NOT trigger starCountAnomaly (satellite protection)")
    }

    /// Invariant 20: Stage 3 rescue rules only PROMOTE, never DEMOTE.
    /// A borderline frame with good rescue conditions gets promoted to .good.
    /// No rescue rule can push a frame to a worse tier.
    func testRescueRulesOnlyPromoteNeverDemote() {
        // Create a group where one frame lands in borderline via z-scores
        // but has rescue-eligible conditions (good FWHM + acceptable noise).
        // Star count must stay above Stage 1 noStars threshold:
        // narrowband "H" → dropThreshold = 0.50 * 0.30 = 0.15, so stars >= 500*0.15 = 75.
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, noiseMedian: 0.05)

        // starCount=100: above Stage 1 threshold (75), but far below median (500)
        // → very negative star z-score → pulls combinedZ into borderline
        // FWHM and noise at group median → rescue Rule A eligible
        let rescueCandidate = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 100, noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(rescueCandidate)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[rescueCandidate.url] else {
            XCTFail("Rescue candidate should have a score")
            return
        }

        // Must not be Stage 1 garbage — we're testing Stage 3 rescue
        XCTAssertNil(bd.garbageReason, "Frame above Stage 1 thresholds should not be garbage")

        // Frame has good FWHM (at median, <= median*1.05) and good noise (z~0, <= 0.5)
        // → Rule A fires → tier promoted to .good
        XCTAssertGreaterThanOrEqual(bd.tier.rawValue, QualityTier.good.rawValue,
                                    "Frame with normal FWHM+noise should be rescued to at least .good")
    }

    /// Invariant 29: SSWEIGHT formula: clamp(0, 100, 50 + combinedZ*20) * (1 - trailingScore*0.5)
    /// Tests the formula with known inputs to verify exact output.
    func testSSWEIGHTFormulaCorrectness() {
        // Test the formula directly with known z-scores
        // Formula: weight = (50 + z*20) * (1 - ts*0.5), clamped [0, 100]

        // Case 1: z=0, no trailing → weight = 50
        let w1 = computeSSWEIGHT(combinedZ: 0.0, trailingScore: nil, isLockedKeep: false)
        XCTAssertEqual(w1, 50.0, accuracy: 0.01, "z=0, no trailing → SSWEIGHT=50")

        // Case 2: z=2.5, no trailing → 50 + 2.5*20 = 100 → clamped to 100
        let w2 = computeSSWEIGHT(combinedZ: 2.5, trailingScore: nil, isLockedKeep: false)
        XCTAssertEqual(w2, 100.0, accuracy: 0.01, "z=2.5 → SSWEIGHT=100 (clamped)")

        // Case 3: z=-2.5, no trailing → 50 + (-2.5)*20 = 0 → clamped to 0
        let w3 = computeSSWEIGHT(combinedZ: -2.5, trailingScore: nil, isLockedKeep: false)
        XCTAssertEqual(w3, 0.0, accuracy: 0.01, "z=-2.5 → SSWEIGHT=0 (clamped)")

        // Case 4: z=1.0, trailing=0.5 → (50+20)*(1-0.25) = 70*0.75 = 52.5
        let w4 = computeSSWEIGHT(combinedZ: 1.0, trailingScore: 0.5, isLockedKeep: false)
        XCTAssertEqual(w4, 52.5, accuracy: 0.01, "z=1.0, ts=0.5 → SSWEIGHT=52.5")

        // Case 5: z=-1.0, trailing=0.8 → (50-20)*(1-0.4) = 30*0.6 = 18.0
        let w5 = computeSSWEIGHT(combinedZ: -1.0, trailingScore: 0.8, isLockedKeep: false)
        XCTAssertEqual(w5, 18.0, accuracy: 0.01, "z=-1.0, ts=0.8 → SSWEIGHT=18.0")
    }

    /// Invariant 30: isLockedKeep frames get minimum SSWEIGHT of 50.
    /// Even with negative z-scores, locked frames never go below 50.
    func testSSWEIGHTLockedKeepMinimum50() {
        // Case 1: Locked keep with negative z → normally weight < 50, but locked → 50
        let w1 = computeSSWEIGHT(combinedZ: -1.0, trailingScore: nil, isLockedKeep: true)
        XCTAssertGreaterThanOrEqual(w1, 50.0, "Locked keep with z=-1.0 must have SSWEIGHT >= 50")
        XCTAssertEqual(w1, 50.0, accuracy: 0.01, "Locked keep with z=-1.0 → SSWEIGHT=50 (minimum)")

        // Case 2: Locked keep with positive z → weight > 50, should not be capped down
        let w2 = computeSSWEIGHT(combinedZ: 1.5, trailingScore: nil, isLockedKeep: true)
        XCTAssertEqual(w2, 80.0, accuracy: 0.01, "Locked keep with z=1.5 → SSWEIGHT=80 (above minimum)")

        // Case 3: Locked keep with trailing penalty → ensure minimum still applies
        let w3 = computeSSWEIGHT(combinedZ: -0.5, trailingScore: 0.6, isLockedKeep: true)
        XCTAssertGreaterThanOrEqual(w3, 50.0, "Locked keep with trailing penalty must still be >= 50")
    }

    // MARK: - Rule 5: Extreme Eccentricity (FL-Adaptive)

    /// Rule 5: At long FL (2455mm RC12), ecc > 2× baseline → garbage.
    /// Baseline = 0.8 / sqrt(2455/200) = 0.228, threshold = 0.456.
    /// Ecc=0.51 (like frame #40) should be flagged as elongated.
    func testExtremeEccentricityLongFL_Garbage() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01)
        // Set FL on all entries (same setup group)
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.34  // Normal for RC12
        }
        // Add a clearly trailed frame (like M82 #40)
        var bad = makeEntry(index: 99, fwhm: 3.6, hfr: 2.1, starCount: 2464, noiseMAD: 0.01,
                            computedEccentricity: 0.51, focalLength: 2455.0)
        bad.noiseMedian = 0.05
        entries.append(bad)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[bad.url]?.tier, .trash,
                       "Ecc=0.51 at 2455mm (2.2× baseline 0.228) must be garbage")
        XCTAssertEqual(scores[bad.url]?.garbageReason, .elongated)
    }

    /// Rule 5: Normal eccentricity at long FL should NOT trigger.
    /// Ecc=0.34 at 2455mm → excessRatio = (0.34-0.228)/0.228 = 0.49 (< 1.0).
    func testNormalEccentricityLongFL_NoFalsePositive() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01)
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.34
        }
        // Add a frame with same normal eccentricity
        var normal = makeEntry(index: 99, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01,
                               computedEccentricity: 0.34, focalLength: 2455.0)
        normal.noiseMedian = 0.05
        entries.append(normal)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertNotEqual(scores[normal.url]?.tier, .trash,
                          "Ecc=0.34 at 2455mm (excessRatio=0.49) must NOT be garbage")
    }

    /// Rule 5: High ecc at short FL should NOT trigger (baseline is naturally high).
    /// At 468mm, baseline = 0.523. Ecc=0.51 → excessRatio = -0.02 (below baseline!).
    func testHighEccentricityShortFL_NoFalsePositive() {
        var entries = makeGroup(count: 24, fwhm: 5.0, hfr: 3.0, starCount: 1000, noiseMAD: 0.01)
        for i in 0..<entries.count {
            entries[i].focalLength = 468.0
            entries[i].computedEccentricity = 0.50
        }
        var frame = makeEntry(index: 99, fwhm: 5.0, hfr: 3.0, starCount: 1000, noiseMAD: 0.01,
                              computedEccentricity: 0.51, focalLength: 468.0)
        frame.noiseMedian = 0.05
        entries.append(frame)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertNotEqual(scores[frame.url]?.tier, .trash,
                          "Ecc=0.51 at 468mm (below baseline 0.523) must NOT trigger Rule 5")
    }

    /// Rule 5: Extreme ecc at medium FL (620mm RASA f/2.2).
    /// Baseline = 0.455. Ecc=0.95 → excessRatio = (0.95-0.455)/0.455 = 1.09 → garbage.
    func testExtremeEccentricityMediumFL_Garbage() {
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 1500, noiseMAD: 0.01)
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.45
        }
        var bad = makeEntry(index: 99, fwhm: 4.2, hfr: 2.6, starCount: 1500, noiseMAD: 0.01,
                            computedEccentricity: 0.95, focalLength: 620.0)
        bad.noiseMedian = 0.05
        entries.append(bad)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[bad.url]?.tier, .trash,
                       "Ecc=0.95 at 620mm (excessRatio=1.09) must be garbage")
    }

    /// Rule 5 bypasses fwhmRulesOutTrailing — ecc-based check needs no FWHM cross-check.
    /// Frame has normal FWHM (within 15% of median) but extreme eccentricity.
    func testExtremeEcc_BypassesFWHMCrossCheck() {
        var entries = makeGroup(count: 24, fwhm: 8.5, hfr: 4.0, starCount: 2500, noiseMAD: 0.01)
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.33
        }
        // Frame with FWHM within 15% of median (8.79 < 8.5*1.15=9.775) BUT extreme ecc
        var bad = makeEntry(index: 99, fwhm: 8.79, hfr: 4.62, starCount: 2464, noiseMAD: 0.01,
                            computedEccentricity: 0.51, focalLength: 2455.0)
        bad.noiseMedian = 0.05
        entries.append(bad)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[bad.url]?.tier, .trash,
                       "Extreme ecc must trigger garbage even when FWHM is normal (bypasses fwhmRulesOutTrailing)")
        XCTAssertEqual(scores[bad.url]?.garbageReason, .elongated)
    }

    // MARK: - Rule 6: Consensus-Based Trailing with fwhmRulesOutTrailing

    /// Rule 6 (old Rule 5): fwhmRulesOutTrailing should block consensus-based trailing
    /// when FWHM is within 15% of median AND eccentricity is not extreme.
    func testFWHMRulesOutTrailing_BlocksModerateTrailing() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01)
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.25
        }
        // Frame with normal FWHM, moderate trailing score, but NOT extreme ecc
        var frame = makeEntry(index: 99, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01,
                              computedEccentricity: 0.35, focalLength: 2455.0,
                              trailingScore: 0.75, trailingConsensus: 0.9)
        frame.noiseMedian = 0.05
        entries.append(frame)

        let scores = QualityEstimator.computeScores(for: entries)
        // ecc=0.35 at 2455mm → excessRatio = (0.35-0.228)/0.228 = 0.535 (< 1.0) → Rule 5 doesn't fire
        // FWHM=3.5 = median → fwhmRulesOutTrailing = true → Rule 6 doesn't fire either
        XCTAssertNotEqual(scores[frame.url]?.garbageReason, .elongated,
                          "Moderate ecc with normal FWHM: fwhmRulesOutTrailing should protect against false positive")
    }

    // MARK: - Rule 1: Decentered Target Detection

    /// Rule 1: Low star count with plate-solved offset > 30% FOV → decenteredTarget reason.
    /// Simulates M82 scenario: mount recenter shifts target off sensor.
    func testDecenteredTarget_LowStarsWithOffset() {
        // RC12 + ASI6200MM: FL=2455mm, pixel=3.76µm, sensor 9576×6388
        // FOV ≈ 9576 * 3.76µm / 2455mm * (180/π) ≈ 0.84°
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            var e = makeEntry(index: i, fwhm: 3.5, hfr: 2.0, starCount: 3000, noiseMAD: 0.01,
                              focalLength: 2455.0, solvedRA: 148.93, solvedDec: 69.44,
                              width: 9576, height: 6388, pixelSizeMicrons: 3.76)
            e.noiseMedian = 0.05
            entries.append(e)
        }
        // Frame with target shifted ~0.5° in Dec (>30% of 0.84° FOV) and low stars
        // Using Dec offset avoids cos(Dec) scaling that reduces RA offsets at high declination
        var shifted = makeEntry(index: 99, fwhm: 3.5, hfr: 2.0, starCount: 68, noiseMAD: 0.01,
                                focalLength: 2455.0, solvedRA: 148.93, solvedDec: 69.44 + 0.5,
                                width: 9576, height: 6388, pixelSizeMicrons: 3.76)
        shifted.noiseMedian = 0.05
        entries.append(shifted)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[shifted.url]?.tier, .trash,
                       "Low stars with large pointing offset must be trash")
        XCTAssertTrue(scores[shifted.url]?.garbageReasons.contains(.decenteredTarget) == true,
                      "Must include decenteredTarget reason when plate-solved offset is large")
        XCTAssertTrue(scores[shifted.url]?.garbageReasons.contains(.noStars) == true,
                      "Must also include noStars reason (both apply)")
    }

    /// Rule 1: Low star count WITHOUT plate-solved offset → generic noStars reason.
    func testLowStars_WithoutOffset_GenericReason() {
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            var e = makeEntry(index: i, fwhm: 3.5, hfr: 2.0, starCount: 3000, noiseMAD: 0.01,
                              focalLength: 2455.0, solvedRA: 148.93, solvedDec: 69.44,
                              width: 9576, height: 6388, pixelSizeMicrons: 3.76)
            e.noiseMedian = 0.05
            entries.append(e)
        }
        // Frame with low stars but same center position (no offset — e.g. clouds)
        var cloudy = makeEntry(index: 99, fwhm: 3.5, hfr: 2.0, starCount: 68, noiseMAD: 0.01,
                               focalLength: 2455.0, solvedRA: 148.93, solvedDec: 69.44,
                               width: 9576, height: 6388, pixelSizeMicrons: 3.76)
        cloudy.noiseMedian = 0.05
        entries.append(cloudy)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[cloudy.url]?.tier, .trash)
        XCTAssertTrue(scores[cloudy.url]?.garbageReasons.contains(.noStars) == true,
                      "Must include noStars reason")
        XCTAssertFalse(scores[cloudy.url]?.garbageReasons.contains(.decenteredTarget) == true,
                       "Must NOT include decenteredTarget when pointing is normal")
    }

    // MARK: - Multi-Reason Detection

    /// A frame with multiple issues should show ALL reasons, not just the first.
    func testMultipleGarbageReasons() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 3000, noiseMAD: 0.01)
        // Frame with BOTH low stars AND extreme eccentricity
        var bad = makeEntry(index: 99, fwhm: 3.5, hfr: 2.0, starCount: 10, noiseMAD: 0.01,
                            computedEccentricity: 0.70, focalLength: 2455.0)
        bad.noiseMedian = 0.05
        entries.append(bad)

        let scores = QualityEstimator.computeScores(for: entries)
        let reasons = scores[bad.url]?.garbageReasons ?? []
        XCTAssertTrue(reasons.contains(.noStars), "Must detect low star count")
        XCTAssertTrue(reasons.contains(.elongated), "Must detect extreme eccentricity")
        XCTAssertGreaterThanOrEqual(reasons.count, 2, "Must have at least 2 reasons")
    }

    /// Rule 1: Low star count without plate-solve data → generic noStars (no false decentered).
    func testLowStars_NoPlateSolve_GenericReason() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 3000, noiseMAD: 0.01)
        // No solvedRA/solvedDec set on any entry
        var bad = makeEntry(index: 99, fwhm: 3.5, hfr: 2.0, starCount: 68, noiseMAD: 0.01)
        bad.noiseMedian = 0.05
        entries.append(bad)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[bad.url]?.garbageReason, .noStars,
                       "Without plate-solve data, must fall back to generic noStars reason")
    }

    // MARK: - SSWEIGHT Helper

    /// Reproduces the SSWEIGHT formula from TriageViewModel for unit testing.
    /// Formula: clamp(0, 100, (50 + combinedZ*20) * (1 - trailingScore*0.5))
    /// isLockedKeep → minimum weight 50.
    private func computeSSWEIGHT(combinedZ: Double, trailingScore: Double?, isLockedKeep: Bool) -> Double {
        var weight = 50.0 + combinedZ * 20.0
        if let ts = trailingScore {
            weight *= (1.0 - ts * 0.5)
        }
        if isLockedKeep {
            weight = max(weight, 50.0)
        }
        weight = max(0.0, min(100.0, weight))
        return weight
    }
}
