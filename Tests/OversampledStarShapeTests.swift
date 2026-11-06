// v6.11.3 (algo v44) — Round, oversampled stars must be measured as stars.
//
// Regression gate for the point-source concentration test in
// `StarMetricsCalculator.computeShape`.
//
// Background: the test "peak >= 2 x mean inside the aperture" ran on a FIXED 5 px radius.
// For a Gaussian that ratio depends only on radius / FWHM and falls below 2.0 once FWHM
// exceeds 6.6 px, so every real star of an oversampled frame in ordinary seeing (3" at
// 0.395"/px = 7.6 px on the RC12) was discarded as "nebulosity", while the gradient rescue
// for bloated stars only opens at FWHM >= 8 px. In that dead band the shape sample was
// refilled by the rescue pass with the only candidates that still passed: noise peaks on
// the steep halo flanks and fine diffraction rays of saturated stars. Those measure
// eccentricity ~0.75, and 35 frames of a live Pleiades session (all FWHM 7.2-7.9 px) were
// flagged "star trailing/elongation" although their stars were round.
//
// Synthetic image: flat sky + Gaussian noise, a grid of ROUND Gaussian stars with a FWHM
// in the former dead band, and one saturated star with a steep power-law halo and thin
// diffraction rays. The measured eccentricity must describe the round stars, and the
// shape sample must sit on them — not on the halo.

import XCTest
import Metal
@testable import AstroTriage

final class OversampledStarShapeTests: XCTestCase {

