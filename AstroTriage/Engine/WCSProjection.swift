// WCSProjection.swift
// Gnomonic (TAN) tangent-plane math for everything that reads a plate solve as "where this
// frame points" or maps pixels between two solved frames. GUI-free; compiled into the app and
// into the headless AstroScoreCLI, so the scoring rig and the app share one definition.
//
// Why this exists (6.11.2): CRVAL1/2 is the sky position of the REFERENCE PIXEL CRPIX1/2, not
// of the frame. NINA and ASTAP put CRPIX at the image center, so CRVAL happened to be the
// center; ZWO ASIAIR (astrometry.net-style SIP solutions) puts CRPIX anywhere in the frame.
// On one 85 mm / APS-C session (C 9, 391 solved frames) the true image centers agreed to
// 0.04° while CRVAL scattered 1.4° around them, and two consecutive frames one minute apart
// carried CRVALs 1.7° apart. Everything that read CRVAL as the pointing went wrong at once:
//   • the Field column split one pointing into F1 (252) / F2 (139),
//   • the decentered-target rule flagged 139 frames "target shifted off sensor",
//   • Auto Rotate's planar CRVAL-difference translation was off by up to 103 px with a spurious
//     rotation of up to 3.4° — the CD matrix of a tangent plane 3.8° further east in RA at
//     Dec +63° is rotated by ΔRA·sin(Dec) against the reference (meridian convergence, not
//     camera rotation; the local north direction at the image center agreed to 0.03°),
//   • a re-solve "disagreed" with the stored WCS by that same 1.7° / 3.4°.
// Treating each solution as its own tangent plane — project the pixel you mean, compare the
// results — fixes all four. SIP terms are ignored: at the image center they are arcseconds,
// the errors removed here are degrees.

import Foundation

/// A gnomonic plate solution: the sky position CRVAL of the reference pixel CRPIX and the CD
/// matrix in degrees per pixel. Pixel coordinates follow FITS: 1-based, (1, 1) is the center
/// of the first pixel, so the image center of a W × H frame is ((W+1)/2, (H+1)/2).
struct TangentPlaneWCS {
    let crval1: Double
    let crval2: Double
    let crpix1: Double
    let crpix2: Double
    let cd11: Double
    let cd12: Double
    let cd21: Double
    let cd22: Double

    init(crval1: Double, crval2: Double, crpix1: Double, crpix2: Double,
         cd11: Double, cd12: Double, cd21: Double, cd22: Double) {
        self.crval1 = crval1; self.crval2 = crval2
        self.crpix1 = crpix1; self.crpix2 = crpix2
        self.cd11 = cd11; self.cd12 = cd12; self.cd21 = cd21; self.cd22 = cd22
    }

    /// The solution a frame carries in its header fields, or nil unless all eight are present.
    init?(entry: ImageEntry) {
        guard let crval1 = entry.solvedRA, let crval2 = entry.solvedDec,
              let crpix1 = entry.wcsCRPIX1, let crpix2 = entry.wcsCRPIX2,
              let cd11 = entry.wcsCD11, let cd12 = entry.wcsCD12,
              let cd21 = entry.wcsCD21, let cd22 = entry.wcsCD22
        else { return nil }
        self.init(crval1: crval1, crval2: crval2, crpix1: crpix1, crpix2: crpix2,
                  cd11: cd11, cd12: cd12, cd21: cd21, cd22: cd22)
    }

    private static let toRadians = Double.pi / 180
    private static let toDegrees = 180 / Double.pi

    /// Sky position of a pixel: inverse gnomonic projection about the tangent point.
    /// RA is returned in [0, 360).
    func sky(atPixelX x: Double, y: Double) -> (ra: Double, dec: Double) {
        let dx = x - crpix1
        let dy = y - crpix2
        // Standard (tangent-plane) coordinates of the pixel, radians.
        let xi  = (cd11 * dx + cd12 * dy) * Self.toRadians
        let eta = (cd21 * dx + cd22 * dy) * Self.toRadians
        let ra0 = crval1 * Self.toRadians
        let dec0 = crval2 * Self.toRadians
        var ra = (ra0 + atan2(xi, cos(dec0) - eta * sin(dec0))) * Self.toDegrees
        ra = ra.truncatingRemainder(dividingBy: 360)
        if ra < 0 { ra += 360 }
        let sinDec = (sin(dec0) + eta * cos(dec0)) / (1 + xi * xi + eta * eta).squareRoot()
        let dec = asin(max(-1, min(1, sinDec))) * Self.toDegrees
        return (ra, dec)
    }

