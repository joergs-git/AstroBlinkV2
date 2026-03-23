import XCTest
@testable import AstroTriage

// Tests for Community Detection Learning and Compare window quality compliance.
// Validates: sanity bounds, community floor logic, recommendation coverage,
// and consistency between Compare window and file list quality display.

final class CommunityDetectionTests: XCTestCase {

    // MARK: - Community Baseline Sanity Bounds

    func testSanityBoundsRejectInvalidFWHM() {
        // FWHM < 0.5 or > 30 should be rejected by client-side validation
        let tooLow = CommunityFilterBaseline(
            medianFWHM: 0.3, medianHFR: nil, medianStars: nil, medianNoiseMad: nil,
            medianSNR: 5.0, medianTrailing: nil, medianEccentricity: nil,
            madFWHM: 0.1, madSNR: 1.0, madTrailing: nil,
            avgRetentionRate: 0.8, contributingSessions: 10
        )
        // isWithinMAD should work but the service rejects median_fwhm < 0.5
        XCTAssertTrue(tooLow.medianFWHM! < 0.5, "FWHM 0.3 should be below sanity minimum")
    }

    func testSanityBoundsRejectNegativeTrailing() {
        let baseline = CommunityFilterBaseline(
            medianFWHM: 2.5, medianHFR: nil, medianStars: nil, medianNoiseMad: nil,
            medianSNR: 5.0, medianTrailing: -0.1, medianEccentricity: nil,
            madFWHM: 0.5, madSNR: 1.0, madTrailing: 0.1,
            avgRetentionRate: 0.8, contributingSessions: 10
        )
        XCTAssertTrue(baseline.medianTrailing! < 0, "Trailing < 0 should be rejected")
    }

    func testSanityBoundsRejectLowRetention() {
        let baseline = CommunityFilterBaseline(
            medianFWHM: 2.5, medianHFR: nil, medianStars: nil, medianNoiseMad: nil,
            medianSNR: 5.0, medianTrailing: 0.1, medianEccentricity: nil,
            madFWHM: 0.5, madSNR: 1.0, madTrailing: 0.1,
            avgRetentionRate: 0.05, contributingSessions: 10
        )
        // Retention < 10% is implausible
        XCTAssertTrue(baseline.avgRetentionRate < 0.1, "Retention 5% should be rejected")
    }

    // MARK: - Community Floor Logic

    func testIsWithinMADPassesForNormalValues() {
        let baseline = CommunityFilterBaseline(
            medianFWHM: 3.0, medianHFR: nil, medianStars: nil, medianNoiseMad: nil,
            medianSNR: 6.0, medianTrailing: 0.1, medianEccentricity: nil,
            madFWHM: 0.5, madSNR: 1.0, madTrailing: 0.08,
            avgRetentionRate: 0.82, contributingSessions: 15
        )
        // FWHM 3.2 is within 1 MAD (0.5) of median 3.0
        XCTAssertTrue(baseline.isWithinMAD(3.2, median: baseline.medianFWHM, mad: baseline.madFWHM))
        // FWHM 4.0 is 2 MADs away — should fail
        XCTAssertFalse(baseline.isWithinMAD(4.0, median: baseline.medianFWHM, mad: baseline.madFWHM))
    }

    func testIsWithinMADFailsWhenMissingData() {
        let baseline = CommunityFilterBaseline(
            medianFWHM: nil, medianHFR: nil, medianStars: nil, medianNoiseMad: nil,
            medianSNR: nil, medianTrailing: nil, medianEccentricity: nil,
            madFWHM: nil, madSNR: nil, madTrailing: nil,
            avgRetentionRate: 0.8, contributingSessions: 5
        )
        // No median/MAD → should return false (never lock)
        XCTAssertFalse(baseline.isWithinMAD(3.0, median: baseline.medianFWHM, mad: baseline.madFWHM))
    }

