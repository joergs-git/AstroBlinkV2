// v0.1.0
import Foundation
import Metal
import ImageDecoderBridge

// Swift wrapper around the C bridge for decoding FITS/XISF files
// Handles memory management (Lesson L4) and Metal buffer creation
struct ImageDecoder {

    // Decode an image file and return pixel data in a Metal buffer
    // Uses MTLStorageModeShared for zero-copy unified memory access
    static func decode(url: URL, device: MTLDevice) -> Result<DecodedImage, DecoderError> {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        var result: DecodeResult
        if ext == "xisf" {
            result = decode_xisf(path)
        } else {
            result = decode_fits(path)
        }

        guard result.success != 0 else {
            let errorMsg = withUnsafePointer(to: result.error) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            return .failure(.decodeFailed(errorMsg))
        }

        // Ensure we free the C-allocated pixels when done (Lesson L4)
        defer { free_decode_result(&result) }

        let width = Int(result.width)
        let height = Int(result.height)
        let channels = Int(result.channelCount)
        let byteCount = width * height * channels * MemoryLayout<UInt16>.size

        // Create Metal buffer with shared storage (zero-copy on Apple Silicon)
        guard let buffer = device.makeBuffer(bytes: result.pixels, length: byteCount, options: .storageModeShared) else {
            return .failure(.metalBufferFailed)
        }

        return .success(DecodedImage(
            buffer: buffer,
            width: width,
            height: height,
            channelCount: channels
        ))
    }

    enum DecoderError: Error, LocalizedError {
        case decodeFailed(String)
        case metalBufferFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed(let msg): return "Decode failed: \(msg)"
            case .metalBufferFailed: return "Failed to create Metal buffer"
            }
        }
    }
}
