// v0.7.0
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

    var cachedCount: Int { cache.count }

    // Prefetch ALL images: decode → bin2x → STF stretch → cache BGRA8 texture
    func prefetchAll(
        images: [ImageEntry],
        onProgress: @escaping (Int, Int) -> Void
    ) {
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

                            // 2. Compute STF params (from full-res data)
                            let stfParams = STFCalculator.calculate(from: decoded)

                            // 3. Bin2x + STF stretch → BGRA8 texture
                            let generator = await self?.previewGenerator
                            let preview = generator?.generatePreview(from: decoded, stfParams: stfParams)

                            // decoded (raw uint16 buffer) is released here — only the
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
