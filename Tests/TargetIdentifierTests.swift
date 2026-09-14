// Tests for naming a plate-solved field, and for comparing a fresh solve against the one a
// frame already carried.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class TargetIdentifierTests: XCTestCase {

    // MARK: - Angular separation

    func testSeparationIsZeroForIdenticalPositions() {
        XCTAssertEqual(TargetIdentifier.angularSeparationArcmin(ra1: 83.8, dec1: -5.4,
                                                               ra2: 83.8, dec2: -5.4),
                       0, accuracy: 1e-9)
    }

    func testSeparationInDeclinationIsExact() {
        // One degree of declination is 60' regardless of RA.
        XCTAssertEqual(TargetIdentifier.angularSeparationArcmin(ra1: 10, dec1: 20,
                                                               ra2: 10, dec2: 21),
                       60, accuracy: 1e-6)
    }

    func testSeparationInRAShrinksWithDeclination() {
        // A degree of RA spans cos(dec) degrees on the sky — at dec 60° that is half.
        let atEquator = TargetIdentifier.angularSeparationArcmin(ra1: 10, dec1: 0, ra2: 11, dec2: 0)
        let atSixty   = TargetIdentifier.angularSeparationArcmin(ra1: 10, dec1: 60, ra2: 11, dec2: 60)
        XCTAssertEqual(atEquator, 60, accuracy: 0.01)
        XCTAssertEqual(atSixty, 30, accuracy: 0.05)
    }

    func testSeparationIsSymmetric() {
        let a = TargetIdentifier.angularSeparationArcmin(ra1: 83.8, dec1: -5.4, ra2: 85.0, dec2: -2.0)
        let b = TargetIdentifier.angularSeparationArcmin(ra1: 85.0, dec1: -2.0, ra2: 83.8, dec2: -5.4)
        XCTAssertEqual(a, b, accuracy: 1e-9)
    }

    // MARK: - Identification

    func testIdentifiesOrionNebulaFromItsCoordinates() throws {
        // The centre the spike's real solve returned for the Orion test frame.
        let id = try XCTUnwrap(TargetIdentifier.identify(raDeg: 83.84, decDeg: -5.35,
                                                        fieldRadiusArcmin: 90))
        XCTAssertEqual(id.target.canonicalName, "M42")
        XCTAssertTrue(id.centreInsideObject, "the solved centre sits inside M42")
        XCTAssertTrue(id.displayName.contains("M42"))
    }

    func testDisplayNameCarriesTheCommonName() throws {
        let id = try XCTUnwrap(TargetIdentifier.identify(raDeg: 83.82, decDeg: -5.39,
                                                        fieldRadiusArcmin: 60))
        // The point of the feature: a name a human recognises, not just a catalogue id.
        XCTAssertTrue(id.displayName.lowercased().contains("orion"),
                      "expected the common name in \(id.displayName)")
    }

    func testEmptySkyIdentifiesNothing() {
        // A deliberately barren patch far from any catalogued object.
        XCTAssertNil(TargetIdentifier.identify(raDeg: 45.0, decDeg: -80.0, fieldRadiusArcmin: 30))
    }

    func testLargeObjectWinsOverACloserTinyOne() throws {
        // Sitting inside a big nebula must beat a small object that is marginally nearer to
        // the exact centre pixel — that is what the "distance outside the object" ranking buys.
        let id = try XCTUnwrap(TargetIdentifier.identify(raDeg: 83.9, decDeg: -5.3,
                                                        fieldRadiusArcmin: 60))
        XCTAssertTrue(id.centreInsideObject)
    }

    func testNarrowFieldDoesNotClaimADistantObject() {
        // A tiny field far from anything must not reach out and grab a neighbour.
        let wide = TargetIdentifier.identify(raDeg: 84.6, decDeg: -5.35, fieldRadiusArcmin: 120)
        let narrow = TargetIdentifier.identify(raDeg: 84.6, decDeg: -5.35, fieldRadiusArcmin: 5)
        if let narrow, let wide {
            XCTAssertLessThanOrEqual(narrow.separationArcmin, wide.separationArcmin + 1e-6)
        }
        // The wide field should find something at this distance from M42; that is the point.
        XCTAssertNotNil(wide)
    }

    // MARK: - Field radius

    func testFieldRadiusIsHalfTheDiagonal() throws {
        // 6248 x 4176 px at 1.66"/px → diagonal ≈ 3.46°, half ≈ 104'.
        let radius = try XCTUnwrap(TargetIdentifier.fieldRadiusArcmin(widthPixels: 6248,
                                                                     heightPixels: 4176,
                                                                     arcsecPerPixel: 1.66))
        XCTAssertEqual(radius, 103.9, accuracy: 1.0)
    }

    func testFieldRadiusNeedsCompleteGeometry() {
        XCTAssertNil(TargetIdentifier.fieldRadiusArcmin(widthPixels: nil, heightPixels: 4176, arcsecPerPixel: 1.66))
        XCTAssertNil(TargetIdentifier.fieldRadiusArcmin(widthPixels: 6248, heightPixels: nil, arcsecPerPixel: 1.66))
        XCTAssertNil(TargetIdentifier.fieldRadiusArcmin(widthPixels: 6248, heightPixels: 4176, arcsecPerPixel: 0))
    }
}

// MARK: - Comparison

final class PlateSolveComparisonTests: XCTestCase {

