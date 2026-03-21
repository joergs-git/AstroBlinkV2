// v5.1.1
import Foundation
import ImageDecoderBridge

// CPU bilinear debayer for QuickLook extension (no Metal available in sandbox).
// Converts raw Bayer CFA mono data to 3-channel planar RGB uint16.
// Same algorithm as the GPU debayer_bilinear kernel in Shaders.metal.
struct QuickLookDebayer {

    // Bayer pattern encoding (matches Metal shader convention)
    enum BayerPattern: Int {
        case rggb = 0
        case grbg = 1
        case gbrg = 2
        case bggr = 3
    }

    // Parse BAYERPAT string from FITS/XISF header to enum
    static func parsePattern(_ str: String) -> BayerPattern? {
        switch str.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "RGGB": return .rggb
        case "GRBG": return .grbg
        case "GBRG": return .gbrg
        case "BGGR": return .bggr
        default: return nil
        }
    }

    // Read BAYERPAT header from a FITS or XISF file via the C bridge
    static func readBayerPattern(url: URL) -> BayerPattern? {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        var headerResult: HeaderResult
        if ext == "xisf" {
            headerResult = read_xisf_headers(path)
        } else {
            headerResult = read_fits_headers(path)
        }

        guard headerResult.success != 0, headerResult.count > 0, let entries = headerResult.entries else {
            var mutable = headerResult
            free_header_result(&mutable)
            return nil
        }

        var pattern: BayerPattern?
        for i in 0..<Int(headerResult.count) {
            let key = withUnsafePointer(to: entries[i].key) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 80) { String(cString: $0) }
            }
            if key.trimmingCharacters(in: .whitespaces) == "BAYERPAT" {
                let value = withUnsafePointer(to: entries[i].value) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
                // Strip single quotes that FITS string values may have
                let cleaned = value.replacingOccurrences(of: "'", with: "")
                    .trimmingCharacters(in: .whitespaces)
                pattern = parsePattern(cleaned)
                break
            }
        }

        var mutable = headerResult
        free_header_result(&mutable)
        return pattern
    }

    // Debayer mono CFA data to 3-channel planar RGB (R plane, G plane, B plane).
    // Input: width*height uint16 mono pixels + Bayer pattern.
    // Output: newly allocated buffer with width*height*3 uint16 pixels (caller must free).
    static func debayer(
        pixels: UnsafePointer<UInt16>,
        width: Int,
        height: Int,
        pattern: BayerPattern
    ) -> QuickLookImageData? {
        let planeSize = width * height
        let totalPixels = planeSize * 3
        guard let output = UnsafeMutablePointer<UInt16>.allocate(capacity: totalPixels) as UnsafeMutablePointer<UInt16>? else {
            return nil
        }

        // Color map: for each Bayer pattern, what color is at each 2x2 position
        // Position index: py*2 + px, value: 0=R, 1=G, 2=B
        let colorMaps: [[Int]] = [
            [0, 1, 1, 2],  // RGGB
            [1, 0, 2, 1],  // GRBG
            [1, 2, 0, 1],  // GBRG
            [2, 1, 1, 0],  // BGGR
        ]
        let colorMap = colorMaps[pattern.rawValue]

        // Process rows in parallel for performance
        DispatchQueue.concurrentPerform(iterations: height) { y in
            let py = y % 2
            for x in 0..<width {
                let px = x % 2
                let pos = py * 2 + px
                let myColor = colorMap[pos]
                let idx = y * width + x

                let center = Float(pixels[idx])
                var r: Float, g: Float, b: Float

                // Clamped pixel access helper
                func pix(_ px: Int, _ py: Int) -> Float {
                    let cx = max(0, min(width - 1, px))
                    let cy = max(0, min(height - 1, py))
                    return Float(pixels[cy * width + cx])
                }

                if myColor == 0 {
                    // Red pixel
                    r = center
                    g = (pix(x-1, y) + pix(x+1, y) + pix(x, y-1) + pix(x, y+1)) * 0.25
                    b = (pix(x-1, y-1) + pix(x+1, y-1) + pix(x-1, y+1) + pix(x+1, y+1)) * 0.25
                } else if myColor == 2 {
                    // Blue pixel
                    b = center
                    g = (pix(x-1, y) + pix(x+1, y) + pix(x, y-1) + pix(x, y+1)) * 0.25
                    r = (pix(x-1, y-1) + pix(x+1, y-1) + pix(x-1, y+1) + pix(x+1, y+1)) * 0.25
                } else {
                    // Green pixel — need to determine neighbor colors
                    g = center
                    let neighborPos = py * 2 + ((px + 1) % 2)
                    let neighborColor = colorMap[neighborPos]
                    if neighborColor == 0 {
                        r = (pix(x-1, y) + pix(x+1, y)) * 0.5
                        b = (pix(x, y-1) + pix(x, y+1)) * 0.5
                    } else {
                        b = (pix(x-1, y) + pix(x+1, y)) * 0.5
                        r = (pix(x, y-1) + pix(x, y+1)) * 0.5
                    }
                }

                // Write to planar RGB output
                output[idx] = UInt16(max(0, min(65535, r)))
                output[planeSize + idx] = UInt16(max(0, min(65535, g)))
                output[2 * planeSize + idx] = UInt16(max(0, min(65535, b)))
            }
        }

        return QuickLookImageData(
            pixels: output,
            width: width,
            height: height,
            channelCount: 3,
            byteCount: totalPixels * MemoryLayout<UInt16>.size
        )
    }
}