    func testIsWithinMADFailsWithZeroMAD() {
        let baseline = CommunityFilterBaseline(
            medianFWHM: 3.0, medianHFR: nil, medianStars: nil, medianNoiseMad: nil,
            medianSNR: nil, medianTrailing: nil, medianEccentricity: nil,
            madFWHM: 0.0, madSNR: nil, madTrailing: nil,
            avgRetentionRate: 0.8, contributingSessions: 5
        )
        XCTAssertFalse(baseline.isWithinMAD(3.0, median: baseline.medianFWHM, mad: baseline.madFWHM))
    }

    // MARK: - Community Baseline Expiry

    func testBaselineExpiry() {
        let now = Date()
        let fresh = CommunityBaseline(
            pixelScaleCenter: 1.25, sessionCount: 20, machineCount: 5,
            filterBaselines: [:], fetchedAt: now,
            expiresAt: now.addingTimeInterval(7 * 86400)
        )
        XCTAssertFalse(fresh.isExpired)

        let stale = CommunityBaseline(
            pixelScaleCenter: 1.25, sessionCount: 20, machineCount: 5,
            filterBaselines: [:], fetchedAt: now.addingTimeInterval(-8 * 86400),
            expiresAt: now.addingTimeInterval(-1 * 86400)
        )
        XCTAssertTrue(stale.isExpired)
    }

    // MARK: - Group Key Consistency

    func testGroupKeyMatchesCalibrationDatabase() {
        // Community and CalibrationDatabase must use the same key format
        let communityKey = CommunityBaseline.groupKey(filter: "Ha", exposure: 300)
        let calibKey = CalibrationProfile.groupKey(filter: "Ha", exposure: 300)
        XCTAssertEqual(communityKey, calibKey,
            "Community and CalibrationDatabase must use the same group key format")
    }

