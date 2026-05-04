// Session-lifecycle orchestrator extracted from TriageViewModel.
//
// Owns the methods that load images into a session, drive header
// enrichment, kick off scoring + SNR-retention recomputation, and hand
// mosaic generation to the VLM check. This is the second slice toward
// smaller, more focused state holders (PlaybackController was first).
//
// The orchestrator does NOT own @Published UI state. It mutates the
// host's state through a narrow SessionHost protocol so existing
// SwiftUI bindings continue to work unchanged while the methods are
// migrated step by step.
//
// Step 2: session-loading methods moved (loadSession / loadFiles /
// loadMultipleFolders / loadMixedSelection + wireSessionOverviewCallbacks
// + commonAncestor static helper).
//
// Step 3: prefetch family moved (checkMemoryBudgetAndCache,
// startFullPrefetch, stopCaching, continueCaching, cacheNetworkFiles,
// startFullPrefetchInterleaved) — see SessionOrchestrator+Prefetch.swift
// for the bodies. The orchestrator now owns the App Nap assertion that
// keeps caching alive when the app is backgrounded.
//
// Step 4: enrichWithHeaders moved into SessionOrchestrator+Headers.swift.
// The headerEnrichmentTask handle that lets a new session cancel a stale
// header-read pass now lives on the orchestrator.
//
// Step 5: scoring + post-scoring cascade moved into
// SessionOrchestrator+Scoring.swift (recomputeQualityScores,
// scheduleQualityRescore, recomputeSNRRetention, updateConvergence,
// saveToFrameHistory, computeMoonData, refineBortleOnline). The
// rescore-retry counter that gates scheduleQualityRescore now lives on
// the orchestrator. Quality logic itself unchanged — kAlgorithmVersion
// not bumped — but Golden-Set regression run as insurance.
//
// Step 6: VLM mosaic + Claude Vision anomaly check moved into
// SessionOrchestrator+VLM.swift (startVisualValidation,
// cancelVisualValidation, runVisualAnalysis). The cancellable handle
// for the in-flight generation task lives on the orchestrator.
//
// Step 7: commitSession() wraps the calibration-learning + community-
// upload pair that used to live inline at the end of moveMarkedToPreDelete.
// Centralised here because "what the session learned" is a session-
// lifecycle concept; the PRE-DELETE flow that triggers it stays on TVM
// because it owns the file-system move.
import Foundation

/// State and actions on TriageViewModel that the SessionOrchestrator
/// needs to read, mutate, or invoke. Class-bound so the orchestrator
/// can hold the host weakly and avoid a retain cycle (host owns the
/// orchestrator strongly).
///
/// The surface starts narrow and grows in subsequent slices as more
/// methods migrate. Anything still living on TriageViewModel that the
/// orchestrator needs to touch goes through here. Bridge methods
/// (enrichWithHeaders, checkMemoryBudgetAndCache, cacheNetworkFiles)
/// will be removed once their owning code moves into the orchestrator
/// in subsequent slices.
@MainActor
protocol SessionHost: AnyObject {
    // MARK: Session identity / state
    var images: [ImageEntry] { get set }
    var sessionRootURL: URL? { get set }
    var currentSessionId: String { get set }
    var communityBaseline: CommunityBaseline? { get set }
    var currentSetupFingerprint: SetupFingerprint? { get }

    // MARK: Loading status
    var isLoading: Bool { get set }
    var loadingPhase: TriageViewModel.LoadingPhase { get set }
    var statusMessage: String { get set }
    var needsTableRefresh: Bool { get set }
    var needsScrollToTop: Bool { get set }
    var needsQualityResort: Bool { get set }
    var hasOSCImages: Bool { get set }
    var headerProgress: Double { get set }
    var headerReadCount: Int { get set }
    var headerReadTotal: Int { get set }
    var headerReadStartTime: Date? { get set }
    var headerEstimatedSecondsRemaining: Int? { get set }
    var pendingColumnOrder: [String]? { get set }

    // MARK: Scoring outputs
    var snrRetention: Double { get set }
    var snrRetentionDetail: String { get set }
    var cullingStatus: TriageViewModel.CullingStatus? { get set }
    var isConverged: Bool { get set }
    var convergenceResult: ConvergenceResult? { get set }

