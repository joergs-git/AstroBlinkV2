import XCTest
@testable import AstroTriage

/// Diagnostic test to find the GPU star detection coordinate bug.
/// Compares CPU vs GPU star detection on the same image to find the discrepancy.
final class GPUStarDetectionTests: XCTestCase {

    /// Compare CPU and GPU star detection coordinates on a real FITS file.
    /// The CPU path (subsampleFactor=4) is proven correct.
    /// The GPU path (bin2x + detect_stars_binned) clusters stars on the left.
    func testCPUvsGPUStarCoordinates() throws {
        // Find a test FITS file
        let testDir = URL(fileURLWithPath: "/Users/joergklaas/Library/Containers/com.joergsflow.AstroBlinkV2/Data/tmp/AstroTriage_StarAnalysis")
        let fm = FileManager.default

        // Look for any .fits or .fit file in the test analysis directory
        var testFile: URL?
        if fm.fileExists(atPath: testDir.path),
           let contents = try? fm.contentsOfDirectory(at: testDir, includingPropertiesForKeys: nil) {
            for folder in contents where folder.hasDirectoryPath {
                if let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    testFile = files.first(where: {
                        ["fits", "fit", "xisf"].contains($0.pathExtension.lowercased())
                    })
                    if testFile != nil { break }
                }
            }
        }

        // Fallback: check TestImages
        if testFile == nil {
            let projectDir = URL(fileURLWithPath: "/Users/joergklaas/Desktop/claude-code/AstroTriage-blinkV2")
            let testImages = projectDir.appendingPathComponent("TestImages")
            if let files = try? fm.contentsOfDirectory(at: testImages, includingPropertiesForKeys: nil) {
                testFile = files.first(where: {
                    ["fits", "fit", "xisf"].contains($0.pathExtension.lowercased())
                })
            }
        }

        guard let file = testFile else {
            print("No test image found — skipping GPU star detection test")
            return
        }

        print("\n=== GPU vs CPU Star Detection Test ===")
        print("File: \(file.lastPathComponent)")

