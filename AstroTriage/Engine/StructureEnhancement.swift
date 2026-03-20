// Structure enhancement for nebula/cloud detail
// Large-radius local contrast boost that enhances extended features without sharpening stars.
// Uses multi-scale approach: extract detail at nebula-scale frequencies, amplify, add back.
import Foundation
import Accelerate

enum StructureEnhancement {

    // Enhance extended structure (nebula, clouds) in planar float data
    // amount: 0.0 = off, 1.0 = moderate, 2.0 = strong
    static func enhance(data: [Float], width: Int, height: Int,
                        channelCount: Int, amount: Float) -> [Float] {
        guard amount > 0.01 else { return data }
        let planeSize = width * height
        var result = data

        for ch in 0..<channelCount {
            let offset = ch * planeSize
            let plane = Array(data[offset..<offset + planeSize])
            let enhanced = enhancePlane(plane, width: width, height: height, amount: amount)
            result.replaceSubrange(offset..<offset + planeSize, with: enhanced)
        }

        return result
    }

    // Enhance structure in a single channel
    // Approach: subtract large-blur (nebula scale), amplify mid-frequency detail, add back
    // Stars are point sources and get removed by the large blur → not amplified
    private static func enhancePlane(_ plane: [Float], width: Int, height: Int,
                                     amount: Float) -> [Float] {
        let planeSize = width * height

        // Two-scale approach:
        // Scale 1: radius ~40px (large nebula structure)
        // Scale 2: radius ~15px (smaller cloud detail)
        let blur1 = boxBlur(plane, width: width, height: height, radius: 40)
        let blur2 = boxBlur(plane, width: width, height: height, radius: 15)

        // Extract detail layers
        // Layer 1: mid-frequency (between 15px and 40px) — nebula texture
        // Layer 2: high-mid-frequency (between original and 15px) — fine structure
        var detail1 = [Float](repeating: 0, count: planeSize)
        var detail2 = [Float](repeating: 0, count: planeSize)

        // detail1 = blur2 - blur1 (medium scale structure)
        vDSP_vsub(blur1, 1, blur2, 1, &detail1, 1, vDSP_Length(planeSize))
        // detail2 = original - blur2 (fine structure, includes stars)
        vDSP_vsub(blur2, 1, plane, 1, &detail2, 1, vDSP_Length(planeSize))

        // Only boost detail1 (nebula scale) — detail2 contains stars
        // Boost factor: amount * 1.5 for mid-frequency, amount * 0.3 for fine
        let midBoost = amount * 1.5
        let fineBoost = amount * 0.3  // gentle fine structure boost (stars are here)

        // result = blur1 + detail1 * (1 + midBoost) + detail2 * (1 + fineBoost)
        var result = [Float](repeating: 0, count: planeSize)
        for i in 0..<planeSize {
            result[i] = max(0, blur1[i] + detail1[i] * (1.0 + midBoost) + detail2[i] * (1.0 + fineBoost))
        }

        return result
    }

    // Fast box blur (separable: horizontal pass + vertical pass)
    // Approximates Gaussian blur, runs in O(n) regardless of radius
    private static func boxBlur(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let r = min(radius, min(width, height) / 4)
        guard r > 0 else { return plane }

        // Two-pass box blur (approximates Gaussian well)
        var temp = horizontalBlur(plane, width: width, height: height, radius: r)
        temp = verticalBlur(temp, width: width, height: height, radius: r)
        // Second pass for smoother result
        temp = horizontalBlur(temp, width: width, height: height, radius: r)
        temp = verticalBlur(temp, width: width, height: height, radius: r)
        return temp
    }

    private static func horizontalBlur(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var result = [Float](repeating: 0, count: width * height)
        let kernelSize = Float(2 * radius + 1)

        for y in 0..<height {
            let rowStart = y * width

            // Initialize running sum for first pixel
            var sum: Float = 0
            for x in 0...min(radius, width - 1) {
                sum += plane[rowStart + x]
            }
            // Mirror left edge
            for x in 1...radius {
                sum += plane[rowStart + min(x, width - 1)]
            }

            result[rowStart] = sum / kernelSize

            for x in 1..<width {
                let addIdx = min(x + radius, width - 1)
                let removeIdx = max(x - radius - 1, 0)
                sum += plane[rowStart + addIdx] - plane[rowStart + removeIdx]
                result[rowStart + x] = sum / kernelSize
            }
        }

        return result
    }

    private static func verticalBlur(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var result = [Float](repeating: 0, count: width * height)
        let kernelSize = Float(2 * radius + 1)

        for x in 0..<width {
            var sum: Float = 0
            for y in 0...min(radius, height - 1) {
                sum += plane[y * width + x]
            }
            for y in 1...radius {
                sum += plane[min(y, height - 1) * width + x]
            }

            result[x] = sum / kernelSize

            for y in 1..<height {
                let addIdx = min(y + radius, height - 1)
                let removeIdx = max(y - radius - 1, 0)
                sum += plane[addIdx * width + x] - plane[removeIdx * width + x]
                result[y * width + x] = sum / kernelSize
            }
        }

        return result
    }
}