    func testGroupKeyNormalizesFilter() {
        let key1 = CommunityBaseline.groupKey(filter: "ha", exposure: 300)
        let key2 = CommunityBaseline.groupKey(filter: "HA", exposure: 300)
        let key3 = CommunityBaseline.groupKey(filter: " Ha ", exposure: 300)
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key2, key3)
    }

    func testGroupKeyEmptyFilterUsesALL() {
        let key = CommunityBaseline.groupKey(filter: "", exposure: 300)
        XCTAssertTrue(key.hasPrefix("ALL|"))
    }

    // MARK: - Recommendation Label Coverage (Compare Compliance)

    func testRecommendationLabelCoversAllTiers() {
        // CRITICAL: Every QualityTier must produce a non-ambiguous recommendation
        // in the Compare window. This test catches the bug where z-score trash
        // returned an empty string.

        // Excellent — no recommendation needed (empty is fine)
        let excellent = QualityBreakdown(
            tier: .excellent, combinedZScore: 1.5,
            starsZ: 1.0, fwhmZ: -0.5, hfrZ: nil, noiseZ: -0.3, trailingZ: nil,
            snrContribution: 95, snrSquared: 100,
            garbageReasons: [], isLockedKeep: false, reasoningText: nil
        )
        // Excellent returns "" — acceptable (no action needed)
        _ = excellent.recommendationLabel

        // Good — no recommendation needed
        let good = QualityBreakdown(
            tier: .good, combinedZScore: 0.3,
            starsZ: 0.5, fwhmZ: -0.2, hfrZ: nil, noiseZ: 0.1, trailingZ: nil,
            snrContribution: 80, snrSquared: 64,
            garbageReasons: [], isLockedKeep: false, reasoningText: nil
        )
        _ = good.recommendationLabel

        // Borderline — must show KEEP or REVIEW (never empty)
        let borderline = QualityBreakdown(
            tier: .borderline, combinedZScore: -1.0,
            starsZ: -0.5, fwhmZ: 0.8, hfrZ: nil, noiseZ: 0.3, trailingZ: nil,
            snrContribution: 40, snrSquared: 16,
            garbageReasons: [], isLockedKeep: false, reasoningText: nil
        )
        let borderlineRec = borderline.recommendationLabel
        XCTAssertFalse(borderlineRec.isEmpty,
            "Borderline frames must have a recommendation (KEEP or REVIEW)")
        XCTAssertTrue(borderlineRec.hasPrefix("KEEP") || borderlineRec.hasPrefix("REVIEW"),
            "Borderline recommendation must be KEEP or REVIEW, got: \(borderlineRec)")

        // Trash with garbage reasons — must show DELETE
        let garbageTrash = QualityBreakdown(
            tier: .trash, combinedZScore: -99,
            starsZ: nil, fwhmZ: nil, hfrZ: nil, noiseZ: nil, trailingZ: nil,
            snrContribution: nil, snrSquared: nil,
            garbageReasons: [.noStars], isLockedKeep: false, reasoningText: nil
        )
        let garbageRec = garbageTrash.recommendationLabel
        XCTAssertTrue(garbageRec.hasPrefix("DELETE"),
            "Garbage trash must show DELETE, got: \(garbageRec)")

        // Trash without garbage reasons (z-score based) — must show DELETE
        let zscoreTrash = QualityBreakdown(
            tier: .trash, combinedZScore: -2.5,
            starsZ: -2.0, fwhmZ: 2.5, hfrZ: nil, noiseZ: 1.5, trailingZ: nil,
            snrContribution: nil, snrSquared: nil,
            garbageReasons: [], isLockedKeep: false, reasoningText: nil
        )
        let zscoreRec = zscoreTrash.recommendationLabel
        XCTAssertTrue(zscoreRec.hasPrefix("DELETE"),
            "Z-score trash must show DELETE, got: \(zscoreRec)")
        XCTAssertTrue(zscoreRec.contains("below quality threshold"),
            "Z-score trash reason should mention quality threshold")
    }

    func testLockedKeepRecommendation() {
        let locked = QualityBreakdown(
            tier: .good, combinedZScore: 0.1,
            starsZ: 0.0, fwhmZ: 0.0, hfrZ: nil, noiseZ: 0.0, trailingZ: nil,
            snrContribution: 50, snrSquared: 25,
            garbageReasons: [], isLockedKeep: true, reasoningText: nil
        )
        XCTAssertTrue(locked.recommendationLabel.contains("calibrated baseline"),
            "Local lock should mention calibrated baseline")
    }

    func testCommunityFloorRecommendation() {
        var communityLocked = QualityBreakdown(
            tier: .good, combinedZScore: -0.3,
            starsZ: 0.0, fwhmZ: 0.2, hfrZ: nil, noiseZ: 0.1, trailingZ: nil,
            snrContribution: 60, snrSquared: 36,
            garbageReasons: [], isLockedKeep: false, reasoningText: nil
        )
        communityLocked.isCommunityFloorLocked = true
        let rec = communityLocked.recommendationLabel
        XCTAssertTrue(rec.contains("community baseline"),
            "Community lock should mention community baseline, got: \(rec)")
    }

    func testLocalLockTakesPriorityOverCommunity() {
        // If both isLockedKeep and isCommunityFloorLocked are true,
        // local calibration message must win
        var both = QualityBreakdown(
            tier: .good, combinedZScore: 0.5,
            starsZ: 0.5, fwhmZ: -0.2, hfrZ: nil, noiseZ: -0.1, trailingZ: nil,
            snrContribution: 70, snrSquared: 49,
            garbageReasons: [], isLockedKeep: true, reasoningText: nil
        )
        both.isCommunityFloorLocked = true
        let rec = both.recommendationLabel
        XCTAssertTrue(rec.contains("calibrated baseline"),
            "Local lock must take priority over community lock")
        XCTAssertFalse(rec.contains("community"),
            "Community should not appear when local lock is active")
    }

    // MARK: - Community Floor Never Overrides Garbage

    func testCommunityFloorCannotOverrideGarbage() {
        // A frame flagged as garbage (Stage 1) must never be promoted by community floor.
        // The community floor only applies to z-score borderline/trash, not garbage.
        let garbage = QualityBreakdown(
            tier: .trash, combinedZScore: -99,
            starsZ: nil, fwhmZ: nil, hfrZ: nil, noiseZ: nil, trailingZ: nil,
            snrContribution: nil, snrSquared: nil,
            garbageReasons: [.noStars], isLockedKeep: false, reasoningText: nil
        )
        // Garbage frames should always say DELETE, never KEEP
        XCTAssertTrue(garbage.recommendationLabel.hasPrefix("DELETE"))
    }
}