    // Deterministic LCG so the noise field is identical on every run.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)   // [0, 1)
        }
        /// Approximately Gaussian (sum of 12 uniforms, mean 0, sigma 1).
        mutating func gaussian() -> Float {
            var s: Float = 0
            for _ in 0..<12 { s += next() }
            return s - 6
        }
    }

    private struct Synthetic {
        let image: DecodedImage
        let starPositions: [(x: Float, y: Float)]
        let brightStar: (x: Float, y: Float)
    }

    /// 1400x1400 mono frame: sky 1700 ADU, noise sigma 60 ADU, a 10x10 grid of round
    /// Gaussian stars (FWHM `fwhm` px, peaks 12000-50000 ADU above the sky) and one
    /// saturated star with a halo ~ r^-2.5 and eight thin rays, placed between grid stars.
    private func makeSynthetic(device: MTLDevice, fwhm: Float) -> Synthetic? {
        let w = 1400, h = 1400
        var px = [Float](repeating: 1700, count: w * h)
        var rng = LCG(state: 7)

        // Saturated star with halo and rays (added before the noise so the flank is noisy).
        let bx: Float = 760, by: Float = 640
        let coreR: Float = 30
        for y in 0..<h {
            for x in 0..<w {
                let dx = Float(x) - bx, dy = Float(y) - by
                let r = (dx * dx + dy * dy).squareRoot()
                guard r < 420 else { continue }
                var v: Float = r <= coreR ? 70000 : 60000 * powf(coreR / r, 2.5)
                if r > coreR {
                    // Eight rays, 2 px wide, 40% of the local halo level.
                    let ang = atan2f(dy, dx)
                    for k in 0..<8 {
                        let a = Float(k) * .pi / 8 + 0.2
                        let dist = abs(sinf(ang - a)) * r      // distance from the ray's line
                        if dist < 1.5 { v *= 1.4 }
                    }
                }
                px[y * w + x] += v
            }
        }

        // Round grid stars, sub-pixel offsets, peaks rising across the grid.
        let sigma = fwhm / 2.3548
        var stars: [(x: Float, y: Float)] = []
        var index = 0
        for gy in 0..<10 {
            for gx in 0..<10 {
                let cx = Float(110 + gx * 130) + 0.3 * Float(gx % 3)
                let cy = Float(110 + gy * 130) + 0.4 * Float(gy % 2)
                // Keep the grid clear of the saturated core itself.
                let db = ((cx - bx) * (cx - bx) + (cy - by) * (cy - by)).squareRoot()
                if db < 60 { continue }
                let peak = Float(12000 + (index * 37) % 38000)
                index += 1
                stars.append((cx, cy))
                let reach = Int(4 * sigma) + 1
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        let x = Int(cx.rounded()) + dx, y = Int(cy.rounded()) + dy
                        let ddx = Float(x) - cx, ddy = Float(y) - cy
                        px[y * w + x] += peak * expf(-(ddx * ddx + ddy * ddy) / (2 * sigma * sigma))
                    }
                }
            }
        }

        for i in 0..<px.count { px[i] += 60 * rng.gaussian() }

        guard let buffer = device.makeBuffer(length: w * h * 2, options: .storageModeShared) else { return nil }
        let out = buffer.contents().bindMemory(to: UInt16.self, capacity: w * h)
        for i in 0..<px.count { out[i] = UInt16(max(0, min(65535, px[i].rounded()))) }
        return Synthetic(image: DecodedImage(buffer: buffer, width: w, height: h, channelCount: 1),
                         starPositions: stars, brightStar: (bx, by))
    }

    private func measure(_ syn: Synthetic, generator: PreviewGenerator) -> StarMetrics? {
        let stars = generator.detectStarsFromImage(syn.image, channel: 0)
        guard !stars.isEmpty else { return nil }
        return StarMetricsCalculator.measure(stars: stars, fullResImage: syn.image, channel: 0,
                                             totalStarCount: generator.lastTotalStarCount,
                                             generator: generator, arcsecPerPixel: 0.395)
    }

    /// Fraction of the measured shape sample that sits on a real grid star.
    private func fractionOnRealStars(_ details: [StarDetail], _ syn: Synthetic) -> Double {
        guard !details.isEmpty else { return 0 }
        let onStar = details.filter { d in
            syn.starPositions.contains { abs($0.x - d.x) <= 4 && abs($0.y - d.y) <= 4 }
        }
        return Double(onStar.count) / Double(details.count)
    }

    /// FWHM 7.3 px sits in the former dead band (6.6 px ... 8 px). The round stars must be
    /// the shape sample, and the frame must measure as round.
    func testRoundStarsInFormerDeadBandAreMeasuredAsRound() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let generator = PreviewGenerator(device: device),
              let syn = makeSynthetic(device: device, fwhm: 7.3) else { throw XCTSkip("no Metal device") }
        let metrics = try XCTUnwrap(measure(syn, generator: generator), "measurement failed")

        // Precondition: the frame really is in the band this test is about.
        XCTAssertGreaterThan(metrics.medianFWHM, 6.6, "synthetic frame is not oversampled enough")
        XCTAssertLessThan(metrics.medianFWHM, 8.0, "synthetic frame left the dead band")

        let ecc = try XCTUnwrap(metrics.medianEccentricity, "no eccentricity: real stars were rejected")
        XCTAssertLessThan(ecc, 0.35, "round stars measured as elongated (ecc \(ecc)) — halo sample?")
        XCTAssertGreaterThanOrEqual(metrics.starDetails.count, 30, "shape sample too small")
        XCTAssertGreaterThanOrEqual(fractionOnRealStars(metrics.starDetails, syn), 0.9,
                                    "shape sample does not sit on the real stars")

        let trailing = try XCTUnwrap(TrailingAnalyzer.analyze(starDetails: metrics.starDetails,
                                                              focalLength: 1964, pixelSizeMicrons: 3.76),
                                     "trailing analysis produced no result")
        XCTAssertLessThan(trailing.trailingScore, 0.3, "round frame got a trailing score")
    }

    /// Well-sampled stars (FWHM 3.2 px) never needed the scaled aperture; they must keep
    /// measuring as round next to the same bright star.
    func testWellSampledStarsStayRound() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let generator = PreviewGenerator(device: device),
              let syn = makeSynthetic(device: device, fwhm: 3.2) else { throw XCTSkip("no Metal device") }
        let metrics = try XCTUnwrap(measure(syn, generator: generator), "measurement failed")
        XCTAssertLessThan(metrics.medianFWHM, 4.4, "synthetic frame is not in the unchanged regime")
        let ecc = try XCTUnwrap(metrics.medianEccentricity)
        XCTAssertLessThan(ecc, 0.35)
        XCTAssertGreaterThanOrEqual(fractionOnRealStars(metrics.starDetails, syn), 0.9)
    }
}
