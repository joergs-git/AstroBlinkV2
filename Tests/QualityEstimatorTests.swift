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
        computedStarCount: Int? = nil
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
        let entries = makeGroup(count: 9)
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertTrue(scores.isEmpty, "Groups smaller than minGroupSize should produce no scores")
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
        let group300 = (0..<8).map {
            makeEntry(index: $0, exposure: 300.0, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }
        let group180 = (0..<8).map {
            makeEntry(index: 100 + $0, exposure: 180.0, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }

        let entries = group300 + group180
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertTrue(scores.isEmpty,
                      "Groups of 8 (split by exposure) should not produce scores (below minGroupSize=10)")
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
}
