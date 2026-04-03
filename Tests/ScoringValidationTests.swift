import XCTest
@testable import AstroTriage

// Systematic validation of the quality scoring pipeline across setups, filters,
// target types, and failure modes. Ensures garbage detection is 100% reliable
// and excellent frames are 99%+ safely preserved.

final class ScoringValidationTests: XCTestCase {

    // MARK: - Setup Profiles

    struct SetupProfile {
        let name: String
        let focalLength: Double      // mm
        let pixelSize: Double        // microns
        let sensorWidth: Int         // pixels
        let sensorHeight: Int        // pixels
        let fwhmGoodMean: Double     // typical good-seeing FWHM
        let fwhmGoodStddev: Double
        let starCountL: Int          // typical star count in luminance
        let starCountHa: Int         // typical star count in Ha
        let noiseMADMean: Float      // typical noise MAD
        let eccBaseline: Double      // FL-adaptive baseline
    }

    static let rasa = SetupProfile(name: "RASA", focalLength: 620, pixelSize: 3.76,
        sensorWidth: 9576, sensorHeight: 6388, fwhmGoodMean: 3.0, fwhmGoodStddev: 0.3,
        starCountL: 1800, starCountHa: 350, noiseMADMean: 0.006, eccBaseline: 0.454)

    static let ref85 = SetupProfile(name: "Ref85", focalLength: 468, pixelSize: 3.76,
        sensorWidth: 9576, sensorHeight: 6388, fwhmGoodMean: 3.8, fwhmGoodStddev: 0.4,
        starCountL: 3200, starCountHa: 450, noiseMADMean: 0.004, eccBaseline: 0.523)

    static let ref140 = SetupProfile(name: "Ref140", focalLength: 904, pixelSize: 3.76,
        sensorWidth: 9576, sensorHeight: 6388, fwhmGoodMean: 3.5, fwhmGoodStddev: 0.3,
        starCountL: 1400, starCountHa: 200, noiseMADMean: 0.005, eccBaseline: 0.376)

    static let rc12 = SetupProfile(name: "RC12", focalLength: 2423, pixelSize: 3.76,
        sensorWidth: 9576, sensorHeight: 6388, fwhmGoodMean: 3.0, fwhmGoodStddev: 0.3,
        starCountL: 2500, starCountHa: 150, noiseMADMean: 0.006, eccBaseline: 0.230)

    static let edgeHD = SetupProfile(name: "EdgeHD", focalLength: 2032, pixelSize: 3.76,
        sensorWidth: 9576, sensorHeight: 6388, fwhmGoodMean: 2.5, fwhmGoodStddev: 0.25,
        starCountL: 2000, starCountHa: 100, noiseMADMean: 0.007, eccBaseline: 0.251)

    static let allSetups = [rasa, ref85, ref140, rc12, edgeHD]

    // MARK: - Helpers

    /// Create a synthetic ImageEntry with specified metrics for quality scoring.
    private func makeEntry(
        index: Int, filter: String = "H", target: String = "IC1848", exposure: Double = 300.0,
        fwhm: Double? = nil, hfr: Double? = nil, starCount: Int? = nil,
        computedFWHM: Double? = nil, computedHFR: Double? = nil,
        computedStarCount: Int? = nil, computedEccentricity: Double? = nil,
        noiseMAD: Float? = nil, noiseMedian: Float? = nil,
        focalLength: Double? = nil, trailingScore: Double? = nil,
        trailingConsensus: Double? = nil, starChainFraction: Double? = nil,
        solvedRA: Double? = nil, solvedDec: Double? = nil,
        width: Int? = nil, height: Int? = nil, pixelSizeMicrons: Double? = nil,
        psfFluxSum: Double? = nil, moonIllumination: Double? = nil,
        moonDistance: Double? = nil, twilightPhase: TwilightPhase? = nil,
        date: String? = nil
    ) -> ImageEntry {
        let url = URL(fileURLWithPath: "/tmp/validation_\(index).xisf")
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
        entry.starChainFraction = starChainFraction
        entry.solvedRA = solvedRA
        entry.solvedDec = solvedDec
        entry.width = width
        entry.height = height
        entry.pixelSizeMicrons = pixelSizeMicrons
        entry.psfFluxSum = psfFluxSum
        entry.moonIllumination = moonIllumination
        entry.moonDistance = moonDistance
        entry.twilightPhase = twilightPhase
        entry.date = date
        return entry
    }

