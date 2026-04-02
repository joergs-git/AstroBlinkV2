import XCTest
@testable import AstroTriage

final class ConvergenceDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(
        index: Int, zScore: Double, isMarked: Bool = false, exposure: Double = 300.0
    ) -> ImageEntry {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test_\(index).xisf"))
        entry.filter = "H"
        entry.target = "IC1848"
        entry.exposure = exposure
        entry.qualityBreakdown = QualityBreakdown(
            tier: zScore > 0.5 ? .excellent : zScore > -0.3 ? .good : zScore > -1.2 ? .borderline : .trash,
            combinedZScore: zScore,
            starsZ: nil, fwhmZ: nil, hfrZ: nil, noiseZ: nil, trailingZ: nil, psfFluxZ: nil,
            snrContribution: nil, snrSquared: nil, garbageReasons: [],
            isLockedKeep: false, reasoningText: nil
        )
        entry.isMarkedForDeletion = isMarked
        return entry
    }

    // MARK: - Convergence Detection

    func testConvergedWhenUniformQuality() {
        // All frames have very similar z-scores → spread < 0.3
        let entries = (0..<20).map { makeEntry(index: $0, zScore: 0.1 + Double($0) * 0.01) }
        let result = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 100.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertTrue(result.isConverged, "Uniform quality should trigger convergence")
        XCTAssertLessThan(result.qualitySpread, 0.3)
    }

    func testNotConvergedWhenWideSpread() {
        // Wide range of z-scores → spread > 0.3
        let entries = (0..<20).map { makeEntry(index: $0, zScore: -2.0 + Double($0) * 0.2) }
        let result = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 80.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertFalse(result.isConverged, "Wide spread should NOT trigger convergence")
    }

    func testNotConvergedWithTooFewScores() {
        // Only 3 frames with scores
        let entries = (0..<3).map { makeEntry(index: $0, zScore: 0.1) }
        let result = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 100.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertFalse(result.isConverged, "Too few frames should not converge")
    }

    // MARK: - SNR Stopping

    func testSNRStopWhenLossExceedsIntegration() {
        // 10 entries: 5 marked with 300s each
        var entries: [ImageEntry] = []
        for i in 0..<10 {
            entries.append(makeEntry(index: i, zScore: 0.1, isMarked: i >= 5))
        }
        // SNR loss 30% but integration loss only 50% → stop NOT reached
        let result1 = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 70.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertFalse(result1.snrStopReached, "SNR loss < integration loss should not trigger stop")

        // SNR loss 60% but integration loss only 50% → stop reached
        let result2 = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 40.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertTrue(result2.snrStopReached, "SNR loss > integration loss should trigger stop")
    }

    // MARK: - Stack Readiness

    func testReadinessFullWhenPerfect() {
        let entries = (0..<20).map { makeEntry(index: $0, zScore: 0.1) }
        let result = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 100.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertGreaterThanOrEqual(result.readinessPercent, 90.0,
            "Perfect conditions should give high readiness")
    }

    func testReadinessLabelReady() {
        let entries = (0..<20).map { makeEntry(index: $0, zScore: 0.1) }
        let result = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 100.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertEqual(result.readinessLabel, "Ready for WBPP")
    }

    func testReadinessLowWithMarkedFrames() {
        var entries = (0..<20).map { makeEntry(index: $0, zScore: -2.0 + Double($0) * 0.2) }
        // Mark half
        for i in 0..<10 { entries[i].isMarkedForDeletion = true }
        let result = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 50.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertLessThan(result.readinessPercent, 80.0,
            "Heavy marking + low SNR retention should give low readiness")
    }

    // MARK: - Convergence Message

    func testConvergenceMessagePresent() {
        let entries = (0..<20).map { makeEntry(index: $0, zScore: 0.1) }
        let result = ConvergenceDetector.analyze(
            entries: entries, snrRetention: 100.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertNotNil(result.message, "Converged state should produce a message")
        XCTAssertTrue(result.message?.contains("Culling complete") ?? false)
    }

    func testEmptyEntriesHandled() {
        let result = ConvergenceDetector.analyze(
            entries: [], snrRetention: 100.0,
            calibrationDB: CalibrationDatabase.shared, fingerprint: nil
        )
        XCTAssertFalse(result.isConverged)
        XCTAssertEqual(result.readinessPercent, 0)
    }
}
