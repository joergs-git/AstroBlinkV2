// v3.6.0 — Computed HFR & FWHM from detected star positions
// Measures Half-Flux Radius and Full Width at Half Maximum for quality scoring.
// Operates on full-resolution uint16 data using small patches around each star.
// FWHM uses linearized Gaussian fit (ln(brightness) vs dist² → sigma → 2.355σ).
// Values are for *relative comparison within a session*, not absolute calibration.

import Foundation
import Metal

// Per-image star metrics: median HFR, FWHM, and star count
struct StarMetrics {
    let medianHFR: Double       // Half-flux radius in pixels (median of measured stars)
    let medianFWHM: Double      // Full width at half maximum in pixels
    let measuredStarCount: Int  // Stars used for HFR/FWHM measurement (capped subset)
    let totalStarCount: Int     // True total number of stars detected in the image
}

enum StarMetricsCalculator {

    // Aperture radius for HFR/FWHM measurement (pixels around centroid)
    private static let apertureRadius: Float = 10.0
    // Annulus for local background estimation
    private static let bgInnerRadius: Float = 12.0
    private static let bgOuterRadius: Float = 15.0
    // Minimum number of qualifying stars to produce a result
    private static let minStars = 2
    // Maximum stars to measure (top N brightest after filtering)
    private static let maxMeasuredStars = 30
    // Saturation threshold (98% of uint16 max — relaxed from 95% to accept more stars)
    private static let saturationThreshold: UInt16 = 64224
    // Minimum distance between stars to avoid crowding (full-res pixels)
    private static let crowdingDistance: Float = 15.0
    // Minimum distance from image edge (full-res pixels)
    private static let edgeMargin: Float = 12.0
    // Center crop fraction for quality measurement: only use stars within this
    // fraction of the image (centered). Excludes edge stars affected by optical
    // aberrations, vignetting, dithering shifts, and tilt.
    private static let centerCropFraction: Float = 0.70
    // Gaussian fit: minimum pixels above background required for valid fit
    private static let minFitPixels = 8

    /// Measure HFR and FWHM from detected star positions on full-resolution image data.
    ///
    /// - Parameters:
    ///   - stars: Detected stars from GPU or CPU star detection (full-res coordinates)
    ///   - image: Full-resolution decoded image (uint16 buffer)
    ///   - channel: Which channel to measure on (0=mono/first, 1=green for debayered OSC)
    /// - Returns: StarMetrics with median values, or nil if fewer than minStars qualify
    static func measure(
        stars: [DetectedStar],
        fullResImage image: DecodedImage,
        channel: Int = 0,
        totalStarCount: Int? = nil
    ) -> StarMetrics? {
        let w = image.width
        let h = image.height
        let planeSize = w * h
        let ch = min(channel, image.channelCount - 1)
        let channelOffset = ch * planeSize
        let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: planeSize * image.channelCount)
        let totalDetected = stars.count

        // Filter stars: center crop + skip edge, saturated, crowded
        var filtered = filterStars(stars, width: w, height: h, ptr: ptr, channelOffset: channelOffset, useCenterCrop: true)
        // Fallback: if center crop is too strict, retry with full frame
        if filtered.count < minStars {
            filtered = filterStars(stars, width: w, height: h, ptr: ptr, channelOffset: channelOffset, useCenterCrop: false)
        }
        guard filtered.count >= minStars else { return nil }

        let toMeasure = Array(filtered.prefix(maxMeasuredStars))

        var hfrValues: [Double] = []
        var fwhmValues: [Double] = []

        for star in toMeasure {
            let cx = Int(star.x.rounded())
            let cy = Int(star.y.rounded())
            let safeRadius = Int(bgOuterRadius)  // Use largest radius for bounds check

            // Bounds check (must cover background annulus which extends to bgOuterRadius)
            guard cx - safeRadius >= 0, cx + safeRadius < w, cy - safeRadius >= 0, cy + safeRadius < h else { continue }

            // Estimate local background from annulus
            let bg = estimateBackground(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: cx, cy: cy, innerR: bgInnerRadius, outerR: bgOuterRadius
            )

            // Compute HFR
            if let hfr = computeHFR(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: star.x, cy: star.y, radius: apertureRadius, background: bg
            ) {
                // Sanity check: HFR should be reasonable (0.5 - 15 pixels)
                if hfr >= 0.5 && hfr <= 15.0 {
                    hfrValues.append(hfr)
                }
            }

            // Compute FWHM via Gaussian fit
            if let fwhm = computeFWHMGaussian(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: star.x, cy: star.y, radius: apertureRadius, background: bg
            ) {
                // Sanity check: FWHM should be reasonable (1.0 - 20 pixels)
                if fwhm >= 1.0 && fwhm <= 20.0 {
                    fwhmValues.append(fwhm)
                }
            }
        }