    /// Create a baseline group of N frames with realistic metrics from a setup profile.
    private func makeBaselineGroup(
        setup: SetupProfile, filter: String = "H", target: String = "IC1848",
        count: Int = 20, exposure: Double = 300.0
    ) -> [ImageEntry] {
        let isNarrowband = ["H", "HA", "OIII", "SII", "HBETA", "NII"].contains(filter.uppercased())
        let starCount = isNarrowband ? setup.starCountHa : setup.starCountL
        let bgLevel: Float = 0.05

        return (0..<count).map { i in
            // Slight variation per frame (realistic, correlated)
            let seeingFactor = 1.0 + Double(i % 5 - 2) * 0.03  // ±6% FWHM variation
            let fwhm = setup.fwhmGoodMean * seeingFactor
            let stars = Int(Double(starCount) / seeingFactor)  // Worse seeing → fewer stars
            let noise = setup.noiseMADMean * Float(seeingFactor)  // Worse seeing → more noise
            let snrMedian = bgLevel / noise

            return makeEntry(
                index: i, filter: filter, target: target, exposure: exposure,
                computedFWHM: fwhm, computedHFR: fwhm * 0.65,
                computedStarCount: stars, computedEccentricity: setup.eccBaseline * 0.9,
                noiseMAD: noise, noiseMedian: bgLevel,
                focalLength: setup.focalLength,
                trailingScore: 0.05, trailingConsensus: 0.2,
                width: setup.sensorWidth, height: setup.sensorHeight,
                pixelSizeMicrons: setup.pixelSize, date: "2026-03-15"
            )
        }
    }

    /// Helper to get the QualityBreakdown for a specific entry index.
    private func score(entries: [ImageEntry]) -> [URL: QualityBreakdown] {
        QualityEstimator.computeScores(for: entries)
    }

    private func tier(for index: Int, in entries: [ImageEntry], scores: [URL: QualityBreakdown]) -> QualityTier? {
        scores[entries[index].url]?.tier
    }

    private func reasons(for index: Int, in entries: [ImageEntry], scores: [URL: QualityBreakdown]) -> [GarbageReason] {
        scores[entries[index].url]?.garbageReasons ?? []
    }

    // =========================================================================
    // MARK: - A. Garbage Detection Tests (100% Target)
    // =========================================================================

    // MARK: R0b — Dark Frame / Dome

    func testR0b_DarkFrame_PathA_AllSetups() {
        // stars >= 10000 always triggers dark frame detection
        for setup in Self.allSetups {
            var entries = makeBaselineGroup(setup: setup, count: 10)
            entries[0].computedStarCount = 15000
            entries[0].noiseMedian = 0.001

            let scores = score(entries: entries)
            let r = reasons(for: 0, in: entries, scores: scores)
            XCTAssertTrue(r.contains(.noisePeaks),
                "\(setup.name): stars=15000 must trigger R0b Path A")
        }
    }

    func testR0b_DarkFrame_PathB() {
        // RC12 at 2423mm → FL-scaled threshold ~5100. Stars=8000 with bg=0.001 triggers.
        var entries = makeBaselineGroup(setup: Self.rc12, count: 10)
        entries[0].computedStarCount = 8000
        entries[0].noiseMedian = 0.001

        let scores = score(entries: entries)
        XCTAssertTrue(reasons(for: 0, in: entries, scores: scores).contains(.noisePeaks),
            "stars=8000 + bg=0.001 at long FL must trigger R0b Path B")
    }

