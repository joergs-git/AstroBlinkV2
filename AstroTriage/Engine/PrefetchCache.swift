// v4.5.0
import Foundation
import Metal

// Pre-stretched preview cache: decodes ALL session images, bins 2x, applies STF,
// and caches the final BGRA8 texture. Navigation = just render the cached texture.
// No compute needed at display time → instant image switching.
//
// Dual-queue architecture:
//   priorityQueue (max 2, .userInteractive) — current image ±2 neighbors
//   backgroundQueue (max 6, .userInitiated)  — all other images
// GPU preview generation uses async completion to free worker threads immediately.
@MainActor
class PrefetchCache {
    private var cache: [URL: CachedPreview] = [:]
    private let device: MTLDevice
    private let previewGenerator: PreviewGenerator?

    // Background fill queue for bulk prefetching
    private var backgroundQueue: OperationQueue?
    private var prefetchTask: Task<Void, Never>?

    // High-priority queue for current navigation neighborhood (±2 images)
    private var priorityQueue: OperationQueue?

    // Adaptive concurrency: background gets up to 6, priority gets 2
    // Total max = 8 on machines with ≥16 active processors
    private let maxBackgroundDecodes: Int = min(ProcessInfo.processInfo.activeProcessorCount / 2, 8)
    private static let maxPriorityDecodes: Int = 2

    // Callback for when a priority-queued preview completes (notifies ViewModel to refresh display)
    var onPriorityPreviewReady: ((URL) -> Void)?

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

    // Total memory used by cached BGRA8 textures (bytes)
    var cacheMemoryBytes: Int64 {
        cache.values.reduce(Int64(0)) { total, preview in
            // BGRA8 = 4 bytes per pixel
            total + Int64(preview.texture.width) * Int64(preview.texture.height) * 4
        }
    }

    // MARK: - Priority Navigation Queue

    // Prioritize caching for current image and ±2 neighbors.
    // Called when user navigates to an uncached image during active caching.
    // Uses a dedicated high-priority queue (.userInteractive QoS) so these images
    // are decoded before bulk background fill.
    func prioritizeCaching(
        around index: Int,
        images: [ImageEntry],
        debayerEnabled: Bool,
        targetBackground: Float? = nil,
        lockedSTFParams: [STFParams]? = nil,
        postProcessParams: (sharpening: Float, contrast: Float, darkLevel: Float)? = nil,
        onNoiseStats: ((URL, STFCalculator.NoiseStats) -> Void)? = nil,
        onStarMetrics: ((URL, StarMetrics) -> Void)? = nil
    ) {
        // Cancel any previous priority operations — new navigation supersedes old
        priorityQueue?.cancelAllOperations()

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

        // Build neighborhood: index ±2, clamped to bounds, skip already cached
        let start = max(0, index - 2)
        let end = min(images.count - 1, index + 2)
        guard start <= end else { return }

        var uncachedEntries: [ImageEntry] = []
        for i in start...end {
            if !isCached(images[i].url) {
                uncachedEntries.append(images[i])
            }
        }
        guard !uncachedEntries.isEmpty else { return }

        // Create priority queue if needed
        if priorityQueue == nil {
            let pq = OperationQueue()
            pq.maxConcurrentOperationCount = Self.maxPriorityDecodes
            pq.qualityOfService = .userInteractive
            pq.name = "AstroTriage.PrefetchCache.priority"
            priorityQueue = pq
        }

        let device = self.device
        let generator = self.previewGenerator

        for entry in uncachedEntries {
            let url = entry.url
            let decodingURL = entry.decodingURL
            let bayerPattern = bayerPatterns[entry.url]

            priorityQueue?.addOperation { [weak self] in
                // Double-check cache (may have been filled by background queue)
                var alreadyCached = false
                DispatchQueue.main.sync { alreadyCached = self?.isCached(url) ?? true }
                guard !alreadyCached else { return }

                // Full pipeline: decode → debayer → noise → stars → STF → GPU preview
                let decodeResult = ImageDecoder.decode(url: decodingURL, device: device)
                guard case .success(let decoded) = decodeResult else { return }

                let imageForSTF: DecodedImage
                if decoded.channelCount == 1, let pattern = bayerPattern {
                    imageForSTF = generator?.debayer(image: decoded, pattern: pattern) ?? decoded
                } else {
                    imageForSTF = decoded
                }

                if let onNoiseStats = onNoiseStats {
                    let stats = STFCalculator.measureNoise(from: imageForSTF)
                    Task { @MainActor in onNoiseStats(url, stats) }
                }

                if let onStarMetrics = onStarMetrics {
                    let channel = imageForSTF.channelCount == 3 ? 1 : 0
                    let stars = generator?.detectStarsFromImage(imageForSTF, channel: channel) ?? []
                    let totalStarCount = generator?.lastTotalStarCount ?? stars.count
                    if !stars.isEmpty {
                        let metrics = StarMetricsCalculator.measure(
                            stars: stars, fullResImage: imageForSTF, channel: channel,
                            totalStarCount: totalStarCount
                        )
                        let finalMetrics = metrics ?? StarMetrics(
                            medianHFR: 0, medianFWHM: 0,
                            measuredStarCount: 0, totalStarCount: totalStarCount,
                            medianEccentricity: nil,
                            starDetails: [],
                            starChainFraction: 0
                        )
                        Task { @MainActor in onStarMetrics(url, finalMetrics) }
                    }
                }

                let stfParams: [STFParams]
                if let locked = lockedSTFParams {
                    stfParams = locked
                } else if let tb = targetBackground {
                    stfParams = STFCalculator.calculate(from: imageForSTF, targetBackground: tb)
                } else {
                    stfParams = STFCalculator.calculate(from: imageForSTF)
                }

                // Use async GPU preview generation to free the priority thread faster
                let semaphore = DispatchSemaphore(value: 0)
                var resultPreview: CachedPreview?
                generator?.generatePreviewAsync(
                    from: imageForSTF,
                    stfParams: stfParams,
                    postProcessParams: postProcessParams
                ) { preview in
                    resultPreview = preview
                    semaphore.signal()
                }
                semaphore.wait()

                // Store and notify ViewModel to refresh display
                Task { @MainActor [weak self] in
                    if let preview = resultPreview {
                        self?.storePreview(preview, for: url)
                    }
                    self?.onPriorityPreviewReady?(url)
                }
            }
        }
    }

