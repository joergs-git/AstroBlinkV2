// v2.0.0
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

        // Create output BGRA8 texture at binned resolution
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: binnedW,
            height: binnedH,
            mipmapped: false
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
            // Create a second texture for post-process output
            let ppTexDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: binnedW,
                height: binnedH,
                mipmapped: false
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
}
