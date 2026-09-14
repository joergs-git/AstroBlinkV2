// PlateSolveComparison — how a fresh solve differs from the one a frame already carried.
//
// Re-solving an already-solved frame is only useful if the result is compared: a solve that
// agrees with the existing header confirms it, and one that disagrees means the stored WCS is
// wrong (a misidentified field, a stale solve copied from a different night, a rotator moved
// between solve and capture). Both answers matter, so both are reported.
//
// v6.9.0

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
        centreOffsetArcmin = TargetIdentifier.angularSeparationArcmin(
            ra1: existing.crval1, dec1: existing.crval2,
            ra2: fresh.crval1, dec2: fresh.crval2
        )

        let oldScale = existing.arcsecPerPixel
        let newScale = fresh.arcsecPerPixel
        scaleDifferencePercent = oldScale > 0 ? (newScale - oldScale) / oldScale * 100.0 : 0

        rotationDifferenceDegrees = Self.rotationDelta(
            Self.rotationDegrees(of: existing),
            Self.rotationDegrees(of: fresh)
        )
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
    /// Requires the full CD matrix and both reference values — a partial WCS cannot be
    /// compared meaningfully, and treating it as zero would fabricate a disagreement.
    init?(existingOn entry: ImageEntry) {
        guard let crval1 = entry.solvedRA, let crval2 = entry.solvedDec,
              let cd11 = entry.wcsCD11, let cd12 = entry.wcsCD12,
              let cd21 = entry.wcsCD21, let cd22 = entry.wcsCD22
        else { return nil }

        self.init(
            crval1: crval1, crval2: crval2,
            // CRPIX is not needed for any comparison; fall back to 0 when absent.
            crpix1: entry.wcsCRPIX1 ?? 0, crpix2: entry.wcsCRPIX2 ?? 0,
            cd11: cd11, cd12: cd12, cd21: cd21, cd22: cd22,
            crota2: entry.wcsRotation
        )
    }
}
