// v3.3.0
import Foundation
import SwiftUI
import Metal
import MetalKit
import UniformTypeIdentifiers
import StoreKit

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

    // Auto Meridian: rotate images 180° to normalize orientation across meridian flips.
    // Uses PIERSIDE header (EAST/WEST) + OBJCTRA/OBJCTDEC for same-target matching.
    // First image's pier side = reference. Opposite side with same coordinates → rotated.
    @Published var autoMeridianEnabled: Bool = true  // Default ON
    // True when session has images with PIERSIDE on both sides (meridian flip detected)
    @Published var hasMeridianFlip: Bool = false
    // Reference pier side determined from the first image with PIERSIDE data
    private var referencePierSide: String?
    // Reference coordinates (RA/DEC) for pier side matching
    private var referenceCoords: (ra: String, dec: String)?

    // Prefetch progress (0.0 to 1.0)
    @Published var cacheProgress: Double = 0
    @Published var cachingCount: Int = 0
    @Published var cachingTotal: Int = 0
    @Published var isCaching: Bool = false

    // Triggers a table reload in updateNSView (for checkbox/mark changes)
    @Published var needsTableRefresh: Bool = false

    // Hide marked images: when true, marked images are invisible in the list
    @Published var hideMarked: Bool = false

    // Show only marked: inverted view — when true, only marked images are shown
    // Mutually exclusive with hideMarked (Shift+H toggles this)
    @Published var showOnlyMarked: Bool = false

    // Skip marked images during arrow-key navigation
    @Published var skipMarked: Bool = false

    // Spotlight-style search: filters file list in real time
    // Supports plain text (searches all columns) or "column:value" syntax (e.g. "filter:Ha", "fwhm:>4")
    @Published var filterText: String = ""

    // Side panel visibility (integrated into main window)
    @Published var showInspector: Bool = false
    @Published var showSessionOverview: Bool = false

    // Quick Stack: triangle-match alignment + mean combine for visual impression
    @Published var showQuickStack: Bool = false
    var quickStackEngine: QuickStackEngine?
    // Quick Stack V2: optimized pipeline with GPU warp, hash-based matching, parallel star detection
    @Published var showQuickStackV2: Bool = false
    var quickStackEngineV2: QuickStackEngineV2?
    // Selected row indices from the file list (for multi-select operations like stacking)
    var selectedTableIndices: IndexSet = IndexSet()

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

    // Benchmark timing for session loading performance (zero overhead — just Date() stamps)
    let benchmarkStats = BenchmarkStats()

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

    // Total memory used by cached preview textures
    var cacheMemoryBytes: Int64 {
        prefetchCache?.cacheMemoryBytes ?? 0
    }

    // Total raw file size of all loaded images
    var totalRawFileSize: Int64 {
        images.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
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

    // Visible images: filtered by hide/show marked state + column filter
    var visibleImages: [ImageEntry] {
        var result = images
        if hideMarked {
            result = result.filter { !$0.isMarkedForDeletion }
        } else if showOnlyMarked {
            result = result.filter { $0.isMarkedForDeletion }
        }
        if !filterText.isEmpty {
            result = result.filter { matchesFilter($0) }
        }
        return result
    }

    // Column name aliases for "column:value" syntax (case-insensitive)
    private static let columnAliases: [String: String] = [
        "filter": "filter", "fil": "filter",
        "object": "target", "obj": "target", "target": "target",
        "type": "frameType", "frametype": "frameType",
        "camera": "camera", "cam": "camera",
        "filename": "filename", "file": "filename", "name": "filename",
        "subfolder": "subfolder", "folder": "subfolder", "sub": "subfolder",
        "date": "date", "time": "time",
        "exp": "exposure", "exposure": "exposure",
        "fwhm": "fwhm", "hfr": "hfr",
        "stars": "starCount", "starcount": "starCount",
        "temp": "sensorTemp", "sensortemp": "sensorTemp",
        "gain": "gain", "offset": "offset",
        "amb": "ambientTemp", "ambtemp": "ambientTemp", "ambienttemp": "ambientTemp",
        "foc": "focuserTemp", "foctemp": "focuserTemp", "focusertemp": "focuserTemp",
        "telescope": "telescope", "tel": "telescope",
        "binning": "binning", "bin": "binning",
    ]

    // Check if an image entry matches the current filter criteria.
    // Supports plain text (all columns) or "column:value" syntax.
    private func matchesFilter(_ entry: ImageEntry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }

        // Check for "column:value" syntax (e.g. "filter:Ha", "fwhm:>4.0")
        if let colonIdx = query.firstIndex(of: ":") {
            let prefix = String(query[query.startIndex..<colonIdx]).lowercased()
            let value = String(query[query.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            if let columnId = Self.columnAliases[prefix], !value.isEmpty {
                if ColumnDefinition.isNumericColumn(columnId) {
                    return matchesNumericFilter(entry, column: columnId, query: value)
                } else {
                    return ColumnDefinition.value(for: columnId, from: entry)
                        .lowercased().contains(value.lowercased())
                }
            }
        }

        // Plain text: search across all displayable columns
        let lowerQuery = query.lowercased()
        let searchColumns = ["filename", "target", "filter", "camera", "frameType",
                             "subfolder", "telescope", "date", "time", "binning",
                             "exposure", "fwhm", "hfr", "starCount", "gain",
                             "sensorTemp", "ambientTemp", "focuserTemp"]
        return searchColumns.contains { col in
            ColumnDefinition.value(for: col, from: entry).lowercased().contains(lowerQuery)
        }
    }

    // Parse numeric filter: ">4.0", "<2.5", ">=300", "<=0.5", "=120", or plain "4.0"
    private func matchesNumericFilter(_ entry: ImageEntry, column: String, query: String) -> Bool {
        guard let entryValue = ColumnDefinition.numericValue(for: column, from: entry) else {
            return false  // No value for this column → doesn't match
        }

        var op = "="
        var numStr = query

        if query.hasPrefix(">=") {
            op = ">="
            numStr = String(query.dropFirst(2))
        } else if query.hasPrefix("<=") {
            op = "<="
            numStr = String(query.dropFirst(2))
        } else if query.hasPrefix(">") {
            op = ">"
            numStr = String(query.dropFirst(1))
        } else if query.hasPrefix("<") {
            op = "<"
            numStr = String(query.dropFirst(1))
        } else if query.hasPrefix("=") {
            op = "="
            numStr = String(query.dropFirst(1))
        }

        guard let threshold = Double(numStr.trimmingCharacters(in: .whitespaces)) else {
            // Not a valid number — fall back to string contains on formatted value
            return ColumnDefinition.value(for: column, from: entry)
                .lowercased().contains(query.lowercased())
        }

        switch op {
        case ">":  return entryValue > threshold
        case "<":  return entryValue < threshold
        case ">=": return entryValue >= threshold
        case "<=": return entryValue <= threshold
        default:
            // Approximate equality for floating point comparison
            return Swift.abs(entryValue - threshold) < 0.001
        }
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
        if let v = AppSettings.loadBool(for: .autoMeridian) { autoMeridianEnabled = v }

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

        benchmarkStats.markSessionStart()
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
                self.benchmarkStats.markScanComplete(fileCount: entries.count, totalBytes: entries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
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
        benchmarkStats.markSessionStart()
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
                self.benchmarkStats.markScanComplete(fileCount: entries.count, totalBytes: entries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
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
                    // Check memory budget — if over budget, shows alert and calls back
                    self.checkMemoryBudgetAndCache(for: entries)
                }
                // Give table focus so keyboard navigation works immediately
                self.focusTableAfterDelay()

                // Ask for App Store review after 5th session (Apple limits to 3x/year automatically)
                self.checkForReviewPrompt()

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

    // Estimate cache memory needed and warn user if it exceeds available RAM.
    // If within budget, starts caching immediately. If over budget, shows a non-blocking
    // sheet alert and starts/skips caching based on user choice.
    private func checkMemoryBudgetAndCache(for entries: [ImageEntry]) {
        let totalRawBytes = entries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        let physicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        // Safe budget: 70% of physical RAM for cache (leaves 30% for OS, app, and decode buffers)
        let safeBudget = Int64(Double(physicalMemory) * 0.7)

        // Always enrich headers regardless of cache decision
        enrichWithHeaders()

        // If estimated cache fits comfortably, proceed without warning
        if totalRawBytes <= safeBudget {
            applyAllEnabled = true
            triggerApplyAll()
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
                guard let self = self else { return }
                if response == .alertFirstButtonReturn {
                    self.applyAllEnabled = true
                    self.triggerApplyAll()
                } else {
                    self.statusMessage = "Caching skipped — use arrow keys for on-demand viewing"
                    self.applyAllEnabled = false
                }
            }
        } else {
            // Fallback: app-modal (no window available yet)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                applyAllEnabled = true
                triggerApplyAll()
            } else {
                statusMessage = "Caching skipped — use arrow keys for on-demand viewing"
                applyAllEnabled = false
            }
        }
    }

    // Prevent App Nap from throttling caching when app is in background
    private var appNapAssertion: NSObjectProtocol?

    // Start pre-decoding + stretching ALL images (skips already-cached)
    private func startFullPrefetch() {
        guard let prefetchCache = prefetchCache else { return }

        benchmarkStats.markCachingStart()
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
            postProcessParams: ppParams,
            onProgress: { [weak self] completed, total in
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
                    self.statusMessage = "instant navigation ready"
                    self.benchmarkStats.markCachingEnd()
                    // Release App Nap assertion when caching completes
                    self.appNapAssertion = nil
                    // Update session overview with noise stats now that all images are measured
                    self.sessionOverviewModel.updateStats(from: self.images)
                    // Recompute quality scores now that noiseMAD is populated for all images
                    self.recomputeQualityScores()
                }
            },
            onNoiseStats: { [weak self] url, stats in
                guard let self = self else { return }
                // Store noise stats in the corresponding ImageEntry
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    self.images[idx].noiseMedian = stats.median
                    self.images[idx].noiseMAD = stats.normalizedMAD
                }
            },
            onStarMetrics: { [weak self] url, metrics in
                guard let self = self else { return }
                // Store computed star metrics (always computed for per-group source consistency)
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    self.images[idx].computedHFR = metrics.medianHFR
                    self.images[idx].computedFWHM = metrics.medianFWHM
                    self.images[idx].computedStarCount = metrics.measuredStarCount
                }
            }
        )
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
        statusMessage = "Caching paused"
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
        statusMessage = "ready"

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
        benchmarkStats.markHeaderEnrichStart()
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

                    // Pier side for meridian flip detection
                    // Case-insensitive key lookup (XISF may store differently than FITS)
                    // FITS values may be wrapped in single quotes (e.g. "'East'"), strip them
                    let pierVal = headers["PIERSIDE"] ?? headers.first(where: { $0.key.uppercased() == "PIERSIDE" })?.value
                    if let pier = pierVal, !pier.isEmpty {
                        let cleaned = pier.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "'", with: "")
                            .trimmingCharacters(in: .whitespaces)
                            .uppercased()
                        if cleaned == "EAST" || cleaned == "WEST" {
                            self.images[index].pierSide = cleaned
                        }
                    }

                    // Rotator angle for meridian flip fallback (ASIAIR/AM5 mounts)
                    let rotVal = headers["ROTATOR"] ?? headers.first(where: { $0.key.uppercased() == "ROTATOR" })?.value
                    if let rot = rotVal, let val = Double(rot) {
                        self.images[index].rotatorAngle = val
                    }

                    // Object coordinates for meridian flip matching
                    // Case-insensitive key lookup, strip FITS single-quote wrappers
                    let raVal = headers["OBJCTRA"] ?? headers.first(where: { $0.key.uppercased() == "OBJCTRA" })?.value
                    if let ra = raVal, !ra.isEmpty {
                        self.images[index].objctRA = ra.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "'", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    }
                    let decVal = headers["OBJCTDEC"] ?? headers.first(where: { $0.key.uppercased() == "OBJCTDEC" })?.value
                    if let dec = decVal, !dec.isEmpty {
                        self.images[index].objctDec = dec.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "'", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    }

                    if self.images[index].bayerPattern != nil {
                        foundOSC = true
                    }
                }

                self.needsTableRefresh = true
                self.loadingPhase = .none
                self.benchmarkStats.markHeaderEnrichEnd()
                self.sessionOverviewModel.updateStats(from: self.images)
                self.hasOSCImages = foundOSC
                // Compute relative quality scores now that all header metadata is available
                self.recomputeQualityScores()
                self.detectMeridianFlip()
                // Update rotation for current image now that pier side data is available
                self.updateMeridianRotation()

                // If debayer is enabled and OSC images were found, previews were cached
                // without bayerPattern (headers weren't available yet). Re-cache with debayer.
                if foundOSC && self.debayerEnabled {
                    self.prefetchCache?.invalidateAll()
                    self.startFullPrefetch()
                    // Also re-display current image with debayer applied
                    self.displayCurrentImage()
                }
            }
        }
    }

    // MARK: - Quality Estimation

    // Compute or recompute quality tiers for all images using QualityEstimator.
    // Called after header enrichment completes (FWHM, HFR, StarCount are now populated).
    // Also call this after adding a new folder to the session (new images may change group stats).
    func recomputeQualityScores() {
        let scores = QualityEstimator.computeScores(for: images)
        for index in images.indices {
            images[index].qualityTier = scores[images[index].url]
        }
        // Notify table that quality column cells need redrawing
        needsTableRefresh = true

        let scored = scores.count
        let total  = images.count
        if scored > 0 {
            statusMessage = "Quality scored: \(scored)/\(total) images in \(countGroups(scores)) group(s)"
        }
    }

    /// Count distinct groups that produced at least one score
    private func countGroups(_ scores: [URL: QualityTier]) -> Int {
        // Use a set of GroupKey-equivalent tuples built from scored images
        var groups = Set<String>()
        for entry in images where scores[entry.url] != nil {
            let filter = (entry.filter   ?? "").uppercased()
            let object = entry.target    ?? ""
            let night  = String((entry.date ?? "").prefix(10))
            let exp    = String(entry.exposure.map { Int($0.rounded()) } ?? 0)
            groups.insert("\(filter)|\(object)|\(night)|\(exp)")
        }
        return groups.count
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

    // MARK: - Auto Meridian

    // Toggle auto meridian rotation for normalized orientation across meridian flips
    func toggleAutoMeridian() {
        autoMeridianEnabled.toggle()
        AppSettings.saveBool(autoMeridianEnabled, for: .autoMeridian)
        statusMessage = autoMeridianEnabled
            ? "Auto Meridian ON — normalizing pier side orientation"
            : "Auto Meridian OFF"
        // Update rotation for current image and redraw
        updateMeridianRotation()
    }

    // Determine whether the current image needs 180° rotation for meridian flip correction.
    // Logic: reference = first image's pier side. Images on the opposite side with matching
    // coordinates (same target) get rotated. Coordinate matching uses OBJCTRA/OBJCTDEC with
    // tolerance (~1 arcmin) — more reliable than target name matching.
    func shouldRotateForMeridian(_ entry: ImageEntry) -> Bool {
        guard autoMeridianEnabled,
              let refSide = referencePierSide,
              let entrySide = entry.pierSide,
              entrySide.uppercased() != refSide.uppercased() else {
            return false
        }

        // Check if same target by coordinates (within ~1 arcmin tolerance)
        if let refCoords = referenceCoords,
           let entryRA = entry.objctRA,
           let entryDec = entry.objctDec {
            return coordinatesMatch(
                ra1: refCoords.ra, dec1: refCoords.dec,
                ra2: entryRA, dec2: entryDec
            )
        }

        // Fallback: match by target name if coordinates not available
        if let refTarget = images.first(where: { $0.pierSide == referencePierSide })?.target,
           let entryTarget = entry.target {
            return refTarget.lowercased() == entryTarget.lowercased()
        }

        return false
    }

    // Update rotation state for the currently displayed image
    private func updateMeridianRotation() {
        guard let entry = selectedImage else {
            renderer?.rotate180 = false
            if let mtkView = findMTKView() { mtkView.needsDisplay = true }
            return
        }
        let shouldRotate = shouldRotateForMeridian(entry)
        renderer?.rotate180 = shouldRotate
        if let mtkView = findMTKView() { mtkView.needsDisplay = true }
    }

    // Detect meridian flip in session after headers are loaded.
    // Primary: PIERSIDE header (EAST/WEST). Fallback: ROTATOR angle (~180° change).
    func detectMeridianFlip() {
        let withPierSide = images.filter { $0.pierSide != nil }

        if !withPierSide.isEmpty {
            // Primary detection via PIERSIDE header
            referencePierSide = withPierSide.first?.pierSide
            if let first = withPierSide.first {
                if let ra = first.objctRA, let dec = first.objctDec {
                    referenceCoords = (ra: ra, dec: dec)
                }
            }

            let sides = Set(withPierSide.compactMap { $0.pierSide })
            hasMeridianFlip = sides.count > 1

            let eastCount = withPierSide.filter { $0.pierSide == "EAST" }.count
            let westCount = withPierSide.filter { $0.pierSide == "WEST" }.count
            if hasMeridianFlip {
                print("[Meridian] Flip detected via PIERSIDE: \(eastCount) EAST, \(westCount) WEST")
            } else {
                print("[Meridian] All images on same side: \(referencePierSide ?? "?") (\(withPierSide.count) images)")
            }
            return
        }

        // Fallback: detect meridian flip from ROTATOR angle change (~180°)
        // ASIAIR/AM5 mounts write ROTATOR but not PIERSIDE.
        // After a meridian flip, rotator angle changes by ~180° (±20° tolerance).
        let withRotator = images.filter { $0.rotatorAngle != nil }
        guard withRotator.count >= 2 else {
            hasMeridianFlip = false
            referencePierSide = nil
            referenceCoords = nil
            return
        }

        let refAngle = withRotator.first!.rotatorAngle!
        if let first = withRotator.first {
            if let ra = first.objctRA, let dec = first.objctDec {
                referenceCoords = (ra: ra, dec: dec)
            }
        }

        // Classify images into two groups based on rotator angle:
        // "same side" = within 30° of reference, "flipped" = within 30° of reference+180°
        var sameCount = 0
        var flippedCount = 0
        let flipThreshold: Double = 30.0  // degrees tolerance

        for img in withRotator {
            let angle = img.rotatorAngle!
            let diff = angleDifference(angle, refAngle)
            if diff <= flipThreshold {
                sameCount += 1
            } else if Swift.abs(diff - 180.0) <= flipThreshold {
                flippedCount += 1
            }
            // Anything else: ambiguous, skip
        }

        hasMeridianFlip = sameCount > 0 && flippedCount > 0

        if hasMeridianFlip {
            // Infer pier side from rotator angle groups and set on images
            let flippedAngle = normalizeAngle(refAngle + 180.0)
            referencePierSide = "EAST"  // Arbitrary assignment for first group
            for i in images.indices {
                guard let angle = images[i].rotatorAngle else { continue }
                let diff = angleDifference(angle, refAngle)
                if diff <= flipThreshold {
                    images[i].pierSide = "EAST"
                } else if Swift.abs(diff - 180.0) <= flipThreshold {
                    images[i].pierSide = "WEST"
                }
            }

            let eastCount = images.filter { $0.pierSide == "EAST" }.count
            let westCount = images.filter { $0.pierSide == "WEST" }.count
            print("[Meridian] Flip detected via ROTATOR angle: \(eastCount) EAST (ref ~\(String(format: "%.0f", refAngle))°), \(westCount) WEST (~\(String(format: "%.0f", flippedAngle))°)")
        } else {
            referencePierSide = nil
            print("[Meridian] No flip detected via ROTATOR (\(withRotator.count) images, ref angle ~\(String(format: "%.0f", refAngle))°)")
        }
    }

    // Compute absolute angle difference in [0, 180] range
    private func angleDifference(_ a: Double, _ b: Double) -> Double {
        var diff = Swift.abs(a - b).truncatingRemainder(dividingBy: 360.0)
        if diff > 180.0 { diff = 360.0 - diff }
        return diff
    }

    // Normalize angle to [0, 360) range
    private func normalizeAngle(_ a: Double) -> Double {
        var result = a.truncatingRemainder(dividingBy: 360.0)
        if result < 0 { result += 360.0 }
        return result
    }

    // Compare RA/DEC coordinate strings with generous tolerance.
    // Mount pointing can drift across meridian flips due to plate-solve refinement,
    // polar alignment error, or centering differences. 10 arcmin (~0.17°) is safe —
    // wide enough for real-world drift but won't confuse distinct nearby targets.
    // Supports formats: "HH MM SS.ss" (space-separated) and decimal degrees.
    private func coordinatesMatch(ra1: String, dec1: String, ra2: String, dec2: String) -> Bool {
        let ra1deg = parseRA(ra1)
        let ra2deg = parseRA(ra2)
        let dec1deg = parseDec(dec1)
        let dec2deg = parseDec(dec2)

        guard let r1 = ra1deg, let r2 = ra2deg, let d1 = dec1deg, let d2 = dec2deg else {
            // Can't parse — fall back to case-insensitive string match
            return ra1.lowercased() == ra2.lowercased() && dec1.lowercased() == dec2.lowercased()
        }

        // ~2 arcmin tolerance (2/60 = 0.033 degrees)
        let tolerance: Double = 2.0 / 60.0
        let raDiff: Double = Swift.abs(r1 - r2)
        let decDiff: Double = Swift.abs(d1 - d2)
        return raDiff < tolerance && decDiff < tolerance
    }

    // Parse RA string to degrees. Supports "HH MM SS.ss" or decimal degrees.
    private func parseRA(_ ra: String) -> Double? {
        let parts = ra.split(separator: " ").compactMap { Double($0) }
        if parts.count >= 3 {
            // HH MM SS → degrees (15° per hour)
            return (parts[0] + parts[1] / 60.0 + parts[2] / 3600.0) * 15.0
        }
        if parts.count == 1 { return parts[0] }
        return nil
    }

    // Parse Dec string to degrees. Supports "+DD MM SS.ss" or decimal degrees.
    private func parseDec(_ dec: String) -> Double? {
        let trimmed = dec.trimmingCharacters(in: .whitespaces)
        let isNegative = trimmed.hasPrefix("-")
        let cleaned = trimmed.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
        let parts = cleaned.split(separator: " ").compactMap { Double($0) }
        if parts.count >= 3 {
            let deg = parts[0] + parts[1] / 60.0 + parts[2] / 3600.0
            return isNegative ? -deg : deg
        }
        if parts.count == 1 {
            return isNegative ? -parts[0] : parts[0]
        }
        return nil
    }

    // MARK: - Zoom

    // Zoom in by 20% (multiplicative so each step feels equal)
    func zoomIn() {
        guard let renderer = renderer, let mtkView = findMTKView() else { return }
        renderer.zoomScale *= 1.2
        mtkView.needsDisplay = true
        statusMessage = String(format: "Zoom: %.0f%%", renderer.zoomScale * 100)
    }

    // Zoom out by 20%
    func zoomOut() {
        guard let renderer = renderer, let mtkView = findMTKView() else { return }
        renderer.zoomScale = max(0.1, renderer.zoomScale / 1.2)
        mtkView.needsDisplay = true
        statusMessage = String(format: "Zoom: %.0f%%", renderer.zoomScale * 100)
    }

    // Reset zoom to fit-to-view
    func resetZoom() {
        guard let renderer = renderer, let mtkView = findMTKView() else { return }
        renderer.resetZoom()
        mtkView.needsDisplay = true
        statusMessage = "Zoom: Fit to view"
    }

    // MARK: - Quick Stack

    // Start quick stack with the currently selected images from the file list.
    // Validates that all selected images target the same object (by name or RA/DEC proximity).
    func startQuickStack() {
        let indices = selectedTableIndices

        if indices.count < 3 {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Got it")
            if indices.isEmpty {
                alert.messageText = "No Images Selected"
                alert.informativeText = "Select 3 or more images in the file list first, then hit NormalStacker.\n\nTip: Use Cmd+A to select all, or Shift+Click for a range."
            } else {
                alert.messageText = "Not Enough Images"
                alert.informativeText = "NormalStacker needs at least 3 images to align and stack. You selected \(indices.count).\n\nSelect more images and try again."
            }
            alert.runModal()
            return
        }

        let visible = visibleImages
        let entries = indices.compactMap { idx -> ImageEntry? in
            guard idx >= 0 && idx < visible.count else { return nil }
            return visible[idx]
        }

        guard entries.count >= 3 else { return }

        // Safety check: all images must target the same object (prevents accidental mixed stacking)
        if let mismatch = validateSameTarget(entries) {
            statusMessage = mismatch
            // Show alert dialog so the user can't miss the warning
            let alert = NSAlert()
            alert.messageText = "Cannot NormalStacker"
            alert.informativeText = mismatch
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Create engine if needed
        if quickStackEngine == nil, let device = device {
            quickStackEngine = QuickStackEngine(device: device)
        }

        guard let engine = quickStackEngine else { return }

        showQuickStack = true
        benchmarkStats.markQuickStackStart(frameCount: entries.count)
        engine.startStack(entries: entries, debayerEnabled: debayerEnabled)
    }

    // Quick Stack V2: GPU warp, hash-based matching, parallel star detection
    func startQuickStackV2() {
        let indices = selectedTableIndices

        // No selection or too few images
        if indices.count < 3 {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Got it")

            if indices.isEmpty {
                alert.messageText = "No Images Selected"
                alert.informativeText = "Select 3 or more images in the file list first, then hit LightspeedStacker.\n\nTip: Use Cmd+A to select all, or Shift+Click for a range."
            } else {
                alert.messageText = "Not Enough Images"
                alert.informativeText = "LightspeedStacker needs at least 3 images to align and stack. You selected \(indices.count).\n\nSelect more images and try again."
            }

            alert.runModal()
            return
        }

        let visible = visibleImages
        let entries = indices.compactMap { idx -> ImageEntry? in
            guard idx >= 0 && idx < visible.count else { return nil }
            return visible[idx]
        }

        guard entries.count >= 3 else { return }

        if let mismatch = validateSameTarget(entries) {
            let alert = NSAlert()
            alert.messageText = "Cannot LightspeedStack"
            alert.informativeText = mismatch
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if quickStackEngineV2 == nil, let device = device {
            quickStackEngineV2 = QuickStackEngineV2(device: device)
        }

        guard let engine = quickStackEngineV2 else { return }

        showQuickStackV2 = true
        benchmarkStats.markQuickStackStart(frameCount: entries.count)
        engine.startStack(entries: entries, debayerEnabled: debayerEnabled)
    }

    // Validate all entries target the same sky object. Returns error message if mismatch found, nil if OK.
    // Checks by object name first; falls back to RA/DEC coordinate proximity (1° tolerance).
    private func validateSameTarget(_ entries: [ImageEntry]) -> String? {
        // Collect unique target names (ignoring nil/empty/unknown)
        let targets = Set(entries.compactMap { entry -> String? in
            guard let t = entry.target, !t.isEmpty, t.lowercased() != "unknown" else { return nil }
            return t.trimmingCharacters(in: .whitespaces).lowercased()
        })

        if targets.count > 1 {
            let names = Set(entries.compactMap { entry -> String? in
                guard let t = entry.target, !t.isEmpty, t.lowercased() != "unknown" else { return nil }
                return t.trimmingCharacters(in: .whitespaces)
            })
            return "Cannot stack: mixed targets detected (\(names.sorted().joined(separator: ", "))). Select only images of the same object."
        }

        // If no target names, try RA/DEC proximity check
        if targets.isEmpty {
            let coords = entries.compactMap { entry -> (ra: Double, dec: Double)? in
                guard let raStr = entry.objctRA, let decStr = entry.objctDec,
                      let ra = parseRA(raStr), let dec = parseDec(decStr) else { return nil }
                return (ra, dec)
            }

            if coords.count >= 2 {
                let refRA = coords[0].ra
                let refDec = coords[0].dec
                for coord in coords.dropFirst() {
                    let dRA: Double = Swift.abs(coord.ra - refRA) * cos(refDec * Double.pi / 180.0)
                    let dDec: Double = Swift.abs(coord.dec - refDec)
                    let separation: Double = (dRA * dRA + dDec * dDec).squareRoot()
                    if separation > 1.0 {  // >1° apart = different field
                        return "Cannot stack: images point to different sky regions (>1° apart). Select only images of the same target field."
                    }
                }
            }
        }

        return nil
    }

    // parseRA and parseDec already defined above (Auto Meridian section)

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
        showOnlyMarked = false
        sharpening = 0.0
        contrast = 0.0
        darkLevel = 0.0
        autoMeridianEnabled = true  // Default ON
        needsTableRefresh = true
        updatePostProcessParams()
        updateMeridianRotation()
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

    // MARK: - Search Filter

    // Mark all currently filtered/visible images for deletion
    func markFilteredImages() {
        let visible = visibleImages
        guard !visible.isEmpty else {
            statusMessage = "No filtered images to mark"
            return
        }
        let visibleURLs = Set(visible.map { $0.url })
        var count = 0
        for i in images.indices where visibleURLs.contains(images[i].url) {
            if !images[i].isMarkedForDeletion {
                images[i].isMarkedForDeletion = true
                count += 1
            }
        }
        needsTableRefresh = true
        statusMessage = "Marked \(count) filtered images"
    }

    // Unmark all currently filtered/visible images
    func unmarkFilteredImages() {
        let visible = visibleImages
        let visibleURLs = Set(visible.map { $0.url })
        var count = 0
        for i in images.indices where visibleURLs.contains(images[i].url) {
            if images[i].isMarkedForDeletion {
                images[i].isMarkedForDeletion = false
                count += 1
            }
        }
        needsTableRefresh = true
        statusMessage = "Unmarked \(count) images"
    }

    // MARK: - Skip/Hide Marked

    func toggleSkipMarked() {
        skipMarked.toggle()
        AppSettings.saveBool(skipMarked, for: .skipMarked)
        statusMessage = skipMarked ? "Skip marked: ON" : "Skip marked: OFF"
    }

    // Cycle view filter: all → hide marked → only marked → all
    func cycleViewFilter() {
        if !hideMarked && !showOnlyMarked {
            // State 1 → 2: hide marked
            hideMarked = true
            showOnlyMarked = false
            statusMessage = "Hide marked: showing only unmarked"
        } else if hideMarked {
            // State 2 → 3: show only marked (inverted)
            hideMarked = false
            showOnlyMarked = true
            let markedCount = images.filter { $0.isMarkedForDeletion }.count
            statusMessage = "Inverted: showing only marked (\(markedCount) files)"
        } else {
            // State 3 → 1: show all
            hideMarked = false
            showOnlyMarked = false
            statusMessage = "Showing all files"
        }
        needsTableRefresh = true
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

    // MARK: - Move Marked to Custom Folder (Cmd+M)

    // Move checkmarked images to a user-selected destination folder.
    // Opens a save panel starting at the session directory where the user can
    // pick an existing folder or create a new one. Supports undo via Cmd+Z.
    func moveMarkedToFolder() {
        let markedImages = images.filter { $0.isMarkedForDeletion }
        guard !markedImages.isEmpty else {
            statusMessage = "No images marked — checkmark files first (Space)"
            return
        }

        // Open panel for folder selection, starting at session root
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select destination folder for \(markedImages.count) marked file(s)"
        panel.prompt = "Move Here"
        if let root = sessionRootURL {
            panel.directoryURL = root
        }

        guard panel.runModal() == .OK, let destDir = panel.url else {
            statusMessage = "Move cancelled"
            return
        }

        // Security-scoped access for the destination
        let accessed = destDir.startAccessingSecurityScopedResource()

        let fm = FileManager.default
        let firstMarkedIndex = images.firstIndex(where: { $0.isMarkedForDeletion }) ?? selectedIndex

        var movedCount = 0
        var failedCount = 0
        var undoEntries: [PreDeleteUndoEntry] = []

        for entry in markedImages {
            // Handle name collision: add numeric suffix
            var finalDest = destDir.appendingPathComponent(entry.filename)
            var suffix = 1
            while fm.fileExists(atPath: finalDest.path) {
                let name = entry.url.deletingPathExtension().lastPathComponent
                let ext = entry.url.pathExtension
                finalDest = destDir.appendingPathComponent("\(name)_\(suffix).\(ext)")
                suffix += 1
            }
            do {
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

        if accessed { destDir.stopAccessingSecurityScopedResource() }

        // Push to undo stack (same stack as PRE-DELETE — Cmd+Z undoes both)
        if !undoEntries.isEmpty {
            preDeleteUndoStack.append(undoEntries)
        }

        // Remove moved images from the list
        let markedURLs = Set(markedImages.map { $0.url })
        images.removeAll { markedURLs.contains($0.url) }

        // Re-select near where moved files were
        if !images.isEmpty {
            let newIndex = min(firstMarkedIndex, images.count - 1)
            selectImage(at: max(0, newIndex))
        } else {
            selectedIndex = -1
            currentDecodedImage = nil
        }

        needsTableRefresh = true
        sessionOverviewModel.updateStats(from: images)

        let destName = destDir.lastPathComponent
        if failedCount > 0 {
            statusMessage = "Moved \(movedCount) to \"\(destName)\" (\(failedCount) failed) — Undo available"
        } else {
            statusMessage = "Moved \(movedCount) file(s) to \"\(destName)\" — Undo available"
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

    // Sort by the first 4 visible columns (excluding the marked checkbox).
    // Moving a column to position 1 makes it the primary sort key,
    // position 2 = secondary, position 3 = tertiary, position 4 = quaternary.
    // Uses isDefaultDescending: numeric AND date/time columns sort descending by default
    // (newest date first, highest SNR first, etc.), text columns ascending (A-Z).
    func applySortByColumnOrder(_ columnIdentifiers: [String]) {
        let sortColumns = Array(
            columnIdentifiers
                .filter { $0 != "marked" }
                .prefix(4)
        )
        let descriptors = sortColumns.map { colId in
            let ascending = !ColumnDefinition.isDefaultDescending(colId)
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

        // Update meridian rotation for this image (zero-cost UV flip)
        updateMeridianRotation()

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
                benchmarkStats.markFirstImageDisplayed()
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
                        self.benchmarkStats.markFirstImageDisplayed()
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

    // MARK: - App Store Review

    // Prompt for review after 5th session load. Apple's API automatically limits
    // to 3 prompts per 365 days and suppresses if user already reviewed.
    private func checkForReviewPrompt() {
        let count = (AppSettings.defaults.object(forKey: AppSettings.Key.sessionCount.rawValue) as? Int ?? 0) + 1
        AppSettings.defaults.set(count, forKey: AppSettings.Key.sessionCount.rawValue)

        // Trigger on 5th and every 50th session after that (Apple rate-limits anyway)
        guard count == 5 || (count > 5 && count % 50 == 0) else { return }

        // Small delay so the session is visually loaded before the prompt appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            SKStoreReviewController.requestReview()
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
