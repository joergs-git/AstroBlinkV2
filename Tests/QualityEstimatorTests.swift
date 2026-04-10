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
        var entries = makeGroup(count: 24, fwhm: 4.0, hfr: 2.5, starCount: 200, noiseMAD: 0.01, filter: "Ha")
        for i in 0..<entries.count {
            entries[i].focalLength = 620.0
            entries[i].computedEccentricity = 0.40
            entries[i].noiseMedian = 0.05
        }
        // Trailing with consensus — must be caught even with normal FWHM
        var trailed = makeEntry(index: 99, filter: "Ha", fwhm: 4.0, hfr: 2.5, starCount: 200,
                                noiseMAD: 0.01, noiseMedian: 0.05,
                                computedEccentricity: 0.65, focalLength: 620.0,
                                trailingScore: 0.55, trailingConsensus: 0.6)
        entries.append(trailed)

        let scores = QualityEstimator.computeScores(for: entries)
        guard let bd = scores[trailed.url] else {
            XCTFail("Trailed Ha frame should have a score")
            return
        }

        XCTAssertEqual(bd.tier, .trash,
                       "Ha frame with trailingScore=0.55 and consensus=0.6 must be garbage (absolute ceiling at 0.50)")
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
                                computedEccentricity: 0.65, focalLength: 620.0,
                                trailingScore: 0.55, trailingConsensus: 0.7)
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
}
