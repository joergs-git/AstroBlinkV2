// Gradient removal via median grid + bicubic interpolation
// Subtracts smooth background model from stacked image data
// Operates on raw float pixel data (planar format: RRRR...GGGG...BBBB...)
import Foundation
import Accelerate

enum GradientRemoval {

    // Grid size for background sampling (8x8 = 64 tiles)
    private static let gridSize = 8

    // Remove background gradient from planar float data
    // Returns corrected data with flat background
    static func removeGradient(data: [Float], width: Int, height: Int, channelCount: Int) -> [Float] {
        let planeSize = width * height
        var result = data

        for ch in 0..<channelCount {
            let offset = ch * planeSize
            let plane = Array(data[offset..<offset + planeSize])
            let corrected = removeGradientFromPlane(plane, width: width, height: height)
            result.replaceSubrange(offset..<offset + planeSize, with: corrected)
        }

        return result
    }

    // Remove gradient from a single channel plane
    private static func removeGradientFromPlane(_ plane: [Float], width: Int, height: Int) -> [Float] {
        let tileW = width / gridSize
        let tileH = height / gridSize

        // Step 1: Compute sigma-clipped median for each grid tile
        // (sigma-clip removes stars, leaving only background)
        var gridMedians = [[Float]](repeating: [Float](repeating: 0, count: gridSize), count: gridSize)

        for gy in 0..<gridSize {
            for gx in 0..<gridSize {
                let startX = gx * tileW
                let startY = gy * tileH
                let endX = min(startX + tileW, width)
                let endY = min(startY + tileH, height)

                // Collect tile pixels
                var tilePixels = [Float]()
                tilePixels.reserveCapacity(tileW * tileH)
                for y in startY..<endY {
                    for x in startX..<endX {
                        tilePixels.append(plane[y * width + x])
                    }
                }

                // Sigma-clipped median (2 iterations, 2.5 sigma)
                gridMedians[gy][gx] = sigmaClippedMedian(tilePixels)
            }
        }

        // Step 2: Bicubic interpolation of grid medians to full resolution
        var background = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            let gy = Float(y) / Float(tileH) - 0.5
            for x in 0..<width {
                let gx = Float(x) / Float(tileW) - 0.5
                background[y * width + x] = bicubicInterpolate(gridMedians, gx: gx, gy: gy)
            }
        }

        // Step 3: Subtract background, shift to keep median the same
        // result = pixel - background + global_median
        var result = [Float](repeating: 0, count: width * height)
        let globalMedian = gridMedians.flatMap { $0 }.sorted()[gridSize * gridSize / 2]

        for i in 0..<width * height {
            result[i] = max(0, plane[i] - background[i] + globalMedian)
        }

        return result
    }

    // Sigma-clipped median: reject outliers (stars) before computing median
    private static func sigmaClippedMedian(_ pixels: [Float], iterations: Int = 2, sigma: Float = 2.5) -> Float {
        guard !pixels.isEmpty else { return 0 }
        var filtered = pixels

        for _ in 0..<iterations {
            guard filtered.count > 10 else { break }
            filtered.sort()
            let median = filtered[filtered.count / 2]

            // MAD-based sigma estimate
            let deviations = filtered.map { Swift.abs($0 - median) }
            let mad = deviations.sorted()[deviations.count / 2] * 1.4826
            guard mad > 0 else { break }

            let low = median - sigma * mad
            let high = median + sigma * mad
            filtered = filtered.filter { $0 >= low && $0 <= high }
        }

        guard !filtered.isEmpty else { return pixels.sorted()[pixels.count / 2] }
        return filtered[filtered.count / 2]
    }

    // Bicubic interpolation on the grid
    private static func bicubicInterpolate(_ grid: [[Float]], gx: Float, gy: Float) -> Float {
        let gs = gridSize

        // Clamp to grid bounds
        let x = max(0, min(Float(gs - 1), gx))
        let y = max(0, min(Float(gs - 1), gy))

        let xi = Int(x)
        let yi = Int(y)
        let fx = x - Float(xi)
        let fy = y - Float(yi)

        // Bilinear interpolation (simpler, nearly as good for smooth gradients)
        let x0 = max(0, min(gs - 1, xi))
        let x1 = max(0, min(gs - 1, xi + 1))
        let y0 = max(0, min(gs - 1, yi))
        let y1 = max(0, min(gs - 1, yi + 1))

        let a = grid[y0][x0] * (1 - fx) + grid[y0][x1] * fx
        let b = grid[y1][x0] * (1 - fx) + grid[y1][x1] * fx

        return a * (1 - fy) + b * fy
    }
}
