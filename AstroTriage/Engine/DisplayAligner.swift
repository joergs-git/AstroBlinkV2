// v5.22.0
import Foundation

// Public 2D affine transform shared across alignment/display code.
// Maps source pixel (x, y) → (a*x + b*y + tx, c*x + d*y + ty).
// Kept as a plain struct so it can cross thread boundaries freely.
struct AffineTransform2D: Equatable, Hashable {
    let a: Float, b: Float, tx: Float
    let c: Float, d: Float, ty: Float

    static let identity = AffineTransform2D(a: 1, b: 0, tx: 0, c: 0, d: 1, ty: 0)

    /// 180° rotation around image center (in normalized [0,1] UV space).
    /// Equivalent to the legacy rotate180 UV swap (u → 1-u, v → 1-v).
    static let rotate180Normalized = AffineTransform2D(a: -1, b: 0, tx: 1, c: 0, d: -1, ty: 1)

    /// UV-normalized rotation by `thetaRad` around the image centre (0.5, 0.5).
    /// Sign convention: positive theta = math-positive (CCW in math XY) — same
    /// convention as `rotate180Normalized` (θ = π) and `.rotation` (`atan2(c, a)`).
    ///
    /// Sampling semantics: this transforms source UV → destination UV, so if the
    /// frame was captured rotated by +θ relative to the reference, applying
    /// this transform with -θ unrotates the sample positions back into reference
    /// orientation. Used by the header-driven meridian-rotation path when the
    /// scope / rotator angles give a precise rotation amount (not just the
    /// binary 180° pier flip).
    static func rotationAroundCenterNormalized(_ thetaRad: Float) -> AffineTransform2D {
        let cTheta = cosf(thetaRad)
        let sTheta = sinf(thetaRad)
        return AffineTransform2D(
            a:  cTheta, b: -sTheta, tx: 0.5 * (1.0 - cTheta + sTheta),
            c:  sTheta, d:  cTheta, ty: 0.5 * (1.0 - sTheta - cTheta)
        )
    }

    var rotation: Float { atan2f(c, a) }
    var scale: Float { sqrtf(a * a + c * c) }

    /// Apply transform to a pixel/UV position.
    func apply(_ x: Float, _ y: Float) -> (Float, Float) {
        return (a * x + b * y + tx, c * x + d * y + ty)
    }

    /// Inverse transform (nil when determinant is too small to invert reliably).
    var inverse: AffineTransform2D? {
        let det = a * d - b * c
        guard Swift.abs(det) > 1e-6 else { return nil }
        let invDet = 1.0 / det
        return AffineTransform2D(
            a:  d * invDet,
            b: -b * invDet,
            tx: (b * ty - d * tx) * invDet,
            c: -c * invDet,
            d:  a * invDet,
            ty: (c * tx - a * ty) * invDet
        )
    }

    /// Convert a pixel-space transform into a normalized UV-space transform.
    /// Pixel transform: (x_ref_px, y_ref_px) = T(x_src_px, y_src_px).
    /// Normalized result maps (u_src, v_src) → (u_ref, v_ref) where u = x/W, v = y/H.
    /// Cross terms pick up the aspect ratio because a pixel's horizontal and vertical
    /// extents aren't equal in normalized space unless W == H.
    func normalized(width: Int, height: Int) -> AffineTransform2D {
        guard width > 0, height > 0 else { return self }
        let W = Float(width)
        let H = Float(height)
        return AffineTransform2D(
            a:  a,
            b:  b * H / W,
            tx: tx / W,
            c:  c * W / H,
            d:  d,
            ty: ty / H
        )
    }
}

