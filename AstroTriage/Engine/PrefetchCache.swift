// v2.0.0
import Foundation
import Metal

// Pre-stretched preview cache: decodes ALL session images, bins 2x, applies STF,
// and caches the final BGRA8 texture. Navigation = just render the cached texture.
// No compute needed at display time → instant image switching.
//
// Uses a sliding window (OperationQueue) instead of batch-sync — as each decode
// completes, the next file starts immediately. No batch boundary stalls.
@MainActor
class PrefetchCache {
    private var cache: [URL: CachedPreview] = [:]
    private let device: MTLDevice
    private let previewGenerator: PreviewGenerator?

    // Sliding window prefetch using OperationQueue
    private var operationQueue: OperationQueue?
    private var prefetchTask: Task<Void, Never>?

    // Adaptive concurrency based on available P-cores (capped at 6)
    private let maxConcurrentDecodes: Int = min(ProcessInfo.processInfo.activeProcessorCount / 2, 6)

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

    // Prefetch ALL images using sliding window: as each decode completes,
    // the next file immediately starts — no batch boundary stalls.
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

        // Cancel previous prefetch
        operationQueue?.cancelAllOperations()
        prefetchTask?.cancel()

        let device = self.device
        let total = images.count
        // Capture previewGenerator on main actor before entering background operations
        let generator = self.previewGenerator

        // Create sliding window operation queue
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrentDecodes
        queue.qualityOfService = .userInitiated
        self.operationQueue = queue

        // Thread-safe completed counter
        let completedCount = OSAtomicCounter()
        // Track already-cached URLs to skip them (snapshot on main actor)
        let cachedURLs = Set(cache.keys)

        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Add all operations to the queue — OperationQueue manages the sliding window
            for entry in images {
                guard !Task.isCancelled else { return }

                // Skip if already cached (using snapshot, no main actor hop)
                if cachedURLs.contains(entry.url) {
                    let completed = completedCount.increment()
                    Task { @MainActor in onProgress(completed, total) }
                    continue
                }

                let url = entry.url
                let decodingURL = entry.decodingURL
                let bayerPattern = bayerPatterns[entry.url]

                queue.addOperation {
                    guard !queue.isSuspended else { return }

                    // 1. Decode full-res uint16
                    let decodeResult = ImageDecoder.decode(url: decodingURL, device: device)
                    guard case .success(let decoded) = decodeResult else {
                        let completed = completedCount.increment()
                        Task { @MainActor in onProgress(completed, total) }
                        return
                    }

                    // 2. Debayer if enabled and mono CFA image with Bayer pattern
                    let imageForSTF: DecodedImage
                    if decoded.channelCount == 1, let pattern = bayerPattern {
                        imageForSTF = generator?.debayer(image: decoded, pattern: pattern) ?? decoded
                    } else {
                        imageForSTF = decoded
                    }

                    // 3. Compute STF params with default stretch
                    let stfParams = STFCalculator.calculate(from: imageForSTF)

                    // 4. GPU bin2x + STF stretch → BGRA8 texture
                    let preview = generator?.generatePreview(from: imageForSTF, stfParams: stfParams)

                    // Store result and report progress
                    let completed = completedCount.increment()
                    Task { @MainActor in
                        if let preview = preview {
                            self?.storePreview(preview, for: url)
                        }
                        onProgress(completed, total)
                    }
                }
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
        operationQueue?.cancelAllOperations()
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func clear() {
        operationQueue?.cancelAllOperations()
        prefetchTask?.cancel()
        prefetchTask = nil
        cache.removeAll()
    }
}

// Thread-safe atomic counter for progress tracking across concurrent operations
private final class OSAtomicCounter: @unchecked Sendable {
    private var value: Int = 0
    private let lock = NSLock()

    @discardableResult
    func increment() -> Int {
        lock.lock()
        value += 1
        let result = value
        lock.unlock()
        return result
    }
}
