// Tests for checking a solved plate scale against what the headers claim, and for the
// sexagesimal coordinate formatting shown per row.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class OpticsConsistencyTests: XCTestCase {

    /// A solution with a given plate scale, built the way a real CD matrix looks.
    private func solution(arcsecPerPixel: Double) -> WCSSolution {
        let deg = arcsecPerPixel / 3600.0
        return WCSSolution(crval1: 83.84, crval2: -5.35, crpix1: 100, crpix2: 100,
                           cd11: -deg, cd12: 0, cd21: 0, cd22: deg, crota2: 0)
    }

    // MARK: - Agreement

    func testHeaderMatchingTheSolveIsConsistent() throws {
        // 3.76 µm at 467 mm → 206.265 * 3.76 / 467 = 1.661"/px.
        let check = OpticsConsistency(solution: solution(arcsecPerPixel: 1.661),
                                      focalLengthMM: 467,
                                      pixelSizeMicrons: 3.76,
                                      binning: "1x1")
        XCTAssertTrue(check.isConsistent)
        XCTAssertFalse(check.isMismatch)
        XCTAssertEqual(try XCTUnwrap(check.deviationPercent), 0, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(check.impliedFocalLengthMM), 467, accuracy: 2)
    }

    func testSpecSheetRoundingStaysWithinTolerance() throws {
        // A real RC12 delivers ~2423 mm where the spec sheet says 2455 — 1.3%, not an error.
        let measured = 206.265 * 3.76 / 2423
        let check = OpticsConsistency(solution: solution(arcsecPerPixel: measured),
                                      focalLengthMM: 2455,
                                      pixelSizeMicrons: 3.76,
                                      binning: "1x1")
        XCTAssertTrue(check.isConsistent, "1.3% must not be reported as a wrong header")
        XCTAssertEqual(try XCTUnwrap(check.impliedFocalLengthMM), 2423, accuracy: 5)
    }

    // MARK: - Disagreement

    func testForgottenReducerIsFlagged() throws {
        // Header says 2455 mm, a 0.7x reducer makes it really 1719 mm — a 43% scale error.
        let measured = 206.265 * 3.76 / 1719
        let check = OpticsConsistency(solution: solution(arcsecPerPixel: measured),
                                      focalLengthMM: 2455,
                                      pixelSizeMicrons: 3.76,
                                      binning: "1x1")
        XCTAssertTrue(check.isMismatch)
        XCTAssertEqual(try XCTUnwrap(check.impliedFocalLengthMM), 1719, accuracy: 5)
        // The header claims a longer focal length → a SMALLER pixel scale than reality.
        XCTAssertLessThan(try XCTUnwrap(check.deviationPercent), 0)
        XCTAssertTrue(check.explanation.contains("MISMATCH"))
    }

    func testDeviationSignSaysWhichWayTheHeaderIsWrong() throws {
        // Header focal length too SHORT → header scale too LARGE → positive deviation.
        let measured = 206.265 * 3.76 / 1000
        let check = OpticsConsistency(solution: solution(arcsecPerPixel: measured),
                                      focalLengthMM: 500,
                                      pixelSizeMicrons: 3.76,
                                      binning: "1x1")
        XCTAssertGreaterThan(try XCTUnwrap(check.deviationPercent), 0)
        XCTAssertEqual(try XCTUnwrap(check.impliedFocalLengthMM), 1000, accuracy: 5)
    }

    // MARK: - Binning

    func testBinningIsAccountedForOnBothSides() {
        // XPIXSZ is the PHYSICAL pixel size; a 2x2 frame really covers twice the sky per
        // stored pixel. Ignoring that would report every binned frame as a 100% mismatch.
        let measured = 206.265 * 3.76 * 2 / 467
        let check = OpticsConsistency(solution: solution(arcsecPerPixel: measured),
                                      focalLengthMM: 467,
                                      pixelSizeMicrons: 3.76,
                                      binning: "2x2")
        XCTAssertTrue(check.isConsistent, "binned frames must not be flagged wholesale")
    }

    // MARK: - Missing data

    func testAbsentHeadersAreNotAMismatch() {
        for check in [
            OpticsConsistency(solution: solution(arcsecPerPixel: 1.66),
                              focalLengthMM: nil, pixelSizeMicrons: 3.76, binning: "1x1"),
            OpticsConsistency(solution: solution(arcsecPerPixel: 1.66),
                              focalLengthMM: 467, pixelSizeMicrons: nil, binning: "1x1"),
            OpticsConsistency(solution: solution(arcsecPerPixel: 1.66),
                              focalLengthMM: 0, pixelSizeMicrons: 3.76, binning: "1x1")
        ] {
            XCTAssertNil(check.deviationPercent)
            // An absence is not an error — it must not light up as a warning.
            XCTAssertTrue(check.isConsistent)
            XCTAssertFalse(check.isMismatch)
        }
    }

    func testScaleIsStillShownWithoutAFocalLength() {
        let check = OpticsConsistency(solution: solution(arcsecPerPixel: 1.66),
                                      focalLengthMM: nil, pixelSizeMicrons: nil, binning: nil)
        XCTAssertTrue(check.scaleAndFocalLength.contains("1.66"))
        XCTAssertFalse(check.scaleAndFocalLength.contains("mm"))
    }

    func testCellTextCarriesBothNumbersWhenAvailable() {
        let check = OpticsConsistency(solution: solution(arcsecPerPixel: 1.661),
                                      focalLengthMM: 467, pixelSizeMicrons: 3.76, binning: "1x1")
        XCTAssertTrue(check.scaleAndFocalLength.contains("1.66"))
        XCTAssertTrue(check.scaleAndFocalLength.contains("467mm"))
    }
}

