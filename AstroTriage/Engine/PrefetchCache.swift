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
    // `cache` is fully MainActor-isolated — only the main thread reads or writes it.
    // Background decode workers never touch `cache` directly; they hand results back
    // via `Task { @MainActor in storePreview(...) }`.
    private var cache: [URL: CachedPreview] = [:]
    private let device: MTLDevice
    private let previewGenerator: PreviewGenerator?

    // `cachedURLsSet` is a write-once-per-store mirror of `cache.keys` that background
    // workers can read under NSLock to skip URLs that another worker already cached.
    // The set is intentionally separate so workers don't have to hop to MainActor just
    // to ask "is this already done?". `storePreview` writes `cache` first, then this set,
    // so a "set says yes" answer always implies the cache is also populated. Background
    // never reads `cache` itself, so the reverse race ("set says yes, cache empty") cannot occur.
    // Both the lock and the set are deliberately read/written from background
    // OperationQueue workers; the surrounding @MainActor isolation does not apply
    // here because the contract is "always touched under cachedURLsLock". The
    // set needs nonisolated(unsafe) to bypass the actor hop (Swift 6 strict
    // concurrency); NSLock is already Sendable and needs no annotation.
    private let cachedURLsLock = NSLock()
    nonisolated(unsafe) private var cachedURLsSet = Set<URL>()

    // Bumped on every clear() / invalidateAll(). Workers capture this at enqueue time
    // and the MainActor completion task checks it before writing into `cache` — prevents
    // stale workers from a previous session from polluting a freshly-cleared cache.
    private var sessionGeneration: Int = 0

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

    // Callback fired exactly once per session the very first time ANY preview is stored in the cache.
    // Used by the benchmark system to measure true "app ready to display" time without depending on
    // user navigation, MTKView attachment timing, or displayCurrentImage success. Reset by resetFirstPreviewTracking().
    var onFirstPreviewStored: (() -> Void)?
    private var firstPreviewStoredFired: Bool = false

    // Star-based display alignment — shared with view model.
    // Set once per session; workers call alignOrEstablish after star detection to
    // compute per-frame transforms for display-time visual consistency.
    var displayAligner: DisplayAligner?

    // Closure to look up the per-frame target grouping key (used by the aligner).
    // Captured at enqueue time so background workers don't touch @MainActor state.
    var targetKeyForEntry: ((ImageEntry) -> String)?

    // Callback fired when alignment transform is computed for a frame.
    var onAlignmentComputed: ((URL, AffineTransform2D) -> Void)?

    /// Set to true when the session is known to have WCS plate-solve data in every file
    /// (e.g. ASIAir captures). Detected by peeking at the first file's headers in
    /// loadSession. When true, prefetch workers skip star matching entirely — alignment
    /// will be computed by applyWCSAlignment after header enrichment, much faster.
    var skipStarMatchingForAlignment: Bool = false

    /// Extract complete WCS data from an ImageEntry — returns nil if any required field is missing.
    /// All 8 fields (CRPIX1/2, CRVAL1/2, CD11/12/21/22) must be present for CD-matrix alignment.
    static func wcsDataIfComplete(_ entry: ImageEntry) -> DisplayAligner.WCSData? {
        guard let crpix1 = entry.wcsCRPIX1,
              let crpix2 = entry.wcsCRPIX2,
              let crval1 = entry.solvedRA,
              let crval2 = entry.solvedDec,
              let cd11 = entry.wcsCD11,
              let cd12 = entry.wcsCD12,
              let cd21 = entry.wcsCD21,
              let cd22 = entry.wcsCD22
        else { return nil }
        return DisplayAligner.WCSData(
            crpix1: crpix1, crpix2: crpix2,
            crval1: crval1, crval2: crval2,
            cd11: cd11, cd12: cd12, cd21: cd21, cd22: cd22
        )
    }

    init(device: MTLDevice) {
        self.device = device
        self.previewGenerator = PreviewGenerator(device: device)
    }

    // Pick the channel with the strongest star signal for HFR / FWHM / detection.
    //
    // Hardcoding green (channel 1) was correct for broadband OSC frames, where
    // RGGB sees roughly equal stellar continuum across all three channels and
    // green wins by virtue of being the most-sampled colour. It is wrong for
    // narrowband OSC (Lextr / L-eXtreme / Optolong / SHO duo-band): those
    // filters pass Ha at 656 nm (deep red) plus a narrow OIII band at ~500 nm,
    // so stellar continuum lands almost entirely in the red channel and the
    // green channel sees only OIII-band photons. The 60 brightest unsaturated
    // green-channel stars are then too faint to fit cleanly, every frame
    // collapses to the all-zero partial-metrics path, and the UI shows "!"
    // for every HFR/FWHM cell.
    //
    // The pick uses a simple count of bright pixels (> half of full range) on
    // a 5 % subsample per channel — it is filter-agnostic, runs in ~5 ms total
    // for 25 MP, needs no extra metadata, and tracks where the star signal
    // actually went rather than where we expected it to be.
    static func bestMeasurementChannel(of image: DecodedImage) -> Int {
        guard image.channelCount > 1 else { return 0 }
        let w = image.width, h = image.height
        let planeSize = w * h
        let ptr = image.buffer.contents().bindMemory(
            to: UInt16.self, capacity: planeSize * image.channelCount
        )
        let stride = 20  // 5 % subsample
        let threshold: UInt16 = 32768  // half of full UInt16 range
        var bestChannel = 0
        var bestCount = -1
        for ch in 0..<image.channelCount {
            let chOff = ch * planeSize
            var count = 0
            var i = 0
            while i < planeSize {
                if ptr[chOff + i] > threshold { count += 1 }
                i += stride
            }
            if count > bestCount {
                bestCount = count
                bestChannel = ch
            }
        }
        return bestChannel
    }

    // Retrieve a cached pre-stretched preview, nil if not yet ready
    func getPreview(for url: URL) -> CachedPreview? {
        return cache[url]
    }

    // Check if a URL has been cached (for UI indicators)
    func isCached(_ url: URL) -> Bool {
        return cache[url] != nil
    }

    /// Re-key a cached preview after a rename that did NOT change pixel data (Change Filter /
    /// Batch Rename only rewrite a header keyword + the filename). The pre-stretched preview
    /// stays valid, so moving it to the new URL keeps the file instantly displayable instead
    /// of forcing a slow re-decode when the user next navigates to it. No-op if the old URL
    /// wasn't cached or the URL is unchanged (header-only edit).
    func migrateCacheEntry(from oldURL: URL, to newURL: URL) {
        guard oldURL != newURL, let preview = cache.removeValue(forKey: oldURL) else { return }
        cache[newURL] = preview
        cachedURLsLock.lock()
        cachedURLsSet.remove(oldURL)
        cachedURLsSet.insert(newURL)
        cachedURLsLock.unlock()
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
        onStarMetrics: ((URL, StarMetrics) -> Void)? = nil,
        onFileHash: ((URL, String) -> Void)? = nil,
        onOrientationFingerprint: ((URL, [UInt8]) -> Void)? = nil
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
        // Capture alignment state at enqueue time (main actor) so background workers
        // can use them without hopping back.
        let aligner = self.displayAligner
        let targetKeyProvider = self.targetKeyForEntry
        let onAligned = self.onAlignmentComputed
        let skipStarAlignment = self.skipStarMatchingForAlignment
        let workerGeneration = self.sessionGeneration

        for entry in uncachedEntries {
            let url = entry.url
            let decodingURL = entry.decodingURL
            let bayerPattern = bayerPatterns[entry.url]
            // Pre-compute target key on main actor so worker doesn't need entry access later
            let targetKey: String? = targetKeyProvider?(entry)
            // Extract WCS plate-solve data from entry (main-actor access) to pass
            // to background worker. Nil when header enrichment hasn't read the fields yet.
            let wcsData: DisplayAligner.WCSData? = Self.wcsDataIfComplete(entry)

            priorityQueue?.addOperation { [weak self] in
                // Double-check cache (may have been filled by background queue)
                // Uses thread-safe set instead of DispatchQueue.main.sync
                self?.cachedURLsLock.lock()
                let alreadyCached = self?.cachedURLsSet.contains(url) ?? true
                self?.cachedURLsLock.unlock()
                guard !alreadyCached else { return }

                // Full pipeline: hash → decode → debayer → noise → stars → STF → GPU preview
                // Compute file hash from first 64KB (cheap: ~0.5ms)
                let fileHashResult = FileHasher.hash(for: decodingURL)

                let decodeResult = ImageDecoder.decode(url: decodingURL, device: device)
                guard case .success(let decoded) = decodeResult else { return }

                let imageForSTF: DecodedImage
                if decoded.channelCount == 1, let pattern = bayerPattern {
                    imageForSTF = generator?.debayer(image: decoded, pattern: pattern) ?? decoded
                } else {
                    imageForSTF = decoded
                }

                // Measurement image: ALWAYS debayered when BAYERPAT is known,
                // independent of the user's display-debayer toggle. HFR/FWHM
                // apertures and Gaussian fits assume a smooth PSF; the raw Bayer
                // mosaic corrupts both with R/G/G/B striation, which silently
                // returns the all-zero partial-metrics path for OSC frames whenever
                // display debayer is off. Reuses the display-debayered buffer when
                // the user toggle already computed it (zero extra GPU cost).
                let measurementImage: DecodedImage
                if imageForSTF.channelCount == 3 {
                    measurementImage = imageForSTF
                } else if decoded.channelCount == 1,
                          let pat = entry.bayerPattern, !pat.isEmpty,
                          let debayered = generator?.debayer(image: decoded, pattern: pat) {
                    measurementImage = debayered
                } else {
                    measurementImage = imageForSTF
                }

                // Pixel-based orientation fingerprint — cheap (<1 ms on M-series
                // for 50 MP). Runs on the RAW decoded buffer so it's consistent
                // across OSC/mono and doesn't depend on debayer availability.
                var fingerprintResult: [UInt8]?
                if onOrientationFingerprint != nil {
                    fingerprintResult = OrientationFingerprint.compute(from: decoded)
                }

                // Compute metrics synchronously on background thread.
                // Use measurementImage so OSC noise/HFR/FWHM see smooth, single-color
                // data even when the user has display debayer off.
                var noiseStatsResult: STFCalculator.NoiseStats?
                if onNoiseStats != nil {
                    noiseStatsResult = STFCalculator.measureNoise(from: measurementImage)
                }

                var starMetricsResult: StarMetrics?
                var alignmentResult: AffineTransform2D?
                if onStarMetrics != nil {
                    let channel = Self.bestMeasurementChannel(of: measurementImage)
                    let stars = generator?.detectStarsFromImage(measurementImage, channel: channel) ?? []
                    let totalStarCount = generator?.lastTotalStarCount ?? stars.count
                    if !stars.isEmpty {
                        let metrics = StarMetricsCalculator.measure(
                            stars: stars, fullResImage: measurementImage, channel: channel,
                            totalStarCount: totalStarCount,
                            generator: generator,
                            arcsecPerPixel: entry.arcsecPerPixel
                        )
                        starMetricsResult = metrics ?? StarMetrics(
                            medianHFR: 0, medianFWHM: 0,
                            measuredStarCount: 0, totalStarCount: totalStarCount,
                            medianEccentricity: nil,
                            starDetails: [],
                            starChainFraction: 0, trailCandidateCount: 0, trailRejectCount: 0,
                            psfFluxSum: 0, psfMeanFlux: 0
                        )

                        // Compute star-based alignment transform for display
                        // (thread-safe: aligner uses internal lock).
                        //
                        // Convert the pixel-space "frame → reference" transform into a ready-to-use
                        // normalized UV-space "reference UV → frame UV" transform:
                        //   1. Invert (ref pixels → frame pixels)
                        //   2. Normalize to [0,1] UV space using the full-res image dimensions
                        //      (stars come from full-res coordinates, see PreviewGenerator.detectStarsFromImage)
                        // The renderer then applies it directly to the 4 reference-space quad corners.
                        // Skip star matching entirely when:
                        //   (a) the WCS detection at session start determined every file
                        //       in this session has plate-solve data — applyWCSAlignment
                        //       will handle alignment after headers are enriched, OR
                        //   (b) this specific entry already has WCS at enqueue time
                        if !skipStarAlignment, wcsData == nil,
                           let aligner = aligner, let tk = targetKey,
                           let pixelTransform = aligner.alignOrEstablish(
                            stars: stars, wcs: nil, targetKey: tk, debugTag: entry.filename) {
                            let inv = pixelTransform.inverse ?? .identity
                            alignmentResult = inv.normalized(
                                width: imageForSTF.width,
                                height: imageForSTF.height
                            )
                        }
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

                // Single MainActor task: deliver ALL results atomically.
                Task { @MainActor [weak self] in
                    let isStale = (self?.sessionGeneration ?? -1) != workerGeneration

                    // Metric callbacks land regardless of generation — they are
                    // URL-keyed and a wrong-URL no-op is harmless. Same reasoning
                    // as the bg-queue delivery path. Without this, frames touched
                    // by the priority queue (current image + ±2 neighbours at
                    // load time) lose their metrics when header-time OSC detection
                    // or Apply All triggers an `invalidateAll()` mid-flight.
                    if let hash = fileHashResult { onFileHash?(url, hash) }
                    if let fp = fingerprintResult { onOrientationFingerprint?(url, fp) }
                    if let stats = noiseStatsResult { onNoiseStats?(url, stats) }
                    if let metrics = starMetricsResult { onStarMetrics?(url, metrics) }
                    if let transform = alignmentResult { onAligned?(url, transform) }

                    // Preview storage + priority-ready notification stay session-coupled.
                    if !isStale {
                        if let preview = resultPreview {
                            self?.storePreview(preview, for: url)
                        }
                        self?.onPriorityPreviewReady?(url)
                    }
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
        resolveDecodingURL: ((URL) -> URL)? = nil,  // Late-resolve URL at execution time (for NAS pipeline)
        needsAnalysis: Set<URL> = [],  // URLs that need metrics even if preview is cached
        onProgress: @escaping (Int, Int) -> Void,
        onNoiseStats: ((URL, STFCalculator.NoiseStats) -> Void)? = nil,
        onStarMetrics: ((URL, StarMetrics) -> Void)? = nil,
        onFileHash: ((URL, String) -> Void)? = nil,
        onOrientationFingerprint: ((URL, [UInt8]) -> Void)? = nil
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
        // Capture alignment state for use in background workers
        let aligner = self.displayAligner
        let targetKeyProvider = self.targetKeyForEntry
        let onAligned = self.onAlignmentComputed
        let skipStarAlignment = self.skipStarMatchingForAlignment
        let workerGeneration = self.sessionGeneration
        // Pre-compute target keys for all images (so workers don't touch MainActor state)
        let targetKeys: [URL: String]
        if let provider = targetKeyProvider {
            targetKeys = Dictionary(uniqueKeysWithValues: images.map { ($0.url, provider($0)) })
        } else {
            targetKeys = [:]
        }
        // Pre-extract WCS data per URL (main-actor access) for background workers
        let wcsDataByURL: [URL: DisplayAligner.WCSData] = Dictionary(
            uniqueKeysWithValues: images.compactMap { entry in
                Self.wcsDataIfComplete(entry).map { (entry.url, $0) }
            }
        )

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

                // Skip if already cached AND not flagged for re-analysis.
                // Frames in needsAnalysis must go through the full pipeline even if
                // the preview texture is cached, because their metric callbacks
                // (onNoiseStats, onStarMetrics) were never fired.
                if cachedURLs.contains(entry.url) && !needsAnalysis.contains(entry.url) {
                    let completed = completedCount.increment()
                    Task { @MainActor in onProgress(completed, total) }
                    continue
                }

                let url = entry.url
                let fallbackDecodingURL = entry.decodingURL
                let bayerPattern = bayerPatterns[entry.url]
                // Pull entry.bayerPattern out separately — bayerPatterns above is gated
                // by the user's display-debayer toggle; measurement must always debayer
                // OSC mosaics, so we need the raw header field independent of that.
                let measurementBayerPattern = entry.bayerPattern

                let urlsLock = self?.cachedURLsLock
                let urlsSetRef = self
                let forceAnalyze = needsAnalysis.contains(url)

                queue.addOperation {
                    guard !queue.isSuspended else { return }

                    // Skip if priority queue already cached this image (thread-safe set check
                    // instead of DispatchQueue.main.sync to avoid stalling on main thread).
                    // Don't skip if the frame needs re-analysis (cached preview but missing metrics).
                    if !forceAnalyze, let lock = urlsLock {
                        lock.lock()
                        let alreadyCached = urlsSetRef?.cachedURLsSet.contains(url) ?? false
                        lock.unlock()
                        if alreadyCached {
                            let completed = completedCount.increment()
                            Task { @MainActor in onProgress(completed, total) }
                            return
                        }
                    }

                    // Resolve decodingURL at execution time — for NAS pipeline, the file
                    // may have been downloaded to local cache since the operation was created.
                    // The resolver uses a thread-safe dictionary (no main-thread hop needed).
                    let decodingURL: URL
                    if let resolver = resolveDecodingURL {
                        decodingURL = resolver(url)
                    } else {
                        decodingURL = fallbackDecodingURL
                    }

                    // 0. Compute file hash from first 64KB (~0.5ms)
                    let fileHashResult = FileHasher.hash(for: decodingURL)

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

                    // Measurement image: ALWAYS debayered when BAYERPAT is known.
                    // See detailed rationale in prioritizeCaching path. Reuses the
                    // display-debayered buffer when display debayer was already on.
                    let measurementImage: DecodedImage
                    if imageForSTF.channelCount == 3 {
                        measurementImage = imageForSTF
                    } else if decoded.channelCount == 1,
                              let pat = measurementBayerPattern, !pat.isEmpty,
                              let debayered = generator?.debayer(image: decoded, pattern: pat) {
                        measurementImage = debayered
                    } else {
                        measurementImage = imageForSTF
                    }

                    // 2a. Pixel-based orientation fingerprint (<1 ms). Used as the
                    // last-resort signal for auto-rotate when headers are silent
                    // and star matching fails (RASA, rotation-invariant fields).
                    var fingerprintResult: [UInt8]?
                    if onOrientationFingerprint != nil {
                        fingerprintResult = OrientationFingerprint.compute(from: decoded)
                    }

                    // 2b. Measure noise stats on the (always-debayered for OSC)
                    // measurement image, so SNR is consistent independent of the
                    // user's display debayer toggle.
                    var noiseStatsResult: STFCalculator.NoiseStats?
                    if onNoiseStats != nil {
                        noiseStatsResult = STFCalculator.measureNoise(from: measurementImage)
                    }

                    // 2c. GPU star detection + CPU HFR/FWHM measurement (~5-7ms per image)
                    // Always computed for all images to support per-group source consistency
                    var starMetricsResult: StarMetrics?
                    var alignmentResult: AffineTransform2D?
                    if onStarMetrics != nil {
                        // Pick the channel with the strongest star signal per-frame
                        // (broadband → green; narrowband Lextr/L-eXtreme → red, etc.)
                        let channel = Self.bestMeasurementChannel(of: measurementImage)
                        let stars = generator?.detectStarsFromImage(measurementImage, channel: channel) ?? []
                        let totalStarCount = generator?.lastTotalStarCount ?? stars.count
                        if !stars.isEmpty {
                            let metrics = StarMetricsCalculator.measure(
                                stars: stars, fullResImage: measurementImage, channel: channel,
                                totalStarCount: totalStarCount,
                                generator: generator,
                                arcsecPerPixel: entry.arcsecPerPixel
                            )
                            // Compute star-based alignment for display consistency.
                            // See detailed comment in prioritizeCaching path — we normalize
                            // to UV space here so the renderer can apply it directly.
                            // Skip star matching when WCS available — see priorityQueue path
                            if !skipStarAlignment, wcsDataByURL[url] == nil,
                               let aligner = aligner, let tk = targetKeys[url],
                               let pixelTransform = aligner.alignOrEstablish(
                                stars: stars, wcs: nil,
                                targetKey: tk, debugTag: entry.filename) {
                                let inv = pixelTransform.inverse ?? .identity
                                alignmentResult = inv.normalized(
                                    width: imageForSTF.width,
                                    height: imageForSTF.height
                                )
                            }
                            // Always report star count even if HFR/FWHM measurement failed
                            // (not enough stars in center crop for measurement)
                            starMetricsResult = metrics ?? StarMetrics(
                                medianHFR: 0, medianFWHM: 0,
                                measuredStarCount: 0, totalStarCount: totalStarCount,
                                medianEccentricity: nil,
                                starDetails: [],
                                starChainFraction: 0, trailCandidateCount: 0, trailRejectCount: 0,
                                psfFluxSum: 0, psfMeanFlux: 0
                            )
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

                    // Single MainActor task: deliver ALL per-image results atomically.
                    // This guarantees starChainFraction and noiseMAD are populated BEFORE
                    // onProgress fires the final scoring pass (fixes R9 timing race).
                    // Generation guard prevents stale workers from a previous session from
                    // populating the freshly-cleared cache.
                    let completed = completedCount.increment()
                    Task { @MainActor [weak self] in
                        let isStale = (self?.sessionGeneration ?? -1) != workerGeneration

                        // Metric callbacks land regardless of generation — they are
                        // URL-keyed and the orchestrator looks the index up via
                        // `firstIndex(where: { $0.url == url })`. If the new
                        // generation doesn't have this URL, it's a harmless no-op.
                        // This recovers the (expensive) measurement work for frames
                        // that were in flight when `invalidateAll()` fired — without
                        // this, header-time OSC detection / Apply All / settings
                        // changes silently strand whichever frames were mid-pipeline.
                        if let hash = fileHashResult { onFileHash?(url, hash) }
                        if let fp = fingerprintResult { onOrientationFingerprint?(url, fp) }
                        if let stats = noiseStatsResult { onNoiseStats?(url, stats) }
                        if let metrics = starMetricsResult { onStarMetrics?(url, metrics) }
                        if let transform = alignmentResult { onAligned?(url, transform) }

                        // Preview storage and onProgress are session-coupled — the
                        // cache was cleared by the new generation and `completed`
                        // is per-prefetchAll-call. Skip these for stale workers;
                        // the new generation's workers will re-do them.
                        if !isStale {
                            if let preview = resultPreview {
                                self?.storePreview(preview, for: url)
                            }
                            onProgress(completed, total)
                        }
                    }
                }
            }
        }
    }

    // Store a preview in the cache (also updates thread-safe URL set).
    // Fires onFirstPreviewStored exactly once per session — measures actual app readiness
    // independent of which image the user is looking at or whether the MTKView is attached yet.
    func storePreview(_ preview: CachedPreview, for url: URL) {
        cache[url] = preview
        cachedURLsLock.lock()
        cachedURLsSet.insert(url)
        cachedURLsLock.unlock()
        if !firstPreviewStoredFired {
            firstPreviewStoredFired = true
            onFirstPreviewStored?()
        }
    }

    // Reset the "first preview stored" guard for a fresh session.
    // Called by the view model at session start so the benchmark metric is recomputed.
    func resetFirstPreviewTracking() {
        firstPreviewStoredFired = false
    }

    // Invalidate all cached previews (e.g. when stretch mode changes).
    // Note: does NOT reset firstPreviewStoredFired — settings changes mid-session must not
    // re-fire the "time to first image" benchmark metric.
    func invalidateAll() {
        sessionGeneration += 1
        cache.removeAll()
        cachedURLsLock.lock()
        cachedURLsSet.removeAll()
        cachedURLsLock.unlock()
    }

    // Stop prefetch but keep already-cached previews
    func stopPrefetch() {
        backgroundQueue?.cancelAllOperations()
        priorityQueue?.cancelAllOperations()
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func clear() {
        sessionGeneration += 1
        backgroundQueue?.cancelAllOperations()
        priorityQueue?.cancelAllOperations()
        prefetchTask?.cancel()
        prefetchTask = nil
        cache.removeAll()
        cachedURLsLock.lock()
        cachedURLsSet.removeAll()
        cachedURLsLock.unlock()
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
