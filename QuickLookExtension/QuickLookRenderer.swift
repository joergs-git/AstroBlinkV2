// v2.0.2
import Foundation
import CoreGraphics
import Dispatch

// CPU-based STF renderer for QuickLook extension.
// Applies PixInsight-compatible auto-stretch and outputs a CGImage.
// Uses pre-computed LUT + parallel row processing for maximum CPU throughput.
struct QuickLookRenderer {

    // Render decoded image data with STF stretch to a CGImage.
    // Uses a 65536-entry LUT per channel to avoid per-pixel float math,
    // and processes rows in parallel across all CPU cores.
    static func renderToImage(
        imageData: QuickLookImageData,
        stfParams: [QuickLookSTFParams],
        targetWidth: Int,
        targetHeight: Int
    ) -> CGImage? {
        let srcW = imageData.width
        let srcH = imageData.height
        let channels = imageData.channelCount
        let pixels = imageData.pixels

        // Determine if we need to downsample
        let binX = max(1, srcW / targetWidth)
        let binY = max(1, srcH / targetHeight)
        let outW = srcW / binX
        let outH = srcH / binY

        // Build per-channel LUT: uint16 [0..65535] → UInt8 [0..255]
        // This pre-computes the entire STF stretch so the inner loop is just table lookups
        var luts = [[UInt8]]()
        for ch in 0..<min(channels, stfParams.count) {
            luts.append(buildLUT(params: stfParams[ch]))
        }
        // Fallback: if fewer params than channels, reuse first
        while luts.count < channels {
            luts.append(luts[0])
        }

        // Allocate BGRA8 output buffer
        let bytesPerRow = outW * 4
        let bufferSize = outH * bytesPerRow
        guard let outputBuffer = calloc(bufferSize, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        defer { free(outputBuffer) }

        let planeSize = srcW * srcH

        // Process rows in parallel across all CPU cores
        if channels == 1 {
            let lut = luts[0]
            DispatchQueue.concurrentPerform(iterations: outH) { y in
                let srcY = y * binY
                let rowOffset = y * bytesPerRow
                for x in 0..<outW {
                    let srcIdx = srcY * srcW + x * binX
                    let byte = lut[Int(pixels[srcIdx])]
                    outputBuffer[rowOffset + x * 4 + 0] = byte  // B
                    outputBuffer[rowOffset + x * 4 + 1] = byte  // G
                    outputBuffer[rowOffset + x * 4 + 2] = byte  // R
                    outputBuffer[rowOffset + x * 4 + 3] = 255   // A
                }
            }
        } else if channels == 3 {
            let lutR = luts[0]
            let lutG = luts[1]
            let lutB = luts[2]
            DispatchQueue.concurrentPerform(iterations: outH) { y in
                let srcY = y * binY
                let rowOffset = y * bytesPerRow
                for x in 0..<outW {
                    let srcIdx = srcY * srcW + x * binX
                    let r = lutR[Int(pixels[srcIdx])]
                    let g = lutG[Int(pixels[planeSize + srcIdx])]
                    let b = lutB[Int(pixels[2 * planeSize + srcIdx])]
                    outputBuffer[rowOffset + x * 4 + 0] = b
                    outputBuffer[rowOffset + x * 4 + 1] = g
                    outputBuffer[rowOffset + x * 4 + 2] = r
                    outputBuffer[rowOffset + x * 4 + 3] = 255
                }
            }
        } else {
            // Fallback for other channel counts
            let lut = luts[0]
            DispatchQueue.concurrentPerform(iterations: outH) { y in
                let srcY = y * binY
                let rowOffset = y * bytesPerRow
                for x in 0..<outW {
                    let srcIdx = srcY * srcW + x * binX
                    let byte = lut[Int(pixels[srcIdx])]
                    outputBuffer[rowOffset + x * 4 + 0] = byte
                    outputBuffer[rowOffset + x * 4 + 1] = byte
                    outputBuffer[rowOffset + x * 4 + 2] = byte
                    outputBuffer[rowOffset + x * 4 + 3] = 255
                }
            }
        }

        // Create CGImage from BGRA buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: outputBuffer,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }

    // Build a 65536-entry lookup table mapping uint16 → stretched UInt8.
    // Pre-computes the full STF stretch so the rendering loop is just table lookups.
    private static func buildLUT(params: QuickLookSTFParams) -> [UInt8] {
        let c0 = params.c0
        let mb = params.mb
        let invRange = 1.0 / (1.0 - c0)

        return (0..<65536).map { i in
            var v = Float(i) / 65535.0

            // Clip shadows and rescale
            v = (v - c0) * invRange
            if v <= 0.0 { return 0 }
            if v >= 1.0 { return 255 }

            // Midtones Transfer Function (inlined for LUT build performance)
            if v == mb { v = 0.5 }
            else { v = (mb - 1.0) * v / ((2.0 * mb - 1.0) * v - mb) }

            // Scale to byte
            let byte = Int(v * 255.0 + 0.5)
            return UInt8(max(0, min(255, byte)))
        }
    }
}
