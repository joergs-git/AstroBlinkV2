// Wiener-inspired deconvolution — fast spatial-domain implementation
// Uses iterative sharpening with noise-aware regularization
// Much faster than FFT-based Wiener for large images while giving similar results
import Foundation
import Accelerate

enum WienerDeconvolution {

    // Apply deconvolution to all channels of planar float data
    // fwhm: estimated PSF width in pixels (from star detection)
    // strength: 0.0 = no effect, 1.0 = moderate, 2.0 = aggressive
    static func deconvolve(data: [Float], width: Int, height: Int,
                           channelCount: Int, fwhm: Float, strength: Float) -> [Float] {
        guard strength > 0.01, fwhm > 0.5 else { return data }
        let planeSize = width * height
        var result = data

        for ch in 0..<channelCount {
            let offset = ch * planeSize
            let plane = Array(data[offset..<offset + planeSize])
            let deconvolved = deconvolvePlane(plane, width: width, height: height,
                                              fwhm: fwhm, strength: strength)
            result.replaceSubrange(offset..<offset + planeSize, with: deconvolved)
        }

        return result
    }

    // Spatial-domain deconvolution using iterative unsharp with noise regularization
    // Approach: multi-pass sharpening at PSF-matched radius with decreasing strength
    // This approximates Wiener deconvolution without the FFT overhead
    private static func deconvolvePlane(_ plane: [Float], width: Int, height: Int,
                                         fwhm: Float, strength: Float) -> [Float] {
        let planeSize = width * height

        // PSF radius from FWHM (sigma = FWHM/2.355, effective radius ≈ 2*sigma)
        let sigma = max(0.5, fwhm / 2.355)
        let radius = max(1, Int(ceil(sigma * 2)))

        // Estimate noise level (MAD of the plane)
        let noiseLevel = estimateNoise(plane)

        // Multi-pass iterative sharpening at PSF-matched scale
        // Pass 1: primary PSF radius (star sharpening)
        // Pass 2: slightly larger (halo reduction)
        var result = plane

        let passes: [(radius: Int, weight: Float)] = [
            (radius, 0.7 * strength),
            (max(1, radius * 2), 0.3 * strength),
        ]

        for pass in passes {
            let blurred = gaussianBlur(result, width: width, height: height, radius: pass.radius)

            // Noise-regularized sharpening: only sharpen where signal > noise
            // detail = original - blurred (high-frequency content)
            // result = original + weight * detail * (signal / (signal + noise²))
            let noise2 = noiseLevel * noiseLevel * 10.0  // regularization strength

            for i in 0..<planeSize {
                let detail = result[i] - blurred[i]
                let signal = Swift.abs(detail)
                // Wiener-like regularization: suppress sharpening in noisy regions
                let regularized = detail * signal / (signal + noise2)
                result[i] = max(0, result[i] + pass.weight * regularized)
            }
        }

        return result
    }

    // Fast Gaussian blur via two-pass box blur (O(n) per pixel)
    private static func gaussianBlur(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let r = min(radius, min(width, height) / 4)
        guard r > 0 else { return plane }
        // Two-pass box blur approximates Gaussian
        var temp = horizontalBlur(plane, width: width, height: height, radius: r)
        temp = verticalBlur(temp, width: width, height: height, radius: r)
        temp = horizontalBlur(temp, width: width, height: height, radius: r)
        temp = verticalBlur(temp, width: width, height: height, radius: r)
        return temp
    }

    // Estimate noise via MAD (median absolute deviation)
    private static func estimateNoise(_ plane: [Float]) -> Float {
        // Subsample for speed
        let stride = max(1, plane.count / 10000)
        var samples = [Float]()
        samples.reserveCapacity(10000)
        for i in Swift.stride(from: 0, to: plane.count, by: stride) {
            samples.append(plane[i])
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let deviations = samples.map { Swift.abs($0 - median) }.sorted()
        return deviations[deviations.count / 2] * 1.4826
    }

    private static func horizontalBlur(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var result = [Float](repeating: 0, count: width * height)
        let kernelSize = Float(2 * radius + 1)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for x in 0...min(radius, width - 1) { sum += plane[row + x] }
            for x in 1...radius { sum += plane[row + min(x, width - 1)] }
            result[row] = sum / kernelSize
            for x in 1..<width {
                sum += plane[row + min(x + radius, width - 1)] - plane[row + max(x - radius - 1, 0)]
                result[row + x] = sum / kernelSize
            }
        }
        return result
    }

    private static func verticalBlur(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var result = [Float](repeating: 0, count: width * height)
        let kernelSize = Float(2 * radius + 1)
        for x in 0..<width {
            var sum: Float = 0
            for y in 0...min(radius, height - 1) { sum += plane[y * width + x] }
            for y in 1...radius { sum += plane[min(y, height - 1) * width + x] }
            result[x] = sum / kernelSize
            for y in 1..<height {
                sum += plane[min(y + radius, height - 1) * width + x] - plane[max(y - radius - 1, 0) * width + x]
                result[y * width + x] = sum / kernelSize
            }
        }
        return result
    }
}
