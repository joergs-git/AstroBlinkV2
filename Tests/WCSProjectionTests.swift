// WCSProjectionTests.swift
// Tangent-plane math shared by the Field column, the decentered-target rule, Auto Rotate's WCS
// alignment and the plate-solve comparison (6.11.2). The two solutions below are the real
// headers of two consecutive 60 s frames (one minute apart, camera untouched, pointing stable
// to 2 px) of an ASIAIR session on an 85 mm refractor (468 mm, ASI2600MC, 6248 × 4176).
// ASIAIR put the reference pixel at (1360, 2486) in one and at (4811, 3891) in the other, so
// their CRVALs sit 1.71° apart and their CD rotations differ by 3.3° although both describe
// the same sky. Every expectation here was cross-checked against astropy on the original files.

import XCTest
@testable import AstroTriage

final class WCSProjectionTests: XCTestCase {

    static let width = 6248
    static let height = 4176

    /// Frame 0008: reference pixel in the lower left.
    static let solutionA = TangentPlaneWCS(
        crval1: 342.630940876, crval2: 63.0181497294,
        crpix1: 1360.20243835, crpix2: 2485.90316772,
        cd11: 0.000443224948407, cd12: 0.000120293677586,
        cd21: -0.000119945777983, cd22: 0.000443690123134)

    /// Frame 0009: reference pixel in the upper right.
    static let solutionB = TangentPlaneWCS(
        crval1: 346.399238095, crval2: 63.1773463052,
        crpix1: 4811.35083008, crpix2: 3890.88104248,
        cd11: 0.000435499131529, cd12: 0.000145875387599,
        cd21: -0.000146000705098, cd22: 0.0004360556105)

    static func entry(_ name: String, _ wcs: TangentPlaneWCS) -> ImageEntry {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(name).fit"))
        entry.solvedRA = wcs.crval1
        entry.solvedDec = wcs.crval2
        entry.wcsCRPIX1 = wcs.crpix1
        entry.wcsCRPIX2 = wcs.crpix2
        entry.wcsCD11 = wcs.cd11
        entry.wcsCD12 = wcs.cd12
        entry.wcsCD21 = wcs.cd21
        entry.wcsCD22 = wcs.cd22
        entry.width = width
        entry.height = height
        entry.focalLength = 468
        entry.pixelSizeMicrons = 3.76
        entry.binning = "1x1"
        return entry
    }

    private var centerX: Double { (Double(Self.width) + 1) / 2 }
    private var centerY: Double { (Double(Self.height) + 1) / 2 }

    // MARK: - Image center

    func testFrameCenterIsTheImageCenterNotTheReferencePixel() throws {
        let center = try XCTUnwrap(WCSProjection.frameCenter(of: Self.entry("a", Self.solutionA)))
        XCTAssertEqual(center.ra, 344.227457, accuracy: 0.0002)
        XCTAssertEqual(center.dec, 62.621128, accuracy: 0.0002)
        let fromCRVAL = WCSProjection.angularSeparation(ra1: center.ra, dec1: center.dec,
                                                        ra2: Self.solutionA.crval1, dec2: Self.solutionA.crval2)
        XCTAssertGreaterThan(fromCRVAL, 0.8, "CRVAL is the reference pixel's position, 0.9° from the frame center")
    }

    func testTwoSolutionsOfOnePointingAgreeAtTheImageCenter() throws {
        let a = try XCTUnwrap(WCSProjection.frameCenter(of: Self.entry("a", Self.solutionA)))
        let b = try XCTUnwrap(WCSProjection.frameCenter(of: Self.entry("b", Self.solutionB)))
        let centers = WCSProjection.angularSeparation(ra1: a.ra, dec1: a.dec, ra2: b.ra, dec2: b.dec)
        let crvals = WCSProjection.angularSeparation(ra1: Self.solutionA.crval1, dec1: Self.solutionA.crval2,
                                                     ra2: Self.solutionB.crval1, dec2: Self.solutionB.crval2)
        XCTAssertEqual(centers * 3600, 4.24, accuracy: 0.5, "the frames really are 2.5 px apart")
        XCTAssertEqual(crvals, 1.71, accuracy: 0.01, "while their CRVALs are 1.7° apart")
    }

    func testReferencePixelAtTheCenterReturnsCRVAL() throws {
        // NINA / ASTAP / PixInsight style solution: nothing changes for them.
        let centered = TangentPlaneWCS(crval1: 83.82, crval2: -5.39, crpix1: centerX, crpix2: centerY,
                                       cd11: Self.solutionA.cd11, cd12: Self.solutionA.cd12,
                                       cd21: Self.solutionA.cd21, cd22: Self.solutionA.cd22)
        let center = try XCTUnwrap(WCSProjection.frameCenter(of: Self.entry("c", centered)))
        XCTAssertEqual(center.ra, 83.82, accuracy: 1e-9)
        XCTAssertEqual(center.dec, -5.39, accuracy: 1e-9)
    }

    func testFallsBackToSolvedCoordinatesWithoutAFullWCS() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/bare.fit"))
        XCTAssertNil(WCSProjection.frameCenter(of: entry))
        entry.solvedRA = 10
        entry.solvedDec = 20
        let center = WCSProjection.frameCenter(of: entry)
        XCTAssertEqual(center?.ra, 10)
        XCTAssertEqual(center?.dec, 20)
    }

    // MARK: - Projection

    func testPixelSkyRoundTrip() throws {
        for (x, y) in [(1.0, 1.0), (centerX, centerY), (6248.0, 4176.0), (100.0, 4000.0)] {
            let sky = Self.solutionB.sky(atPixelX: x, y: y)
            let back = try XCTUnwrap(Self.solutionB.pixel(ofRA: sky.ra, dec: sky.dec))
            XCTAssertEqual(back.x, x, accuracy: 1e-6)
            XCTAssertEqual(back.y, y, accuracy: 1e-6)
        }
    }

    func testRightAscensionWrapsIntoZeroTo360() {
        let nearZero = TangentPlaneWCS(crval1: 359.95, crval2: 10, crpix1: 100, crpix2: 100,
                                       cd11: -0.0005, cd12: 0, cd21: 0, cd22: 0.0005)
        let east = nearZero.sky(atPixelX: -200, y: 100)   // 0.15° east of the tangent point
        XCTAssertGreaterThanOrEqual(east.ra, 0)
        XCTAssertLessThan(east.ra, 1)
        XCTAssertEqual(east.ra, 0.1, accuracy: 0.01)
    }

    func testPointBehindTheTangentPlaneHasNoPixel() {
        XCTAssertNil(Self.solutionA.pixel(ofRA: Self.solutionA.crval1 + 180, dec: -Self.solutionA.crval2))
    }

    // MARK: - Rotation

    func testNorthAngleIsAPropertyOfTheSkyNotOfTheReferencePixel() throws {
        let a = try XCTUnwrap(Self.solutionA.northAngle(atPixelX: centerX, y: centerY))
        let b = try XCTUnwrap(Self.solutionB.northAngle(atPixelX: centerX, y: centerY))
        XCTAssertEqual(a, 106.61, accuracy: 0.02)
        XCTAssertEqual(a, b, accuracy: 0.05, "same camera angle one minute apart")
        let cdA = atan2(Self.solutionA.cd12, Self.solutionA.cd11) * 180 / .pi
        let cdB = atan2(Self.solutionB.cd12, Self.solutionB.cd11) * 180 / .pi
        XCTAssertEqual(abs(cdA - cdB), 3.33, accuracy: 0.05,
                       "the CD matrices differ by the meridian convergence between the two reference pixels")
    }
}