/// Lightweight star-based image alignment for display-time visual consistency.
///
/// Per target group: the first frame whose stars arrive becomes the reference.
/// Subsequent frames are matched against that reference using triangle matching +
/// least-squares affine refinement (same algorithm as QuickStackEngineV2 stacking,
/// extracted and simplified for display use).
///
/// Thread-safe: the reference state is protected by a lock so background prefetch
/// workers can call `alignOrEstablish` concurrently.
///
/// Returned transform maps FRAME pixel coordinates → REFERENCE pixel coordinates.
/// Display code should invert this (`transform.inverse`) to sample the frame texture
/// at positions corresponding to the reference view.
final class DisplayAligner {
    // Matching parameters.
    //
    // triangleStarLimit = 30 (not 20) for one specific reason: matching across filters.
    // Top-20 brightest stars in an H-alpha narrowband frame have almost NO overlap with
    // top-20 in a B broadband frame — they're capturing different physical phenomena.
    // Top-30 has enough extra stars that filter-invariant real stars make the cut in
    // both sets, enabling cross-filter alignment.
    //
    // Cost: C(30,3)=4060 triangles vs C(20,3)=1140 triangles (~3.5× building cost,
    // ~9× matching cost in worst case). Performance stays acceptable because most
    // frames hit the early-exit threshold before exhausting the candidate pool.
    //
    // Inlier thresholds: QuickStackEngineV2 defaults (6/5). The early-exit threshold
    // (35, below) is the critical parameter for preventing false-rotation matches,
    // not the initial threshold.
    private static let triangleStarLimit = 30
    private static let inlierCheckLimit = 50
    private static let initialInlierThreshold: Float = 10.0
    private static let minInitialInliers = 6
    private static let minFinalInliers = 5
    // Confident-match threshold for the fast path: if the top-inlier candidate has
    // this many initial inliers, it's an obviously correct identity-class match and
    // we can skip the multi-bucket refinement loop. 25 is safely below inlierCheckLimit
    // (50) so it's reachable, and above the ~20 ceiling for false 0° matches seen on
    // the M81 debug data.
    private static let confidentInlierThreshold = 25

    // Per-target reference state. Holds both WCS (primary alignment path) and stars
    // (fallback). wcs is nil for frames without plate-solve data; stars/triangles are
    // nil for frames where we couldn't detect enough stars.
    private struct ReferenceState {
        let wcs: WCSData?
        let stars: [DetectedStar]
        let triangles: [Triangle]
        let index: [TriangleKey: [Int]]
    }

    private struct Triangle {
        let i0: Int, i1: Int, i2: Int
        let ratios: (Float, Float)
    }

    private struct TriangleKey: Hashable {
        let r1Bucket: Int
        let r2Bucket: Int

        init(r1: Float, r2: Float) {
            r1Bucket = Int(r1 / 0.025)
            r2Bucket = Int(r2 / 0.025)
        }

        init(r1Bucket: Int, r2Bucket: Int) {
            self.r1Bucket = r1Bucket
            self.r2Bucket = r2Bucket
        }
    }

    private let lock = NSLock()
    private var references: [String: ReferenceState] = [:]

