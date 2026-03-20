// v4.4.0 — Quick Stack V2: Optimized stacking pipeline
// Key improvements over V1:
// 1. GPU warp+accumulate via Metal compute kernel (10-20x faster than CPU)
// 2. Parallel star detection across all frames (TaskGroup)
// 3. Hash-based triangle matching (O(1) lookup instead of O(N²) brute force)
// 4. Reduced star/triangle count for preview-quality matching
// 5. vDSP vectorized normalization
// 6. Mini preview updates every 3rd frame (not every frame)
// 7. Min/max pixel rejection — removes satellite trails and hot pixels
// 8. Lanczos-3 interpolation option — sharper on large dithers
// 9. Adaptive triangle matching with retry for wide dither patterns

import Foundation
import Metal
import Accelerate

@MainActor
class QuickStackEngineV2: ObservableObject {

    // Reuse same Phase enum and published state as V1 for UI compatibility
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

    enum InterpolationMode: String, CaseIterable {
        case bilinear = "Bilinear"
        case lanczos = "Lanczos-3"
    }

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var currentLayer: Int = 0
    @Published var totalLayers: Int = 0
    @Published var miniPreviewTexture: MTLTexture?
    @Published var resultTexture: MTLTexture?
    @Published var errorMessage: String?
    @Published var resultWidth: Int = 0
    @Published var resultHeight: Int = 0
    @Published var detectedStarPositions: [(x: CGFloat, y: CGFloat)] = []
    // Source image dimensions for correct preview aspect ratio (set after first decode)
    @Published var sourceWidth: Int = 0
    @Published var sourceHeight: Int = 0
    @Published var alignmentInfo: String = ""
    var resultFloatData: [Float]?
    var resultChannelCount: Int = 1
    var stackedEntries: [ImageEntry] = []
    // Average FWHM from stacked frames (for Wiener deconvolution PSF estimation)
    var averageFWHM: Double? {
        let fwhms = stackedEntries.compactMap { $0.computedFWHM ?? $0.fwhm.map { Double($0) } }
        guard !fwhms.isEmpty else { return nil }
        return fwhms.reduce(0, +) / Double(fwhms.count) / 2.0  // bin2x halves the FWHM
    }
    var interpolationMode: InterpolationMode = .bilinear

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bin2xPipeline: MTLComputePipelineState?
    private let warpPipeline: MTLComputePipelineState?
    private let warpLanczosPipeline: MTLComputePipelineState?
    private let debayerPipeline: MTLComputePipelineState?
    private let cosmeticPipeline: MTLComputePipelineState?
    private var stackTask: Task<Void, Never>?

