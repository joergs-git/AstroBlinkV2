// v4.2.0 — Computed HFR, FWHM, Eccentricity + Trailing Detection from detected star positions
// Measures Half-Flux Radius and Full Width at Half Maximum for quality scoring.
// Eccentricity uses ADAPTIVE aperture (FWHM-scaled) to capture star wings/trails.
// Extracts position angle (PA) and axis ratio for orientation consensus analysis.
// Operates on full-resolution uint16 data using small patches around each star.
// FWHM uses linearized Gaussian fit (ln(brightness) vs dist² → sigma → 2.355σ).
// Values are for *relative comparison within a session*, not absolute calibration.

import Foundation
import Metal

// Per-image star metrics: median HFR, FWHM, eccentricity, and star count
struct StarMetrics {
    let medianHFR: Double       // Half-flux radius in pixels (median of measured stars)
    let medianFWHM: Double      // Full width at half maximum in pixels
    let measuredStarCount: Int  // Stars used for HFR/FWHM measurement (capped subset)
    let totalStarCount: Int     // True total number of stars detected in the image
    let medianEccentricity: Double?  // Median star eccentricity [0..1], nil if < 5 measured
    // Per-star details for problem visualization and trailing consensus analysis
    let starDetails: [StarDetail]
}

// Result of 2D moment analysis on a single star: eccentricity + position angle + axis ratio
private struct ShapeResult {
    let eccentricity: Double   // [0..1], 0 = round
    let positionAngle: Double  // PA of major axis in degrees [0..180)
    let axisRatio: Double      // minor/major eigenvalue ratio [0..1], 1 = round
}

enum StarMetricsCalculator {

    // Aperture radius for HFR/FWHM measurement (pixels around centroid)
    private static let apertureRadius: Float = 10.0
    // Annulus for local background estimation
    private static let bgInnerRadius: Float = 12.0
    private static let bgOuterRadius: Float = 15.0
    // Minimum number of qualifying stars to produce a result
    private static let minStars = 2
    // Maximum stars to measure (increased from 30 to 60 for better trailing consensus)
    private static let maxMeasuredStars = 60
    // Saturation threshold for HFR/FWHM (98% — saturated cores corrupt Gaussian fits)
    private static let saturationThreshold: UInt16 = 64224
    // Relaxed saturation threshold for shape measurement only (99.5% — include bright stars)
    // Bright stars show trailing most visibly; the annular measurement skips the saturated core
    private static let shapeSaturationThreshold: UInt16 = 65207
    // Minimum distance between stars to avoid crowding (reduced from 15 to 10 for more candidates)
    private static let crowdingDistance: Float = 10.0
    // Minimum distance from image edge (full-res pixels)
    private static let edgeMargin: Float = 12.0
    // Center crop fraction for quality measurement
    private static let centerCropFraction: Float = 0.70
    // Gaussian fit: minimum pixels above background required for valid fit
    private static let minFitPixels = 8
    // Minimum eccentricity aperture (pixels) — ensures measurement even for tiny stars
    private static let minEccAperture: Float = 5.0
    // Maximum eccentricity aperture (pixels) — prevents measuring too far into background
    private static let maxEccAperture: Float = 15.0
    // FWHM multiplier for adaptive eccentricity aperture
    private static let eccApertureFWHMMultiplier: Float = 2.5

    /// Measure HFR, FWHM, and eccentricity from detected star positions.
    /// Two-pass approach:
    ///   Pass 1: Compute FWHM for all stars (used to determine adaptive eccentricity aperture)
    ///   Pass 2: Compute eccentricity with FWHM-scaled aperture + extract PA and axis ratio
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

        // Refine star positions to full-res sub-pixel accuracy (currently GPS returns bin2x coords)
        let refinedStars = StarDetector.refinePositions(stars: stars, in: image, channel: channel)

        // Filter stars: center crop + skip edge, saturated (strict for HFR/FWHM), crowded
        var filtered = filterStars(refinedStars, width: w, height: h, ptr: ptr, channelOffset: channelOffset, useCenterCrop: true)
        if filtered.count < minStars {
            filtered = filterStars(refinedStars, width: w, height: h, ptr: ptr, channelOffset: channelOffset, useCenterCrop: false)
        }
        guard filtered.count >= minStars else { return nil }

