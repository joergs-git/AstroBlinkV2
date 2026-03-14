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
    private func makeGroup(count: Int, fwhm: Double = 3.0, hfr: Double = 2.0, starCount: Int = 500, noiseMAD: Float = 0.01, filter: String = "H") -> [ImageEntry] {
        (0..<count).map {
            makeEntry(index: $0, filter: filter, fwhm: fwhm, hfr: hfr, starCount: starCount, noiseMAD: noiseMAD)
        }
    }

    // MARK: - Tests

    func testMinGroupSizePreventsScoring() {
        // 19 entries = below minGroupSize (20) → no tiers assigned
        let entries = makeGroup(count: 19)
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertTrue(scores.isEmpty, "Groups smaller than minGroupSize should produce no scores")
    }

    func testExactMinGroupSizeProducesScores() {
        // Exactly 20 entries should produce scores
        var entries = makeGroup(count: 20)
        // Make one slightly different to avoid all-identical edge case
        entries[0].fwhm = 4.0
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertFalse(scores.isEmpty, "Group of exactly minGroupSize should produce scores")
    }

    func testIdenticalFramesAllUncertain() {
        // 25 identical entries → z=0 for all → all should be .uncertain
        // (z=0 falls between thresholdTrash=-1.0 and thresholdGood=0.5)
        let entries = makeGroup(count: 25)
        let scores = QualityEstimator.computeScores(for: entries)

        XCTAssertEqual(scores.count, 25, "All 25 entries should receive a score")
        for entry in entries {
            XCTAssertEqual(scores[entry.url], .uncertain,
                           "Identical frames should all be .uncertain (z=0)")
        }
    }

    func testClearOutlierDetectedAsTrash() {
        // 24 frames with FWHM=3.0 + 1 frame with FWHM=10.0 (dramatically worse)
        var entries = makeGroup(count: 24)
        var outlier = makeEntry(index: 99, fwhm: 10.0, hfr: 8.0, starCount: 50, noiseMAD: 0.05)
        entries.append(outlier)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[outlier.url], .trash,
                       "A frame with dramatically worse metrics should be .trash")
    }

    func testBestFrameDetectedAsGood() {
        // 24 frames with mediocre FWHM + 1 frame with excellent FWHM
        var entries = makeGroup(count: 24, fwhm: 5.0, hfr: 4.0, starCount: 200, noiseMAD: 0.02)
        let best = makeEntry(index: 99, fwhm: 1.5, hfr: 1.0, starCount: 800, noiseMAD: 0.005)
        entries.append(best)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[best.url], .good,
                       "A frame with clearly superior metrics should be .good")
    }

    func testNarrowbandReducesStarWeight() {
        // Narrowband filter "Ha" → star count weight should be 0.3 instead of 1.0
        // Create a group where one frame has low star count but good FWHM/HFR/noise
        // With full star weight, it might be penalized. With reduced weight, it should be fine.
        var entries = makeGroup(count: 24, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01, filter: "Ha")
        // Frame with fewer stars but excellent seeing — 200/500 = 40%, above 25% NB garbage threshold
        let entry = makeEntry(index: 99, filter: "Ha", fwhm: 1.5, hfr: 1.0, starCount: 200, noiseMAD: 0.005)
        entries.append(entry)

        let scores = QualityEstimator.computeScores(for: entries)
        // Despite having only 100 stars vs 500, the frame's excellent FWHM/HFR/noise
        // should keep it at .good or at least .uncertain with reduced star weight
        XCTAssertNotEqual(scores[entry.url], .trash,
                          "Narrowband frame with low stars but good metrics should not be trash")
    }

    func testGroupingByFilterObjectExposure() {
        // Two groups of 20 with different filters → scored independently
        var hGroup = makeGroup(count: 20, fwhm: 3.0, filter: "H")
        var oGroup = (0..<20).map {
            makeEntry(index: 100 + $0, filter: "O", fwhm: 4.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }

        // Make one H-frame an outlier within its group
        hGroup[0].fwhm = 10.0
        hGroup[0].hfr = 8.0
        hGroup[0].noiseMAD = 0.05

        let entries = hGroup + oGroup
        let scores = QualityEstimator.computeScores(for: entries)

        // The H-outlier should be trash in its group
        XCTAssertEqual(scores[hGroup[0].url], .trash,
                       "Outlier in H group should be trash")

        // O-group frames should all be .uncertain (identical within group)
        for entry in oGroup {
            XCTAssertEqual(scores[entry.url], .uncertain,
                           "Identical O-group frames should all be uncertain")
        }
    }

    func testZscoresWithZeroStdDev() {
        // All identical values → std=0 → z-scores should be 0 (not NaN or crash)
        let entries = makeGroup(count: 25, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        let scores = QualityEstimator.computeScores(for: entries)

        // Should not crash, and all entries should get a tier
        XCTAssertEqual(scores.count, 25, "Zero std dev should produce valid scores (z=0)")
    }

    func testNegatedZscoresForLowerIsBetter() {
        // FWHM and HFR are negated (lower = better).
        // A frame with LOWER FWHM/HFR should score HIGHER (more positive combined z).
        var entries = makeGroup(count: 24, fwhm: 5.0, hfr: 4.0, noiseMAD: 0.02)
        let betterSeeing = makeEntry(index: 99, fwhm: 1.0, hfr: 0.5, starCount: 500, noiseMAD: 0.002)
        entries.append(betterSeeing)

        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertEqual(scores[betterSeeing.url], .good,
                       "Lower FWHM/HFR (negated z) should result in .good tier")
    }

    func testMixedNilMetrics() {
        // Some entries have FWHM, some don't → scoring should still work via available metrics
        var entries: [ImageEntry] = []
        for i in 0..<25 {
            let fwhm: Double? = i < 15 ? 3.0 : nil  // 15 have FWHM, 10 don't
            entries.append(makeEntry(index: i, fwhm: fwhm, noiseMAD: 0.01))
        }
        // Make one frame clearly worse in noise (the only universal metric here)
        entries[0].noiseMAD = 0.1

        let scores = QualityEstimator.computeScores(for: entries)
        // Should not crash — noiseMAD provides a scoring dimension for all
        XCTAssertFalse(scores.isEmpty, "Mixed nil metrics should still produce scores")
    }

    func testDifferentExposuresSeparateGroups() {
        // Same filter+target but different exposure → separate groups
        let group300 = (0..<15).map {
            makeEntry(index: $0, exposure: 300.0, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }
        let group180 = (0..<15).map {
            makeEntry(index: 100 + $0, exposure: 180.0, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01)
        }

        let entries = group300 + group180
        let scores = QualityEstimator.computeScores(for: entries)

        // Neither group reaches minGroupSize (20) → no scores
        XCTAssertTrue(scores.isEmpty,
                      "Groups of 15 (split by exposure) should not produce scores")
    }

    func testPerGroupSourceConsistency() {
        // If not ALL entries have header FWHM, computed FWHM should be used for entire group
        var entries: [ImageEntry] = []
        for i in 0..<25 {
            if i == 0 {
                // First entry: has header FWHM but NOT computed
                entries.append(makeEntry(index: i, fwhm: 3.0, hfr: 2.0, starCount: 500, noiseMAD: 0.01))
            } else {
                // Rest: have computed FWHM but not header
                entries.append(makeEntry(index: i, noiseMAD: 0.01, computedFWHM: 3.0, computedHFR: 2.0, computedStarCount: 500))
            }
        }

        let scores = QualityEstimator.computeScores(for: entries)
        // The first entry has header FWHM but group doesn't ALL have it,
        // so computed values should be used. Entry 0 has no computedFWHM → nil.
        // This is the expected behavior: consistency over per-image best source.
        XCTAssertFalse(scores.isEmpty, "Mixed source groups should still score via computed values")
    }
}