    // V2 tuning: 80 detected stars for robust field coverage and LS refinement.
    // 20 triangle stars → C(20,3) = 1140 triangles (still fast, better coverage for wide dithers).
    // More detected stars means more inlier candidates → better refinement accuracy.
    private let maxStars = 80
    private let triangleStarLimit = 20
    private let inlierCheckLimit = 50      // Cap for O(N²) inlier counting during matching
    private let subsampleFactor = 2         // Half-res detection (was 4) — 4× finer star positions
    private let sigmaThreshold: Float = 5.0

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            self.bin2xPipeline = nil
            self.warpPipeline = nil
            self.warpLanczosPipeline = nil
            self.cosmeticPipeline = nil
            return nil
        }

        // Load GPU kernels
        if let bin2xFunc = library.makeFunction(name: "bin2x"),
           let pipe = try? device.makeComputePipelineState(function: bin2xFunc) {
            self.bin2xPipeline = pipe
        } else {
            self.bin2xPipeline = nil
        }

        if let warpFunc = library.makeFunction(name: "warp_accumulate"),
           let pipe = try? device.makeComputePipelineState(function: warpFunc) {
            self.warpPipeline = pipe
        } else {
            self.warpPipeline = nil
        }

        if let lanczosFunc = library.makeFunction(name: "warp_accumulate_lanczos"),
           let pipe = try? device.makeComputePipelineState(function: lanczosFunc) {
            self.warpLanczosPipeline = pipe
        } else {
            self.warpLanczosPipeline = nil
        }

        if let debayerFunc = library.makeFunction(name: "debayer_bilinear"),
           let pipe = try? device.makeComputePipelineState(function: debayerFunc) {
            self.debayerPipeline = pipe
        } else {
            self.debayerPipeline = nil
        }

        if let cosmeticFunc = library.makeFunction(name: "cosmetic_correction"),
           let pipe = try? device.makeComputePipelineState(function: cosmeticFunc) {
            self.cosmeticPipeline = pipe
        } else {
            self.cosmeticPipeline = nil
        }
    }

    func cancel() {
        stackTask?.cancel()
        stackTask = nil
        phase = .idle
    }

    func startStack(entries: [ImageEntry], debayerEnabled: Bool) {
        guard entries.count >= 3 else {
            errorMessage = "Need at least 3 images to stack"
            phase = .failed
            return
        }

        // Cancel any previous run before resetting state
        stackTask?.cancel()
        stackTask = nil

        // Clear stale preview from previous run
        miniPreviewTexture = nil
        detectedStarPositions = []

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

    // MARK: - GPU Bin2x (same as V1)

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

    // MARK: - GPU Debayer (bilinear interpolation, CFA → RGB)

    private static let bayerPatternMap: [String: Int] = [
        "RGGB": 0, "GRBG": 1, "GBRG": 2, "BGGR": 3
    ]

    private func gpuDebayer(_ image: DecodedImage, pattern: String) -> DecodedImage? {
        guard let pipeline = debayerPipeline,
              image.channelCount == 1,
              let patternIndex = Self.bayerPatternMap[pattern.uppercased()] else { return nil }

        let outputSize = image.width * image.height * 3 * MemoryLayout<UInt16>.size
        guard let outputBuffer = device.makeBuffer(length: outputSize, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        var w = Int32(image.width), h = Int32(image.height), pat = Int32(patternIndex)
        encoder.setBytes(&w, length: 4, index: 2)
        encoder.setBytes(&h, length: 4, index: 3)
        encoder.setBytes(&pat, length: 4, index: 4)
        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let grid = MTLSize(width: (image.width + 31) / 32, height: (image.height + 31) / 32, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return DecodedImage(buffer: outputBuffer, width: image.width, height: image.height, channelCount: 3)
    }

    // MARK: - GPU Cosmetic Correction (hot/cold pixel rejection)

    private func gpuCosmeticCorrection(_ image: DecodedImage) -> DecodedImage? {
        guard let pipeline = cosmeticPipeline else { return nil }

        let totalBytes = image.width * image.height * image.channelCount * MemoryLayout<UInt16>.size
        guard let outBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        // Pack CosmeticParams struct (matches Metal side: 3 ints)
        var params = (Int32(image.width), Int32(image.height), Int32(image.channelCount))

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 2)

        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let grid = MTLSize(width: (image.width + 31) / 32, height: (image.height + 31) / 32, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return DecodedImage(buffer: outBuffer, width: image.width, height: image.height, channelCount: image.channelCount)
    }

    // MARK: - Main Pipeline

    private func runStack(entries: [ImageEntry], debayerEnabled: Bool) async {
        // Step 1: Decode + bin2x (same as V1)
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
                // Cosmetic correction: reject hot/cold pixels before any further processing
                let corrected = gpuCosmeticCorrection(decoded) ?? decoded
                // Debayer OSC images before binning (CFA mono → RGB)
                var processed = corrected
                if debayerEnabled, let pattern = entry.bayerPattern, corrected.channelCount == 1 {
                    if let debayered = gpuDebayer(corrected, pattern: pattern) {
                        processed = debayered
                    }
                }
                let binned = gpuBin2x(processed) ?? processed
                frames.append((binned, entry))
            case .failure(let error):
                errorMessage = "Decode error: \(error.localizedDescription)"
                phase = .failed
                return
            }
        }

        guard frames.count >= 3 else {
            errorMessage = "Need at least 3 decodable frames"
            phase = .failed
            return
        }

        // Filter to matching dimensions
        let refWidth = frames[0].decoded.width
        let refHeight = frames[0].decoded.height
        sourceWidth = refWidth
        sourceHeight = refHeight
        frames = frames.filter { $0.decoded.width == refWidth && $0.decoded.height == refHeight }

        guard frames.count >= 3 else {
            errorMessage = "Less than 3 frames with matching dimensions"
            phase = .failed
            return
        }

        // Step 2: PARALLEL star detection + full-res centroid refinement
        // Detect on subsample=2 of binned image, then refine on full binned resolution
        // for sub-pixel accuracy in the coordinate space the warp kernel uses.
        phase = .detecting
        progress = 0.25

        let allStars: [[Star]] = await withTaskGroup(of: (Int, [Star]).self) { group in
            for (i, frame) in frames.enumerated() {
                group.addTask { [self] in
                    // Coarse detection on subsampled data
                    let coarse = self.detectStars(in: frame.decoded)
                    // Refine centroids on full binned-resolution data (9×9 window)
                    let refined = StarDetector.refinePositions(
                        stars: coarse, in: frame.decoded, radius: 4
                    )
                    return (i, refined)
                }
            }
            var results = Array(repeating: [Star](), count: frames.count)
            for await (index, stars) in group {
                results[index] = stars
            }
            return results
        }

        // Update mini preview with detected stars from reference frame
        let refStars = allStars[0]
        if !refStars.isEmpty {
            let previewScale = 200.0 / max(CGFloat(refWidth), CGFloat(refHeight))
            detectedStarPositions = refStars.prefix(20).map {
                (x: CGFloat($0.x) * previewScale, y: CGFloat($0.y) * previewScale)
            }
        }

        guard refStars.count >= 3 else {
            errorMessage = "Not enough stars detected in reference frame"
            phase = .failed
            return
        }

        // Step 3: Hash-based triangle matching (V2 optimization)
        phase = .matching
        progress = 0.35

        let refTriangles = buildTriangles(from: refStars, limit: triangleStarLimit)
        // Build hash index from reference triangles
        let refIndex = buildTriangleIndex(from: refTriangles)

        // Also build wider triangle sets for retry on alignment failure (M81 fix)
        let retryLimit = 25
        let retryRefTriangles = buildTriangles(from: refStars, limit: retryLimit)
        let retryRefIndex = buildTriangleIndex(from: retryRefTriangles)

        var transforms: [AffineTransform2D?] = [AffineTransform2D.identity] // Reference = identity

        for i in 1..<frames.count {
            guard !Task.isCancelled else { phase = .idle; return }
            let frameStars = allStars[i]
            if frameStars.count < 3 {
                transforms.append(nil)
                continue
            }

            let frameTriangles = buildTriangles(from: frameStars, limit: triangleStarLimit)
            // Use hash-based matching instead of brute force
            if let transform = matchTrianglesHashed(
                refIndex: refIndex, refTriangles: refTriangles, refStars: refStars,
                frameTriangles: frameTriangles, frameStars: frameStars,
                inlierThreshold: 10.0
            ) {
                transforms.append(transform)
            } else {
                // Retry with wider triangle set and looser threshold for large dither patterns
                let retryFrameTriangles = buildTriangles(from: frameStars, limit: retryLimit)
                if let transform = matchTrianglesHashed(
                    refIndex: retryRefIndex, refTriangles: retryRefTriangles, refStars: refStars,
                    frameTriangles: retryFrameTriangles, frameStars: frameStars,
                    inlierThreshold: 15.0
                ) {
                    transforms.append(transform)
                } else {
                    transforms.append(nil)
                }
            }
        }

        let alignedCount = transforms.compactMap({ $0 }).count
        let failedCount = frames.count - alignedCount

        alignmentInfo = failedCount > 0
            ? "Aligned \(alignedCount) of \(frames.count) frames (\(failedCount) skipped)"
            : "Aligned all \(alignedCount) frames"

        guard alignedCount >= 2 else {
            errorMessage = "Could not align enough frames (\(alignedCount)/\(frames.count), \(failedCount) failed)"
            phase = .failed
            return
        }

        // Step 4: GPU warp + accumulate (V2 optimization — main speedup)
        phase = .aligning
        totalLayers = alignedCount
        currentLayer = 0

        let channelCount = frames[0].decoded.channelCount
        let pixelCount = refWidth * refHeight
        let totalFloats = pixelCount * channelCount

        // Create GPU buffers for accumulator, weights, and min/max rejection
        let accByteCount = totalFloats * MemoryLayout<Float>.size
        let wgtByteCount = pixelCount * MemoryLayout<Float>.size
        let minMaxByteCount = totalFloats * MemoryLayout<Float>.size

        guard let accBuffer = device.makeBuffer(length: accByteCount, options: .storageModeShared),
              let wgtBuffer = device.makeBuffer(length: wgtByteCount, options: .storageModeShared),
              let minBuffer = device.makeBuffer(length: minMaxByteCount, options: .storageModeShared),
              let maxBuffer = device.makeBuffer(length: minMaxByteCount, options: .storageModeShared) else {
            errorMessage = "Failed to allocate GPU buffers"
            phase = .failed
            return
        }

        // Zero-fill accumulator and weights; init min to FLT_MAX, max to -FLT_MAX
        memset(accBuffer.contents(), 0, accByteCount)
        memset(wgtBuffer.contents(), 0, wgtByteCount)
        // Min/max initialization happens in shader on first write (when weight==0)

        for (i, frame) in frames.enumerated() {
            guard !Task.isCancelled else { phase = .idle; return }

            let transform = i == 0 ? AffineTransform2D.identity : transforms[i]
            guard let xform = transform else { continue }

            currentLayer += 1
            progress = 0.5 + Double(currentLayer) / Double(alignedCount) * 0.4

            // GPU warp: dispatch Metal compute kernel (bilinear or Lanczos-3)
            let activePipeline = interpolationMode == .lanczos ? (warpLanczosPipeline ?? warpPipeline) : warpPipeline
            if let activePipeline = activePipeline {
                let inv = xform.inverse ?? .identity

                guard let cmdBuf = commandQueue.makeCommandBuffer(),
                      let encoder = cmdBuf.makeComputeCommandEncoder() else { continue }

                // Pack affine params for Metal (matches AffineParams struct in shader)
                var params = (inv.a, inv.b, inv.tx, inv.c, inv.d, inv.ty)
                var w = Int32(refWidth), h = Int32(refHeight), cc = Int32(channelCount)

                encoder.setComputePipelineState(activePipeline)
                encoder.setBuffer(frame.decoded.buffer, offset: 0, index: 0)
                encoder.setBuffer(accBuffer, offset: 0, index: 1)
                encoder.setBuffer(wgtBuffer, offset: 0, index: 2)
                encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 3)
                encoder.setBytes(&w, length: 4, index: 4)
                encoder.setBytes(&h, length: 4, index: 5)
                encoder.setBytes(&cc, length: 4, index: 6)
                encoder.setBuffer(minBuffer, offset: 0, index: 7)
                encoder.setBuffer(maxBuffer, offset: 0, index: 8)

                let tg = MTLSize(width: 32, height: 32, depth: 1)
                let grid = MTLSize(width: (refWidth + 31) / 32, height: (refHeight + 31) / 32, depth: 1)
                encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                encoder.endEncoding()
                cmdBuf.commit()
                cmdBuf.waitUntilCompleted()
            } else {
                // Fallback: CPU warp with min/max tracking
                let accPtrCPU = accBuffer.contents().bindMemory(to: Float.self, capacity: totalFloats)
                let wgtPtrCPU = wgtBuffer.contents().bindMemory(to: Float.self, capacity: pixelCount)
                let minPtrCPU = minBuffer.contents().bindMemory(to: Float.self, capacity: totalFloats)
                let maxPtrCPU = maxBuffer.contents().bindMemory(to: Float.self, capacity: totalFloats)
                var accArray = Array(UnsafeBufferPointer(start: accPtrCPU, count: totalFloats))
                var wgtArray = Array(UnsafeBufferPointer(start: wgtPtrCPU, count: pixelCount))
                var minArray = Array(UnsafeBufferPointer(start: minPtrCPU, count: totalFloats))
                var maxArray = Array(UnsafeBufferPointer(start: maxPtrCPU, count: totalFloats))

                warpAndAccumulateCPU(
                    source: frame.decoded, transform: xform,
                    into: &accArray, weights: &wgtArray,
                    minValues: &minArray, maxValues: &maxArray,
                    width: refWidth, height: refHeight, channelCount: channelCount
                )

                accArray.withUnsafeBufferPointer { src in
                    memcpy(accBuffer.contents(), src.baseAddress!, accByteCount)
                }
                wgtArray.withUnsafeBufferPointer { src in
                    memcpy(wgtBuffer.contents(), src.baseAddress!, wgtByteCount)
                }
                minArray.withUnsafeBufferPointer { src in
                    memcpy(minBuffer.contents(), src.baseAddress!, minMaxByteCount)
                }
                maxArray.withUnsafeBufferPointer { src in
                    memcpy(maxBuffer.contents(), src.baseAddress!, minMaxByteCount)
                }
            }

            // Mini preview: every 3rd frame or first/last (V2 optimization)
            if currentLayer == 1 || currentLayer == alignedCount || currentLayer % 3 == 0 {
                let accPtr = accBuffer.contents().bindMemory(to: Float.self, capacity: totalFloats)
                let wgtPtr = wgtBuffer.contents().bindMemory(to: Float.self, capacity: pixelCount)
                let accArray = Array(UnsafeBufferPointer(start: accPtr, count: totalFloats))
                let wgtArray = Array(UnsafeBufferPointer(start: wgtPtr, count: pixelCount))

                await updateMiniPreview(
                    accumulator: accArray, weights: wgtArray,
                    width: refWidth, height: refHeight, channelCount: channelCount
                )
            }
        }

        // Step 5: Normalize with vDSP (V2 optimization)
        guard !Task.isCancelled else { phase = .idle; return }
        phase = .stacking
        progress = 0.95

        let accPtr = accBuffer.contents().bindMemory(to: Float.self, capacity: totalFloats)
        let wgtPtr = wgtBuffer.contents().bindMemory(to: Float.self, capacity: pixelCount)
        let minPtr = minBuffer.contents().bindMemory(to: Float.self, capacity: totalFloats)
        let maxPtr = maxBuffer.contents().bindMemory(to: Float.self, capacity: totalFloats)
        var accumulator = Array(UnsafeBufferPointer(start: accPtr, count: totalFloats))
        let weightMap = Array(UnsafeBufferPointer(start: wgtPtr, count: pixelCount))
        let minValues = Array(UnsafeBufferPointer(start: minPtr, count: totalFloats))
        let maxValues = Array(UnsafeBufferPointer(start: maxPtr, count: totalFloats))

        // Min/max rejection: subtract per-pixel min and max from sum, reduce weight by 2.
        // Only applies when pixel has >= 3 contributions (otherwise simple mean).
        // Removes single-frame outliers: satellite trails (1 bright frame) and hot pixels.
        for ch in 0..<channelCount {
            let chOff = ch * pixelCount
            for px in 0..<pixelCount {
                let w = weightMap[px]
                if w >= 3.0 {
                    accumulator[chOff + px] -= minValues[chOff + px] + maxValues[chOff + px]
                }
            }
        }

        // Build effective weight map: reduce by 2 where rejection was applied
        var effectiveWeights = weightMap
        for px in 0..<pixelCount {
            if effectiveWeights[px] >= 3.0 {
                effectiveWeights[px] -= 2.0
            }
        }

        // Clamp weights to minimum 1.0 to avoid division by zero
        var one: Float = 1.0
        vDSP_vthr(effectiveWeights, 1, &one, &effectiveWeights, 1, vDSP_Length(pixelCount))

        for ch in 0..<channelCount {
            let offset = ch * pixelCount
            accumulator.withUnsafeMutableBufferPointer { accBuf in
                effectiveWeights.withUnsafeBufferPointer { wgtBuf in
                    vDSP_vdiv(
                        wgtBuf.baseAddress!, 1,
                        accBuf.baseAddress! + offset, 1,
                        accBuf.baseAddress! + offset, 1,
                        vDSP_Length(pixelCount)
                    )
                }
            }
        }

        // Create result texture
        let resultTex = createResultTexture(
            from: accumulator, width: refWidth, height: refHeight, channelCount: channelCount
        )

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

    // MARK: - Triangle Matching (V2: hash-based)

    struct Triangle {
        let i0: Int, i1: Int, i2: Int
        let ratios: (Float, Float)
        let orientation: Float
    }

    // Quantization key for hash-based triangle lookup
    // Quantizes ratios to 0.025 buckets for fast matching with neighbor search
    private struct TriangleKey: Hashable {
        let r1Bucket: Int
        let r2Bucket: Int

        // Init from float ratios (quantizes automatically)
        init(r1: Float, r2: Float) {
            r1Bucket = Int(r1 / 0.025)
            r2Bucket = Int(r2 / 0.025)
        }

        // Init from explicit bucket values (for neighbor search ±1)
        init(r1Bucket: Int, r2Bucket: Int) {
            self.r1Bucket = r1Bucket
            self.r2Bucket = r2Bucket
        }
    }

    // 2D affine transform for star alignment (rotation + translation + scale)
    struct AffineTransform2D {
        let a: Float, b: Float, tx: Float
        let c: Float, d: Float, ty: Float

        static let identity = AffineTransform2D(a: 1, b: 0, tx: 0, c: 0, d: 1, ty: 0)

        var rotation: Float { atan2f(c, a) }
        var scale: Float { sqrtf(a * a + c * c) }

        func apply(_ x: Float, _ y: Float) -> (Float, Float) {
            return (a * x + b * y + tx, c * x + d * y + ty)
        }

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
    }

    private nonisolated func buildTriangles(from stars: [Star], limit: Int? = nil) -> [Triangle] {
        let n = min(stars.count, limit ?? triangleStarLimit)
        var triangles: [Triangle] = []

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
                    guard longest > 10 else { continue }

                    let r1 = sides[1].0 / longest
                    let r2 = sides[2].0 / longest

                    let longestDx = stars[sides[0].2].x - stars[sides[0].1].x
                    let longestDy = stars[sides[0].2].y - stars[sides[0].1].y
                    let angle = atan2f(longestDy, longestDx)

                    triangles.append(Triangle(
                        i0: sides[0].1, i1: sides[0].2,
                        i2: sides[2].1 == sides[0].1 || sides[2].1 == sides[0].2 ? sides[2].2 : sides[2].1,
                        ratios: (r1, r2),
                        orientation: angle
                    ))
                }
            }
        }
        return triangles
    }

    // Build hash index: maps quantized ratio buckets → triangle indices
    private nonisolated func buildTriangleIndex(from triangles: [Triangle]) -> [TriangleKey: [Int]] {
        var index: [TriangleKey: [Int]] = [:]
        for (i, tri) in triangles.enumerated() {
            let key = TriangleKey(r1: tri.ratios.0, r2: tri.ratios.1)
            index[key, default: []].append(i)
        }
        return index
    }

    // Hash-based matching: instead of O(N²) brute force, lookup candidate matches in O(1)
    // After finding the best 3-point transform, refines it using least-squares on all inliers
    private nonisolated func matchTrianglesHashed(
        refIndex: [TriangleKey: [Int]], refTriangles: [Triangle], refStars: [Star],
        frameTriangles: [Triangle], frameStars: [Star],
        inlierThreshold: Float = 10.0
    ) -> AffineTransform2D? {
        var bestInliers = 0
        var bestTransform: AffineTransform2D?

        for ft in frameTriangles {
            let key = TriangleKey(r1: ft.ratios.0, r2: ft.ratios.1)

            // Check the exact bucket and neighboring buckets (±1) for tolerance
            for dr1 in -1...1 {
                for dr2 in -1...1 {
                    let searchKey = TriangleKey(r1Bucket: key.r1Bucket + dr1, r2Bucket: key.r2Bucket + dr2)
                    guard let candidates = refIndex[searchKey] else { continue }

                    for refIdx in candidates {
                        let rt = refTriangles[refIdx]

                        // Fine-grained ratio check (5% tolerance)
                        let dr1f = Swift.abs(rt.ratios.0 - ft.ratios.0)
                        let dr2f = Swift.abs(rt.ratios.1 - ft.ratios.1)
                        guard dr1f < 0.05 && dr2f < 0.05 else { continue }

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

                        let inliers = countInliers(
                            transform: transform,
                            refStars: refStars, frameStars: frameStars,
                            threshold: inlierThreshold,
                            limit: inlierCheckLimit
                        )

                        if inliers > bestInliers {
                            bestInliers = inliers
                            bestTransform = transform
                        }
                    }
                }
            }
        }

        // Require at least 6 inliers to reject false triangle matches.
        // Correct matches typically have 15+ inliers; false matches have 3-5 from coincidence.
        guard bestInliers >= 6, let initial = bestTransform else {
            return nil
        }

        // Two-pass least-squares refinement:
        // Pass 1: collect inliers at 8px threshold, re-solve affine from all pairs
        // Pass 2: use refined transform with tighter 4px threshold, re-solve again
        // This converges to sub-pixel alignment accuracy
        let pass1 = refineTransform(
            initial: initial,
            refStars: refStars, frameStars: frameStars,
            threshold: 8.0
        )
        let pass2 = refineTransform(
            initial: pass1 ?? initial,
            refStars: refStars, frameStars: frameStars,
            threshold: 4.0
        )
        let final = pass2 ?? pass1 ?? initial
        let finalInliers = countInliers(transform: final, refStars: refStars, frameStars: frameStars, threshold: 4.0)

        // Post-refinement quality gate: reject if too few inliers survive 4px tightening
        guard finalInliers >= 5 else { return nil }
        return final
    }

    // Least-squares affine refinement using all inlier star correspondences.
    // Solves the overdetermined system via normal equations (AᵀA)x = Aᵀb
    // for each of the two coordinate transforms (x' and y') independently.
    private nonisolated func refineTransform(
        initial: AffineTransform2D,
        refStars: [Star], frameStars: [Star],
        threshold: Float
    ) -> AffineTransform2D? {
        let threshSq = threshold * threshold

        // Collect matched pairs: frame star → closest ref star under the initial transform
        var srcPts: [(Float, Float)] = []
        var dstPts: [(Float, Float)] = []

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

        // Need at least 3 pairs for affine, but more is better
        guard srcPts.count >= 4 else { return nil }

        // Solve least-squares: for each destination coordinate (X, Y),
        // minimize sum of (a*xi + b*yi + tx - Xi)² over all pairs.
        // Normal equations: [sum(xi²)   sum(xi*yi) sum(xi)] [a ]   [sum(xi*Xi)]
        //                   [sum(xi*yi) sum(yi²)   sum(yi)] [b ] = [sum(yi*Xi)]
        //                   [sum(xi)    sum(yi)    N      ] [tx]   [sum(Xi)   ]

        let n = Float(srcPts.count)
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        var sx: Float = 0, sy: Float = 0
        var sxX: Float = 0, syX: Float = 0, sX: Float = 0
        var sxY: Float = 0, syY: Float = 0, sY: Float = 0

        for i in 0..<srcPts.count {
            let (xi, yi) = srcPts[i]
            let (Xi, Yi) = dstPts[i]
            sxx += xi * xi;  syy += yi * yi;  sxy += xi * yi
            sx  += xi;       sy  += yi
            sxX += xi * Xi;  syX += yi * Xi;  sX  += Xi
            sxY += xi * Yi;  syY += yi * Yi;  sY  += Yi
        }

        // Solve 3x3 system using Cramer's rule (same matrix for both X and Y targets)
        let det = sxx * (syy * n - sy * sy)
                - sxy * (sxy * n - sy * sx)
                + sx  * (sxy * sy - syy * sx)
        guard Swift.abs(det) > 1e-6 else { return nil }
        let invDet = 1.0 / det

        // Solve for (a, b, tx) mapping frame→ref X coordinates
        let a  = ((syy * n - sy * sy) * sxX + (sy * sx - sxy * n) * syX + (sxy * sy - syy * sx) * sX) * invDet
        let b  = ((sy * sx - sxy * n) * sxX + (sxx * n - sx * sx) * syX + (sxy * sx - sxx * sy) * sX) * invDet
        let tx = ((sxy * sy - syy * sx) * sxX + (sxy * sx - sxx * sy) * syX + (sxx * syy - sxy * sxy) * sX) * invDet

        // Solve for (c, d, ty) mapping frame→ref Y coordinates (same LHS matrix)
        let c  = ((syy * n - sy * sy) * sxY + (sy * sx - sxy * n) * syY + (sxy * sy - syy * sx) * sY) * invDet
        let d  = ((sy * sx - sxy * n) * sxY + (sxx * n - sx * sx) * syY + (sxy * sx - sxx * sy) * sY) * invDet
        let ty = ((sxy * sy - syy * sx) * sxY + (sxy * sx - sxx * sy) * syY + (sxx * syy - sxy * sxy) * sY) * invDet

        // Scale should be near 1.0 on BOTH axes
        let scaleX = (a * a + c * c).squareRoot()
        let scaleY = (b * b + d * d).squareRoot()
        guard scaleX > 0.95 && scaleX < 1.05 && scaleY > 0.95 && scaleY < 1.05 else { return nil }

        return AffineTransform2D(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
    }

    // MARK: - Affine Transform

    private nonisolated func solveAffine(
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

        // Basic sanity: scale on both axes should be roughly 1.0
        let scaleX = (a * a + c * c).squareRoot()
        let scaleY = (b * b + d * d).squareRoot()
        guard scaleX > 0.8 && scaleX < 1.2 && scaleY > 0.8 && scaleY < 1.2 else { return nil }

        return AffineTransform2D(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
    }

    private nonisolated func countInliers(
        transform: AffineTransform2D,
        refStars: [Star], frameStars: [Star],
        threshold: Float,
        limit: Int = Int.max
    ) -> Int {
        let threshSq = threshold * threshold
        var count = 0
        let maxFrame = min(frameStars.count, limit)
        let maxRef = min(refStars.count, limit)

        for i in 0..<maxFrame {
            let (tx, ty) = transform.apply(frameStars[i].x, frameStars[i].y)
            for j in 0..<maxRef {
                let dx = tx - refStars[j].x
                let dy = ty - refStars[j].y
                if dx * dx + dy * dy < threshSq {
                    count += 1
                    break
                }
            }
        }
        return count
    }

    // MARK: - CPU Warp Fallback

    private nonisolated func warpAndAccumulateCPU(
        source: DecodedImage,
        transform: AffineTransform2D,
        into accumulator: inout [Float],
        weights: inout [Float],
        minValues: inout [Float],
        maxValues: inout [Float],
        width: Int, height: Int, channelCount: Int
    ) {
        let srcPtr = source.buffer.contents().bindMemory(to: UInt16.self, capacity: source.pixelCount)
        let planeSize = width * height
        let inv = transform.inverse ?? .identity

        for y in 0..<height {
            for x in 0..<width {
                let (sx, sy) = inv.apply(Float(x), Float(y))
                guard sx >= 0 && sx < Float(width - 1) && sy >= 0 && sy < Float(height - 1) else { continue }

                let ix = Int(sx)
                let iy = Int(sy)
                let fx = sx - Float(ix)
                let fy = sy - Float(iy)
                let w00 = (1 - fx) * (1 - fy)
                let w10 = fx * (1 - fy)
                let w01 = (1 - fx) * fy
                let w11 = fx * fy

                let dstIdx = y * width + x
                let isFirst = weights[dstIdx] == 0.0

                for ch in 0..<channelCount {
                    let chOff = ch * planeSize
                    let v00 = Float(srcPtr[chOff + iy * width + ix])
                    let v10 = Float(srcPtr[chOff + iy * width + ix + 1])
                    let v01 = Float(srcPtr[chOff + (iy + 1) * width + ix])
                    let v11 = Float(srcPtr[chOff + (iy + 1) * width + ix + 1])

                    let interpolated = v00 * w00 + v10 * w10 + v01 * w01 + v11 * w11
                    let accIdx = ch * planeSize + dstIdx
                    accumulator[accIdx] += interpolated

                    // Track min/max for outlier rejection
                    if isFirst {
                        minValues[accIdx] = interpolated
                        maxValues[accIdx] = interpolated
                    } else {
                        minValues[accIdx] = min(minValues[accIdx], interpolated)
                        maxValues[accIdx] = max(maxValues[accIdx], interpolated)
                    }
                }
                weights[dstIdx] += 1.0
            }
        }
    }

    // MARK: - Preview (same as V1, just called less often)

    private func updateMiniPreview(
        accumulator: [Float], weights: [Float],
        width: Int, height: Int, channelCount: Int
    ) async {
        let previewSize = 200
        let planeSize = width * height

        var previewPixels = [UInt8](repeating: 0, count: previewSize * previewSize * 4)

        let scaleX = Float(width) / Float(previewSize)
        let scaleY = Float(height) / Float(previewSize)

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
                    previewPixels[outIdx] = byte
                    previewPixels[outIdx + 1] = byte
                    previewPixels[outIdx + 2] = byte
                } else {
                    for ch in 0..<min(channelCount, 3) {
                        var v = accumulator[ch * planeSize + srcIdx] / w / 65535.0
                        v = max(0, min(1, (v - c0) / max(1 - c0, 0.001)))
                        v = mtfApply(v, mb)
                        let bgraIdx = ch == 0 ? 2 : (ch == 1 ? 1 : 0)
                        previewPixels[outIdx + bgraIdx] = UInt8(max(0, min(255, v * 255)))
                    }
                }
                previewPixels[outIdx + 3] = 255
            }
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: previewSize, height: previewSize, mipmapped: false
        )
        texDesc.usage = [.shaderRead]

        if let tex = device.makeTexture(descriptor: texDesc) {
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: previewSize, height: previewSize, depth: 1)),
                mipmapLevel: 0, withBytes: previewPixels, bytesPerRow: previewSize * 4
            )
            miniPreviewTexture = tex
        }
    }

    private nonisolated func mtfApply(_ x: Float, _ m: Float) -> Float {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if x == m { return 0.5 }
        return (m - 1) * x / ((2 * m - 1) * x - m)
    }

    // MARK: - Result Texture (same as V1)

    private func createResultTexture(
        from data: [Float], width: Int, height: Int, channelCount: Int
    ) -> MTLTexture? {
        let planeSize = width * height

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
                    pixels[outIdx] = byte
                    pixels[outIdx + 1] = byte
                    pixels[outIdx + 2] = byte
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
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        texDesc.usage = [.shaderRead]

        guard let tex = device.makeTexture(descriptor: texDesc) else { return nil }
        tex.replace(
            region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4
        )
        return tex
    }
}