        guard hfrValues.count >= minStars, fwhmValues.count >= minStars else { return nil }

        // Use median for robustness against outliers
        hfrValues.sort()
        fwhmValues.sort()

        let medianHFR = hfrValues[hfrValues.count / 2]
        let medianFWHM = fwhmValues[fwhmValues.count / 2]

        return StarMetrics(
            medianHFR: medianHFR,
            medianFWHM: medianFWHM,
            measuredStarCount: totalDetected,
            totalStarCount: totalStarCount ?? totalDetected
        )
    }

    // MARK: - Star Filtering

    /// Filter stars: skip saturated, edge, crowded, and stars outside center crop.
    /// Center crop (70%) excludes stars affected by optical aberrations, vignetting,
    /// dithering shifts, and tilt — giving more consistent quality measurements.
    /// Returns filtered stars sorted by brightness (brightest first).
    private static func filterStars(
        _ stars: [DetectedStar],
        width: Int, height: Int,
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        useCenterCrop: Bool = true
    ) -> [DetectedStar] {
        var result: [DetectedStar] = []

        // Boundary limits
        let minX: Float, maxX: Float, minY: Float, maxY: Float
        if useCenterCrop {
            let cropMarginX = Float(width) * (1.0 - centerCropFraction) * 0.5
            let cropMarginY = Float(height) * (1.0 - centerCropFraction) * 0.5
            minX = max(edgeMargin, cropMarginX)
            maxX = Float(width) - max(edgeMargin, cropMarginX)
            minY = max(edgeMargin, cropMarginY)
            maxY = Float(height) - max(edgeMargin, cropMarginY)
        } else {
            minX = edgeMargin
            maxX = Float(width) - edgeMargin
            minY = edgeMargin
            maxY = Float(height) - edgeMargin
        }

        for star in stars {
            // Skip stars outside boundary region
            if star.x < minX || star.x >= maxX ||
               star.y < minY || star.y >= maxY {
                continue
            }

            // Skip saturated stars: check peak pixel in 3x3 around centroid
            let cx = Int(star.x.rounded())
            let cy = Int(star.y.rounded())
            var isSaturated = false
            for dy in -1...1 {
                for dx in -1...1 {
                    let px = cx + dx
                    let py = cy + dy
                    if px >= 0 && px < width && py >= 0 && py < height {
                        if ptr[channelOffset + py * width + px] > saturationThreshold {
                            isSaturated = true
                            break
                        }
                    }
                }
                if isSaturated { break }
            }
            if isSaturated { continue }

            // Skip crowded: check if any already-accepted brighter star is too close
            let isCrowded = result.contains { accepted in
                let dx = star.x - accepted.x
                let dy = star.y - accepted.y
                return (dx * dx + dy * dy) < crowdingDistance * crowdingDistance
            }
            if isCrowded { continue }

            result.append(star)
        }

        return result
    }

    // MARK: - Background Estimation

    /// Estimate local background as median of pixels in an annulus around the star.
    private static func estimateBackground(
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        width: Int,
        cx: Int, cy: Int,
        innerR: Float, outerR: Float
    ) -> Float {
        var bgValues: [Float] = []
        let r = Int(outerR)

        for dy in -r...r {
            for dx in -r...r {
                let dist = Float(dx * dx + dy * dy).squareRoot()
                if dist >= innerR && dist <= outerR {
                    let px = cx + dx
                    let py = cy + dy
                    bgValues.append(Float(ptr[channelOffset + py * width + px]))
                }
            }
        }

        guard !bgValues.isEmpty else { return 0 }
        bgValues.sort()
        return bgValues[bgValues.count / 2]
    }

    // MARK: - HFR Computation

    /// Compute Half-Flux Radius using cumulative radial flux profile.
    /// HFR = radius enclosing 50% of total star flux.
    private static func computeHFR(
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        width: Int,
        cx: Float, cy: Float,
        radius: Float,
        background: Float
    ) -> Double? {
        // Build cumulative radial flux profile with 0.5px steps
        let steps = Int(radius / 0.5) + 1
        var cumulativeFlux = [Double](repeating: 0, count: steps)
        var totalFlux: Double = 0

        let r = Int(radius)
        let intCx = Int(cx.rounded())
        let intCy = Int(cy.rounded())

        // Collect all pixel fluxes with their distances
        struct PixelFlux {
            let distance: Float
            let flux: Float
        }
        var pixels: [PixelFlux] = []

        for dy in -r...r {
            for dx in -r...r {
                let dist = Float(dx * dx + dy * dy).squareRoot()
                if dist <= radius {
                    let px = intCx + dx
                    let py = intCy + dy
                    let value = Float(ptr[channelOffset + py * width + px]) - background
                    if value > 0 {
                        pixels.append(PixelFlux(distance: dist, flux: value))
                        totalFlux += Double(value)
                    }
                }
            }
        }

        guard totalFlux > 0 else { return nil }

        // Build cumulative profile
        for stepIdx in 0..<steps {
            let stepRadius = Float(stepIdx) * 0.5
            var flux: Double = 0
            for p in pixels {
                if p.distance <= stepRadius {
                    flux += Double(p.flux)
                }
            }
            cumulativeFlux[stepIdx] = flux
        }

        // Find radius where cumulative flux reaches 50% (linear interpolation)
        let halfFlux = totalFlux * 0.5
        for stepIdx in 1..<steps {
            if cumulativeFlux[stepIdx] >= halfFlux {
                let r0 = Float(stepIdx - 1) * 0.5
                let r1 = Float(stepIdx) * 0.5
                let f0 = cumulativeFlux[stepIdx - 1]
                let f1 = cumulativeFlux[stepIdx]
                let fraction = (halfFlux - f0) / (f1 - f0)
                return Double(r0 + Float(fraction) * (r1 - r0))
            }
        }

        return nil
    }

    // MARK: - FWHM Computation (Gaussian Fit)

    /// Compute FWHM via linearized Gaussian fit.
    /// For a Gaussian profile: I(r) = I_peak * exp(-r² / (2σ²))
    /// Taking ln: ln(I) = ln(I_peak) - r² / (2σ²)
    /// This is linear in r² → simple linear regression on (r², ln(I))
    /// gives slope = -1/(2σ²), so σ = sqrt(-1/(2*slope))
    /// FWHM = 2.355 * σ (standard Gaussian relation)
    private static func computeFWHMGaussian(
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        width: Int,
        cx: Float, cy: Float,
        radius: Float,
        background: Float
    ) -> Double? {
        let r = Int(radius)
        let intCx = Int(cx.rounded())
        let intCy = Int(cy.rounded())

        // Find peak value first (background-subtracted)
        var peakValue: Float = 0
        for dy in -2...2 {
            for dx in -2...2 {
                let px = intCx + dx
                let py = intCy + dy
                let val = Float(ptr[channelOffset + py * width + px]) - background
                if val > peakValue { peakValue = val }
            }
        }
        guard peakValue > 100 else { return nil }  // Need reasonable SNR

        // Collect (r², ln(brightness)) pairs for pixels above 10% of peak
        // Only use pixels within a reasonable radius (5px) to avoid background contamination
        let fitRadius = min(radius, 5.0)
        let fitRadiusSq = fitRadius * fitRadius
        let threshold = peakValue * 0.1

        var sumR2: Double = 0
        var sumLnI: Double = 0
        var sumR2LnI: Double = 0
        var sumR2R2: Double = 0
        var count = 0

        let fitR = Int(fitRadius)
        for dy in -fitR...fitR {
            for dx in -fitR...fitR {
                let distSq = Float(dx * dx + dy * dy)
                if distSq > fitRadiusSq { continue }

                let px = intCx + dx
                let py = intCy + dy
                let val = Float(ptr[channelOffset + py * width + px]) - background

                // Only include pixels well above background and below saturation
                if val > threshold && val < peakValue * 1.1 {
                    let r2 = Double(distSq)
                    let lnI = log(Double(val))

                    sumR2 += r2
                    sumLnI += lnI
                    sumR2LnI += r2 * lnI
                    sumR2R2 += r2 * r2
                    count += 1
                }
            }
        }

        guard count >= minFitPixels else { return nil }

        // Linear regression: lnI = a + b * r²
        // b = (n * Σ(r²·lnI) - Σr² · ΣlnI) / (n * Σ(r²²) - (Σr²)²)
        let n = Double(count)
        let denominator = n * sumR2R2 - sumR2 * sumR2
        guard Swift.abs(denominator) > 1e-10 else { return nil }

        let slope = (n * sumR2LnI - sumR2 * sumLnI) / denominator

        // slope = -1/(2σ²), so σ² = -1/(2*slope)
        guard slope < -1e-6 else { return nil }  // Must be negative (Gaussian falls off)
        let sigmaSq = -1.0 / (2.0 * slope)
        let sigma = sigmaSq.squareRoot()

        // FWHM = 2 * sqrt(2 * ln(2)) * σ ≈ 2.3548 * σ
        let fwhm = 2.3548 * sigma

        return fwhm
    }
}
