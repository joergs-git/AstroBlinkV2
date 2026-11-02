// PlateSolveComparison — how a fresh solve differs from the one a frame already carried.
//
// Re-solving an already-solved frame is only useful if the result is compared: a solve that
// agrees with the existing header confirms it, and one that disagrees means the stored WCS is
// wrong (a misidentified field, a stale solve copied from a different night, a rotator moved
// between solve and capture). Both answers matter, so both are reported.
//
// Compared at a COMMON PIXEL, not CRVAL against CRVAL (6.11.2): CRVAL is the sky position of
// the reference pixel, which ASIAIR places anywhere in the frame while ASTAP puts it at the
// center. Two correct solutions of one exposure then differ in CRVAL by degrees and in CD
// rotation by ΔRA·sin(Dec) — 1.7° and 3.3° on one real pair — and every re-solve looked like
// a disagreement. Projecting the fresh solution's reference pixel through the stored one asks
// the right question: do the two describe the same sky at the same place on the sensor?
//
// v6.9.0, v6.11.2

import Foundation

struct PlateSolveComparison: Equatable {

    /// How far the two solutions place the frame centre apart, in arcminutes.
    let centreOffsetArcmin: Double
    /// Difference in plate scale, as a percentage of the existing value.
    let scaleDifferencePercent: Double
    /// Difference in field rotation, in degrees, normalised to [0, 180].
    let rotationDifferenceDegrees: Double

    /// Thresholds above which a difference is worth the user's attention rather than being
    /// ordinary solver noise. Repeated solves of the same frame agree far below these.
    static let centreToleranceArcmin = 1.0
    static let scaleTolerancePercent = 1.0
    static let rotationToleranceDegrees = 0.5

    /// True when the new solution meaningfully disagrees with the old one.
    var isSignificant: Bool {
        centreOffsetArcmin > Self.centreToleranceArcmin
            || abs(scaleDifferencePercent) > Self.scaleTolerancePercent
            || rotationDifferenceDegrees > Self.rotationToleranceDegrees
    }

    /// Compact description for the report, e.g. "centre 12.4', scale +0.3%, rotation 0.1°".
    var summary: String {
        String(format: "centre %.1f', scale %+.2f%%, rotation %.2f°",
               centreOffsetArcmin, scaleDifferencePercent, rotationDifferenceDegrees)
    }

    // MARK: - Construction

    /// Compare a fresh solution against the WCS a frame already carried.
    init(existing: WCSSolution, fresh: WCSSolution) {
        // Where does the stored solution put the pixel the fresh solution calls its reference
        // point? For the same sky, exactly at fresh.crval — whatever either CRPIX is.
        let stored = TangentPlaneWCS(solution: existing)
        let storedAtFreshReference = stored.sky(atPixelX: fresh.crpix1, y: fresh.crpix2)
        centreOffsetArcmin = TargetIdentifier.angularSeparationArcmin(
            ra1: storedAtFreshReference.ra, dec1: storedAtFreshReference.dec,
            ra2: fresh.crval1, dec2: fresh.crval2
        )

        let oldScale = existing.arcsecPerPixel
        let newScale = fresh.arcsecPerPixel
        scaleDifferencePercent = oldScale > 0 ? (newScale - oldScale) / oldScale * 100.0 : 0

        // Field rotation at that same pixel under both solutions. The CD-matrix angle is the
        // rotation at each solution's OWN reference pixel; for reference pixels at different
        // RA those differ by meridian convergence although the sky is the same.
        let latest = TangentPlaneWCS(solution: fresh)
        let storedNorth = stored.northAngle(atPixelX: fresh.crpix1, y: fresh.crpix2)
            ?? Self.rotationDegrees(of: existing)
        let freshNorth = latest.northAngle(atPixelX: fresh.crpix1, y: fresh.crpix2)
            ?? Self.rotationDegrees(of: fresh)
        rotationDifferenceDegrees = Self.rotationDelta(storedNorth, freshNorth)
    }

    /// Field rotation implied by a CD matrix, in degrees. Matches how `MetadataExtractor`
    /// derives `wcsRotation` so the two never disagree about what "rotation" means.
    static func rotationDegrees(of s: WCSSolution) -> Double {
        s.crota2 ?? (atan2(-s.cd12, s.cd11) * 180.0 / .pi)
    }

    /// Smallest angle between two rotations, in [0, 180]. Plain subtraction would report a
    /// 359°-vs-1° pair as a 358° disagreement instead of 2°.
    static func rotationDelta(_ a: Double, _ b: Double) -> Double {
        var delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta
    }
}

// MARK: - Reading an existing solve off an entry

extension WCSSolution {

    /// Reconstruct the solution a frame already carries, or nil when it has no usable WCS.
    ///
    /// Requires the full CD matrix, both reference values AND the reference pixel — the
    /// comparison projects through the stored solution, and a partial WCS cannot be compared
    /// meaningfully; treating a missing value as zero would fabricate a disagreement.
    init?(existingOn entry: ImageEntry) {
        guard let wcs = TangentPlaneWCS(entry: entry) else { return nil }
        self.init(
            crval1: wcs.crval1, crval2: wcs.crval2,
            crpix1: wcs.crpix1, crpix2: wcs.crpix2,
            cd11: wcs.cd11, cd12: wcs.cd12, cd21: wcs.cd21, cd22: wcs.cd22,
            crota2: entry.wcsRotation
        )
    }
}

extension TangentPlaneWCS {
    /// The tangent plane of a solver result.
    init(solution s: WCSSolution) {
        self.init(crval1: s.crval1, crval2: s.crval2, crpix1: s.crpix1, crpix2: s.crpix2,
                  cd11: s.cd11, cd12: s.cd12, cd21: s.cd21, cd22: s.cd22)
    }
}
