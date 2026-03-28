import Foundation

// Moon phase and position calculator for astrophotography quality context.
// Uses low-precision algorithms sufficient for illumination (~1%) and angular separation (~1°).
// References:
//   - Jean Meeus, "Astronomical Algorithms" (2nd ed.), chapters 47-48
//   - Synodic period method for illumination
//   - Low-precision lunar ephemeris for RA/Dec

struct MoonCalculator {

    // MARK: - Moon Illumination

    /// Compute moon illumination fraction [0.0 = new moon, 1.0 = full moon].
    /// Uses the synodic period method with phase angle correction.
    /// Accuracy: ~1-2% illumination.
    static func illumination(utcDate: Date) -> Double {
        let jd = julianDate(from: utcDate)

        // Julian centuries from J2000.0
        let T = (jd - 2451545.0) / 36525.0

        // Sun's mean anomaly (degrees)
        let M = normalize(357.5291 + 35999.0503 * T)

        // Moon's mean anomaly (degrees)
        let Mp = normalize(134.9634 + 477198.8675 * T)

        // Moon's mean elongation from sun (degrees)
        let D = normalize(297.8502 + 445267.1115 * T)

        // Phase angle (simplified Meeus formula)
        let Drad = D * .pi / 180.0
        let Mrad = M * .pi / 180.0
        let Mprad = Mp * .pi / 180.0

        let i = 180.0 - D
            - 6.289 * sin(Mprad)
            + 2.100 * sin(Mrad)
            - 1.274 * sin(2 * Drad - Mprad)
            - 0.658 * sin(2 * Drad)
            - 0.214 * sin(2 * Mprad)
            - 0.110 * sin(Drad)

        let irad = i * .pi / 180.0
        let illumination = (1.0 + cos(irad)) / 2.0
        return max(0.0, min(1.0, illumination))
    }

    // MARK: - Moon Position (Low Precision)

    /// Compute moon RA/Dec in degrees for a given UTC date.
    /// Low-precision formula (~1° accuracy, sufficient for angular separation).
    /// Returns (ra: 0-360°, dec: -90 to +90°) or nil if computation fails.
    static func position(utcDate: Date) -> (ra: Double, dec: Double)? {
        let jd = julianDate(from: utcDate)
        let T = (jd - 2451545.0) / 36525.0

        // Fundamental arguments (degrees)
        let Lp = normalize(218.3165 + 481267.8813 * T)  // Moon's mean longitude
        let D  = normalize(297.8502 + 445267.1115 * T)  // Mean elongation
        let M  = normalize(357.5291 + 35999.0503 * T)   // Sun's mean anomaly
        let Mp = normalize(134.9634 + 477198.8675 * T)  // Moon's mean anomaly
        let F  = normalize(93.2720 + 483202.0175 * T)   // Moon's argument of latitude

        let Drad  = D * .pi / 180.0
        let Mrad  = M * .pi / 180.0
        let Mprad = Mp * .pi / 180.0
        let Frad  = F * .pi / 180.0

        // Ecliptic longitude (degrees)
        let lambda = Lp
            + 6.289 * sin(Mprad)
            + 1.274 * sin(2 * Drad - Mprad)
            + 0.658 * sin(2 * Drad)
            + 0.214 * sin(2 * Mprad)
            - 0.186 * sin(Mrad)
            - 0.114 * sin(2 * Frad)

        // Ecliptic latitude (degrees)
        let beta = 5.128 * sin(Frad)
            + 0.281 * sin(Mprad + Frad)
            + 0.278 * sin(Mprad - Frad)

        let lambdaRad = lambda * .pi / 180.0
        let betaRad = beta * .pi / 180.0

        // Mean obliquity of the ecliptic
        let epsilon = 23.4393 - 0.0130 * T
        let epsilonRad = epsilon * .pi / 180.0

        // Convert ecliptic → equatorial (RA, Dec)
        let sinRA = sin(lambdaRad) * cos(epsilonRad) - tan(betaRad) * sin(epsilonRad)
        let cosRA = cos(lambdaRad)
        var ra = atan2(sinRA, cosRA) * 180.0 / .pi
        if ra < 0 { ra += 360.0 }

        let sinDec = sin(betaRad) * cos(epsilonRad) + cos(betaRad) * sin(epsilonRad) * sin(lambdaRad)
        let dec = asin(max(-1.0, min(1.0, sinDec))) * 180.0 / .pi

        return (ra: ra, dec: dec)
    }

