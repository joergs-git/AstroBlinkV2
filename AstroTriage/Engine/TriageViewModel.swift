// v2.2.0
import Foundation
import SwiftUI
import Metal
import MetalKit
import UniformTypeIdentifiers

// Central state manager for the triage workflow
// @MainActor ensures all UI updates happen on main thread (Lesson L9)
@MainActor
class TriageViewModel: ObservableObject {
    @Published var images: [ImageEntry] = []
    @Published var selectedIndex: Int = -1
    @Published var currentDecodedImage: DecodedImage?
    @Published var sessionRootURL: URL?
    @Published var statusMessage: String = "No session loaded"
    @Published var isLoading: Bool = false

    // Loading phase for user feedback overlay
    enum LoadingPhase: String {
        case none = ""
        case scanning = "Scanning folder..."
        case readingHeaders = "Reading file headers..."
    }
    @Published var loadingPhase: LoadingPhase = .none
    @Published var headerProgress: Double = 0
    @Published var headerReadCount: Int = 0
    @Published var headerReadTotal: Int = 0

    // Stretch slider: affects ONLY the currently displayed image (not cached previews)
    // Maps to STF targetBackground [0.0 .. 0.50]
    // Default 0.25 = PixInsight standard; 0.0 = linear; 0.50 = max stretch
    @Published var stretchStrength: Float = STFCalculator.defaultTargetBackground

    // Night mode: black background + red UI for dark-adapted vision
    @Published var nightMode: Bool = false

    // Debayer toggle: when ON, OSC (one-shot-color) images are debayered to RGB
    // Default OFF for faster caching. Only relevant when session has OSC images.
    @Published var debayerEnabled: Bool = false

    // Post-processing sliders: GPU-accelerated adjustments on the display texture
    // These do NOT modify raw data — only the visual output after STF stretch
    @Published var sharpening: Float = 0.0    // Range -2 to +2 (negative = blur, positive = sharpen)
    @Published var contrast: Float = 0.0      // Range -1 to 1 (0 = off)
    @Published var darkLevel: Float = 0.0     // Range 0–0.5 (0 = off)

    // True when the current session contains OSC images (detected via BAYERPAT header)
    @Published var hasOSCImages: Bool = false

    // Prefetch progress (0.0 to 1.0)
    @Published var cacheProgress: Double = 0
    @Published var cachingCount: Int = 0
    @Published var cachingTotal: Int = 0
    @Published var isCaching: Bool = false

    // Triggers a table reload in updateNSView (for checkbox/mark changes)
    @Published var needsTableRefresh: Bool = false

    // Hide marked images: when true, marked images are invisible in the list
    @Published var hideMarked: Bool = false

    // Skip marked images during arrow-key navigation
    @Published var skipMarked: Bool = false

    // Side panel visibility (integrated into main window)
    @Published var showInspector: Bool = false
    @Published var showSessionOverview: Bool = false

    // Real-time system stats (CPU + memory), updated every 2 seconds
    struct SystemStats {
        var memory: String   // "MEM 2.1 GB"
        var cpu: String      // "CPU 34% | 28 cores"
    }
    @Published var systemStats: SystemStats?
    private var statsTimer: Timer?

    // Models for embedded side panels
    let headerInspectorModel = HeaderInspectorModel()
    let sessionOverviewModel = SessionOverviewModel()

    // Current sort descriptors (supports multi-level sorting)
    private var currentSortDescriptors: [NSSortDescriptor] = []

    // Metal device for buffer creation
    let device: MTLDevice?

    // Renderer reference for stretch mode toggle (set by ContentView)
    weak var renderer: MetalRenderer?

    // Preview cache: pre-stretched, binned BGRA8 textures for instant display
    private var prefetchCache: PrefetchCache?

    // Local file cache for network volumes
    private let sessionCache = SessionCache()

    var selectedImage: ImageEntry? {
        guard selectedIndex >= 0, selectedIndex < images.count else { return nil }
        return images[selectedIndex]
    }

    var hasSubfolders: Bool {
        images.contains { !$0.subfolder.isEmpty }
    }

    // Count of already-cached preview images
    var prefetchCachedCount: Int {
        prefetchCache?.cachedCount ?? 0
    }

    // Check if a specific image URL has been cached (for table UI indicator)
    func isImageCached(_ url: URL) -> Bool {
        prefetchCache?.isCached(url) ?? false
    }

    // Count of images marked for deletion
    var markedCount: Int {
        images.filter { $0.isMarkedForDeletion }.count
    }

    // MARK: - Filter Statistics

    var filterStatistics: String {
        var grouped: [String: (count: Int, exposure: Double)] = [:]
        var totalExposure: Double = 0

        for entry in images {
            let f = entry.filter ?? "none"
            let current = grouped[f, default: (0, 0.0)]
            let exp = entry.exposure ?? 0
            grouped[f] = (current.count + 1, current.exposure + exp)
            totalExposure += exp
        }

        guard !grouped.isEmpty else { return "" }

        let sorted = grouped.sorted { $0.key < $1.key }
        let parts = sorted.map { (filter, data) in
            let timeStr = formatDuration(data.exposure)
            return "\(filter)(#\(data.count) // \(timeStr))"
        }

        let totalStr = formatDuration(totalExposure)
        return parts.joined(separator: "  ") + "  TOTAL: \(totalStr)"
    }

    // Visible images: all images or only unmarked, depending on hideMarked
    var visibleImages: [ImageEntry] {
        if hideMarked {
            return images.filter { !$0.isMarkedForDeletion }
        }
        return images
    }

    // Track security-scoped resource for proper cleanup
    private var accessedURL: URL?

