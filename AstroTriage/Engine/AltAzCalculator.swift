// Altitude/Azimuth calculator for deep-sky target visibility planning.
// Computes topocentric alt/az from RA/Dec J2000 + observer location + time.
// Uses the same JD infrastructure as MoonCalculator/SunCalculator.
// Accuracy: ~0.5° (sufficient for visibility planning, ignores refraction/nutation).

import Foundation

enum AltAzCalculator {

    struct AltAz {
        let altitude: Double   // degrees, 0 = horizon, 90 = zenith
        let azimuth: Double    // degrees, 0 = N, 90 = E, 180 = S, 270 = W
    }

    struct VisibilityPoint: Identifiable {
        let id = UUID()
        let time: Date
        let altitude: Double
    }

    struct TonightInfo {
        let maxAltitude: Double
        let transitTime: Date
        let hoursAbove30: Double
        let curve: [VisibilityPoint]
    }

    // MARK: - Core Computation

    /// Compute altitude and azimuth for a celestial object.
    /// - Parameters:
    ///   - ra: Right ascension in degrees [0, 360)
    ///   - dec: Declination in degrees [-90, +90]
    ///   - latitude: Observer latitude in degrees (N positive)
    ///   - longitude: Observer longitude in degrees (E positive)
    ///   - utcDate: Time of observation (UTC)
    static func compute(ra: Double, dec: Double,
                        latitude: Double, longitude: Double,
                        utcDate: Date) -> AltAz {
        let jd = julianDate(from: utcDate)

        // Greenwich Mean Sidereal Time (degrees)
        let T = (jd - 2451545.0) / 36525.0
        let gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
                 + 0.000387933 * T * T - T * T * T / 38710000.0

        // Local Sidereal Time (degrees)
        let lst = normalize(gmst + longitude)

        // Hour angle (degrees)
        let ha = normalize(lst - ra)

        // Convert to radians
        let haRad = ha * .pi / 180.0
        let decRad = dec * .pi / 180.0
        let latRad = latitude * .pi / 180.0

        // Altitude: sin(alt) = sin(lat)sin(dec) + cos(lat)cos(dec)cos(ha)
        let sinAlt = sin(latRad) * sin(decRad) + cos(latRad) * cos(decRad) * cos(haRad)
        let altitude = asin(max(-1, min(1, sinAlt))) * 180.0 / .pi

        // Azimuth: atan2(-sin(ha), cos(lat)tan(dec) - sin(lat)cos(ha))
        let azY = -sin(haRad)
        let azX = cos(latRad) * tan(decRad) - sin(latRad) * cos(haRad)
        var azimuth = atan2(azY, azX) * 180.0 / .pi
        if azimuth < 0 { azimuth += 360.0 }

        return AltAz(altitude: altitude, azimuth: azimuth)
    }

    // MARK: - Visibility Curve

    /// Compute altitude at regular intervals throughout the night.
    /// Night window = sunset to sunrise (from SunCalculator), extended 30min each side.
    static func visibilityCurve(ra: Double, dec: Double,
                                latitude: Double, longitude: Double,
                                date: Date,
                                intervalMinutes: Int = 15) -> [VisibilityPoint] {
        // Find sunset and sunrise for this date
        let (sunset, sunrise) = sunsetSunrise(date: date, latitude: latitude, longitude: longitude)
        guard let start = sunset, let end = sunrise else {
            // Polar region or computation failed — compute 18h window centered on midnight
            let calendar = Calendar(identifier: .gregorian)
            let midnight = calendar.startOfDay(for: date).addingTimeInterval(24 * 3600)
            return computeCurve(ra: ra, dec: dec, latitude: latitude, longitude: longitude,
                                from: midnight.addingTimeInterval(-9 * 3600),
                                to: midnight.addingTimeInterval(9 * 3600),
                                intervalMinutes: intervalMinutes)
        }

        // Extend 30 min before sunset and after sunrise for twilight context
        let extStart = start.addingTimeInterval(-30 * 60)
        let extEnd = end.addingTimeInterval(30 * 60)
        return computeCurve(ra: ra, dec: dec, latitude: latitude, longitude: longitude,
                            from: extStart, to: extEnd, intervalMinutes: intervalMinutes)
    }

    /// Full tonight info including max altitude, transit, hours above 30°.
    static func tonightInfo(ra: Double, dec: Double,
                            latitude: Double, longitude: Double,
                            date: Date) -> TonightInfo {
        let curve = visibilityCurve(ra: ra, dec: dec, latitude: latitude, longitude: longitude, date: date)

        let maxPoint = curve.max(by: { $0.altitude < $1.altitude })
        let maxAlt = maxPoint?.altitude ?? 0
        let transit = maxPoint?.time ?? date

        // Count 15-min intervals above 30° → hours
        let above30Count = curve.filter { $0.altitude >= 30.0 }.count
        let hoursAbove30 = Double(above30Count) * 15.0 / 60.0  // 15-min intervals

        return TonightInfo(maxAltitude: maxAlt, transitTime: transit,
                           hoursAbove30: hoursAbove30, curve: curve)
    }

