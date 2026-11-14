import XCTest
@testable import AstroTriage

/// Quality Overview bars (6.12.3): one colour language — green good, yellow medium, red bad —
/// and every row compared with the other nights of the same filter.
final class QualityBarScaleTests: XCTestCase {

    // Real B-filter nights of an RC12 session: noise 7.8e-4 … 1.8e-3, background 1.4e-2 … 4.5e-2.
    private let noise: [Float] = [8.5e-4, 8.6e-4, 1.8e-3, 7.8e-4, 8.0e-4, 10.0e-4]
    private let bkg: [Float] = [1.4e-2, 1.5e-2, 4.5e-2, 1.5e-2, 1.4e-2, 2.2e-2]

    func testLowerIsBetterRatesAgainstTheBestNight() {
        XCTAssertEqual(QualityBarScale.lowerIsBetter(7.8e-4, peers: noise).rating, .good)
        XCTAssertEqual(QualityBarScale.lowerIsBetter(10.0e-4, peers: noise).rating, .good)   // 1.28×
        XCTAssertEqual(QualityBarScale.lowerIsBetter(2.2e-2, peers: bkg).rating, .medium)    // 1.57×
        XCTAssertEqual(QualityBarScale.lowerIsBetter(1.8e-3, peers: noise).rating, .bad)     // 2.3×
        XCTAssertEqual(QualityBarScale.lowerIsBetter(4.5e-2, peers: bkg).rating, .bad)       // 3.2×
    }

    func testLowerIsBetterBarLengthIsRelativeToTheWorstNight() {
        XCTAssertEqual(QualityBarScale.lowerIsBetter(4.5e-2, peers: bkg).fraction, 1.0, accuracy: 1e-6)
        XCTAssertEqual(QualityBarScale.lowerIsBetter(1.5e-2, peers: bkg).fraction, 1.0 / 3.0, accuracy: 1e-3)
    }

    func testHigherIsBetter() {
        let snr: [Float] = [16, 18, 23, 19, 18, 18]
        XCTAssertEqual(QualityBarScale.higherIsBetter(23, peers: snr), .init(fraction: 1.0, rating: .good))
        XCTAssertEqual(QualityBarScale.higherIsBetter(16, peers: snr).rating, .good)    // 70 %
        XCTAssertEqual(QualityBarScale.higherIsBetter(10, peers: snr).rating, .medium)  // 43 %
        XCTAssertEqual(QualityBarScale.higherIsBetter(3, peers: snr).rating, .bad)      // 13 %
    }

    func testUniformNightsAreAllGood() {
        let flat: [Float] = [1.4e-3, 1.6e-3, 1.4e-3]
        for v in flat { XCTAssertEqual(QualityBarScale.lowerIsBetter(v, peers: flat).rating, .good) }
    }

    func testMissingValuesDoNotCrashOrDivideByZero() {
        XCTAssertEqual(QualityBarScale.lowerIsBetter(0, peers: [0, 0]).fraction, 0)
        XCTAssertEqual(QualityBarScale.higherIsBetter(5, peers: []).fraction, 0)
    }

    func testLabelsReadAsOneDigitBeforeAndAfterThePoint() {
        let exp = QualityBarScale.exponent(forMax: 2.6e-3)
        XCTAssertEqual(exp, -3)
        XCTAssertEqual(QualityBarScale.unitLabel(exponent: exp), "e-3")
        XCTAssertEqual(QualityBarScale.label(1.4e-3, exponent: exp), "1.4")
        XCTAssertEqual(QualityBarScale.label(7.1e-4, exponent: exp), "0.7")
        XCTAssertEqual(QualityBarScale.unitLabel(exponent: 0), "")
    }
}
