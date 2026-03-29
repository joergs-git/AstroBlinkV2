// Bortle sky quality estimation from SITELAT/SITELONG coordinates.
// Uses an embedded 0.5° resolution global grid (~253 KB) generated from
// GeoNames city population data + Garstang light pollution model.
// Accuracy: ±1 Bortle class for typical locations, ±2 for terrain-shielded dark sites.

import Foundation

enum BortleEstimator {

    // Grid parameters (must match generator script)
    private static let gridLon = 720     // columns: -180 to +179.5
    private static let gridLat = 360     // rows: +90 to -89.5
    private static let resolution = 0.5  // degrees per cell
    private static let headerSize = 8    // 4 bytes magic + 4 bytes dimensions

    // Lazy-loaded grid data (loaded once on first query, ~253 KB)
    private static var gridData: Data? = {
        guard let url = Bundle.main.url(forResource: "BortleGrid", withExtension: "bin") else {
            print("[BortleEstimator] BortleGrid.bin not found in bundle")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            print("[BortleEstimator] Failed to load BortleGrid.bin")
            return nil
        }
        // Verify magic header
        guard data.count >= headerSize,
              data[0] == 0x42, data[1] == 0x52, data[2] == 0x54, data[3] == 0x4C else {  // "BRTL"
            print("[BortleEstimator] Invalid BortleGrid.bin header")
            return nil
        }
        let expectedSize = headerSize + gridLon * gridLat
        guard data.count == expectedSize else {
            print("[BortleEstimator] BortleGrid.bin size mismatch: \(data.count) vs expected \(expectedSize)")
            return nil
        }
        return data
    }()

    /// Estimate Bortle class (1-9) for the given coordinates.
    /// Returns nil if coordinates are invalid or grid data is unavailable.
    /// - Parameters:
    ///   - latitude: Degrees north (positive) or south (negative), range -90 to +90
    ///   - longitude: Degrees east (positive) or west (negative), range -180 to +180
    /// - Returns: Bortle class 1 (pristine) to 9 (inner city), or nil
    static func estimate(latitude: Double, longitude: Double) -> Int? {
        guard let data = gridData else { return nil }
        guard latitude >= -90 && latitude <= 90,
              longitude >= -180 && longitude <= 180 else { return nil }

        // Bilinear interpolation between 4 nearest grid cells
        let row = (90.0 - latitude) / resolution
        let col = (longitude + 180.0) / resolution

        let r0 = Int(floor(row))
        let c0 = Int(floor(col))
        let r1 = min(r0 + 1, gridLat - 1)
        let c1 = min(c0 + 1, gridLon - 1)
        let r0c = max(0, min(r0, gridLat - 1))
        let c0c = max(0, min(c0, gridLon - 1))

        // Fractional position within cell
        let fr = row - Double(r0)
        let fc = col - Double(c0)

        // Read 4 corner values
        let v00 = Double(data[headerSize + r0c * gridLon + c0c])
        let v01 = Double(data[headerSize + r0c * gridLon + c1])
        let v10 = Double(data[headerSize + r1 * gridLon + c0c])
        let v11 = Double(data[headerSize + r1 * gridLon + c1])

        // Bilinear interpolation
        let interpolated = v00 * (1 - fr) * (1 - fc) +
                           v01 * (1 - fr) * fc +
                           v10 * fr * (1 - fc) +
                           v11 * fr * fc

        return max(1, min(9, Int(interpolated.rounded())))
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
}
