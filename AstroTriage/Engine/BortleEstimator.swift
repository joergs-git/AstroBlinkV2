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
