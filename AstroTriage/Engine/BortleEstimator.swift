// Bortle sky quality estimation from SITELAT/SITELONG coordinates.
// Uses a 0.025° resolution global grid (~1.6 MB gzipped) derived from
// the Falchi 2016 World Atlas of Artificial Night Sky Brightness.
// Data source: GFZ Potsdam (CC-BY 4.0), DOI: 10.5880/GFZ.1.4.2016.001
// Accuracy: ±1 Bortle class. Resolution ~2.8km at equator, ~1.5km at lat 52.

import Foundation
import Compression

enum BortleEstimator {

    // Grid parameters (must match generator script)
    private static let gridLon = 14400    // columns: -180 to +179.975
    private static let gridLat = 7200     // rows: +90 to -89.975
    private static let resolution = 0.025 // degrees per cell
    private static let headerSize = 8     // 4 bytes magic + 4 bytes dimensions

    // Lazy-loaded decompressed grid data (~99 MB in memory, 1.6 MB on disk)
    private static var gridData: [UInt8]? = {
        guard let url = Bundle.main.url(forResource: "BortleGrid", withExtension: "bin") else {
            print("[BortleEstimator] BortleGrid.bin not found in bundle")
            return nil
        }
        guard let fileData = try? Data(contentsOf: url) else {
            print("[BortleEstimator] Failed to load BortleGrid.bin")
            return nil
        }
        // Verify magic header "BRTL"
        guard fileData.count > headerSize,
              fileData[0] == 0x42, fileData[1] == 0x52, fileData[2] == 0x54, fileData[3] == 0x4C else {
            print("[BortleEstimator] Invalid BortleGrid.bin header")
            return nil
        }

        // Decompress zlib data using Compression framework
        let compressedData = fileData.subdata(in: headerSize..<fileData.count)
        let expectedSize = gridLon * gridLat
        var decompressed = [UInt8](repeating: 0, count: expectedSize)

        // Strip zlib header (2 bytes) and checksum (4 bytes) — COMPRESSION_ZLIB expects raw deflate
        let deflateStart = 2  // skip zlib header
        let deflateEnd = compressedData.count - 4  // skip adler32 checksum
        guard deflateEnd > deflateStart else {
            print("[BortleEstimator] Compressed data too short")
            return nil
        }

        let deflateData = compressedData.subdata(in: deflateStart..<deflateEnd)
        let decodedSize = deflateData.withUnsafeBytes { srcPtr -> Int in
            let src = srcPtr.bindMemory(to: UInt8.self)
            return compression_decode_buffer(
                &decompressed, expectedSize,
                src.baseAddress!, deflateData.count,
                nil, COMPRESSION_ZLIB
            )
        }

        guard decodedSize == expectedSize else {
            print("[BortleEstimator] Decompression size mismatch: \(decodedSize) vs \(expectedSize)")
            return nil
        }

        print("[BortleEstimator] Grid loaded: \(gridLon)×\(gridLat) at \(resolution)° (\(decodedSize) bytes)")
        return decompressed
    }()

    // MARK: - Public API

    /// Estimate Bortle class (1-9) for the given coordinates.
    /// Uses bilinear interpolation between grid cells for smooth boundaries.
    /// Returns integer Bortle from local grid (offline fallback).
    static func estimate(latitude: Double, longitude: Double) -> Int? {
        guard let grid = gridData else { return nil }
        guard latitude >= -90 && latitude <= 90,
              longitude >= -180 && longitude <= 180 else { return nil }

        // Bilinear interpolation between 4 nearest grid cells
        let row = (90.0 - latitude) / resolution
        let col = (longitude + 180.0) / resolution

        let r0 = max(0, min(Int(floor(row)), gridLat - 1))
        let c0 = max(0, min(Int(floor(col)), gridLon - 1))
        let r1 = min(r0 + 1, gridLat - 1)
        let c1 = min(c0 + 1, gridLon - 1)

        let fr = row - Double(r0)
        let fc = col - Double(c0)

        let v00 = Double(grid[r0 * gridLon + c0])
        let v01 = Double(grid[r0 * gridLon + c1])
        let v10 = Double(grid[r1 * gridLon + c0])
        let v11 = Double(grid[r1 * gridLon + c1])

        let interpolated = v00 * (1 - fr) * (1 - fc) +
                           v01 * (1 - fr) * fc +
                           v10 * fr * (1 - fc) +
                           v11 * fr * fc

        return max(1, min(9, Int(interpolated.rounded())))
    }

    /// Estimate Bortle via Supabase REST API (actual VIIRS satellite data).
    /// Falls back to local grid if offline. Caches result in UserDefaults.
    /// Call from background thread — does network I/O.
    static func estimateOnline(latitude: Double, longitude: Double) async -> Double? {
        guard latitude >= -90 && latitude <= 90,
              longitude >= -180 && longitude <= 180 else { return nil }

        // Cache key: round to 0.01° (~1km) — same coordinates always get same result
        let key = String(format: "bortle_%.2f_%.2f", latitude, longitude)
        // Only use cache if it's a Double (fractional) — discard old Int cache from v5.7.0
        if let cached = UserDefaults.standard.object(forKey: key) {
            if let d = cached as? Double, d != d.rounded() {
                // Fractional value = from Supabase, trust it
                return d
            }
            // Integer value = old local grid cache, ignore and re-query
        }

        // Query Supabase REST API directly (no Edge Function needed)
        if SupabaseClient.isConfigured {
            let gridLat = String(format: "%.1f", (latitude * 10).rounded() / 10)
            let gridLon = String(format: "%.1f", (longitude * 10).rounded() / 10)
            if let url = SupabaseClient.restURL(table: "bortle_grid",
                                                query: "lat=eq.\(gridLat)&lon=eq.\(gridLon)&select=bortle") {
                var request = SupabaseClient.makeRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                // 10s timeout preserved — local grid fallback is right there if Supabase stalls.
                if let (data, response) = try? await SupabaseClient.send(request, timeout: 10, retries: 2),
                   (200...299).contains(response.statusCode),
                   let rows = try? JSONDecoder().decode([[String: Double]].self, from: data),
                   let bortle = rows.first?["bortle"] {
                    let clamped = max(1.0, min(9.0, bortle))
                    UserDefaults.standard.set(clamped, forKey: key)
                    return clamped
                }
            }
        }

        // Fallback to local grid (integer precision)
        if let local = estimate(latitude: latitude, longitude: longitude) {
            let v = Double(local)
            UserDefaults.standard.set(v, forKey: key)
            return v
        }
        return nil
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
