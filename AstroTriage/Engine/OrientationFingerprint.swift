// v5.28.0
//
// Lightweight 32×32 per-frame spatial signature used as the last-resort
// signal in auto-rotate. Compares a frame to the per-target reference in
// both natural and 180°-rotated orientation; when the rotated match is
// significantly better, the frame is flagged for a 180° flip.
//
// Why this exists: 20.8 % of the 6 210-frame local corpus carries neither
// PIERSIDE nor a rotator angle (mostly RASA setups), and cross-session
// rotator recalibrations on GEM setups (Cosmic Horseshoe, M81 …) make
// rotator deltas unreliable. Star matching is usually enough, but on
// rotation-invariant star fields it can fail closed (spurious identity).
// The pixel fingerprint runs on raw pixel structure, so it's immune to
// both of those failure modes.
//
// Cost: single pass over ~256 k pixel reads per 50 MP frame, ≤ 1 ms on an
// M-series core. 1024 bytes / frame stored on ImageEntry (transient,
// session-scoped, not persisted).

import Foundation
import Metal

enum OrientationFingerprint {

    // 32×32 grid — fine enough to capture asymmetric structure in a
    // DSO + field-star layout, coarse enough to stay cheap to compare.
    static let dim = 32
    static let byteCount = dim * dim                     // 1024

    /// Build a fingerprint from a raw decoded image. Operates on channel 0
    /// only (which works for both mono sensors and OSC-debayered RGB — the
    /// spatial pattern of bright spots carries through all channels). For
    /// planar RGB the first channel is the R plane.
    ///
    /// The fingerprint value in each cell is the max pixel value in that
    /// cell, mapped to its position relative to the global median: cells
    /// at or below median become 0, cells above median are quantised onto
    /// [1, 255] by their intensity above the median. This makes the
    /// fingerprint invariant to global brightness shifts (exposure, gain,
    /// filter throughput) while preserving the "where are the bright
    /// features" shape — which is exactly what rotation matching needs.
    static func compute(from image: DecodedImage) -> [UInt8]? {
        let w = image.width
        let h = image.height
        let ch = image.channelCount
        // Need at least a handful of pixels per cell or the signature
        // degenerates. 4 px per dim guarantees non-trivial sampling.
        guard w >= dim * 4, h >= dim * 4, ch >= 1 else { return nil }

        // Channel 0 is R for planar RGB, the only channel for mono — both
        // give a good "bright spot" map.
        let planeOffset = 0
        let planeLen = w * h
        let ptr = image.buffer.contents().bindMemory(to: UInt16.self,
                                                     capacity: planeLen * ch)

        let cellW = w / dim
        let cellH = h / dim
        // Sample every ~Nth pixel inside a cell — we don't need all of
        // them, just enough to catch a bright star if one is in the cell.
        // Target ~16 samples per row & col inside each cell.
        let stepX = max(1, cellW / 16)
        let stepY = max(1, cellH / 16)

        var cells = [UInt16](repeating: 0, count: byteCount)
        for gy in 0..<dim {
            let y0 = gy * cellH
            let y1 = y0 + cellH
            for gx in 0..<dim {
                let x0 = gx * cellW
                let x1 = x0 + cellW
                var maxVal: UInt16 = 0
                var y = y0
                while y < y1 {
                    let rowBase = planeOffset + y * w
                    var x = x0
                    while x < x1 {
                        let v = ptr[rowBase + x]
                        if v > maxVal { maxVal = v }
                        x += stepX
                    }
                    y += stepY
                }
                cells[gy * dim + gx] = maxVal
            }
        }

        // Global median + dynamic range for normalisation. The max-cell
        // tends to be a bright star; medians are robust to a few hot
        // pixels or a cosmic ray hit.
        let sorted = cells.sorted()
        let median = sorted[sorted.count / 2]
        let top: UInt16 = {
            // 95th percentile as "range top" — ignores hottest outlier.
            let idx = Int(Double(sorted.count) * 0.95)
            return sorted[min(idx, sorted.count - 1)]
        }()

        let rangeRaw = top > median ? UInt32(top - median) : 1
        let range = max(rangeRaw, 1)
        var out = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            let v = cells[i]
            if v <= median { out[i] = 0; continue }
            let delta = UInt32(v - median)
            let q = (delta * 255) / range
            out[i] = UInt8(min(255, q))
        }
        return out
    }

    /// Sum of absolute differences between two fingerprints in direct order.
    static func sadDirect(_ a: [UInt8], _ b: [UInt8]) -> UInt64 {
        precondition(a.count == byteCount && b.count == byteCount)
        var total: UInt64 = 0
        for i in 0..<byteCount {
            let d = Int32(a[i]) - Int32(b[i])
            total += UInt64(d.magnitude)
        }
        return total
    }

    /// Sum of absolute differences between `a` and the 180°-rotated `b`.
    /// (Index i in `b` maps to `byteCount - 1 - i` for a pure 180° flip.)
    static func sadMirrored(_ a: [UInt8], _ b: [UInt8]) -> UInt64 {
        precondition(a.count == byteCount && b.count == byteCount)
        var total: UInt64 = 0
        let last = byteCount - 1
        for i in 0..<byteCount {
            let d = Int32(a[i]) - Int32(b[last - i])
            total += UInt64(d.magnitude)
        }
        return total
    }

    /// Decide whether `frame` is a 180°-rotated version of `reference`.
    ///
    /// Triggers only when:
    ///   • the mirrored SAD is ≥ 20 % lower than the direct SAD (clear
    ///     margin — random noise produces ~equal SADs), AND
    ///   • the direct SAD is high enough that we're not comparing two
    ///     already-matching (flat or low-structure) fingerprints.
    ///
    /// Both conditions are required because on a completely featureless
    /// sky the two orientations produce near-identical SADs and the
    /// ratio becomes unstable.
    static func mirrorIsBetterMatch(reference: [UInt8], frame: [UInt8]) -> Bool {
        let direct = sadDirect(reference, frame)
        let mirrored = sadMirrored(reference, frame)

        // direct > 2048 ≈ 2 cells-worth of absolute delta on average,
        // empirical floor to avoid triggering on uniform frames.
        guard direct > 2048 else { return false }
        // mirrored < direct × 0.8 → ≥ 20 % better in mirrored orientation.
        return mirrored * 5 < direct * 4
    }
}
