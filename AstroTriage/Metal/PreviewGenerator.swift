// v0.7.0
import Foundation
import Metal

// Generates pre-stretched, downsampled BGRA8 preview textures for instant navigation.
// Uses its own Metal compute pipeline (same shader as MetalRenderer) to run
// independently of the draw cycle. Bins uint16 data 2x on CPU, then applies
// STF stretch on GPU, producing a small (~5MB) ready-to-display texture.

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
    }

    // Generate a pre-stretched, bin2x preview texture from raw decoded image data.
    // This runs synchronously on the calling thread (compute is fast, ~5ms).
    func generatePreview(from image: DecodedImage, stfParams: [STFParams]) -> CachedPreview? {
        // Step 1: CPU bin2x — average every 2x2 block of uint16 pixels
        let binnedResult = bin2x(image: image)
        guard let binnedBuffer = binnedResult.buffer else { return nil }

        let binnedW = binnedResult.width
        let binnedH = binnedResult.height
        let channels = image.channelCount

        // Step 2: Prepare STF buffer (pad mono to 3 channels)
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

        // Step 3: Create output BGRA8 texture at binned resolution
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: binnedW,
            height: binnedH,
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .private

        guard let outTexture = device.makeTexture(descriptor: texDesc) else { return nil }

        // Step 4: Run compute shader — STF stretch on binned data
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

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

        let threadgroupSize = MTLSize(width: 32, height: 32, depth: 1)
        let gridSize = MTLSize(
            width: (binnedW + 31) / 32,
            height: (binnedH + 31) / 32,
            depth: 1
        )
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return CachedPreview(
            texture: outTexture,
            stfParams: stfParams,
            originalWidth: image.width,
            originalHeight: image.height,
            channelCount: image.channelCount
        )
    }

    // MARK: - CPU bin2x

    // Average every 2x2 block of uint16 pixels → half-resolution MTLBuffer.
    // For planar data (mono or RGB), each channel plane is binned independently.
    private func bin2x(image: DecodedImage) -> (buffer: MTLBuffer?, width: Int, height: Int) {
        let srcW = image.width
        let srcH = image.height
        let channels = image.channelCount
        let newW = srcW / 2
        let newH = srcH / 2

        guard newW > 0, newH > 0 else {
            return (nil, 0, 0)
        }

        let src = image.buffer.contents().bindMemory(to: UInt16.self, capacity: srcW * srcH * channels)
        let dstCount = newW * newH * channels
        let dstBytes = dstCount * MemoryLayout<UInt16>.size

        guard let dstBuffer = device.makeBuffer(length: dstBytes, options: .storageModeShared) else {
            return (nil, 0, 0)
        }

        let dst = dstBuffer.contents().bindMemory(to: UInt16.self, capacity: dstCount)
        let planeSize = srcW * srcH
        let newPlaneSize = newW * newH

        for ch in 0..<channels {
            let srcPlane = src.advanced(by: ch * planeSize)
            let dstPlane = dst.advanced(by: ch * newPlaneSize)

            for y in 0..<newH {
                let sy = y * 2
                for x in 0..<newW {
                    let sx = x * 2
                    // Average 2x2 block
                    let sum = UInt32(srcPlane[sy * srcW + sx])
                            + UInt32(srcPlane[sy * srcW + sx + 1])
                            + UInt32(srcPlane[(sy + 1) * srcW + sx])
                            + UInt32(srcPlane[(sy + 1) * srcW + sx + 1])
                    dstPlane[y * newW + x] = UInt16(sum / 4)
                }
            }
        }

        return (dstBuffer, newW, newH)
    }
}