    // MARK: - Angular Separation

    /// Compute angular separation in degrees between two sky positions (both in degrees).
    /// Uses the Vincenty formula for numerical stability at small angles.
    static func angularSeparation(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let ra1r  = ra1 * .pi / 180.0
        let dec1r = dec1 * .pi / 180.0
        let ra2r  = ra2 * .pi / 180.0
        let dec2r = dec2 * .pi / 180.0

        let dra = ra2r - ra1r
        let sinDec1 = sin(dec1r), cosDec1 = cos(dec1r)
        let sinDec2 = sin(dec2r), cosDec2 = cos(dec2r)
        let cosDra = cos(dra), sinDra = sin(dra)

        // Vincenty formula (stable for small and large angles)
        let num1 = cosDec2 * sinDra
        let num2 = cosDec1 * sinDec2 - sinDec1 * cosDec2 * cosDra
        let numerator = sqrt(num1 * num1 + num2 * num2)
        let denominator = sinDec1 * sinDec2 + cosDec1 * cosDec2 * cosDra

        let sep = atan2(numerator, denominator) * 180.0 / .pi
        return Swift.abs(sep)
    }

    /// Convenience: compute moon distance from a target given by FITS RA/Dec strings.
    /// RA format: "HH MM SS.SS", Dec format: "+/-DD MM SS.SS"
    /// Returns angular separation in degrees, or nil if coordinates can't be parsed.
    static func moonTargetDistance(utcDate: Date, targetRA: String, targetDec: String) -> Double? {
        guard let moonPos = position(utcDate: utcDate),
              let raDegs = parseRA(targetRA),
              let decDegs = parseDec(targetDec) else {
            return nil
        }
        return angularSeparation(ra1: moonPos.ra, dec1: moonPos.dec, ra2: raDegs, dec2: decDegs)
    }

    /// Convenience using numeric RA/Dec in degrees (e.g., from CRVAL1/CRVAL2).
    static func moonTargetDistance(utcDate: Date, targetRADeg: Double, targetDecDeg: Double) -> Double? {
        guard let moonPos = position(utcDate: utcDate) else { return nil }
        return angularSeparation(ra1: moonPos.ra, dec1: moonPos.dec, ra2: targetRADeg, dec2: targetDecDeg)
    }

    // MARK: - Helpers

    /// Normalize angle to [0, 360) degrees.
    private static func normalize(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360.0)
        if a < 0 { a += 360.0 }
        return a
    }

    /// Compute Julian Date from a UTC Date.
    private static func julianDate(from date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, let month = c.month, let day = c.day,
              let hour = c.hour, let minute = c.minute, let second = c.second else {
            return 0
        }
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        return Double(jdn) - 0.5 + (Double(hour) + Double(minute) / 60.0 + Double(second) / 3600.0) / 24.0
    }

    /// Parse FITS RA string "HH MM SS.SS" → degrees.
    private static func parseRA(_ ra: String) -> Double? {
        let parts = ra.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count >= 2 else { return nil }
        guard let h = Double(parts[0]) else { return nil }
        let m = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        let s = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
        return (h + m / 60.0 + s / 3600.0) * 15.0  // hours → degrees
    }

    /// Parse FITS Dec string "+DD MM SS.SS" → degrees.
    private static func parseDec(_ dec: String) -> Double? {
        let trimmed = dec.trimmingCharacters(in: .whitespaces)
        let sign: Double = trimmed.hasPrefix("-") ? -1.0 : 1.0
        let clean = trimmed.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
        let parts = clean.split(separator: " ")
        guard parts.count >= 1, let d = Double(parts[0]) else { return nil }
        let m = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        let s = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
        return sign * (d + m / 60.0 + s / 3600.0)
    }
}
