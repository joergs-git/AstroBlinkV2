// GPU structure enhancement — multi-scale local contrast boost for nebula/cloud detail
// Uses Metal compute kernels: separable box blur at two scales + detail blend
import Foundation
import Metal

enum StructureEnhancement {

    static func enhance(data: [Float], width: Int, height: Int,
                        channelCount: Int, amount: Float,
                        device: MTLDevice? = nil) -> [Float] {
        guard amount > 0.01 else { return data }
        if let device = device ?? MTLCreateSystemDefaultDevice() {
            if let result = gpuEnhance(data: data, width: width, height: height,
                                       channelCount: channelCount, amount: amount, device: device) {
                return result
            }
        }
        return data
    }

    private static func gpuEnhance(data: [Float], width: Int, height: Int,
                                    channelCount: Int, amount: Float, device: MTLDevice) -> [Float]? {
        let totalSize = width * height * channelCount

        guard let library = device.makeDefaultLibrary(),
              let blurFunc = library.makeFunction(name: "box_blur_pass"),
              let blendFunc = library.makeFunction(name: "structure_blend"),
              let blurPipeline = try? device.makeComputePipelineState(function: blurFunc),
              let blendPipeline = try? device.makeComputePipelineState(function: blendFunc),
              let queue = device.makeCommandQueue() else { return nil }

        let inputBuf = device.makeBuffer(bytes: data, length: totalSize * 4, options: .storageModeShared)!
        let tempBuf1 = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!
        let tempBuf2 = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!
        let blurSmallBuf = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!
        let blurLargeBuf = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!
        let outputBuf = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!

        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let g = MTLSize(width: (width + 31) / 32, height: (height + 31) / 32, depth: 1)

        // Helper: run one blur pass (direction: 0=horizontal, 1=vertical)
        func blurPass(input: MTLBuffer, output: MTLBuffer, radius: Int, direction: Int, cmdBuf: MTLCommandBuffer) {
            var params = (Int32(width), Int32(height), Int32(channelCount), Int32(radius), Int32(direction))
            let paramsBuf = device.makeBuffer(bytes: &params, length: MemoryLayout.size(ofValue: params), options: .storageModeShared)!
            let encoder = cmdBuf.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(blurPipeline)
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.setBuffer(paramsBuf, offset: 0, index: 2)
            encoder.dispatchThreadgroups(g, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        // Small blur (radius 15): 2-pass box blur = H→V→H→V
        guard let cmd1 = queue.makeCommandBuffer() else { return nil }
        blurPass(input: inputBuf, output: tempBuf1, radius: 15, direction: 0, cmdBuf: cmd1)
        blurPass(input: tempBuf1, output: tempBuf2, radius: 15, direction: 1, cmdBuf: cmd1)
        blurPass(input: tempBuf2, output: tempBuf1, radius: 15, direction: 0, cmdBuf: cmd1)
        blurPass(input: tempBuf1, output: blurSmallBuf, radius: 15, direction: 1, cmdBuf: cmd1)
        cmd1.commit()
        cmd1.waitUntilCompleted()

        // Large blur (radius 40): 2-pass box blur
        guard let cmd2 = queue.makeCommandBuffer() else { return nil }
        blurPass(input: inputBuf, output: tempBuf1, radius: 40, direction: 0, cmdBuf: cmd2)
        blurPass(input: tempBuf1, output: tempBuf2, radius: 40, direction: 1, cmdBuf: cmd2)
        blurPass(input: tempBuf2, output: tempBuf1, radius: 40, direction: 0, cmdBuf: cmd2)
        blurPass(input: tempBuf1, output: blurLargeBuf, radius: 40, direction: 1, cmdBuf: cmd2)
        cmd2.commit()
        cmd2.waitUntilCompleted()

        // Blend: combine detail layers
        guard let cmd3 = queue.makeCommandBuffer() else { return nil }
        var blendParams = (Int32(width), Int32(height), Int32(channelCount), amount * 1.5, Float(0.0))
        let blendParamsBuf = device.makeBuffer(bytes: &blendParams, length: MemoryLayout.size(ofValue: blendParams), options: .storageModeShared)!
        let encoder = cmd3.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(blendPipeline)
        encoder.setBuffer(inputBuf, offset: 0, index: 0)
        encoder.setBuffer(blurLargeBuf, offset: 0, index: 1)
        encoder.setBuffer(blurSmallBuf, offset: 0, index: 2)
        encoder.setBuffer(outputBuf, offset: 0, index: 3)
        encoder.setBuffer(blendParamsBuf, offset: 0, index: 4)
        encoder.dispatchThreadgroups(g, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cmd3.commit()
        cmd3.waitUntilCompleted()

        let ptr = outputBuf.contents().bindMemory(to: Float.self, capacity: totalSize)
        return Array(UnsafeBufferPointer(start: ptr, count: totalSize))
    }
}
