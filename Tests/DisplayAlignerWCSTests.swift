// DisplayAlignerWCSTests.swift
// Auto Rotate's WCS transform between two solutions with different reference pixels (6.11.2).
// Fixture: the two real ASIAIR headers in WCSProjectionTests — same pointing to 2.5 px, CRVALs
// 1.7° apart. The old CD-composition form mapped frame B's center 50.6 px off and rotated it
// by 3.39° against A; both numbers were measured on the original files with astropy.

import XCTest
@testable import AstroTriage

final class DisplayAlignerWCSTests: XCTestCase {

    private func data(_ wcs: TangentPlaneWCS, dimensions: Bool) -> DisplayAligner.WCSData {
        DisplayAligner.WCSData(crpix1: wcs.crpix1, crpix2: wcs.crpix2,
                               crval1: wcs.crval1, crval2: wcs.crval2,
                               cd11: wcs.cd11, cd12: wcs.cd12, cd21: wcs.cd21, cd22: wcs.cd22,
                               width: dimensions ? WCSProjectionTests.width : nil,
                               height: dimensions ? WCSProjectionTests.height : nil)
    }

    private let centerX = (Double(WCSProjectionTests.width) + 1) / 2
    private let centerY = (Double(WCSProjectionTests.height) + 1) / 2

    func testSamePointingWithScatteredReferencePixelsIsPixelLocked() throws {
        let t = try XCTUnwrap(DisplayAligner.transformFromWCS(
            frame: data(WCSProjectionTests.solutionB, dimensions: true),
            reference: data(WCSProjectionTests.solutionA, dimensions: true)))
        // Frame B's center lands where the sky says: 2.5 px from A's center, not 50 px.
        let x = Double(t.a) * centerX + Double(t.b) * centerY + Double(t.tx)
        let y = Double(t.c) * centerX + Double(t.d) * centerY + Double(t.ty)
        XCTAssertEqual(x, 3127.04, accuracy: 0.05)
        XCTAssertEqual(y, 2088.82, accuracy: 0.05)
        // and the relative rotation is the real one (none), not the 3.4° meridian convergence.
        let rotation = atan2(Double(t.c), Double(t.a)) * 180 / .pi
        XCTAssertEqual(rotation, -0.044, accuracy: 0.01)
        let det = Double(t.a) * Double(t.d) - Double(t.b) * Double(t.c)
        XCTAssertEqual(det, 1.0, accuracy: 0.002, "same camera, same scale")
    }

    func testWithoutDimensionsTheReferencePixelAnchorsTheTransform() throws {
        let t = try XCTUnwrap(DisplayAligner.transformFromWCS(
            frame: data(WCSProjectionTests.solutionB, dimensions: false),
            reference: data(WCSProjectionTests.solutionA, dimensions: false)))
        let x = Double(t.a) * centerX + Double(t.b) * centerY + Double(t.tx)
        let y = Double(t.c) * centerX + Double(t.d) * centerY + Double(t.ty)
        XCTAssertEqual(hypot(x - 3127.04, y - 2088.82), 0, accuracy: 3,
                       "anchored 3000 px away the center is still within a few pixels")
    }

    func testIdenticalSolutionsGiveTheIdentity() throws {
        let t = try XCTUnwrap(DisplayAligner.transformFromWCS(
            frame: data(WCSProjectionTests.solutionA, dimensions: true),
            reference: data(WCSProjectionTests.solutionA, dimensions: true)))
        XCTAssertEqual(Double(t.a), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(t.d), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(t.b), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(t.c), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(t.tx), 0, accuracy: 1e-3)
        XCTAssertEqual(Double(t.ty), 0, accuracy: 1e-3)
    }
}
