// v0.1.0
import Metal

// Basic texture reuse pool to avoid repeated allocation/deallocation
// Uses NSCache with explicit cost for proper memory pressure handling (Lesson L3)
class TexturePool {
    private let device: MTLDevice
    private let cache = NSCache<NSString, TextureWrapper>()

    init(device: MTLDevice) {
        self.device = device
        // Limit cache to reasonable memory budget
        let systemMemory = ProcessInfo.processInfo.physicalMemory
        let maxCostBytes = systemMemory / 16 // ~4GB on 64GB system
        cache.totalCostLimit = Int(maxCostBytes)
    }

    // Get or create a texture for the given dimensions
    func texture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let key = "\(width)x\(height)x\(pixelFormat.rawValue)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached.texture
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        // Explicit cost for NSCache (Lesson L3)
        let cost = width * height * 4 // BGRA8 = 4 bytes/pixel
        cache.setObject(TextureWrapper(texture: texture), forKey: key, cost: cost)

        return texture
    }

    func clearAll() {
        cache.removeAllObjects()
    }
}

// NSCache requires NSObject-based values
private class TextureWrapper: NSObject {
    let texture: MTLTexture
    init(texture: MTLTexture) {
        self.texture = texture
    }
}
