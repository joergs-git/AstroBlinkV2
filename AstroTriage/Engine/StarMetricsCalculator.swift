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
    // Fraction of stars participating in parallel close-neighbor chains [0..1].
    // Tracking hops create chains of discrete dots — each dot looks round,
    // but the spatial pattern (many parallel short chains) is unmistakable.
    let starChainFraction: Double
    // Number of detections initially flagged by RANSAC trail detection (0 = no trail found).
    // Used for diagnostics — helps identify false positive trail detections.
    let trailCandidateCount: Int
    // Number of detections confirmed as trail after axis ratio verification (0 = false positive or no trail).
    let trailRejectCount: Int
    // PSF Signal Weight components (PixInsight 1.8.9+ compatibility)
    // psfFluxSum: estimated total PSF flux = Σ(brightness × π × (FWHM/2)²) for measured stars,
    //   scaled by totalCount/measuredCount to estimate full-image flux
    // psfMeanFlux: mean PSF flux per star (proxy for resolution/seeing quality)
    let psfFluxSum: Double
    let psfMeanFlux: Double
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
    // Center crop fraction for HFR/FWHM measurement (strict — avoid edge aberrations)
    private static let centerCropFraction: Float = 0.70
    // Wider crop for shape/eccentricity measurement and compare overlay (5% margin)
    // Trailing consensus handles edge aberrations via PA analysis, so wider coverage is safe
    private static let shapeCropFraction: Float = 0.90
    // Gaussian fit: minimum pixels above background required for valid fit
    private static let minFitPixels = 8
    // Minimum eccentricity aperture (pixels) — ensures measurement even for tiny stars
    private static let minEccAperture: Float = 5.0
    // Maximum eccentricity aperture (pixels) — prevents measuring too far into background
    private static let maxEccAperture: Float = 15.0
    // FWHM multiplier for adaptive eccentricity aperture
    private static let eccApertureFWHMMultiplier: Float = 2.5
    // Axis ratio below which a detection is classified as a satellite/plane streak artifact.
    // Real stars — even with severe tracking errors — have axisRatio > 0.15.
    // Satellite and airplane trails are essentially linear (axisRatio < 0.05).
    // Threshold 0.12 aggressively rejects streaks without mis-rejecting tracked stars.
    private static let streakAxisRatioThreshold: Double = 0.12
    // Fixed aperture for quick pre-filter shape check (before FWHM-adaptive aperture is known)
    private static let preFilterAperture: Float = 5.0

    /// Measure HFR, FWHM, and eccentricity from detected star positions.
    /// Two-pass approach:
    ///   Pass 1: Compute FWHM for all stars (used to determine adaptive eccentricity aperture)
    ///   Pass 2: Compute eccentricity with FWHM-scaled aperture + extract PA and axis ratio
    /// When generator is provided, GPU PSF fitting replaces CPU FWHM/flux computation.
    static func measure(
        stars: [DetectedStar],
        fullResImage image: DecodedImage,
        channel: Int = 0,
        totalStarCount: Int? = nil,
        generator: PreviewGenerator? = nil
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

        // ── Pass 0: Satellite/airplane trail detection via collinear point pattern ──
        // Detect and remove detections that lie along a straight line (satellite/plane trail).
        // Uses RANSAC-style line detection on ALL refined star positions (before center crop).
        // This catches trails regardless of where they cross the image.
        let trailIndices = detectSatelliteTrail(stars: refinedStars, width: w, height: h)
        var trailPositions = Set<Int>()  // indices into refinedStars
        var streakRejectCount = trailIndices.count

        // Verify trail candidates: real satellite trails have streak-like axis ratios (< 0.3).
        // Galaxy knots, HII regions, and normal stars along coincidental lines have normal
        // axis ratios (> 0.3). Without this check, extended objects like edge-on galaxies
        // (M82, NGC 4565, NGC 891) cause false positive trail detections.
        if !trailIndices.isEmpty {
            var streakLikeCount = 0
            var measuredCount = 0
            for idx in trailIndices {
                let star = refinedStars[idx]
                let cx = Int(star.x.rounded())
                let cy = Int(star.y.rounded())
                let safeR = Int(preFilterAperture + bgOuterRadius)
                guard cx - safeR >= 0, cx + safeR < w,
                      cy - safeR >= 0, cy + safeR < h else { continue }
                let bg = estimateBackground(
                    ptr: ptr, channelOffset: channelOffset, width: w,
                    cx: cx, cy: cy, innerR: bgInnerRadius, outerR: bgOuterRadius
                )
                if let shape = computeShape(
                    ptr: ptr, channelOffset: channelOffset, width: w,
                    cx: star.x, cy: star.y, aperture: preFilterAperture, background: bg
                ) {
                    measuredCount += 1
                    // Streak-like = very elongated (low axis ratio < 0.3)
                    // Real satellite trails: axis ratio typically < 0.1
                    // Normal/trailed stars: axis ratio > 0.3
                    if shape.axisRatio < 0.3 { streakLikeCount += 1 }
                }
            }
            // If fewer than 30% of measurable trail candidates look like actual streaks,
            // reject the entire trail detection as a false positive
            if measuredCount >= 3 && Double(streakLikeCount) / Double(measuredCount) < 0.3 {
                streakRejectCount = 0
                // trailPositions stays empty — don't remove any stars
            } else {
                for idx in trailIndices { trailPositions.insert(idx) }
            }
        }

        // Filter stars: center crop + skip edge, saturated (strict for HFR/FWHM), crowded
        // Exclude trail detections from the filtered set
        let refinedClean: [DetectedStar]
        if !trailPositions.isEmpty {
            refinedClean = refinedStars.enumerated().compactMap { trailPositions.contains($0.offset) ? nil : $0.element }
        } else {
            refinedClean = refinedStars
        }

        var filtered = filterStars(refinedClean, width: w, height: h, ptr: ptr, channelOffset: channelOffset, useCenterCrop: true)
        if filtered.count < minStars {
            filtered = filterStars(refinedClean, width: w, height: h, ptr: ptr, channelOffset: channelOffset, useCenterCrop: false)
        }
        guard filtered.count >= minStars else { return nil }

        let toMeasure = Array(filtered.prefix(maxMeasuredStars))

        // ── Pass 1: Compute HFR and FWHM (on streak-filtered stars only) ──
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

        // ── GPU PSF Fitting (when available) ──
        // Replaces CPU linearized FWHM with proper Gauss-Newton fitted σ.
        // Also produces fitted amplitude for accurate flux computation.
        var gpuFitResults: [PreviewGenerator.PSFFitResult]?
        if let gen = generator {
            let fitInput = toMeasure.enumerated().map { (i, star) -> (x: Float, y: Float, background: Float, peakBrightness: Float) in
                let bg = estimateBackground(ptr: ptr, channelOffset: channelOffset, width: w,
                                            cx: Int(star.x.rounded()), cy: Int(star.y.rounded()),
                                            innerR: bgInnerRadius, outerR: bgOuterRadius)
                return (x: star.x, y: star.y, background: bg, peakBrightness: star.brightness)
            }
            let results = gen.fitPSF(image: image, stars: fitInput, channel: channel)
            if results.count == toMeasure.count {
                gpuFitResults = results
                // Replace CPU FWHM with GPU-fitted FWHM for stars with good fit (χ² < 1000)
                fwhmValues.removeAll()
                for (i, fit) in results.enumerated() {
                    let fittedFWHM = Double(fit.sigma) * 2.3548
                    if fit.chi2 < 1000 && fittedFWHM >= 1.0 && fittedFWHM <= 20.0 {
                        fwhmValues.append(fittedFWHM)
                        perStarFWHM[i] = fittedFWHM
                    }
                }
            }
        }

        hfrValues.sort()
        fwhmValues.sort()
        guard fwhmValues.count >= minStars else { return nil }
        let medianHFR = hfrValues[hfrValues.count / 2]
        let medianFWHM = fwhmValues[fwhmValues.count / 2]

        // ── Star chain detection: tracking hop pattern (parallel short chains) ──
        // Must run after Pass 1 (needs medianFWHM) and on all refined stars (before crowding filter).
        let chainFraction = detectStarChains(stars: refinedClean, medianFWHM: medianFWHM)

        // ── Pass 2: Compute eccentricity with FWHM-adaptive aperture ──
        // Use median FWHM to determine a consistent aperture across all stars in this image.
        // This captures the full PSF wings where trailing is visible.
        let eccAperture = min(maxEccAperture, max(minEccAperture, Float(medianFWHM) * eccApertureFWHMMultiplier))

        var eccValues: [Double] = []
        var details: [StarDetail] = []

        // Use wider crop for shape/eccentricity, but pre-filter streaks here too
        let shapeStars = filterStarsForShape(refinedStars, width: w, height: h, ptr: ptr, channelOffset: channelOffset)
        let shapeCandidates = Array(shapeStars.prefix(maxMeasuredStars))

        for star in shapeCandidates {
            let cx = Int(star.x.rounded())
            let cy = Int(star.y.rounded())
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
                // Reject streaks again with the FWHM-adaptive aperture (more accurate than Pass 0)
                if shape.axisRatio < streakAxisRatioThreshold { continue }

                eccValues.append(shape.eccentricity)

                // Look up HFR/FWHM from Pass 1 by position match
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

        // Correct total star count for verified satellite/plane trail contamination.
        // Subtract only the confirmed trail detections from the raw count. This preserves
        // comparability with frames that have no trail detection (both use full-image counts).
        // The previous approach of replacing with filtered.count (center-crop-only) caused
        // false "zero/near-zero stars" garbage on frames with false positive trail detection,
        // because filtered.count (~15% of rawTotal) is not comparable to rawTotal.
        // For real trails: count may be slightly elevated, but trailing/eccentricity rules
        // handle the actual quality issue. Elevated count alone won't trigger garbage.
        let rawTotal = totalStarCount ?? totalDetected
        let correctedTotal: Int
        if streakRejectCount > 0 {
            correctedTotal = max(filtered.count, rawTotal - streakRejectCount)
        } else {
            correctedTotal = rawTotal
        }

        // PSF flux estimation: use GPU-fitted amplitude when available,
        // else approximate from peak brightness. Flux = 2π × A × σ².
        var measuredFluxSum: Double = 0
        var fluxStarCount = 0
        for (i, star) in toMeasure.enumerated() {
            let fwhm = perStarFWHM[i] ?? medianFWHM
            if fwhm > 0 {
                // Use GPU-fitted amplitude for accurate flux when available
                let amplitude: Double
                if let fits = gpuFitResults, i < fits.count, fits[i].chi2 < 1000 {
                    amplitude = Double(fits[i].amplitude)
                } else {
                    amplitude = Double(star.brightness)
                }
                let sigma = fwhm / 2.355
                let flux = amplitude * 2.0 * Double.pi * sigma * sigma
                measuredFluxSum += flux
                fluxStarCount += 1
            }
        }
        // Scale up to full image: measured stars are a subset (center crop + filtering)
        let scaleFactor = fluxStarCount > 0 ? Double(correctedTotal) / Double(fluxStarCount) : 1.0
        let totalPsfFlux = measuredFluxSum * scaleFactor
        let meanPsfFlux = fluxStarCount > 0 ? measuredFluxSum / Double(fluxStarCount) : 0

        return StarMetrics(
            medianHFR: medianHFR,
            medianFWHM: medianFWHM,
            measuredStarCount: totalDetected,
            totalStarCount: correctedTotal,
            medianEccentricity: medianEcc,
            starDetails: details,
            starChainFraction: chainFraction,
            trailCandidateCount: trailIndices.count,
            trailRejectCount: streakRejectCount,
            psfFluxSum: totalPsfFlux,
            psfMeanFlux: meanPsfFlux
        )
    }

    // MARK: - Star Chain Detection (tracking hop pattern)

    /// Detect tracking hop pattern: many stars have close neighbors aligned in parallel directions.
    /// When a mount has periodic error or loses tracking briefly, each real star becomes a chain
    /// of 3-10 discrete dots. Each dot looks like a real star (round, good FWHM), but the spatial
    /// pattern — many parallel short chains scattered across the frame — is unmistakable.
    ///
    /// Algorithm: find ALL close pairs (not just nearest neighbor), compute connecting directions,
    /// and check for directional consensus. In normal images, close pairs are rare and have random
    /// directions. In tracking-hop images, many close pairs exist and all point the same way.
    ///
    /// Returns the fraction of stars participating in consensus-direction close pairs [0..1].
    /// Values > 0.25 indicate tracking hops. Values near 0 indicate normal star field.
    private static func detectStarChains(
        stars: [DetectedStar], medianFWHM: Double
    ) -> Double {
        let n = stars.count
        guard n >= 10 else { return 0 }

        // Close neighbor threshold: mount PE at 2455mm FL with 3.76µm pixels
        // creates gaps of 30-100+ pixels between chain dots. Use generous threshold
        // to catch various PE magnitudes. Normal star-to-star distances in a 50-star
        // field of 9576x6388 average ~1100px, so 120px is still highly discriminating.
        let closeThreshold = max(80.0, Float(medianFWHM) * 12.0)
        let closeThresholdSq = closeThreshold * closeThreshold

        // PA tolerance for consensus: close pairs within this range count as "agreeing"
        let consensusToleranceDeg = 25.0

        // Find ALL close pairs (not just nearest neighbor) — captures more chain evidence.
        // Each star can have multiple close neighbors from the same or different chains.
        // Dedup by only recording pairs where i < j to avoid double-counting.
        struct ClosePair {
            let starIdxA: Int
            let starIdxB: Int
            let pa: Double         // Position angle of connecting vector [0..180°)
        }
        var closePairs: [ClosePair] = []

        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = stars[j].x - stars[i].x
                let dy = stars[j].y - stars[i].y
                let distSq = dx * dx + dy * dy
                if distSq < closeThresholdSq && distSq > 4.0 {  // Min 2px apart (not same detection)
                    var pa = atan2(Double(dy), Double(dx)) * 180.0 / .pi
                    if pa < 0 { pa += 180.0 }
                    if pa >= 180.0 { pa -= 180.0 }
                    closePairs.append(ClosePair(starIdxA: i, starIdxB: j, pa: pa))
                }
            }
        }

        guard closePairs.count >= 3 else { return 0 }

        // Circular statistics on close-pair PAs (doubled-angle method, same as TrailingAnalyzer)
        let doubled = closePairs.map { $0.pa * 2.0 * .pi / 180.0 }
        let sumSin = doubled.map { sin($0) }.reduce(0, +)
        let sumCos = doubled.map { cos($0) }.reduce(0, +)
        let count = Double(doubled.count)

        // Resultant vector length R: 0 = random PAs, 1 = all same direction
        let R = ((sumSin * sumSin + sumCos * sumCos).squareRoot()) / count

        // Require minimum consensus strength — random close pairs in dense fields
        // will have low R. Threshold 0.35 is lenient enough for partial chain visibility.
        guard R > 0.35 else { return 0 }

        // Compute circular mean PA
        var meanDoubled = atan2(sumSin / count, sumCos / count)
        if meanDoubled < 0 { meanDoubled += 2.0 * .pi }
        let consensusPA = meanDoubled * 0.5 * 180.0 / .pi

        // Count stars that participate in consensus-direction close pairs
        var consensusStarIndices = Set<Int>()
        for pair in closePairs {
            let d = Swift.abs(pair.pa - consensusPA)
            let diff = min(d, 180.0 - d)
            if diff < consensusToleranceDeg {
                consensusStarIndices.insert(pair.starIdxA)
                consensusStarIndices.insert(pair.starIdxB)
            }
        }

        let chainFraction = Double(consensusStarIndices.count) / Double(n)

        // Also require that a significant fraction of close pairs agree
        let agreeingPairs = closePairs.filter { pair in
            let d = Swift.abs(pair.pa - consensusPA)
            return min(d, 180.0 - d) < consensusToleranceDeg
        }.count
        let pairConsensusFraction = Double(agreeingPairs) / Double(closePairs.count)

        // Both conditions must hold: many stars in chains AND strong directional consensus
        // Lower pairConsensus threshold (0.3) because with all-pairs approach, there are
        // more cross-chain pairs that don't align but are still within threshold distance
        guard pairConsensusFraction > 0.3 else { return 0 }

        return chainFraction
    }

    // MARK: - Satellite Trail Detection (collinear point pattern)

    /// Detect satellite/airplane trail by finding collinear star detections.
    /// Returns indices of stars that lie on a detected trail line.
    /// Algorithm: RANSAC-style — sample random pairs, count inliers within tolerance,
    /// keep the best line. If it has enough inliers (>= 8), those are trail detections.
    private static func detectSatelliteTrail(
        stars: [DetectedStar], width: Int, height: Int
    ) -> [Int] {
        let n = stars.count
        guard n >= 10 else { return [] }

        // Distance tolerance: a detection within this many pixels of the line is an inlier.
        // Satellite trails are typically 2-5px wide; use 5px for some margin.
        let tolerance: Float = 5.0
        // Minimum inliers to confirm a trail (8 points on a line can't be coincidence)
        let minInliers = 8
        // Number of RANSAC iterations — sample pairs and test
        let maxIterations = min(200, n * (n - 1) / 2)

        var bestInliers: [Int] = []

        // Deterministic sampling: test pairs spread across the star list
        var iteration = 0
        let step = max(1, n / 15)  // Sample ~15 anchor points

        for i in stride(from: 0, to: n, by: step) {
            for j in (i + 1)..<n {
                guard iteration < maxIterations else { break }
                iteration += 1

                let dx = stars[j].x - stars[i].x
                let dy = stars[j].y - stars[i].y
                let len = (dx * dx + dy * dy).squareRoot()
                guard len > 20 else { continue }  // Skip pairs too close together

                // Line normal (perpendicular direction)
                let nx = -dy / len
                let ny = dx / len

                // Count inliers: stars within `tolerance` of the line through i and j
                var inliers: [Int] = []
                for k in 0..<n {
                    let ex = stars[k].x - stars[i].x
                    let ey = stars[k].y - stars[i].y
                    let dist = Swift.abs(ex * nx + ey * ny)
                    if dist < tolerance {
                        inliers.append(k)
                    }
                }

                if inliers.count > bestInliers.count {
                    bestInliers = inliers
                }
            }
            guard iteration < maxIterations else { break }
        }

        // Only flag as trail if enough collinear points found
        guard bestInliers.count >= minInliers else { return [] }

        // Verify the trail spans a significant portion of the image (not just a cluster)
        let trailStars = bestInliers.map { stars[$0] }
        let minX = trailStars.map(\.x).min()!
        let maxX = trailStars.map(\.x).max()!
        let minY = trailStars.map(\.y).min()!
        let maxY = trailStars.map(\.y).max()!
        let span = ((maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY)).squareRoot()
        let imageSize = (Float(width * width + height * height)).squareRoot()

        // Trail must span at least 15% of image diagonal
        guard span > imageSize * 0.15 else { return [] }

        return bestInliers
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
        // Use wider crop (90%) for shape measurement — trailing consensus handles edge aberrations
        var result = filterStarsImpl(stars, width: width, height: height, ptr: ptr, channelOffset: channelOffset,
                                     useCenterCrop: true, satThreshold: shapeSaturationThreshold,
                                     cropFraction: shapeCropFraction)
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
        satThreshold: UInt16,
        cropFraction: Float = centerCropFraction
    ) -> [DetectedStar] {
        var result: [DetectedStar] = []

        let minX: Float, maxX: Float, minY: Float, maxY: Float
        if useCenterCrop {
            let cropMarginX = Float(width) * (1.0 - cropFraction) * 0.5
            let cropMarginY = Float(height) * (1.0 - cropFraction) * 0.5
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
