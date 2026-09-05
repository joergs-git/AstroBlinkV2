// v3.2.0
import Foundation
import Metal

// Generates pre-stretched, downsampled BGRA8 preview textures for instant navigation.
// Uses Metal compute for bin2x + STF stretch in a single command buffer.
// All GPU work (debayer → bin2x → STF) is chained to minimize round-trips.

struct CachedPreview {
    let texture: MTLTexture       // BGRA8, pre-stretched, bin2x resolution
    let stfParams: [STFParams]    // STF params used (for invalidation check)
    let originalWidth: Int
    let originalHeight: Int
    let channelCount: Int
    var histogramBins: [Float]?   // 64-bin luminance histogram (log-normalized, 0-1)
}

// PrefetchCache hands a captured `PreviewGenerator?` reference to background
// OperationQueue workers. Metal device / command queue / pipelines are documented
// thread-safe, and the per-call CPU work uses local state. Marked
// @unchecked Sendable so background-worker captures stop tripping Swift 6
// strict-concurrency without forcing every Metal type to inherit Sendable.
final class PreviewGenerator: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let computePipeline: MTLComputePipelineState
    let debayerPipeline: MTLComputePipelineState?
    let bin2xPipeline: MTLComputePipelineState?
    let postProcessPipeline: MTLComputePipelineState?
    let starDetectPipeline: MTLComputePipelineState?
    let psfFitPipeline: MTLComputePipelineState?
    let psfFitEllipticalPipeline: MTLComputePipelineState?

    // Bayer pattern string to shader index mapping
    private static let bayerPatternMap: [String: Int] = [
        "RGGB": 0, "GRBG": 1, "GBRG": 2, "BGGR": 3
    ]

    /// - Parameter library: optional pre-loaded Metal library. When nil (the app/default),
    ///   `device.makeDefaultLibrary()` loads `default.metallib` from the main bundle. A
    ///   bundle-less command-line tool (AstroScoreCLI) has no app bundle, so it loads its
    ///   metallib explicitly and injects it here. Backward-compatible: existing callers pass
    ///   only `device`.
    init?(device: MTLDevice, library injectedLibrary: MTLLibrary? = nil) {
        self.device = device

        guard let queue = device.makeCommandQueue(),
              let library = injectedLibrary ?? device.makeDefaultLibrary(),
              let computeFunc = library.makeFunction(name: "normalize_uint16"),
              let pipeline = try? device.makeComputePipelineState(function: computeFunc) else {
            return nil
        }

        self.commandQueue = queue
        self.computePipeline = pipeline

        // Load debayer kernel (optional)
        if let debayerFunc = library.makeFunction(name: "debayer_bilinear"),
           let debayerPipe = try? device.makeComputePipelineState(function: debayerFunc) {
            self.debayerPipeline = debayerPipe
        } else {
            self.debayerPipeline = nil
        }

        // Load GPU bin2x kernel
        if let bin2xFunc = library.makeFunction(name: "bin2x"),
           let bin2xPipe = try? device.makeComputePipelineState(function: bin2xFunc) {
            self.bin2xPipeline = bin2xPipe
        } else {
            self.bin2xPipeline = nil
        }

        // Load post-process kernel for baking sharpening/contrast/dark into previews
        if let ppFunc = library.makeFunction(name: "post_process"),
           let ppPipe = try? device.makeComputePipelineState(function: ppFunc) {
            self.postProcessPipeline = ppPipe
        } else {
            self.postProcessPipeline = nil
        }

        // Load GPU star detection kernel
        if let starFunc = library.makeFunction(name: "detect_stars_binned"),
           let starPipe = try? device.makeComputePipelineState(function: starFunc) {
            self.starDetectPipeline = starPipe
        } else {
            self.starDetectPipeline = nil
        }

        // Load GPU PSF fitting kernels (circular + elliptical)
        if let psfFunc = library.makeFunction(name: "psf_fit_gaussian"),
           let psfPipe = try? device.makeComputePipelineState(function: psfFunc) {
            self.psfFitPipeline = psfPipe
        } else {
            self.psfFitPipeline = nil
        }
        if let psfEllipFunc = library.makeFunction(name: "psf_fit_elliptical"),
           let psfEllipPipe = try? device.makeComputePipelineState(function: psfEllipFunc) {
            self.psfFitEllipticalPipeline = psfEllipPipe
        } else {
            self.psfFitEllipticalPipeline = nil
        }
    }

    // Debayer a mono CFA image to RGB using Metal compute
    // Returns a new DecodedImage with channelCount=3, or nil on failure
    func debayer(image: DecodedImage, pattern: String) -> DecodedImage? {
        guard let pipeline = debayerPipeline,
              image.channelCount == 1,
              let patternIndex = Self.bayerPatternMap[pattern.uppercased()] else {
            return nil
        }

        let outputSize = image.width * image.height * 3 * MemoryLayout<UInt16>.size
        guard let outputBuffer = device.makeBuffer(length: outputSize, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        var w = Int32(image.width)
        var h = Int32(image.height)
        var pat = Int32(patternIndex)
        encoder.setBytes(&w, length: 4, index: 2)
        encoder.setBytes(&h, length: 4, index: 3)
        encoder.setBytes(&pat, length: 4, index: 4)

        let threadGroupSize = MTLSize(width: 32, height: 32, depth: 1)
        let threadGroups = MTLSize(
            width: (image.width + 31) / 32,
            height: (image.height + 31) / 32,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return DecodedImage(
            buffer: outputBuffer,
            width: image.width,
            height: image.height,
            channelCount: 3
        )
    }

    // Generate a pre-stretched, bin2x preview texture from raw decoded image data.
    // Chains GPU bin2x → STF stretch → optional post-process in a single command buffer.
    // postProcessParams: when non-nil, bakes sharpening/contrast/dark into the cached preview.
    func generatePreview(
        from image: DecodedImage,
        stfParams: [STFParams],
        postProcessParams: (sharpening: Float, contrast: Float, darkLevel: Float)? = nil,
        removeGradient: Bool = false
    ) -> CachedPreview? {
        let srcW = image.width
        let srcH = image.height
        let channels = image.channelCount
        let binnedW = srcW / 2
        let binnedH = srcH / 2

        guard binnedW > 0, binnedH > 0 else { return nil }

        // Allocate bin2x output buffer on GPU
        let binnedBytes = binnedW * binnedH * channels * MemoryLayout<UInt16>.size
        guard let binnedBuffer = device.makeBuffer(length: binnedBytes, options: .storageModeShared) else {
            return nil
        }

        // Prepare STF params buffer (pad mono to 3 channels)
        var params = stfParams
        while params.count < 3 {
            params.append(params.first ?? STFParams(c0: 0.0, mb: 0.5))
        }

        var floatData: [Float] = []
        for p in params {
            floatData.append(p.c0)
            floatData.append(p.mb)
        }

        guard let stfBuffer = device.makeBuffer(
            bytes: &floatData,
            length: floatData.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { return nil }

        // Create output BGRA8 texture at binned resolution (mipmapped for trilinear anti-moiré)
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: binnedW,
            height: binnedH,
            mipmapped: true
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .private

        guard let outTexture = device.makeTexture(descriptor: texDesc) else { return nil }

        // Optional: gradient removal on source data before bin2x + STF
        // Modifies the shared MTLBuffer in-place (zero-copy). Restores after if needed.
        var gradientBackup: [UInt16]?
        if removeGradient {
            let pixelCount = srcW * srcH * channels
            let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: pixelCount)
            // Backup original data (will restore after GPU dispatch)
            gradientBackup = Array(UnsafeBufferPointer(start: ptr, count: pixelCount))
            // Convert uint16 → float [0,1]
            var floats = [Float](repeating: 0, count: pixelCount)
            for i in 0..<pixelCount { floats[i] = Float(ptr[i]) / 65535.0 }
            // Apply gradient removal
            let corrected = GradientRemoval.removeGradient(
                data: floats, width: srcW, height: srcH,
                channelCount: channels, device: device
            )
            // Write back to buffer
            for i in 0..<pixelCount { ptr[i] = UInt16(min(65535, max(0, corrected[i] * 65535.0))) }
        }

        // Single command buffer for both GPU passes (bin2x → STF stretch)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Pass 1: GPU bin2x — average 2x2 blocks
        if let bin2xPipeline = bin2xPipeline {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(bin2xPipeline)
            encoder.setBuffer(image.buffer, offset: 0, index: 0)
            encoder.setBuffer(binnedBuffer, offset: 0, index: 1)
            var sw = Int32(srcW)
            var sh = Int32(srcH)
            var cc = Int32(channels)
            encoder.setBytes(&sw, length: 4, index: 2)
            encoder.setBytes(&sh, length: 4, index: 3)
            encoder.setBytes(&cc, length: 4, index: 4)

            let tg = MTLSize(width: 32, height: 32, depth: 1)
            let grid = MTLSize(
                width: (binnedW + 31) / 32,
                height: (binnedH + 31) / 32,
                depth: 1
            )
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        // Pass 2: STF stretch on binned data → BGRA8 texture
        do {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(computePipeline)
            encoder.setBuffer(binnedBuffer, offset: 0, index: 0)

            var width = Int32(binnedW)
            var height = Int32(binnedH)
            var channelCount = Int32(channels)
            encoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 1)
            encoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 2)
            encoder.setBytes(&channelCount, length: MemoryLayout<Int32>.size, index: 3)
            encoder.setBuffer(stfBuffer, offset: 0, index: 4)
            encoder.setTexture(outTexture, index: 0)

            let tg = MTLSize(width: 32, height: 32, depth: 1)
            let grid = MTLSize(
                width: (binnedW + 31) / 32,
                height: (binnedH + 31) / 32,
                depth: 1
            )
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        // Pass 3: Optional post-processing (sharpening, contrast, dark level)
        // Bakes post-process into the cached preview so navigation stays instant
        let finalTexture: MTLTexture
        if let pp = postProcessParams, let ppPipeline = postProcessPipeline,
           (abs(pp.sharpening) > 0.001 || abs(pp.contrast) > 0.001 || pp.darkLevel > 0.001) {
            // Create a second texture for post-process output (mipmapped for trilinear anti-moiré)
            let ppTexDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: binnedW,
                height: binnedH,
                mipmapped: true
            )
            ppTexDesc.usage = [.shaderWrite, .shaderRead]
            ppTexDesc.storageMode = .private

            guard let ppOutTexture = device.makeTexture(descriptor: ppTexDesc),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                // Fall back to STF-only output if post-process texture allocation fails
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                return CachedPreview(texture: outTexture, stfParams: stfParams,
                    originalWidth: image.width, originalHeight: image.height,
                    channelCount: image.channelCount, histogramBins: nil)
            }

            encoder.setComputePipelineState(ppPipeline)
            encoder.setTexture(outTexture, index: 0)     // input: STF output
            encoder.setTexture(ppOutTexture, index: 1)    // output: post-processed

            var ppData = (pp.sharpening, pp.contrast, pp.darkLevel)
            encoder.setBytes(&ppData, length: MemoryLayout<(Float, Float, Float)>.size, index: 0)

            let tg = MTLSize(width: 32, height: 32, depth: 1)
            let grid = MTLSize(
                width: (binnedW + 31) / 32,
                height: (binnedH + 31) / 32,
                depth: 1
            )
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            encoder.endEncoding()

            finalTexture = ppOutTexture
        } else {
            finalTexture = outTexture
        }

        // Generate mipmaps for trilinear filtering (anti-moiré when zoomed out on MacBook screens)
        if finalTexture.mipmapLevelCount > 1 {
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.generateMipmaps(for: finalTexture)
                blitEncoder.endEncoding()
            }
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Compute 64-bin luminance histogram from the binned buffer (shared memory — fast CPU read)
        let histBins: [Float]? = {
            let pixelCount = binnedW * binnedH
            let ptr = binnedBuffer.contents().bindMemory(to: UInt16.self, capacity: pixelCount * channels)
            let binCount = 64
            var bins = [Int](repeating: 0, count: binCount)
            let step = 4
            for y in stride(from: 0, to: binnedH, by: step) {
                for x in stride(from: 0, to: binnedW, by: step) {
                    let idx = y * binnedW + x
                    let lum: Float
                    if channels == 1 {
                        lum = Float(ptr[idx]) / 65535.0
                    } else {
                        // RGB planar: R + G + B weighted luminance
                        let r = Float(ptr[idx]) / 65535.0
                        let g = Float(ptr[pixelCount + idx]) / 65535.0
                        let b = Float(ptr[2 * pixelCount + idx]) / 65535.0
                        lum = 0.299 * r + 0.587 * g + 0.114 * b
                    }
                    let bin = min(binCount - 1, Int(lum * Float(binCount)))
                    bins[bin] += 1
                }
            }
            let maxBin = Float(bins.max() ?? 1)
            return bins.map { maxBin > 0 ? log(1 + Float($0)) / log(1 + maxBin) : 0 }
        }()

        // Restore original buffer data after GPU is done (gradient removal was in-place)
        if let backup = gradientBackup {
            let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: backup.count)
            backup.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: backup.count)
            }
        }

        return CachedPreview(
            texture: finalTexture,
            stfParams: stfParams,
            originalWidth: image.width,
            originalHeight: image.height,
            channelCount: image.channelCount,
            histogramBins: histBins
        )
    }

    // Async version: dispatches final GPU command buffer and calls completion on Metal callback thread.
    // Frees the calling worker thread immediately instead of blocking on waitUntilCompleted().
    func generatePreviewAsync(
        from image: DecodedImage,
        stfParams: [STFParams],
        postProcessParams: (sharpening: Float, contrast: Float, darkLevel: Float)? = nil,
        completion: @escaping (CachedPreview?) -> Void
    ) {
        let srcW = image.width
        let srcH = image.height
        let channels = image.channelCount
        let binnedW = srcW / 2
        let binnedH = srcH / 2

        guard binnedW > 0, binnedH > 0 else { completion(nil); return }

        let binnedBytes = binnedW * binnedH * channels * MemoryLayout<UInt16>.size
        guard let binnedBuffer = device.makeBuffer(length: binnedBytes, options: .storageModeShared) else {
            completion(nil); return
        }

        var params = stfParams
        while params.count < 3 {
            params.append(params.first ?? STFParams(c0: 0.0, mb: 0.5))
        }

        var floatData: [Float] = []
        for p in params {
            floatData.append(p.c0)
            floatData.append(p.mb)
        }

        guard let stfBuffer = device.makeBuffer(
            bytes: &floatData,
            length: floatData.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { completion(nil); return }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: binnedW,
            height: binnedH,
            mipmapped: true
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .private

        guard let outTexture = device.makeTexture(descriptor: texDesc) else { completion(nil); return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { completion(nil); return }

        // Pass 1: GPU bin2x
        if let bin2xPipeline = bin2xPipeline {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { completion(nil); return }
            encoder.setComputePipelineState(bin2xPipeline)
            encoder.setBuffer(image.buffer, offset: 0, index: 0)
            encoder.setBuffer(binnedBuffer, offset: 0, index: 1)
            var sw = Int32(srcW)
            var sh = Int32(srcH)
            var cc = Int32(channels)
            encoder.setBytes(&sw, length: 4, index: 2)
            encoder.setBytes(&sh, length: 4, index: 3)
            encoder.setBytes(&cc, length: 4, index: 4)

            let tg = MTLSize(width: 32, height: 32, depth: 1)
            let grid = MTLSize(
                width: (binnedW + 31) / 32,
                height: (binnedH + 31) / 32,
                depth: 1
            )
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        // Pass 2: STF stretch → BGRA8 texture
        do {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { completion(nil); return }
            encoder.setComputePipelineState(computePipeline)
            encoder.setBuffer(binnedBuffer, offset: 0, index: 0)

            var width = Int32(binnedW)
            var height = Int32(binnedH)
            var channelCount = Int32(channels)
            encoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 1)
            encoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 2)
            encoder.setBytes(&channelCount, length: MemoryLayout<Int32>.size, index: 3)
            encoder.setBuffer(stfBuffer, offset: 0, index: 4)
            encoder.setTexture(outTexture, index: 0)

            let tg = MTLSize(width: 32, height: 32, depth: 1)
            let grid = MTLSize(
                width: (binnedW + 31) / 32,
                height: (binnedH + 31) / 32,
                depth: 1
            )
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        // Pass 3: Optional post-processing
        let finalTexture: MTLTexture
        if let pp = postProcessParams, let ppPipeline = postProcessPipeline,
           (abs(pp.sharpening) > 0.001 || abs(pp.contrast) > 0.001 || pp.darkLevel > 0.001) {
            let ppTexDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: binnedW,
                height: binnedH,
                mipmapped: true
            )
            ppTexDesc.usage = [.shaderWrite, .shaderRead]
            ppTexDesc.storageMode = .private

            guard let ppOutTexture = device.makeTexture(descriptor: ppTexDesc),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                // Fall back to STF-only with sync completion
                commandBuffer.commit()
                commandBuffer.addCompletedHandler { _ in
                    completion(CachedPreview(texture: outTexture, stfParams: stfParams,
                        originalWidth: image.width, originalHeight: image.height,
                        channelCount: image.channelCount, histogramBins: nil))
                }
                return
            }

            encoder.setComputePipelineState(ppPipeline)
            encoder.setTexture(outTexture, index: 0)
            encoder.setTexture(ppOutTexture, index: 1)

            var ppData = (pp.sharpening, pp.contrast, pp.darkLevel)
            encoder.setBytes(&ppData, length: MemoryLayout<(Float, Float, Float)>.size, index: 0)

            let tg = MTLSize(width: 32, height: 32, depth: 1)
            let grid = MTLSize(
                width: (binnedW + 31) / 32,
                height: (binnedH + 31) / 32,
                depth: 1
            )
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            encoder.endEncoding()

            finalTexture = ppOutTexture
        } else {
            finalTexture = outTexture
        }

        // Generate mipmaps
        if finalTexture.mipmapLevelCount > 1 {
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.generateMipmaps(for: finalTexture)
                blitEncoder.endEncoding()
            }
        }

        // Async completion — compute histogram from binned buffer then return preview
        let origWidth = image.width
        let origHeight = image.height
        let origChannels = image.channelCount
        let histW = binnedW, histH = binnedH, histCh = channels
        commandBuffer.addCompletedHandler { _ in
            // Compute histogram from binned uint16 data (shared buffer — CPU readable after GPU done)
            let pixelCount = histW * histH
            let ptr = binnedBuffer.contents().bindMemory(to: UInt16.self, capacity: pixelCount * histCh)
            let binCount = 64
            var bins = [Int](repeating: 0, count: binCount)
            let step = 4
            for y in stride(from: 0, to: histH, by: step) {
                for x in stride(from: 0, to: histW, by: step) {
                    let idx = y * histW + x
                    let lum: Float
                    if histCh == 1 {
                        lum = Float(ptr[idx]) / 65535.0
                    } else {
                        let r = Float(ptr[idx]) / 65535.0
                        let g = Float(ptr[pixelCount + idx]) / 65535.0
                        let b = Float(ptr[2 * pixelCount + idx]) / 65535.0
                        lum = 0.299 * r + 0.587 * g + 0.114 * b
                    }
                    let bin = min(binCount - 1, Int(lum * Float(binCount)))
                    bins[bin] += 1
                }
            }
            let maxBin = Float(bins.max() ?? 1)
            let histBins = bins.map { maxBin > 0 ? log(1 + Float($0)) / log(1 + maxBin) : 0 }

            completion(CachedPreview(
                texture: finalTexture,
                stfParams: stfParams,
                originalWidth: origWidth,
                originalHeight: origHeight,
                channelCount: origChannels,
                histogramBins: histBins
            ))
        }
        commandBuffer.commit()
    }

    // MARK: - GPU Star Detection

    // Maximum candidates the GPU kernel can emit (capped by atomic counter)
    // Must be large enough to hold ALL peaks above threshold across the full image.
    // GPU threads execute in tile order (left-to-right), so a small buffer fills up
    // with left-biased stars and misses the right side entirely.
    // L-band images can have 6000+ peaks — 16384 handles even dense star fields.
    private static let maxGPUCandidates = 16384

    /// True total star count from last detection (before truncation to 50)
    private(set) var lastTotalStarCount: Int = 0

    /// Detect stars on a binned uint16 buffer using the GPU `detect_stars_binned` kernel.
    /// Returns detected stars in full-resolution coordinates (scaled ×2 from binned).
    ///
    /// - Parameters:
    ///   - binnedBuffer: uint16 buffer at bin2x resolution (output of bin2x kernel)
    ///   - binnedWidth: Width of binned image
    ///   - binnedHeight: Height of binned image
    ///   - channelCount: Number of channels (1=mono, 3=RGB planar)
    ///   - channel: Which channel for detection (0=mono/first, 1=green for OSC)
    ///   - median: Background median in uint16 scale (from StarDetector.computeThreshold)
    ///   - threshold: Detection threshold in uint16 scale
    /// - Returns: Array of detected stars in full-res coordinates, sorted by brightness
    func detectStarsGPU(
        binnedBuffer: MTLBuffer,
        binnedWidth: Int,
        binnedHeight: Int,
        channelCount: Int,
        channel: Int,
        median: Float,
        threshold: Float
    ) -> [DetectedStar] {
        guard let pipeline = starDetectPipeline else { return [] }

        let maxCandidates = Self.maxGPUCandidates

        // Allocate output buffers
        // StarCandidate: (uint x, uint y, float value) = 12 bytes each
        let candidateBufferSize = maxCandidates * 12
        guard let candidateBuffer = device.makeBuffer(length: candidateBufferSize, options: .storageModeShared),
              let counterBuffer = device.makeBuffer(length: 4, options: .storageModeShared) else {
            return []
        }

        // Zero the counter
        memset(counterBuffer.contents(), 0, 4)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return []
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(binnedBuffer, offset: 0, index: 0)
        encoder.setBuffer(candidateBuffer, offset: 0, index: 1)
        encoder.setBuffer(counterBuffer, offset: 0, index: 2)

        var w = Int32(binnedWidth)
        var h = Int32(binnedHeight)
        var thresh = threshold
        var med = median
        var ch = Int32(channel)
        var cc = Int32(channelCount)
        var maxC = Int32(maxCandidates)

        encoder.setBytes(&w, length: 4, index: 3)
        encoder.setBytes(&h, length: 4, index: 4)
        encoder.setBytes(&thresh, length: 4, index: 5)
        encoder.setBytes(&med, length: 4, index: 6)
        encoder.setBytes(&ch, length: 4, index: 7)
        encoder.setBytes(&cc, length: 4, index: 8)
        encoder.setBytes(&maxC, length: 4, index: 9)

        let threadGroupSize = MTLSize(width: 32, height: 32, depth: 1)
        let threadGroups = MTLSize(
            width: (binnedWidth + 31) / 32,
            height: (binnedHeight + 31) / 32,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back candidates — raw counter may exceed maxCandidates (true total star count)
        let rawCount = Int(counterBuffer.contents().load(as: UInt32.self))
        let count = min(rawCount, maxCandidates)
        guard count > 0 else { return [] }

        let candidatePtr = candidateBuffer.contents()
        var stars: [DetectedStar] = []
        stars.reserveCapacity(count)

        for i in 0..<count {
            let offset = i * 12
            let bx = candidatePtr.load(fromByteOffset: offset, as: UInt32.self)
            let by = candidatePtr.load(fromByteOffset: offset + 4, as: UInt32.self)
            let val = candidatePtr.load(fromByteOffset: offset + 8, as: Float.self)

            // Scale binned coordinates to full resolution (×2)
            let fullX = Float(bx) * 2.0 + 1.0  // +1 for bin2x center offset
            let fullY = Float(by) * 2.0 + 1.0

            stars.append(DetectedStar(x: fullX, y: fullY, brightness: val))
        }

        // Sort by brightness (brightest first) and cap at 1000.
        //
        // Was 200. On fast f/2.2 RASA + 300 s + Lextr / L-eXtreme OSC the
        // brightest 200 stars in the picked channel can ALL saturate the 3×3
        // central patch — `filterStars` then rejects every one of them, the
        // candidate pool collapses to zero, and `StarMetricsCalculator.measure`
        // returns nil for every frame. Bumping to 1000 keeps the brightness-
        // priority sort but adds 800 mid-brightness candidates so unsaturated
        // stars survive the filter even when the top of the distribution is
        // a saturation cliff. Cost is negligible (filterStars is O(n) and the
        // GPU candidate buffer already holds up to 16 384).
        stars.sort()
        lastTotalStarCount = rawCount  // True total from GPU atomic counter (not capped)
        return Array(stars.prefix(1000))
    }

    /// Detect stars from a full-resolution image: GPU bin2x + GPU star detection.
    /// Computes threshold on CPU from a 5% subsample, then runs GPU detection on binned data.
    ///
    /// - Parameters:
    ///   - image: Full-resolution decoded image (uint16)
    ///   - channel: Which channel (0=mono, 1=green for debayered OSC)
    /// - Returns: Detected stars in full-res coordinates, or empty array on failure
    func detectStarsFromImage(_ image: DecodedImage, channel: Int = 0) -> [DetectedStar] {
        guard let bin2xPipeline = bin2xPipeline, starDetectPipeline != nil else {
            // GPU not available, fall back to CPU
            let result = StarDetector.detectStarsWithTotalCount(in: image, maxStars: 50, subsampleFactor: 4, channel: channel)
            lastTotalStarCount = result.totalCount
            return result.stars
        }

        // Compute threshold on CPU from 5% subsample of raw data (~2ms)
        guard let (median, threshold) = StarDetector.computeThreshold(
            from: image, subsampleFactor: 2, sigmaThreshold: 5.0, channel: channel
        ) else {
            return []
        }

        let srcW = image.width
        let srcH = image.height
        let channels = image.channelCount
        let binnedW = srcW / 2
        let binnedH = srcH / 2
        guard binnedW > 0, binnedH > 0 else { return [] }

        // GPU bin2x
        let binnedBytes = binnedW * binnedH * channels * MemoryLayout<UInt16>.size
        guard let binnedBuffer = device.makeBuffer(length: binnedBytes, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            let result = StarDetector.detectStarsWithTotalCount(in: image, maxStars: 50, subsampleFactor: 4, channel: channel)
            lastTotalStarCount = result.totalCount
            return result.stars
        }

        encoder.setComputePipelineState(bin2xPipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(binnedBuffer, offset: 0, index: 1)
        var sw = Int32(srcW)
        var sh = Int32(srcH)
        var cc = Int32(channels)
        encoder.setBytes(&sw, length: 4, index: 2)
        encoder.setBytes(&sh, length: 4, index: 3)
        encoder.setBytes(&cc, length: 4, index: 4)

        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let grid = MTLSize(width: (binnedW + 31) / 32, height: (binnedH + 31) / 32, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // GPU star detection on binned buffer
        var stars = detectStarsGPU(
            binnedBuffer: binnedBuffer,
            binnedWidth: binnedW,
            binnedHeight: binnedH,
            channelCount: channels,
            channel: channel,
            median: median,
            threshold: threshold
        )

        // Sanity check: if too many candidates (> 5000), the threshold is catching
        // galaxy/nebula structure (HII regions, star clusters) as false stars.
        // Auto-escalate sigma threshold until count is reasonable.
        // Only the GPU detection kernel re-runs — bin2x is already done.
        if lastTotalStarCount > 5000 {
            for sigma: Float in [8.0, 12.0, 16.0] {
                guard let (med2, thresh2) = StarDetector.computeThreshold(
                    from: image, subsampleFactor: 2, sigmaThreshold: sigma, channel: channel
                ) else { break }
                stars = detectStarsGPU(
                    binnedBuffer: binnedBuffer,
                    binnedWidth: binnedW,
                    binnedHeight: binnedH,
                    channelCount: channels,
                    channel: channel,
                    median: med2,
                    threshold: thresh2
                )
                if lastTotalStarCount <= 5000 { break }
            }
        }

        return stars
    }

    // MARK: - GPU PSF Fitting

    /// PSF fit result for one star: fitted amplitude, sigma, background, and chi²
    struct PSFFitResult {
        let amplitude: Float    // Fitted peak above background
        let sigma: Float        // Gaussian sigma (FWHM = 2.355 * sigma)
        let background: Float   // Fitted local background
        let chi2: Float         // Reduced chi² (goodness of fit)

        /// Scale-free fit quality: RMS residual as a fraction of the fitted amplitude.
        ///
        /// `chi2` from the kernel is divided by the degrees of freedom but NOT by the noise
        /// variance, and the residuals are raw ADU — so it carries units of ADU² and grows
        /// with star brightness. An absolute threshold on it therefore selects FAINT stars,
        /// not well-fitted ones (measured on GOLDENSET1: median 8.8e5 against a gate of 1000,
        /// so real stars were rejected and only noise peaks on dark/cloud frames passed).
        /// Dividing the RMS residual by the amplitude removes the brightness scaling and
        /// yields an interpretable number: 0.10 means "residuals are 10% of peak height".
        var relativeResidual: Double {
            guard amplitude > 0, chi2 >= 0 else { return .infinity }
            return (Double(chi2).squareRoot()) / Double(amplitude)
        }
    }

    /// GPU-accelerated circular Gaussian PSF fitting for filtered stars.
    /// Runs Gauss-Newton optimization (8 iterations, 3 params: A, σ, B) on 11×11 stamps.
    /// Returns one PSFFitResult per input star, or empty array on GPU failure.
    func fitPSF(
        image: DecodedImage,
        stars: [(x: Float, y: Float, background: Float, peakBrightness: Float)],
        channel: Int = 0
    ) -> [PSFFitResult] {
        guard let pipeline = psfFitPipeline, !stars.isEmpty else { return [] }

        let count = stars.count
        // Input buffer: packed (x, y, bg, peak) per star = 16 bytes each
        let inputSize = count * 16
        guard let inputBuffer = device.makeBuffer(length: inputSize, options: .storageModeShared),
              let outputBuffer = device.makeBuffer(length: count * 16, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }

        // Fill input buffer
        let inputPtr = inputBuffer.contents()
        for (i, s) in stars.enumerated() {
            let offset = i * 16
            inputPtr.storeBytes(of: s.x, toByteOffset: offset, as: Float.self)
            inputPtr.storeBytes(of: s.y, toByteOffset: offset + 4, as: Float.self)
            inputPtr.storeBytes(of: s.background, toByteOffset: offset + 8, as: Float.self)
            inputPtr.storeBytes(of: s.peakBrightness, toByteOffset: offset + 12, as: Float.self)
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(inputBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        var w = Int32(image.width)
        var h = Int32(image.height)
        var ch = Int32(min(channel, image.channelCount - 1))
        var cc = Int32(image.channelCount)
        var sc = Int32(count)
        encoder.setBytes(&w, length: 4, index: 3)
        encoder.setBytes(&h, length: 4, index: 4)
        encoder.setBytes(&ch, length: 4, index: 5)
        encoder.setBytes(&cc, length: 4, index: 6)
        encoder.setBytes(&sc, length: 4, index: 7)

        // One thread per star
        let tg = MTLSize(width: min(64, count), height: 1, depth: 1)
        let grid = MTLSize(width: (count + 63) / 64, height: 1, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read results
        let outPtr = outputBuffer.contents()
        var results: [PSFFitResult] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            let offset = i * 16
            results.append(PSFFitResult(
                amplitude: outPtr.load(fromByteOffset: offset, as: Float.self),
                sigma: outPtr.load(fromByteOffset: offset + 4, as: Float.self),
                background: outPtr.load(fromByteOffset: offset + 8, as: Float.self),
                chi2: outPtr.load(fromByteOffset: offset + 12, as: Float.self)
            ))
        }
        return results
    }

    // MARK: - Elliptical PSF Fitting

    /// Elliptical Gaussian PSF fit result: derives eccentricity + PA analytically from σx/σy/θ
    struct PSFEllipticalResult {
        let amplitude: Float    // Fitted peak A above background
        let sigmaX: Float       // Major axis sigma (σx >= σy by convention)
        let sigmaY: Float       // Minor axis sigma
        let theta: Float        // Rotation angle in radians [0, π)
        let chi2: Float         // Reduced chi²

        /// Scale-free fit quality — see PSFFitResult.relativeResidual for the rationale.
        var relativeResidual: Double {
            guard amplitude > 0, chi2 >= 0 else { return .infinity }
            return (Double(chi2).squareRoot()) / Double(amplitude)
        }

        /// Eccentricity derived from axis ratio: √(1 - σy²/σx²)
        var eccentricity: Double {
            let ratio = Double(min(sigmaX, sigmaY)) / Double(max(sigmaX, sigmaY))
            return sqrt(max(0, 1.0 - ratio * ratio))
        }

        /// Position angle in degrees [0, 180), matching image moments convention
        var positionAngleDeg: Double {
            Double(theta) * 180.0 / Double.pi
        }

        /// Geometric mean FWHM: √(σx·σy) × 2.355
        var fwhm: Double {
            Double(sqrt(sigmaX * sigmaY)) * 2.3548
        }

        /// Axis ratio: σy/σx (minor/major), 1.0 = round
        var axisRatio: Double {
            Double(min(sigmaX, sigmaY)) / Double(max(sigmaX, sigmaY))
        }

        /// Elliptical PSF flux: 2π × A × σx × σy
        var psfFlux: Double {
            2.0 * Double.pi * Double(amplitude) * Double(sigmaX) * Double(sigmaY)
        }
    }

    /// GPU-accelerated elliptical Gaussian PSF fitting.
    /// Fits 5 params (A, σx, σy, θ, B) on 11×11 stamps via Gauss-Newton.
    /// Position fixed from detection. Derives eccentricity and PA analytically.
    func fitPSFElliptical(
        image: DecodedImage,
        stars: [(x: Float, y: Float, background: Float, peakBrightness: Float)],
        channel: Int = 0
    ) -> [PSFEllipticalResult] {
        guard let pipeline = psfFitEllipticalPipeline, !stars.isEmpty else { return [] }

        let count = stars.count
        // Input: same as circular (x, y, bg, peak) = 16 bytes each
        let inputSize = count * 16
        // Output: (amplitude, sigmaX, sigmaY, theta, chi2) = 20 bytes each
        let outputSize = count * 20
        guard let inputBuffer = device.makeBuffer(length: inputSize, options: .storageModeShared),
              let outputBuffer = device.makeBuffer(length: outputSize, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }

        // Fill input buffer (same layout as circular fit)
        let inputPtr = inputBuffer.contents()
        for (i, s) in stars.enumerated() {
            let offset = i * 16
            inputPtr.storeBytes(of: s.x, toByteOffset: offset, as: Float.self)
            inputPtr.storeBytes(of: s.y, toByteOffset: offset + 4, as: Float.self)
            inputPtr.storeBytes(of: s.background, toByteOffset: offset + 8, as: Float.self)
            inputPtr.storeBytes(of: s.peakBrightness, toByteOffset: offset + 12, as: Float.self)
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(inputBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        var w = Int32(image.width)
        var h = Int32(image.height)
        var ch = Int32(min(channel, image.channelCount - 1))
        var cc = Int32(image.channelCount)
        var sc = Int32(count)
        encoder.setBytes(&w, length: 4, index: 3)
        encoder.setBytes(&h, length: 4, index: 4)
        encoder.setBytes(&ch, length: 4, index: 5)
        encoder.setBytes(&cc, length: 4, index: 6)
        encoder.setBytes(&sc, length: 4, index: 7)

        let tg = MTLSize(width: min(64, count), height: 1, depth: 1)
        let grid = MTLSize(width: (count + 63) / 64, height: 1, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read results (5 floats = 20 bytes per star)
        let outPtr = outputBuffer.contents()
        var results: [PSFEllipticalResult] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            let offset = i * 20
            results.append(PSFEllipticalResult(
                amplitude: outPtr.load(fromByteOffset: offset, as: Float.self),
                sigmaX: outPtr.load(fromByteOffset: offset + 4, as: Float.self),
                sigmaY: outPtr.load(fromByteOffset: offset + 8, as: Float.self),
                theta: outPtr.load(fromByteOffset: offset + 12, as: Float.self),
                chi2: outPtr.load(fromByteOffset: offset + 16, as: Float.self)
            ))
        }
        return results
    }
}
