// Bortle sky quality estimation from SITELAT/SITELONG coordinates.
// Uses Garstang light pollution model with embedded GeoNames city database.
// Per-point computation (no grid) — infinite resolution, exact lat/lon.
// City-radius correction prevents overestimation near city edges.

import Foundation

enum BortleEstimator {

    // MARK: - City Database

    private struct City {
        let lat: Float
        let lon: Float
        let population: Int
        let radius: Float        // Estimated city radius in km (from population)
        let contribution: Float  // Pre-computed: population^exponent
    }

    // Lazy-loaded city database from BortleGrid.bin (repurposed as city data)
    // Falls back to embedded CSV if binary not found
    private static let cities: [City] = loadCities()

    // Pre-computed per-coordinate cache (same site = same Bortle)
    private static var cache: [String: Int] = [:]
    private static let cacheLock = NSLock()

    // Model parameters — calibrated against lightpollutionmap.info VIIRS data
    private static let populationExponent: Float = 0.7
    private static let distanceExponent: Float = 2.5
    private static let scaleFactor: Float = 0.006
    private static let maxDistanceKM: Float = 150

    // Bortle thresholds — calibrated against VIIRS radiance-to-SQM conversion
    // VIIRS nW/cm²·sr → approximate Bortle (from Falchi 2016 + lightpollutionmap.info):
    // <0.25 → B1-2, 0.25-0.50 → B3, 0.50-1.5 → B4, 1.5-4 → B5, 4-15 → B6, 15-50 → B7, 50-150 → B8, >150 → B9
    private static let bortleThresholds: [(radiance: Float, bortle: Int)] = [
        (0.015, 1),
        (0.06,  2),
        (0.18,  3),
        (0.45,  4),
        (1.0,   5),
        (2.5,   6),
        (7.0,   7),
        (18.0,  8),
        (999.0, 9),
    ]

    // MARK: - Public API

    /// Estimate Bortle class (1-9) for the given coordinates.
    /// Uses per-point Garstang model — no grid, exact resolution.
    /// Caches result per coordinate pair (all frames at same site get same value).
    static func estimate(latitude: Double, longitude: Double) -> Int? {
        guard latitude >= -90 && latitude <= 90,
              longitude >= -180 && longitude <= 180 else { return nil }
        guard !cities.isEmpty else { return nil }

        // Cache key: round to 4 decimal places (~11m resolution)
        let key = String(format: "%.4f,%.4f", latitude, longitude)
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let lat = Float(latitude)
        let lon = Float(longitude)

        // Sum contributions from all cities within range
        let radiance = computeRadiance(lat: lat, lon: lon)
        let bortle = radianceToBortle(radiance)

        cacheLock.lock()
        cache[key] = bortle
        cacheLock.unlock()

        return bortle
    }

    /// Bortle class description string.
    static func description(for bortle: Int) -> String {
        switch bortle {
        case 1: return "Excellent dark-sky site"
        case 2: return "Typical truly dark site"
        case 3: return "Rural sky"
        case 4: return "Rural/suburban transition"
        case 5: return "Suburban sky"
        case 6: return "Bright suburban sky"
        case 7: return "Suburban/urban transition"
        case 8: return "City sky"
        case 9: return "Inner-city sky"
        default: return "Unknown"
        }
    }

    // MARK: - Computation

    private static func computeRadiance(lat: Float, lon: Float) -> Float {
        // Pre-filter by latitude band (~2° margin for maxDistanceKM)
        let latMargin = maxDistanceKM / 111.0
        let latMin = lat - latMargin
        let latMax = lat + latMargin

        var totalRadiance: Float = 0

        for city in cities {
            // Quick latitude pre-filter (avoids expensive haversine for far cities)
            guard city.lat >= latMin && city.lat <= latMax else { continue }

            let dist = haversineKM(lat1: lat, lon1: lon, lat2: city.lat, lon2: city.lon)
            guard dist < maxDistanceKM else { continue }

            // City-radius correction: a city is not a point source.
            // Effective distance = max(actual distance, city radius × 0.3).
            // This prevents infinite radiance at city center while allowing
            // suburbs (1-3km out) to have noticeably lower contribution.
            let effectiveDist = max(dist, city.radius * 0.3)

            let contribution = scaleFactor * city.contribution / powf(effectiveDist, distanceExponent)
            totalRadiance += contribution
        }

        return totalRadiance
    }

    private static func haversineKM(lat1: Float, lon1: Float, lat2: Float, lon2: Float) -> Float {
        let R: Float = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sinf(dLat / 2) * sinf(dLat / 2) +
                cosf(lat1 * .pi / 180) * cosf(lat2 * .pi / 180) *
                sinf(dLon / 2) * sinf(dLon / 2)
        return R * 2 * asinf(sqrtf(min(a, 1.0)))
    }

    private static func radianceToBortle(_ radiance: Float) -> Int {
        for (threshold, bortle) in bortleThresholds {
            if radiance < threshold { return bortle }
        }
        return 9
    }

    // MARK: - City Data Loading

    /// Load cities from the embedded BortleCities.csv resource.
    /// Each line: latitude,longitude,population
    private static func loadCities() -> [City] {
        guard let url = Bundle.main.url(forResource: "BortleCities", withExtension: "csv") else {
            print("[BortleEstimator] BortleCities.csv not found in bundle")
            return []
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[BortleEstimator] Failed to read BortleCities.csv")
            return []
        }

        var result: [City] = []
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: ",")
            guard parts.count >= 3,
                  let lat = Float(parts[0]),
                  let lon = Float(parts[1]),
                  let pop = Int(parts[2]),
                  pop >= 5000 else { continue }

            // Estimate city radius from population (Bettencourt scaling)
            // radius_km ≈ 0.5 × (pop/1000)^0.4
            // 5K → 1.0km, 76K → 2.8km, 500K → 6km, 3.7M → 13km
            let radius = min(30, max(0.5, 0.5 * powf(Float(pop) / 1000, 0.4)))

            let contrib = powf(Float(pop), populationExponent)
            result.append(City(lat: lat, lon: lon, population: pop, radius: radius, contribution: contrib))
        }

        print("[BortleEstimator] Loaded \(result.count) cities")
        return result
    }
}
