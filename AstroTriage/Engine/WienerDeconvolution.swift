// GPU Wiener-like deconvolution — noise-regularized sharpening at PSF-matched scale
// Uses Metal compute kernels: box blur at FWHM radius + Wiener-like sharpening blend
import Foundation
import Metal

enum WienerDeconvolution {

    static func deconvolve(data: [Float], width: Int, height: Int,
                           channelCount: Int, fwhm: Float, strength: Float,
                           device: MTLDevice? = nil) -> [Float] {
        guard strength > 0.01, fwhm > 0.5 else { return data }
        if let device = device ?? MTLCreateSystemDefaultDevice() {
            if let result = gpuDeconvolve(data: data, width: width, height: height,
                                          channelCount: channelCount, fwhm: fwhm,
                                          strength: strength, device: device) {
                return result
            }
        }
        return data
    }

    private static func gpuDeconvolve(data: [Float], width: Int, height: Int,
                                       channelCount: Int, fwhm: Float, strength: Float,
                                       device: MTLDevice) -> [Float]? {
        let totalSize = width * height * channelCount
        // Use FWHM directly as radius — the PSF extends well beyond sigma
        let radius = max(2, Int(ceil(fwhm)))

        // Estimate noise (CPU, subsampled — instant)
        let noiseLevel = estimateNoise(data, planeSize: width * height)

        guard let library = device.makeDefaultLibrary(),
              let blurFunc = library.makeFunction(name: "box_blur_pass"),
              let wienerFunc = library.makeFunction(name: "wiener_sharpen"),
              let blurPipeline = try? device.makeComputePipelineState(function: blurFunc),
              let wienerPipeline = try? device.makeComputePipelineState(function: wienerFunc),
              let queue = device.makeCommandQueue() else { return nil }

        let inputBuf = device.makeBuffer(bytes: data, length: totalSize * 4, options: .storageModeShared)!
        let tempBuf = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!
        let blurredBuf = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!
        let outputBuf = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!

        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let g = MTLSize(width: (width + 31) / 32, height: (height + 31) / 32, depth: 1)

        // Blur at PSF radius (2-pass box blur)
        guard let cmd1 = queue.makeCommandBuffer() else { return nil }

        func blurPass(input: MTLBuffer, output: MTLBuffer, r: Int, dir: Int, cmdBuf: MTLCommandBuffer) {
            var params = (Int32(width), Int32(height), Int32(channelCount), Int32(r), Int32(dir))
            let pb = device.makeBuffer(bytes: &params, length: MemoryLayout.size(ofValue: params), options: .storageModeShared)!
            let enc = cmdBuf.makeComputeCommandEncoder()!
            enc.setComputePipelineState(blurPipeline)
            enc.setBuffer(input, offset: 0, index: 0)
            enc.setBuffer(output, offset: 0, index: 1)
            enc.setBuffer(pb, offset: 0, index: 2)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        blurPass(input: inputBuf, output: tempBuf, r: radius, dir: 0, cmdBuf: cmd1)
        blurPass(input: tempBuf, output: blurredBuf, r: radius, dir: 1, cmdBuf: cmd1)
        blurPass(input: blurredBuf, output: tempBuf, r: radius, dir: 0, cmdBuf: cmd1)
        blurPass(input: tempBuf, output: blurredBuf, r: radius, dir: 1, cmdBuf: cmd1)
        cmd1.commit()
        cmd1.waitUntilCompleted()

        // Pass 1: Primary sharpening at PSF radius
        guard let cmd2 = queue.makeCommandBuffer() else { return nil }
        var wienerParams = (Int32(width), Int32(height), Int32(channelCount), strength, noiseLevel)
        let wpBuf = device.makeBuffer(bytes: &wienerParams, length: MemoryLayout.size(ofValue: wienerParams), options: .storageModeShared)!
        let enc2 = cmd2.makeComputeCommandEncoder()!
        enc2.setComputePipelineState(wienerPipeline)
        enc2.setBuffer(inputBuf, offset: 0, index: 0)
        enc2.setBuffer(blurredBuf, offset: 0, index: 1)
        enc2.setBuffer(outputBuf, offset: 0, index: 2)
        enc2.setBuffer(wpBuf, offset: 0, index: 3)
        enc2.dispatchThreadgroups(g, threadsPerThreadgroup: tg)
        enc2.endEncoding()
        cmd2.commit()
        cmd2.waitUntilCompleted()

        // Pass 2: Halo reduction at 2x radius (gentler)
        let haloRadius = radius * 2
        guard let cmd3 = queue.makeCommandBuffer() else { return nil }
        blurPass(input: outputBuf, output: tempBuf, r: haloRadius, dir: 0, cmdBuf: cmd3)
        blurPass(input: tempBuf, output: blurredBuf, r: haloRadius, dir: 1, cmdBuf: cmd3)
        blurPass(input: blurredBuf, output: tempBuf, r: haloRadius, dir: 0, cmdBuf: cmd3)
        blurPass(input: tempBuf, output: blurredBuf, r: haloRadius, dir: 1, cmdBuf: cmd3)
        cmd3.commit()
        cmd3.waitUntilCompleted()

        // Apply halo pass at reduced strength
        guard let cmd4 = queue.makeCommandBuffer() else { return nil }
        var haloParams = (Int32(width), Int32(height), Int32(channelCount), strength * 0.3, noiseLevel)
        let hpBuf = device.makeBuffer(bytes: &haloParams, length: MemoryLayout.size(ofValue: haloParams), options: .storageModeShared)!
        let enc4 = cmd4.makeComputeCommandEncoder()!
        enc4.setComputePipelineState(wienerPipeline)
        enc4.setBuffer(outputBuf, offset: 0, index: 0)  // use pass 1 output as input
        enc4.setBuffer(blurredBuf, offset: 0, index: 1)
        enc4.setBuffer(tempBuf, offset: 0, index: 2)     // write to temp
        enc4.setBuffer(hpBuf, offset: 0, index: 3)
        enc4.dispatchThreadgroups(g, threadsPerThreadgroup: tg)
        enc4.endEncoding()
        cmd4.commit()
        cmd4.waitUntilCompleted()

        let ptr = tempBuf.contents().bindMemory(to: Float.self, capacity: totalSize)
        return Array(UnsafeBufferPointer(start: ptr, count: totalSize))
    }

    private static func estimateNoise(_ data: [Float], planeSize: Int) -> Float {
        let stride = max(1, planeSize / 10000)
        var samples = [Float]()
        samples.reserveCapacity(10000)
        for i in Swift.stride(from: 0, to: planeSize, by: stride) {
            samples.append(data[i])
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let deviations = samples.map { Swift.abs($0 - median) }.sorted()
        return deviations[deviations.count / 2] * 1.4826
    }
}