    // MARK: - Bulk Prefetch

    // Prefetch ALL images using sliding window: as each decode completes,
    // the next file immediately starts — no batch boundary stalls.
    // debayerEnabled: when true, OSC images with BAYERPAT are debayered to RGB
    // targetBackground: custom STF target (nil = default 0.25), each image still gets auto-STF
    // lockedSTFParams: when non-nil, ALL images use these exact frozen STF params (Lock STF mode)
    // postProcessParams: optional sharpening/contrast/dark baked into cached preview
    func prefetchAll(
        images: [ImageEntry],
        debayerEnabled: Bool,
        targetBackground: Float? = nil,
        lockedSTFParams: [STFParams]? = nil,
        postProcessParams: (sharpening: Float, contrast: Float, darkLevel: Float)? = nil,
        onProgress: @escaping (Int, Int) -> Void,
        onNoiseStats: ((URL, STFCalculator.NoiseStats) -> Void)? = nil,
        onStarMetrics: ((URL, StarMetrics) -> Void)? = nil
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

        // Cancel previous prefetch (both queues)
        backgroundQueue?.cancelAllOperations()
        priorityQueue?.cancelAllOperations()
        prefetchTask?.cancel()

        let device = self.device
        let total = images.count
        // Capture previewGenerator on main actor before entering background operations
        let generator = self.previewGenerator

        // Create sliding window operation queue for background fill
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxBackgroundDecodes
        queue.qualityOfService = .userInitiated
        queue.name = "AstroTriage.PrefetchCache.background"
        self.backgroundQueue = queue

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

                    // Skip if priority queue already cached this image
                    var alreadyCached = false
                    DispatchQueue.main.sync { alreadyCached = self?.isCached(url) ?? false }
                    if alreadyCached {
                        let completed = completedCount.increment()
                        Task { @MainActor in onProgress(completed, total) }
                        return
                    }

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

                    // 2b. Measure noise stats (uses same 5% subsample as STF — ~2ms)
                    if let onNoiseStats = onNoiseStats {
                        let stats = STFCalculator.measureNoise(from: imageForSTF)
                        Task { @MainActor in onNoiseStats(url, stats) }
                    }

                    // 2c. GPU star detection + CPU HFR/FWHM measurement (~5-7ms per image)
                    // Always computed for all images to support per-group source consistency
                    if let onStarMetrics = onStarMetrics {
                        let channel = imageForSTF.channelCount == 3 ? 1 : 0  // Green for OSC
                        let stars = generator?.detectStarsFromImage(imageForSTF, channel: channel) ?? []
                        let totalStarCount = generator?.lastTotalStarCount ?? stars.count
                        if !stars.isEmpty {
                            let metrics = StarMetricsCalculator.measure(
                                stars: stars, fullResImage: imageForSTF, channel: channel,
                                totalStarCount: totalStarCount
                            )
                            // Always report star count even if HFR/FWHM measurement failed
                            // (not enough stars in center crop for measurement)
                            let finalMetrics = metrics ?? StarMetrics(
                                medianHFR: 0, medianFWHM: 0,
                                measuredStarCount: 0, totalStarCount: totalStarCount,
                                medianEccentricity: nil,
                                starDetails: [],
                                starChainFraction: 0
                            )
                            Task { @MainActor in onStarMetrics(url, finalMetrics) }
                        }
                    }

                    // 3. Compute STF params: use locked params (exact c0/mb) or per-image auto
                    let stfParams: [STFParams]
                    if let locked = lockedSTFParams {
                        // Lock STF: all images use the exact same frozen stretch params
                        stfParams = locked
                    } else if let tb = targetBackground {
                        stfParams = STFCalculator.calculate(from: imageForSTF, targetBackground: tb)
                    } else {
                        stfParams = STFCalculator.calculate(from: imageForSTF)
                    }

                    // 4. GPU bin2x + STF stretch + optional post-process → BGRA8 texture (async)
                    // Uses addCompletedHandler instead of waitUntilCompleted to free the worker thread
                    // for the next decode while GPU finishes the stretch pass (~2-3ms saved per image)
                    let semaphore = DispatchSemaphore(value: 0)
                    var resultPreview: CachedPreview?
                    generator?.generatePreviewAsync(
                        from: imageForSTF,
                        stfParams: stfParams,
                        postProcessParams: postProcessParams
                    ) { preview in
                        resultPreview = preview
                        semaphore.signal()
                    }
                    semaphore.wait()

                    // Store result and report progress
                    let completed = completedCount.increment()
                    Task { @MainActor in
                        if let preview = resultPreview {
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
        backgroundQueue?.cancelAllOperations()
        priorityQueue?.cancelAllOperations()
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func clear() {
        backgroundQueue?.cancelAllOperations()
        priorityQueue?.cancelAllOperations()
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