    // MARK: VLM mosaic state (mirrors stay on TriageViewModel for SwiftUI bindings)
    var isGeneratingMosaic: Bool { get set }
    var mosaicProgress: String { get set }
    var selectedEntries: [ImageEntry] { get }
    func shouldRotateForMeridian(_ entry: ImageEntry) -> Bool

    // MARK: Cache + download state
    var isCaching: Bool { get set }
    var cacheProgress: Double { get set }
    var cachingStopped: Bool { get set }
    var cachingCount: Int { get set }
    var cachingTotal: Int { get set }
    var cachingStartTime: Date? { get set }
    var cachingEstimatedSecondsRemaining: Int? { get set }
    var isDownloading: Bool { get set }
    var downloadCount: Int { get set }
    var downloadTotal: Int { get set }
    var downloadProgress: Double { get set }
    var downloadStartTime: Date? { get set }
    var downloadEstimatedSecondsRemaining: Int? { get set }
    var networkURLUpdater: ((URL, URL) -> Void)? { get set }
    var applyAllEnabled: Bool { get set }
    var showInspector: Bool { get set }

    // MARK: Render / post-process settings (read by prefetch)
    var debayerEnabled: Bool { get }
    var stretchStrength: Float { get }
    var sharpening: Float { get }
    var contrast: Float { get }
    var darkLevel: Float { get }
    var isSTFLocked: Bool { get }
    var appliedStretch: Float { get set }
    var appliedSharpening: Float { get set }
    var appliedContrast: Float { get set }
    var appliedDarkLevel: Float { get set }
    var appliedLocked: Bool { get set }
    var renderer: MetalRenderer? { get }

    // MARK: Multi-source / security-scoped resource bookkeeping
    var accessedURLs: [URL] { get set }
    var multiSourceSession: Bool { get set }
    var multiSourcePreDeleteConfirmed: Bool { get set }
    func stopAllAccessedURLs()
    func beginSecurityScopes(for urls: [URL])

    // MARK: Download cancellation seam (wraps the NSLock dance on the host)
    var isDownloadCancelled: Bool { get }
    func setDownloadCancelled(_ value: Bool)

    // MARK: Session-load actions performed on the host
    func selectImage(at index: Int)
    func assignSessionIndices()
    func displayCurrentImage()
    func focusTableAfterDelay()
    func triggerApplyAll()
    func checkForReviewPrompt()
    func navigateToObject(_ objectName: String, filter: String?, exposure: Double?, night: String?)

    // MARK: Bridge methods — meridian flip + WCS alignment + dimension check
    // and the column-order sort all stay on TriageViewModel. They're tied to
    // display orientation rather than session lifecycle, so they're out of
    // scope for SessionOrchestrator splits.
    func detectMeridianFlip()
    func applyWCSAlignment()
    func updateMeridianRotation()
    func checkForMixedDimensions()
    func applySortByColumnOrder(_ columnIdentifiers: [String])
}

@MainActor
final class SessionOrchestrator {
    /// Back-reference to the owner. Weak: the host owns this orchestrator
    /// strongly via `let orchestrator: SessionOrchestrator`.
    weak var host: SessionHost?

    // Long-lived dependencies the orchestrator drives directly. Held
    // strongly here once methods migrate; for now they're injected so
    // the wiring in TriageViewModel.init() is established up front.
    let prefetchCache: PrefetchCache?
    let benchmarkStats: BenchmarkStats
    let benchmarkService: BenchmarkService
    let sessionCache: SessionCache
    let sessionOverviewModel: SessionOverviewModel
    let displayAligner: DisplayAligner

    /// App Nap assertion held while caching is active. Acquired in startFullPrefetch /
    /// startFullPrefetchInterleaved and released on completion or stopCaching, so
    /// background pre-cache work isn't throttled by power management. Owned by the
    /// orchestrator since only prefetch methods touch it.
    var appNapAssertion: NSObjectProtocol?

    /// Cancellable handle for the in-flight header-enrichment pass. Cancelled at
    /// the start of every new session load so a stale background read doesn't
    /// stomp on the new session's images. Owned by the orchestrator since only
    /// enrichWithHeaders writes to it.
    var headerEnrichmentTask: Task<Void, Never>?

