// v3.2.0
import Foundation
import Metal
import Accelerate

// PixInsight-compatible STF (Screen Transfer Function) parameter calculator.
// Computes per-channel median, MAD, and derives shadows clip + midtone balance.
// Algorithm source: PixInsight AutoSTF Script (Juan Conejero, PTeam)
// Uses vDSP vectorized sort for ~3x faster median computation on large samples.

struct STFParams {
    var c0: Float = 0.0    // Shadows clipping point [0,1]
    var mb: Float = 0.5    // Midtone balance for MTF [0,1]
}

struct STFCalculator {

    // PixInsight AutoSTF constants
    static let shadowsClip: Float = -1.25    // Sigma factor below median
    static let defaultTargetBackground: Float = 0.25 // Target background level [0,1]
    static let sampleFraction: Float = 0.05   // 5% subsample for statistics

    // Calculate STF parameters from a decoded image's raw uint16 buffer
    // targetBackground: 0.0 = no stretch (linear), 0.25 = default, 0.50 = max stretch
    // Returns array of STFParams: 1 element for mono, 3 for RGB
    static func calculate(from image: DecodedImage, targetBackground: Float = defaultTargetBackground) -> [STFParams] {
        // No stretch: return identity params (no clipping, no midtone adjustment)
        if targetBackground <= 0.001 {
            return Array(repeating: STFParams(c0: 0.0, mb: 0.5), count: image.channelCount)
        }

        let ptr = image.buffer.contents().bindMemory(
            to: UInt16.self,
            capacity: image.pixelCount
        )
        let planeSize = image.width * image.height
        let channelCount = image.channelCount

        var results: [STFParams] = []

        for ch in 0..<channelCount {
            let channelOffset = ch * planeSize
            let params = calculateChannel(
                ptr: ptr.advanced(by: channelOffset),
                count: planeSize,
                targetBackground: targetBackground
            )
            results.append(params)
        }

        return results
    }

    // Calculate STF for a single channel using vDSP vectorized sort
    private static func calculateChannel(ptr: UnsafePointer<UInt16>, count: Int, targetBackground: Float = defaultTargetBackground) -> STFParams {
        // Subsample: take ~5% of pixels with deterministic stride (reproducible)
        let sampleCount = max(1000, Int(Float(count) * sampleFraction))
        let stride = max(1, count / sampleCount)

        // Collect normalized samples [0,1]
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)

        var i = 0
        while i < count {
            samples.append(Float(ptr[i]) / 65535.0)
            i += stride
        }

        let n = samples.count
        guard n > 0 else {
            return STFParams(c0: 0.0, mb: 0.5)
        }

        // vDSP vectorized sort — ~3x faster than stdlib sort for Float arrays
        vDSP_vsort(&samples, vDSP_Length(n), 1) // 1 = ascending

        let median: Float
        if n % 2 == 0 {
            median = (samples[n / 2 - 1] + samples[n / 2]) / 2.0
        } else {
            median = samples[n / 2]
        }

        // MAD: compute absolute deviations in-place, then sort again for median
        // Reuse the samples array to avoid allocation
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

        // Shadows clipping point
        let c0 = max(0.0, min(1.0, median + shadowsClip * normalizedMAD))

        // Midtone balance via MTF — uses the provided targetBackground
        let mb: Float
        if c0 >= 1.0 {
            mb = 0.5
        } else {
            // Map median-relative-to-clip to target background
            let medNorm = (median - c0) / (1.0 - c0)
            mb = mtf(targetBackground, medNorm)
        }

        return STFParams(c0: c0, mb: mb)
    }

    // Noise statistics from first channel (mono or green for OSC)
    // Uses the same 5% subsample as STF — essentially free, ~2ms per image.
    // Returns (median, normalizedMAD) where median = background level, MAD = noise estimator.
    struct NoiseStats {
        let median: Float        // Background signal level [0,1]
        let normalizedMAD: Float // Noise estimator [0,1] (1.4826 * MAD)
    }

    // Center crop fraction for noise measurement: only sample from center 70%
    // to exclude edge effects (vignetting, dithering, optical aberrations)
    private static let noiseCropFraction: Float = 0.70

    static func measureNoise(from image: DecodedImage) -> NoiseStats {
        let ptr = image.buffer.contents().bindMemory(
            to: UInt16.self,
            capacity: image.pixelCount
        )
        let w = image.width
        let h = image.height

        // Center crop boundaries
        let cropMarginX = Int(Float(w) * (1.0 - noiseCropFraction) * 0.5)
        let cropMarginY = Int(Float(h) * (1.0 - noiseCropFraction) * 0.5)
        let cropX0 = cropMarginX
        let cropY0 = cropMarginY
        let cropW = w - 2 * cropMarginX
        let cropH = h - 2 * cropMarginY
        let cropSize = cropW * cropH

        // Use first channel, sample from center crop region
        let sampleCount = max(1000, Int(Float(cropSize) * sampleFraction))
        let sampleStride = max(1, cropSize / sampleCount)

        var samples = [Float]()
        samples.reserveCapacity(sampleCount)

        var i = 0
        while i < cropSize {
            let localY = i / cropW
            let localX = i % cropW
            let globalIdx = (cropY0 + localY) * w + (cropX0 + localX)
            samples.append(Float(ptr[globalIdx]) / 65535.0)
            i += sampleStride
        }

        let n = samples.count
        guard n > 0 else { return NoiseStats(median: 0, normalizedMAD: 0) }

        vDSP_vsort(&samples, vDSP_Length(n), 1)

        let median: Float
        if n % 2 == 0 {
            median = (samples[n / 2 - 1] + samples[n / 2]) / 2.0
        } else {
            median = samples[n / 2]
        }

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

        return NoiseStats(median: median, normalizedMAD: 1.4826 * mad)
    }

    // Midtones Transfer Function — inverse for parameter calculation
    // Given target output and input, find the midtone balance parameter
    private static func mtf(_ target: Float, _ x: Float) -> Float {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }
        if x == target { return 0.5 }

        // m = x(1 - target) / (x(1 - 2*target) + target)
        let denom = x * (1.0 - 2.0 * target) + target
        if abs(denom) < 1e-10 { return 0.5 }
        return x * (1.0 - target) / denom
    }
}
