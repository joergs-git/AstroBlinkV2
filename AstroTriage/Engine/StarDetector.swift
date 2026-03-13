// v3.6.0 — Shared star detection utility
// Extracted from QuickStackEngineV2 for reuse by StarMetricsCalculator and both stack engines.
// CPU-based: threshold above background + 3x3 local maxima + weighted centroid.
// Operates on subsampled data for speed (~50-80ms per 50MP image at 4x subsample).

import Foundation
import Accelerate
import Metal

// A detected star with sub-pixel position in full-resolution coordinates
struct DetectedStar: Comparable {
    let x: Float     // Sub-pixel X in full-res coordinates
    let y: Float     // Sub-pixel Y in full-res coordinates
    let brightness: Float  // Background-subtracted peak brightness

    static func < (lhs: DetectedStar, rhs: DetectedStar) -> Bool {
        lhs.brightness > rhs.brightness  // Sort brightest first
    }
}

// MARK: - CPU Star Detection

enum StarDetector {

    /// Detect stars in a decoded image using CPU-based threshold + local maxima.
    /// Returns up to `maxStars` brightest stars sorted by brightness (descending).
    ///
    /// - Parameters:
    ///   - image: Decoded uint16 image in Metal shared buffer
    ///   - maxStars: Maximum number of stars to return (default 50)
    ///   - subsampleFactor: Downsample factor for speed (default 4 = 1/4 resolution)
    ///   - sigmaThreshold: Detection threshold in sigma above background (default 5.0)
    ///   - channel: Which channel to use (0=first/mono, 1=green for debayered OSC)
    /// - Returns: Array of detected stars, sorted brightest first
    static func detectStars(
        in image: DecodedImage,
        maxStars: Int = 50,
        subsampleFactor: Int = 4,
        sigmaThreshold: Float = 5.0,
        channel: Int = 0
    ) -> [DetectedStar] {
        let w = image.width
        let h = image.height
        let planeSize = w * h
        let channelOffset = min(channel, image.channelCount - 1) * planeSize
        let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: planeSize * image.channelCount)

        let subW = w / subsampleFactor
        let subH = h / subsampleFactor
        guard subW > 10, subH > 10 else { return [] }

        // Build subsampled float array from selected channel
        var subData = [Float](repeating: 0, count: subW * subH)
        for sy in 0..<subH {
            for sx in 0..<subW {
                let srcIdx = channelOffset + sy * subsampleFactor * w + sx * subsampleFactor
                subData[sy * subW + sx] = Float(ptr[srcIdx])
            }
        }

        // Compute background median and MAD for threshold
        var sorted = subData
        vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
        let median = sorted[sorted.count / 2]

        var deviations = subData
        let negMedian = -median
        vDSP_vsadd(deviations, 1, [negMedian], &deviations, 1, vDSP_Length(deviations.count))
        vDSP_vabs(deviations, 1, &deviations, 1, vDSP_Length(deviations.count))
        vDSP_vsort(&deviations, vDSP_Length(deviations.count), 1)
        let mad = deviations[deviations.count / 2]
        let sigma = 1.4826 * mad

        guard sigma > 0 else { return [] }
        let threshold = median + sigmaThreshold * sigma

        // Find local maxima above threshold
        var stars: [DetectedStar] = []
        let border = 2

        for sy in border..<(subH - border) {
            for sx in border..<(subW - border) {
                let val = subData[sy * subW + sx]
                guard val > threshold else { continue }

                // Check if local maximum in 3x3 neighborhood
                var isMax = true
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        if subData[(sy + dy) * subW + (sx + dx)] >= val {
                            isMax = false
                            break
                        }
                    }
                    if !isMax { break }
                }
                guard isMax else { continue }

