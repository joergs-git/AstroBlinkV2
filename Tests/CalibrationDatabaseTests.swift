import XCTest
@testable import AstroTriage

final class CalibrationDatabaseTests: XCTestCase {

    // MARK: - SetupFingerprint

    func testFingerprintHashDeterministic() {
        let fp1 = SetupFingerprint(telescope: "RASA 8", camera: "ASI6200MM", focalLength: 620.0, pixelSizeMicrons: 3.76)
        let fp2 = SetupFingerprint(telescope: "RASA 8", camera: "ASI6200MM", focalLength: 620.0, pixelSizeMicrons: 3.76)
        XCTAssertEqual(fp1.hash, fp2.hash, "Same hardware should produce same hash")
    }

    func testFingerprintHashCaseInsensitive() {
        let fp1 = SetupFingerprint(telescope: "RASA 8", camera: "ASI6200MM", focalLength: 620.0, pixelSizeMicrons: 3.76)
        let fp2 = SetupFingerprint(telescope: "rasa 8", camera: "asi6200mm", focalLength: 620.0, pixelSizeMicrons: 3.76)
        XCTAssertEqual(fp1.hash, fp2.hash, "Hash should be case-insensitive")
    }

    func testFingerprintDifferentHardware() {
        let fp1 = SetupFingerprint(telescope: "RASA 8", camera: "ASI6200MM", focalLength: 620.0, pixelSizeMicrons: 3.76)
        let fp2 = SetupFingerprint(telescope: "RC12", camera: "ASI6200MM", focalLength: 2423.0, pixelSizeMicrons: 3.76)
        XCTAssertNotEqual(fp1.hash, fp2.hash, "Different setups should have different hashes")
    }

    func testFingerprintNilHandling() {
        let fp = SetupFingerprint(telescope: nil, camera: nil, focalLength: nil, pixelSizeMicrons: nil)
        XCTAssertFalse(fp.hash.isEmpty, "Hash should still be generated for nil inputs")
        XCTAssertEqual(fp.telescope, "Unknown")
        XCTAssertEqual(fp.camera, "Unknown")
    }

    // MARK: - MetricBaseline (Welford's algorithm)

    func testWelfordMeanSingleValue() {
        var baseline = MetricBaseline()
        baseline.update(value: 5.0)
        XCTAssertEqual(baseline.mean, 5.0, accuracy: 0.001)
        XCTAssertEqual(baseline.count, 1)
    }

    func testWelfordMeanMultipleValues() {
        var baseline = MetricBaseline()
        let values = [2.0, 4.0, 6.0, 8.0, 10.0]
        for v in values { baseline.update(value: v) }
        XCTAssertEqual(baseline.mean, 6.0, accuracy: 0.001, "Mean of [2,4,6,8,10] should be 6.0")
        XCTAssertEqual(baseline.count, 5)
    }

    func testWelfordVariance() {
        var baseline = MetricBaseline()
        for v in [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0] {
            baseline.update(value: v)
        }
        // Population variance of [2,4,4,4,5,5,7,9] = 4.0
        XCTAssertEqual(baseline.variance, 4.0, accuracy: 0.01)
        XCTAssertEqual(baseline.stdDev, 2.0, accuracy: 0.01)
    }

    func testIsWithinMADRequiresMinimumCount() {
        var baseline = MetricBaseline()
        for i in 0..<20 { baseline.update(value: Double(i)) }
        // Only 20 samples, need 30
        XCTAssertFalse(baseline.isWithinMAD(10.0), "Should return false with < 30 samples")
    }

    func testIsWithinMADWithSufficientData() {
        var baseline = MetricBaseline()
        // 35 values all around 3.0 with small variation
        for _ in 0..<35 { baseline.update(value: 3.0 + Double.random(in: -0.1...0.1)) }
        XCTAssertTrue(baseline.isWithinMAD(3.0), "Value at mean should be within 1 MAD")
        XCTAssertFalse(baseline.isWithinMAD(10.0), "Far-off value should NOT be within 1 MAD")
    }

    // MARK: - CalibrationProfile

    func testProfileGroupKey() {
        let key1 = CalibrationProfile.groupKey(filter: "Ha", exposure: 300)
        let key2 = CalibrationProfile.groupKey(filter: "ha", exposure: 300)
        XCTAssertEqual(key1, key2, "Group key should be case-insensitive")
    }

    func testProfileLearningThreshold() {
        let fp = SetupFingerprint(telescope: "Test", camera: "Test", focalLength: 500.0, pixelSizeMicrons: 3.76)
        var profile = CalibrationProfile(fingerprint: fp)
        XCTAssertFalse(profile.hasLearned, "New profile should not have learned")

        profile.totalFramesAnalyzed = 30
        XCTAssertTrue(profile.hasLearned, "Profile with 30+ frames should have learned")
    }

    func testProfileAgreementRate() {
        let fp = SetupFingerprint(telescope: "Test", camera: "Test", focalLength: 500.0, pixelSizeMicrons: 3.76)
        var profile = CalibrationProfile(fingerprint: fp)

        // Initial: no data → 100% agreement (optimistic default)
        XCTAssertEqual(profile.agreementRate, 1.0, accuracy: 0.001)

        profile.algorithmFlagged = 8
        profile.userOverrodeKeep = 2
        XCTAssertEqual(profile.agreementRate, 0.8, accuracy: 0.001, "8 out of 10 = 80% agreement")
    }

    // MARK: - FilterExposureBaseline

    func testBaselineUpdates() {
        var baseline = FilterExposureBaseline()
        baseline.fwhm.update(value: 3.5)
        baseline.hfr.update(value: 2.1)
        baseline.starCount.update(value: 500.0)
        baseline.framesAnalyzed += 1

        XCTAssertEqual(baseline.fwhm.mean, 3.5, accuracy: 0.001)
        XCTAssertEqual(baseline.hfr.mean, 2.1, accuracy: 0.001)
        XCTAssertEqual(baseline.starCount.mean, 500.0, accuracy: 0.001)
        XCTAssertEqual(baseline.framesAnalyzed, 1)
    }
}
