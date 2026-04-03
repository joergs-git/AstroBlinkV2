import XCTest
@testable import AstroTriage

// Golden-set regression tests using real metric values from validated datasets.
// These tests catch scoring regressions BEFORE the user sees them.
// Run automatically on every build — if any trailing/garbage detection breaks,
// the test fails immediately.
//
// Based on: wiki/quality-testing-log.md golden set (1,638 frames, 7 setups)
// Metric values derived from actual M82, IC63, NGC7635 imaging sessions.

final class ScoringRegressionTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(
        index: Int, filter: String = "L", target: String = "M 82", exposure: Double = 180.0,
        computedFWHM: Double? = nil, computedHFR: Double? = nil,
        computedStarCount: Int? = nil, computedEccentricity: Double? = nil,
        noiseMAD: Float? = nil, noiseMedian: Float? = nil,
        focalLength: Double = 2455.0, trailingScore: Double? = nil,
        trailingConsensus: Double? = nil, starChainFraction: Double? = nil,
        twilightPhase: TwilightPhase? = nil, date: String = "2026-03-18"
    ) -> ImageEntry {
        let url = URL(fileURLWithPath: "/tmp/golden_\(filter)_\(index).xisf")
        var entry = ImageEntry(url: url)
        entry.filter = filter
        entry.target = target
        entry.exposure = exposure
        entry.computedFWHM = computedFWHM
        entry.computedHFR = computedHFR
        entry.computedStarCount = computedStarCount
        entry.computedEccentricity = computedEccentricity
        entry.noiseMAD = noiseMAD
        entry.noiseMedian = noiseMedian
        entry.focalLength = focalLength
        entry.trailingScore = trailingScore
        entry.trailingConsensus = trailingConsensus
        entry.starChainFraction = starChainFraction
        entry.twilightPhase = twilightPhase
        entry.date = date
        entry.width = 9576
        entry.height = 6388
        entry.pixelSizeMicrons = 3.76
        return entry
    }

    // MARK: - M82 Trailing Regression (CRITICAL)
    // January M82 frames have severe tracking errors. These MUST be detected.
    // This test catches the exact regression where FL-bucketing or MAD floors
    // cause uniformly bad groups to escape detection.

    func testM82_JanuaryTrailingFramesMustBeDetected() {
        // 15 good March frames (good tracking, low trailing)
        var entries: [ImageEntry] = (0..<15).map { i in
            makeEntry(index: i, filter: "B", target: "M 82", exposure: 180,
                computedFWHM: 7.0 + Double(i % 5) * 0.2,
                computedHFR: 3.8 + Double(i % 5) * 0.1,
                computedStarCount: 3800 + i * 30,
                computedEccentricity: 0.38 + Double(i % 3) * 0.02,
                noiseMAD: 0.005, noiseMedian: 0.05,
                focalLength: 2455.0,
                trailingScore: 0.05 + Double(i % 4) * 0.02,
                trailingConsensus: 0.15,
                date: "2026-03-18")
        }

        // 15 bad January frames (tracking errors — high FWHM, high trailing, high ecc)
        let janFrames: [ImageEntry] = (0..<15).map { i in
            makeEntry(index: 100 + i, filter: "B", target: "M 82", exposure: 180,
                computedFWHM: 9.5 + Double(i % 5) * 0.5,
                computedHFR: 5.0 + Double(i % 5) * 0.3,
                computedStarCount: 2600 + i * 40,
                computedEccentricity: 0.55 + Double(i % 4) * 0.03,
                noiseMAD: 0.007, noiseMedian: 0.05,
                focalLength: 2455.0,
                trailingScore: 0.35 + Double(i % 5) * 0.06,
                trailingConsensus: 0.65,
                date: "2026-01-19")
        }
        entries.append(contentsOf: janFrames)

        let scores = QualityEstimator.computeScores(for: entries)

        // Count how many January frames are detected as non-good (trash or borderline)
        var janTrash = 0
        var janBorderline = 0
        var janGood = 0
        for i in 0..<15 {
            let url = janFrames[i].url
            guard let bd = scores[url] else { janGood += 1; continue }
            switch bd.tier {
            case .trash: janTrash += 1
            case .borderline: janBorderline += 1
            default: janGood += 1
            }
        }

        // CRITICAL ASSERTION: At least 60% of January trailing frames must be
        // detected as non-good (trash + borderline). Historical baseline: 78%.
        let detectedPercent = Double(janTrash + janBorderline) / 15.0 * 100.0
        XCTAssertGreaterThanOrEqual(detectedPercent, 60.0,
            "M82 January trailing detection: \(janTrash) trash + \(janBorderline) borderline = \(Int(detectedPercent))% (need ≥60%). \(janGood) escaped as good.")

        // No March frame should be trash
        for i in 0..<15 {
            let bd = scores[entries[i].url]
            XCTAssertNotEqual(bd?.tier, .trash,
                "March frame \(i) must NOT be trash (FWHM \(entries[i].computedFWHM!))")
        }
    }

    // MARK: - M82 Chain Detection Regression
    // January M82 frames with tracking hops (star chains) must be detected.

    func testM82_TrackingHopsMustBeDetected() {
        // 10 good frames
        var entries: [ImageEntry] = (0..<10).map { i in
            makeEntry(index: i, filter: "L", target: "M 82", exposure: 180,
                computedFWHM: 5.5 + Double(i % 3) * 0.3,
                computedHFR: 3.5 + Double(i % 3) * 0.2,
                computedStarCount: 4000 + i * 50,
                noiseMAD: 0.005, noiseMedian: 0.05,
                trailingScore: 0.05, trailingConsensus: 0.1,
                starChainFraction: 0.02,
                date: "2026-03-18")
        }

        // 5 frames with tracking hops (star chains > 0.25)
        for i in 0..<5 {
            entries.append(makeEntry(index: 50 + i, filter: "L", target: "M 82", exposure: 180,
                computedFWHM: 8.0 + Double(i) * 0.3,
                computedHFR: 5.0 + Double(i) * 0.2,
                computedStarCount: 3000 + i * 40,
                noiseMAD: 0.007, noiseMedian: 0.05,
                trailingScore: 0.30 + Double(i) * 0.05,
                trailingConsensus: 0.5,
                starChainFraction: 0.30 + Double(i) * 0.05,
                date: "2026-01-19"))
        }

        let scores = QualityEstimator.computeScores(for: entries)

        for i in 0..<5 {
            let url = entries[10 + i].url
            let reasons = scores[url]?.garbageReasons ?? []
            XCTAssertTrue(reasons.contains(.trackingHop),
                "Chain frame \(i) (chainFraction=\(entries[10+i].starChainFraction!)) must trigger R9")
        }
    }

    // MARK: - Dark Frame Isolation Regression
    // Dark frames must be detected AND must not corrupt group statistics.

    func testDarkFrameDetectionAndIsolation() {
        var entries: [ImageEntry] = (0..<15).map { i in
            makeEntry(index: i, computedFWHM: 5.0 + Double(i % 3) * 0.2,
                computedHFR: 3.2, computedStarCount: 3500 + i * 20,
                noiseMAD: 0.005, noiseMedian: 0.05,
                trailingScore: 0.05, trailingConsensus: 0.1)
        }

        // 2 dark frames (dome closed) — stars ≥ 10000 triggers Path A
        for i in 0..<2 {
            entries.append(makeEntry(index: 90 + i,
                computedFWHM: 3.0, computedHFR: 1.5,
                computedStarCount: 16000,
                noiseMAD: 0.001, noiseMedian: 0.001,
                trailingScore: 0.0, trailingConsensus: 0.0))
        }

        // 1 real wide-field frame at low gain with many stars — must NOT trigger R0b
        entries.append(makeEntry(index: 95,
            computedFWHM: 4.0, computedHFR: 1.6,
            computedStarCount: 5200,
            noiseMAD: 0.003, noiseMedian: 0.0025,
            trailingScore: 0.05, trailingConsensus: 0.1))

        let scores = QualityEstimator.computeScores(for: entries)

        // Dark frames must be trash with noisePeaks reason
        for i in 0..<2 {
            let reasons = scores[entries[15 + i].url]?.garbageReasons ?? []
            XCTAssertTrue(reasons.contains(.noisePeaks),
                "Dark frame \(i) must trigger R0b")
        }

        // Real frames must not be affected
        for i in 0..<15 {
            let tier = scores[entries[i].url]?.tier
            XCTAssertNotEqual(tier, .trash,
                "Real frame \(i) must not be trashed by dark frame contamination")
        }
    }

    // MARK: - Narrowband Trailing Preservation
    // Ha frames with moderate trailing must NOT be trashed (precious integration time).

    func testNarrowbandModerateTrailingPreserved() {
        var entries: [ImageEntry] = (0..<15).map { i in
            makeEntry(index: i, filter: "Ha", target: "IC1805", exposure: 300,
                computedFWHM: 4.5 + Double(i % 4) * 0.2,
                computedHFR: 2.8 + Double(i % 4) * 0.1,
                computedStarCount: 350 + i * 10,
                noiseMAD: 0.008, noiseMedian: 0.04,
                focalLength: 620.0,
                trailingScore: 0.10 + Double(i % 5) * 0.04,
                trailingConsensus: 0.3)
        }

        // 3 frames with moderate trailing (score 0.30-0.40) — should be preserved for NB
        for i in 0..<3 {
            entries.append(makeEntry(index: 50 + i, filter: "Ha", target: "IC1805", exposure: 300,
                computedFWHM: 5.0 + Double(i) * 0.2,
                computedHFR: 3.2 + Double(i) * 0.1,
                computedStarCount: 300 + i * 10,
                noiseMAD: 0.009, noiseMedian: 0.04,
                focalLength: 620.0,
                trailingScore: 0.30 + Double(i) * 0.05,
                trailingConsensus: 0.45))
        }

        let scores = QualityEstimator.computeScores(for: entries)

        for i in 0..<3 {
            let url = entries[15 + i].url
            let reasons = scores[url]?.garbageReasons ?? []
            XCTAssertFalse(reasons.contains(.elongated),
                "Ha frame with trailing=\(entries[15+i].trailingScore!) must NOT be trashed (narrowband preservation)")
        }
    }

    // MARK: - Narrowband Severe Trailing Detection
    // Ha frames with SEVERE trailing (>0.50 + high consensus) MUST be caught by R6a.

    func testNarrowbandSevereTrailingDetected() {
        var entries: [ImageEntry] = (0..<12).map { i in
            makeEntry(index: i, filter: "Ha", target: "NGC7635", exposure: 300,
                computedFWHM: 4.0 + Double(i % 3) * 0.2,
                computedHFR: 2.5, computedStarCount: 400 + i * 10,
                noiseMAD: 0.007, noiseMedian: 0.04,
                focalLength: 2423.0,
                trailingScore: 0.08 + Double(i % 4) * 0.03,
                trailingConsensus: 0.2)
        }

        // 3 frames with severe trailing
        for i in 0..<3 {
            entries.append(makeEntry(index: 50 + i, filter: "Ha", target: "NGC7635", exposure: 300,
                computedFWHM: 5.5 + Double(i) * 0.3,
                computedHFR: 3.5, computedStarCount: 250,
                computedEccentricity: 0.65 + Double(i) * 0.05,
                noiseMAD: 0.009, noiseMedian: 0.04,
                focalLength: 2423.0,
                trailingScore: 0.55 + Double(i) * 0.05,
                trailingConsensus: 0.7))
        }

        let scores = QualityEstimator.computeScores(for: entries)

        for i in 0..<3 {
            let url = entries[12 + i].url
            let tier = scores[url]?.tier
            XCTAssertEqual(tier, .trash,
                "Ha frame with trailing=\(entries[12+i].trailingScore!) + consensus=0.7 must be trash")
        }
    }

    // MARK: - Cross-Setup Session (RASA + RC12 same target)
    // Frames from different setups must be scored in separate groups but
    // session sanity must still catch bad nights across setups.

    func testCrossSetup_SeparateGroupScoring() {
        // 10 RASA frames (FL 620, good quality)
        var entries: [ImageEntry] = (0..<10).map { i in
            makeEntry(index: i, filter: "Ha", target: "IC1805", exposure: 300,
                computedFWHM: 3.5 + Double(i % 3) * 0.2,
                computedHFR: 2.2 + Double(i % 3) * 0.1,
                computedStarCount: 600 + i * 20,
                noiseMAD: 0.006, noiseMedian: 0.04,
                focalLength: 620.0,
                trailingScore: 0.05, trailingConsensus: 0.1,
                date: "2026-03-18")
        }

        // 10 RC12 frames (FL 2423, also good quality but different FWHM scale)
        for i in 0..<10 {
            entries.append(makeEntry(index: 50 + i, filter: "Ha", target: "IC1805", exposure: 300,
                computedFWHM: 6.0 + Double(i % 3) * 0.3,
                computedHFR: 3.8 + Double(i % 3) * 0.2,
                computedStarCount: 200 + i * 10,
                noiseMAD: 0.008, noiseMedian: 0.04,
                focalLength: 2423.0,
                trailingScore: 0.08, trailingConsensus: 0.15,
                date: "2026-03-18"))
        }

        let scores = QualityEstimator.computeScores(for: entries)

        // RC12 frames with FWHM 6.0-6.6 must NOT be trashed just because
        // RASA frames have FWHM 3.5 (different plate scale, different group)
        for i in 0..<10 {
            let tier = scores[entries[10 + i].url]?.tier
            XCTAssertNotEqual(tier, .trash,
                "RC12 frame \(i) (FWHM \(entries[10+i].computedFWHM!)) must not be trashed by RASA comparison")
        }
    }

    // MARK: - Tight Session Common Sense
    // Uniform quality sessions must not penalize the "worst" frame when
    // all frames are within insignificant differences.

    func testTightSession_FWHMVariationInsignificant() {
        // 20 frames with FWHM 4.0-4.4 (0.4px range — sub-pixel, invisible)
        let entries: [ImageEntry] = (0..<20).map { i in
            let fwhm = 4.0 + Double(i) * 0.02
            return makeEntry(index: i, filter: "L", target: "NGC3184",
                computedFWHM: fwhm, computedHFR: fwhm * 0.65,
                computedStarCount: 1400 + (i * 7) % 40 - 20,
                noiseMAD: 0.005 + Float((i * 3) % 10) * 0.00005,
                noiseMedian: 0.05,
                focalLength: 904.0,
                trailingScore: 0.04 + Double((i * 5) % 8) * 0.005,
                trailingConsensus: 0.1)
        }

        let scores = QualityEstimator.computeScores(for: entries)

        var trashCount = 0
        for i in 0..<20 {
            if scores[entries[i].url]?.tier == .trash { trashCount += 1 }
        }
        XCTAssertEqual(trashCount, 0,
            "Tight session (FWHM 4.0-4.4) must have zero trash frames, got \(trashCount)")
    }

    // MARK: - Planet Exclusion

    func testPlanetFramesProduceNoScores() {
        let entries: [ImageEntry] = (0..<8).map { i in
            makeEntry(index: i, filter: "L", target: "Jupiter", exposure: 0.05,
                computedStarCount: 2, noiseMAD: 0.002, noiseMedian: 0.003, focalLength: 2000)
        }
        let scores = QualityEstimator.computeScores(for: entries)
        XCTAssertTrue(scores.isEmpty, "Planet targets must produce no scores")
    }

    // MARK: - Tier Distribution Sanity
    // In a mixed session with good and bad frames, the distribution must be reasonable.

    func testMixedSession_TierDistributionSanity() {
        var entries: [ImageEntry] = []

        // 20 good frames (normal seeing, clean tracking)
        for i in 0..<20 {
            entries.append(makeEntry(index: i, filter: "L", target: "M 82", exposure: 180,
                computedFWHM: 5.5 + Double(i % 5) * 0.3,
                computedHFR: 3.5 + Double(i % 5) * 0.2,
                computedStarCount: 4000 + i * 50,
                computedEccentricity: 0.35 + Double(i % 3) * 0.02,
                noiseMAD: 0.005, noiseMedian: 0.05,
                trailingScore: 0.05 + Double(i % 4) * 0.02,
                trailingConsensus: 0.1,
                date: "2026-03-18"))
        }

        // 5 garbage frames (severe defocus)
        for i in 0..<5 {
            entries.append(makeEntry(index: 80 + i, filter: "L", target: "M 82", exposure: 180,
                computedFWHM: 14.0 + Double(i) * 1.0,
                computedHFR: 9.0 + Double(i) * 0.5,
                computedStarCount: 800 + i * 50,
                computedEccentricity: 0.30,
                noiseMAD: 0.012, noiseMedian: 0.05,
                trailingScore: 0.03, trailingConsensus: 0.1,
                date: "2026-03-18"))
        }

        let scores = QualityEstimator.computeScores(for: entries)

        var tiers: [QualityTier: Int] = [:]
        for entry in entries {
            if let t = scores[entry.url]?.tier {
                tiers[t, default: 0] += 1
            }
        }

        // Defocused frames must be trash (FWHM >2x median)
        let trashCount = tiers[.trash, default: 0]
        XCTAssertGreaterThanOrEqual(trashCount, 4,
            "At least 4 of 5 defocused frames must be trash, got \(trashCount)")

        // Good frames must mostly be good/excellent
        let goodExcellent = (tiers[.good, default: 0]) + (tiers[.excellent, default: 0])
        XCTAssertGreaterThanOrEqual(goodExcellent, 15,
            "At least 15 of 20 good frames must be good/excellent, got \(goodExcellent)")
    }
}