// MARK: - Coordinate formatting

final class SkyCoordinateFormatterTests: XCTestCase {

    func testRightAscensionOfTheOrionTestFrame() {
        // 83.8405° → 5h 35m 21.7s — the value ASTAP printed for this frame.
        XCTAssertEqual(SkyCoordinateFormatter.rightAscension(degrees: 83.840544),
                       "05h35m21.7s")
    }

    func testDeclinationOfTheOrionTestFrame() {
        // -5.3514° → -05° 21' 05"
        XCTAssertEqual(SkyCoordinateFormatter.declination(degrees: -5.351421),
                       "-05°21'05\"")
    }

    func testZeroAndPositiveDeclinationCarryTheSign() {
        XCTAssertTrue(SkyCoordinateFormatter.declination(degrees: 0).hasPrefix("+"))
        XCTAssertTrue(SkyCoordinateFormatter.declination(degrees: 41.269).hasPrefix("+"))
    }

    func testRightAscensionWrapsRatherThanPrintingNegativeOr24h() {
        // A solver can hand back a value just outside [0, 360).
        XCTAssertEqual(SkyCoordinateFormatter.rightAscension(degrees: 0), "00h00m00.0s")
        XCTAssertEqual(SkyCoordinateFormatter.rightAscension(degrees: 360), "00h00m00.0s")
        XCTAssertEqual(SkyCoordinateFormatter.rightAscension(degrees: -15), "23h00m00.0s")
    }

    func testRoundingBoundaryDoesNotProduceSixtySeconds() {
        // 59.96s must carry into the next minute, not print as "60.0s".
        let ra = SkyCoordinateFormatter.rightAscension(degrees: 15.0 * (1 + 59.99 / 3600.0))
        XCTAssertFalse(ra.contains("60.0s"), "got \(ra)")

        let dec = SkyCoordinateFormatter.declination(degrees: 10 + 59.9 / 3600.0)
        XCTAssertFalse(dec.contains("60\""), "got \(dec)")
    }

    func testFormattedStringsHaveAStableWidth() {
        // The table aligns these columns; a variable-width string would make it ragged.
        let widths = Set([
            SkyCoordinateFormatter.rightAscension(degrees: 5.0).count,
            SkyCoordinateFormatter.rightAscension(degrees: 183.7).count,
            SkyCoordinateFormatter.rightAscension(degrees: 359.99).count
        ])
        XCTAssertEqual(widths.count, 1, "RA strings vary in width: \(widths)")

        let decWidths = Set([
            SkyCoordinateFormatter.declination(degrees: -5.35).count,
            SkyCoordinateFormatter.declination(degrees: 41.27).count,
            SkyCoordinateFormatter.declination(degrees: -0.01).count
        ])
        XCTAssertEqual(decWidths.count, 1, "Dec strings vary in width: \(decWidths)")
    }
}
