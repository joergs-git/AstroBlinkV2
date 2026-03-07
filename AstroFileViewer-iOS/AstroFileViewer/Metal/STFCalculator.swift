// v0.5.0
import Foundation
import Metal

// PixInsight-compatible STF (Screen Transfer Function) parameter calculator.
// Computes per-channel median, MAD, and derives shadows clip + midtone balance.
// Algorithm source: PixInsight AutoSTF Script (Juan Conejero, PTeam)

struct STFParams {
    var c0: Float = 0.0    // Shadows clipping point [0,1]
    var mb: Float = 0.5    // Midtone balance for MTF [0,1]
}

struct STFCalculator {

    // PixInsight AutoSTF constants
    static let shadowsClip: Float = -1.25    // Sigma factor below median
    static let targetBackground: Float = 0.25 // Target background level [0,1]
    static let sampleFraction: Float = 0.05   // 5% subsample for statistics

    // Calculate STF parameters from a decoded image's raw uint16 buffer
    // Returns array of STFParams: 1 element for mono, 3 for RGB
    static func calculate(from image: DecodedImage) -> [STFParams] {
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
                count: planeSize
            )
            results.append(params)
        }

        return results
    }

    // Calculate STF for a single channel
    private static func calculateChannel(ptr: UnsafePointer<UInt16>, count: Int) -> STFParams {
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

        guard !samples.isEmpty else {
            return STFParams(c0: 0.0, mb: 0.5)
        }

        // Sort for median calculation
        samples.sort()

        let n = samples.count
        let median: Float
        if n % 2 == 0 {
            median = (samples[n / 2 - 1] + samples[n / 2]) / 2.0
        } else {
            median = samples[n / 2]
        }

        // MAD (Median Absolute Deviation) → robust sigma estimate
        // MAD = median(|samples - median|)
        // Normalized MAD = 1.4826 * MAD (equals sigma for normal distribution)
        var deviations = samples.map { abs($0 - median) }
        deviations.sort()

        let mad: Float
        if n % 2 == 0 {
            mad = (deviations[n / 2 - 1] + deviations[n / 2]) / 2.0
        } else {
            mad = deviations[n / 2]
        }

        let normalizedMAD = 1.4826 * mad

        // Shadows clipping point
        let c0 = max(0.0, min(1.0, median + shadowsClip * normalizedMAD))

        // Midtone balance via MTF
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

    // Midtones Transfer Function — inverse for parameter calculation
    // Given target output and input, find the midtone balance parameter
    private static func mtf(_ target: Float, _ x: Float) -> Float {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }
        if x == target { return 0.5 }

        // Solve for m: target = (m-1)*x / ((2m-1)*x - m)
        // Rearranging: m = target * x / (target * (2*x - 1) - x + 1)
        // But we actually need the midtone balance m such that MTF(x, m) = target
        // The formula: m = (target * (2*x - 1) + x - target*x) ... let's derive properly
        //
        // MTF(x, m) = (m-1)*x / ((2m-1)*x - m) = target
        // (m-1)*x = target * ((2m-1)*x - m)
        // mx - x = target*(2mx - x - m)
        // mx - x = 2tmx - tx - tm
        // mx - 2tmx + tm = x - tx
        // m(x - 2tx + t) = x(1 - t)
        // m = x(1 - t) / (x - 2tx + t)
        // m = x(1 - target) / (x(1 - 2*target) + target)

        let denom = x * (1.0 - 2.0 * target) + target
        if abs(denom) < 1e-10 { return 0.5 }
        return x * (1.0 - target) / denom
    }
}
