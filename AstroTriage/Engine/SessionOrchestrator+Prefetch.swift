// Prefetch + caching pipeline extension for SessionOrchestrator.
//
// Step 3: pulls the post-load prefetch family out of TriageViewModel.
// The orchestrator now owns memory-budget gating, the local-disk
// pre-cache (startFullPrefetch), the interleaved NAS download/cache
// pipeline (cacheNetworkFiles + startFullPrefetchInterleaved), and the
// stop/continue user controls.
//
// The methods touch a lot of host-side state (caching counters, applied
// post-process params, etc.) but every dependency goes through the
// SessionHost protocol so SwiftUI bindings on TriageViewModel stay
// authoritative for the UI.
import Foundation
import AppKit

extension SessionOrchestrator {
    // MARK: - Memory budget + cache start

    /// Estimate cache memory needed and warn the user if it exceeds available RAM.
    /// If within budget, starts caching immediately. If over budget, shows a
    /// non-blocking sheet alert and starts/skips caching based on user choice.
    func checkMemoryBudgetAndCache(for entries: [ImageEntry]) {
        guard let host = host else { return }
        let totalRawBytes = entries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        let physicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        // Safe budget: 70% of physical RAM for cache (leaves 30% for OS, app, and decode buffers)
        let safeBudget = Int64(Double(physicalMemory) * 0.7)

        // Always enrich headers regardless of cache decision
        self.enrichWithHeaders()

        // If estimated cache fits comfortably, proceed without warning
        if totalRawBytes <= safeBudget {
            host.applyAllEnabled = true
            host.triggerApplyAll()
            return
        }

        // Calculate how many images would fit safely
        let avgFileSize = totalRawBytes / max(Int64(entries.count), 1)
        let safeImageCount = avgFileSize > 0 ? Int(safeBudget / avgFileSize) : entries.count
        let reductionPercent = Int(100.0 - Double(safeImageCount) / Double(entries.count) * 100.0)

        let totalGB = String(format: "%.1f", Double(totalRawBytes) / 1_073_741_824.0)
        let ramGB = String(format: "%.0f", Double(physicalMemory) / 1_073_741_824.0)
        let safeGB = String(format: "%.1f", Double(safeBudget) / 1_073_741_824.0)

        let alert = NSAlert()
        alert.messageText = "Large session — memory warning"
        alert.informativeText = """
        This session has \(entries.count) images (~\(totalGB) GB). \
        Caching all previews may use more memory than your system comfortably supports \
        (\(ramGB) GB RAM, ~\(safeGB) GB available for cache).

        You can proceed, but navigation may slow down once memory fills up. \
        To avoid this, consider reducing your selection by ~\(reductionPercent)% \
        (~\(safeImageCount) images would fit safely).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cache All Anyway")
        alert.addButton(withTitle: "Skip Caching")

        // Non-blocking sheet on key window, with callback
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self = self, let host = self.host else { return }
                if response == .alertFirstButtonReturn {
                    host.applyAllEnabled = true
                    host.triggerApplyAll()
                } else {
                    host.statusMessage = "Caching skipped — use arrow keys for on-demand viewing"
                    host.applyAllEnabled = false
                }
            }
        } else {
            // Fallback: app-modal (no window available yet)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                host.applyAllEnabled = true
                host.triggerApplyAll()
            } else {
                host.statusMessage = "Caching skipped — use arrow keys for on-demand viewing"
                host.applyAllEnabled = false
            }
        }
    }

    // MARK: - Local pre-cache

    /// Start pre-decoding + stretching ALL images (skips already-cached).
    func startFullPrefetch() {
        guard let host = host else { return }
        guard let prefetchCache = prefetchCache else { return }

        benchmarkStats.markCachingStart()
        host.isCaching = true
        host.cachingStopped = false
        host.cachingTotal = host.images.count
        host.cachingCount = 0
        host.cacheProgress = 0
        host.cachingStartTime = Date()
        host.cachingEstimatedSecondsRemaining = nil

        // Disable App Nap during caching so background processing continues
        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Pre-caching astrophotography images"
        )

        // Pass applied stretch target, locked STF params, and post-process params for cache baking
        let targetBg: Float? = abs(host.appliedStretch - STFCalculator.defaultTargetBackground) > 0.001
            ? host.appliedStretch : nil
        let lockedParams: [STFParams]? = host.appliedLocked ? host.renderer?.lockedSTFParams : nil
        let ppParams: (sharpening: Float, contrast: Float, darkLevel: Float)?
        if abs(host.appliedSharpening) > 0.001 || abs(host.appliedContrast) > 0.001 || host.appliedDarkLevel > 0.001 {
            ppParams = (host.appliedSharpening, host.appliedContrast, host.appliedDarkLevel)
        } else {
            ppParams = nil
        }

        // Identify frames that have cached previews but missing analysis data.
        // These frames were skipped in a prior prefetch because their preview was cached,
        // but the metric callbacks (onNoiseStats, onStarMetrics) never fired.
        // Use OR (||): if EITHER metric is missing the frame is half-measured and
        // must be re-analysed. AND (&&) silently strands frames where one callback
        // landed and the other was dropped (generation race, NAS late delivery, etc.).
        let needsAnalysis = Set(host.images.filter { $0.noiseMAD == nil || $0.computedStarCount == nil }
                                            .map { $0.url })

        prefetchCache.prefetchAll(
            images: host.images,
            debayerEnabled: host.debayerEnabled,
            targetBackground: lockedParams != nil ? nil : targetBg,  // locked params override target
            lockedSTFParams: lockedParams,
            postProcessParams: ppParams,
            needsAnalysis: needsAnalysis,
            onProgress: { [weak self] completed, total in
                guard let self = self, let host = self.host else { return }
                host.cachingCount = completed
                host.cachingTotal = total
                host.cacheProgress = total > 0 ? Double(completed) / Double(total) : 0

                // Refresh table periodically so cache checkmarks appear (every 4 images)
                if completed % 4 == 0 || completed == total {
                    host.needsTableRefresh = true
                    // Compute caching time estimate after 20 items
                    if completed >= 20, let startTime = host.cachingStartTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let avgPerItem = elapsed / Double(completed)
                        let remaining = Int(avgPerItem * Double(total - completed))
                        host.cachingEstimatedSecondsRemaining = max(1, remaining)
                    }
                }

                if completed < total {
                    host.statusMessage = "Analyzing \(completed)/\(total)..."
                } else {
                    host.isCaching = false
                    host.cachingEstimatedSecondsRemaining = nil
                    host.cachingStartTime = nil
                    host.needsTableRefresh = true
                    host.statusMessage = "instant navigation ready"
                    self.benchmarkStats.markCachingEnd()
                    print("[Bench] LOAD READY at \(Date().timeIntervalSince1970) — caching complete, \(host.images.count) frames")
                    // Fire-and-forget anonymous upload of session load stats (community telemetry)
                    self.benchmarkService.autoUploadSessionLoad(
                        stats: self.benchmarkStats,
                        sessionRootURL: host.sessionRootURL
                    )
                    // Release App Nap assertion when caching completes
                    self.appNapAssertion = nil
                    // Update session overview with noise stats now that all images are measured
                    self.sessionOverviewModel.updateStats(from: host.images)
                    // Recompute quality scores now that noiseMAD is populated for all images
                    self.recomputeQualityScores()
                    // Fix for MainActor Task delivery race: metric callbacks for individual
                    // frames are dispatched as separate MainActor Tasks which may not have
                    // executed yet when onProgress(total,total) fires. Re-check after a
                    // short delay to catch any frames whose metrics arrived late.
                    self.scheduleQualityRescore()
                    // Jump to first image after precaching + quality scoring complete
                    if !host.images.isEmpty {
                        host.selectImage(at: 0)
                    }
                }
            },
            onNoiseStats: { [weak self] url, stats in
                guard let self = self, let host = self.host else { return }
                // Store noise stats in the corresponding ImageEntry
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    host.images[idx].noiseMedian = stats.median
                    host.images[idx].noiseMAD = stats.normalizedMAD
                }
                // Re-arm the rescore debouncer. Late metrics on slow NAS loads
                // would otherwise miss the end-of-cache rescore window and the
                // affected frames would sit "Quality Assessment Incomplete".
                self.requestQualityRescoreDebounced()
            },
            onStarMetrics: { [weak self] url, metrics in
                guard let self = self, let host = self.host else { return }
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    if metrics.medianHFR > 0 { host.images[idx].computedHFR = metrics.medianHFR }
                    if metrics.medianFWHM > 0 { host.images[idx].computedFWHM = metrics.medianFWHM }
                    host.images[idx].computedStarCount = metrics.totalStarCount
                    host.images[idx].computedEccentricity = metrics.medianEccentricity
                    host.images[idx].psfFluxSum = metrics.psfFluxSum
                    host.images[idx].psfMeanFlux = metrics.psfMeanFlux
                    host.images[idx].starChainFraction = metrics.starChainFraction
                    if !metrics.starDetails.isEmpty {
                        host.images[idx].starDetails = metrics.starDetails
                    }

                    // Run trailing analysis with orientation consensus.
                    // focalLength may not be available yet (header enrichment runs in parallel)
                    // — trailing scores are recomputed in recomputeQualityScores() after enrichment
                    if !metrics.starDetails.isEmpty {
                        let trailing = TrailingAnalyzer.analyze(
                            starDetails: metrics.starDetails,
                            focalLength: host.images[idx].focalLength,
                            pixelSizeMicrons: host.images[idx].pixelSizeMicrons
                        )
                        if let t = trailing {
                            host.images[idx].trailingScore = t.trailingScore
                            host.images[idx].trailingPA = t.consensusPA
                            host.images[idx].trailingAxisRatio = t.medianAxisRatio
                            host.images[idx].trailingConsensus = t.consensusFraction
                        }
                    }
                }
                // Re-arm the rescore debouncer (see onNoiseStats for rationale).
                self.requestQualityRescoreDebounced()
            },
            onFileHash: { [weak self] url, hash in
                guard let self = self, let host = self.host else { return }
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    host.images[idx].fileHash = hash
                    // Restore persisted per-frame user state from Frame History DB.
                    // fileHash is the stable cross-machine identity, so this also
                    // picks up feedback given on another Mac via the iCloud-synced DB.
                    if let record = try? FrameHistoryDatabase.shared.frameRecord(fileHash: hash) {
                        host.images[idx].userConfidence = record.userConfidence
                        host.images[idx].qualityFeedback = QualityFeedback(rawValue: record.qualityFeedback) ?? .none
                    }
                }
            },
            onOrientationFingerprint: { [weak self] url, fp in
                guard let self = self, let host = self.host else { return }
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    host.images[idx].orientationFingerprint = fp
                }
            }
        )
    }

    // MARK: - Stop / continue controls

    /// Stop the current caching process (keeps already-cached previews).
    func stopCaching() {
        guard let host = host else { return }
        prefetchCache?.stopPrefetch()
        host.isCaching = false
        host.cachingStopped = true
        appNapAssertion = nil  // Release App Nap assertion
        host.statusMessage = "Caching paused"
    }

    /// Continue caching from where it left off.
    func continueCaching() {
        guard let host = host else { return }
        host.cachingStopped = false
        startFullPrefetch()
    }

    // MARK: - Interleaved NAS pipeline

    /// Interleaved NAS pipeline: download files and pre-cache concurrently.
    /// As each file downloads to local SSD, it becomes available for pre-caching.
    /// Pre-caching starts after the first 4 files are downloaded.
    func cacheNetworkFiles() async {
        guard let host = host else { return }
        guard let rootURL = host.sessionRootURL else { return }
        sessionCache.prepareSession(rootURL: rootURL)

        let total = host.images.count
        let sourceURLs = host.images.map { $0.url }

        // Reset cancellation flag for new download session
        host.setDownloadCancelled(false)

        // Set up dedicated download fuel bar
        host.isDownloading = true
        host.downloadCount = 0
        host.downloadTotal = total
        host.downloadProgress = 0
        host.downloadStartTime = Date()
        host.downloadEstimatedSecondsRemaining = nil

        let sessionCacheRef = sessionCache
        let progressCounter = NSLock()
        var progressCount = 0
        var precacheStarted = false

        // Parallel download with 4 concurrent streams. The cancellation flag is
        // observed on every iteration via the host's nonisolated wrapped
        // accessor — the underlying NSLock stays private to TriageViewModel.
        // We snapshot `host` here (still on the main actor) and capture it
        // weakly into the detached task so the worker threads never touch
        // the orchestrator's @MainActor `host` property. Reading
        // `isDownloadCancelled` from a worker is safe because the accessor is
        // marked `nonisolated` on SessionHost (lock-protected internally).
        // Previously this path used `MainActor.assumeIsolated`, which traps
        // when called from `concurrentPerform` workers (utility-qos pool).
        let hostForWorker: any SessionHost = host
        await Task.detached(priority: .utility) { [weak self, weak hostForWorker] in
            DispatchQueue.concurrentPerform(iterations: total) { index in
                // Early exit if session changed (user opened another folder)
                guard let workerHost = hostForWorker else { return }
                guard !workerHost.isDownloadCancelled else { return }

                let sourceURL = sourceURLs[index]
                let localURL = sessionCacheRef.cacheFile(sourceURL: sourceURL)

                // Update decodingURL + thread-safe URL map for prefetch pipeline
                if let localURL = localURL {
                    // URL-based lookup (not index-based): host.images may have been
                    // reordered by applySortByColumnOrder since concurrentPerform
                    // snapshotted sourceURLs. An index-based write here would
                    // cross-assign cache paths to the wrong entries, causing
                    // enrichWithHeaders to later read headers from the wrong files
                    // (manifests as duplicate DATE-LOC / EXPTIME across rows).
                    Task { @MainActor [weak self] in
                        guard let host = self?.host else { return }
                        if let idx = host.images.firstIndex(where: { $0.url == sourceURL }) {
                            host.images[idx].decodingURL = localURL
                        }
                    }
                    // Update thread-safe URL map (no main-thread hop needed)
                    Task { @MainActor [weak self] in
                        self?.host?.networkURLUpdater?(sourceURL, localURL)
                    }
                }

                progressCounter.lock()
                progressCount += 1
                let current = progressCount
                progressCounter.unlock()

                if current % 4 == 0 || current == total {
                    Task { @MainActor [weak self] in
                        guard let self = self, let host = self.host else { return }
                        host.downloadCount = current
                        host.downloadTotal = total
                        host.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                        // Time estimate after 20 files
                        if current >= 20, let startTime = host.downloadStartTime {
                            let elapsed = Date().timeIntervalSince(startTime)
                            let avgPerItem = elapsed / Double(current)
                            let remaining = Int(avgPerItem * Double(total - current))
                            host.downloadEstimatedSecondsRemaining = max(1, remaining)
                        }

                        // Start pre-caching after first 4 files are downloaded
                        if !precacheStarted && current >= 4 {
                            precacheStarted = true
                            host.applyAllEnabled = true
                            self.startFullPrefetchInterleaved()
                        }
                    }
                }
            }
        }.value

        host.isDownloading = false
        host.downloadEstimatedSecondsRemaining = nil
        host.downloadStartTime = nil
        host.networkURLUpdater = nil  // Release closure + captured URL map

        // Bail out if session was cancelled (user opened another folder)
        guard !host.isDownloadCancelled else { return }

        // If fewer than 4 files (small session), start prefetch now
        if !precacheStarted {
            host.applyAllEnabled = true
            host.triggerApplyAll()
        }

        // Now that files are local, enrich headers from SSD cache (instant vs NAS)
        // This populates filter, gain, temp, etc. from FITS/XISF headers
        self.enrichWithHeaders()

        Task.detached(priority: .background) {
            SessionCache.cleanupOldCaches()
        }
    }

    /// Start pre-caching with late URL resolution for interleaved NAS pipeline.
    /// Operations resolve decodingURL at execution time, so they use the local
    /// cache file even if it was downloaded after the operation was created.
    func startFullPrefetchInterleaved() {
        guard let host = host else { return }
        guard let prefetchCache = prefetchCache else { return }

        // Update applied settings so cacheMatchesCurrentSettings returns true
        // after prefetch completes (same as triggerApplyAll does)
        host.appliedStretch = host.stretchStrength
        host.appliedSharpening = host.sharpening
        host.appliedContrast = host.contrast
        host.appliedDarkLevel = host.darkLevel
        host.appliedLocked = host.isSTFLocked

        benchmarkStats.markCachingStart()
        host.isCaching = true
        host.cachingStopped = false
        host.cachingTotal = host.images.count
        host.cachingCount = 0
        host.cacheProgress = 0
        host.cachingStartTime = Date()
        host.cachingEstimatedSecondsRemaining = nil

        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Pre-caching astrophotography images"
        )

        let targetBg: Float? = abs(host.appliedStretch - STFCalculator.defaultTargetBackground) > 0.001
            ? host.appliedStretch : nil
        let lockedParams: [STFParams]? = host.appliedLocked ? host.renderer?.lockedSTFParams : nil
        let ppParams: (sharpening: Float, contrast: Float, darkLevel: Float)?
        if abs(host.appliedSharpening) > 0.001 || abs(host.appliedContrast) > 0.001 || host.appliedDarkLevel > 0.001 {
            ppParams = (host.appliedSharpening, host.appliedContrast, host.appliedDarkLevel)
        } else {
            ppParams = nil
        }

        // Thread-safe URL lookup for late resolution — avoids DispatchQueue.main.sync
        // bottleneck that would serialize background operations.
        // Downloads update this dictionary as files arrive; prefetch reads it lock-free-ish.
        let urlLock = NSLock()
        var urlMap: [URL: URL] = [:]
        for entry in host.images {
            urlMap[entry.url] = entry.decodingURL
        }
        // Expose updater for download callback
        host.networkURLUpdater = { url, localURL in
            urlLock.lock()
            urlMap[url] = localURL
            urlLock.unlock()
        }

        let resolveURL: (URL) -> URL = { originalURL in
            urlLock.lock()
            let resolved = urlMap[originalURL] ?? originalURL
            urlLock.unlock()
            return resolved
        }

        // Identify frames that need re-analysis (cached preview but missing metrics).
        // OR not AND — see the local-path comment above for the rationale.
        let needsAnalysisNAS = Set(host.images.filter { $0.noiseMAD == nil || $0.computedStarCount == nil }
                                               .map { $0.url })

        prefetchCache.prefetchAll(
            images: host.images,
            debayerEnabled: host.debayerEnabled,
            targetBackground: lockedParams != nil ? nil : targetBg,
            lockedSTFParams: lockedParams,
            postProcessParams: ppParams,
            resolveDecodingURL: resolveURL,
            needsAnalysis: needsAnalysisNAS,
            onProgress: { [weak self] completed, total in
                guard let self = self, let host = self.host else { return }
                host.cachingCount = completed
                host.cachingTotal = total
                host.cacheProgress = total > 0 ? Double(completed) / Double(total) : 0

                if completed % 4 == 0 || completed == total {
                    host.needsTableRefresh = true
                    if completed >= 20, let startTime = host.cachingStartTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let avgPerItem = elapsed / Double(completed)
                        let remaining = Int(avgPerItem * Double(total - completed))
                        host.cachingEstimatedSecondsRemaining = max(1, remaining)
                    }
                }

                if completed < total {
                    host.statusMessage = "Analyzing \(completed)/\(total)..."
                } else {
                    host.isCaching = false
                    host.cachingEstimatedSecondsRemaining = nil
                    host.cachingStartTime = nil
                    host.needsTableRefresh = true
                    host.statusMessage = "instant navigation ready"
                    self.benchmarkStats.markCachingEnd()
                    print("[Bench] LOAD READY (NAS) at \(Date().timeIntervalSince1970) — caching complete, \(host.images.count) frames")
                    // Fire-and-forget anonymous upload of session load stats (community telemetry)
                    self.benchmarkService.autoUploadSessionLoad(
                        stats: self.benchmarkStats,
                        sessionRootURL: host.sessionRootURL
                    )
                    self.appNapAssertion = nil
                    // Don't compute quality scores here — header enrichment hasn't run yet
                    // for NAS sessions. enrichWithHeaders() completion handles quality scoring
                    // + session overview update after all header data is available.
                    //
                    // BUT: header enrichment may finish BEFORE bulk prefetch. In that
                    // case the post-header recompute scores only the early-measured
                    // frames; late metric callbacks arrive while isCaching is still
                    // true so the debouncer (correctly) suppresses itself. Now that
                    // isCaching has flipped off, fire a final debouncer pass +
                    // legacy retry chain to pick up any frame whose metrics landed
                    // during that gap.
                    self.requestQualityRescoreDebounced()
                    self.scheduleQualityRescore()
                    if !host.images.isEmpty {
                        host.selectImage(at: 0)
                    }
                }
            },
            onNoiseStats: { [weak self] url, stats in
                guard let self = self, let host = self.host else { return }
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    host.images[idx].noiseMedian = stats.median
                    host.images[idx].noiseMAD = stats.normalizedMAD
                }
                // NAS path was previously missing the debouncer hook — that's why
                // late-arriving frames on slow networks stayed "Quality Assessment
                // Incomplete" indefinitely (no rescore triggered).
                self.requestQualityRescoreDebounced()
            },
            onStarMetrics: { [weak self] url, metrics in
                guard let self = self, let host = self.host else { return }
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    if metrics.medianHFR > 0 { host.images[idx].computedHFR = metrics.medianHFR }
                    if metrics.medianFWHM > 0 { host.images[idx].computedFWHM = metrics.medianFWHM }
                    host.images[idx].computedStarCount = metrics.totalStarCount
                    host.images[idx].computedEccentricity = metrics.medianEccentricity
                    host.images[idx].psfFluxSum = metrics.psfFluxSum
                    host.images[idx].psfMeanFlux = metrics.psfMeanFlux
                    host.images[idx].starChainFraction = metrics.starChainFraction
                    if !metrics.starDetails.isEmpty {
                        host.images[idx].starDetails = metrics.starDetails
                    }
                    // Trailing analysis
                    if !metrics.starDetails.isEmpty {
                        let trailing = TrailingAnalyzer.analyze(
                            starDetails: metrics.starDetails,
                            focalLength: host.images[idx].focalLength,
                            pixelSizeMicrons: host.images[idx].pixelSizeMicrons
                        )
                        if let t = trailing {
                            host.images[idx].trailingScore = t.trailingScore
                            host.images[idx].trailingPA = t.consensusPA
                            host.images[idx].trailingAxisRatio = t.medianAxisRatio
                            host.images[idx].trailingConsensus = t.consensusFraction
                        }
                    }
                }
                // Debouncer hook (see onNoiseStats above for rationale).
                self.requestQualityRescoreDebounced()
            },
            onFileHash: { [weak self] url, hash in
                guard let self = self, let host = self.host else { return }
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    host.images[idx].fileHash = hash
                    // Restore persisted per-frame user state from Frame History DB.
                    // fileHash is the stable cross-machine identity, so this also
                    // picks up feedback given on another Mac via the iCloud-synced DB.
                    if let record = try? FrameHistoryDatabase.shared.frameRecord(fileHash: hash) {
                        host.images[idx].userConfidence = record.userConfidence
                        host.images[idx].qualityFeedback = QualityFeedback(rawValue: record.qualityFeedback) ?? .none
                    }
                }
            },
            onOrientationFingerprint: { [weak self] url, fp in
                guard let self = self, let host = self.host else { return }
                if let idx = host.images.firstIndex(where: { $0.url == url }) {
                    host.images[idx].orientationFingerprint = fp
                }
            }
        )
    }
}
