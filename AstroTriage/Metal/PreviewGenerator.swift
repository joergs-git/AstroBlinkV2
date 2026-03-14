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
}

class PreviewGenerator {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let computePipeline: MTLComputePipelineState
    let debayerPipeline: MTLComputePipelineState?
    let bin2xPipeline: MTLComputePipelineState?
    let postProcessPipeline: MTLComputePipelineState?
    let starDetectPipeline: MTLComputePipelineState?

    // Bayer pattern string to shader index mapping
    private static let bayerPatternMap: [String: Int] = [
        "RGGB": 0, "GRBG": 1, "GBRG": 2, "BGGR": 3
    ]

    init?(device: MTLDevice) {
        self.device = device

        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
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
        postProcessParams: (sharpening: Float, contrast: Float, darkLevel: Float)? = nil
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
                    channelCount: image.channelCount)
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

        return CachedPreview(
            texture: finalTexture,
            stfParams: stfParams,
            originalWidth: image.width,
            originalHeight: image.height,
            channelCount: image.channelCount
        )
    }

    // MARK: - GPU Star Detection

    // Maximum candidates the GPU kernel can emit (capped by atomic counter)
    private static let maxGPUCandidates = 512

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

        // Sort by brightness (brightest first) and cap at 50
        stars.sort()
        lastTotalStarCount = rawCount  // True total from GPU atomic counter (not capped)
        return Array(stars.prefix(50))
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

        // Compute threshold on CPU from 5% subsample (~2ms)
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
        return detectStarsGPU(
            binnedBuffer: binnedBuffer,
            binnedWidth: binnedW,
            binnedHeight: binnedH,
            channelCount: channels,
            channel: channel,
            median: median,
            threshold: threshold
        )
    }
}
