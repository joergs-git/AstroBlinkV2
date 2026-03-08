// v2.0.0
import Foundation
import ImageDecoderBridge

// Lightweight image data container for QuickLook extension (no Metal dependency)
struct QuickLookImageData {
    let pixels: UnsafeMutablePointer<UInt16>
    let width: Int
    let height: Int
    let channelCount: Int
    let byteCount: Int

    // Free the C-allocated pixel buffer
    func free() {
        Darwin.free(pixels)
    }
}

// Decodes FITS/XISF files using the shared C bridge.
// Returns raw uint16 pixel data without Metal — QuickLook extensions
// run in a sandboxed process where GPU access may be limited.
struct QuickLookDecoder {

    static func decode(url: URL) -> QuickLookImageData? {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        var result: DecodeResult
        if ext == "xisf" {
            result = decode_xisf(path)
        } else {
            result = decode_fits(path)
        }

        guard result.success != 0 else {
            var mutableResult = result
            free_decode_result(&mutableResult)
            return nil
        }

        let width = Int(result.width)
        let height = Int(result.height)
        let channels = Int(result.channelCount)
        let byteCount = width * height * channels * MemoryLayout<UInt16>.size

        guard let pixels = result.pixels else {
            var mutableResult = result
            free_decode_result(&mutableResult)
            return nil
        }

        // Take ownership of the C-allocated buffer (don't free via free_decode_result)
        return QuickLookImageData(
            pixels: pixels,
            width: width,
            height: height,
            channelCount: channels,
            byteCount: byteCount
        )
    }
}

// Error types for QuickLook providers
enum QuickLookError: Error {
    case decodeFailed
    case renderFailed
}
