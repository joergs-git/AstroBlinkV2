// v3.2.0
import Foundation
import Metal
import Accelerate

// Quick Stack: fast-and-dirty image stacking without astrometric plate solving.
// Detects bright stars via threshold + blob detection on subsampled data,
// matches triangles formed by the brightest stars across frames,
// computes affine transforms for alignment, and median-combines aligned frames.
// Designed for visual impression — not science-grade stacking.

@MainActor
class QuickStackEngine: ObservableObject {

    // Progress reporting for the live mini preview
    enum Phase: String {
        case idle = ""
        case decoding = "Decoding frames..."
        case detecting = "Detecting stars..."
        case matching = "Matching star patterns..."
        case aligning = "Aligning frames..."
        case stacking = "Stacking..."
        case done = "Done"
        case failed = "Failed"
    }

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0   // 0.0–1.0
    @Published var currentLayer: Int = 0
    @Published var totalLayers: Int = 0
    @Published var miniPreviewTexture: MTLTexture?  // 200x200 live preview
    @Published var resultTexture: MTLTexture?        // Full-res stacked result
    @Published var errorMessage: String?
    @Published var resultWidth: Int = 0
    @Published var resultHeight: Int = 0
    // Detected star positions for the current frame (in preview coords 0–200)
    @Published var detectedStarPositions: [(x: CGFloat, y: CGFloat)] = []
    // Raw float result data + dimensions for external rendering (zoomable result window)
    var resultFloatData: [Float]?
    var resultChannelCount: Int = 1

    // Session metadata from stacked entries (for default filename generation)
    var stackedEntries: [ImageEntry] = []

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bin2xPipeline: MTLComputePipelineState?
    private var stackTask: Task<Void, Never>?