    /// Reset all reference state. Call when a new session is loaded.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        references.removeAll()
    }

    /// Stats for diagnostics: how many target groups have a reference set.
    var referenceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return references.count
    }

    /// Whether a reference has already been established for a given target.
    func hasReference(for targetKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return references[targetKey] != nil
    }

    /// Set to true temporarily for verbose diagnostic logging. Leave false for production.
    static var debugLogging: Bool = false

    // MARK: - WCS Plate-Solve Based Transform (Primary Alignment Path)

    /// Bundle of the WCS fields needed for CD-matrix based alignment.
    struct WCSData {
        let crpix1: Double
        let crpix2: Double
        let crval1: Double
        let crval2: Double
        let cd11: Double
        let cd12: Double
        let cd21: Double
        let cd22: Double
    }

    /// Compute an exact frame-to-reference affine transform from WCS plate-solve data.
    ///
    /// For a pixel `p_frame = (x, y)` in the frame, the sky position is
    ///     sky = crval_frame + CD_frame × (p_frame - crpix_frame)
    /// and the same sky point in reference coordinates is
    ///     p_ref = crpix_ref + CD_ref⁻¹ × (sky - crval_ref)
    /// Composing gives:
    ///     p_ref = crpix_ref + CD_ref⁻¹ × (crval_frame - crval_ref + CD_frame × (p_frame - crpix_frame))
    /// which is a pure affine transform on `p_frame`.
    ///
    /// Because CD is in degrees/pixel, CRVAL differences must be in degrees. We also
    /// scale the RA difference by cos(dec) to correct for the spherical projection
    /// distortion — this keeps the alignment accurate for large RA offsets far from
    /// the celestial equator.
    ///
    /// Returns a transform in frame → reference pixel space, or nil if the CD matrix
    /// is singular or the inputs are invalid.
    static func transformFromWCS(frame: WCSData, reference: WCSData) -> AffineTransform2D? {
        // Invert reference CD matrix
        let detRef = reference.cd11 * reference.cd22 - reference.cd12 * reference.cd21
        guard Swift.abs(detRef) > 1e-12 else { return nil }
        let invRef11 =  reference.cd22 / detRef
        let invRef12 = -reference.cd12 / detRef
        let invRef21 = -reference.cd21 / detRef
        let invRef22 =  reference.cd11 / detRef

        // M = CD_ref⁻¹ × CD_frame  (2×2 matrix product)
        let m11 = invRef11 * frame.cd11 + invRef12 * frame.cd21
        let m12 = invRef11 * frame.cd12 + invRef12 * frame.cd22
        let m21 = invRef21 * frame.cd11 + invRef22 * frame.cd21
        let m22 = invRef21 * frame.cd12 + invRef22 * frame.cd22

        // Sky offset between frames, scaled by cos(reference.dec) for RA spherical correction
        let cosDec = cos(reference.crval2 * .pi / 180.0)
        let dRA  = (frame.crval1 - reference.crval1) * cosDec
        let dDec =  frame.crval2 - reference.crval2

        // Pixel offset contribution from sky difference: CD_ref⁻¹ × (dRA, dDec)
        let skyOffsetX = invRef11 * dRA + invRef12 * dDec
        let skyOffsetY = invRef21 * dRA + invRef22 * dDec

        // Affine form: p_ref = M × (p_frame - crpix_frame) + crpix_ref + skyOffset
        //            = M × p_frame + (crpix_ref + skyOffset - M × crpix_frame)
        let tx = reference.crpix1 + skyOffsetX - (m11 * frame.crpix1 + m12 * frame.crpix2)
        let ty = reference.crpix2 + skyOffsetY - (m21 * frame.crpix1 + m22 * frame.crpix2)

        let transform = AffineTransform2D(
            a:  Float(m11), b: Float(m12), tx: Float(tx),
            c:  Float(m21), d: Float(m22), ty: Float(ty)
        )

        // Sanity: determinant should be close to 1 for same-camera frames.
        // (Slight deviation is normal from plate-solve precision.)
        let det = m11 * m22 - m12 * m21
        guard det > 0.8 && det < 1.25 else { return nil }

        return transform
    }

    /// Align stars to the reference for this target group.
    /// - If no reference exists yet, this frame becomes the reference and `.identity` is returned.
    /// - If a reference exists, attempts to compute the affine transform from these stars.
    /// - Returns nil if alignment fails (too few stars, poor triangle match, large residuals).
    ///
    /// Thread-safe: reference establishment is atomic. Multiple callers with the same targetKey
    /// will see the first one win; subsequent callers align against it.
    func alignOrEstablish(
        stars: [DetectedStar], wcs: WCSData? = nil,
        targetKey: String, debugTag: String? = nil
    ) -> AffineTransform2D? {
        // Need at least 3 stars for the triangle-based fallback path.
        // (WCS path only needs 0 stars.)
        guard stars.count >= 3 else {
            if Self.debugLogging { print("[AutoRotate] \(debugTag ?? "?") target=\(targetKey) FAIL: only \(stars.count) stars (<3)") }
            return nil
        }

        // Sort brightest first (DetectedStar is Comparable descending by brightness)
        let sortedStars = stars.sorted()

        lock.lock()
        if let ref = references[targetKey] {
            // Reference exists — release lock before heavy CPU work
            lock.unlock()

            // Primary path: WCS-based transform (exact, fast, filter-independent).
            // Used when both reference and current frame have plate-solve data.
            if let refWCS = ref.wcs, let frameWCS = wcs,
               let wcsTransform = Self.transformFromWCS(frame: frameWCS, reference: refWCS) {
                if Self.debugLogging {
                    let rotDeg = atan2f(wcsTransform.c, wcsTransform.a) * 180.0 / .pi
                    print(String(format: "[AutoRotate] %@ target=%@ OK[wcs]: rot=%.2f° tx=%.1f ty=%.1f",
                                 debugTag ?? "?", targetKey, rotDeg, wcsTransform.tx, wcsTransform.ty))
                }
                return wcsTransform
            }

            // Fallback: star-based triangle matching
            let result = matchToReference(frameStars: sortedStars, reference: ref, debugTag: debugTag, targetKey: targetKey)
            if result == nil, Self.debugLogging {
                print("[AutoRotate] \(debugTag ?? "?") target=\(targetKey) stars=\(sortedStars.count) FAIL: no match (refStars=\(ref.stars.count))")
            }
            return result
        }

        // Establish reference from this frame's data while holding lock.
        // Store both WCS (primary) and triangles (fallback) so future frames can use either.
        let triangles = buildTriangles(from: sortedStars)
        let index = buildTriangleIndex(from: triangles)
        references[targetKey] = ReferenceState(
            wcs: wcs, stars: sortedStars, triangles: triangles, index: index
        )
        lock.unlock()
        if Self.debugLogging {
            let hasWCS = wcs != nil ? "+wcs" : "no-wcs"
            print("[AutoRotate] \(debugTag ?? "?") target=\(targetKey) stars=\(sortedStars.count) REFERENCE established (\(hasWCS)), triangles=\(triangles.count)")
        }
        return .identity
    }

    // MARK: - Triangle Matching

    private func matchToReference(
        frameStars: [DetectedStar], reference: ReferenceState,
        debugTag: String? = nil, targetKey: String? = nil
    ) -> AffineTransform2D? {
        let frameTriangles = buildTriangles(from: frameStars)
        guard !frameTriangles.isEmpty else { return nil }

        // Rotation bucketing: keep the best candidate (by initial inliers) from each
        // rotation bucket. This guarantees candidates from distinct rotation clusters
        // survive for refinement, preventing a single high-scoring false cluster from
        // crowding out the true cluster.
        //
        // 36 buckets × 10° = full 360° coverage. 10° is narrow enough to separate
        // adjacent clusters like 0° and 19° (multi-night camera rotation differences),
        // but wide enough that small drift within a session stays in one bucket.
        // Refinement cost is capped at 36 refinements/frame max, but in practice most
        // frames only populate 3-5 buckets.
        struct Candidate {
            let transform: AffineTransform2D
            let initialInliers: Int
        }
        let bucketCount = 36
        let bucketWidthDeg: Float = 10.0
        var bucketCandidates = [Candidate?](repeating: nil, count: bucketCount)

        for ft in frameTriangles {
            let key = TriangleKey(r1: ft.ratios.0, r2: ft.ratios.1)

            for dr1 in -1...1 {
                for dr2 in -1...1 {
                    let searchKey = TriangleKey(
                        r1Bucket: key.r1Bucket + dr1,
                        r2Bucket: key.r2Bucket + dr2
                    )
                    guard let refCandidates = reference.index[searchKey] else { continue }

                    for refIdx in refCandidates {
                        let rt = reference.triangles[refIdx]

                        let dr1f = Swift.abs(rt.ratios.0 - ft.ratios.0)
                        let dr2f = Swift.abs(rt.ratios.1 - ft.ratios.1)
                        guard dr1f < 0.05 && dr2f < 0.05 else { continue }

                        let refPts = [
                            (reference.stars[rt.i0].x, reference.stars[rt.i0].y),
                            (reference.stars[rt.i1].x, reference.stars[rt.i1].y),
                            (reference.stars[rt.i2].x, reference.stars[rt.i2].y)
                        ]
                        let framePts = [
                            (frameStars[ft.i0].x, frameStars[ft.i0].y),
                            (frameStars[ft.i1].x, frameStars[ft.i1].y),
                            (frameStars[ft.i2].x, frameStars[ft.i2].y)
                        ]

                        guard let transform = solveAffine(from: framePts, to: refPts) else { continue }

                        let inliers = countInliers(
                            transform: transform,
                            refStars: reference.stars, frameStars: frameStars,
                            threshold: Self.initialInlierThreshold,
                            limit: Self.inlierCheckLimit
                        )
                        guard inliers >= Self.minInitialInliers else { continue }

                        // Compute rotation and bucket index
                        let rotDeg = atan2f(transform.c, transform.a) * 180.0 / .pi
                        // Shift rotation to [0, 360) for bucketing
                        var rotPos = rotDeg
                        if rotPos < 0 { rotPos += 360 }
                        let bucketIdx = min(bucketCount - 1, Int(rotPos / bucketWidthDeg))

                        // Keep best-initial-inlier candidate in this rotation bucket
                        if let existing = bucketCandidates[bucketIdx] {
                            if inliers > existing.initialInliers {
                                bucketCandidates[bucketIdx] = Candidate(transform: transform, initialInliers: inliers)
                            }
                        } else {
                            bucketCandidates[bucketIdx] = Candidate(transform: transform, initialInliers: inliers)
                        }
                    }
                }
            }
        }

        // Extract populated buckets, sorted by initial inliers (highest first).
        // Only refine the top-5: these cover the most promising rotation clusters,
        // and refining all 36 buckets doubles the load time for no measurable quality
        // gain on real sessions (most frames only populate 2-4 distinct buckets anyway).
        let allCandidates = bucketCandidates.compactMap { $0 }
            .sorted { $0.initialInliers > $1.initialInliers }
        let candidates = Array(allCandidates.prefix(5))

        // Fast path: if the top candidate has overwhelming inlier count (35+), it's
        // an obviously correct identity-class match and we can skip the multi-candidate
        // refinement loop. Saves most of the per-frame cost on the common success path.
        if let best = candidates.first, best.initialInliers >= Self.confidentInlierThreshold {
            let pass1 = refineTransform(
                initial: best.transform,
                refStars: reference.stars, frameStars: frameStars,
                threshold: 8.0
            )
            let pass2 = refineTransform(
                initial: pass1 ?? best.transform,
                refStars: reference.stars, frameStars: frameStars,
                threshold: 4.0
            )
            let refined = pass2 ?? pass1 ?? best.transform
            let finalInliers = countInliers(
                transform: refined, refStars: reference.stars, frameStars: frameStars,
                threshold: 4.0
            )
            if finalInliers >= Self.minFinalInliers {
                if Self.debugLogging {
                    let rotDeg = atan2f(refined.c, refined.a) * 180.0 / .pi
                    print(String(format: "[AutoRotate] %@ target=%@ OK[fast]: initialInliers=%d finalInliers=%d rot=%.1f° tx=%.1f ty=%.1f",
                                 debugTag ?? "?", targetKey ?? "?",
                                 best.initialInliers, finalInliers,
                                 rotDeg, refined.tx, refined.ty))
                }
                return refined
            }
            // Fast path refinement failed — fall through to multi-candidate search
        }

        guard !candidates.isEmpty else {
            if Self.debugLogging {
                print("[AutoRotate] \(debugTag ?? "?") target=\(targetKey ?? "?") frameStars=\(frameStars.count) refStars=\(reference.stars.count) FAIL initial: no candidates")
            }
            return nil
        }

        // Refine each top-K candidate and keep the best by FINAL inlier count
        var bestFinalTransform: AffineTransform2D?
        var bestFinalInliers = 0
        var bestInitialForLog = 0

        for cand in candidates {
            let pass1 = refineTransform(
                initial: cand.transform,
                refStars: reference.stars, frameStars: frameStars,
                threshold: 8.0
            )
            let pass2 = refineTransform(
                initial: pass1 ?? cand.transform,
                refStars: reference.stars, frameStars: frameStars,
                threshold: 4.0
            )
            let refined = pass2 ?? pass1 ?? cand.transform

            let finalInliers = countInliers(
                transform: refined, refStars: reference.stars, frameStars: frameStars,
                threshold: 4.0
            )

            if finalInliers > bestFinalInliers {
                bestFinalInliers = finalInliers
                bestFinalTransform = refined
                bestInitialForLog = cand.initialInliers
            }
        }

        guard bestFinalInliers >= Self.minFinalInliers, let final = bestFinalTransform else {
            if Self.debugLogging {
                print("[AutoRotate] \(debugTag ?? "?") target=\(targetKey ?? "?") FAIL final: bestFinalInliers=\(bestFinalInliers) (<\(Self.minFinalInliers)) candidates=\(candidates.count)")
            }
            return nil
        }
        if Self.debugLogging {
            let rotDeg = atan2f(final.c, final.a) * 180.0 / .pi
            print(String(format: "[AutoRotate] %@ target=%@ OK: initialInliers=%d finalInliers=%d rot=%.1f° tx=%.1f ty=%.1f candidates=%d",
                         debugTag ?? "?", targetKey ?? "?",
                         bestInitialForLog, bestFinalInliers,
                         rotDeg, final.tx, final.ty, candidates.count))
        }
        return final
    }

    // MARK: - Triangle Building

    private func buildTriangles(from stars: [DetectedStar]) -> [Triangle] {
        let n = min(stars.count, Self.triangleStarLimit)
        var triangles: [Triangle] = []
        // Reserve capacity for expected triangle count — avoids reallocation
        triangles.reserveCapacity(max(0, n * (n - 1) * (n - 2) / 6))

        for i in 0..<n {
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    let dx01 = stars[j].x - stars[i].x
                    let dy01 = stars[j].y - stars[i].y
                    let d01 = (dx01 * dx01 + dy01 * dy01).squareRoot()

                    let dx02 = stars[k].x - stars[i].x
                    let dy02 = stars[k].y - stars[i].y
                    let d02 = (dx02 * dx02 + dy02 * dy02).squareRoot()

                    let dx12 = stars[k].x - stars[j].x
                    let dy12 = stars[k].y - stars[j].y
                    let d12 = (dx12 * dx12 + dy12 * dy12).squareRoot()

                    var sides = [(d01, i, j), (d02, i, k), (d12, j, k)]
                    sides.sort { $0.0 > $1.0 }

                    let longest = sides[0].0
                    guard longest > 10 else { continue }  // Too small → noise

                    let r1 = sides[1].0 / longest
                    let r2 = sides[2].0 / longest

                    triangles.append(Triangle(
                        i0: sides[0].1,
                        i1: sides[0].2,
                        i2: sides[2].1 == sides[0].1 || sides[2].1 == sides[0].2
                            ? sides[2].2 : sides[2].1,
                        ratios: (r1, r2)
                    ))
                }
            }
        }
        return triangles
    }

    private func buildTriangleIndex(from triangles: [Triangle]) -> [TriangleKey: [Int]] {
        var index: [TriangleKey: [Int]] = [:]
        for (i, tri) in triangles.enumerated() {
            let key = TriangleKey(r1: tri.ratios.0, r2: tri.ratios.1)
            index[key, default: []].append(i)
        }
        return index
    }

    // MARK: - Affine Solving

    /// Solve 3-point affine from 3 source → 3 destination correspondences.
    /// Returns nil if points are colinear or the resulting scale is way off 1.0.
    private func solveAffine(
        from src: [(Float, Float)], to dst: [(Float, Float)]
    ) -> AffineTransform2D? {
        let x0 = src[0].0, y0 = src[0].1
        let x1 = src[1].0, y1 = src[1].1
        let x2 = src[2].0, y2 = src[2].1

        let det = x0 * (y1 - y2) - y0 * (x1 - x2) + (x1 * y2 - x2 * y1)
        guard Swift.abs(det) > 1e-6 else { return nil }
        let invDet = 1.0 / det

        let inv00 = (y1 - y2) * invDet
        let inv01 = (y2 - y0) * invDet
        let inv02 = (y0 - y1) * invDet
        let inv10 = (x2 - x1) * invDet
        let inv11 = (x0 - x2) * invDet
        let inv12 = (x1 - x0) * invDet
        let inv20 = (x1 * y2 - x2 * y1) * invDet
        let inv21 = (x2 * y0 - x0 * y2) * invDet
        let inv22 = (x0 * y1 - x1 * y0) * invDet

        let X0 = dst[0].0, Y0 = dst[0].1
        let X1 = dst[1].0, Y1 = dst[1].1
        let X2 = dst[2].0, Y2 = dst[2].1

        let a  = inv00 * X0 + inv01 * X1 + inv02 * X2
        let b  = inv10 * X0 + inv11 * X1 + inv12 * X2
        let tx = inv20 * X0 + inv21 * X1 + inv22 * X2
        let c  = inv00 * Y0 + inv01 * Y1 + inv02 * Y2
        let d  = inv10 * Y0 + inv11 * Y1 + inv12 * Y2
        let ty = inv20 * Y0 + inv21 * Y1 + inv22 * Y2

        // Sanity check: scale should be roughly 1.0 on both axes
        let scaleX = (a * a + c * c).squareRoot()
        let scaleY = (b * b + d * d).squareRoot()
        guard scaleX > 0.8 && scaleX < 1.2 && scaleY > 0.8 && scaleY < 1.2 else { return nil }

        // CRITICAL: reject mirror transforms (negative determinant).
        // Triangle-ratio matching is invariant to triangle handedness, so the hash-based
        // search can pair a CCW triangle in the reference with a CW triangle in the frame,
        // producing an affine that mirrors the image. Since astrophotography frames from
        // the same setup are never physically mirrored between exposures, a negative-det
        // solution is always a false match — reject it.
        //
        // Note: we intentionally do NOT restrict rotation angles. Multi-night sessions
        // legitimately have arbitrary camera rotations (e.g. 20° one night, 75° another)
        // when the camera is physically rotated between sessions. Triangle matching is
        // rotation-invariant by design and should handle any angle.
        let determinant = a * d - b * c
        guard determinant > 0.9 && determinant < 1.1 else { return nil }

        return AffineTransform2D(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
    }

    /// Least-squares affine refinement: find the transform minimizing sum of squared
    /// residuals over all matched pairs (frame star → closest ref star under initial).
    private func refineTransform(
        initial: AffineTransform2D,
        refStars: [DetectedStar], frameStars: [DetectedStar],
        threshold: Float
    ) -> AffineTransform2D? {
        let threshSq = threshold * threshold

        var srcPts: [(Float, Float)] = []
        var dstPts: [(Float, Float)] = []
        srcPts.reserveCapacity(frameStars.count)
        dstPts.reserveCapacity(frameStars.count)

        for fs in frameStars {
            let (tx, ty) = initial.apply(fs.x, fs.y)
            var bestDist: Float = .greatestFiniteMagnitude
            var bestRef: (Float, Float) = (0, 0)
            for rs in refStars {
                let dx = tx - rs.x
                let dy = ty - rs.y
                let d = dx * dx + dy * dy
                if d < bestDist {
                    bestDist = d
                    bestRef = (rs.x, rs.y)
                }
            }
            if bestDist < threshSq {
                srcPts.append((fs.x, fs.y))
                dstPts.append(bestRef)
            }
        }

        guard srcPts.count >= 4 else { return nil }

        // Normal equations: AᵀA x = Aᵀb — same LHS matrix for both X and Y targets
        let n = Float(srcPts.count)
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        var sx: Float = 0, sy: Float = 0
        var sxX: Float = 0, syX: Float = 0, sX: Float = 0
        var sxY: Float = 0, syY: Float = 0, sY: Float = 0

        for i in 0..<srcPts.count {
            let (xi, yi) = srcPts[i]
            let (Xi, Yi) = dstPts[i]
            sxx += xi * xi; syy += yi * yi; sxy += xi * yi
            sx  += xi;      sy  += yi
            sxX += xi * Xi; syX += yi * Xi; sX  += Xi
            sxY += xi * Yi; syY += yi * Yi; sY  += Yi
        }

        let det = sxx * (syy * n - sy * sy)
                - sxy * (sxy * n - sy * sx)
                + sx  * (sxy * sy - syy * sx)
        guard Swift.abs(det) > 1e-6 else { return nil }
        let invDet = 1.0 / det

        let a  = ((syy * n - sy * sy) * sxX + (sy * sx - sxy * n) * syX + (sxy * sy - syy * sx) * sX) * invDet
        let b  = ((sy * sx - sxy * n) * sxX + (sxx * n - sx * sx) * syX + (sxy * sx - sxx * sy) * sX) * invDet
        let tx = ((sxy * sy - syy * sx) * sxX + (sxy * sx - sxx * sy) * syX + (sxx * syy - sxy * sxy) * sX) * invDet

        let c  = ((syy * n - sy * sy) * sxY + (sy * sx - sxy * n) * syY + (sxy * sy - syy * sx) * sY) * invDet
        let d  = ((sy * sx - sxy * n) * sxY + (sxx * n - sx * sx) * syY + (sxy * sx - sxx * sy) * sY) * invDet
        let ty = ((sxy * sy - syy * sx) * sxY + (sxy * sx - sxx * sy) * syY + (sxx * syy - sxy * sxy) * sY) * invDet

        let scaleX = (a * a + c * c).squareRoot()
        let scaleY = (b * b + d * d).squareRoot()
        guard scaleX > 0.95 && scaleX < 1.05 && scaleY > 0.95 && scaleY < 1.05 else { return nil }

        // Reject mirror transforms — see solveAffine() for rationale
        let determinant = a * d - b * c
        guard determinant > 0.95 && determinant < 1.05 else { return nil }

        return AffineTransform2D(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
    }

    /// Count frame stars that map to any reference star within `threshold` pixels.
    private func countInliers(
        transform: AffineTransform2D,
        refStars: [DetectedStar], frameStars: [DetectedStar],
        threshold: Float,
        limit: Int = Int.max
    ) -> Int {
        let threshSq = threshold * threshold
        var count = 0
        let maxFrame = min(frameStars.count, limit)
        let maxRef = min(refStars.count, limit)

        for i in 0..<maxFrame {
            let fs = frameStars[i]
            let (tx, ty) = transform.apply(fs.x, fs.y)
            for j in 0..<maxRef {
                let rs = refStars[j]
                let dx = tx - rs.x
                let dy = ty - rs.y
                if dx * dx + dy * dy < threshSq {
                    count += 1
                    break
                }
            }
        }
        return count
    }
}
