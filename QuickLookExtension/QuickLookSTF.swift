// v2.0.0
import Foundation
import Accelerate

// Lightweight STF calculator for QuickLook extension.
// Same PixInsight-compatible algorithm as the main app but without Metal dependency.
struct QuickLookSTFParams {
    var c0: Float = 0.0    // Shadows clipping point [0,1]
    var mb: Float = 0.5    // Midtone balance for MTF [0,1]
}

struct QuickLookSTF {

    static let shadowsClip: Float = -1.25
    static let targetBackground: Float = 0.25
    static let sampleFraction: Float = 0.05

    // Calculate STF parameters for all channels
    static func calculate(
        pixels: UnsafePointer<UInt16>,
        width: Int,
        height: Int,
        channelCount: Int
    ) -> [QuickLookSTFParams] {
        let planeSize = width * height
        var results: [QuickLookSTFParams] = []

        for ch in 0..<channelCount {
            let channelPtr = pixels.advanced(by: ch * planeSize)
            let params = calculateChannel(ptr: channelPtr, count: planeSize)
            results.append(params)
        }

        return results
    }

    private static func calculateChannel(ptr: UnsafePointer<UInt16>, count: Int) -> QuickLookSTFParams {
        // Subsample ~5% of pixels
        let sampleCount = max(1000, Int(Float(count) * sampleFraction))
        let stride = max(1, count / sampleCount)

        var samples = [Float]()
        samples.reserveCapacity(sampleCount)

        var i = 0
        while i < count {
            samples.append(Float(ptr[i]) / 65535.0)
            i += stride
        }

        let n = samples.count
        guard n > 0 else { return QuickLookSTFParams() }

        // vDSP vectorized sort for median
        vDSP_vsort(&samples, vDSP_Length(n), 1)

        let median: Float
        if n % 2 == 0 {
            median = (samples[n / 2 - 1] + samples[n / 2]) / 2.0
        } else {
            median = samples[n / 2]
        }

        // MAD calculation
        let negMedian = -median
        vDSP_vsadd(samples, 1, [negMedian], &samples, 1, vDSP_Length(n))
        vDSP_vabs(samples, 1, &samples, 1, vDSP_Length(n))
        vDSP_vsort(&samples, vDSP_Length(n), 1)

        let mad: Float
        if n % 2 == 0 {
            mad = (samples[n / 2 - 1] + samples[n / 2]) / 2.0
        } else {
            mad = samples[n / 2]
        }

        let normalizedMAD = 1.4826 * mad
        let c0 = max(0.0, min(1.0, median + shadowsClip * normalizedMAD))

        let mb: Float
        if c0 >= 1.0 {
            mb = 0.5
        } else {
            let medNorm = (median - c0) / (1.0 - c0)
            mb = mtf(targetBackground, medNorm)
        }

        return QuickLookSTFParams(c0: c0, mb: mb)
    }

    // Inverse MTF for parameter calculation
    private static func mtf(_ target: Float, _ x: Float) -> Float {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }
        if x == target { return 0.5 }
        let denom = x * (1.0 - 2.0 * target) + target
        if abs(denom) < 1e-10 { return 0.5 }
        return x * (1.0 - target) / denom
    }
}