    // Star detection parameters (tuned for typical astro subs)
    private let maxStars = 50           // Keep brightest N stars per frame
    private let subsampleFactor = 4     // Detect on 1/4 resolution for speed
    private let sigmaThreshold: Float = 5.0  // Stars must be this many sigma above background

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        // Load bin2x kernel for halving resolution before stacking
        if let library = device.makeDefaultLibrary(),
           let bin2xFunc = library.makeFunction(name: "bin2x"),
           let pipe = try? device.makeComputePipelineState(function: bin2xFunc) {
            self.bin2xPipeline = pipe
        } else {
            self.bin2xPipeline = nil
        }
    }

    // Cancel any running stack operation
    func cancel() {
        stackTask?.cancel()
        stackTask = nil
        phase = .idle
    }

    // Start stacking the given image entries. Minimum 3 frames required.
    // Uses first frame as reference; all others are aligned to it.
    func startStack(entries: [ImageEntry], debayerEnabled: Bool) {
        guard entries.count >= 3 else {
            errorMessage = "Need at least 3 images to stack"
            phase = .failed
            return
        }

        totalLayers = entries.count
        currentLayer = 0
        errorMessage = nil
        phase = .decoding
        progress = 0
        stackedEntries = entries

        let capturedEntries = entries
        let capturedDebayer = debayerEnabled

        stackTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runStack(entries: capturedEntries, debayerEnabled: capturedDebayer)
        }
    }

    // GPU bin2x: halve resolution for faster stacking (returns new DecodedImage at half size)
    private func gpuBin2x(_ image: DecodedImage) -> DecodedImage? {
        guard let pipeline = bin2xPipeline else { return nil }
        let dstW = image.width / 2
        let dstH = image.height / 2
        let ch = image.channelCount
        guard dstW > 0, dstH > 0 else { return nil }

        let outSize = dstW * dstH * ch * MemoryLayout<UInt16>.size
        guard let outBuffer = device.makeBuffer(length: outSize, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        var sw = Int32(image.width), sh = Int32(image.height), cc = Int32(ch)
        encoder.setBytes(&sw, length: 4, index: 2)
        encoder.setBytes(&sh, length: 4, index: 3)
        encoder.setBytes(&cc, length: 4, index: 4)
        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let grid = MTLSize(width: (dstW + 31) / 32, height: (dstH + 31) / 32, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return DecodedImage(buffer: outBuffer, width: dstW, height: dstH, channelCount: ch)
    }

    // Main stacking pipeline — runs on MainActor but offloads heavy work via Task.detached
    // Uses GPU bin2x to halve resolution before stacking for ~4x speed improvement
    private func runStack(entries: [ImageEntry], debayerEnabled: Bool) async {
        // Step 1: Decode all frames and bin2x for speed
        phase = .decoding
        var frames: [(decoded: DecodedImage, entry: ImageEntry)] = []

        for (i, entry) in entries.enumerated() {
            guard !Task.isCancelled else { phase = .idle; return }
            progress = Double(i) / Double(entries.count) * 0.2

            let decodeURL = entry.decodingURL
            let result = await Task.detached(priority: .userInitiated) {
                ImageDecoder.decode(url: decodeURL, device: self.device)
            }.value

            switch result {
            case .success(let decoded):
                // Apply GPU bin2x to halve resolution (4x fewer pixels to align/stack)
                let binned = gpuBin2x(decoded) ?? decoded
                frames.append((binned, entry))
            case .failure(let error):
                print("[QuickStack] Failed to decode \(entry.filename): \(error)")
            }
        }

        guard frames.count >= 3 else {
            errorMessage = "Only \(frames.count) frames decoded — need at least 3"
            phase = .failed
            return
        }

        // Ensure all frames have the same dimensions
        let refWidth = frames[0].decoded.width
        let refHeight = frames[0].decoded.height
        frames = frames.filter { $0.decoded.width == refWidth && $0.decoded.height == refHeight }
        guard frames.count >= 3 else {
            errorMessage = "Frames have different dimensions — cannot stack"
            phase = .failed
            return
        }

        // Step 2: Detect stars in each frame and show crosses in preview
        phase = .detecting
        var allStars: [[Star]] = []

        for (i, frame) in frames.enumerated() {
            guard !Task.isCancelled else { phase = .idle; return }
            progress = 0.2 + Double(i) / Double(frames.count) * 0.2

            let stars = await Task.detached(priority: .userInitiated) {
                self.detectStars(in: frame.decoded)
            }.value

            allStars.append(stars)

            // Show detected star positions as blue crosses in the mini preview
            let previewScale = 200.0 / max(CGFloat(refWidth), CGFloat(refHeight))
            detectedStarPositions = stars.prefix(30).map { star in
                (x: CGFloat(star.x) * previewScale, y: CGFloat(star.y) * previewScale)
            }

            print("[QuickStack] Frame \(i): detected \(stars.count) stars")
        }

        // Clear star crosses after detection phase
        detectedStarPositions = []

        // Verify we have enough stars in reference frame
        guard allStars[0].count >= 3 else {
            errorMessage = "Reference frame has too few stars (\(allStars[0].count)) — need at least 3"
            phase = .failed
            return
        }

        // Step 3: Match star patterns and compute affine transforms
        phase = .matching
        let refStars = allStars[0]
        let refTriangles = buildTriangles(from: refStars)
        var transforms: [AffineTransform2D?] = [nil] // Reference = identity (index 0)

        for i in 1..<frames.count {
            guard !Task.isCancelled else { phase = .idle; return }
            progress = 0.4 + Double(i) / Double(frames.count) * 0.2

            let frameStars = allStars[i]
            if frameStars.count < 3 {
                print("[QuickStack] Frame \(i): too few stars (\(frameStars.count)), skipping")
                transforms.append(nil)
                continue
            }

            let frameTriangles = buildTriangles(from: frameStars)
            if let transform = matchTriangles(ref: refTriangles, refStars: refStars,
                                               frame: frameTriangles, frameStars: frameStars) {
                transforms.append(transform)
                print("[QuickStack] Frame \(i): matched — dx=\(String(format: "%.1f", transform.tx)), dy=\(String(format: "%.1f", transform.ty)), rot=\(String(format: "%.2f°", transform.rotation * 180 / .pi))")
            } else {
                print("[QuickStack] Frame \(i): no match found")
                transforms.append(nil)
            }
        }

        // Count successful alignments
        let alignedCount = transforms.compactMap({ $0 }).count + 1 // +1 for reference
        guard alignedCount >= 3 else {
            errorMessage = "Only \(alignedCount) frames aligned — need at least 3. Star patterns may be too different."
            phase = .failed
            return
        }

        // Step 4: Warp + accumulate aligned frames into a running median
        phase = .aligning
        totalLayers = alignedCount
        currentLayer = 0

        // Accumulator: float buffer for running average (faster than true median for preview)
        let pixelCount = refWidth * refHeight
        let channelCount = frames[0].decoded.channelCount
        let totalFloats = pixelCount * channelCount
        var accumulator = [Float](repeating: 0, count: totalFloats)
        var weightMap = [Float](repeating: 0, count: pixelCount)

        for (i, frame) in frames.enumerated() {
            guard !Task.isCancelled else { phase = .idle; return }

            let transform = i == 0 ? AffineTransform2D.identity : transforms[i]
            guard let xform = transform else { continue } // Skip unmatched frames

            currentLayer += 1
            progress = 0.6 + Double(currentLayer) / Double(alignedCount) * 0.3
            phase = .aligning

            // Warp and accumulate on background thread
            await Task.detached(priority: .userInitiated) {
                self.warpAndAccumulate(
                    source: frame.decoded,
                    transform: xform,
                    into: &accumulator,
                    weights: &weightMap,
                    width: refWidth,
                    height: refHeight,
                    channelCount: channelCount
                )
            }.value

            // Update mini preview after each layer
            await updateMiniPreview(
                accumulator: accumulator,
                weights: weightMap,
                width: refWidth,
                height: refHeight,
                channelCount: channelCount
            )
        }

        // Step 5: Normalize and produce final result
        guard !Task.isCancelled else { phase = .idle; return }
        phase = .stacking
        progress = 0.95

        // Normalize accumulator by weight
        for px in 0..<pixelCount {
            let w = max(weightMap[px], 1.0)
            for ch in 0..<channelCount {
                accumulator[ch * pixelCount + px] /= w
            }
        }

        // Convert to uint16 texture for display
        let resultTex = createResultTexture(
            from: accumulator,
            width: refWidth,
            height: refHeight,
            channelCount: channelCount
        )

        // Store raw float data for the zoomable/stretchable result window
        resultFloatData = accumulator
        resultChannelCount = channelCount

        resultTexture = resultTex
        resultWidth = refWidth
        resultHeight = refHeight
        phase = .done
        progress = 1.0
    }

    // MARK: - Star Detection (delegates to shared StarDetector)

    // Type alias for compatibility with triangle matching code
    typealias Star = DetectedStar

    private nonisolated func detectStars(in image: DecodedImage) -> [Star] {
        return StarDetector.detectStars(
            in: image,
            maxStars: maxStars,
            subsampleFactor: subsampleFactor,
            sigmaThreshold: sigmaThreshold
        )
    }

    // MARK: - Triangle Matching

    // A triangle formed by 3 stars, characterized by side ratios for scale-invariant matching
    struct Triangle {
        let i0: Int, i1: Int, i2: Int   // Indices into star array
        let ratios: (Float, Float)        // (side2/side1, side3/side1) — sorted sides
        let orientation: Float            // Angle of longest side (for rotation estimate)
    }

    // Build triangles from the brightest stars (combinatorial but limited to top ~15)
    private nonisolated func buildTriangles(from stars: [Star]) -> [Triangle] {
        let n = min(stars.count, 15)  // Limit combinations
        var triangles: [Triangle] = []

        for i in 0..<n {
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    let dx01 = stars[j].x - stars[i].x
                    let dy01 = stars[j].y - stars[i].y
                    let d01 = sqrtf(dx01 * dx01 + dy01 * dy01)

                    let dx02 = stars[k].x - stars[i].x
                    let dy02 = stars[k].y - stars[i].y
                    let d02 = sqrtf(dx02 * dx02 + dy02 * dy02)

                    let dx12 = stars[k].x - stars[j].x
                    let dy12 = stars[k].y - stars[j].y
                    let d12 = sqrtf(dx12 * dx12 + dy12 * dy12)

                    // Sort sides: longest first
                    var sides = [(d01, i, j), (d02, i, k), (d12, j, k)]
                    sides.sort { $0.0 > $1.0 }

                    let longest = sides[0].0
                    guard longest > 10 else { continue } // Skip tiny triangles

                    let r1 = sides[1].0 / longest
                    let r2 = sides[2].0 / longest

                    // Orientation: angle of the longest side
                    let longestDx = stars[sides[0].2].x - stars[sides[0].1].x
                    let longestDy = stars[sides[0].2].y - stars[sides[0].1].y
                    let angle = atan2f(longestDy, longestDx)

                    triangles.append(Triangle(
                        i0: sides[0].1, i1: sides[0].2, i2: sides[2].1 == sides[0].1 || sides[2].1 == sides[0].2 ? sides[2].2 : sides[2].1,
                        ratios: (r1, r2),
                        orientation: angle
                    ))
                }
            }
        }

        return triangles
    }

    // Match triangles between reference and target frame, return best affine transform
    private nonisolated func matchTriangles(ref: [Triangle], refStars: [Star],
                                 frame: [Triangle], frameStars: [Star]) -> AffineTransform2D? {
        let ratioTolerance: Float = 0.05  // 5% tolerance on side ratios

        var bestInliers = 0
        var bestTransform: AffineTransform2D?

        for rt in ref {
            for ft in frame {
                // Check if triangle ratios match
                let dr1 = abs(rt.ratios.0 - ft.ratios.0)
                let dr2 = abs(rt.ratios.1 - ft.ratios.1)
                guard dr1 < ratioTolerance && dr2 < ratioTolerance else { continue }

                // Try to compute affine from the 3 matched star pairs
                let refPts = [
                    (refStars[rt.i0].x, refStars[rt.i0].y),
                    (refStars[rt.i1].x, refStars[rt.i1].y),
                    (refStars[rt.i2].x, refStars[rt.i2].y)
                ]
                let framePts = [
                    (frameStars[ft.i0].x, frameStars[ft.i0].y),
                    (frameStars[ft.i1].x, frameStars[ft.i1].y),
                    (frameStars[ft.i2].x, frameStars[ft.i2].y)
                ]

                guard let transform = solveAffine(from: framePts, to: refPts) else { continue }

                // Count inliers: how many stars in this frame map close to a reference star
                let inliers = countInliers(transform: transform,
                                            refStars: refStars, frameStars: frameStars,
                                            threshold: 10.0)

                if inliers > bestInliers {
                    bestInliers = inliers
                    bestTransform = transform
                }
            }
        }

        // Require at least 3 inlier matches for a valid alignment
        return bestInliers >= 3 ? bestTransform : nil
    }

    // Count how many frame stars, after transform, land near a reference star
    private nonisolated func countInliers(transform: AffineTransform2D,
                               refStars: [Star], frameStars: [Star],
                               threshold: Float) -> Int {
        let threshSq = threshold * threshold
        var count = 0

        for fs in frameStars {
            let (tx, ty) = transform.apply(fs.x, fs.y)
            for rs in refStars {
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

    // MARK: - Affine Transform

    // 2D affine transform: rotation + translation + scale
    // [a  b  tx]   [x]
    // [c  d  ty] * [y]
    // [0  0   1]   [1]
    struct AffineTransform2D {
        let a: Float, b: Float, tx: Float
        let c: Float, d: Float, ty: Float

        static let identity = AffineTransform2D(a: 1, b: 0, tx: 0, c: 0, d: 1, ty: 0)

        var rotation: Float { atan2f(c, a) }
        var scale: Float { sqrtf(a * a + c * c) }

        func apply(_ x: Float, _ y: Float) -> (Float, Float) {
            return (a * x + b * y + tx, c * x + d * y + ty)
        }

        // Inverse transform for backward mapping (sampling source at destination coords)
        var inverse: AffineTransform2D? {
            let det = a * d - b * c
            guard abs(det) > 1e-6 else { return nil }
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
    }

    // Solve affine transform from 3 point pairs using direct linear solve
    // Maps source points to destination points
    private nonisolated func solveAffine(from src: [(Float, Float)], to dst: [(Float, Float)]) -> AffineTransform2D? {
        guard src.count == 3, dst.count == 3 else { return nil }

        // Solve two 3x3 systems:
        // [x0 y0 1] [a]   [X0]       [x0 y0 1] [c]   [Y0]
        // [x1 y1 1] [b] = [X1]  and  [x1 y1 1] [d] = [Y1]
        // [x2 y2 1] [tx]  [X2]       [x2 y2 1] [ty]  [Y2]

        let x0 = src[0].0, y0 = src[0].1
        let x1 = src[1].0, y1 = src[1].1
        let x2 = src[2].0, y2 = src[2].1

        // Determinant of the source matrix
        let det = x0 * (y1 - y2) - y0 * (x1 - x2) + (x1 * y2 - x2 * y1)
        guard abs(det) > 1e-6 else { return nil }
        let invDet = 1.0 / det

        // Compute inverse of source matrix
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

        // Sanity check: scale should be roughly 1.0 (same focal length / sensor)
        let scale = sqrtf(a * a + c * c)
        guard scale > 0.8 && scale < 1.2 else { return nil }

        return AffineTransform2D(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
    }

    // MARK: - Warp and Accumulate

    // Apply affine warp (backward mapping) and accumulate into running sum
    // Uses bilinear interpolation for sub-pixel accuracy
    private nonisolated func warpAndAccumulate(
        source: DecodedImage,
        transform: AffineTransform2D,
        into accumulator: inout [Float],
        weights: inout [Float],
        width: Int, height: Int, channelCount: Int
    ) {
        let srcPtr = source.buffer.contents().bindMemory(to: UInt16.self, capacity: source.pixelCount)
        let planeSize = width * height
        let inv = transform.inverse ?? .identity

        for y in 0..<height {
            for x in 0..<width {
                // Backward map: find source coordinate for this destination pixel
                let (sx, sy) = inv.apply(Float(x), Float(y))

                // Bounds check with 1px margin for bilinear interpolation
                guard sx >= 0 && sx < Float(width - 1) && sy >= 0 && sy < Float(height - 1) else { continue }

                // Bilinear interpolation
                let ix = Int(sx)
                let iy = Int(sy)
                let fx = sx - Float(ix)
                let fy = sy - Float(iy)
                let w00 = (1 - fx) * (1 - fy)
                let w10 = fx * (1 - fy)
                let w01 = (1 - fx) * fy
                let w11 = fx * fy

                let dstIdx = y * width + x

                for ch in 0..<channelCount {
                    let chOff = ch * planeSize
                    let v00 = Float(srcPtr[chOff + iy * width + ix])
                    let v10 = Float(srcPtr[chOff + iy * width + ix + 1])
                    let v01 = Float(srcPtr[chOff + (iy + 1) * width + ix])
                    let v11 = Float(srcPtr[chOff + (iy + 1) * width + ix + 1])

                    let interpolated = v00 * w00 + v10 * w10 + v01 * w01 + v11 * w11
                    accumulator[ch * planeSize + dstIdx] += interpolated
                }

                weights[dstIdx] += 1.0
            }
        }
    }

    // MARK: - Preview Generation

    // Create a 200x200 mini preview texture from the current accumulator state
    private func updateMiniPreview(
        accumulator: [Float],
        weights: [Float],
        width: Int, height: Int, channelCount: Int
    ) async {
        let previewSize = 200
        let planeSize = width * height

        // Compute normalized + STF-stretched preview at 200x200
        var previewPixels = [UInt8](repeating: 0, count: previewSize * previewSize * 4)

        let scaleX = Float(width) / Float(previewSize)
        let scaleY = Float(height) / Float(previewSize)

        // Quick stats for auto-stretch of the accumulated data
        let sampleCount = min(10000, planeSize)
        let sampleStride = max(1, planeSize / sampleCount)
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)

        for i in stride(from: 0, to: planeSize, by: sampleStride) {
            let w = max(weights[i], 1.0)
            samples.append(accumulator[i] / w / 65535.0)
        }
        vDSP_vsort(&samples, vDSP_Length(samples.count), 1)
        let median = samples[samples.count / 2]
        let negMed = -median
        var devs = samples
        vDSP_vsadd(devs, 1, [negMed], &devs, 1, vDSP_Length(devs.count))
        vDSP_vabs(devs, 1, &devs, 1, vDSP_Length(devs.count))
        vDSP_vsort(&devs, vDSP_Length(devs.count), 1)
        let mad = 1.4826 * devs[devs.count / 2]
        let c0 = max(0.0, min(1.0, median - 1.25 * mad))
        let mNorm = (median - c0) / max(1.0 - c0, 0.001)
        let mb = mNorm > 0 && mNorm < 1 ? mNorm * (1 - 0.25) / (mNorm * (1 - 2 * 0.25) + 0.25) : 0.5

        for py in 0..<previewSize {
            for px in 0..<previewSize {
                let srcX = Int(Float(px) * scaleX)
                let srcY = Int(Float(py) * scaleY)
                let srcIdx = min(srcY * width + srcX, planeSize - 1)
                let w = max(weights[srcIdx], 1.0)

                let outIdx = (py * previewSize + px) * 4

                if channelCount == 1 {
                    var v = accumulator[srcIdx] / w / 65535.0
                    v = max(0, min(1, (v - c0) / max(1 - c0, 0.001)))
                    v = mtfApply(v, mb)
                    let byte = UInt8(max(0, min(255, v * 255)))
                    previewPixels[outIdx] = byte     // B
                    previewPixels[outIdx + 1] = byte // G
                    previewPixels[outIdx + 2] = byte // R
                } else {
                    for ch in 0..<min(channelCount, 3) {
                        var v = accumulator[ch * planeSize + srcIdx] / w / 65535.0
                        v = max(0, min(1, (v - c0) / max(1 - c0, 0.001)))
                        v = mtfApply(v, mb)
                        // BGRA layout: ch0=R→idx+2, ch1=G→idx+1, ch2=B→idx+0
                        let bgraIdx = ch == 0 ? 2 : (ch == 1 ? 1 : 0)
                        previewPixels[outIdx + bgraIdx] = UInt8(max(0, min(255, v * 255)))
                    }
                }
                previewPixels[outIdx + 3] = 255  // Alpha
            }
        }

        // Create texture from pixel data
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: previewSize, height: previewSize,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]

        if let tex = device.makeTexture(descriptor: texDesc) {
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: previewSize, height: previewSize, depth: 1)),
                mipmapLevel: 0,
                withBytes: previewPixels,
                bytesPerRow: previewSize * 4
            )
            miniPreviewTexture = tex
        }
    }

    // MTF helper for preview stretch
    private nonisolated func mtfApply(_ x: Float, _ m: Float) -> Float {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if x == m { return 0.5 }
        return (m - 1) * x / ((2 * m - 1) * x - m)
    }

    // MARK: - Result Texture

    // Convert normalized float accumulator to a BGRA8 texture with STF auto-stretch
    private func createResultTexture(
        from data: [Float],
        width: Int, height: Int, channelCount: Int
    ) -> MTLTexture? {
        let planeSize = width * height

        // Compute STF params from the stacked result
        let sampleCount = min(50000, planeSize)
        let sampleStride = max(1, planeSize / sampleCount)
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)

        for i in stride(from: 0, to: planeSize, by: sampleStride) {
            samples.append(data[i] / 65535.0)
        }
        vDSP_vsort(&samples, vDSP_Length(samples.count), 1)
        let median = samples[samples.count / 2]
        let negMed = -median
        var devs = samples
        vDSP_vsadd(devs, 1, [negMed], &devs, 1, vDSP_Length(devs.count))
        vDSP_vabs(devs, 1, &devs, 1, vDSP_Length(devs.count))
        vDSP_vsort(&devs, vDSP_Length(devs.count), 1)
        let mad = 1.4826 * devs[devs.count / 2]
        let c0 = max(0.0, min(1.0, median - 1.25 * mad))
        let mNorm = (median - c0) / max(1.0 - c0, 0.001)
        let mb = mNorm > 0 && mNorm < 1 ? mNorm * (1 - 0.25) / (mNorm * (1 - 2 * 0.25) + 0.25) : 0.5

        // Build BGRA8 pixel buffer
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let outIdx = idx * 4

                if channelCount == 1 {
                    var v = data[idx] / 65535.0
                    v = max(0, min(1, (v - c0) / max(1 - c0, 0.001)))
                    v = mtfApply(v, mb)
                    let byte = UInt8(max(0, min(255, v * 255)))
                    pixels[outIdx] = byte     // B
                    pixels[outIdx + 1] = byte // G
                    pixels[outIdx + 2] = byte // R
                } else {
                    for ch in 0..<min(channelCount, 3) {
                        var v = data[ch * planeSize + idx] / 65535.0
                        v = max(0, min(1, (v - c0) / max(1 - c0, 0.001)))
                        v = mtfApply(v, mb)
                        let bgraIdx = ch == 0 ? 2 : (ch == 1 ? 1 : 0)
                        pixels[outIdx + bgraIdx] = UInt8(max(0, min(255, v * 255)))
                    }
                }
                pixels[outIdx + 3] = 255
            }
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]

        guard let tex = device.makeTexture(descriptor: texDesc) else { return nil }
        tex.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )

        return tex
    }
}