    /// Retry counter for the delayed rescore loop. Reset on each scheduleQualityRescore
    /// entry; bounded at 3 to keep stale metric callbacks from triggering an
    /// unbounded rescore chain. Owned by the orchestrator since only the
    /// scheduleQualityRescore* pair touches it.
    var rescoreRetryCount = 0

    /// Cancellable handle for the in-flight VLM mosaic generation task.
    /// startVisualValidation populates it; cancelVisualValidation tears it down.
    /// Owned by the orchestrator since only the +VLM extension touches it.
    var vlmGenerationTask: Task<Void, Never>?

    init(
        prefetchCache: PrefetchCache?,
        benchmarkStats: BenchmarkStats,
        benchmarkService: BenchmarkService,
        sessionCache: SessionCache,
        sessionOverviewModel: SessionOverviewModel,
        displayAligner: DisplayAligner
    ) {
        self.prefetchCache = prefetchCache
        self.benchmarkStats = benchmarkStats
        self.benchmarkService = benchmarkService
        self.sessionCache = sessionCache
        self.sessionOverviewModel = sessionOverviewModel
        self.displayAligner = displayAligner
    }

    /// Wire up the back-reference after the host has finished its own
    /// initialization. Called once from TriageViewModel.init().
    func attach(host: SessionHost) {
        self.host = host
    }

    // MARK: - Session commit

    /// Commit retained frames to the per-setup calibration database (for
    /// adaptive Welford learning) and upload the anonymous session summary
    /// to the community-detection service (when telemetry is opted in).
    /// Called from the PRE-DELETE flow once the file-system moves have
    /// completed — what stays on disk is the user's quality verdict for
    /// that session, which is the signal both subsystems learn from.
    func commitSession() {
        guard let host = host else { return }
        guard let fp = host.currentSetupFingerprint else { return }
        CalibrationDatabase.shared.commitSession(entries: host.images, fingerprint: fp)
        // Upload anonymous session summary to community (if opted in)
        CommunityDetectionService.shared.uploadSessionData(entries: host.images, fingerprint: fp)
    }

    // MARK: - Session loading entry points

    /// Single-folder session load (most common path). Reads FITS headers
    /// for WCS pre-scan synchronously, then enrichment + scoring run
    /// later via the host bridge methods.
    func loadSession(url: URL) {
        guard let host = host else { return }
        host.currentSessionId = UUID().uuidString
        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        print("[Bench] LOAD START at \(Date().timeIntervalSince1970) — \(url.lastPathComponent)")
        host.isLoading = true
        host.isCaching = false
        host.cacheProgress = 0
        host.loadingPhase = .scanning
        host.statusMessage = "Scanning \(url.lastPathComponent)..."

        // Release previous session's security-scoped resources before starting a
        // new session. Single-folder load: one scope on the picked folder.
        host.stopAllAccessedURLs()
        host.multiSourceSession = false
        host.multiSourcePreDeleteConfirmed = false

        host.sessionRootURL = url
        prefetchCache?.clear()
        // Reset the display aligner — each session establishes its own per-target references
        displayAligner.reset()
        // Cancel any in-progress NAS downloads
        host.setDownloadCancelled(true)
        host.isDownloading = false
        host.isCaching = false

        host.beginSecurityScopes(for: [url])
        let isNetwork = SessionCache.isNetworkVolume(url)

        Task.detached(priority: .userInitiated) { [weak self] in
            var entries = SessionScanner.scan(rootURL: url)

            // Read FITS headers synchronously (in parallel) for every file BEFORE
            // returning to MainActor. This guarantees that prefetch workers see
            // accurate per-frame WCS data at enqueue time — frames with WCS skip
            // star matching (saving lots of CPU), frames without WCS still get
            // proper star-based fallback alignment. ~300-500ms for typical sessions.
            let headerStart = Date()

            // Use a lock-protected mutation: concurrentPerform writes to entries[idx]
            // from different threads, but each thread writes only its own index, so
            // we need a barrier — Swift Array is value type, so we use an unsafe pointer.
            entries.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: buffer.count) { idx in
                    let headers = MetadataExtractor.readHeaders(from: buffer[idx].decodingURL)
                    guard !headers.isEmpty else { return }
                    // Populate JUST the WCS fields needed for the alignment skip decision
                    // and applyWCSAlignment. Full header enrichment still runs later for
                    // all the other metadata fields.
                    if let v = headers["CRPIX1"] { buffer[idx].wcsCRPIX1 = Double(v) }
                    if let v = headers["CRPIX2"] { buffer[idx].wcsCRPIX2 = Double(v) }
                    if let v = headers["CD1_1"]  { buffer[idx].wcsCD11 = Double(v) }
                    if let v = headers["CD1_2"]  { buffer[idx].wcsCD12 = Double(v) }
                    if let v = headers["CD2_1"]  { buffer[idx].wcsCD21 = Double(v) }
                    if let v = headers["CD2_2"]  { buffer[idx].wcsCD22 = Double(v) }
                    if let v = headers["CRVAL1"], let val = Double(v) { buffer[idx].solvedRA = val }
                    if let v = headers["CRVAL2"], let val = Double(v) { buffer[idx].solvedDec = val }
                    if let v = headers["NAXIS1"], let val = Int(v), val > 0 { buffer[idx].width = val }
                    if let v = headers["NAXIS2"], let val = Int(v), val > 0 { buffer[idx].height = val }
                }
            }
            // Freeze the mutable scan result before crossing the actor boundary —
            // the @Sendable MainActor.run closure cannot capture `var` storage in
            // Swift 6 strict-concurrency mode.
            let scannedEntries = entries
            let headerMs = Int(Date().timeIntervalSince(headerStart) * 1000)
            let wcsCount = scannedEntries.filter { $0.wcsCD11 != nil && $0.wcsCRPIX1 != nil }.count
            print("[Bench] WCS pre-scan: \(wcsCount)/\(scannedEntries.count) frames have WCS (\(headerMs)ms)")

