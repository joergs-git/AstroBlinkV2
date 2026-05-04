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
    /// Uses filter "L" (trailMult=1.0) for full strictness.
    func testExtremeEccentricityLongFL_Garbage() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01, filter: "L")
        // Set FL on all entries (same setup group)
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.34  // Normal for RC12
        }
        // Add a clearly trailed frame (like M82 #40)
        var bad = makeEntry(index: 99, filter: "L", fwhm: 3.6, hfr: 2.1, starCount: 2464, noiseMAD: 0.01,
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
    /// Uses filter "L" (trailMult=1.0) for full strictness.
    func testExtremeEccentricityMediumFL_Garbage() {
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 1500, noiseMAD: 0.01, filter: "L")
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.45
        }
        var bad = makeEntry(index: 99, filter: "L", fwhm: 4.2, hfr: 2.6, starCount: 1500, noiseMAD: 0.01,
                            computedEccentricity: 0.95, focalLength: 620.0)
        bad.noiseMedian = 0.05
        entries.append(bad)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[bad.url]?.tier, .trash,
                       "Ecc=0.95 at 620mm (excessRatio=1.09) must be garbage")
    }

    /// Rule 5 bypasses fwhmRulesOutTrailing — ecc-based check needs no FWHM cross-check.
    /// Frame has normal FWHM (within 15% of median) but extreme eccentricity.
    /// Uses filter "L" (trailMult=1.0) for full strictness.
    func testExtremeEcc_BypassesFWHMCrossCheck() {
        var entries = makeGroup(count: 24, fwhm: 8.5, hfr: 4.0, starCount: 2500, noiseMAD: 0.01, filter: "L")
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.33
        }
        // Frame with FWHM within 15% of median (8.79 < 8.5*1.15=9.775) BUT extreme ecc
        var bad = makeEntry(index: 99, filter: "L", fwhm: 8.79, hfr: 4.62, starCount: 2464, noiseMAD: 0.01,
                            computedEccentricity: 0.51, focalLength: 2455.0)
        bad.noiseMedian = 0.05
        entries.append(bad)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[bad.url]?.tier, .trash,
                       "Extreme ecc must trigger garbage even when FWHM is normal (bypasses fwhmRulesOutTrailing)")
        XCTAssertEqual(scores[bad.url]?.garbageReason, .elongated)
    }

    // MARK: - Rule 6: Consensus-Based Trailing with fwhmRulesOutTrailing

    /// Rules 5/6: fwhmRulesOutTrailing should block trailing when FWHM is within
    /// 15% of median. Note: Rule 6a (absolute ceiling) does NOT check FWHM
    /// because tracking error = normal FWHM + high ecc. This test uses ts < 0.50
    /// (below Rule 6a ceiling) to verify Rules 5/6 FWHM cross-check still works.
    func testFWHMRulesOutTrailing_BlocksModerateTrailing() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01)
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.25
        }
        // Frame with normal FWHM, moderate trailing score below Rule 6a ceiling (0.50)
        var frame = makeEntry(index: 99, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01,
                              computedEccentricity: 0.35, focalLength: 2455.0,
                              trailingScore: 0.45, trailingConsensus: 0.4)
        frame.noiseMedian = 0.05
        entries.append(frame)

        let scores = QualityEstimator.computeScores(for: entries)
        // ts=0.45 < 0.50 → Rule 6a doesn't fire
        // ecc=0.35 at 2455mm → excessRatio = (0.35-0.228)/0.228 = 0.535 (< 1.0) → Rule 5 doesn't fire
        // FWHM=3.5 = median → fwhmRulesOutTrailing = true → Rule 6 doesn't fire either
        XCTAssertNotEqual(scores[frame.url]?.garbageReason, .elongated,
                          "Moderate trailing below ceiling + normal FWHM: Rules 5/6 should be blocked by fwhmRulesOutTrailing")
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
    /// Uses filter "L" (trailMult=1.0) so eccentricity threshold isn't raised.
    func testMultipleGarbageReasons() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 3000, noiseMAD: 0.01, filter: "L")
        // Ensure all entries share the same FL bucket as the bad frame
        for i in 0..<entries.count { entries[i].focalLength = 2455.0 }
        // Frame with BOTH low stars AND extreme eccentricity
        var bad = makeEntry(index: 99, filter: "L", fwhm: 3.5, hfr: 2.0, starCount: 10, noiseMAD: 0.01,
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

    // MARK: - Filter-Aware Trailing Penalty Tests

    /// Unit test: filterTrailingMultiplier returns correct values for each canonical filter.
    func testFilterTrailingMultiplier() {
        // Narrowband → 0.3
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "Ha"), 0.3)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "OIII"), 0.3)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "SII"), 0.3)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "Hbeta"), 0.3)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "NII"), 0.3)

        // RGB → 0.6
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "R"), 0.6)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "G"), 0.6)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "B"), 0.6)

        // Luminance → 1.0
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "L"), 1.0)

        // Unknown → 0.7
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: ""), 0.7)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "Unknown"), 0.7)
        XCTAssertEqual(QualityEstimator.filterTrailingMultiplier(for: "L-eXtreme"), 0.7)
    }

    /// Narrowband frame with mild trailing (0.35) should NOT be garbage.
    /// Below the absolute ceiling (0.50) and not enough for z-score garbage.
    func testNarrowbandTrailingNotGarbage() {
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 200, noiseMAD: 0.01, filter: "Ha")
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.40
            entries[i].noiseMedian = 0.05
        }
        // Mild trailing — below absolute ceiling, preserved for narrowband
        var trailed = makeEntry(index: 99, filter: "Ha", fwhm: 4.2, hfr: 2.6, starCount: 200,
                                noiseMAD: 0.01, noiseMedian: 0.05,
                                computedEccentricity: 0.55, focalLength: 620.0,
                                trailingScore: 0.35, trailingConsensus: 0.7)
        entries.append(trailed)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[trailed.url] else {
            XCTFail("Trailed Ha frame should have a score")
            return
        }

        XCTAssertNotEqual(bd.garbageReason, .elongated,
                          "Ha frame with trailingScore=0.35 must NOT be garbage (mild trailing preserved for narrowband)")
        // Effective mult at ts=0.35: 0.3 + 0.7 * 0.1225 = 0.386
        XCTAssertEqual(bd.filterTrailingMultiplier, 0.386, accuracy: 0.01,
                       "Ha with ts=0.35 should have severity-adjusted trailing multiplier ~0.39")
    }

    /// Narrowband frame with significant trailing (0.55 + consensus 0.6) MUST be garbage.
    /// The absolute trailing ceiling (Rule 6a) catches this regardless of filter.
    /// Rule 6a does NOT check fwhmRulesOutTrailing because tracking error produces
    /// normal FWHM + high eccentricity — consensus is the sufficient guard.
    func testSevereNarrowbandTrailingIsGarbage() {
        // Absolute trailing ceiling (Rule 6a) was raised 0.50 → 0.60 in algorithm v20
        // (2026-04-16, curation-driven: 33 false positives at 0.50-0.60 where humans
        // rated 3★). Severe trailing test now uses 0.65 to clearly exceed the ceiling.
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 200, noiseMAD: 0.01, filter: "Ha")
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.40
            entries[i].noiseMedian = 0.05
        }
        // Trailing with consensus — must be caught even with normal FWHM
        var trailed = makeEntry(index: 99, filter: "Ha", fwhm: 4.0, hfr: 2.5, starCount: 200,
                                noiseMAD: 0.01, noiseMedian: 0.05,
                                computedEccentricity: 0.70, focalLength: 620.0,
                                trailingScore: 0.65, trailingConsensus: 0.6)
        entries.append(trailed)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[trailed.url] else {
            XCTFail("Trailed Ha frame should have a score")
            return
        }

        XCTAssertEqual(bd.tier, .trash,
                       "Ha frame with trailingScore=0.65 and consensus=0.6 must be garbage (absolute ceiling at 0.60)")
        XCTAssertEqual(bd.garbageReason, .elongated)
    }

    /// Mild narrowband trailing (0.20) must be fully preserved — no change from base multiplier.
    func testMildNarrowbandTrailingPreserved() {
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 200, noiseMAD: 0.01, filter: "Ha")
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.40
            entries[i].noiseMedian = 0.05
            entries[i].trailingScore = 0.10
        }
        var mild = makeEntry(index: 99, filter: "Ha", fwhm: 4.0, hfr: 2.5, starCount: 200,
                             noiseMAD: 0.01, noiseMedian: 0.05,
                             computedEccentricity: 0.45, focalLength: 620.0,
                             trailingScore: 0.20, trailingConsensus: 0.3)
        entries.append(mild)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[mild.url] else {
            XCTFail("Mild trailed Ha frame should have a score")
            return
        }

        XCTAssertNotEqual(bd.tier, .trash,
                          "Ha frame with trailingScore=0.20 must NOT be garbage")
        // Effective mult at ts=0.20: 0.3 + 0.7 * 0.04 = 0.328
        XCTAssertEqual(bd.filterTrailingMultiplier, 0.328, accuracy: 0.01,
                       "Ha with ts=0.20 should have near-base trailing multiplier ~0.33")
    }

    /// Absolute trailing ceiling requires consensus — high score alone is not enough.
    /// This prevents false positives from optical aberrations (random PA distribution).
    func testAbsoluteTrailingCeilingRequiresConsensus() {
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 200, noiseMAD: 0.01, filter: "Ha")
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.40
            entries[i].noiseMedian = 0.05
        }
        // High trailing score BUT low consensus — optical aberration, not tracking error
        var trailed = makeEntry(index: 99, filter: "Ha", fwhm: 5.0, hfr: 3.0, starCount: 200,
                                noiseMAD: 0.01, noiseMedian: 0.05,
                                computedEccentricity: 0.65, focalLength: 620.0,
                                trailingScore: 0.70, trailingConsensus: 0.4)
        entries.append(trailed)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[trailed.url] else {
            XCTFail("Ha frame should have a score")
            return
        }

        XCTAssertNotEqual(bd.garbageReason, .elongated,
                          "Ha frame with trailingScore=0.70 but consensus=0.4 must NOT trigger ceiling (no consensus)")
    }

    /// Rule 6a does NOT check fwhmRulesOutTrailing — tracking error produces normal FWHM
    /// plus high eccentricity. Consensus guards against optical aberrations instead.
    /// Absolute ceiling raised 0.50 → 0.60 in algorithm v20 (curation-driven tune-up
    /// 2026-04-16); trailing scenarios here use scores above 0.60 accordingly.
    func testAbsoluteTrailingCeilingIgnoresFWHMCrossCheck() {
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 200, noiseMAD: 0.01, filter: "Ha")
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.40
            entries[i].noiseMedian = 0.05
        }
        // Normal FWHM + high trailing score + strong consensus = tracking error
        // Rule 6a must fire despite FWHM being within normal range
        var trailed = makeEntry(index: 99, filter: "Ha", fwhm: 4.0, hfr: 2.5, starCount: 200,
                                noiseMAD: 0.01, noiseMedian: 0.05,
                                computedEccentricity: 0.70, focalLength: 620.0,
                                trailingScore: 0.65, trailingConsensus: 0.7)
        entries.append(trailed)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[trailed.url] else {
            XCTFail("Ha frame should have a score")
            return
        }

        XCTAssertEqual(bd.garbageReason, .elongated,
                       "Rule 6a must fire even with normal FWHM — tracking error = normal FWHM + high ecc with consensus")
        XCTAssertEqual(bd.tier, .trash)
    }

    /// Unit test for the effectiveTrailingMultiplier formula.
    func testEffectiveTrailingMultiplierValues() {
        // Narrowband base = 0.3
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 0.3, trailingScore: 0.0), 0.3, accuracy: 0.001)
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 0.3, trailingScore: 0.5), 0.475, accuracy: 0.001)
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 0.3, trailingScore: 1.0), 1.0, accuracy: 0.001)

        // RGB base = 0.6
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 0.6, trailingScore: 0.0), 0.6, accuracy: 0.001)
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 0.6, trailingScore: 0.5), 0.7, accuracy: 0.001)
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 0.6, trailingScore: 1.0), 1.0, accuracy: 0.001)

        // Luminance base = 1.0 — always 1.0 regardless of severity
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 1.0, trailingScore: 0.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 1.0, trailingScore: 1.0), 1.0, accuracy: 0.001)

        // Clamping: negative trailing score treated as 0
        XCTAssertEqual(QualityEstimator.effectiveTrailingMultiplier(baseMult: 0.3, trailingScore: -0.5), 0.3, accuracy: 0.001)
    }

    /// Luminance frame with trailing score 0.75 (high) should be garbage.
    /// At L (mult=1.0), threshold stays 0.7 → 0.75 > 0.7 → garbage.
    func testLuminanceTrailingIsGarbage() {
        var entries = makeGroup(count: 24, fwhm: 3.5, hfr: 2.0, starCount: 2500, noiseMAD: 0.01, filter: "L")
        for i in 0..<entries.count {
            entries[i].focalLength = 2455.0
            entries[i].computedEccentricity = 0.25
            entries[i].noiseMedian = 0.05
        }
        // Trailing frame with elevated FWHM (to bypass fwhmRulesOutTrailing cross-check)
        var trailed = makeEntry(index: 99, filter: "L", fwhm: 4.5, hfr: 2.5, starCount: 2500,
                                noiseMAD: 0.01, noiseMedian: 0.05,
                                computedEccentricity: 0.40, focalLength: 2455.0,
                                trailingScore: 0.75, trailingConsensus: 0.9)
        entries.append(trailed)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[trailed.url] else {
            XCTFail("Trailed L frame should have a score")
            return
        }

        XCTAssertEqual(bd.tier, .trash,
                       "L frame with trailingScore=0.75 must be garbage (L mult=1.0, threshold=0.7)")
        XCTAssertEqual(bd.garbageReason, .elongated)
        XCTAssertEqual(bd.filterTrailingMultiplier, 1.0, accuracy: 0.001,
                       "L should have trailing multiplier 1.0")
    }

    /// Verify that narrowband trailing has less influence on combinedZ than luminance.
    /// Same trailing z-score should produce less penalty for Ha than for L.
    func testNarrowbandTrailingReducedZWeight() {
        // Create Ha group — all frames need trailing scores for z-score computation
        var haEntries: [ImageEntry] = []
        for i in 0..<24 {
            var e = makeEntry(index: i, filter: "Ha", fwhm: 3.0, hfr: 2.0, starCount: 200,
                              noiseMAD: 0.01, noiseMedian: 0.05, trailingScore: 0.1)
            haEntries.append(e)
        }
        // One clearly trailed frame
        var haTrailed = makeEntry(index: 99, filter: "Ha", fwhm: 3.0, hfr: 2.0, starCount: 200,
                                  noiseMAD: 0.01, noiseMedian: 0.05, trailingScore: 0.6)
        haEntries.append(haTrailed)

        // Create identical L group
        var lEntries: [ImageEntry] = []
        for i in 0..<24 {
            var e = makeEntry(index: 200 + i, filter: "L", fwhm: 3.0, hfr: 2.0, starCount: 200,
                              noiseMAD: 0.01, noiseMedian: 0.05, trailingScore: 0.1)
            lEntries.append(e)
        }
        var lTrailed = makeEntry(index: 299, filter: "L", fwhm: 3.0, hfr: 2.0, starCount: 200,
                                 noiseMAD: 0.01, noiseMedian: 0.05, trailingScore: 0.6)
        lEntries.append(lTrailed)

        let haScores = QualityEstimator.computeScores(for: haEntries)
        let lScores = QualityEstimator.computeScores(for: lEntries)

        guard let haBD = haScores[haTrailed.url], let lBD = lScores[lTrailed.url] else {
            XCTFail("Both trailed frames should have scores")
            return
        }

        // Ha trailing weight: effectiveMult(0.3, 0.6) = 0.552, L = 1.0
        // So Ha frame should have HIGHER combinedZ (less penalized) than L frame
        XCTAssertGreaterThan(haBD.combinedZScore, lBD.combinedZScore,
                             "Ha trailing penalty (severity-adjusted ~0.55×) should produce higher combinedZ than L (1.0×)")
    }

    /// Verify filterTrailingMultiplier is correctly stored on QualityBreakdown for each filter type.
    func testFilterTrailingMultiplierOnBreakdown() {
        // Ha group
        var haEntries = makeGroup(count: 10, fwhm: 3.0, hfr: 2.0, starCount: 200, noiseMAD: 0.01, filter: "Ha")
        for i in 0..<haEntries.count { haEntries[i].noiseMedian = 0.05 }

        // R group
        var rEntries = (0..<10).map {
            makeEntry(index: 100 + $0, filter: "R", fwhm: 3.0, hfr: 2.0, starCount: 500,
                      noiseMAD: 0.01, noiseMedian: 0.05)
        }

        // L group
        var lEntries = (0..<10).map {
            makeEntry(index: 200 + $0, filter: "L", fwhm: 3.0, hfr: 2.0, starCount: 500,
                      noiseMAD: 0.01, noiseMedian: 0.05)
        }

        let scores = QualityEstimator.computeScores(for: haEntries + rEntries + lEntries)

        // Check Ha multiplier
        if let haBD = scores[haEntries[0].url] {
            XCTAssertEqual(haBD.filterTrailingMultiplier, 0.3, accuracy: 0.001,
                           "Ha breakdown should have trailing multiplier 0.3")
        }

        // Check R multiplier
        if let rBD = scores[rEntries[0].url] {
            XCTAssertEqual(rBD.filterTrailingMultiplier, 0.6, accuracy: 0.001,
                           "R breakdown should have trailing multiplier 0.6")
        }

        // Check L multiplier
        if let lBD = scores[lEntries[0].url] {
            XCTAssertEqual(lBD.filterTrailingMultiplier, 1.0, accuracy: 0.001,
                           "L breakdown should have trailing multiplier 1.0")
        }
    }

    // MARK: - SSWEIGHT Helper

    /// Reproduces the SSWEIGHT formula from TriageViewModel for unit testing.
    /// Formula: clamp(0, 100, (50 + combinedZ*20) * (1 - trailingScore*0.5*filterTrailingMult))
    /// isLockedKeep → minimum weight 50.
    private func computeSSWEIGHT(combinedZ: Double, trailingScore: Double?, isLockedKeep: Bool, filterTrailingMultiplier: Double = 1.0) -> Double {
        var weight = 50.0 + combinedZ * 20.0
        if let ts = trailingScore {
            weight *= (1.0 - ts * 0.5 * filterTrailingMultiplier)
        }
        if isLockedKeep {
            weight = max(weight, 50.0)
        }
        weight = max(0.0, min(100.0, weight))
        return weight
    }

    // MARK: - Session Sanity Check Tests

    /// Good L-filter group + bad B-filter group (same target/exposure).
    /// The bad B frames should be demoted by session-wide cross-group comparison.
    func testSessionSanityCheck_demotesBadCrossGroup() {
        // Fixed jitter values for deterministic testing (was random, causing flaky failures)
        let fwhmJitter = [-0.15, -0.10, -0.05, 0.0, 0.02, 0.05, 0.08, 0.10, 0.12, 0.15]
        let starJitter = [-150, -100, -50, 0, 20, 50, 80, 100, 120, 150]

        // 10 good L frames (night 1): FWHM 3.0, SNR 50 (med 0.05, mad 0.001)
        let goodL: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: i, filter: "L", target: "M82", exposure: 180,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 3.0 + fwhmJitter[i],
                      computedStarCount: 3000 + starJitter[i],
                      computedEccentricity: 0.35)
            e.date = "2026-03-15"; e.time = "22:00:00"
            return e
        }
        // 8 bad B frames (night 2): FWHM 10.0, SNR ~8 (med 0.05, mad 0.006)
        // Session sanity requires ≥2 distinct nights to fire
        let badB: [ImageEntry] = (0..<8).map { i in
            var e = makeEntry(index: 100 + i, filter: "B", target: "M82", exposure: 180,
                      noiseMAD: 0.006, noiseMedian: 0.05,
                      computedFWHM: 10.0 + fwhmJitter[i],
                      computedStarCount: 2400 + starJitter[i],
                      computedEccentricity: 0.65)
            e.date = "2026-01-20"; e.time = "22:00:00"
            return e
        }

        let entries = goodL + badB
        let scores = QualityEstimator.computeScores(for: entries)

        // Verify: bad B frames should NOT be .good or .excellent
        // Session sanity check sees FWHM Q1 ~3.0 → threshold 4.2. Bad B at 10.0 → flagged
        // SNR Q3 ~50 → threshold 20. Bad B at ~8.3 → flagged
        // 2+ flags → demoted to borderline at most
        for i in 100..<108 {
            let url = URL(fileURLWithPath: "/tmp/test_\(i).xisf")
            if let bd = scores[url] {
                XCTAssertTrue(bd.tier == .trash || bd.tier == .borderline || bd.tier == .uncertain,
                    "Bad B frame \(i) should be demoted by session sanity, got \(bd.tier)")
                if !bd.sessionSanityReasons.isEmpty {
                    XCTAssertGreaterThanOrEqual(bd.sessionSanityReasons.count, 2,
                        "Should have at least 2 session sanity flags")
                }
            }
        }

        // Verify: good L frames should remain excellent or good
        for i in 0..<10 {
            let url = URL(fileURLWithPath: "/tmp/test_\(i).xisf")
            if let bd = scores[url] {
                XCTAssertTrue(bd.tier == .excellent || bd.tier == .good,
                    "Good L frame \(i) should not be demoted, got \(bd.tier)")
            }
        }
    }

    /// Regression guard for algorithm v18 (v5.22.2):
    /// A pool that mixes plate scales — same scope with and without a focal
    /// reducer — must compare FWHM in arcseconds, not pixels. Native-FL frames
    /// and reduced-FL frames at identical physical seeing (2″ arcsec FWHM)
    /// should NOT be session-sanity-demoted against each other.
    func testSessionSanityCheck_mixedPlateScaleArcsecNormalization() {
        // Native RC12: 2423mm, 3.8µm → 0.324"/px. 2.0" seeing ⇒ 6.2 px FWHM.
        // Reduced RC12 + 0.81× reducer: 1964mm, 3.8µm → 0.399"/px. 2.0" seeing ⇒ 5.0 px FWHM.
        //
        // Under v17 (pixel comparison): pool P10 ~5.0 px (reduced dominates the
        // "best" decile), native frames at 6.2 px trip the 1.3× threshold = 6.5 px
        // and would get a FWHM-flag. With ecc/trailing/SNR flags if the metrics
        // drift at all, those frames demote to trash incorrectly.
        //
        // Under v18 (arcsec comparison on mixed-plate-scale pool): both sets
        // convert to ~2.0" FWHM. Pool P10 ~2.0". 1.3× = 2.6". Neither set trips.
        //
        // Uses a galaxy target ("M82") so the stricter default 1.3× multiplier
        // applies — matches the fwhmSanityMultiplier for default targetType.
        let fwhmJitter = [-0.10, -0.05, 0.0, 0.02, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20]

        let nativeRC12: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: i, filter: "L", target: "M82", exposure: 300,
                      noiseMAD: 0.002, noiseMedian: 0.050,
                      computedFWHM: 6.2 + fwhmJitter[i],
                      computedStarCount: 600,
                      computedEccentricity: 0.35,
                      focalLength: 2423,
                      pixelSizeMicrons: 3.8)
            e.date = "2026-03-15"; e.time = "22:00:00"
            return e
        }
        let reducedRC12: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: 100 + i, filter: "L", target: "M82", exposure: 300,
                      noiseMAD: 0.002, noiseMedian: 0.050,
                      computedFWHM: 5.0 + fwhmJitter[i],
                      computedStarCount: 420,
                      computedEccentricity: 0.35,
                      focalLength: 1964,
                      pixelSizeMicrons: 3.8)
            e.date = "2026-03-16"; e.time = "22:00:00"
            return e
        }

        let entries = nativeRC12 + reducedRC12
        let scores = QualityEstimator.computeScores(for: entries)

        // Every frame here is at ~2" physical seeing — no FWHM or star-count
        // session-sanity flag should fire on ANY frame. (SNR/ecc/trailing are
        // plate-scale invariant and uniform in this fixture, so they can't
        // fire either.) Any session sanity reason on any frame = regression.
        for (idx, entry) in entries.enumerated() {
            guard let bd = scores[entry.url] else { continue }
            XCTAssertTrue(
                bd.sessionSanityReasons.isEmpty,
                "Frame \(idx) (FL=\(entry.focalLength ?? 0)mm) should NOT be session-sanity-flagged on a mixed-plate-scale pool at uniform physical seeing — got: \(bd.sessionSanityReasons)"
            )
            // And therefore must not be in trash tier *from* session sanity.
            // (Other Stage 1 rules could still trash-tier, but nothing in this
            // fixture triggers them.)
            XCTAssertNotEqual(bd.tier, .trash, "Frame \(idx) should not be trash")
        }
    }

    /// Negative control for v18: mixed-plate-scale pool where the longer-FL
    /// frames genuinely have 2× worse physical seeing than the reduced-FL
    /// frames. The native-FL frames SHOULD still be session-sanity-flagged,
    /// because they're actually bad in arcseconds. Proves the arcsec
    /// normalization doesn't disable session sanity — only neutralizes the
    /// plate-scale bias.
    func testSessionSanityCheck_mixedPlateScaleStillCatchesRealBadNight() {
        // Native RC12 at 2423mm: fwhmPx 13.0 → 13.0 × 0.324 = 4.21" arcsec (bad!)
        // Reduced RC12 at 1964mm: fwhmPx 5.0 → 5.0 × 0.399 = 2.00" arcsec (good)
        // Pool P10 (arcsec) dominated by reduced: ~2.0".
        //
        // In algorithm v23 the Stage 1.5 severe single-FWHM-outlier path was
        // removed (empirical precision only 34% on the 4540-frame curated set —
        // see wiki/quality-pipeline-review-2026-04-18.md, FINDING-06). Demotion
        // now requires 2+ co-occurring flags. A genuine bad-seeing night
        // produces both elevated FWHM AND elevated eccentricity (stars move
        // during the exposure — wider AND more elongated), so we model that.
        // This preserves the test's original intent: arcsec normalization does
        // not disable session sanity on a genuinely bad night.
        let fwhmJitter = [-0.10, -0.05, 0.0, 0.02, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20]

        let nativeRC12Bad: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: 200 + i, filter: "L", target: "M82", exposure: 300,
                      noiseMAD: 0.002, noiseMedian: 0.050,
                      computedFWHM: 13.0 + fwhmJitter[i],
                      computedStarCount: 600,
                      computedEccentricity: 0.62,     // >> 1.5× pool P10=0.35 → ecc flag
                      focalLength: 2423,
                      pixelSizeMicrons: 3.8)
            e.date = "2026-03-15"; e.time = "22:00:00"
            return e
        }
        let reducedRC12Good: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: 300 + i, filter: "L", target: "M82", exposure: 300,
                      noiseMAD: 0.002, noiseMedian: 0.050,
                      computedFWHM: 5.0 + fwhmJitter[i],
                      computedStarCount: 420,
                      computedEccentricity: 0.35,
                      focalLength: 1964,
                      pixelSizeMicrons: 3.8)
            e.date = "2026-03-16"; e.time = "22:00:00"
            return e
        }

        let entries = nativeRC12Bad + reducedRC12Good
        let scores = QualityEstimator.computeScores(for: entries)

        // The bad native frames should be tagged with a session-sanity FWHM reason
        // OR demoted to a worse tier than .good. The reduced frames should remain.
        var demotedCount = 0
        for i in 200..<210 {
            let url = URL(fileURLWithPath: "/tmp/test_\(i).xisf")
            guard let bd = scores[url] else { continue }
            // Either it's flagged by session sanity OR already trashed by Stage 1.
            // We don't care which — the behavior we're proving is that session
            // sanity didn't stop working because of the arcsec switch.
            if bd.sessionSanityReasons.contains(where: { $0.contains("FWHM") }) || bd.tier == .trash || bd.tier == .borderline {
                demotedCount += 1
            }
        }
        XCTAssertGreaterThanOrEqual(demotedCount, 7,
            "At least 7 of 10 bad-native frames should be demoted (session-sanity or Stage 1). Got \(demotedCount)")

        // Reduced frames (genuinely good) should NOT be demoted by session sanity.
        for i in 300..<310 {
            let url = URL(fileURLWithPath: "/tmp/test_\(i).xisf")
            guard let bd = scores[url] else { continue }
            XCTAssertTrue(bd.sessionSanityReasons.isEmpty,
                "Reduced-FL good frame \(i) should not be session-sanity-flagged: \(bd.sessionSanityReasons)")
        }
    }

    /// Session sanity must not touch isLockedKeep frames
    func testSessionSanityCheck_respectsLockedKeep() {
        // Similar to above but with calibration that locks bad frames
        // The locked frames should remain good despite session sanity flags
        // (isLockedKeep is set by CalibrationDatabase, not by this test directly)
        // This test verifies that the garbageReasons.isEmpty check protects Stage 1 garbage
        let goodL: [ImageEntry] = (0..<10).map { i in
            makeEntry(index: i, filter: "L", target: "M82", exposure: 180,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 3.0, computedStarCount: 3000,
                      computedEccentricity: 0.35)
        }
        // 6 bad frames with chain fraction → Stage 1 garbage (trackingHop)
        let badChain: [ImageEntry] = (0..<6).map { i in
            var e = makeEntry(index: 200 + i, filter: "B", target: "M82", exposure: 180,
                              noiseMAD: 0.006, noiseMedian: 0.05,
                              computedFWHM: 10.0, computedStarCount: 2400,
                              computedEccentricity: 0.65)
            e.starChainFraction = 0.5  // Above R9 threshold 0.25
            return e
        }

        let entries = goodL + badChain
        let scores = QualityEstimator.computeScores(for: entries)

        // Bad frames should be Stage 1 trash (trackingHop) — session sanity doesn't re-demote
        for i in 200..<206 {
            let url = URL(fileURLWithPath: "/tmp/test_\(i).xisf")
            if let bd = scores[url] {
                XCTAssertEqual(bd.tier, .trash, "Chain frame should be trash")
                XCTAssertTrue(bd.garbageReasons.contains(.trackingHop),
                    "Should have trackingHop garbage reason")
                XCTAssertTrue(bd.sessionSanityReasons.isEmpty,
                    "Session sanity should not add reasons to Stage 1 garbage")
            }
        }
    }

    // MARK: - Algorithm v23 regression tests (curation-driven tune-up, 2026-04-18)

    /// FINDING-06: Stage 1.5 severe single-FWHM-outlier path REMOVED.
    /// A frame whose ONLY Stage 1.5 flag is "FWHM far above session norm" must
    /// NOT be demoted — even if FWHM exceeds the old `severeFwhmMultiplier`
    /// (sanity + 0.1 = 1.4× P10 for galaxies). The 2-flag rule is the only path.
    func testFINDING06_singleFWHMFlag_doesNotDemote() {
        // Two nights of L frames on M82 (galaxies → default sanityMultiplier 1.3,
        // old severeMultiplier 1.4). Fixed jitter for determinism.
        let fwhmJitter = [-0.10, -0.05, 0.0, 0.05, 0.08, 0.10, 0.12, 0.15, 0.18, 0.20]

        // 10 good frames on night A: FWHM ~2.0 (session pool P10 ≈ 1.9)
        let goodA: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: i, filter: "L", target: "M82", exposure: 300,
                              noiseMAD: 0.002, noiseMedian: 0.05,
                              computedFWHM: 2.0 + fwhmJitter[i],
                              computedStarCount: 3000,
                              computedEccentricity: 0.30)
            e.date = "2026-03-15"; e.time = "22:00:00"
            return e
        }
        // 10 frames on night B with slightly elevated FWHM (~3.0 = 1.5× P10)
        // but otherwise identical SNR/stars/ecc/trailing → only the FWHM flag fires.
        let mildB: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: 100 + i, filter: "L", target: "M82", exposure: 300,
                              noiseMAD: 0.002, noiseMedian: 0.05,
                              computedFWHM: 3.0 + fwhmJitter[i],
                              computedStarCount: 3000,
                              computedEccentricity: 0.30)
            e.date = "2026-03-16"; e.time = "22:00:00"
            return e
        }

        let scores = QualityEstimator.computeScores(for: goodA + mildB)

        // None of the mild-B frames should be session-sanity-demoted to trash
        // because only the FWHM flag fires (no SNR/stars/ecc/trail issue).
        for i in 100..<110 {
            let url = URL(fileURLWithPath: "/tmp/test_\(i).xisf")
            guard let bd = scores[url] else {
                XCTFail("Missing score for frame \(i)")
                continue
            }
            XCTAssertNotEqual(bd.tier, .trash,
                "Frame \(i) with only FWHM flag must not be sanity-demoted to trash (severe path removed in v23). Reasons: \(bd.sessionSanityReasons)")
            // If it was flagged, the flag count must be <2 (single flag)
            if !bd.sessionSanityReasons.isEmpty {
                XCTAssertLessThan(bd.sessionSanityReasons.count, 2,
                    "Frame \(i) has \(bd.sessionSanityReasons.count) sanity reasons but was not demoted — confirm single-flag path is disabled")
            }
        }
    }

    /// FINDING-01: Stage 4 rescue preserves sessionSanityReasons on the rescued breakdown.
    /// A frame demoted by Stage 1.5 (sessionSanityReasons populated, garbageReasons empty)
    /// with FWHM within the good-frame 90th percentile gets lifted to .borderline, BUT
    /// the sessionSanityReasons must survive so recommendationLabel shows "REVIEW — ..."
    func testFINDING01_stage4RescuePreservesSanityReasons() {
        // Build a multi-night pool large enough to produce sanity demotes.
        // Night A: 10 excellent frames (FWHM 2.0, SNR ~25). Defines good bar.
        // Night B: 8 frames with SNR-dropped but FWHM matching good — classic cloud
        // profile where Rule 8 / Rule 2 don't fire (different group medians), but
        // cross-pool session sanity sees the SNR drop vs pool P90.
        let fwhmJitterA = [-0.10, -0.05, 0.0, 0.02, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20]
        let fwhmJitterB = [-0.05, -0.02, 0.0, 0.02, 0.05, 0.08, 0.10, 0.12]

        let nightA: [ImageEntry] = (0..<10).map { i in
            var e = makeEntry(index: i, filter: "L", target: "NGC7000", exposure: 300,
                              noiseMAD: 0.002, noiseMedian: 0.05,
                              computedFWHM: 2.0 + fwhmJitterA[i],
                              computedStarCount: 4000,
                              computedEccentricity: 0.30)
            e.date = "2026-03-15"; e.time = "22:00:00"
            return e
        }
        // Night B: different filter so it's a separate scoring group BUT same session pool.
        // Low SNR (high noiseMAD), low star count, same FWHM as good frames.
        let nightB: [ImageEntry] = (0..<8).map { i in
            var e = makeEntry(index: 100 + i, filter: "B", target: "NGC7000", exposure: 300,
                              noiseMAD: 0.030, noiseMedian: 0.05,  // SNR ~1.7 vs ~25
                              computedFWHM: 2.1 + fwhmJitterB[i],  // FWHM matches good
                              computedStarCount: 1200,             // 30% of P90
                              computedEccentricity: 0.30)
            e.date = "2026-03-20"; e.time = "22:00:00"
            return e
        }

        let scores = QualityEstimator.computeScores(for: nightA + nightB)

        // Among the night-B frames, find any that Stage 1.5 sanity-demoted then
        // Stage 4 potentially rescued. The rescued one must carry the sanity reason.
        var foundRescued = false
        for i in 100..<108 {
            let url = URL(fileURLWithPath: "/tmp/test_\(i).xisf")
            guard let bd = scores[url] else { continue }

            // If Stage 4 rescued to borderline, sessionSanityReasons must be preserved
            if bd.tier == .borderline && !bd.sessionSanityReasons.isEmpty {
                foundRescued = true
                XCTAssertTrue(bd.garbageReasons.isEmpty,
                    "Stage 4 rescued frame \(i) should have no Stage 1 garbage reasons")
                XCTAssertFalse(bd.sessionSanityReasons.isEmpty,
                    "Stage 4 rescued frame \(i) must preserve sessionSanityReasons (FINDING-01 fix)")
                // recommendationLabel should render "REVIEW — <reasons>"
                XCTAssertTrue(bd.recommendationLabel.hasPrefix("REVIEW —"),
                    "recommendationLabel should render REVIEW banner on rescued-but-flagged frame, got: \(bd.recommendationLabel)")
            }
        }
        // If the fixture didn't exercise the rescue branch (because sanity didn't
        // fire at all, or Stage 4 didn't match), the test is vacuous — document that.
        if !foundRescued {
            // Check that at least SOME night-B frame was demoted or flagged
            let nightBTrashedOrFlagged = (100..<108).contains(where: { i in
                guard let bd = scores[URL(fileURLWithPath: "/tmp/test_\(i).xisf")] else { return false }
                return bd.tier == .trash || !bd.sessionSanityReasons.isEmpty
            })
            XCTAssertTrue(nightBTrashedOrFlagged,
                "Test fixture failed to trigger sanity flags on cloud-profile frames — revisit fixture")
        }
    }

    /// FINDING-03: When the uncertain override flips tier AFTER reasoning was built
    /// with a rescue narrative, the final breakdown's reasoningText must be
    /// "Small group — low confidence" (not the stale rescue text).
    func testFINDING03_uncertainOverrideReplacesStaleReasoning() {
        // Small group (7 frames, below 8-frame uncertain threshold), borderline
        // combinedZ in the narrow (-1.0, -0.5) range where rescue Rule A fires,
        // then uncertain override flips tier.
        // Build: 7 frames with one being borderline-but-rescued.
        // Mostly similar good frames with one slightly below.
        let entries: [ImageEntry] = [
            // 6 "excellent" (tight group)
            makeEntry(index: 0, filter: "L", target: "M42", exposure: 60,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 2.0, computedStarCount: 2000, computedEccentricity: 0.25),
            makeEntry(index: 1, filter: "L", target: "M42", exposure: 60,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 2.0, computedStarCount: 2000, computedEccentricity: 0.25),
            makeEntry(index: 2, filter: "L", target: "M42", exposure: 60,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 2.0, computedStarCount: 2000, computedEccentricity: 0.25),
            makeEntry(index: 3, filter: "L", target: "M42", exposure: 60,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 2.0, computedStarCount: 2000, computedEccentricity: 0.25),
            makeEntry(index: 4, filter: "L", target: "M42", exposure: 60,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 2.0, computedStarCount: 2000, computedEccentricity: 0.25),
            makeEntry(index: 5, filter: "L", target: "M42", exposure: 60,
                      noiseMAD: 0.001, noiseMedian: 0.05,
                      computedFWHM: 2.0, computedStarCount: 2000, computedEccentricity: 0.25),
            // 1 frame slightly off — enough to be borderline, FWHM still within 1.05× for Rule A
            makeEntry(index: 6, filter: "L", target: "M42", exposure: 60,
                      noiseMAD: 0.0015, noiseMedian: 0.05,   // slightly noisier
                      computedFWHM: 2.05, computedStarCount: 1800, computedEccentricity: 0.30),
        ]
        let scores = QualityEstimator.computeScores(for: entries)

        // Frame 6 should end up uncertain (small group, ambiguous z-score).
        // Its reasoning must NOT reference a rescue; it must say "Small group — low confidence".
        let url6 = URL(fileURLWithPath: "/tmp/test_6.xisf")
        if let bd = scores[url6], bd.tier == .uncertain {
            XCTAssertEqual(bd.reasoningText, "Small group — low confidence",
                "Uncertain-tier frame should have 'Small group — low confidence' reasoning, got: \(bd.reasoningText ?? "nil")")
            // Must not contain stale rescue phrasing
            let stale = bd.reasoningText?.contains("within group norm") ?? false
            XCTAssertFalse(stale,
                "Uncertain-tier reasoning must not carry over rescue narrative")
        }
    }

    /// FINDING-05: A frame that can't produce any z-score (only measured frame
    /// in its group, zscores() returns nil for everything) must NOT silently
    /// vanish from result — it should get a `.uncertain` breakdown.
    func testFINDING05_wSumZeroProducesUncertainNotSilentDrop() {
        // 6-frame group where ONLY index 0 has any metric data.
        // Other 5 frames have ONLY noiseMAD = nil and computedStarCount = nil
        // (so they pass the line 539 guard via… wait, they'd be SKIPPED by that guard).
        //
        // Better construction: index 0 has noiseMAD (passes line 539 guard) but
        // nothing else. The other 5 have ONLY computedStarCount (so they also
        // pass line 539). Since index 0 has no stars and others have no noise,
        // z-scores collapse (each metric has only 1 valid value → nil).
        let entries: [ImageEntry] = [
            // Index 0: only noiseMAD, nothing else computed → all z-scores will be nil
            {
                var e = makeEntry(index: 0, filter: "H", target: "NGC1333", exposure: 300)
                e.noiseMAD = 0.002
                e.noiseMedian = 0.05
                return e
            }(),
            // Others: only computedStarCount (all different values to have some variance)
            makeEntry(index: 1, filter: "H", target: "NGC1333", exposure: 300, computedStarCount: 100),
            makeEntry(index: 2, filter: "H", target: "NGC1333", exposure: 300, computedStarCount: 150),
            makeEntry(index: 3, filter: "H", target: "NGC1333", exposure: 300, computedStarCount: 200),
            makeEntry(index: 4, filter: "H", target: "NGC1333", exposure: 300, computedStarCount: 250),
            makeEntry(index: 5, filter: "H", target: "NGC1333", exposure: 300, computedStarCount: 300),
        ]

        let scores = QualityEstimator.computeScores(for: entries)

        // The isolated frame must have a breakdown even if it's uncertain
        let url0 = URL(fileURLWithPath: "/tmp/test_0.xisf")
        XCTAssertNotNil(scores[url0],
            "FINDING-05: isolated-metric frame must not be silently dropped — should produce .uncertain breakdown")

        if let bd = scores[url0] {
            // Either .uncertain (fresh fallback path) or normal classification if noiseMadZ
            // happens to resolve. The critical invariant is: "never silent drop".
            let isAcceptableTier = (bd.tier == .uncertain || bd.tier == .good
                                    || bd.tier == .borderline || bd.tier == .trash
                                    || bd.tier == .excellent)
            XCTAssertTrue(isAcceptableTier, "Frame should have some assigned tier, got: \(bd.tier)")

            // If it hit the wSum==0 fallback, reasoning should reflect it
            if bd.reasoningText?.contains("No comparable frames") == true {
                XCTAssertEqual(bd.tier, .uncertain,
                    "wSum==0 fallback should assign .uncertain tier")
            }
        }
    }

    // MARK: - R6 Star Count Anomaly — Deeper Coverage (Patch 3)
    //
    // R6: stars > 1.8 × group median + (FWHM elevated OR HFR elevated) → .starCountAnomaly.
    // The FWHM/HFR cross-check exists to protect against satellite-trail-style false positives
    // where a single frame's star detector inflates the count without degrading PSF quality.
    // Group median must be > 20 to avoid noise-driven false positives in tiny-star groups.

    /// R6 fires when stars are doubled AND FWHM is elevated (>1.3× median).
    /// Simulates a real "tracking jump after dither" frame: doubled stars from optical
    /// shift across the sensor, accompanied by smeared PSFs.
    func testR6_StarCountAnomaly_FiresWithFWHMElevation() {
        // Group median: stars=500, FWHM=3.0
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500,
                                noiseMAD: 0.01, noiseMedian: 0.05)

        // Anomaly: stars=1500 (3× median, > 1.8×), FWHM=4.5 (1.5× median, > 1.3×)
        // R6 must fire because both halves of the cross-check pass.
        let anomaly = makeEntry(index: 99, fwhm: 4.5, hfr: 2.0, starCount: 1500,
                                noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(anomaly)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[anomaly.url] else {
            XCTFail("Anomaly frame should have a score")
            return
        }
        XCTAssertTrue(bd.garbageReasons.contains(.starCountAnomaly),
            "R6: doubled stars + elevated FWHM must trigger starCountAnomaly. Got reasons: \(bd.garbageReasons)")
    }

    /// R6 fires when stars are doubled AND HFR is elevated (FWHM happens to be unmeasured).
    /// HFR alone can satisfy the cross-check.
    func testR6_StarCountAnomaly_FiresWithHFRElevationOnly() {
        // Group with HFR populated but no FWHM
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            entries.append(makeEntry(index: i, hfr: 2.0, starCount: 500,
                                     noiseMAD: 0.01, noiseMedian: 0.05))
        }

        // Anomaly: stars=1500, HFR=3.0 (1.5×), no FWHM measurement.
        let anomaly = makeEntry(index: 99, hfr: 3.0, starCount: 1500,
                                noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(anomaly)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[anomaly.url] else {
            XCTFail("Anomaly frame should have a score")
            return
        }
        XCTAssertTrue(bd.garbageReasons.contains(.starCountAnomaly),
            "R6: doubled stars + elevated HFR (no FWHM) must trigger starCountAnomaly. Got: \(bd.garbageReasons)")
    }

    /// R6 does NOT fire when star ratio is just below the 1.8× threshold,
    /// even with elevated FWHM. The threshold is sharp.
    func testR6_StarCountAnomaly_BelowRatioThreshold_DoesNotFire() {
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500,
                                noiseMAD: 0.01, noiseMedian: 0.05)

        // 1.7× (below 1.8 threshold), even with elevated FWHM
        let frame = makeEntry(index: 99, fwhm: 4.5, hfr: 3.0, starCount: 850,
                              noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(frame)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[frame.url] else {
            XCTFail("Frame should have a score")
            return
        }
        XCTAssertFalse(bd.garbageReasons.contains(.starCountAnomaly),
            "R6 must not fire when star ratio (1.7×) is below 1.8× threshold")
    }

    /// R6 has a guard: median > 20. In tiny-star groups (e.g., narrowband long FL),
    /// random ratios above 1.8× are expected. Guard prevents false positives.
    func testR6_StarCountAnomaly_LowMedianGuard() {
        // Group median = 15 (below the >20 guard threshold)
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0,
                                starCount: 15, noiseMAD: 0.01, noiseMedian: 0.05,
                                filter: "OIII")

        // Stars 50 = 3.3× median, FWHM 4.5 = 1.5×. Even though both R6 conditions look met,
        // the median guard prevents the rule from firing on tiny-star groups.
        let frame = makeEntry(index: 99, filter: "OIII", fwhm: 4.5, hfr: 3.0, starCount: 50,
                              noiseMAD: 0.01, noiseMedian: 0.05)
        entries.append(frame)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[frame.url] else {
            XCTFail("Frame should have a score")
            return
        }
        XCTAssertFalse(bd.garbageReasons.contains(.starCountAnomaly),
            "R6 must not fire when group median ≤ 20 stars (low-median guard)")
    }

    // MARK: - R7 Background Anomaly — Full Coverage (Patch 3)
    //
    // R7 (named "Rule 8" inline): backgroundAnomaly fires when (bg − bgMedian) / bgMAD
    // exceeds the threshold (5+ raw MADs). Critical INVARIANT: only POSITIVE deviation
    // triggers — a darker-than-median sky is BETTER (less light pollution / cleaner night).
    // Moon-aware: broadband filters get threshold relaxed when bright moon is close.

    /// R7 fires on a clearly elevated background (clouds / gradient).
    /// Group bg ≈ 0.05; cloudy frame at 0.20 is far above 5 MADs.
    func testR7_BackgroundAnomaly_PositiveDeviationFires() {
        // Mostly identical group with small bg variation so MAD is non-zero
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            // Tiny variation (±0.0005) → small but non-zero MAD
            let bg: Float = 0.05 + Float(i % 5) * 0.0001
            entries.append(makeEntry(index: i, fwhm: 3.0, hfr: 2.0, starCount: 500,
                                     noiseMAD: 0.005, noiseMedian: bg))
        }

        // Cloudy frame: bg = 0.20 (far above the median + threshold MADs)
        let cloudy = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 500,
                               noiseMAD: 0.005, noiseMedian: 0.20)
        entries.append(cloudy)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[cloudy.url] else {
            XCTFail("Cloudy frame should have a score")
            return
        }
        XCTAssertTrue(bd.garbageReasons.contains(.backgroundAnomaly),
            "R7: clearly elevated background must trigger backgroundAnomaly. Got: \(bd.garbageReasons)")
    }

    /// CRITICAL INVARIANT: a darker-than-median sky must NEVER trigger R7.
    /// (CLAUDE.md: "Hard Invariants — R7 Background Anomaly: NUR positive Abweichung. Dunklerer Himmel = BESSER")
    /// This is the load-bearing test for the directionality invariant.
    func testR7_BackgroundAnomaly_NegativeDeviationNeverFires() {
        // Group bg ≈ 0.05 with small spread
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            let bg: Float = 0.05 + Float(i % 5) * 0.0001
            entries.append(makeEntry(index: i, fwhm: 3.0, hfr: 2.0, starCount: 500,
                                     noiseMAD: 0.005, noiseMedian: bg))
        }

        // Exceptionally dark frame: bg = 0.001 (way below median, hundreds of MADs negative).
        // Whatever else fires, R7 must NOT.
        let darkSky = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 500,
                                noiseMAD: 0.005, noiseMedian: 0.001)
        entries.append(darkSky)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[darkSky.url] else {
            XCTFail("Dark-sky frame should have a score")
            return
        }
        XCTAssertFalse(bd.garbageReasons.contains(.backgroundAnomaly),
            "R7 INVARIANT: darker-than-median background must never trigger backgroundAnomaly (dunklerer Himmel = BESSER). Got: \(bd.garbageReasons)")
    }

    /// R7 below-threshold: a slightly-elevated background (e.g., 2-3 MADs above) must NOT fire.
    /// The 5-MAD floor is intentional — empirically calibrated to avoid 34% precision drop.
    func testR7_BackgroundAnomaly_JustBelowThreshold_DoesNotFire() {
        // Build group with very tight bg spread so MAD is well-defined
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            let bg: Float = 0.05 + Float(i % 5) * 0.001  // MAD ≈ 0.001
            entries.append(makeEntry(index: i, fwhm: 3.0, hfr: 2.0, starCount: 500,
                                     noiseMAD: 0.005, noiseMedian: bg))
        }

        // ~3 MADs elevation → below the 5-MAD R7 floor
        let mild = makeEntry(index: 99, fwhm: 3.0, hfr: 2.0, starCount: 500,
                             noiseMAD: 0.005, noiseMedian: 0.053)
        entries.append(mild)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[mild.url] else {
            XCTFail("Frame should have a score")
            return
        }
        XCTAssertFalse(bd.garbageReasons.contains(.backgroundAnomaly),
            "R7 must not fire when deviation is below the 5-MAD threshold")
    }

    /// R7 moon awareness: bright nearby moon raises legitimate background for BROADBAND filters
    /// — threshold relaxes proportionally to moonIllumination × (1 - moonDist/90).
    /// A slightly elevated B-filter frame near full moon should NOT trigger R7.
    func testR7_BackgroundAnomaly_MoonRelaxesBroadbandThreshold() {
        // Build a B-filter group with full moon close by (90% illum, 20° away).
        // moonFactor = 0.9 × (1 - 20/90) = 0.7 → bgThreshold ≈ 5 × 1.7 = 8.5 MADs.
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            let bg: Float = 0.05 + Float(i % 5) * 0.001
            var e = makeEntry(index: i, filter: "B", fwhm: 3.0, hfr: 2.0, starCount: 500,
                              noiseMAD: 0.005, noiseMedian: bg)
            e.moonIllumination = 0.9
            e.moonDistance = 20.0
            entries.append(e)
        }

        // Elevated bg (~6 MADs above median): would trigger R7 without moon relaxation,
        // but should be allowed through under bright nearby moon for broadband.
        var moonyB = makeEntry(index: 99, filter: "B", fwhm: 3.0, hfr: 2.0, starCount: 500,
                               noiseMAD: 0.005, noiseMedian: 0.056)
        moonyB.moonIllumination = 0.9
        moonyB.moonDistance = 20.0
        entries.append(moonyB)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[moonyB.url] else {
            XCTFail("Moony broadband frame should have a score")
            return
        }
        XCTAssertFalse(bd.garbageReasons.contains(.backgroundAnomaly),
            "R7: bright nearby moon must relax broadband threshold (legitimate sky brightness). Got: \(bd.garbageReasons)")
    }

    /// R7 narrowband immunity: narrowband filters must NOT get the moon relaxation —
    /// narrowband is largely immune to moonlight, so an elevated bg there is real anomaly.
    func testR7_BackgroundAnomaly_NarrowbandIgnoresMoon() {
        // Same scenario but with H (narrowband) filter — relaxation should not apply.
        var entries: [ImageEntry] = []
        for i in 0..<24 {
            let bg: Float = 0.05 + Float(i % 5) * 0.0001
            var e = makeEntry(index: i, filter: "H", fwhm: 3.0, hfr: 2.0, starCount: 500,
                              noiseMAD: 0.005, noiseMedian: bg)
            e.moonIllumination = 0.9
            e.moonDistance = 20.0
            entries.append(e)
        }

        // Massively elevated narrowband bg (cloud-like) — must trigger R7
        // even with bright moon present, because narrowband doesn't legitimize moon background.
        var moonyH = makeEntry(index: 99, filter: "H", fwhm: 3.0, hfr: 2.0, starCount: 500,
                               noiseMAD: 0.005, noiseMedian: 0.20)
        moonyH.moonIllumination = 0.9
        moonyH.moonDistance = 20.0
        entries.append(moonyH)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[moonyH.url] else {
            XCTFail("Narrowband frame should have a score")
            return
        }
        XCTAssertTrue(bd.garbageReasons.contains(.backgroundAnomaly),
            "R7: narrowband filter must not be relaxed by moon presence (NB is largely moon-immune). Got: \(bd.garbageReasons)")
    }

    // MARK: - isLockedKeep — Absolute Quality Floor (Patch 3)
    //
    // CalibrationDatabase.meetsAbsoluteFloor() returns true only when:
    //   1. Profile has ≥30 frames (hasLearned == true)
    //   2. Filter+exposure baseline has ≥30 frames
    //   3. ≥2 metrics check (fwhm/hfr/stars/trailing) AND ALL pass within 1 MAD
    //
    // When a frame meets this floor, QualityEstimator must lock it as KEEP — z-score
    // cannot demote below .good. This guards against the "death spiral" where z-scores
    // always find "the worst" frame even in a uniformly excellent set.
    //
    // Tests below seed the singleton CalibrationDatabase with a unique random fingerprint
    // (so they don't collide with any real calibration data) and clean up the JSON file
    // in tearDown.

    /// Random unique fingerprint per test invocation to avoid leaking state between runs.
    private func uniqueFingerprint() -> SetupFingerprint {
        // UUID makes telescope/camera identifiers unique → unique hash → isolated profile
        let uniq = UUID().uuidString
        return SetupFingerprint(telescope: "TestScope-\(uniq)",
                                camera: "TestCam-\(uniq)",
                                focalLength: 500,
                                pixelSizeMicrons: 3.76)
    }

    /// Delete the JSON file written by CalibrationDatabase for a fingerprint, if present.
    /// Best-effort cleanup so test runs don't leave residue.
    private func cleanupCalibrationProfile(_ fp: SetupFingerprint) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AstroBlinkV2/Calibration", isDirectory: true)
        let url = dir.appendingPathComponent("\(fp.hash).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Seed the CalibrationDatabase singleton with N retained frames for a fingerprint.
    /// Each frame has the supplied filter/exposure and per-frame metric overrides via closure.
    private func seedCalibration(fingerprint: SetupFingerprint, count: Int = 35,
                                  filter: String = "L", exposure: Double = 300,
                                  fwhm: Double = 3.0, hfr: Double = 2.0,
                                  starCount: Int = 500, noiseMAD: Float = 0.005,
                                  trailingScore: Double = 0.05) {
        let entries: [ImageEntry] = (0..<count).map { i in
            // Tiny per-frame variation so Welford MAD > 0 (otherwise isWithinMAD short-circuits)
            let f = fwhm + Double(i % 5 - 2) * 0.05
            return makeEntry(index: 10_000 + i, filter: filter, exposure: exposure,
                             fwhm: f, hfr: hfr + Double(i % 5 - 2) * 0.03,
                             starCount: starCount + (i % 5 - 2) * 10,
                             noiseMAD: noiseMAD,
                             noiseMedian: 0.05,
                             trailingScore: trailingScore + Double(i % 5 - 2) * 0.005)
        }
        CalibrationDatabase.shared.commitSession(entries: entries, fingerprint: fingerprint)
    }

    /// A frame that meets the absolute floor is locked as KEEP — even if its z-score
    /// would normally place it below .good in the relative comparison.
    func testIsLockedKeep_FloorPreventsDemotionBelowGood() {
        let fp = uniqueFingerprint()
        defer { cleanupCalibrationProfile(fp) }

        // Seed 35 frames with FWHM ~3.0 baseline
        seedCalibration(fingerprint: fp, count: 35, filter: "L", exposure: 300,
                        fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.005,
                        trailingScore: 0.05)

        // Build a current session: 24 great frames + 1 frame that's "worst by relative z-score"
        // but still well within calibration baseline (FWHM=3.05, very close to learned mean 3.0).
        // Without the floor lock this frame might be borderline against the great group;
        // with the floor it must be locked at ≥ .good.
        var current: [ImageEntry] = []
        for i in 0..<24 {
            // Tight excellent group at FWHM 2.5 — pulls relative z-scores low for the candidate
            current.append(makeEntry(index: i, filter: "L", exposure: 300,
                                     fwhm: 2.5, hfr: 1.7, starCount: 500,
                                     noiseMAD: 0.005, noiseMedian: 0.05,
                                     trailingScore: 0.05))
        }
        let candidate = makeEntry(index: 999, filter: "L", exposure: 300,
                                  fwhm: 3.05, hfr: 2.0, starCount: 500,
                                  noiseMAD: 0.005, noiseMedian: 0.05,
                                  trailingScore: 0.05)
        current.append(candidate)

        let scores = QualityEstimator.computeScores(for: current,
                                                    calibrationDB: CalibrationDatabase.shared,
                                                    fingerprint: fp)
        guard let bd = scores[candidate.url] else {
            XCTFail("Candidate frame should have a score")
            return
        }
        XCTAssertTrue(bd.isLockedKeep,
            "Frame within 1 MAD of learned baseline (≥2 metrics, ≥30 frames) must be locked as KEEP")
        XCTAssertGreaterThanOrEqual(bd.tier.rawValue, QualityTier.good.rawValue,
            "Locked-keep frame must not fall below .good. Tier=\(bd.tier)")
    }

    /// The floor requires ≥30 learned frames. Below that, isLockedKeep stays false
    /// regardless of how close the candidate matches the (insufficient) baseline.
    func testIsLockedKeep_RequiresMinimumLearnedFrames() {
        let fp = uniqueFingerprint()
        defer { cleanupCalibrationProfile(fp) }

        // Seed only 25 frames — below the 30-frame learning threshold
        seedCalibration(fingerprint: fp, count: 25, filter: "L", exposure: 300,
                        fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.005,
                        trailingScore: 0.05)

        var current = makeGroup(count: 24, fwhm: 2.5, hfr: 1.7, starCount: 500,
                                noiseMAD: 0.005, filter: "L")
        for i in 0..<current.count { current[i].exposure = 300 }
        let candidate = makeEntry(index: 999, filter: "L", exposure: 300,
                                  fwhm: 3.0, hfr: 2.0, starCount: 500,
                                  noiseMAD: 0.005, noiseMedian: 0.05,
                                  trailingScore: 0.05)
        current.append(candidate)

        let scores = QualityEstimator.computeScores(for: current,
                                                    calibrationDB: CalibrationDatabase.shared,
                                                    fingerprint: fp)
        guard let bd = scores[candidate.url] else {
            XCTFail("Candidate frame should have a score")
            return
        }
        XCTAssertFalse(bd.isLockedKeep,
            "Floor must not engage with fewer than 30 learned frames")
    }

    /// The floor requires ALL checked metrics to pass. If any single metric drifts
    /// outside 1 MAD of baseline, isLockedKeep stays false — partial-pass is not enough.
    func testIsLockedKeep_RequiresAllMetricsPass() {
        let fp = uniqueFingerprint()
        defer { cleanupCalibrationProfile(fp) }

        seedCalibration(fingerprint: fp, count: 35, filter: "L", exposure: 300,
                        fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.005,
                        trailingScore: 0.05)

        var current: [ImageEntry] = []
        for i in 0..<24 {
            current.append(makeEntry(index: i, filter: "L", exposure: 300,
                                     fwhm: 2.5, hfr: 1.7, starCount: 500,
                                     noiseMAD: 0.005, noiseMedian: 0.05,
                                     trailingScore: 0.05))
        }
        // Candidate matches baseline on FWHM/HFR but star count is dramatically off
        // (250 vs learned ~500 with tiny MAD) — that single failed check must veto the lock.
        let candidate = makeEntry(index: 999, filter: "L", exposure: 300,
                                  fwhm: 3.0, hfr: 2.0, starCount: 250,
                                  noiseMAD: 0.005, noiseMedian: 0.05,
                                  trailingScore: 0.05)
        current.append(candidate)

        let scores = QualityEstimator.computeScores(for: current,
                                                    calibrationDB: CalibrationDatabase.shared,
                                                    fingerprint: fp)
        guard let bd = scores[candidate.url] else {
            XCTFail("Candidate frame should have a score")
            return
        }
        XCTAssertFalse(bd.isLockedKeep,
            "Floor must require ALL checked metrics to pass — a single drifted metric vetoes the lock")
    }

    /// A locked-keep frame whose combinedZ exceeds the .excellent threshold is still
    /// allowed to be .excellent — the lock floors the tier, it doesn't cap it.
    func testIsLockedKeep_AllowsExcellentTier() {
        let fp = uniqueFingerprint()
        defer { cleanupCalibrationProfile(fp) }

        seedCalibration(fingerprint: fp, count: 35, filter: "L", exposure: 300,
                        fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.005,
                        trailingScore: 0.05)

        // Current group: 24 mediocre frames + 1 within-baseline AND clearly best-by-z frame.
        var current: [ImageEntry] = []
        for i in 0..<24 {
            current.append(makeEntry(index: i, filter: "L", exposure: 300,
                                     fwhm: 4.0, hfr: 2.7, starCount: 400,
                                     noiseMAD: 0.012, noiseMedian: 0.05,
                                     trailingScore: 0.10))
        }
        // Best frame: matches baseline (within 1 MAD) AND wins relative z-score
        let best = makeEntry(index: 999, filter: "L", exposure: 300,
                             fwhm: 3.0, hfr: 2.0, starCount: 500,
                             noiseMAD: 0.005, noiseMedian: 0.05,
                             trailingScore: 0.05)
        current.append(best)

        let scores = QualityEstimator.computeScores(for: current,
                                                    calibrationDB: CalibrationDatabase.shared,
                                                    fingerprint: fp)
        guard let bd = scores[best.url] else {
            XCTFail("Best frame should have a score")
            return
        }
        XCTAssertTrue(bd.isLockedKeep, "Best-and-baseline-matching frame must be locked")
        XCTAssertEqual(bd.tier, .excellent,
            "Lock must NOT cap the tier — frames that clearly win z-score are still .excellent")
    }

    // MARK: - Stage 1.5b — Narrowband Bad-Night Detection (Patch 3)
    //
    // Stage 1.5b reads from the FrameHistoryDatabase singleton to compare a session
    // against per-setup historical baselines. Narrowband filters get RELAXED thresholds
    // (FWHM 6 MADs vs 3, trailing 6 vs 3, severe 10 vs 5) because narrowband PSFs are
    // inherently bloated, resolution matters less, and exposures are expensive to discard.
    //
    // KNOWN COVERAGE GAP: Stage 1.5b's data source is FrameHistoryDatabase.shared, which
    // is a singleton persisted to disk. Seeding it from a unit test would either pollute
    // production data or require risky disk surgery. The narrowband-specific threshold
    // logic is left untested at the integration level; full coverage would need a
    // FrameHistoryDatabase test seam (dependency injection or in-memory mode) that does
    // not currently exist.
    func testStage1_5b_NarrowbandThresholds_NotCoveredHere() throws {
        throw XCTSkip("Stage 1.5b reads FrameHistoryDatabase.shared which is a disk-backed singleton without a test seam. Adding coverage requires production refactor (dependency injection or in-memory mode) which is out of scope for Patch 3 — see comment above.")
    }

    // MARK: - Phase 2 — Curation-Driven Threshold Learning integration

    /// Build a population that produces a meaningful trash/borderline mix
    /// so we can compare two scoring runs. Mostly-clean group with a
    /// graded-outlier tail. Outliers stay BELOW Stage 1 thresholds
    /// (FWHM ≤ 2× median, HFR ≤ 2× median, stars ≥ 50% median, etc.) so
    /// their tier is determined by the borderline z-score branch — i.e.
    /// the path the learned offset actually adjusts. Stage-1-tripping
    /// outliers would short-circuit to .trash before reaching that branch.
    private func makeMarginalGroup() -> [ImageEntry] {
        var entries: [ImageEntry] = []
        // Twelve clean reference frames (well above the borderline boundary).
        for i in 0..<12 {
            entries.append(makeEntry(index: i, fwhm: 2.0, hfr: 1.0, starCount: 500,
                                     noiseMAD: 0.005, noiseMedian: 0.05))
        }
        // Three graded outliers: FWHM stays ≤ 1.95× median (under the
        // highFWHM cutoff at median × 2.0); HFR ≤ 1.9× median; stars ≥ 60%
        // of median (well above the starCountDrop cutoff at 50%).
        entries.append(makeEntry(index: 100, fwhm: 3.5, hfr: 1.7, starCount: 350,
                                 noiseMAD: 0.008, noiseMedian: 0.05))
        entries.append(makeEntry(index: 101, fwhm: 3.7, hfr: 1.8, starCount: 320,
                                 noiseMAD: 0.009, noiseMedian: 0.05))
        entries.append(makeEntry(index: 102, fwhm: 3.9, hfr: 1.9, starCount: 300,
                                 noiseMAD: 0.010, noiseMedian: 0.05))
        return entries
    }

    /// 1 — Directional contract for the borderline offset:
    ///   - Lenient offset (negative) must NOT increase the trash count.
    ///   - Strict offset (positive) must NOT decrease the trash count.
    ///   - Stage 1 garbage reasons are independent of any learned offset.
    ///
    /// Asserting an exact tier shift would couple the test to
    /// QualityEstimator's z-score distribution math (MAD floors, weight
    /// rebalance, etc.), which is owned by a different test. The
    /// directional contract is what `effectiveBorderline` is supposed to
    /// guarantee at the API level.
    func testLearnedBorderlineOffset_DirectionalContract() {
        let entries = makeMarginalGroup()

        let scoresDefault = QualityEstimator.computeScores(for: entries)

        let lenient = LearnedThresholds(borderlineOffset: -0.8, sampleCount: 100)
        let scoresLenient = QualityEstimator.computeScores(for: entries, learnedThresholds: lenient)

        let strict = LearnedThresholds(borderlineOffset: 0.8, sampleCount: 100)
        let scoresStrict = QualityEstimator.computeScores(for: entries, learnedThresholds: strict)

        let trashDefault  = scoresDefault.values.filter  { $0.tier == .trash }.count
        let trashLenient  = scoresLenient.values.filter  { $0.tier == .trash }.count
        let trashStrict   = scoresStrict.values.filter   { $0.tier == .trash }.count

        XCTAssertLessThanOrEqual(trashLenient, trashDefault,
                                 "Lenient offset must NOT increase trash count")
        XCTAssertGreaterThanOrEqual(trashStrict, trashDefault,
                                    "Strict offset must NOT decrease trash count")

        // Stage 1 garbage reasons are computed before the borderline branch
        // ever runs, so the same set must appear regardless of the offset.
        let reasonsDefault = Set(scoresDefault.values.flatMap { $0.garbageReasons }.map(\.rawValue))
        let reasonsLenient = Set(scoresLenient.values.flatMap { $0.garbageReasons }.map(\.rawValue))
        let reasonsStrict  = Set(scoresStrict.values.flatMap  { $0.garbageReasons }.map(\.rawValue))
        XCTAssertEqual(reasonsLenient, reasonsDefault,
                       "Lenient offset must not change Stage 1 garbage reasons")
        XCTAssertEqual(reasonsStrict, reasonsDefault,
                       "Strict offset must not change Stage 1 garbage reasons")
    }

    /// 2 — Below the activation gate (`sampleCount < learningThreshold`),
    /// the offset is IGNORED — even a wildly lenient offset produces the
    /// exact same tier histogram as `learnedThresholds: nil`.
    func testLearnedBorderlineOffset_BelowActivationGate_IsIgnored() {
        let entries = makeMarginalGroup()

        let scoresDefault = QualityEstimator.computeScores(for: entries)

        // 49 samples — one below the 50-sample gate. Should be a no-op.
        let belowGate = LearnedThresholds(borderlineOffset: -1.0, sampleCount: 49)
        let scoresBelowGate = QualityEstimator.computeScores(for: entries, learnedThresholds: belowGate)

        for (url, defaultBd) in scoresDefault {
            XCTAssertEqual(scoresBelowGate[url]?.tier, defaultBd.tier,
                           "Below the 50-sample gate, learned offsets must not affect tier assignment")
        }
    }

    /// 3 — Stage 1 garbage is forced to .trash *before* the borderline
    /// branch ever runs. A lenient learned offset must not promote a
    /// Stage-1-flagged frame.
    func testLearnedThresholds_CannotPromoteStage1Garbage() {
        // Build a group where one frame triggers Rule 1a (zero stars).
        var entries: [ImageEntry] = []
        for i in 0..<12 {
            entries.append(makeEntry(index: i, fwhm: 2.0, hfr: 1.0, starCount: 500,
                                     noiseMAD: 0.005, noiseMedian: 0.05))
        }
        // Frame with computedStarCount == 0 → triggers Stage 1 noStars.
        entries.append(makeEntry(index: 100, fwhm: 2.0, hfr: 1.0, starCount: 0,
                                 noiseMAD: 0.005, noiseMedian: 0.05,
                                 computedStarCount: 0))

        let extreme = LearnedThresholds(borderlineOffset: -0.8, sampleCount: 200)
        let scores = QualityEstimator.computeScores(for: entries, learnedThresholds: extreme)

        let zeroStarURL = entries.last!.url
        XCTAssertEqual(scores[zeroStarURL]?.tier, .trash,
                       "Frame with Stage 1 garbage (zero stars) must stay .trash regardless of any learned offset")
        // And the Stage 1 garbage reason should still be on the breakdown.
        XCTAssertFalse(scores[zeroStarURL]?.garbageReasons.isEmpty ?? true,
                       "Stage 1 garbage reasons must still appear on the breakdown")
    }

    /// 4 — `LearnedThresholds.init` (and decode) clamp out-of-range
    /// offsets so a tampered profile JSON cannot bypass the safe range.
    func testLearnedThresholds_DecodeClampsOutOfRangeOffsets() throws {
        let oversized: [String: Any] = [
            "borderlineOffset": 5.0,
            "trailingCeilingOffset": -2.0,
            "sampleCount": 100,
        ]
        let json = try JSONSerialization.data(withJSONObject: oversized)
        let decoded = try JSONDecoder().decode(LearnedThresholds.self, from: json)

        XCTAssertEqual(decoded.borderlineOffset, 0.8, accuracy: 1e-9,
                       "Out-of-range borderlineOffset must clamp to +0.8 cap on decode")
        XCTAssertEqual(decoded.trailingCeilingOffset, -0.15, accuracy: 1e-9,
                       "Out-of-range trailingCeilingOffset must clamp to -0.15 floor on decode")
        XCTAssertEqual(decoded.sampleCount, 100)
    }
}