        // Decode the image
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("No Metal device — skipping GPU test")
            return
        }
        let decodeResult = ImageDecoder.decode(url: file, device: device)
        guard case .success(let image) = decodeResult else {
            XCTFail("Failed to decode \(file.lastPathComponent)")
            return
        }

        print("Image: \(image.width) × \(image.height), \(image.channelCount) channel(s)")

        // === CPU Detection (known correct) ===
        let cpuResult = StarDetector.detectStarsWithTotalCount(
            in: image, maxStars: 50, subsampleFactor: 4,
            sigmaThreshold: 5.0, channel: 0
        )
        print("\nCPU detected: \(cpuResult.stars.count) stars (total: \(cpuResult.totalCount))")

        if !cpuResult.stars.isEmpty {
            let cpuXs = cpuResult.stars.map { $0.x }
            let cpuYs = cpuResult.stars.map { $0.y }
            print("  X range: \(String(format: "%.1f", cpuXs.min()!)) - \(String(format: "%.1f", cpuXs.max()!))")
            print("  Y range: \(String(format: "%.1f", cpuYs.min()!)) - \(String(format: "%.1f", cpuYs.max()!))")
            print("  X normalized: \(String(format: "%.3f", cpuXs.min()! / Float(image.width))) - \(String(format: "%.3f", cpuXs.max()! / Float(image.width)))")
            print("  Y normalized: \(String(format: "%.3f", cpuYs.min()! / Float(image.height))) - \(String(format: "%.3f", cpuYs.max()! / Float(image.height)))")

            // Print first 5 stars
            for (i, star) in cpuResult.stars.prefix(5).enumerated() {
                print("  CPU star[\(i)]: x=\(String(format: "%.1f", star.x)) y=\(String(format: "%.1f", star.y)) bright=\(String(format: "%.0f", star.brightness))")
            }
        }

        // === GPU Detection ===
        guard let generator = PreviewGenerator(device: device) else {
            print("Failed to create PreviewGenerator")
            return
        }
        let gpuStars = generator.detectStarsFromImage(image, channel: 0)
        let gpuTotal = generator.lastTotalStarCount

        print("\nGPU detected: \(gpuStars.count) stars (total: \(gpuTotal))")

        if !gpuStars.isEmpty {
            let gpuXs = gpuStars.map { $0.x }
            let gpuYs = gpuStars.map { $0.y }
            print("  X range: \(String(format: "%.1f", gpuXs.min()!)) - \(String(format: "%.1f", gpuXs.max()!))")
            print("  Y range: \(String(format: "%.1f", gpuYs.min()!)) - \(String(format: "%.1f", gpuYs.max()!))")
            print("  X normalized: \(String(format: "%.3f", gpuXs.min()! / Float(image.width))) - \(String(format: "%.3f", gpuXs.max()! / Float(image.width)))")
            print("  Y normalized: \(String(format: "%.3f", gpuYs.min()! / Float(image.height))) - \(String(format: "%.3f", gpuYs.max()! / Float(image.height)))")

            for (i, star) in gpuStars.prefix(5).enumerated() {
                print("  GPU star[\(i)]: x=\(String(format: "%.1f", star.x)) y=\(String(format: "%.1f", star.y)) bright=\(String(format: "%.0f", star.brightness))")
            }
        }

        // === Compare ===
        if !cpuResult.stars.isEmpty && !gpuStars.isEmpty {
            let cpuXRange = cpuResult.stars.map { $0.x }.max()! - cpuResult.stars.map { $0.x }.min()!
            let gpuXRange = gpuStars.map { $0.x }.max()! - gpuStars.map { $0.x }.min()!
            let cpuYRange = cpuResult.stars.map { $0.y }.max()! - cpuResult.stars.map { $0.y }.min()!
            let gpuYRange = gpuStars.map { $0.y }.max()! - gpuStars.map { $0.y }.min()!

            print("\n=== Comparison ===")
            print("  CPU X spread: \(String(format: "%.1f", cpuXRange)) px (\(String(format: "%.1f", cpuXRange / Float(image.width) * 100))% of width)")
            print("  GPU X spread: \(String(format: "%.1f", gpuXRange)) px (\(String(format: "%.1f", gpuXRange / Float(image.width) * 100))% of width)")
            print("  CPU Y spread: \(String(format: "%.1f", cpuYRange)) px (\(String(format: "%.1f", cpuYRange / Float(image.height) * 100))% of height)")
            print("  GPU Y spread: \(String(format: "%.1f", gpuYRange)) px (\(String(format: "%.1f", gpuYRange / Float(image.height) * 100))% of height)")

            // The bug: GPU X spread should be similar to CPU X spread
            // If GPU X spread is < 20% of image width while CPU is > 50%, that's the bug
            let gpuXPct = gpuXRange / Float(image.width) * 100
            let cpuXPct = cpuXRange / Float(image.width) * 100

            if gpuXPct < cpuXPct * 0.5 {
                print("\n  *** BUG CONFIRMED: GPU X spread (\(String(format: "%.1f", gpuXPct))%) is much smaller than CPU (\(String(format: "%.1f", cpuXPct))%) ***")

                // Detailed investigation: check raw bin2x star coordinates before ×2 scaling
                print("\n=== Detailed GPU Investigation ===")

                // Compute threshold (same as detectStarsFromImage)
                guard let (median, threshold) = StarDetector.computeThreshold(
                    from: image, subsampleFactor: 2, sigmaThreshold: 5.0, channel: 0
                ) else {
                    print("  Failed to compute threshold")
                    return
                }
                print("  Threshold median=\(String(format: "%.1f", median)) threshold=\(String(format: "%.1f", threshold))")

                // Create bin2x buffer manually and inspect
                let binnedW = image.width / 2
                let binnedH = image.height / 2
                let channels = image.channelCount
                let binnedBytes = binnedW * binnedH * channels * MemoryLayout<UInt16>.size

                guard let binnedBuffer = device.makeBuffer(length: binnedBytes, options: .storageModeShared) else {
                    print("  Failed to create binned buffer")
                    return
                }

                // Run bin2x GPU kernel
                guard let library = device.makeDefaultLibrary(),
                      let bin2xFunc = library.makeFunction(name: "bin2x"),
                      let bin2xPipeline = try? device.makeComputePipelineState(function: bin2xFunc) else {
                    print("  Failed to create bin2x pipeline")
                    return
                }

                guard let cb1 = generator.commandQueue.makeCommandBuffer(),
                      let enc1 = cb1.makeComputeCommandEncoder() else { return }

                enc1.setComputePipelineState(bin2xPipeline)
                enc1.setBuffer(image.buffer, offset: 0, index: 0)
                enc1.setBuffer(binnedBuffer, offset: 0, index: 1)
                var sw = Int32(image.width)
                var sh = Int32(image.height)
                var cc = Int32(channels)
                enc1.setBytes(&sw, length: 4, index: 2)
                enc1.setBytes(&sh, length: 4, index: 3)
                enc1.setBytes(&cc, length: 4, index: 4)
                let tg = MTLSize(width: 32, height: 32, depth: 1)
                let grid = MTLSize(width: (binnedW + 31) / 32, height: (binnedH + 31) / 32, depth: 1)
                enc1.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                enc1.endEncoding()
                cb1.commit()
                cb1.waitUntilCompleted()

                // Inspect binned buffer: check a few pixels at different X positions
                let binnedPtr = binnedBuffer.contents().bindMemory(to: UInt16.self, capacity: binnedW * binnedH * channels)
                let midY = binnedH / 2

                print("\n  Binned buffer inspection (row \(midY), channel 0):")
                let chOffset = 0 // channel 0
                let checkPositions = [10, binnedW/4, binnedW/2, binnedW*3/4, binnedW-10]
                for x in checkPositions {
                    let idx = chOffset + midY * binnedW + x
                    let val = binnedPtr[idx]
                    print("    binned[\(x), \(midY)] = \(val) (threshold=\(String(format: "%.0f", threshold)))")
                }

                // Also check: scan across the middle row for peaks above threshold
                var peaksInRow: [(x: Int, val: UInt16)] = []
                for x in 3..<(binnedW - 3) {
                    let idx = chOffset + midY * binnedW + x
                    let val = Float(binnedPtr[idx])
                    if val > threshold {
                        // Local max check
                        var isMax = true
                        for dx in -1...1 {
                            for dy in -1...1 {
                                if dx == 0 && dy == 0 { continue }
                                let nIdx = chOffset + (midY + dy) * binnedW + (x + dx)
                                if Float(binnedPtr[nIdx]) >= val { isMax = false; break }
                            }
                            if !isMax { break }
                        }
                        if isMax { peaksInRow.append((x: x, val: binnedPtr[idx])) }
                    }
                }
                print("\n  Peaks above threshold in row \(midY): \(peaksInRow.count)")
                for p in peaksInRow.prefix(10) {
                    print("    peak at x=\(p.x) (\(String(format: "%.1f", Float(p.x) / Float(binnedW) * 100))% of width) val=\(p.val)")
                }

                // Scan ALL rows for peaks — check X distribution
                var allPeakXs: [Float] = []
                for y in stride(from: 3, to: binnedH - 3, by: 5) { // Sample every 5th row
                    for x in 3..<(binnedW - 3) {
                        let idx = chOffset + y * binnedW + x
                        let val = Float(binnedPtr[idx])
                        if val > threshold {
                            var isMax = true
                            for dx in -1...1 {
                                for dy in -1...1 {
                                    if dx == 0 && dy == 0 { continue }
                                    let nIdx = chOffset + (y + dy) * binnedW + (x + dx)
                                    if Float(binnedPtr[nIdx]) >= val { isMax = false; break }
                                }
                                if !isMax { break }
                            }
                            if isMax { allPeakXs.append(Float(x)) }
                        }
                    }
                }
                print("\n  CPU scan of binned buffer: \(allPeakXs.count) peaks found")
                if !allPeakXs.isEmpty {
                    print("    X range: \(String(format: "%.0f", allPeakXs.min()!)) - \(String(format: "%.0f", allPeakXs.max()!))")
                    print("    X normalized: \(String(format: "%.3f", allPeakXs.min()! / Float(binnedW))) - \(String(format: "%.3f", allPeakXs.max()! / Float(binnedW)))")
                }

            } else {
                print("\n  GPU coordinates look correct — X spread is adequate")
            }
        }
    }
}
