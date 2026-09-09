// v6.8.0 (algo v41) — Single hot pixels must never be counted as stars.
//
// Regression gate for the spatial-extent gate in both star detectors:
//   • GPU: `detect_stars_binned` (Shaders.metal) reads the UNBINNED buffer for the gate
//   • CPU: `StarDetector.detectStarsWithTotalCount` → `hasStellarExtent`
//
// Background: hot-pixel frames reported 10000-25000 "stars" where genuine frames of the
// same night have ~3000. Those phantom detections inflated the star-count P90 floor (real
// frames flagged "zero stars", algo v38), crowded genuine stars out of the brightness-ordered
// shape sample (v39/v40), and satisfied Rule 0's "has signal" exception on empty frames.
// Neither detector required a detection to have any spatial extent: a hot pixel is trivially
// a 3x3 local maximum and maximally "sharp".
//
// Synthetic image: flat background + Gaussian noise, a grid of Gaussian stars, and many
// isolated single-pixel spikes brighter than any star. Both detectors must return the star
// count, not stars + spikes — and no detection may sit on a spike.

import XCTest
import Metal
@testable import AstroTriage

final class HotPixelRejectionTests: XCTestCase {

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
        let starPositions: [(x: Int, y: Int)]
        let hotPixels: [(x: Int, y: Int)]
    }

    /// 512x512 mono frame: background 1000 ADU, noise sigma 10, 25 Gaussian stars
    /// (sigma 1.5 px, peak +5000) on a grid, 300 single-pixel spikes (+9000) that are
    /// brighter than every star and kept >= 8 px away from any star.
    private func makeSynthetic(device: MTLDevice) -> Synthetic? {
        let w = 512, h = 512
        var px = [Float](repeating: 1000, count: w * h)
        var rng = LCG(state: 42)
        for i in 0..<px.count { px[i] += 10 * rng.gaussian() }

        // Stars on a 5x5 grid, sub-pixel offsets so they are not all pixel-centred.
        var stars: [(x: Int, y: Int)] = []
        for gy in 0..<5 {
            for gx in 0..<5 {
                let cx = Float(60 + gx * 98) + 0.3 * Float(gx % 3)
                let cy = Float(60 + gy * 98) + 0.4 * Float(gy % 2)
                stars.append((Int(cx.rounded()), Int(cy.rounded())))
                let sigma: Float = 1.5
                for dy in -6...6 {
                    for dx in -6...6 {
                        let x = Int(cx.rounded()) + dx, y = Int(cy.rounded()) + dy
                        let ddx = Float(x) - cx, ddy = Float(y) - cy
                        px[y * w + x] += 5000 * expf(-(ddx * ddx + ddy * ddy) / (2 * sigma * sigma))
                    }
                }
            }
        }

        // Sensor defects, never within 8 px of a star or 3 px of each other. Every third
        // defect is an adjacent PAIR or a short straight chain (3 px), which is what the
        // ASI6200 actually produces and what a one-neighbour extent test lets through;
        // the rest are isolated single pixels.
        var hot: [(x: Int, y: Int)] = []
        var attempts = 0
        while hot.count < 300 && attempts < 20000 {
            attempts += 1
            let x = 8 + Int(rng.next() * Float(w - 16))
            let y = 8 + Int(rng.next() * Float(h - 16))
            let farFromStars = stars.allSatisfy { abs($0.x - x) > 8 || abs($0.y - y) > 8 }
            let farFromHot = hot.allSatisfy { abs($0.x - x) > 4 || abs($0.y - y) > 4 }
            guard farFromStars, farFromHot else { continue }
            px[y * w + x] += 9000
            switch hot.count % 3 {
            case 1:  px[y * w + x + 1] += 7000                                   // horizontal pair
            case 2:  px[(y + 1) * w + x] += 8000; px[(y + 2) * w + x] += 6000    // vertical chain
            default: break                                                      // single pixel
            }
            hot.append((x, y))
        }

        guard let buffer = device.makeBuffer(length: w * h * 2, options: .storageModeShared) else { return nil }
        let out = buffer.contents().bindMemory(to: UInt16.self, capacity: w * h)
        for i in 0..<px.count { out[i] = UInt16(max(0, min(65535, px[i].rounded()))) }
        return Synthetic(image: DecodedImage(buffer: buffer, width: w, height: h, channelCount: 1),
                         starPositions: stars, hotPixels: hot)
    }

    private func assertNoDetectionOnHotPixel(_ detected: [DetectedStar], _ syn: Synthetic,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let onHot = detected.filter { d in
            syn.hotPixels.contains { abs(Float($0.x) - d.x) <= 3.5 && abs(Float($0.y) - d.y) <= 3.5 }
        }
        XCTAssertEqual(onHot.count, 0, "\(onHot.count) detections sit on hot pixels", file: file, line: line)
    }

    func testCPUDetectorRejectsHotPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let syn = makeSynthetic(device: device) else { throw XCTSkip("no Metal device") }
        XCTAssertEqual(syn.hotPixels.count, 300)

        let result = StarDetector.detectStarsWithTotalCount(in: syn.image, maxStars: 1000,
                                                            subsampleFactor: 4, channel: 0)
        // Subsampling (every 4th pixel) can miss a star whose peak falls between sample
        // points, so allow a small shortfall — but never a surplus from hot pixels.
        XCTAssertLessThanOrEqual(result.totalCount, syn.starPositions.count,
                                 "CPU detector counted hot pixels as stars")
        XCTAssertGreaterThanOrEqual(result.totalCount, syn.starPositions.count - 5,
                                    "CPU detector lost real stars")
        assertNoDetectionOnHotPixel(result.stars, syn)
    }

    func testGPUDetectorRejectsHotPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let syn = makeSynthetic(device: device),
              let generator = PreviewGenerator(device: device) else { throw XCTSkip("no Metal device") }

        let stars = generator.detectStarsFromImage(syn.image, channel: 0)
        let total = generator.lastTotalStarCount
        XCTAssertEqual(total, syn.starPositions.count,
                       "GPU detector: expected \(syn.starPositions.count) stars, got \(total) (hot pixels counted?)")
        XCTAssertEqual(stars.count, syn.starPositions.count)
        assertNoDetectionOnHotPixel(stars, syn)

        // Every real star must still be found (within bin2x positional tolerance).
        for s in syn.starPositions {
            let found = stars.contains { abs($0.x - Float(s.x)) <= 2.5 && abs($0.y - Float(s.y)) <= 2.5 }
            XCTAssertTrue(found, "real star at (\(s.x), \(s.y)) lost")
        }
    }

    /// An undersampled star (FWHM ~1.3 px, sigma 0.55) centred exactly on a pixel is the
    /// worst case for the extent gate — its brightest neighbour carries only ~28% of the peak.
    /// It must still pass, while an equally bright single pixel must not.
    func testExtentGateKeepsUndersampledStar() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let w = 64, h = 64
        guard let buffer = device.makeBuffer(length: w * h * 2, options: .storageModeShared) else { return }
        let p = buffer.contents().bindMemory(to: UInt16.self, capacity: w * h)
        for i in 0..<(w * h) { p[i] = 1000 }
        // Pixel-integrated Gaussian, sigma 0.55, centred on (20, 20)
        let sigma: Float = 0.55
        func integ(_ a: Float, _ b: Float) -> Float {   // ∫ N(0,σ) over [a, b]
            0.5 * (erff(b / (sigma * sqrtf(2))) - erff(a / (sigma * sqrtf(2))))
        }
        let norm = integ(-0.5, 0.5) * integ(-0.5, 0.5)
        for dy in -3...3 {
            for dx in -3...3 {
                let v = 4000 * integ(Float(dx) - 0.5, Float(dx) + 0.5) * integ(Float(dy) - 0.5, Float(dy) + 0.5) / norm
                p[(20 + dy) * w + (20 + dx)] = UInt16(1000 + v.rounded())
            }
        }
        // Single hot pixel of the same peak height at (44, 44), a horizontal pair at (10, 44)
        // and a vertical 3-px chain at (44, 10): one-dimensional, so not stars.
        p[44 * w + 44] = 5000
        p[44 * w + 10] = 5000; p[44 * w + 11] = 4200
        p[10 * w + 44] = 5000; p[11 * w + 44] = 4600; p[12 * w + 44] = 3900

        XCTAssertTrue(StarDetector.hasStellarExtent(ptr: p, channelOffset: 0, width: w, height: h,
                                                    nearX: 21, nearY: 19, searchRadius: 3,
                                                    background: 1000),
                      "undersampled pixel-centred star rejected by the extent gate")
        XCTAssertFalse(StarDetector.hasStellarExtent(ptr: p, channelOffset: 0, width: w, height: h,
                                                     nearX: 44, nearY: 44, searchRadius: 3,
                                                     background: 1000),
                       "single hot pixel passed the extent gate")
        XCTAssertFalse(StarDetector.hasStellarExtent(ptr: p, channelOffset: 0, width: w, height: h,
                                                     nearX: 10, nearY: 44, searchRadius: 3,
                                                     background: 1000),
                       "horizontal hot-pixel pair passed the extent gate")
        XCTAssertFalse(StarDetector.hasStellarExtent(ptr: p, channelOffset: 0, width: w, height: h,
                                                     nearX: 44, nearY: 11, searchRadius: 3,
                                                     background: 1000),
                       "vertical hot-pixel chain passed the extent gate")
    }
}
