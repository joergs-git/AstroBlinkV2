import Foundation

// Twilight classification based on sun altitude
enum TwilightPhase: String, Hashable, Comparable {
    case night          = "Night"           // Sun < -18°
    case astronomical   = "Astro twilight"  // Sun -18° to -12°
    case nautical       = "Nautical twi."   // Sun -12° to -6°
    case civil          = "Civil twilight"   // Sun -6° to 0°
    case daylight       = "Daylight"        // Sun > 0°

    static func < (lhs: TwilightPhase, rhs: TwilightPhase) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var sortOrder: Int {
        switch self {
        case .night:        return 0
        case .astronomical: return 1
        case .nautical:     return 2
        case .civil:        return 3
        case .daylight:     return 4
        }
    }
}

// Simplified solar position calculator using NOAA algorithm.
// Accuracy: ~0.3° for sun altitude, sufficient for twilight classification.
// Reference: NOAA Solar Calculator (https://gml.noaa.gov/grad/solcalc/)
struct SunCalculator {

    // Compute sun altitude in degrees for a given UTC date and location.
    // Returns nil if inputs are invalid.
    static func sunAltitude(utcDate: Date, latitude: Double, longitude: Double) -> Double? {
        guard Swift.abs(latitude) <= 90.0, Swift.abs(longitude) <= 180.0 else { return nil }

        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: utcDate)
        guard let year = components.year, let month = components.month, let day = components.day,
              let hour = components.hour, let minute = components.minute, let second = components.second else {
            return nil
        }

        // Julian Day Number
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045

        // Julian Date (fractional)
        let jd = Double(jdn) - 0.5 + (Double(hour) + Double(minute) / 60.0 + Double(second) / 3600.0) / 24.0

        // Julian Century from J2000.0
        let T = (jd - 2451545.0) / 36525.0

        // Geometric mean longitude of the sun (degrees)
        let L0 = (280.46646 + T * (36000.76983 + T * 0.0003032)).truncatingRemainder(dividingBy: 360.0)

        // Mean anomaly of the sun (degrees)
        let M = (357.52911 + T * (35999.05029 - T * 0.0001537)).truncatingRemainder(dividingBy: 360.0)
        let Mrad = M * .pi / 180.0

        // Equation of center
        let C = sin(Mrad) * (1.914602 - T * (0.004817 + T * 0.000014))
              + sin(2 * Mrad) * (0.019993 - T * 0.000101)
              + sin(3 * Mrad) * 0.000289

        // Sun's true longitude
        let sunLon = L0 + C

        // Sun's apparent longitude (corrected for nutation and aberration)
        let omega = 125.04 - 1934.136 * T
        let lambda = sunLon - 0.00569 - 0.00478 * sin(omega * .pi / 180.0)
        let lambdaRad = lambda * .pi / 180.0

        // Mean obliquity of the ecliptic
        let epsilon0 = 23.0 + (26.0 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60.0) / 60.0
        let epsilon = epsilon0 + 0.00256 * cos(omega * .pi / 180.0)
        let epsilonRad = epsilon * .pi / 180.0

        // Sun's declination
        let sinDec = sin(epsilonRad) * sin(lambdaRad)
        let dec = asin(sinDec)  // radians

        // Equation of time (minutes)
        let tanHalfEps = tan(epsilonRad / 2.0)
        let y2 = tanHalfEps * tanHalfEps
        let L0rad = L0 * .pi / 180.0
        let eqTime = 4.0 * (180.0 / .pi) * (
            y2 * sin(2 * L0rad)
            - 2.0 * 0.016709 * sin(Mrad)  // eccentricity ≈ 0.016709
            + 4.0 * 0.016709 * y2 * sin(Mrad) * cos(2 * L0rad)
            - 0.5 * y2 * y2 * sin(4 * L0rad)
            - 1.25 * 0.016709 * 0.016709 * sin(2 * Mrad)
        )

        // True solar time (minutes)
        let timeOffset = eqTime + 4.0 * longitude  // 4 min per degree of longitude
        let tst = Double(hour) * 60.0 + Double(minute) + Double(second) / 60.0 + timeOffset

        // Hour angle (degrees)
        let ha = (tst / 4.0) - 180.0
        let haRad = ha * .pi / 180.0

        // Solar altitude
        let latRad = latitude * .pi / 180.0
        let sinAlt = sin(latRad) * sin(dec) + cos(latRad) * cos(dec) * cos(haRad)
        let altitude = asin(sinAlt) * 180.0 / .pi

        return altitude
    }

    // Classify a sun altitude into a twilight phase
    static func classify(altitude: Double) -> TwilightPhase {
        if altitude > 0       { return .daylight }
        if altitude > -6      { return .civil }
        if altitude > -12     { return .nautical }
        if altitude > -18     { return .astronomical }
        return .night
    }

    // Convenience: compute twilight phase for a given UTC date and location
    static func twilightPhase(utcDate: Date, latitude: Double, longitude: Double) -> TwilightPhase? {
        guard let alt = sunAltitude(utcDate: utcDate, latitude: latitude, longitude: longitude) else {
            return nil
        }
        return classify(altitude: alt)
    }
}