        let toMeasure = Array(filtered.prefix(maxMeasuredStars))

        // ── Pass 1: Compute HFR and FWHM ──
        var hfrValues: [Double] = []
        var fwhmValues: [Double] = []
        // Per-star FWHM for adaptive aperture (parallel arrays with toMeasure)
        var perStarFWHM: [Double?] = Array(repeating: nil, count: toMeasure.count)
        var perStarHFR: [Double?] = Array(repeating: nil, count: toMeasure.count)

        for (i, star) in toMeasure.enumerated() {
            let cx = Int(star.x.rounded())
            let cy = Int(star.y.rounded())
            let safeRadius = Int(bgOuterRadius)
            guard cx - safeRadius >= 0, cx + safeRadius < w, cy - safeRadius >= 0, cy + safeRadius < h else { continue }

            let bg = estimateBackground(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: cx, cy: cy, innerR: bgInnerRadius, outerR: bgOuterRadius
            )

            if let hfr = computeHFR(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: star.x, cy: star.y, radius: apertureRadius, background: bg
            ), hfr >= 0.5 && hfr <= 15.0 {
                hfrValues.append(hfr)
                perStarHFR[i] = hfr
            }

            if let fwhm = computeFWHMGaussian(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: star.x, cy: star.y, radius: apertureRadius, background: bg
            ), fwhm >= 1.0 && fwhm <= 20.0 {
                fwhmValues.append(fwhm)
                perStarFWHM[i] = fwhm
            }
        }

        guard hfrValues.count >= minStars, fwhmValues.count >= minStars else { return nil }

        hfrValues.sort()
        fwhmValues.sort()
        let medianHFR = hfrValues[hfrValues.count / 2]
        let medianFWHM = fwhmValues[fwhmValues.count / 2]

        // ── Pass 2: Compute eccentricity with FWHM-adaptive aperture ──
        // Use median FWHM to determine a consistent aperture across all stars in this image.
        // This captures the full PSF wings where trailing is visible.
        let eccAperture = min(maxEccAperture, max(minEccAperture, Float(medianFWHM) * eccApertureFWHMMultiplier))

        var eccValues: [Double] = []
        var details: [StarDetail] = []

        // Also measure bright stars that were excluded from HFR/FWHM (for shape analysis only)
        let shapeStars = filterStarsForShape(refinedStars, width: w, height: h, ptr: ptr, channelOffset: channelOffset)
        let shapeCandidates = Array(shapeStars.prefix(maxMeasuredStars))

        for star in shapeCandidates {
            let cx = Int(star.x.rounded())
            let cy = Int(star.y.rounded())
            // Need enough room for the adaptive aperture + background annulus
            let safeR = Int(max(bgOuterRadius, eccAperture + 2))
            guard cx - safeR >= 0, cx + safeR < w, cy - safeR >= 0, cy + safeR < h else { continue }

            let bg = estimateBackground(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: cx, cy: cy, innerR: bgInnerRadius, outerR: bgOuterRadius
            )

            if let shape = computeShape(
                ptr: ptr, channelOffset: channelOffset, width: w,
                cx: star.x, cy: star.y, aperture: eccAperture, background: bg
            ) {
                eccValues.append(shape.eccentricity)

                // Find this star's HFR/FWHM from Pass 1 (if it was in toMeasure)
                let starHFR = perStarHFR.first(where: { $0 != nil }) as? Double
                let starFWHM = perStarFWHM.first(where: { $0 != nil }) as? Double
                // Look up by position match
                var matchedHFR: Double? = nil
                var matchedFWHM: Double? = nil
                for (j, m) in toMeasure.enumerated() {
                    if abs(m.x - star.x) < 2 && abs(m.y - star.y) < 2 {
                        matchedHFR = perStarHFR[j]
                        matchedFWHM = perStarFWHM[j]
                        break
                    }
                }

                details.append(StarDetail(
                    x: star.x, y: star.y,
                    eccentricity: shape.eccentricity,
                    hfr: matchedHFR, fwhm: matchedFWHM,
                    positionAngle: shape.positionAngle,
                    axisRatio: shape.axisRatio
                ))
            }
        }