            await MainActor.run { [weak self] in
                guard let self, let host = self.host else { return }
                self.benchmarkStats.markScanComplete(fileCount: scannedEntries.count, totalBytes: scannedEntries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
                host.images = scannedEntries
                host.assignSessionIndices()
                // Disable prefetch star-matching when ANY frame has WCS. Reasoning:
                // when WCS frames exist, applyWCSAlignment defines the global reference.
                // Frames WITHOUT WCS would otherwise star-match against each other,
                // forming a separate reference group inconsistent with WCS.
                // applyWCSAlignment now also handles the WCS-less frames via a
                // rotator-based synthetic transform, all anchored to the same reference.
                let anyHasWCS = scannedEntries.contains { $0.wcsCD11 != nil && $0.wcsCRPIX1 != nil }
                self.prefetchCache?.skipStarMatchingForAlignment = anyHasWCS
                host.isLoading = false
                host.needsTableRefresh = true

                if !scannedEntries.isEmpty {
                    host.selectImage(at: 0)
                    host.needsScrollToTop = true
                }

                // Refresh overview stats but honor user-persisted visibility.
                self.sessionOverviewModel.updateStats(from: scannedEntries)
                // Session Overview visibility is user-persisted; do not force-show.
                host.showInspector = true

                // Enable Apply All by default so cached previews are instant from the start
                host.applyAllEnabled = true

                if isNetwork {
                    host.statusMessage = "Downloading \(scannedEntries.count) images to local cache..."
                    // Clear scanning overlay — download fuel bar takes over from here
                    host.loadingPhase = .none
                    // Header enrichment deferred to after downloads complete — reading headers
                    // from local SSD cache is 100x faster than reading from NAS over SMB
                } else {
                    // Check memory budget — if over budget, shows alert and calls back
                    self.checkMemoryBudgetAndCache(for: scannedEntries)
                }
                // Give table focus so keyboard navigation works immediately
                host.focusTableAfterDelay()

                // Ask for App Store review after 5th session (Apple limits to 3x/year automatically)
                host.checkForReviewPrompt()

                // Security-scoped access tracked in accessedURLs, released on next session or quit
            }

            if isNetwork {
                // Interleaved pipeline: cacheNetworkFiles starts pre-caching
                // automatically after first 4 files download — no separate triggerApplyAll
                await self?.cacheNetworkFiles()
            }
        }
    }

    /// Load specific files (user selected individual files, not a folder).
    func loadFiles(urls: [URL]) {
        guard let host = host else { return }
        let imageURLs = urls.filter { SessionScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else {
            host.statusMessage = "No FITS/XISF files in selection"
            return
        }

        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        host.isLoading = true
        host.isCaching = false
        host.cacheProgress = 0
        host.cachingStopped = false
        host.loadingPhase = .scanning

        // Session root: if all files share the same parent, use that; otherwise
        // compute the deepest common ancestor across the picked file URLs so
        // PRE-DELETE lands somewhere every picked file is reachable from.
        let parentFolders = imageURLs.map { $0.deletingLastPathComponent() }
        let uniqueParents = Array(Set(parentFolders.map { $0.standardizedFileURL }))
        let rootURL: URL
        if uniqueParents.count == 1 {
            rootURL = uniqueParents[0]
            host.multiSourceSession = false
        } else {
            rootURL = Self.commonAncestor(of: uniqueParents)
            host.multiSourceSession = true
        }
        host.multiSourcePreDeleteConfirmed = false

        // Release previous security-scoped resources and grab scopes for every
        // distinct parent folder + each explicit file URL.
        host.stopAllAccessedURLs()
        host.beginSecurityScopes(for: uniqueParents + imageURLs)

        host.sessionRootURL = rootURL
        prefetchCache?.clear()
        host.setDownloadCancelled(true)
        host.isDownloading = false
        host.isCaching = false

        host.statusMessage = "Loading \(imageURLs.count) files..."

        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [ImageEntry] = []
            let fm = FileManager.default

            for url in imageURLs {
                let tokens = NINAFilenameParser.parse(url.lastPathComponent)
                var entry = ImageEntry(url: url)
                entry.date = tokens.date
                entry.time = tokens.time
                entry.target = tokens.target
                entry.frameNumber = tokens.frameNumber
                entry.exposure = tokens.exposure
                entry.filter = tokens.filter
                entry.frameType = tokens.frameType
                entry.gain = tokens.gain
                entry.offset = tokens.offset
                entry.binning = tokens.binning
                entry.sensorTemp = tokens.sensorTemp
                entry.telescope = tokens.telescope
                entry.camera = tokens.camera
                entry.fwhm = tokens.fwhm
                entry.focuserTemp = tokens.focuserTemp
                entry.hfr = tokens.hfr
                entry.starCount = tokens.starCount

                // File size
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    entry.fileSize = size
                }
                entries.append(entry)
            }

            // Sort by date/time ascending
            entries.sort { ($0.dateTime ?? "") < ($1.dateTime ?? "") }
            // Freeze before crossing into MainActor.run (strict concurrency).
            let loadedEntries = entries

            await MainActor.run { [weak self] in
                guard let self, let host = self.host else { return }
                self.benchmarkStats.markScanComplete(fileCount: loadedEntries.count, totalBytes: loadedEntries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
                host.images = loadedEntries
                host.assignSessionIndices()
                host.isLoading = false
                host.needsTableRefresh = true
                host.needsQualityResort = false  // Reset for new session

                if !loadedEntries.isEmpty {
                    host.selectImage(at: 0)
                    host.needsScrollToTop = true
                }

                self.sessionOverviewModel.updateStats(from: loadedEntries)
                // Session Overview visibility is user-persisted (AppSettings.showSessionOverviewPanel).
                // Do not force-show on every load — respects the user's last choice.
                host.showInspector = true

                host.statusMessage = "\(loadedEntries.count) files loaded"
                // Enable Apply All by default so cached previews are instant from the start
                host.applyAllEnabled = true
                host.triggerApplyAll()
                // Read headers in background for metadata enrichment
                self.enrichWithHeaders()
                // Give table focus so keyboard navigation works immediately
                host.focusTableAfterDelay()

                // Same review/coffee prompt logic as loadSession — count this as a session.
                host.checkForReviewPrompt()
            }
        }
    }

    /// Load multiple folders as a merged session. sessionRootURL is set to the
    /// deepest common ancestor of the picked folders (not the first folder's
    /// parent) and security scope is held for EVERY folder so PRE-DELETE moves
    /// succeed for frames originating from any of them.
    func loadMultipleFolders(urls: [URL]) {
        guard let host = host else { return }
        guard !urls.isEmpty else { return }

        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        host.isLoading = true
        host.isCaching = false
        host.cacheProgress = 0
        host.cachingStopped = false
        host.loadingPhase = .scanning

        // Deepest common ancestor across all picked folders — the single
        // location PRE-DELETE will be created in (single-folder case still
        // falls through to that same folder).
        let rootURL: URL
        if urls.count == 1 {
            rootURL = urls[0]
            host.multiSourceSession = false
        } else {
            rootURL = Self.commonAncestor(of: urls)
            host.multiSourceSession = true
        }
        host.multiSourcePreDeleteConfirmed = false

        // Release previous session scopes, then claim a scope for every picked
        // folder so moveMarkedToPreDelete can move frames from any source.
        host.stopAllAccessedURLs()
        host.beginSecurityScopes(for: urls)

        host.sessionRootURL = rootURL
        prefetchCache?.clear()
        host.setDownloadCancelled(true)
        host.isDownloading = false
        host.isCaching = false

        let folderNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        host.statusMessage = "Scanning \(urls.count) folders: \(folderNames)..."

        Task.detached(priority: .userInitiated) { [weak self] in
            var allEntries: [ImageEntry] = []
            for url in urls {
                let entries = SessionScanner.scan(rootURL: url)
                allEntries.append(contentsOf: entries)
            }

            allEntries.sort { ($0.dateTime ?? "") < ($1.dateTime ?? "") }
            // Freeze before crossing into MainActor.run (strict concurrency).
            let mergedEntries = allEntries

            await MainActor.run { [weak self] in
                guard let self, let host = self.host else { return }
                self.benchmarkStats.markScanComplete(fileCount: mergedEntries.count, totalBytes: mergedEntries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
                host.images = mergedEntries
                host.assignSessionIndices()
                host.isLoading = false
                host.needsTableRefresh = true
                host.needsQualityResort = false

                if !mergedEntries.isEmpty {
                    host.selectImage(at: 0)
                    host.needsScrollToTop = true
                }

                self.sessionOverviewModel.updateStats(from: mergedEntries)
                // Session Overview visibility is user-persisted; do not force-show.
                host.showInspector = true
                host.applyAllEnabled = true

                self.checkMemoryBudgetAndCache(for: mergedEntries)

                // Same review/coffee prompt logic as loadSession — count this as a session.
                host.checkForReviewPrompt()
            }
        }
    }

    /// Handle a mixed NSOpenPanel selection of loose files + one or more folders.
    /// Each directory is scanned via SessionScanner; each standalone file produces
    /// its own ImageEntry. Results are deduped by standardizedFileURL so a file
    /// listed both inside a picked folder and as a top-level pick appears once.
    func loadMixedSelection(files: [URL], directories: [URL]) {
        guard let host = host else { return }
        let fileEntries = files.filter {
            SessionScanner.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !fileEntries.isEmpty || !directories.isEmpty else {
            host.statusMessage = "No FITS/XISF files or folders in selection"
            return
        }

        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        host.isLoading = true
        host.isCaching = false
        host.cacheProgress = 0
        host.cachingStopped = false
        host.loadingPhase = .scanning

        // Deepest common ancestor across every picked URL (files' parents + dirs),
        // used as sessionRootURL / PRE-DELETE location.
        let parentsAndDirs: [URL] = fileEntries.map { $0.deletingLastPathComponent() } + directories
        let uniqueScopes = Array(Set(parentsAndDirs.map { $0.standardizedFileURL }))
        let rootURL: URL
        if uniqueScopes.count == 1 {
            rootURL = uniqueScopes[0]
            host.multiSourceSession = false
        } else {
            rootURL = Self.commonAncestor(of: uniqueScopes)
            host.multiSourceSession = true
        }
        host.multiSourcePreDeleteConfirmed = false

        // Claim scopes for every picked folder, every file parent, and the files
        // themselves — the sandbox needs the individual file URLs to move them
        // into PRE-DELETE.
        host.stopAllAccessedURLs()
        host.beginSecurityScopes(for: uniqueScopes + fileEntries)

        host.sessionRootURL = rootURL
        prefetchCache?.clear()
        host.setDownloadCancelled(true)
        host.isDownloading = false
        host.isCaching = false

        let summary = "\(fileEntries.count) file\(fileEntries.count == 1 ? "" : "s") + \(directories.count) folder\(directories.count == 1 ? "" : "s")"
        host.statusMessage = "Scanning \(summary)..."

        Task.detached(priority: .userInitiated) { [weak self] in
            var merged: [ImageEntry] = []
            let fm = FileManager.default

            // Folder scans
            for dir in directories {
                merged.append(contentsOf: SessionScanner.scan(rootURL: dir))
            }

            // Loose files — build ImageEntries the same way loadFiles does
            for url in fileEntries {
                let tokens = NINAFilenameParser.parse(url.lastPathComponent)
                var entry = ImageEntry(url: url)
                entry.date = tokens.date
                entry.time = tokens.time
                entry.target = tokens.target
                entry.frameNumber = tokens.frameNumber
                entry.exposure = tokens.exposure
                entry.filter = tokens.filter
                entry.frameType = tokens.frameType
                entry.gain = tokens.gain
                entry.offset = tokens.offset
                entry.binning = tokens.binning
                entry.sensorTemp = tokens.sensorTemp
                entry.telescope = tokens.telescope
                entry.camera = tokens.camera
                entry.fwhm = tokens.fwhm
                entry.focuserTemp = tokens.focuserTemp
                entry.hfr = tokens.hfr
                entry.starCount = tokens.starCount
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    entry.fileSize = size
                }
                merged.append(entry)
            }

            // Dedupe by standardized URL — a file listed both inside a picked
            // folder and as its own pick collapses to one entry.
            var seen: Set<URL> = []
            let deduped = merged.filter { entry in
                let key = entry.url.standardizedFileURL
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }

            let sorted = deduped.sorted { ($0.dateTime ?? "") < ($1.dateTime ?? "") }

            await MainActor.run { [weak self] in
                guard let self, let host = self.host else { return }
                self.benchmarkStats.markScanComplete(
                    fileCount: sorted.count,
                    totalBytes: sorted.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
                host.images = sorted
                host.assignSessionIndices()
                host.isLoading = false
                host.needsTableRefresh = true
                host.needsQualityResort = false

                if !sorted.isEmpty {
                    host.selectImage(at: 0)
                    host.needsScrollToTop = true
                }

                self.sessionOverviewModel.updateStats(from: sorted)
                // Respect user-persisted Session Overview visibility.
                host.showInspector = true
                host.applyAllEnabled = true
                host.triggerApplyAll()
                self.enrichWithHeaders()
                host.focusTableAfterDelay()

                host.statusMessage = "\(sorted.count) frames loaded from \(summary)"
            }
        }
    }

    // MARK: - Helpers

    /// Wire session overview tap callbacks (idempotent — safe to call multiple times).
    /// Each closure forwards into the host so navigation stays driven by the view model.
    private func wireSessionOverviewCallbacks() {
        sessionOverviewModel.onObjectTapped = { [weak self] name in
            self?.host?.navigateToObject(name, filter: nil, exposure: nil, night: nil)
        }
        sessionOverviewModel.onFilterTapped = { [weak self] obj, filter, exposure, night in
            self?.host?.navigateToObject(obj, filter: filter, exposure: exposure, night: night)
        }
    }

    /// Compute the deepest common ancestor directory across a set of URLs.
    /// Returns `/` if the URLs don't share any common parent, or the first URL's
    /// parent when the set has a single element. Used to derive sessionRootURL
    /// for multi-folder / mixed selections so PRE-DELETE ends up at a sensible
    /// location (and so the selection is still reachable from the sandbox).
    static func commonAncestor(of urls: [URL]) -> URL {
        guard let first = urls.first else {
            return URL(fileURLWithPath: "/")
        }
        if urls.count == 1 {
            // For a single URL, return its parent (or itself if it's a directory
            // — the caller is responsible for passing the right thing).
            return first
        }
        // Build path-component arrays for each URL and walk forward while every
        // array agrees. The longest common prefix is the deepest common ancestor.
        let componentLists = urls.map { $0.pathComponents }
        var prefix: [String] = []
        var idx = 0
        outer: while true {
            var current: String?
            for list in componentLists {
                guard idx < list.count else { break outer }
                if current == nil { current = list[idx] }
                if list[idx] != current { break outer }
            }
            if let c = current { prefix.append(c) }
            idx += 1
        }
        // Reconstruct a URL from the shared prefix. Empty prefix → "/".
        let path = prefix.isEmpty ? "/" : ("/" + prefix.dropFirst().joined(separator: "/"))
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