    /// Pixel position of a sky point: forward gnomonic projection, then CD⁻¹. Nil when the
    /// point lies 90° or more from the tangent point (it has no image on the plane) or the CD
    /// matrix is singular.
    func pixel(ofRA ra: Double, dec: Double) -> (x: Double, y: Double)? {
        let a = ra * Self.toRadians
        let d = dec * Self.toRadians
        let a0 = crval1 * Self.toRadians
        let d0 = crval2 * Self.toRadians
        let cosDeltaRA = cos(a - a0)
        let denominator = sin(d) * sin(d0) + cos(d) * cos(d0) * cosDeltaRA
        guard denominator > 1e-12 else { return nil }
        let xi  = cos(d) * sin(a - a0) / denominator * Self.toDegrees
        let eta = (sin(d) * cos(d0) - cos(d) * sin(d0) * cosDeltaRA) / denominator * Self.toDegrees
        let det = cd11 * cd22 - cd12 * cd21
        guard abs(det) > 1e-20 else { return nil }
        let dx = ( cd22 * xi - cd12 * eta) / det
        let dy = (-cd21 * xi + cd11 * eta) / det
        return (crpix1 + dx, crpix2 + dy)
    }

    /// Direction of celestial north (+Dec) in pixel space at a pixel, in degrees from +x
    /// towards +y, in (-180, 180]. This is the field rotation a solution describes AT THAT
    /// PIXEL. It is not atan2 of the CD matrix: CD is the local frame at CRPIX, so two correct
    /// solutions of one exposure whose reference pixels sit at different RA differ in CD
    /// rotation by ΔRA·sin(Dec) while agreeing here. Nil only when the pixel has no image.
    func northAngle(atPixelX x: Double, y: Double) -> Double? {
        let here = sky(atPixelX: x, y: y)
        // Step towards the pole, or away from it when already next to it.
        let step = here.dec < 89.0 ? 0.01 : -0.01
        guard let p0 = pixel(ofRA: here.ra, dec: here.dec),
              let p1 = pixel(ofRA: here.ra, dec: here.dec + step)
        else { return nil }
        var angle = atan2(p1.y - p0.y, p1.x - p0.x) * Self.toDegrees
        if step < 0 {
            angle += 180
            if angle > 180 { angle -= 360 }
        }
        return angle
    }
}

enum WCSProjection {
    /// Two frames may be offset by this fraction of the larger field edge and still count as
    /// the same field for the Field column and the LightspeedStacker gate: 0.6 leaves at least
    /// 40% overlap along that axis for the star matcher. (The decentered-target scoring rule
    /// uses the stricter "group center still on this sensor" test, see QualityEstimator.)
    static let sameFieldOffsetFraction = 0.6

    /// The sky position of the frame's IMAGE CENTER — the number to use whenever frames are
    /// compared by where they point. Through the full WCS when the frame has one (CRPIX, CD
    /// matrix, dimensions); the bare CRVAL — or the RA/DEC target header that loads into the
    /// same fields — when it does not; nil without any coordinates. For a solution whose CRPIX
    /// is the image center (NINA, ASTAP, PixInsight) this is exactly CRVAL.
    static func frameCenter(of entry: ImageEntry) -> (ra: Double, dec: Double)? {
        if let wcs = TangentPlaneWCS(entry: entry),
           let width = entry.width, let height = entry.height, width > 0, height > 0 {
            return wcs.sky(atPixelX: (Double(width) + 1) / 2, y: (Double(height) + 1) / 2)
        }
        if let ra = entry.solvedRA, let dec = entry.solvedDec { return (ra, dec) }
        return nil
    }

    /// Great-circle separation in degrees. Haversine: stable for tiny angles, correct across
    /// the 0h/24h RA wrap and near the poles — a plain |ΔRA| reads 359° for a field straddling
    /// 0h, and a planar ΔRA·cos(Dec) approximation drifts for separations of degrees.
    static func angularSeparation(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let toRad = Double.pi / 180
        let dLat = (dec2 - dec1) * toRad
        let dLon = (ra2 - ra1) * toRad
        let a = sin(dLat / 2) * sin(dLat / 2)
              + cos(dec1 * toRad) * cos(dec2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * atan2(sqrt(a), sqrt(max(0, 1 - a))) / toRad
    }
}
