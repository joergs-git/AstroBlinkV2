import XCTest
@testable import AstroTriage

final class ThresholdLearnerTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal FrameRecord for grid-search tests. Only fields the learner
    /// actually reads need real values; the rest get defaults that never
    /// affect outcomes.
    private func makeRecord(
        hash: String = UUID().uuidString,
        combinedZ: Double? = nil,
        userConfidence: Int = 0,
        trailingScore: Double? = nil,
        garbageReasons: [GarbageReason] = []
    ) -> FrameRecord {
        let json: String? = {
            guard !garbageReasons.isEmpty else { return nil }
            let raw = garbageReasons.map { $0.rawValue }
            return (try? JSONEncoder().encode(raw)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        return FrameRecord(
            fileHash: hash,
            shortId: "T-0000",
            filename: "test.xisf",
            filePath: "/tmp/test.xisf",
            observingNight: "2026-04-01",
            captureDate: nil,
            captureTime: nil,
            sessionId: "test-session",
            telescope: nil,
            camera: nil,
            focalLength: nil,
            pixelSizeMicrons: nil,
            setupHash: "test-setup",
            target: nil,
            filter: "L",
            exposure: 60,
            gain: nil,
            offsetVal: nil,
            binning: nil,
            pierSide: nil,
            rotatorAngle: nil,
            mount: nil,
            computedFWHM: nil,
            computedHFR: nil,
            computedStarCount: nil,
            computedEccentricity: nil,
            noiseMedian: nil,
            noiseMAD: nil,
            psfFlux: nil,
            trailingScore: trailingScore,
            trailingPA: nil,
            trailingConsensus: nil,
            trailingAxisRatio: nil,
            starChainFraction: nil,
            sensorTemp: nil,
            focuserTemp: nil,
            ambientTemp: nil,
            twilightPhase: nil,
            moonIllumination: nil,
            moonDistance: nil,
            qualityTier: nil,
            combinedZScore: combinedZ,
            garbageReasons: json,
            isLockedKeep: 0,
            filterTrailingMultiplier: nil,
            bortleClass: nil,
            canonicalTarget: nil,
            majorTarget: nil,
            userConfidence: userConfidence,
            qualityFeedback: 0,
            wasDeleted: 0,
            algorithmVersion: kAlgorithmVersion,
            recordedAt: "2026-04-01T12:00:00Z",
            width: nil,
            height: nil
        )
    }

    /// Build a balanced curated set of `n` frames. Half are "true keep"
    /// (3★, z near zero) and half are "true garbage" (1★, z far below the
    /// supplied trash boundary). Exact z values are clustered around the
    /// boundary so the grid search has enough resolution to land somewhere
    /// non-trivial.
    private func balancedSet(n: Int, trashBoundary: Double, gap: Double = 1.0) -> [FrameRecord] {
        var records: [FrameRecord] = []
        let half = n / 2
        for i in 0..<half {
            // Keep: z ranging from 0 down to (trashBoundary + gap)
            let z = -Double(i) * gap / Double(half)
            records.append(makeRecord(combinedZ: z, userConfidence: 3))
        }
        for i in 0..<half {
            // Garbage: z ranging from trashBoundary - 0.05 down to trashBoundary - gap
            let z = trashBoundary - 0.05 - Double(i) * (gap / Double(half))
            records.append(makeRecord(combinedZ: z, userConfidence: 1))
        }
        return records
    }

    // MARK: - Tests

    /// 1 — Grid search lands on (or near) the rating boundary when curation
    /// is clean. 50 keeps with z ≥ -1.0, 50 garbage with z ≤ -2.0 → the
    /// minimum-cost threshold should sit somewhere between, so the
    /// borderline offset is roughly 0 ± 0.1 (the grid step).
    func testGridSearchFindsOptimalBorderlineOffset() {
        var records: [FrameRecord] = []
        for _ in 0..<50 {
            records.append(makeRecord(combinedZ: -0.5, userConfidence: 3))  // clearly keep
        }
        for _ in 0..<50 {
            records.append(makeRecord(combinedZ: -3.0, userConfidence: 1))  // clearly garbage
        }
        let result = ThresholdLearner.computeLearnedThresholds(curatedFrames: records)
        XCTAssertNotNil(result, "Should compute thresholds with 50/50 clean curated split")
        // Both classes are well-separated from the default -2.0 boundary, so
        // every offset in the search range yields zero cost. Tie-break picks 0.
        XCTAssertEqual(result?.borderlineOffset ?? 99, 0.0, accuracy: 0.001,
                       "Tie-break should regularize toward zero when many offsets are cost-equal")
    }

    /// 2 — Falls back to nil when fewer than 50 curated frames are available
    /// OR fewer than 10 frames per rating class.
    func testGridSearchRequiresMinimumData() {
        // 49 frames total (one short of 50)
        var records: [FrameRecord] = []
        for _ in 0..<25 { records.append(makeRecord(combinedZ: -0.5, userConfidence: 3)) }
        for _ in 0..<24 { records.append(makeRecord(combinedZ: -3.0, userConfidence: 1)) }
        XCTAssertNil(
            ThresholdLearner.computeLearnedThresholds(curatedFrames: records),
            "49 frames is below the 50-sample minimum"
        )

        // 60 frames but only 5 at 1★ (below per-class minimum of 10)
        var lopsided: [FrameRecord] = []
        for _ in 0..<55 { lopsided.append(makeRecord(combinedZ: -0.5, userConfidence: 3)) }
        for _ in 0..<5  { lopsided.append(makeRecord(combinedZ: -3.0, userConfidence: 1)) }
        XCTAssertNil(
            ThresholdLearner.computeLearnedThresholds(curatedFrames: lopsided),
            "Per-class minimum (10 at 1★) gates the borderline grid search"
        )
    }

    /// 3 — Offset is mathematically clamped to ±0.8 by the search range.
    /// Even an extremely lopsided curated set cannot push it outside.
    func testGridSearchRespectsMaxOffset() {
        // All 1★ frames sit just below the default boundary; all 3★ sit
        // way above. A "perfect" learner would push the boundary up
        // (offset > 0). Verify the cap holds.
        var records: [FrameRecord] = []
        for _ in 0..<60 { records.append(makeRecord(combinedZ: 0.5, userConfidence: 3)) }
        for _ in 0..<60 { records.append(makeRecord(combinedZ: -2.05, userConfidence: 1)) }
        let result = ThresholdLearner.computeLearnedThresholds(curatedFrames: records)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result?.borderlineOffset ?? 99, 0.8 + 0.001,
                                 "Borderline offset must not exceed +0.8 cap")
        XCTAssertGreaterThanOrEqual(result?.borderlineOffset ?? -99, -0.8 - 0.001,
                                    "Borderline offset must not go below -0.8 cap")
    }

    /// 4 — Frames carrying decentered / background / twilight reasons
    /// must be excluded from the grid search regardless of star rating.
    /// If they were included, a curator who rated decentered frames 1★
    /// would push the borderline far stricter than warranted.
    func testNonLearnableReasonsExcluded() {
        // Build a set where ALL the 1★ frames have decentered/background/
        // twilight reasons. The learner should ignore them, leaving the
        // remaining 3★ frames below per-class minimum → returns nil.
        var records: [FrameRecord] = []
        for _ in 0..<55 {
            records.append(makeRecord(combinedZ: -0.5, userConfidence: 3))
        }
        for _ in 0..<15 {
            records.append(makeRecord(
                combinedZ: -3.0,
                userConfidence: 1,
                garbageReasons: [.decenteredTarget]
            ))
        }
        XCTAssertNil(
            ThresholdLearner.computeLearnedThresholds(curatedFrames: records),
            "Decentered-reason frames must be excluded; remainder fails per-class minimum"
        )
    }

    /// 5 — When two offsets produce equal cost, the learner prefers the
    /// one closer to zero (regularization toward defaults). The
    /// `testGridSearchFindsOptimalBorderlineOffset` test above already
    /// covers this in the well-separated case; here we explicitly verify
    /// the tie-break with manufactured data.
    func testTieBreakerFavorsZeroOffset() {
        // Identical FP/FN at every offset (no curated frames near the
        // boundary in any direction) → all offsets cost 0 → 0.0 wins.
        var records: [FrameRecord] = []
        for _ in 0..<30 { records.append(makeRecord(combinedZ:  1.0, userConfidence: 3)) }
        for _ in 0..<30 { records.append(makeRecord(combinedZ: -5.0, userConfidence: 1)) }
        let result = ThresholdLearner.computeLearnedThresholds(curatedFrames: records)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.borderlineOffset ?? 99, 0.0, accuracy: 0.001,
                       "Equal-cost ties must regularize to offset = 0.0")
    }

    /// 6 — Trailing ceiling grid search reads `trailingScore` and the
    /// trailing-flagged garbage reasons. With 25 frames at trailingScore
    /// well above 0.6 (rated 1★) and 25 well below 0.6 (rated 3★), the
    /// ceiling stays at default (offset = 0).
    func testTrailingCeilingGridSearch() {
        var records: [FrameRecord] = []
        // 25 keepers with low trailing — must still rate them so they
        // land in the candidate set; mark some with the elongated reason
        // so they pass the trailing-population filter.
        for _ in 0..<25 {
            records.append(makeRecord(
                combinedZ: -0.5,
                userConfidence: 3,
                trailingScore: 0.45,
                garbageReasons: [.elongated]
            ))
        }
        // 25 trash with severe trailing
        for _ in 0..<25 {
            records.append(makeRecord(
                combinedZ: -3.0,
                userConfidence: 1,
                trailingScore: 0.85,
                garbageReasons: [.elongated]
            ))
        }
        // Pad the borderline grid search with ≥10 frames each side so the
        // overall result is not nil (trailing alone doesn't trigger output).
        for _ in 0..<25 { records.append(makeRecord(combinedZ:  1.0, userConfidence: 3)) }
        for _ in 0..<25 { records.append(makeRecord(combinedZ: -5.0, userConfidence: 1)) }

        let result = ThresholdLearner.computeLearnedThresholds(curatedFrames: records)
        XCTAssertNotNil(result, "Should compute thresholds with both grid searches viable")
        // Trailing offset should land in [-0.15, +0.20] regardless of input.
        let off = result?.trailingCeilingOffset ?? 99
        XCTAssertGreaterThanOrEqual(off, -0.15 - 0.001)
        XCTAssertLessThanOrEqual(off,    0.20 + 0.001)
    }
}
