// v0.1.0
import Metal

// Wrapper for decoded image data held in a Metal buffer
struct DecodedImage {
    let buffer: MTLBuffer       // uint16 pixel data in shared memory (zero-copy)
    let width: Int
    let height: Int
    let channelCount: Int       // 1=mono, 3=RGB (planar)

    var pixelCount: Int { width * height * channelCount }
    var bytesPerPixel: Int { 2 } // uint16
    var totalBytes: Int { pixelCount * bytesPerPixel }
}
