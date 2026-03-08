// v2.0.0
import Foundation
import Metal
import ImageDecoderBridge

// Swift wrapper around the C bridge for decoding FITS/XISF files
// Handles memory management (Lesson L4) and Metal buffer creation
struct ImageDecoder {

    // Decode an image file and return pixel data in a Metal buffer
    // Uses bytesNoCopy for true zero-copy: the C-allocated page-aligned buffer
    // becomes the MTLBuffer's backing memory directly — no memcpy.
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

        let width = Int(result.width)
        let height = Int(result.height)
        let channels = Int(result.channelCount)
        let byteCount = width * height * channels * MemoryLayout<UInt16>.size

        // Round up to page size for bytesNoCopy requirement
        let pageSize = Int(getpagesize())
        let alignedByteCount = (byteCount + pageSize - 1) / pageSize * pageSize

        // Zero-copy: wrap the page-aligned C allocation as MTLBuffer directly.
        // The deallocator frees the C memory when the MTLBuffer is released.
        let rawPtr = UnsafeMutableRawPointer(result.pixels)!
        guard let buffer = device.makeBuffer(
            bytesNoCopy: rawPtr,
            length: alignedByteCount,
            options: .storageModeShared,
            deallocator: { pointer, _ in
                free(pointer)
            }
        ) else {
            // Fallback: if bytesNoCopy fails, free C memory and report error
            free_decode_result(&result)
            return .failure(.metalBufferFailed)
        }

        // Do NOT call free_decode_result — MTLBuffer now owns the memory
        // and will free it via the deallocator when released

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