    // MARK: - Quick Calculations

    /// Maximum possible altitude for a target at a given latitude.
    /// = 90 - |latitude - declination|
    static func maxAltitude(dec: Double, latitude: Double) -> Double {
        return 90.0 - Swift.abs(latitude - dec)
    }

    /// Approximate transit time (when target crosses meridian) for a given date.
    static func transitTime(ra: Double, longitude: Double, date: Date) -> Date {
        // GMST at 0h UT for this date
        let calendar = Calendar(identifier: .gregorian)
        var utcCal = calendar
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = utcCal.startOfDay(for: date)
        let jd0 = julianDate(from: startOfDay)
        let T0 = (jd0 - 2451545.0) / 36525.0
        let gmst0 = normalize(100.46061837 + 36000.770053608 * T0 + 0.000387933 * T0 * T0)

        // Transit when LST = RA → HA = 0
        // LST = GMST + longitude, so GMST_transit = RA - longitude
        let transitGMST = normalize(ra - longitude)
        var hoursFromMidnight = normalize(transitGMST - gmst0) / 15.04107  // sidereal → solar hours

        // If transit already passed, it's tomorrow
        if hoursFromMidnight > 24 { hoursFromMidnight -= 24 }

        return startOfDay.addingTimeInterval(hoursFromMidnight * 3600)
    }

    // MARK: - Helpers

    private static func computeCurve(ra: Double, dec: Double,
                                     latitude: Double, longitude: Double,
                                     from start: Date, to end: Date,
                                     intervalMinutes: Int) -> [VisibilityPoint] {
        var points: [VisibilityPoint] = []
        let interval = TimeInterval(intervalMinutes * 60)
        var t = start
        while t <= end {
            let altAz = compute(ra: ra, dec: dec, latitude: latitude, longitude: longitude, utcDate: t)
            points.append(VisibilityPoint(time: t, altitude: altAz.altitude))
            t = t.addingTimeInterval(interval)
        }
        return points
    }

    /// Find approximate sunset and sunrise times for a date.
    /// Uses SunCalculator.sunAltitude to binary-search for sun crossing -6° (civil twilight end).
    private static func sunsetSunrise(date: Date, latitude: Double, longitude: Double) -> (sunset: Date?, sunrise: Date?) {
        let calendar = Calendar(identifier: .gregorian)
        var utcCal = calendar
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        // Noon of the given date (local solar noon approximation)
        let startOfDay = utcCal.startOfDay(for: date)
        let noon = startOfDay.addingTimeInterval(12 * 3600 - longitude / 15 * 3600)

        // Scan from noon forward for sunset (altitude crossing below -6°)
        let sunset = findSunCrossing(startTime: noon, endTime: noon.addingTimeInterval(12 * 3600),
                                     latitude: latitude, longitude: longitude,
                                     targetAltitude: -6.0, direction: .descending)

        // Scan from midnight forward for sunrise (altitude crossing above -6°)
        let midnight = noon.addingTimeInterval(12 * 3600)
        let sunrise = findSunCrossing(startTime: midnight, endTime: midnight.addingTimeInterval(12 * 3600),
                                      latitude: latitude, longitude: longitude,
                                      targetAltitude: -6.0, direction: .ascending)

        return (sunset, sunrise)
    }

    private enum CrossingDirection { case ascending, descending }

    private static func findSunCrossing(startTime: Date, endTime: Date,
                                        latitude: Double, longitude: Double,
                                        targetAltitude: Double, direction: CrossingDirection) -> Date? {
        // Coarse scan at 10-minute intervals, then refine
        let coarseInterval: TimeInterval = 600 // 10 min
        var prevAlt: Double?
        var prevTime = startTime
        var t = startTime

        while t <= endTime {
            guard let alt = SunCalculator.sunAltitude(utcDate: t, latitude: latitude, longitude: longitude) else {
                t = t.addingTimeInterval(coarseInterval)
                continue
            }

            if let prev = prevAlt {
                let crossed: Bool
                switch direction {
                case .descending: crossed = prev > targetAltitude && alt <= targetAltitude
                case .ascending:  crossed = prev < targetAltitude && alt >= targetAltitude
                }
                if crossed {
                    // Linear interpolation for the crossing time
                    let fraction = (targetAltitude - prev) / (alt - prev)
                    return prevTime.addingTimeInterval(coarseInterval * fraction)
                }
            }

            prevAlt = alt
            prevTime = t
            t = t.addingTimeInterval(coarseInterval)
        }

        return nil
    }

    /// Julian Date from a Swift Date. Same algorithm as MoonCalculator but self-contained.
    private static func julianDate(from date: Date) -> Double {
        // Seconds since Unix epoch → Julian Date
        // JD of Unix epoch (1970-01-01 00:00:00 UTC) = 2440587.5
        return date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    /// Normalize angle to [0, 360)
    private static func normalize(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360.0)
        if a < 0 { a += 360.0 }
        return a
    }
}
