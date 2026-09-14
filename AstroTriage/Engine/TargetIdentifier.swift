// TargetIdentifier — names the object a plate-solved frame is pointing at.
//
// A plate solve yields coordinates, not a name. Matching those coordinates against the
// bundled deep-sky catalogue turns "83.84°, -5.35°" into "M42 (Orion Nebula)" — which is what
// goes into the OBJECT keyword and into the solve report.
//
// v6.9.0

import Foundation

// MARK: - Identification

struct TargetIdentification: Equatable {
    let target: DeepSkyTarget
    /// Angular distance from the frame centre to the catalogue position, in arcminutes.
    let separationArcmin: Double
    /// True when the frame centre falls inside the object's own angular extent — i.e. we are
    /// looking AT it, not merely near it.
    let centreInsideObject: Bool

    /// "M42 (Orion Nebula)", or just "M42" when the catalogue has no common name.
    var displayName: String {
        if let common = target.commonName, !common.isEmpty {
            return "\(target.canonicalName) (\(common))"
        }
        return target.canonicalName
    }

    /// What goes into the OBJECT header keyword. The canonical catalogue id is the useful,
    /// machine-matchable form — it is what AstroBlink's own grouping already keys on.
    var headerValue: String { target.canonicalName }
}

// MARK: - Identifier

enum TargetIdentifier {

    /// Identify the object at a solved frame centre.
    ///
    /// - Parameters:
    ///   - raDeg: frame centre right ascension, degrees.
    ///   - decDeg: frame centre declination, degrees.
    ///   - fieldRadiusArcmin: half the frame's diagonal, when known. Used as the search
    ///     radius so a wide field can claim an object near its edge while a narrow one
    ///     cannot. Falls back to a fixed radius when the frame geometry is unknown.
    /// - Returns: the best match, or nil when nothing catalogued is close enough.
    static func identify(raDeg: Double,
                         decDeg: Double,
                         fieldRadiusArcmin: Double? = nil) -> TargetIdentification? {

        // Without frame geometry, 60' is a sensible compromise: wide enough for a typical
        // deep-sky field, tight enough not to grab an unrelated neighbour.
        let searchRadius = max(fieldRadiusArcmin ?? 60.0, 5.0)

        var best: TargetIdentification?
        var bestScore = Double.greatestFiniteMagnitude

        for target in DeepSkyTargetDatabase.targets {
            let separation = angularSeparationArcmin(ra1: raDeg, dec1: decDeg,
                                                    ra2: target.raJ2000, dec2: target.decJ2000)

            // The object's own reach: half its major axis. A frame centred inside M31 sits
            // ~90' from some of its extent, and should still be called M31.
            let objectRadius = target.angularSizeMajor / 2.0
            guard separation <= searchRadius + objectRadius else { continue }

            // Rank by how far OUTSIDE the object we are. Negative means inside, so a large
            // nebula we are sitting in beats a small galaxy that happens to be marginally
            // closer to the exact centre pixel.
            let score = separation - objectRadius

            if score < bestScore {
                bestScore = score
                best = TargetIdentification(target: target,
                                            separationArcmin: separation,
                                            centreInsideObject: separation <= objectRadius)
            }
        }
        return best
    }

    /// Angular separation between two sky positions, in arcminutes.
    ///
    /// Uses the haversine form rather than the plain spherical law of cosines: the latter
    /// loses precision exactly where it matters here, for the small separations that decide
    /// which of two nearby objects a frame is centred on.
    static func angularSeparationArcmin(ra1: Double, dec1: Double,
                                        ra2: Double, dec2: Double) -> Double {
        let toRad = Double.pi / 180.0
        let dRA = (ra2 - ra1) * toRad
        let dDec = (dec2 - dec1) * toRad
        let lat1 = dec1 * toRad
        let lat2 = dec2 * toRad

        let a = sin(dDec / 2) * sin(dDec / 2)
              + cos(lat1) * cos(lat2) * sin(dRA / 2) * sin(dRA / 2)
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return c * (180.0 / Double.pi) * 60.0
    }

    /// Half the frame diagonal in arcminutes, from the solved plate scale and the frame size.
    static func fieldRadiusArcmin(widthPixels: Int?, heightPixels: Int?,
                                  arcsecPerPixel: Double) -> Double? {
        guard let widthPixels, let heightPixels,
              widthPixels > 0, heightPixels > 0, arcsecPerPixel > 0 else { return nil }
        let w = Double(widthPixels) * arcsecPerPixel
        let h = Double(heightPixels) * arcsecPerPixel
        return (w * w + h * h).squareRoot() / 2.0 / 60.0
    }
}
