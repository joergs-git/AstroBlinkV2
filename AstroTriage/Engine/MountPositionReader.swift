// MountPositionReader — the approximate sky position a frame was taken at.
//
// Reads the MOUNT's own pointing out of the headers (RA/DEC or OBJCTRA/OBJCTDEC), never an
// existing WCS. A stale CRVAL would let a wrong solve come back "confirmed", which is exactly
// what the re-solve comparison exists to catch.
//
// The position is handed to ASTAP on the COMMAND LINE (`-ra` / `-spd`) rather than written
// into the temporary FITS. Writing it back would mean writing a numeric keyword, and the
// bridge's header writer emits strings — ASTAP then ignores the value and searches far more
// sky than it needs to. On an RC12 narrowband frame that was the difference between a 33 s
// solve and a 2 s one.
//
// v6.9.0

import Foundation

struct MountPosition: Equatable {
    /// Right ascension in degrees [0, 360).
    let raDegrees: Double
    /// Declination in degrees [-90, +90].
    let decDegrees: Double

    /// ASTAP's `-ra` expects hours.
    var raHours: Double { raDegrees / 15.0 }
    /// ASTAP's `-spd` expects "south pole distance" — declination shifted into [0, 180].
    var southPoleDistance: Double { decDegrees + 90.0 }
}

enum MountPositionReader {

    /// Read the pointing from a FITS or XISF frame, or nil when the headers do not carry one.
    ///
    /// Prefers the decimal `RA`/`DEC` pair; falls back to the sexagesimal `OBJCTRA`/`OBJCTDEC`
    /// that ASIAIR and older NINA versions write.
    static func read(from url: URL) -> MountPosition? {
        func header(_ keyword: String) -> String? {
            BatchOperations.readHeaderValue(url: url, keyword: keyword)
        }

        if let raText = header("RA"), let decText = header("DEC"),
           let ra = parseRightAscension(raText), let dec = parseDeclination(decText) {
            return make(ra: ra, dec: dec)
        }
        if let raText = header("OBJCTRA"), let decText = header("OBJCTDEC"),
           let ra = parseRightAscension(raText), let dec = parseDeclination(decText) {
            return make(ra: ra, dec: dec)
        }
        return nil
    }

    private static func make(ra: Double, dec: Double) -> MountPosition? {
        // A header can hold anything; refuse a position that is not on the sky rather than
        // sending ASTAP hunting in a place that cannot exist.
        guard dec >= -90, dec <= 90, ra.isFinite else { return nil }
        var normalisedRA = ra.truncatingRemainder(dividingBy: 360)
        if normalisedRA < 0 { normalisedRA += 360 }
        return MountPosition(raDegrees: normalisedRA, decDegrees: dec)
    }

    // MARK: - Parsing

    /// Right ascension → degrees.
    ///
    /// Accepts a decimal value in DEGREES (what NINA writes into `RA`) and a sexagesimal
    /// value in HOURS (what `OBJCTRA` holds, e.g. `'02 57 00'`). The two are distinguished by
    /// shape, not by keyword, so either spelling works wherever it turns up.
    static func parseRightAscension(_ text: String) -> Double? {
        let cleaned = strip(text)
        if let parts = sexagesimalParts(cleaned) {
            // Sexagesimal RA is conventionally in hours.
            let hours = parts.magnitude
            guard hours >= 0, hours < 24.0001 else { return nil }
            return parts.sign * hours * 15.0
        }
        return Double(cleaned)
    }

    /// Declination → degrees. Decimal or sexagesimal, both already in degrees.
    static func parseDeclination(_ text: String) -> Double? {
        let cleaned = strip(text)
        if let parts = sexagesimalParts(cleaned) {
            return parts.sign * parts.magnitude
        }
        return Double(cleaned)
    }

    /// Remove the quoting FITS/XISF string values carry (`'02 57 00'`) and surrounding space.
    private static func strip(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split `02 57 00`, `+60:38:02`, `-05 21 04.8` into sign and magnitude.
    /// Returns nil when the text is not sexagesimal, so the caller can try a plain decimal.
    private static func sexagesimalParts(_ text: String) -> (sign: Double, magnitude: Double)? {
        let separators = CharacterSet(charactersIn: " :hdm's")
        let fields = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard fields.count >= 2 else { return nil }

        // The sign belongs to the whole value, not just the degrees field: "-05 21 04" is
        // −5°21′04″, not −5° + 21′ + 4″.
        let sign: Double = text.hasPrefix("-") ? -1 : 1
        guard let first = Double(fields[0]) else { return nil }
        let minutes = fields.count > 1 ? (Double(fields[1]) ?? 0) : 0
        let seconds = fields.count > 2 ? (Double(fields[2]) ?? 0) : 0
        guard minutes >= 0, minutes < 60.0001, seconds >= 0, seconds < 60.0001 else { return nil }

        return (sign, abs(first) + minutes / 60.0 + seconds / 3600.0)
    }
}
