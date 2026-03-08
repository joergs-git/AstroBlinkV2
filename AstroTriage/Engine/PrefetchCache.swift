// v0.9.7
import Foundation
import Metal

// Pre-stretched preview cache: decodes ALL session images, bins 2x, applies STF,
// and caches the final BGRA8 texture. Navigation = just render the cached texture.
// No compute needed at display time → instant image switching.
@MainActor
class PrefetchCache {
    private var cache: [URL: CachedPreview] = [:]
    private let device: MTLDevice
    private let previewGenerator: PreviewGenerator?

    // Background prefetch task
    private var prefetchTask: Task<Void, Never>?

    // Concurrency: decode + stretch up to 4 images in parallel
    private let maxConcurrentDecodes = 4

    init(device: MTLDevice) {
        self.device = device
        self.previewGenerator = PreviewGenerator(device: device)
    }

    // Retrieve a cached pre-stretched preview, nil if not yet ready
    func getPreview(for url: URL) -> CachedPreview? {
        return cache[url]
    }

    // Check if a URL has been cached (for UI indicators)
    func isCached(_ url: URL) -> Bool {
        return cache[url] != nil
    }

    var cachedCount: Int { cache.count }

    // Prefetch ALL images: decode → bin2x → STF stretch → cache BGRA8 texture
    // debayerEnabled: when true, OSC images with BAYERPAT are debayered to RGB
    func prefetchAll(
        images: [ImageEntry],
        debayerEnabled: Bool,
        onProgress: @escaping (Int, Int) -> Void
    ) {
        // Build lookup for Bayer patterns by URL (only used when debayer is enabled)
        let bayerPatterns: [URL: String]
        if debayerEnabled {
            bayerPatterns = Dictionary(
                uniqueKeysWithValues: images.compactMap { entry in
                    guard let pat = entry.bayerPattern else { return nil }
                    return (entry.url, pat)
                }
            )
        } else {
            bayerPatterns = [:]
        }

        prefetchTask?.cancel()

        let device = self.device
        let total = images.count
        let concurrency = maxConcurrentDecodes
        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var completed = 0
            var index = 0

            while index < total {
                guard !Task.isCancelled else { return }

                let batchEnd = min(index + concurrency, total)
                let batch = Array(images[index..<batchEnd])

                await withTaskGroup(of: (URL, CachedPreview?).self) { group in
                    for entry in batch {
                        // Skip if already cached
                        let alreadyCached = await self?.getPreview(for: entry.url) != nil
                        if alreadyCached {
                            completed += 1
                            await MainActor.run { onProgress(completed, total) }
                            continue
                        }

                        group.addTask {
                            guard !Task.isCancelled else { return (entry.url, nil) }

                            // 1. Decode full-res uint16
                            let decodeResult = ImageDecoder.decode(url: entry.decodingURL, device: device)
                            guard case .success(let decoded) = decodeResult else {
                                return (entry.url, nil)
                            }

                            // 2. Debayer if enabled and mono CFA image with Bayer pattern
                            let imageForSTF: DecodedImage
                            if decoded.channelCount == 1,
                               let pattern = bayerPatterns[entry.url] {
                                let generator = await self?.previewGenerator
                                imageForSTF = generator?.debayer(image: decoded, pattern: pattern) ?? decoded
                            } else {
                                imageForSTF = decoded
                            }

                            // 3. Compute STF params with default stretch
                            let stfParams = STFCalculator.calculate(from: imageForSTF)

                            // 4. Bin2x + STF stretch → BGRA8 texture
                            let generator = await self?.previewGenerator
                            let preview = generator?.generatePreview(from: imageForSTF, stfParams: stfParams)

                            // decoded + imageForSTF buffers released here — only the
                            // small BGRA8 texture survives in the cache
                            return (entry.url, preview)
                        }
                    }

                    for await (url, preview) in group {
                        if let preview = preview {
                            await self?.storePreview(preview, for: url)
                        }
                        completed += 1
                        await MainActor.run { onProgress(completed, total) }
                    }
                }

                index = batchEnd
            }
        }
    }

    // Store a preview in the cache
    func storePreview(_ preview: CachedPreview, for url: URL) {
        cache[url] = preview
    }

    // Invalidate all cached previews (e.g. when stretch mode changes)
    func invalidateAll() {
        cache.removeAll()
    }

    // Stop prefetch but keep already-cached previews
    func stopPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func clear() {
        prefetchTask?.cancel()
        prefetchTask = nil
        cache.removeAll()
    }
}