    init() {
        self.device = MTLCreateSystemDefaultDevice()
        if let device = self.device {
            self.prefetchCache = PrefetchCache(device: device)
        }
        // Clean up stale network cache directories (keep most recent 3)
        SessionCache.cleanupOldCaches()

        // Restore persisted settings
        if let v = AppSettings.loadFloat(for: .stretchStrength) { stretchStrength = v }
        if let v = AppSettings.loadFloat(for: .sharpening) { sharpening = v }
        if let v = AppSettings.loadFloat(for: .contrast) { contrast = v }
        if let v = AppSettings.loadFloat(for: .darkLevel) { darkLevel = v }
        if let v = AppSettings.loadBool(for: .nightMode) { nightMode = v }
        if let v = AppSettings.loadBool(for: .debayerEnabled) { debayerEnabled = v }
        if let v = AppSettings.loadBool(for: .skipMarked) { skipMarked = v }
        if let v = AppSettings.loadBool(for: .hideMarked) { hideMarked = v }

        // Start lightweight system stats polling (CPU + memory every 2s)
        startStatsPolling()
    }

    private func startStatsPolling() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSystemStats()
            }
        }
    }

    private func updateSystemStats() {
        // App memory usage via mach_task_basic_info
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let memResult = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let memGB: String
        if memResult == KERN_SUCCESS {
            let mb = Double(info.resident_size) / (1024 * 1024)
            memGB = mb >= 1024 ? String(format: "MEM %.1f GB", mb / 1024) : String(format: "MEM %d MB", Int(mb))
        } else {
            memGB = "MEM —"
        }

        // Process CPU usage via TASK_THREAD_TIMES_INFO
        var threadInfo = task_thread_times_info()
        var threadCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size) / 4
        let cpuResult = withUnsafeMutablePointer(to: &threadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &threadCount)
            }
        }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let cpuStr: String
        if cpuResult == KERN_SUCCESS {
            // Show active core count (actual CPU% requires delta tracking which is heavyweight)
            cpuStr = "CPU \(cores) cores"
        } else {
            cpuStr = "\(cores) cores"
        }

        systemStats = SystemStats(memory: memGB, cpu: cpuStr)
    }

    // MARK: - Session Management

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .init(filenameExtension: "xisf")!,
            .init(filenameExtension: "fits")!,
            .init(filenameExtension: "fit")!,
            .init(filenameExtension: "fts")!
        ]
        panel.message = "Select a folder or individual FITS/XISF files"

        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        // Check if user selected a single directory
        var isDir: ObjCBool = false
        if urls.count == 1, FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir), isDir.boolValue {
            loadSession(url: urls[0])
        } else {
            // User selected individual files — load them directly
            loadFiles(urls: urls)
        }
    }

    // Load specific files (user selected individual files, not a folder)
    func loadFiles(urls: [URL]) {
        let imageURLs = urls.filter { SessionScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else {
            statusMessage = "No FITS/XISF files in selection"
            return
        }

        isLoading = true
        isCaching = false
        cacheProgress = 0
        cachingStopped = false
        loadingPhase = .scanning

        // Use the parent folder of the first file as session root
        let rootURL = imageURLs[0].deletingLastPathComponent()

        // Release previous security-scoped resource
        if let prev = accessedURL {
            prev.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }

        // Start security-scoped access to the root directory (needed for PRE-DELETE etc.)
        let accessed = rootURL.startAccessingSecurityScopedResource()
        if accessed { accessedURL = rootURL }

        sessionRootURL = rootURL
        prefetchCache?.clear()

        statusMessage = "Loading \(imageURLs.count) files..."

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

            await MainActor.run {
                guard let self = self else { return }
                self.images = entries
                self.isLoading = false
                self.needsTableRefresh = true

                if !entries.isEmpty {
                    self.selectImage(at: 0)
                }

                self.sessionOverviewModel.updateStats(from: entries)
                self.showSessionOverview = true
                self.showInspector = true

                self.statusMessage = "\(entries.count) files loaded"
                // Enable Apply All by default so cached previews are instant from the start
                self.applyAllEnabled = true
                self.triggerApplyAll()
                // Read headers in background for metadata enrichment
                self.enrichWithHeaders()
                // Give table focus so keyboard navigation works immediately
                self.focusTableAfterDelay()
            }
        }
    }

    func loadSession(url: URL) {
        isLoading = true
        isCaching = false
        cacheProgress = 0
        loadingPhase = .scanning
        statusMessage = "Scanning \(url.lastPathComponent)..."

        // Release previous security-scoped resource before loading new session
        if let prev = accessedURL {
            prev.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }

        sessionRootURL = url
        prefetchCache?.clear()

        let accessed = url.startAccessingSecurityScopedResource()
        if accessed { accessedURL = url }
        let isNetwork = SessionCache.isNetworkVolume(url)

        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = SessionScanner.scan(rootURL: url)

            await MainActor.run {
                guard let self = self else { return }
                self.images = entries
                self.isLoading = false
                self.needsTableRefresh = true

                if !entries.isEmpty {
                    self.selectImage(at: 0)
                }

                // Show both side panels with session data
                self.sessionOverviewModel.updateStats(from: entries)
                self.showSessionOverview = true
                self.showInspector = true

                // Enable Apply All by default so cached previews are instant from the start
                self.applyAllEnabled = true

                if isNetwork {
                    self.statusMessage = "Downloading \(entries.count) images to local cache..."
                } else {
                    // Bake default settings into cache for instant navigation
                    self.triggerApplyAll()
                    // Read headers in background for metadata enrichment
                    self.enrichWithHeaders()
                }
                // Give table focus so keyboard navigation works immediately
                self.focusTableAfterDelay()

                // Security-scoped access tracked in accessedURL, released on next session or quit
            }

            if isNetwork {
                await self?.cacheNetworkFiles()
                await MainActor.run {
                    self?.triggerApplyAll()
                }
            }
        }
    }

    // Prevent App Nap from throttling caching when app is in background
    private var appNapAssertion: NSObjectProtocol?

    // Start pre-decoding + stretching ALL images (skips already-cached)
    private func startFullPrefetch() {
        guard let prefetchCache = prefetchCache else { return }

        isCaching = true
        cachingStopped = false
        cachingTotal = images.count
        cachingCount = 0
        cacheProgress = 0

        // Disable App Nap during caching so background processing continues
        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Pre-caching astrophotography images"
        )

        // Pass applied stretch target, locked STF params, and post-process params for cache baking
        let targetBg: Float? = abs(appliedStretch - STFCalculator.defaultTargetBackground) > 0.001
            ? appliedStretch : nil
        let lockedParams: [STFParams]? = appliedLocked ? renderer?.lockedSTFParams : nil
        let ppParams: (sharpening: Float, contrast: Float, darkLevel: Float)?
        if abs(appliedSharpening) > 0.001 || abs(appliedContrast) > 0.001 || appliedDarkLevel > 0.001 {
            ppParams = (appliedSharpening, appliedContrast, appliedDarkLevel)
        } else {
            ppParams = nil
        }

        prefetchCache.prefetchAll(
            images: images,
            debayerEnabled: debayerEnabled,
            targetBackground: lockedParams != nil ? nil : targetBg,  // locked params override target
            lockedSTFParams: lockedParams,
            postProcessParams: ppParams
        ) { [weak self] completed, total in
            guard let self = self else { return }
            self.cachingCount = completed
            self.cachingTotal = total
            self.cacheProgress = total > 0 ? Double(completed) / Double(total) : 0

            // Refresh table periodically so cache checkmarks appear (every 4 images)
            if completed % 4 == 0 || completed == total {
                self.needsTableRefresh = true
            }

            if completed < total {
                self.statusMessage = "Pre-caching \(completed)/\(total)..."
            } else {
                self.isCaching = false
                self.needsTableRefresh = true
                self.statusMessage = "\(total) images cached — instant navigation ready"
                // Release App Nap assertion when caching completes
                self.appNapAssertion = nil
            }
        }
    }

    // Tracks whether caching was stopped by user (for continue button)
    @Published var cachingStopped: Bool = false

    // Stop the current caching process (keeps already-cached previews)
    func stopCaching() {
        prefetchCache?.stopPrefetch()
        isCaching = false
        cachingStopped = true
        appNapAssertion = nil  // Release App Nap assertion
        let cached = prefetchCache?.cachedCount ?? 0
        statusMessage = "Caching paused — \(cached) of \(images.count) images cached"
    }

    // Continue caching from where it left off
    func continueCaching() {
        cachingStopped = false
        startFullPrefetch()
    }

    // Cache all image files from network to local disk using parallel streams
    // 4 concurrent copies to saturate 10GbE / multi-stream SMB connections
    private func cacheNetworkFiles() async {
        guard let rootURL = sessionRootURL else { return }
        sessionCache.prepareSession(rootURL: rootURL)

        let total = images.count
        let sourceURLs = images.map { $0.url }

        // Thread-safe results array
        let results = UnsafeMutableBufferPointer<URL?>.allocate(capacity: total)
        results.initialize(repeating: nil)
        let progressCounter = NSLock()
        var progressCount = 0

        let sessionCacheRef = sessionCache

        // Parallel copy with 4 concurrent streams (SSD/NAS sweet spot)
        await Task.detached(priority: .utility) {
            DispatchQueue.concurrentPerform(iterations: total) { index in
                let localURL = sessionCacheRef.cacheFile(sourceURL: sourceURLs[index])
                results[index] = localURL

                progressCounter.lock()
                progressCount += 1
                let current = progressCount
                progressCounter.unlock()

                if current % 4 == 0 || current == total {
                    Task { @MainActor [weak self] in
                        self?.statusMessage = "Downloading to local cache \(current)/\(total)..."
                    }
                }
            }
        }.value

        // Apply all cached URLs in one batch on main actor
        for index in 0..<total {
            if let localURL = results[index], index < images.count {
                images[index].decodingURL = localURL
            }
        }

        results.deallocate()
        statusMessage = "\(total) files cached locally"

        Task.detached(priority: .background) {
            SessionCache.cleanupOldCaches()
        }
    }

    // MARK: - Background Header Enrichment

    // Read file headers in background and update entries with authoritative metadata
    // (BAYERPAT, FILTER, GAIN, CCD-TEMP, etc.) — runs after fast filename-only scan
    private var headerEnrichmentTask: Task<Void, Never>?

    // Parsed header data for a single image (used for parallel header reading)
    private struct HeaderData {
        let index: Int
        let headers: [String: String]
    }

    private func enrichWithHeaders() {
        headerEnrichmentTask?.cancel()
        let urls = images.map { $0.url }
        let total = urls.count
        loadingPhase = .readingHeaders
        headerReadCount = 0
        headerReadTotal = total
        headerProgress = 0

        // Cap concurrency: ~8 for local SSD (queue depth), ~4 for network
        let concurrency = min(8, ProcessInfo.processInfo.activeProcessorCount)

        headerEnrichmentTask = Task.detached(priority: .utility) { [weak self] in
            // Read all headers in parallel using concurrentPerform
            var allHeaders = Array(repeating: [String: String](), count: total)
            let headerLock = NSLock()
            let progressCounter = NSLock()
            var progressCount = 0

            DispatchQueue.concurrentPerform(iterations: total) { index in
                let headers = MetadataExtractor.readHeaders(from: urls[index])
                headerLock.lock()
                allHeaders[index] = headers
                headerLock.unlock()

                // Update progress periodically (every 8 files to avoid UI thrashing)
                progressCounter.lock()
                progressCount += 1
                let currentProgress = progressCount
                progressCounter.unlock()

                if currentProgress % 8 == 0 || currentProgress == total {
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.headerReadCount = currentProgress
                        self.headerProgress = total > 0 ? Double(currentProgress) / Double(total) : 0
                    }
                }
            }

            // Apply all headers in one batch on main actor
            await MainActor.run {
                guard let self = self else { return }
                var foundOSC = false

                for index in 0..<total {
                    guard index < self.images.count,
                          self.images[index].url == urls[index] else { continue }

                    let headers = allHeaders[index]
                    guard !headers.isEmpty else { continue }

                    // Apply header values (authoritative over filename)
                    if let filter = headers["FILTER"], !filter.isEmpty {
                        self.images[index].filter = filter
                    }
                    if let exp = headers["EXPTIME"] ?? headers["EXPOSURE"], let val = Double(exp) {
                        self.images[index].exposure = val
                    }
                    if let gain = headers["GAIN"], let val = Int(gain) {
                        self.images[index].gain = val
                    }
                    if let temp = headers["CCD-TEMP"], let val = Double(temp) {
                        self.images[index].sensorTemp = val
                    }
                    if let fwhm = headers["STARFWHM"] ?? headers["FWHM"], let val = Double(fwhm) {
                        self.images[index].fwhm = val
                    }
                    if let obj = headers["OBJECT"], !obj.isEmpty {
                        self.images[index].target = obj
                    }
                    if let cam = headers["INSTRUME"], !cam.isEmpty {
                        self.images[index].camera = cam
                    }
                    if let scope = headers["TELESCOP"], !scope.isEmpty {
                        self.images[index].telescope = scope
                    }
                    if let bayer = headers["BAYERPAT"], !bayer.isEmpty {
                        self.images[index].bayerPattern = bayer.trimmingCharacters(in: .whitespaces).uppercased()
                    }
                    if let off = headers["OFFSET"], let val = Int(off) {
                        self.images[index].offset = val
                    }
                    if let xbin = headers["XBINNING"], let val = Int(xbin) {
                        self.images[index].binning = self.images[index].binning ?? "\(val)x\(val)"
                    }
                    if let focTemp = headers["FOCTEMP"], let val = Double(focTemp) {
                        self.images[index].focuserTemp = val
                    }
                    if let dateStr = headers["DATE-LOC"] ?? headers["DATE-OBS"], !dateStr.isEmpty {
                        if dateStr.count >= 10 {
                            self.images[index].date = self.images[index].date ?? String(dateStr.prefix(10))
                        }
                        if dateStr.count >= 19, let tIndex = dateStr.firstIndex(of: "T") {
                            let timeStart = dateStr.index(after: tIndex)
                            let timeEnd = dateStr.index(timeStart, offsetBy: 8, limitedBy: dateStr.endIndex) ?? dateStr.endIndex
                            self.images[index].time = self.images[index].time ?? String(dateStr[timeStart..<timeEnd])
                        }
                    }

                    // Ambient temperature
                    if let ambTemp = headers["AMBTEMP"] ?? headers["AMBIENT"], let val = Double(ambTemp) {
                        self.images[index].ambientTemp = val
                    }
                    // Frame type from IMAGETYP/FRAME header (authoritative)
                    if let imageType = headers["IMAGETYP"] ?? headers["FRAME"], !imageType.isEmpty {
                        self.images[index].frameType = MetadataExtractor.normalizeFrameType(imageType)
                    }

                    if self.images[index].bayerPattern != nil {
                        foundOSC = true
                    }
                }

                self.needsTableRefresh = true
                self.loadingPhase = .none
                self.sessionOverviewModel.updateStats(from: self.images)
                self.hasOSCImages = foundOSC
            }
        }
    }

    // MARK: - Stretch Strength (current image only)

    // Update stretch for the currently displayed image only.
    // Does NOT invalidate or re-cache previews — cached images use default stretch.
    // When navigating to another image, slider resets to default.
    func updateStretchStrength(_ value: Float) {
        stretchStrength = value
        AppSettings.saveFloat(value, for: .stretchStrength)

        // Auto-disable Apply All — user is tweaking, let them decide when to re-apply
        if applyAllEnabled { applyAllEnabled = false }

        // If renderer already has an image loaded (mono or debayered RGB),
        // recalculate STF from renderer's currentImage with new targetBackground.
        // This correctly handles both mono and debayered color images.
        if let rendererImage = renderer?.currentImage, let mtkView = findMTKView(), let renderer = renderer {
            let stfParams = STFCalculator.calculate(from: rendererImage, targetBackground: value)
            renderer.setSTFParams(stfParams)
            mtkView.needsDisplay = true
            return
        }

        // If showing a cached preview, need to decode raw data first
        guard let entry = selectedImage, let device = device else { return }
        let targetURL = entry.url
        let decodeURL = entry.decodingURL
        let bayerPattern = debayerEnabled ? entry.bayerPattern : nil

        currentDecodeTask?.cancel()
        currentDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = ImageDecoder.decode(url: decodeURL, device: device)
            await MainActor.run {
                guard let self = self, self.selectedImage?.url == targetURL else { return }
                if case .success(let decoded) = result {
                    self.currentDecodedImage = decoded
                    if let mtkView = self.findMTKView(), let renderer = self.renderer {
                        renderer.setImage(decoded, in: mtkView,
                                          bayerPattern: bayerPattern, targetBackground: value)
                    }
                }
            }
        }
    }

    // Toggle night mode for dark-adapted vision
    func toggleNightMode() {
        nightMode.toggle()
        AppSettings.saveBool(nightMode, for: .nightMode)
        statusMessage = nightMode ? "Night mode ON" : "Night mode OFF"
    }

    // Toggle debayer for OSC images — re-caches all previews with/without debayer
    func toggleDebayer() {
        debayerEnabled.toggle()
        AppSettings.saveBool(debayerEnabled, for: .debayerEnabled)
        statusMessage = debayerEnabled
            ? "Debayer ON — re-caching with color interpolation..."
            : "Debayer OFF — re-caching as grayscale..."
        // Clear current image so displayCurrentImage does a fresh decode with new debayer state
        currentDecodedImage = nil
        if let mtkView = findMTKView() {
            renderer?.clearImage(in: mtkView)
        }
        // Re-cache with new debayer setting
        prefetchCache?.clear()
        startFullPrefetch()
        // Refresh the currently displayed image so debayer takes effect immediately
        displayCurrentImage()
    }

    // MARK: - Post-Processing

    // Update post-processing params and trigger re-render (GPU-only, no STF recompute)
    func updatePostProcessParams() {
        AppSettings.saveFloat(sharpening, for: .sharpening)
        AppSettings.saveFloat(contrast, for: .contrast)
        AppSettings.saveFloat(darkLevel, for: .darkLevel)

        // Auto-disable Apply All — user is tweaking, let them decide when to re-apply
        if applyAllEnabled { applyAllEnabled = false }

        guard let renderer = renderer else { return }
        renderer.setPostProcessParams(
            sharpening: sharpening,
            contrast: contrast,
            darkLevel: darkLevel
        )
        if let mtkView = findMTKView() {
            mtkView.needsDisplay = true
        }
    }

    // Reset post-processing sliders to defaults
    func resetPostProcess() {
        sharpening = 0.0
        contrast = 0.0
        darkLevel = 0.0
        updatePostProcessParams()
    }

    // Reset all settings to factory defaults
    func resetAllSettings() {
        AppSettings.resetAll()
        stretchStrength = STFCalculator.defaultTargetBackground
        nightMode = false
        debayerEnabled = false
        skipMarked = false
        hideMarked = false
        sharpening = 0.0
        contrast = 0.0
        darkLevel = 0.0
        needsTableRefresh = true
        updatePostProcessParams()
        statusMessage = "Settings reset to defaults"
    }

    // MARK: - Navigation

    func selectImage(at index: Int) {
        guard index >= 0, index < images.count else { return }
        selectedIndex = index
        displayCurrentImage()
    }

    func navigateNext() {
        guard !images.isEmpty else { return }

        if skipMarked {
            // Find next non-marked, stop at end (no wrap)
            var next = selectedIndex + 1
            while next < images.count {
                if !images[next].isMarkedForDeletion {
                    selectImage(at: next)
                    return
                }
                next += 1
            }
            // No more unmarked images after current position
        } else {
            // Stop at last image (no wrap)
            let next = selectedIndex + 1
            if next < images.count {
                selectImage(at: next)
            }
        }
    }

    func navigatePrevious() {
        guard !images.isEmpty else { return }

        if skipMarked {
            // Find previous non-marked, stop at beginning (no wrap)
            var prev = selectedIndex - 1
            while prev >= 0 {
                if !images[prev].isMarkedForDeletion {
                    selectImage(at: prev)
                    return
                }
                prev -= 1
            }
            // No more unmarked images before current position
        } else {
            // Stop at first image (no wrap)
            if selectedIndex > 0 {
                selectImage(at: selectedIndex - 1)
            }
        }
    }

    // Jump to first image in the list
    func navigateToFirst() {
        guard !images.isEmpty else { return }
        if skipMarked {
            for i in 0..<images.count {
                if !images[i].isMarkedForDeletion {
                    selectImage(at: i)
                    return
                }
            }
        } else {
            selectImage(at: 0)
        }
    }

    // Jump to last image in the list
    func navigateToLast() {
        guard !images.isEmpty else { return }
        if skipMarked {
            for i in stride(from: images.count - 1, through: 0, by: -1) {
                if !images[i].isMarkedForDeletion {
                    selectImage(at: i)
                    return
                }
            }
        } else {
            selectImage(at: images.count - 1)
        }
    }

    // MARK: - Skip/Hide Marked

    func toggleSkipMarked() {
        skipMarked.toggle()
        AppSettings.saveBool(skipMarked, for: .skipMarked)
        statusMessage = skipMarked ? "Skip marked: ON" : "Skip marked: OFF"
    }

    func toggleHideMarked() {
        hideMarked.toggle()
        AppSettings.saveBool(hideMarked, for: .hideMarked)
        needsTableRefresh = true
        statusMessage = hideMarked ? "Hide marked: ON" : "Hide marked: OFF"
    }

    // MARK: - Pre-Delete Toggle

    func togglePreDelete() {
        guard selectedIndex >= 0, selectedIndex < images.count else { return }
        togglePreDelete(at: selectedIndex)
    }

    func togglePreDelete(at index: Int) {
        guard index >= 0, index < images.count else { return }
        images[index].isMarkedForDeletion.toggle()

        let marked = images[index].isMarkedForDeletion
        statusMessage = marked ? "Marked for deletion" : "Unmarked"
        needsTableRefresh = true
    }

    func togglePreDeleteForRows(_ rows: IndexSet) {
        let anyUnmarked = rows.contains { idx in
            idx < images.count && !images[idx].isMarkedForDeletion
        }

        var count = 0
        for index in rows where index < images.count {
            images[index].isMarkedForDeletion = anyUnmarked
            count += 1
        }

        statusMessage = anyUnmarked ? "Marked \(count) for deletion" : "Unmarked \(count)"
        needsTableRefresh = true
    }

    // MARK: - Move Marked to PRE-DELETE Folder

    // Undo stack: each entry is a list of (original URL, PRE-DELETE URL, ImageEntry)
    struct PreDeleteUndoEntry {
        let originalURL: URL
        let preDeleteURL: URL
        let entry: ImageEntry
        let originalIndex: Int
    }
    // Full undo stack — each element is one pre-delete operation (can undo all)
    @Published var preDeleteUndoStack: [[PreDeleteUndoEntry]] = []

    var canUndoPreDelete: Bool { !preDeleteUndoStack.isEmpty }

    func moveMarkedToPreDelete() {
        guard let rootURL = sessionRootURL else {
            statusMessage = "No session loaded"
            return
        }

        let markedImages = images.filter { $0.isMarkedForDeletion }
        guard !markedImages.isEmpty else {
            statusMessage = "No images marked for deletion"
            return
        }

        // Show confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Move \(markedImages.count) marked images?"
        alert.informativeText = "Files will be moved to a \"PRE-DELETE\" folder inside the session directory. No files will be permanently deleted. You can undo this action."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to PRE-DELETE")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Create PRE-DELETE folder if needed
        let preDeleteDir = rootURL.appendingPathComponent("PRE-DELETE", isDirectory: true)
        let fm = FileManager.default

        do {
            if !fm.fileExists(atPath: preDeleteDir.path) {
                try fm.createDirectory(at: preDeleteDir, withIntermediateDirectories: true)
            }
        } catch {
            // Sandbox may block write if user selected individual files instead of folder.
            // Request explicit folder access via NSOpenPanel.
            let folderPanel = NSOpenPanel()
            folderPanel.canChooseDirectories = true
            folderPanel.canChooseFiles = false
            folderPanel.allowsMultipleSelection = false
            folderPanel.directoryURL = rootURL
            folderPanel.message = "Grant write access to the session folder for PRE-DELETE"
            folderPanel.prompt = "Grant Access"

            guard folderPanel.runModal() == .OK, let grantedURL = folderPanel.url else {
                statusMessage = "PRE-DELETE cancelled — folder access not granted"
                return
            }

            // Start security-scoped access to the granted folder
            let accessed = grantedURL.startAccessingSecurityScopedResource()
            if accessed {
                // Release previous if any, store new
                if let prev = accessedURL {
                    prev.stopAccessingSecurityScopedResource()
                }
                accessedURL = grantedURL
                sessionRootURL = grantedURL
            }

            // Retry folder creation with new access
            do {
                let retryDir = grantedURL.appendingPathComponent("PRE-DELETE", isDirectory: true)
                if !fm.fileExists(atPath: retryDir.path) {
                    try fm.createDirectory(at: retryDir, withIntermediateDirectories: true)
                }
            } catch {
                statusMessage = "Error creating PRE-DELETE folder: \(error.localizedDescription)"
                return
            }
        }

        // Remember the first marked index for re-selection later
        let firstMarkedIndex = images.firstIndex(where: { $0.isMarkedForDeletion }) ?? selectedIndex

        // Use current sessionRootURL (may have been updated by folder access grant)
        let activePreDeleteDir = sessionRootURL!.appendingPathComponent("PRE-DELETE", isDirectory: true)

        // Move files and build undo entries
        var movedCount = 0
        var failedCount = 0
        var undoEntries: [PreDeleteUndoEntry] = []

        for entry in markedImages {
            let destURL = activePreDeleteDir.appendingPathComponent(entry.filename)
            do {
                // Handle name collision: add numeric suffix
                var finalDest = destURL
                var suffix = 1
                while fm.fileExists(atPath: finalDest.path) {
                    let name = entry.url.deletingPathExtension().lastPathComponent
                    let ext = entry.url.pathExtension
                    finalDest = activePreDeleteDir.appendingPathComponent("\(name)_\(suffix).\(ext)")
                    suffix += 1
                }
                let originalIndex = images.firstIndex(where: { $0.url == entry.url }) ?? 0
                try fm.moveItem(at: entry.url, to: finalDest)
                undoEntries.append(PreDeleteUndoEntry(
                    originalURL: entry.url,
                    preDeleteURL: finalDest,
                    entry: entry,
                    originalIndex: originalIndex
                ))
                movedCount += 1
            } catch {
                failedCount += 1
            }
        }

        // Push to undo stack
        preDeleteUndoStack.append(undoEntries)

        // Remove moved images from the list
        let markedURLs = Set(markedImages.map { $0.url })
        images.removeAll { markedURLs.contains($0.url) }

        // Select a single image near where the deleted ones were
        if !images.isEmpty {
            let newIndex = min(firstMarkedIndex, images.count - 1)
            selectImage(at: max(0, newIndex))
        } else {
            selectedIndex = -1
            currentDecodedImage = nil
        }

        needsTableRefresh = true

        // Update session overview with remaining images
        sessionOverviewModel.updateStats(from: images)

        if failedCount > 0 {
            statusMessage = "Moved \(movedCount) files to PRE-DELETE (\(failedCount) failed) — Undo available"
        } else {
            statusMessage = "Moved \(movedCount) files to PRE-DELETE — Undo available"
        }
    }

    // Undo the last pre-delete operation: move files back and restore entries
    // Can be called repeatedly to undo all previous operations
    func undoPreDelete() {
        guard let lastUndo = preDeleteUndoStack.popLast() else {
            statusMessage = "Nothing to undo"
            return
        }

        let fm = FileManager.default
        var restoredCount = 0

        // Sort by original index so they get re-inserted in the right order
        let sorted = lastUndo.sorted { $0.originalIndex < $1.originalIndex }

        for undo in sorted {
            do {
                try fm.moveItem(at: undo.preDeleteURL, to: undo.originalURL)
                // Re-insert entry at original position (clamped to current size)
                var restored = undo.entry
                restored.isMarkedForDeletion = false
                let insertAt = min(undo.originalIndex, images.count)
                images.insert(restored, at: insertAt)
                restoredCount += 1
            } catch {
                // File may have been manually moved/deleted — skip
            }
        }

        needsTableRefresh = true

        // Select the first restored image
        if let first = sorted.first {
            let idx = min(first.originalIndex, images.count - 1)
            selectImage(at: max(0, idx))
        }

        sessionOverviewModel.updateStats(from: images)
        let remaining = preDeleteUndoStack.count
        if remaining > 0 {
            statusMessage = "Restored \(restoredCount) files — \(remaining) more undo(s) available"
        } else {
            statusMessage = "Restored \(restoredCount) files — undo stack empty"
        }
    }

    // MARK: - Header Inspector

    func toggleHeaderInspector() {
        showInspector.toggle()
        if showInspector, let image = selectedImage {
            headerInspectorModel.update(for: image.decodingURL, filename: image.filename)
        }
    }

    // MARK: - Lock STF + Apply All

    // Lock STF: freeze exact c0/mb params from current image for all images
    // (compare exposure/brightness across the session)
    @Published var isSTFLocked: Bool = false

    func toggleLockSTF() {
        guard let renderer = renderer else { return }
        isSTFLocked.toggle()
        if isSTFLocked {
            renderer.lockSTF()
            statusMessage = "STF Locked — same stretch for all images"
        } else {
            renderer.unlockSTF()
            statusMessage = "STF Unlocked — auto stretch per image"
        }
        // Re-cache with locked/unlocked params if Apply All is active
        if applyAllEnabled {
            triggerApplyAll()
        }
        // Redraw current image
        if let mtkView = findMTKView() { mtkView.needsDisplay = true }
    }

    // Apply All toggle: when ON, bakes current settings into all cached previews.
    // When settings change while active, auto re-caches.
    @Published var applyAllEnabled: Bool = false

    // Tracks what settings are baked into cached previews
    private(set) var appliedStretch: Float = STFCalculator.defaultTargetBackground
    private(set) var appliedSharpening: Float = 0.0
    private(set) var appliedContrast: Float = 0.0
    private(set) var appliedDarkLevel: Float = 0.0
    private(set) var appliedLocked: Bool = false  // Were locked STF params baked in?

    // Whether current slider settings match what's baked into the cache
    var cacheMatchesCurrentSettings: Bool {
        abs(stretchStrength - appliedStretch) < 0.001
        && abs(sharpening - appliedSharpening) < 0.001
        && abs(contrast - appliedContrast) < 0.001
        && abs(darkLevel - appliedDarkLevel) < 0.001
        && isSTFLocked == appliedLocked
    }

    func toggleApplyAll() {
        applyAllEnabled.toggle()
        if applyAllEnabled {
            triggerApplyAll()
        } else {
            // Revert to default auto-cached previews
            appliedStretch = STFCalculator.defaultTargetBackground
            appliedSharpening = 0.0
            appliedContrast = 0.0
            appliedDarkLevel = 0.0
            appliedLocked = false
            prefetchCache?.invalidateAll()
            statusMessage = "Reverting to default caching..."
            startFullPrefetch()
        }
    }

    // Internal: run the apply-all re-cache with current settings
    private func triggerApplyAll() {
        appliedStretch = stretchStrength
        appliedSharpening = sharpening
        appliedContrast = contrast
        appliedDarkLevel = darkLevel
        appliedLocked = isSTFLocked
        prefetchCache?.invalidateAll()
        statusMessage = "Applying settings to all images..."
        startFullPrefetch()
    }

    // Reset all visual sliders to defaults
    func resetSlidersToDefaults() {
        stretchStrength = STFCalculator.defaultTargetBackground
        sharpening = 0.0
        contrast = 0.0
        darkLevel = 0.0
        isSTFLocked = false
        renderer?.unlockSTF()

        // Update live display
        updatePostProcessParams()

        // Re-cache if Apply All is active, or if applied settings were non-default
        if applyAllEnabled || !cacheMatchesCurrentSettings {
            applyAllEnabled = false
            appliedStretch = stretchStrength
            appliedSharpening = 0.0
            appliedContrast = 0.0
            appliedDarkLevel = 0.0
            appliedLocked = false
            prefetchCache?.invalidateAll()
            statusMessage = "Resetting — re-caching with defaults..."
            startFullPrefetch()
        }

        // Re-render current image with default stretch
        if let image = currentDecodedImage, let mtkView = findMTKView(), let renderer = renderer {
            let stfParams = STFCalculator.calculate(from: image)
            renderer.setSTFParams(stfParams)
            renderer.setImage(image, in: mtkView)
        }

        statusMessage = "Settings reset to defaults"
    }

    // Give the NSTableView first responder status after a short delay
    // (table needs time to populate after loading files)
    func focusTableAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = NSApp.keyWindow else { return }
            func findTable(in view: NSView?) -> NSTableView? {
                guard let view = view else { return nil }
                if let tv = view as? NSTableView { return tv }
                for sub in view.subviews {
                    if let found = findTable(in: sub) { return found }
                }
                return nil
            }
            if let tableView = findTable(in: window.contentView) {
                window.makeFirstResponder(tableView)
            }
        }
    }

    private func findMTKView() -> MTKView? {
        guard let window = NSApp.keyWindow else { return nil }
        return findMTKViewIn(view: window.contentView)
    }

    private func findMTKViewIn(view: NSView?) -> MTKView? {
        guard let view = view else { return nil }
        if let mtkView = view as? MTKView { return mtkView }
        for subview in view.subviews {
            if let found = findMTKViewIn(view: subview) { return found }
        }
        return nil
    }

    // MARK: - Multi-Level Sorting

    func applySortDescriptors(_ descriptors: [NSSortDescriptor]) {
        currentSortDescriptors = descriptors

        let selectedURL = selectedImage?.url

        images.sort { a, b in
            for descriptor in descriptors {
                guard let key = descriptor.key else { continue }
                let ascending = descriptor.ascending

                // For numeric columns: compare numerically, push nil values to the end
                if ColumnDefinition.isNumericColumn(key) {
                    let numA = ColumnDefinition.numericValue(for: key, from: a)
                    let numB = ColumnDefinition.numericValue(for: key, from: b)

                    switch (numA, numB) {
                    case (.some(let nA), .some(let nB)):
                        if nA != nB { return ascending ? nA < nB : nA > nB }
                    case (.some, .none):
                        return true  // a has value, b doesn't → a comes first
                    case (.none, .some):
                        return false // b has value, a doesn't → b comes first
                    case (.none, .none):
                        break // both nil, move to next sort key
                    }
                    continue
                }

                // For text columns: compare as strings
                let valA = ColumnDefinition.value(for: key, from: a)
                let valB = ColumnDefinition.value(for: key, from: b)

                if valA != valB {
                    return ascending ? valA < valB : valA > valB
                }
            }
            return false
        }

        if let url = selectedURL,
           let newIndex = images.firstIndex(where: { $0.url == url }) {
            selectedIndex = newIndex
        }

        needsTableRefresh = true

        let sortInfo = descriptors.map { d in
            "\(d.key ?? "?") \(d.ascending ? "↑" : "↓")"
        }.joined(separator: " > ")
        statusMessage = "Sorted: \(sortInfo)"
    }

    // Sort by the first 3 visible columns (excluding the marked checkbox).
    // Moving a column to position 1 makes it the primary sort key,
    // position 2 = secondary, position 3 = tertiary.
    // Numeric columns default to descending (highest first),
    // text columns default to ascending (A-Z).
    func applySortByColumnOrder(_ columnIdentifiers: [String]) {
        let sortColumns = Array(
            columnIdentifiers
                .filter { $0 != "marked" }
                .prefix(3)
        )
        let descriptors = sortColumns.map { colId in
            let ascending = !ColumnDefinition.isNumericColumn(colId)
            return NSSortDescriptor(key: colId, ascending: ascending)
        }

        guard !descriptors.isEmpty else { return }
        applySortDescriptors(descriptors)
    }

    // MARK: - Image Display

    private var currentDecodeTask: Task<Void, Never>?

    // Display the currently selected image: use cached preview if available,
    // otherwise fall back to on-demand full-res decode + compute.
    private func displayCurrentImage() {
        guard let image = selectedImage, let device = device else { return }

        currentDecodeTask?.cancel()

        // Update header inspector model (panel updates reactively via SwiftUI)
        headerInspectorModel.update(for: image.decodingURL, filename: image.filename)

        // Fast path: use pre-stretched cached preview (instant, zero compute)
        // Works when current slider settings match what's baked into the cache.
        // The cache has stretch + post-process baked in, so no GPU work needed.
        if cacheMatchesCurrentSettings, let preview = prefetchCache?.getPreview(for: image.url) {
            currentDecodedImage = nil  // No raw data needed for display
            if selectedIndex >= 0 && selectedIndex < images.count {
                images[selectedIndex].width = preview.originalWidth
                images[selectedIndex].height = preview.originalHeight
                images[selectedIndex].channelCount = preview.channelCount
            }

            // Tell renderer to display the cached texture directly
            // Disable live post-process since it's already baked into the preview
            if let mtkView = findMTKView(), let renderer = renderer {
                renderer.setPostProcessParams(sharpening: 0, contrast: 0, darkLevel: 0)
                renderer.setPreview(preview, in: mtkView)
            }

            statusMessage = isCaching
                ? "Pre-caching \(cachingCount)/\(cachingTotal)... | \(preview.originalWidth)x\(preview.originalHeight)"
                : "\(preview.originalWidth)x\(preview.originalHeight) \(preview.channelCount == 1 ? "mono" : "RGB")"
            return
        }

        // Slow path: decode on demand (image not yet cached or settings don't match cache)
        statusMessage = "Loading \(image.filename)..."
        let targetURL = image.url
        let decodeURL = image.decodingURL
        // Only pass Bayer pattern when debayer is enabled — otherwise show as mono
        let bayerPattern = debayerEnabled ? image.bayerPattern : nil
        let currentStretch = stretchStrength
        let currentSharp = sharpening
        let currentContrast = contrast
        let currentDark = darkLevel

        currentDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            let result = ImageDecoder.decode(url: decodeURL, device: device)

            await MainActor.run {
                guard let self = self, !Task.isCancelled else { return }
                guard self.selectedImage?.url == targetURL else { return }

                switch result {
                case .success(let decoded):
                    self.currentDecodedImage = decoded
                    if self.selectedIndex >= 0 && self.selectedIndex < self.images.count {
                        self.images[self.selectedIndex].width = decoded.width
                        self.images[self.selectedIndex].height = decoded.height
                        self.images[self.selectedIndex].channelCount = decoded.channelCount
                    }

                    // Debug: log decoder output to understand color behavior
                    // Render: setImage handles debayer + STF calculation internally
                    // (including locked STF and custom targetBackground for correct RGB stretch)
                    if let mtkView = self.findMTKView(), let renderer = self.renderer {
                        renderer.setImage(decoded, in: mtkView,
                                          bayerPattern: bayerPattern,
                                          targetBackground: currentStretch)
                        renderer.setPostProcessParams(
                            sharpening: currentSharp, contrast: currentContrast, darkLevel: currentDark)
                        mtkView.needsDisplay = true
                    }

                    // Status: dimensions + channel info + debayer state (for OSC images)
                    let rawCh = decoded.channelCount == 1 ? "mono" : "RGB\(decoded.channelCount)ch"
                    let debayerInfo: String
                    if let pat = self.selectedImage?.bayerPattern {
                        debayerInfo = self.debayerEnabled ? " | debayer ON (\(pat))" : " | debayer OFF (\(pat))"
                    } else {
                        debayerInfo = ""
                    }
                    self.statusMessage = "\(decoded.width)x\(decoded.height) \(rawCh)\(debayerInfo)"

                case .failure(let error):
                    self.currentDecodedImage = nil
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        if seconds >= 3600 {
            return String(format: "%.1fh", seconds / 3600)
        } else if seconds >= 60 {
            return String(format: "%.0fm", seconds / 60)
        } else {
            return String(format: "%.0fs", seconds)
        }
    }
}