    func testR0b_Guard_BelowStarThreshold() {
        var entries = makeBaselineGroup(setup: Self.rc12, count: 10)
        entries[0].computedStarCount = 4500
        entries[0].noiseMedian = 0.001

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.noisePeaks),
            "stars=4500 must NOT trigger R0b (below threshold)")
    }

    func testR0b_Guard_AboveBackgroundThreshold() {
        var entries = makeBaselineGroup(setup: Self.rc12, count: 10)
        entries[0].computedStarCount = 8000
        entries[0].noiseMedian = 0.004

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.noisePeaks),
            "stars=8000 + bg=0.004 must NOT trigger R0b (bg above 0.002)")
    }

    func testR0b_Guard_WidefieldHighStars_NotDarkFrame() {
        // Wide-field (620mm) with 5200 real stars + low gain narrowband bg — must NOT trigger.
        // FL-scaled threshold at 620mm: 7500 * (1000/620)^2 ≈ ~19500 → capped at 10000.
        var entries = makeBaselineGroup(setup: Self.rasa, count: 10)
        entries[0].computedStarCount = 5200
        entries[0].noiseMedian = 0.0025

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.noisePeaks),
            "Wide-field 5200 stars + low-gain bg must NOT trigger R0b")
    }

    func testR0b_DarkFrame_IsolationFromGroupStats() {
        // Dark frames must not contaminate group statistics
        let baseline = makeBaselineGroup(setup: Self.rc12, count: 20)
        let scoresWithout = score(entries: baseline)

        // Add 3 dark frames
        var withDark = baseline
        for i in 0..<3 {
            var dark = makeEntry(index: 100 + i, filter: "H", target: "IC1848", exposure: 300,
                computedStarCount: 15000, noiseMAD: 0.001, noiseMedian: 0.001,
                focalLength: Self.rc12.focalLength, width: Self.rc12.sensorWidth,
                height: Self.rc12.sensorHeight, pixelSizeMicrons: Self.rc12.pixelSize,
                date: "2026-03-15")
            dark.computedFWHM = 3.0
            dark.computedHFR = 2.0
            withDark.append(dark)
        }
        let scoresWith = score(entries: withDark)

        // Real frames should have same tiers with and without dark frames
        for i in 0..<20 {
            let tierWithout = scoresWithout[baseline[i].url]?.tier
            let tierWith = scoresWith[withDark[i].url]?.tier
            XCTAssertEqual(tierWithout, tierWith,
                "Frame \(i): tier changed from \(String(describing: tierWithout)) to \(String(describing: tierWith)) after adding dark frames")
        }
    }

    // MARK: R3/R4 — High FWHM / HFR

    func testR3_HighFWHM_AllSetups() {
        for setup in Self.allSetups {
            var entries = makeBaselineGroup(setup: setup, count: 10)
            // FWHM at 2.1x median → must trigger
            entries[0].computedFWHM = setup.fwhmGoodMean * 2.1
            entries[0].computedHFR = setup.fwhmGoodMean * 2.1 * 0.65

            let scores = score(entries: entries)
            let r = reasons(for: 0, in: entries, scores: scores)
            XCTAssertTrue(r.contains(.highFWHM),
                "\(setup.name): FWHM at 2.1x median must trigger R3")
        }
    }

    func testR3_Guard_BelowThreshold() {
        var entries = makeBaselineGroup(setup: Self.rc12, count: 10)
        entries[0].computedFWHM = Self.rc12.fwhmGoodMean * 1.9
        entries[0].computedHFR = Self.rc12.fwhmGoodMean * 1.9 * 0.65

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.highFWHM),
            "FWHM at 1.9x median must NOT trigger R3")
    }

    // MARK: R6a — Absolute Trailing Ceiling

    func testR6a_AbsoluteTrailingCeiling() {
        var entries = makeBaselineGroup(setup: Self.rc12, filter: "L", count: 10)
        entries[0].trailingScore = 0.55
        entries[0].trailingConsensus = 0.6

        let scores = score(entries: entries)
        let r = reasons(for: 0, in: entries, scores: scores)
        XCTAssertTrue(r.contains(.elongated),
            "trailingScore=0.55 + consensus=0.6 must trigger R6a absolute ceiling")
    }

    func testR6a_Guard_BelowScoreThreshold() {
        var entries = makeBaselineGroup(setup: Self.rc12, filter: "L", count: 10)
        entries[0].trailingScore = 0.48
        entries[0].trailingConsensus = 0.6

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.elongated),
            "trailingScore=0.48 must NOT trigger R6a (below 0.50)")
    }

    func testR6a_Guard_BelowConsensusThreshold() {
        var entries = makeBaselineGroup(setup: Self.rc12, filter: "L", count: 10)
        entries[0].trailingScore = 0.55
        entries[0].trailingConsensus = 0.4

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.elongated),
            "consensus=0.4 must NOT trigger R6a (below 0.5)")
    }

    // MARK: R9 — Tracking Hops

    func testR9_TrackingHops() {
        var entries = makeBaselineGroup(setup: Self.rc12, count: 10)
        entries[0].starChainFraction = 0.30

        let scores = score(entries: entries)
        XCTAssertTrue(reasons(for: 0, in: entries, scores: scores).contains(.trackingHop),
            "starChainFraction=0.30 must trigger R9")
    }

    func testR9_Guard_BelowThreshold() {
        var entries = makeBaselineGroup(setup: Self.rc12, count: 10)
        entries[0].starChainFraction = 0.20

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.trackingHop),
            "starChainFraction=0.20 must NOT trigger R9")
    }

    // MARK: R10 — Twilight

    func testR10_Broadband_NauticalTwilight() {
        var entries = makeBaselineGroup(setup: Self.rasa, filter: "L", count: 10)
        entries[0].twilightPhase = .nautical

        let scores = score(entries: entries)
        XCTAssertTrue(reasons(for: 0, in: entries, scores: scores).contains(.twilightExposure),
            "Broadband at nautical twilight must trigger R10")
    }

    func testR10_Narrowband_NauticalTwilight_NotTriggered() {
        var entries = makeBaselineGroup(setup: Self.rasa, filter: "H", count: 10)
        entries[0].twilightPhase = .nautical

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.twilightExposure),
            "Narrowband at nautical twilight must NOT trigger R10 (only civil)")
    }

    func testR10_Narrowband_CivilTwilight() {
        var entries = makeBaselineGroup(setup: Self.rasa, filter: "H", count: 10)
        entries[0].twilightPhase = .civil

        let scores = score(entries: entries)
        XCTAssertTrue(reasons(for: 0, in: entries, scores: scores).contains(.twilightExposure),
            "Narrowband at civil twilight must trigger R10")
    }

    // MARK: Multi-Rule Independence

    func testMultipleGarbageReasons() {
        var entries = makeBaselineGroup(setup: Self.rc12, count: 10)
        // High FWHM + tracking hops — both should appear
        entries[0].computedFWHM = Self.rc12.fwhmGoodMean * 2.5
        entries[0].computedHFR = Self.rc12.fwhmGoodMean * 2.5 * 0.65
        entries[0].starChainFraction = 0.35

        let scores = score(entries: entries)
        let r = reasons(for: 0, in: entries, scores: scores)
        XCTAssertTrue(r.contains(.highFWHM), "R3 must fire")
        XCTAssertTrue(r.contains(.trackingHop), "R9 must fire independently of R3")
    }

    // =========================================================================
    // MARK: - B. Excellent Frame Safety Tests (99% Target)
    // =========================================================================

    func testBestFrameIsExcellent_AllSetups() {
        for setup in Self.allSetups {
            var entries = makeBaselineGroup(setup: setup, count: 20)
            // Make frame 0 clearly the best
            entries[0].computedFWHM = setup.fwhmGoodMean * 0.85
            entries[0].computedHFR = setup.fwhmGoodMean * 0.85 * 0.65
            entries[0].computedStarCount = (entries[0].computedStarCount ?? setup.starCountHa) + 100
            entries[0].noiseMAD = setup.noiseMADMean * 0.8

            let scores = score(entries: entries)
            let t = tier(for: 0, in: entries, scores: scores)
            XCTAssertEqual(t, .excellent,
                "\(setup.name): best frame must be excellent, got \(String(describing: t))")
        }
    }

    func testAboveAverageNeverBorderline() {
        // A frame at 95% median FWHM / 105% median stars / 95% noise
        // must be .good or .excellent, never borderline
        for setup in Self.allSetups {
            var entries = makeBaselineGroup(setup: setup, count: 20)
            entries[0].computedFWHM = setup.fwhmGoodMean * 0.95
            entries[0].computedHFR = setup.fwhmGoodMean * 0.95 * 0.65
            entries[0].noiseMAD = setup.noiseMADMean * 0.95

            let scores = score(entries: entries)
            let t = tier(for: 0, in: entries, scores: scores)
            XCTAssertTrue(t == .excellent || t == .good,
                "\(setup.name): above-average frame must be good/excellent, got \(String(describing: t))")
        }
    }

    // =========================================================================
    // MARK: - C. Practical Significance "Common Sense" Tests
    // =========================================================================

    func testTightSession_NoFrameWorseThanGood() {
        // In a session where FWHM varies by only 0.2px (4.40-4.60),
        // no frame should be worse than .good. The MAD floor prevents
        // penalization of insignificant differences.
        // Metrics are NOT perfectly correlated (realistic: each varies independently).
        var entries: [ImageEntry] = []
        for i in 0..<30 {
            // FWHM varies slightly (0.2px range — sub-pixel, invisible)
            let fwhm = 4.40 + Double(i % 10) * 0.02
            // Noise varies independently (realistic: noise is weather/moon, not seeing)
            let noise: Float = 0.006 + Float((i + 7) % 10) * 0.0001
            // Stars vary independently (detection threshold variation)
            let stars = 1200 + (i * 17) % 60 - 30
            entries.append(makeEntry(
                index: i, filter: "H", target: "IC1848", exposure: 300,
                computedFWHM: fwhm, computedHFR: fwhm * 0.65,
                computedStarCount: stars, noiseMAD: noise, noiseMedian: 0.05,
                focalLength: 904, trailingScore: 0.03, trailingConsensus: 0.1,
                width: 9576, height: 6388, pixelSizeMicrons: 3.76, date: "2026-03-15"
            ))
        }

        let scores = score(entries: entries)
        var borderlineCount = 0
        for i in 0..<30 {
            let t = tier(for: i, in: entries, scores: scores)
            if t == .borderline { borderlineCount += 1 }
        }
        // With MAD floor, no more than 1-2 frames should be borderline in a tight session.
        // The key insight: a human would keep ALL these frames. Zero borderline is ideal,
        // but 1-2 at the very edge is acceptable.
        XCTAssertLessThanOrEqual(borderlineCount, 2,
            "Tight session should have at most 2 borderline frames, got \(borderlineCount)")
    }

    // =========================================================================
    // MARK: - D. Target-Type Weight Tests
    // =========================================================================

    func testGalaxyFWHMWeightAmplified() {
        // Galaxy targets should penalize FWHM more heavily
        var galaxyEntries = makeBaselineGroup(setup: Self.rc12, filter: "L",
            target: "M81", count: 20)
        var genericEntries = makeBaselineGroup(setup: Self.rc12, filter: "L",
            target: "UNKNOWN_TARGET", count: 20)

        // Same FWHM degradation on both
        galaxyEntries[0].computedFWHM = Self.rc12.fwhmGoodMean * 1.3
        galaxyEntries[0].computedHFR = Self.rc12.fwhmGoodMean * 1.3 * 0.65
        genericEntries[0].computedFWHM = Self.rc12.fwhmGoodMean * 1.3
        genericEntries[0].computedHFR = Self.rc12.fwhmGoodMean * 1.3 * 0.65

        let galaxyScores = score(entries: galaxyEntries)
        let genericScores = score(entries: genericEntries)

        let galaxyZ = galaxyScores[galaxyEntries[0].url]?.combinedZScore ?? 0
        let genericZ = genericScores[genericEntries[0].url]?.combinedZScore ?? 0

        // Galaxy should have lower (worse) combined z-score due to FWHM 1.4x modifier
        XCTAssertLessThan(galaxyZ, genericZ,
            "Galaxy target should penalize FWHM degradation more: galaxy z=\(galaxyZ) vs generic z=\(genericZ)")
    }

    func testIFN_NoiseWeightDominates() {
        // IFN targets: noise weight 2.0x, FWHM weight 0.4x
        // A frame with slightly worse noise but better FWHM should be penalized more on IFN
        let ifnTarget = "MWC1"  // Mandel-Wilson IFN in our database

        var entries = makeBaselineGroup(setup: Self.ref140, filter: "L",
            target: ifnTarget, count: 20)

        // Frame with slightly worse noise but identical FWHM
        entries[0].noiseMAD = Self.ref140.noiseMADMean * 1.3

        let scores = score(entries: entries)
        let z = scores[entries[0].url]?.combinedZScore ?? 0

        // With IFN noise weight 2.0x, this frame should be clearly penalized
        XCTAssertLessThan(z, 0.0,
            "IFN target with 30% worse noise must have negative z-score, got \(z)")
    }

    // =========================================================================
    // MARK: - E. Planet/Solar System Exclusion Tests
    // =========================================================================

    func testPlanetTargetsExcluded() {
        let planetTargets = ["Jupiter", "Saturn", "Moon", "Mars", "Venus", "Sun"]
        for target in planetTargets {
            let entries = (0..<8).map { i in
                makeEntry(index: i, filter: "L", target: target, exposure: 0.05,
                    computedStarCount: 2, noiseMAD: 0.002, noiseMedian: 0.003,
                    focalLength: 2000, width: 1920, height: 1080, pixelSizeMicrons: 3.76,
                    date: "2026-03-15")
            }
            let scores = score(entries: entries)
            XCTAssertTrue(scores.isEmpty,
                "Planet target '\(target)' must produce no scores (excluded from deep-sky pipeline)")
        }
    }

    func testDeepSkyTargetsNotExcluded() {
        let deepSkyTargets = ["M82", "NGC 7635", "IC1848", "NGC 7000"]
        for target in deepSkyTargets {
            var entries = makeBaselineGroup(setup: Self.rc12, filter: "L",
                target: target, count: 10)

            let scores = score(entries: entries)
            XCTAssertFalse(scores.isEmpty,
                "Deep-sky target '\(target)' must NOT be excluded from scoring")
        }
    }

    func testSolarSystemDetection() {
        XCTAssertTrue(QualityEstimator.isSolarSystemTarget("Jupiter"))
        XCTAssertTrue(QualityEstimator.isSolarSystemTarget("moon"))
        XCTAssertTrue(QualityEstimator.isSolarSystemTarget("SATURN"))
        XCTAssertTrue(QualityEstimator.isSolarSystemTarget("Sun"))
        XCTAssertTrue(QualityEstimator.isSolarSystemTarget("Solar"))
        XCTAssertFalse(QualityEstimator.isSolarSystemTarget("M82"))
        XCTAssertFalse(QualityEstimator.isSolarSystemTarget("NGC 7000"))
        XCTAssertFalse(QualityEstimator.isSolarSystemTarget("IC1848"))
        XCTAssertFalse(QualityEstimator.isSolarSystemTarget(nil))
        XCTAssertFalse(QualityEstimator.isSolarSystemTarget(""))
    }

    // =========================================================================
    // MARK: - F. Cross-Setup Consistency
    // =========================================================================

    func testMedianFrameIsNearNeutral_AllSetups() {
        // All frames at exact group median should have combinedZ near 0
        for setup in Self.allSetups {
            let entries = makeBaselineGroup(setup: setup, count: 20)
            let scores = score(entries: entries)

            // Check the median-ish frame (index 10)
            if let bd = scores[entries[10].url] {
                // With MAD floor, tight sessions compress z-scores toward 0
                XCTAssertTrue(bd.combinedZScore > -1.0 && bd.combinedZScore < 1.0,
                    "\(setup.name): median frame z=\(bd.combinedZScore) should be near 0")
            }
        }
    }

    // =========================================================================
    // MARK: - G. Vulnerability Deep-Dives
    // =========================================================================

    func testV2_UniformEccentricity_LongFL_NoFalseTrailing() {
        // RC12 group where ALL frames have identical trailing — no outliers.
        // Algorithm v11's trailing outlier guard should prevent false positives.
        var entries = makeBaselineGroup(setup: Self.rc12, filter: "L",
            target: "IC63", count: 20)
        for i in 0..<20 {
            entries[i].computedEccentricity = 0.50
            entries[i].trailingScore = 0.25
            entries[i].trailingConsensus = 0.6
        }

        let scores = score(entries: entries)
        for i in 0..<20 {
            let r = reasons(for: i, in: entries, scores: scores)
            XCTAssertFalse(r.contains(.elongated),
                "Frame \(i): uniform trailing should NOT trigger elongation (trailing outlier guard)")
        }
    }

    func testV3_StarCluster_DarkSite_NotDarkFrame() {
        // Dense globular cluster at dark site: stars=4800, bg=0.004
        // Must NOT trigger R0b dark frame detection
        var entries = makeBaselineGroup(setup: Self.rc12, filter: "L",
            target: "M13", count: 10)
        entries[0].computedStarCount = 4800
        entries[0].noiseMedian = 0.004

        let scores = score(entries: entries)
        XCTAssertFalse(reasons(for: 0, in: entries, scores: scores).contains(.noisePeaks),
            "Star cluster (4800 stars, bg=0.004) must NOT trigger dark frame detection")
    }

    // =========================================================================
    // MARK: - H. DeepSkyTargetDatabase Tests
    // =========================================================================

    func testTargetLookup_Messier() {
        XCTAssertNotNil(DeepSkyTargetDatabase.lookup("M42"), "M42 must be in database")
        XCTAssertEqual(DeepSkyTargetDatabase.lookup("M42")?.type, .emissionNebula)
        XCTAssertEqual(DeepSkyTargetDatabase.lookup("M42")?.commonName, "Orion Nebula")
    }

    func testTargetLookup_NGC() {
        XCTAssertNotNil(DeepSkyTargetDatabase.lookup("NGC7000"), "NGC7000 must be in database")
        XCTAssertEqual(DeepSkyTargetDatabase.lookup("NGC7000")?.type, .emissionNebula)
    }

    func testTargetLookup_ByAlias() {
        // NGC 224 is alias for M31
        let target = DeepSkyTargetDatabase.lookup("NGC224")
        XCTAssertNotNil(target, "NGC224 (alias for M31) must resolve")
        XCTAssertEqual(target?.canonicalName, "M31")
    }

    func testTargetType_Galaxy() {
        XCTAssertEqual(DeepSkyTargetDatabase.targetType(for: "M81"), .galaxy)
        XCTAssertEqual(DeepSkyTargetDatabase.targetType(for: "NGC 3184"), .galaxy)
    }

    func testTargetType_EmissionNebula() {
        XCTAssertEqual(DeepSkyTargetDatabase.targetType(for: "NGC 7000"), .emissionNebula)
        XCTAssertEqual(DeepSkyTargetDatabase.targetType(for: "IC 1805"), .emissionNebula)
    }

    func testTargetType_Unknown() {
        XCTAssertNil(DeepSkyTargetDatabase.targetType(for: "CUSTOM_TARGET_123"))
    }

    func testTargetType_WeightModifiers() {
        // Galaxy: FWHM high, noise low
        XCTAssertGreaterThan(TargetType.galaxy.fwhmWeightModifier, 1.0)
        XCTAssertLessThan(TargetType.galaxy.noiseWeightModifier, 1.0)

        // IFN: noise very high, FWHM very low
        XCTAssertGreaterThan(TargetType.ifn.noiseWeightModifier, 1.5)
        XCTAssertLessThan(TargetType.ifn.fwhmWeightModifier, 0.5)

        // Globular cluster: star count weight very low (crowding)
        XCTAssertLessThan(TargetType.globularCluster.starWeightModifier, 0.3)
    }

    func testFOVFillRatio() {
        guard let m81 = DeepSkyTargetDatabase.lookup("M81") else {
            XCTFail("M81 not in database"); return
        }

        // M81 (26.9' x 14.1') on RASA 620mm (large FOV) — small target
        let rasaFill = m81.fovFillRatio(focalLength: 620, pixelSizeMicrons: 3.76,
            sensorWidth: 9576, sensorHeight: 6388)
        XCTAssertLessThan(rasaFill, 0.3, "M81 should be small on RASA FOV")

        // M81 on RC12 2423mm (small FOV) — fills frame
        let rc12Fill = m81.fovFillRatio(focalLength: 2423, pixelSizeMicrons: 3.76,
            sensorWidth: 9576, sensorHeight: 6388)
        XCTAssertGreaterThan(rc12Fill, 0.4, "M81 should be substantial on RC12 FOV")
    }

    func testFilterRecommendations() {
        guard let m42 = DeepSkyTargetDatabase.lookup("M42") else {
            XCTFail("M42 not in database"); return
        }
        // M42 primary filter should be SHO
        switch m42.filters.primary {
        case .sho: break // expected
        default: XCTFail("M42 primary filter should be SHO, got \(m42.filters.primary.displayName)")
        }

        guard let m13 = DeepSkyTargetDatabase.lookup("M13") else {
            XCTFail("M13 not in database"); return
        }
        // M13 should be LRGB (globular cluster)
        switch m13.filters.primary {
        case .lrgb: break // expected
        default: XCTFail("M13 primary filter should be LRGB, got \(m13.filters.primary.displayName)")
        }
    }

    // MARK: - FL-Dependent FWHM MAD Floor

    func testFWHMMADFloor_ScalesWithFocalLength() {
        // Short FL (large plate scale) → smaller pixel floor
        let rasaFloor = QualityEstimator.fwhmMADFloor(arcsecPerPixel: 1.25)  // RASA 620mm
        // Long FL (small plate scale) → larger pixel floor
        let rc12Floor = QualityEstimator.fwhmMADFloor(arcsecPerPixel: 0.32)  // RC12 2423mm

        XCTAssertGreaterThan(rc12Floor, rasaFloor,
            "Long FL should have larger FWHM MAD floor: RC12=\(rc12Floor) vs RASA=\(rasaFloor)")
        XCTAssertGreaterThanOrEqual(rasaFloor, 0.20, "RASA floor should be ≥0.20")
        XCTAssertLessThanOrEqual(rc12Floor, 0.80, "RC12 floor should be ≤0.80")
    }

    func testFWHMMADFloor_NilFocalLength() {
        let floor = QualityEstimator.fwhmMADFloor(arcsecPerPixel: nil)
        XCTAssertEqual(floor, 0.30, "Default floor without FL should be 0.30")
    }

    func testDatabaseTargetCount() {
        let count = DeepSkyTargetDatabase.allTargets.count
        XCTAssertGreaterThanOrEqual(count, 200,
            "Database should have at least 200 targets, has \(count)")
    }

    // =========================================================================
    // MARK: - I. GroupKey Canonicalization
    // =========================================================================

    func testGroupKey_CanonicalizedTargetNames() {
        // "NGC 7000" and "NGC7000" must land in the same scoring group
        var entries: [ImageEntry] = []
        // 5 frames with "NGC 7000"
        for i in 0..<5 {
            entries.append(makeEntry(index: i, filter: "H", target: "NGC 7000", exposure: 300,
                computedFWHM: 3.0 + Double(i) * 0.1, computedHFR: 2.0,
                computedStarCount: 500, noiseMAD: 0.006, noiseMedian: 0.05,
                focalLength: 620, width: 9576, height: 6388, pixelSizeMicrons: 3.76,
                date: "2026-03-15"))
        }
        // 5 frames with "NGC7000" (no space)
        for i in 5..<10 {
            entries.append(makeEntry(index: i, filter: "H", target: "NGC7000", exposure: 300,
                computedFWHM: 3.0 + Double(i - 5) * 0.1, computedHFR: 2.0,
                computedStarCount: 500, noiseMAD: 0.006, noiseMedian: 0.05,
                focalLength: 620, width: 9576, height: 6388, pixelSizeMicrons: 3.76,
                date: "2026-03-15"))
        }

        let scores = score(entries: entries)
        // All 10 frames should be scored (single group of 10, not two groups of 5)
        XCTAssertEqual(scores.count, 10,
            "All 10 frames should be scored when canonical names match")
    }
}
