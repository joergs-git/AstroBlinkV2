// OpticsConsistency — does the solved plate scale match what the headers claim?
//
// A plate solve measures the true angular size of a pixel. The FITS headers claim one too,
// implicitly, via FOCALLEN and XPIXSZ. When the two disagree, the header is wrong — a
// forgotten reducer or flattener, a focal length typed from the spec sheet rather than
// measured, or a binning the header does not mention.
//
// This matters beyond tidiness: `ImageEntry.arcsecPerPixel` feeds the FOV hint that makes
// solving fast, and the plausibility corridor that quality scoring uses to reject impossible
// FWHM measurements. A focal length that is 20% wrong quietly distorts both.
//
// v6.9.0

import Foundation

struct OpticsConsistency: Equatable {

    /// Angular pixel size the solve actually measured, arcsec/pixel.
    let solvedArcsecPerPixel: Double
    /// Angular pixel size implied by FOCALLEN + XPIXSZ (+ binning), when both are present.
    let headerArcsecPerPixel: Double?
    /// Focal length implied by the solve, mm — what FOCALLEN *should* say.
    let impliedFocalLengthMM: Double?
    /// What FOCALLEN does say, mm.
    let headerFocalLengthMM: Double?

    /// A focal length within this much of the measured one is ordinary spec-sheet rounding,
    /// not a wrong header. Reducers shift the scale by 20-30%, a mislabelled binning by 100%,
    /// so real errors sit far outside it.
    static let tolerancePercent = 2.0

    /// How far the header's scale is from the measured one, as a percentage of the measured
    /// value. Positive means the header claims a LARGER pixel scale (i.e. a shorter focal
    /// length) than reality. Nil when the headers do not state enough to compare.
    var deviationPercent: Double? {
        guard let headerArcsecPerPixel, solvedArcsecPerPixel > 0 else { return nil }
        return (headerArcsecPerPixel - solvedArcsecPerPixel) / solvedArcsecPerPixel * 100.0
    }

    /// True when the headers agree with the solve, or when there is nothing to compare —
    /// a missing FOCALLEN is not an inconsistency, it is an absence.
    var isConsistent: Bool {
        guard let deviation = deviationPercent else { return true }
        return abs(deviation) <= Self.tolerancePercent
    }

    /// True only when we actually had both values and they disagree.
    var isMismatch: Bool {
        deviationPercent != nil && !isConsistent
    }

    // MARK: - Construction

    /// Compare a solved frame against the optics its headers claim.
    ///
    /// - Parameters:
    ///   - solution: the fresh solve.
    ///   - focalLengthMM: FOCALLEN.
    ///   - pixelSizeMicrons: XPIXSZ — the PHYSICAL pixel size.
    ///   - binning: e.g. "2x2"; a binned frame covers proportionally more sky per stored pixel.
    init(solution: WCSSolution,
         focalLengthMM: Double?,
         pixelSizeMicrons: Double?,
         binning: String?) {

        let measured = solution.arcsecPerPixel
        solvedArcsecPerPixel = measured
        headerFocalLengthMM = focalLengthMM

        let binFactor = ASTAPSolver.binningFactor(binning)

        if let focalLengthMM, focalLengthMM > 0,
           let pixelSizeMicrons, pixelSizeMicrons > 0 {
            // Same relation ImageEntry.arcsecPerPixel uses, with binning applied.
            headerArcsecPerPixel = 206.265 * pixelSizeMicrons * binFactor / focalLengthMM
        } else {
            headerArcsecPerPixel = nil
        }

        if let pixelSizeMicrons, pixelSizeMicrons > 0, measured > 0 {
            // Invert the same relation: what focal length would produce the measured scale?
            impliedFocalLengthMM = 206.265 * pixelSizeMicrons * binFactor / measured
        } else {
            impliedFocalLengthMM = nil
        }
    }

    // MARK: - Display

    /// Compact cell text, e.g. `1.66" · 467mm` — the measured scale and the focal length it
    /// implies. Falls back to the scale alone when the pixel size is unknown.
    var scaleAndFocalLength: String {
        let scale = String(format: "%.2f\"", solvedArcsecPerPixel)
        guard let implied = impliedFocalLengthMM else { return scale }
        return scale + String(format: " · %.0fmm", implied)
    }

    /// Full explanation for the tooltip — this is where the actual verdict lives.
    var explanation: String {
        guard let deviation = deviationPercent,
              let implied = impliedFocalLengthMM,
              let header = headerFocalLengthMM else {
            return String(format: "Solved scale %.3f\"/px. No FOCALLEN/XPIXSZ in the header to "
                          + "check it against.", solvedArcsecPerPixel)
        }
        let verdict = isConsistent ? "consistent" : "MISMATCH"
        return String(
            format: "Solved: %.3f\"/px → focal length %.0f mm.\nHeader: FOCALLEN %.0f mm "
                  + "→ %.3f\"/px.\nDeviation %+.1f%% — %@.",
            solvedArcsecPerPixel, implied, header, headerArcsecPerPixel ?? 0, deviation, verdict
        )
    }
}

// MARK: - Coordinate formatting

/// Sexagesimal formatting for the solved centre. Astronomers read RA in hours and Dec in
/// degrees; decimal degrees are correct but unreadable at a glance.
enum SkyCoordinateFormatter {

    /// Right ascension, degrees → `05h35m21.7s`.
    static func rightAscension(degrees: Double) -> String {
        // Normalise into [0, 360) first: a solver may return a value just outside.
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }

        let totalHours = d / 15.0
        var hours = Int(totalHours)
        let minutesFull = (totalHours - Double(hours)) * 60
        var minutes = Int(minutesFull)
        var seconds = (minutesFull - Double(minutes)) * 60

        // Guard the rounding boundary: 59.96s must not print as "60.0s".
        if seconds >= 59.95 { seconds = 0; minutes += 1 }
        if minutes >= 60 { minutes = 0; hours += 1 }
        if hours >= 24 { hours = 0 }

        return String(format: "%02dh%02dm%04.1fs", hours, minutes, seconds)
    }

    /// Declination, degrees → `-05°21'05"`.
    static func declination(degrees: Double) -> String {
        let sign = degrees < 0 ? "-" : "+"
        let a = abs(degrees)
        var d = Int(a)
        let minutesFull = (a - Double(d)) * 60
        var minutes = Int(minutesFull)
        var seconds = (minutesFull - Double(minutes)) * 60

        if seconds >= 59.5 { seconds = 0; minutes += 1 }
        if minutes >= 60 { minutes = 0; d += 1 }

        return String(format: "%@%02d°%02d'%02.0f\"", sign, d, minutes, seconds)
    }
}
