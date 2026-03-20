// GPU gradient removal via median grid + Metal compute kernel
// CPU: compute 64 tile medians (fast, subsampled)
// GPU: interpolate grid and subtract background (instant)
import Foundation
import Metal

enum GradientRemoval {

    private static let gridSize = 8

    static func removeGradient(data: [Float], width: Int, height: Int, channelCount: Int,
                                device: MTLDevice? = nil) -> [Float] {
        // Try GPU path first
        if let device = device ?? MTLCreateSystemDefaultDevice() {
            if let result = gpuRemoveGradient(data: data, width: width, height: height,
                                              channelCount: channelCount, device: device) {
                return result
            }
        }
        return data  // fallback: return unchanged
    }

    private static func gpuRemoveGradient(data: [Float], width: Int, height: Int,
                                           channelCount: Int, device: MTLDevice) -> [Float]? {
        let planeSize = width * height
        let totalSize = planeSize * channelCount
        let tileW = width / gridSize
        let tileH = height / gridSize

        // Step 1 (CPU): Compute sigma-clipped median for each grid tile (subsampled — fast)
        var gridMedians = [Float](repeating: 0, count: gridSize * gridSize * channelCount)
        for ch in 0..<channelCount {
            let offset = ch * planeSize
            for gy in 0..<gridSize {
                for gx in 0..<gridSize {
                    let startX = gx * tileW
                    let startY = gy * tileH
                    let endX = min(startX + tileW, width)
                    let endY = min(startY + tileH, height)

                    var samples = [Float]()
                    let step = 4
                    for y in stride(from: startY, to: endY, by: step) {
                        for x in stride(from: startX, to: endX, by: step) {
                            samples.append(data[offset + y * width + x])
                        }
                    }
                    gridMedians[ch * gridSize * gridSize + gy * gridSize + gx] = sigmaClippedMedian(samples)
                }
            }
        }

        // Global median (for shift)
        let allMedians = gridMedians.prefix(gridSize * gridSize)
        let sorted = allMedians.sorted()
        let globalMedian = sorted[sorted.count / 2]

        // Step 2 (GPU): Interpolate grid and subtract
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "gradient_remove"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue(),
              let cmdBuf = queue.makeCommandBuffer() else { return nil }

        let inputBuf = device.makeBuffer(bytes: data, length: totalSize * 4, options: .storageModeShared)!
        let outputBuf = device.makeBuffer(length: totalSize * 4, options: .storageModeShared)!
        let gridBuf = device.makeBuffer(bytes: gridMedians, length: gridMedians.count * 4, options: .storageModeShared)!

        var params = (Int32(width), Int32(height), Int32(channelCount), Int32(gridSize), globalMedian)
        let paramsBuf = device.makeBuffer(bytes: &params, length: MemoryLayout.size(ofValue: params), options: .storageModeShared)!

        let encoder = cmdBuf.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuf, offset: 0, index: 0)
        encoder.setBuffer(outputBuf, offset: 0, index: 1)
        encoder.setBuffer(paramsBuf, offset: 0, index: 2)
        encoder.setBuffer(gridBuf, offset: 0, index: 3)

        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let g = MTLSize(width: (width + 31) / 32, height: (height + 31) / 32, depth: 1)
        encoder.dispatchThreadgroups(g, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let ptr = outputBuf.contents().bindMemory(to: Float.self, capacity: totalSize)
        return Array(UnsafeBufferPointer(start: ptr, count: totalSize))
    }

    private static func sigmaClippedMedian(_ pixels: [Float]) -> Float {
        guard !pixels.isEmpty else { return 0 }
        var filtered = pixels.sorted()
        for _ in 0..<2 {
            guard filtered.count > 10 else { break }
            let median = filtered[filtered.count / 2]
            let deviations = filtered.map { Swift.abs($0 - median) }
            let mad = deviations.sorted()[deviations.count / 2] * 1.4826
            guard mad > 0 else { break }
            let low = median - 2.5 * mad
            let high = median + 2.5 * mad
            filtered = filtered.filter { $0 >= low && $0 <= high }
        }
        guard !filtered.isEmpty else { return pixels.sorted()[pixels.count / 2] }
        return filtered[filtered.count / 2]
    }
}