    /// A realistic solution: ~1.66"/px, no rotation to speak of.
    private func solution(ra: Double, dec: Double,
                          scaleArcsec: Double = 1.66,
                          rotationDeg: Double = 0) -> WCSSolution {
        let scaleDeg = scaleArcsec / 3600.0
        let r = rotationDeg * .pi / 180.0
        return WCSSolution(
            crval1: ra, crval2: dec,
            crpix1: 3124.5, crpix2: 2088.5,
            cd11: -scaleDeg * cos(r), cd12: scaleDeg * sin(r),
            cd21: scaleDeg * sin(r),  cd22: scaleDeg * cos(r),
            crota2: rotationDeg
        )
    }

    func testIdenticalSolutionsDoNotDisagree() {
        let s = solution(ra: 83.84, dec: -5.35)
        let c = PlateSolveComparison(existing: s, fresh: s)
        XCTAssertEqual(c.centreOffsetArcmin, 0, accuracy: 1e-9)
        XCTAssertEqual(c.scaleDifferencePercent, 0, accuracy: 1e-9)
        XCTAssertEqual(c.rotationDifferenceDegrees, 0, accuracy: 1e-9)
        XCTAssertFalse(c.isSignificant, "a frame re-solved to the same place must confirm, not alarm")
    }

    func testSolverNoiseStaysBelowTheAlarmThreshold() {
        // A few arcseconds of centre wander between runs is normal and must not be reported.
        let a = solution(ra: 83.8400, dec: -5.3500)
        let b = solution(ra: 83.8405, dec: -5.3503)
        XCTAssertFalse(PlateSolveComparison(existing: a, fresh: b).isSignificant)
    }

    func testAWronglyPointedExistingSolveIsFlagged() {
        // Half a degree off is a different field, not noise.
        let existing = solution(ra: 83.84, dec: -5.35)
        let fresh    = solution(ra: 84.34, dec: -5.35)
        let c = PlateSolveComparison(existing: existing, fresh: fresh)
        XCTAssertGreaterThan(c.centreOffsetArcmin, 25)
        XCTAssertTrue(c.isSignificant)
    }

    func testAWrongPlateScaleIsFlagged() {
        // e.g. a stale solve from a different focal length / a binning change.
        let existing = solution(ra: 83.84, dec: -5.35, scaleArcsec: 1.66)
        let fresh    = solution(ra: 83.84, dec: -5.35, scaleArcsec: 3.32)
        let c = PlateSolveComparison(existing: existing, fresh: fresh)
        XCTAssertEqual(c.scaleDifferencePercent, 100, accuracy: 1.0)
        XCTAssertTrue(c.isSignificant)
    }

    func testARotatedFieldIsFlagged() {
        let existing = solution(ra: 83.84, dec: -5.35, rotationDeg: 0)
        let fresh    = solution(ra: 83.84, dec: -5.35, rotationDeg: 12)
        let c = PlateSolveComparison(existing: existing, fresh: fresh)
        XCTAssertEqual(c.rotationDifferenceDegrees, 12, accuracy: 0.01)
        XCTAssertTrue(c.isSignificant)
    }

    func testRotationWrapAroundIsNotReportedAsAHugeDifference() {
        // 359° and 1° are 2° apart, not 358°.
        XCTAssertEqual(PlateSolveComparison.rotationDelta(359, 1), 2, accuracy: 1e-9)
        XCTAssertEqual(PlateSolveComparison.rotationDelta(1, 359), 2, accuracy: 1e-9)
        XCTAssertEqual(PlateSolveComparison.rotationDelta(180, 0), 180, accuracy: 1e-9)
        XCTAssertEqual(PlateSolveComparison.rotationDelta(-179, 179), 2, accuracy: 1e-9)
    }

    func testSummaryNamesAllThreeQuantities() {
        let c = PlateSolveComparison(existing: solution(ra: 83.84, dec: -5.35),
                                     fresh: solution(ra: 84.0, dec: -5.35))
        XCTAssertTrue(c.summary.contains("centre"))
        XCTAssertTrue(c.summary.contains("scale"))
        XCTAssertTrue(c.summary.contains("rotation"))
    }

    // MARK: - Reading an existing solve off an entry

    func testPartialWCSIsNotTreatedAsASolve() {
        // A half-written WCS must read as "no solve", otherwise the comparison invents a
        // disagreement out of missing data — and the skip logic would wrongly skip the frame.
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/x.fit"))
        entry.solvedRA = 83.84
        entry.solvedDec = -5.35
        entry.wcsCD11 = -4.6e-4
        // CD1_2, CD2_1, CD2_2 deliberately absent.
        XCTAssertNil(WCSSolution(existingOn: entry))
    }

    func testCompleteWCSIsRecognised() throws {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/x.fit"))
        entry.solvedRA = 83.84
        entry.solvedDec = -5.35
        entry.wcsCRPIX1 = 3124.5
        entry.wcsCRPIX2 = 2088.5
        entry.wcsCD11 = -5.22e-5
        entry.wcsCD12 = -4.58e-4
        entry.wcsCD21 = 4.58e-4
        entry.wcsCD22 = -5.31e-5
        let existing = try XCTUnwrap(WCSSolution(existingOn: entry))
        XCTAssertEqual(existing.crval1, 83.84, accuracy: 1e-9)
        XCTAssertEqual(existing.arcsecPerPixel, 1.66, accuracy: 0.05)
    }
}