                // Weighted centroid in 3x3 neighborhood for sub-pixel accuracy
                var sumX: Float = 0, sumY: Float = 0, sumW: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let v = subData[(sy + dy) * subW + (sx + dx)] - median
                        if v > 0 {
                            sumX += Float(sx + dx) * v
                            sumY += Float(sy + dy) * v
                            sumW += v
                        }
                    }
                }

                if sumW > 0 {
                    let fullX = (sumX / sumW) * Float(subsampleFactor)
                    let fullY = (sumY / sumW) * Float(subsampleFactor)
                    stars.append(DetectedStar(x: fullX, y: fullY, brightness: val - median))
                }
            }
        }

        stars.sort()
        return Array(stars.prefix(maxStars))
    }

    /// Refine star positions using full-resolution weighted centroid.
    /// Takes coarse-detected stars and re-centroids each one on the raw full-res data
    /// using a larger window (radius pixels). This gives true sub-pixel accuracy.
    /// Standard approach in professional astrometry (SExtractor, DAOPHOT).
    ///
    /// - Parameters:
    ///   - stars: Coarsely detected stars (from detectStars)
    ///   - image: Full-resolution decoded image
    ///   - radius: Half-size of centroid window (default 4 → 9×9 window)
    ///   - channel: Which channel to use
    /// - Returns: Stars with refined positions
    static func refinePositions(
        stars: [DetectedStar],
        in image: DecodedImage,
        radius: Int = 4,
        channel: Int = 0
    ) -> [DetectedStar] {
        let w = image.width
        let h = image.height
        let planeSize = w * h
        let channelOffset = min(channel, image.channelCount - 1) * planeSize
        let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: planeSize * image.channelCount)

        // Compute local background from a quick subsample
        let sampleStride = max(1, planeSize / 10000)
        var bgSamples = [Float]()
        bgSamples.reserveCapacity(10000)
        for i in stride(from: 0, to: planeSize, by: sampleStride) {
            bgSamples.append(Float(ptr[channelOffset + i]))
        }
        vDSP_vsort(&bgSamples, vDSP_Length(bgSamples.count), 1)
        let bgMedian = bgSamples[bgSamples.count / 2]

        var refined: [DetectedStar] = []
        refined.reserveCapacity(stars.count)

        for star in stars {
            // Center of refinement window (round to nearest pixel)
            let cx = Int(star.x + 0.5)
            let cy = Int(star.y + 0.5)

            // Bounds check
            guard cx >= radius && cx < w - radius && cy >= radius && cy < h - radius else {
                refined.append(star) // Keep original if too close to edge
                continue
            }

            // Weighted centroid in (2*radius+1) × (2*radius+1) window on full-res data
            var sumX: Float = 0, sumY: Float = 0, sumW: Float = 0
            var peakVal: Float = 0

            for dy in -radius...radius {
                for dx in -radius...radius {
                    let px = cx + dx
                    let py = cy + dy
                    let v = Float(ptr[channelOffset + py * w + px]) - bgMedian
                    if v > 0 {
                        sumX += Float(px) * v
                        sumY += Float(py) * v
                        sumW += v
                        if v > peakVal { peakVal = v }
                    }
                }
            }

            if sumW > 0 {
                refined.append(DetectedStar(
                    x: sumX / sumW,
                    y: sumY / sumW,
                    brightness: peakVal
                ))
            } else {
                refined.append(star)
            }
        }

        return refined
    }

    /// Compute background median and sigma from a decoded image (same algorithm as star detection).
    /// Used to pass threshold/median to GPU star detection kernel.
    ///
    /// - Parameters:
    ///   - image: Decoded uint16 image
    ///   - subsampleFactor: Downsample factor (matches star detection)
    ///   - sigmaThreshold: Sigma multiplier for threshold
    ///   - channel: Which channel to use
    /// - Returns: (median, threshold) tuple in uint16 scale, or nil if sigma is zero
    static func computeThreshold(
        from image: DecodedImage,
        subsampleFactor: Int = 2,
        sigmaThreshold: Float = 5.0,
        channel: Int = 0
    ) -> (median: Float, threshold: Float)? {
        let w = image.width
        let h = image.height
        let planeSize = w * h
        let channelOffset = min(channel, image.channelCount - 1) * planeSize
        let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: planeSize * image.channelCount)

        // Use 5% subsample for speed (same as STFCalculator)
        let sampleCount = max(1000, planeSize / 20)
        let stride = max(1, planeSize / sampleCount)

        var samples = [Float]()
        samples.reserveCapacity(sampleCount)

        var i = 0
        while i < planeSize {
            samples.append(Float(ptr[channelOffset + i]))
            i += stride
        }

        let n = samples.count
        guard n > 0 else { return nil }

        vDSP_vsort(&samples, vDSP_Length(n), 1)
        let median = samples[n / 2]

        let negMedian = -median
        vDSP_vsadd(samples, 1, [negMedian], &samples, 1, vDSP_Length(n))
        vDSP_vabs(samples, 1, &samples, 1, vDSP_Length(n))
        vDSP_vsort(&samples, vDSP_Length(n), 1)

        let mad = samples[n / 2]
        let sigma = 1.4826 * mad

        guard sigma > 0 else { return nil }
        let threshold = median + sigmaThreshold * sigma

        return (median, threshold)
    }
}