        // Eccentricity: 3 stars minimum for reliable median
        let medianEcc: Double?
        if eccValues.count >= 3 {
            eccValues.sort()
            medianEcc = eccValues[eccValues.count / 2]
        } else {
            medianEcc = nil
        }

        return StarMetrics(
            medianHFR: medianHFR,
            medianFWHM: medianFWHM,
            measuredStarCount: totalDetected,
            totalStarCount: totalStarCount ?? totalDetected,
            medianEccentricity: medianEcc,
            starDetails: details
        )
    }

    // MARK: - Star Filtering (strict — for HFR/FWHM measurement)

    private static func filterStars(
        _ stars: [DetectedStar],
        width: Int, height: Int,
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        useCenterCrop: Bool = true
    ) -> [DetectedStar] {
        return filterStarsImpl(stars, width: width, height: height, ptr: ptr, channelOffset: channelOffset,
                               useCenterCrop: useCenterCrop, satThreshold: saturationThreshold)
    }

    // MARK: - Star Filtering (relaxed — for shape/eccentricity measurement)
    // Includes brighter stars (higher saturation threshold) because trailing is most
    // visible in bright stars. The shape measurement skips the saturated core.

    private static func filterStarsForShape(
        _ stars: [DetectedStar],
        width: Int, height: Int,
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int
    ) -> [DetectedStar] {
        // Try center crop first, fall back to full frame
        var result = filterStarsImpl(stars, width: width, height: height, ptr: ptr, channelOffset: channelOffset,
                                     useCenterCrop: true, satThreshold: shapeSaturationThreshold)
        if result.count < minStars {
            result = filterStarsImpl(stars, width: width, height: height, ptr: ptr, channelOffset: channelOffset,
                                     useCenterCrop: false, satThreshold: shapeSaturationThreshold)
        }
        return result
    }

    private static func filterStarsImpl(
        _ stars: [DetectedStar],
        width: Int, height: Int,
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        useCenterCrop: Bool,
        satThreshold: UInt16
    ) -> [DetectedStar] {
        var result: [DetectedStar] = []

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
            if star.x < minX || star.x >= maxX || star.y < minY || star.y >= maxY { continue }

            // Check saturation using the provided threshold
            let cx = Int(star.x.rounded())
            let cy = Int(star.y.rounded())
            var isSaturated = false
            for dy in -1...1 {
                for dx in -1...1 {
                    let px = cx + dx
                    let py = cy + dy
                    if px >= 0 && px < width && py >= 0 && py < height {
                        if ptr[channelOffset + py * width + px] > satThreshold {
                            isSaturated = true
                            break
                        }
                    }
                }
                if isSaturated { break }
            }
            if isSaturated { continue }

            // Crowding check
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

    private static func computeHFR(
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        width: Int,
        cx: Float, cy: Float,
        radius: Float,
        background: Float
    ) -> Double? {
        let steps = Int(radius / 0.5) + 1
        var cumulativeFlux = [Double](repeating: 0, count: steps)
        var totalFlux: Double = 0

        let r = Int(radius)
        let intCx = Int(cx.rounded())
        let intCy = Int(cy.rounded())

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

    private static func computeFWHMGaussian(
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        width: Int,
        cx: Float, cy: Float,
        radius: Float,
        background: Float
    ) -> Double? {
        let intCx = Int(cx.rounded())
        let intCy = Int(cy.rounded())

        var peakValue: Float = 0
        for dy in -2...2 {
            for dx in -2...2 {
                let px = intCx + dx
                let py = intCy + dy
                let val = Float(ptr[channelOffset + py * width + px]) - background
                if val > peakValue { peakValue = val }
            }
        }
        guard peakValue > 100 else { return nil }

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

        let n = Double(count)
        let denominator = n * sumR2R2 - sumR2 * sumR2
        guard Swift.abs(denominator) > 1e-10 else { return nil }

        let slope = (n * sumR2LnI - sumR2 * sumLnI) / denominator
        guard slope < -1e-6 else { return nil }
        let sigmaSq = -1.0 / (2.0 * slope)
        let sigma = sigmaSq.squareRoot()
        let fwhm = 2.3548 * sigma

        return fwhm
    }

    // MARK: - Shape Analysis (Eccentricity + PA + Axis Ratio)

    /// Compute star shape using weighted second-order image moments with ADAPTIVE aperture.
    /// Uses annular measurement for bright stars: skips the potentially saturated core (inner 3px),
    /// measures the wings where trailing is most visible.
    ///
    /// Returns eccentricity, position angle of major axis, and minor/major axis ratio.
    /// PA uses the standard convention: 0° = horizontal, 90° = vertical, range [0..180).
    private static func computeShape(
        ptr: UnsafeMutablePointer<UInt16>,
        channelOffset: Int,
        width: Int,
        cx: Float, cy: Float,
        aperture: Float,
        background: Float
    ) -> ShapeResult? {
        let intCx = Int(cx.rounded())
        let intCy = Int(cy.rounded())
        let fitRadiusSq = aperture * aperture
        let fitR = Int(aperture)

        // Find peak value for threshold
        var peakValue: Float = 0
        for dy in -2...2 {
            for dx in -2...2 {
                let px = intCx + dx
                let py = intCy + dy
                let val = Float(ptr[channelOffset + py * width + px]) - background
                if val > peakValue { peakValue = val }
            }
        }
        guard peakValue > 30 else { return nil }  // Lower SNR threshold than before (was 50)

        // Use 5% of peak as threshold (was 10%) to capture more of the PSF wings
        let threshold = peakValue * 0.05

        // For bright stars near saturation: skip the inner 3px core (may be saturated)
        // and measure shape from the wings only. This captures trailing better.
        let isBright = peakValue > Float(saturationThreshold - 5000)  // Within 8% of saturation
        let innerSkipRadius: Float = isBright ? 3.0 : 0.0
        let innerSkipRadiusSq = innerSkipRadius * innerSkipRadius

        // Weighted second-order moments
        var sumI: Double = 0
        var sumIxx: Double = 0
        var sumIyy: Double = 0
        var sumIxy: Double = 0

        for dy in -fitR...fitR {
            for dx in -fitR...fitR {
                let distSq = Float(dx * dx + dy * dy)
                if distSq > fitRadiusSq { continue }
                if distSq < innerSkipRadiusSq { continue }  // Skip saturated core for bright stars

                let px = intCx + dx
                let py = intCy + dy
                let val = Float(ptr[channelOffset + py * width + px]) - background

                if val > threshold {
                    let intensity = Double(val)
                    let ddx = Double(dx)
                    let ddy = Double(dy)

                    sumI += intensity
                    sumIxx += intensity * ddx * ddx
                    sumIyy += intensity * ddy * ddy
                    sumIxy += intensity * ddx * ddy
                }
            }
        }

        guard sumI > 0 else { return nil }

        let mxx = sumIxx / sumI
        let myy = sumIyy / sumI
        let mxy = sumIxy / sumI

        let trace = mxx + myy
        let det = mxx * myy - mxy * mxy

        guard det > 0, trace > 0 else { return nil }

        let discriminant = trace * trace - 4.0 * det
        guard discriminant >= 0 else { return nil }

        let sqrtDisc = discriminant.squareRoot()
        let lambda1 = (trace + sqrtDisc) * 0.5  // Semi-major² (larger eigenvalue)
        let lambda2 = (trace - sqrtDisc) * 0.5  // Semi-minor² (smaller eigenvalue)

        guard lambda1 > 0, lambda2 >= 0 else { return nil }

        // Eccentricity = sqrt(1 - b²/a²)
        let axisRatio = (lambda2 / lambda1).squareRoot()  // b/a, 1 = round
        let eccentricity = (1.0 - lambda2 / lambda1).squareRoot()

        guard eccentricity >= 0, eccentricity < 1.0 else { return nil }

        // Position angle of major axis: angle of eigenvector for lambda1
        // PA = 0.5 * atan2(2*mxy, mxx - myy), normalized to [0..180)
        var pa = atan2(2.0 * mxy, mxx - myy) * 0.5 * (180.0 / .pi)
        if pa < 0 { pa += 180.0 }
        if pa >= 180.0 { pa -= 180.0 }

        return ShapeResult(
            eccentricity: eccentricity,
            positionAngle: pa,
            axisRatio: axisRatio
        )
    }
}
