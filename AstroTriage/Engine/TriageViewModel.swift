// v4.3.0
import Foundation
import SwiftUI
import Metal
import MetalKit
import UniformTypeIdentifiers
import StoreKit
import ImageDecoderBridge
import AVFoundation

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
    @Published var fontScale: CGFloat = 1.0  // UI font scale (0.8 = small, 1.0 = default, 1.2 = large)

    // Debayer toggle: when ON, OSC (one-shot-color) images are debayered to RGB
    // Default OFF for faster caching. Only relevant when session has OSC images.
    @Published var debayerEnabled: Bool = false

    // Post-processing sliders: GPU-accelerated adjustments on the display texture
    // These do NOT modify raw data — only the visual output after STF stretch
    @Published var sharpening: Float = 0.0    // Range -2 to +2 (negative = blur, positive = sharpen)
    @Published var contrast: Float = 0.0      // Range -1 to 1 (0 = off)
    @Published var darkLevel: Float = 0.0     // Range 0–0.5 (0 = off)
    @Published var histogramBins: [Float] = []  // 64 bins for mini histogram display

    // True when the current session contains OSC images (detected via BAYERPAT header)
    @Published var hasOSCImages: Bool = false

    // Auto Meridian: rotate images 180° to normalize orientation across meridian flips.
    // Meridian flip / rotator correction — per-target-group XOR logic:
    //   needsFlip = piersideChanged XOR rotator180Changed
    //   Both changed = cancel out (no flip). Only one changed = flip needed.
    // First image of each target group sets the reference orientation.
    @Published var autoMeridianEnabled: Bool = true  // Default ON
    @Published var hasMeridianFlip: Bool = false

    // Per-target reference orientation: (pierSide, rotatorAngle) from first image of that target
    struct OrientationRef {
        let pierSide: String?
        let rotatorAngle: Double?
        let wcsRotation: Double?
    }
    private var targetOrientationRefs: [String: OrientationRef] = [:]  // key = canonical target name

    // Frame History: unique session ID for the current session (reset on each folder open)
    private var currentSessionId = UUID().uuidString

    // Prefetch progress (0.0 to 1.0)
    @Published var cacheProgress: Double = 0
    @Published var cachingCount: Int = 0
    @Published var cachingTotal: Int = 0
    @Published var isCaching: Bool = false

    // Time estimates for loading and caching progress bars
    @Published var headerEstimatedSecondsRemaining: Int?
    @Published var cachingEstimatedSecondsRemaining: Int?
    var headerReadStartTime: Date?
    var cachingStartTime: Date?

    // Network file download progress (separate from header reading — runs concurrently)
    // Callback to update thread-safe URL map in the prefetch pipeline
    var networkURLUpdater: ((URL, URL) -> Void)?
    // Cancellation flag for network downloads (checked per-file in concurrentPerform)
    private let downloadCancelled = NSLock()
    private var _downloadCancelled = false
    @Published var isDownloading: Bool = false
    @Published var downloadCount: Int = 0
    @Published var downloadTotal: Int = 0
    @Published var downloadProgress: Double = 0
    @Published var downloadEstimatedSecondsRemaining: Int?
    var downloadStartTime: Date?

    // Scroll file list to top after loading a new session
    @Published var needsScrollToTop: Bool = false

    // Triggers a table reload in updateNSView (for checkbox/mark changes)
    @Published var needsTableRefresh: Bool = false
    // Force single selection after filter toggle (prevents multi-selection carryover)
    @Published var needsForceSingleSelection: Bool = false
    // Programmatic multi-row selection (AIsaac highlight command)
    @Published var pendingHighlightRows: IndexSet?

    // Blink playback
    @Published var isPlaying: Bool = false
    @Published var playbackDelay: Double = 0.1
    private var playbackTimer: Timer?
    private var playbackIndices: [Int] = []
    private var playbackPosition: Int = 0

    // Visual Validation (VLM mosaic anomaly detection)
    @Published var isGeneratingMosaic: Bool = false
    @Published var mosaicProgress: String = ""
    private var vlmGenerationTask: Task<Void, Never>?

    func selectMultipleRows(_ rows: IndexSet) {
        pendingHighlightRows = rows
        needsTableRefresh = true
        // Navigate to the first highlighted row
        if let first = rows.first, first >= 0, first < images.count {
            selectImage(at: first)
        }
    }

    // Recommended column order after header enrichment (set once per session load)
    // FileListView consumes and clears this after applying
    @Published var pendingColumnOrder: [String]?
    @Published var needsQualityResort = false

    // Hide marked images: when true, marked images are invisible in the list
    @Published var hideMarked: Bool = false

    // Show only marked: inverted view — when true, only marked images are shown
    // Mutually exclusive with hideMarked (Shift+H toggles this)
    @Published var showOnlyMarked: Bool = false

    // Skip marked images during arrow-key navigation
    @Published var skipMarked: Bool = false

    // Live SNR retention: percentage of total stack SNR retained after removing marked frames.
    // 100% = nothing marked, decreases as frames are marked. Updated on every mark toggle.
    @Published var snrRetention: Double = 100.0
    // Tooltip detail for the SNR retention bar (per-group breakdown)
    @Published var snrRetentionDetail: String = ""

    // Culling status — actionable text for status bar (v4.3.0)
    @Published var cullingStatus: CullingStatus?
    @Published var isConverged: Bool = false
    // Full convergence analysis result (from ConvergenceDetector)
    @Published var convergenceResult: ConvergenceResult?

    // Culling status model: simple actionable state
    struct CullingStatus {
        enum Level { case trash, warning, done }
        let level: Level
        let text: String

        func color(isNightMode: Bool) -> Color {
            if isNightMode {
                switch level {
                case .trash:   return Color(red: 0.6, green: 0.0, blue: 0.0)
                case .warning: return Color(red: 0.5, green: 0.3, blue: 0.0)
                case .done:    return Color(red: 0.3, green: 0.0, blue: 0.0)
                }
            }
            switch level {
            case .trash:   return .red
            case .warning: return .yellow
            case .done:    return .green
            }
        }
    }

    // In-app messaging banner (fetched from Supabase, shown between toolbar and content)
    @Published var bannerMessage: AppMessage?
    private var messageCheckTimer: Timer?

    // Current setup fingerprint (computed from first image's headers)
    var currentSetupFingerprint: SetupFingerprint? {
        guard let first = images.first(where: { $0.telescope != nil || $0.camera != nil }) else {
            return nil
        }
        return SetupFingerprint(
            telescope: first.telescope,
            camera: first.camera,
            focalLength: first.focalLength,
            pixelSizeMicrons: first.pixelSizeMicrons
        )
    }

    // Community detection learning baseline (fetched on session load if opted in)
    var communityBaseline: CommunityBaseline?

    // Spotlight-style search: filters file list in real time
    // Supports plain text (searches all columns) or "column:value" syntax (e.g. "filter:Ha", "fwhm:>4")
    @Published var filterText: String = ""

    // Side panel visibility (integrated into main window)
    @Published var showInspector: Bool = false
    @Published var showSessionOverview: Bool = false

    // Quick Stack: triangle-match alignment + mean combine for visual impression
    // V1 stacker removed in v4.4.0 — V2 (LightspeedStacker) is the only stacking engine
    // Quick Stack V2: optimized pipeline with GPU warp, hash-based matching, parallel star detection
    @Published var showQuickStackV2: Bool = false
    var quickStackEngineV2: QuickStackEngineV2?
    // Color Combine: mono filter stacks → RGB color image
    @Published var showColorCombine: Bool = false
    var colorCombineEngine: ColorCombineEngine?
    // Selected row indices from the file list (for multi-select operations like stacking)
    var selectedTableIndices: IndexSet = IndexSet()

    /// Returns the currently selected visible entries, or empty if nothing selected.
    /// Used by batch operations to operate only on highlighted files.
    var selectedEntries: [ImageEntry] {
        let visible = visibleImages
        return selectedTableIndices.compactMap { idx in
            idx < visible.count ? visible[idx] : nil
        }
    }

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

    // Star-based visual alignment — shared with prefetch cache for per-target reference tracking
    let displayAligner = DisplayAligner()

    // Benchmark upload service — auto-uploads session load stats after caching completes
    let benchmarkService = BenchmarkService()

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

    // Get cached preview texture for a URL (used by AIsaac for thumbnail generation)
    func getCachedTexture(for url: URL) -> MTLTexture? {
        prefetchCache?.getPreview(for: url)?.texture
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
        "psf": "psfFlux", "flux": "psfFlux", "psfflux": "psfFlux",
        "temp": "sensorTemp", "sensortemp": "sensorTemp",
        "gain": "gain", "offset": "offset",
        "amb": "ambientTemp", "ambtemp": "ambientTemp", "ambienttemp": "ambientTemp",
        "foc": "focuserTemp", "foctemp": "focuserTemp", "focusertemp": "focuserTemp",
        "telescope": "telescope", "tel": "telescope",
        "binning": "binning", "bin": "binning",
        "rating": "userConfidence", "conf": "userConfidence", "confidence": "userConfidence",
    ]

    // Check if an image entry matches the current filter criteria.
    // Supports plain text (all columns) or "column:value" syntax.
    private func matchesFilter(_ entry: ImageEntry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }

        // Check for "column:value" syntax (e.g. "filter:Ha", "fwhm:>4.0", "q:trash")
        if let colonIdx = query.firstIndex(of: ":") {
            let prefix = String(query[query.startIndex..<colonIdx]).lowercased()
            let value = String(query[query.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces).lowercased()

            // Quality tier filter: q:trash, q:borderline, q:good, q:excellent (+ color aliases)
            if (prefix == "q" || prefix == "quality") && !value.isEmpty {
                return matchesQualityFilter(entry, query: value)
            }

            // Trailing score filter: trail:>0.5
            if (prefix == "trail" || prefix == "trailing") && !value.isEmpty {
                guard let score = entry.trailingScore else { return false }
                return matchesNumericValue(score, query: value)
            }

            if let columnId = Self.columnAliases[prefix], !value.isEmpty {
                if ColumnDefinition.isNumericColumn(columnId) {
                    return matchesNumericFilter(entry, column: columnId, query: value)
                } else if columnId == "filter" {
                    // Filter-aware matching: use canonical filter names so filter:Ha
                    // matches H, H2, HII, H-alpha, ha_7nm etc. (all canonicalize to "Ha")
                    let entryCanonical = ColorCombineEngine.canonicalFilterName(entry.filter ?? "").lowercased()
                    let queryCanonical = ColorCombineEngine.canonicalFilterName(value).lowercased()
                    if entryCanonical == queryCanonical { return true }
                    // Fallback: raw contains for non-canonical filter names
                    return (entry.filter ?? "").lowercased().contains(value)
                } else {
                    return ColumnDefinition.value(for: columnId, from: entry)
                        .lowercased().contains(value)
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

    // Match quality tier by name or color alias
    private func matchesQualityFilter(_ entry: ImageEntry, query: String) -> Bool {
        guard let tier = entry.qualityTier else { return query == "unscored" }
        switch query {
        case "trash", "red":        return tier == .trash
        case "borderline", "orange": return tier == .borderline
        case "uncertain", "blue":   return tier == .uncertain
        case "good", "yellow":      return tier == .good
        case "excellent", "green":  return tier == .excellent
        case "unscored":            return false  // has a tier, so not unscored
        default:                    return false
        }
    }

    // Match a raw numeric value against ">X", "<X", ">=X", "<=X", or "=X" query
    private func matchesNumericValue(_ value: Double, query: String) -> Bool {
        var op = ">"
        var numStr = query
        if query.hasPrefix(">=")      { op = ">="; numStr = String(query.dropFirst(2)) }
        else if query.hasPrefix("<=") { op = "<="; numStr = String(query.dropFirst(2)) }
        else if query.hasPrefix(">")  { op = ">";  numStr = String(query.dropFirst(1)) }
        else if query.hasPrefix("<")  { op = "<";  numStr = String(query.dropFirst(1)) }
        else if query.hasPrefix("=")  { op = "=";  numStr = String(query.dropFirst(1)) }
        guard let threshold = Double(numStr.trimmingCharacters(in: .whitespaces)) else { return false }
        switch op {
        case ">":  return value > threshold
        case "<":  return value < threshold
        case ">=": return value >= threshold
        case "<=": return value <= threshold
        default:   return Swift.abs(value - threshold) < 0.001
        }
    }

    // Track security-scoped resources for proper cleanup. Multi-folder / mixed
    // selections need one scope per picked URL so PRE-DELETE moves succeed for
    // frames from any source folder (not just the first one).
    private var accessedURLs: [URL] = []

    // Backwards-compatible accessor for the primary (first) security-scoped URL.
    // Legacy callers such as moveMarkedToPreDelete read this — always prefer the
    // array when iterating or checking membership.
    private var accessedURL: URL? {
        get { accessedURLs.first }
        set {
            // Legacy assignment path: stop all previous, then store the single new one.
            stopAllAccessedURLs()
            if let url = newValue { accessedURLs = [url] }
        }
    }

    // Whether the current session was loaded from multiple source folders (or
    // a mix of files + folders). Used by moveMarkedToPreDelete to show a one-time
    // confirmation sheet explaining where PRE-DELETE will be created.
    private var multiSourceSession: Bool = false

    // One-time-per-session flag: set after the user confirms the multi-source
    // PRE-DELETE location so subsequent deletes in the same session don't re-prompt.
    private var multiSourcePreDeleteConfirmed: Bool = false

    /// Stop accessing every URL we currently hold a scope for and clear the list.
    private func stopAllAccessedURLs() {
        for u in accessedURLs { u.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
    }

    /// Start security-scoped access to each URL and store those that succeeded.
    /// Callers should call stopAllAccessedURLs() before invoking this to release
    /// any previous session's scopes.
    private func beginSecurityScopes(for urls: [URL]) {
        for u in urls {
            if u.startAccessingSecurityScopedResource() {
                accessedURLs.append(u)
            }
        }
    }

    /// Compute the deepest common ancestor directory across a set of URLs.
    /// Returns `/` if the URLs don't share any common parent, or the first URL's
    /// parent when the set has a single element. Used to derive sessionRootURL
    /// for multi-folder / mixed selections so PRE-DELETE ends up at a sensible
    /// location (and so the selection is still reachable from the sandbox).
    private static func commonAncestor(of urls: [URL]) -> URL {
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

    init() {
        self.device = MTLCreateSystemDefaultDevice()
        if let device = self.device {
            self.prefetchCache = PrefetchCache(device: device)
            // When a priority-queued preview completes, refresh display if it matches current image
            self.prefetchCache?.onPriorityPreviewReady = { [weak self] url in
                guard let self = self, self.selectedImage?.url == url else { return }
                self.displayCurrentImage()
            }
            // Star-based display alignment — shared aligner lives on the view model so it can
            // be reset per session. Workers compute transforms against the per-target reference
            // and report back via the callback below.
            self.prefetchCache?.displayAligner = self.displayAligner
            self.prefetchCache?.targetKeyForEntry = { entry in
                // Group by target only — one reference per target is the correct model:
                // the user expects all frames of M81 to align to the same orientation,
                // regardless of filter or exposure. Cross-filter matching is handled by
                // using more stars in the triangle pool (see triangleStarLimit).
                //
                // Falls back to a session-wide "TARGET" bucket when entry.target is not
                // yet populated (header enrichment may lag behind prefetch). For typical
                // single-target sessions this still produces one shared reference.
                if let t = entry.target, !t.isEmpty {
                    return TargetCatalog.canonicalName(t)
                }
                return "TARGET"
            }
            self.prefetchCache?.onAlignmentComputed = { [weak self] url, transform in
                guard let self = self else { return }
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    // CRITICAL: never overwrite a WCS-based transform. Star matching is
                    // a fallback for plate-solve data. If the entry already
                    // has WCS in its headers, applyWCSAlignment() has either already set
                    // the exact transform OR will do so when header enrichment finishes —
                    // either way we must not clobber it with a heuristic star-matching result.
                    if PrefetchCache.wcsDataIfComplete(self.images[idx]) != nil {
                        return
                    }
                    self.images[idx].alignmentTransform = transform
                    if self.selectedImage?.url == url {
                        self.updateMeridianRotation()
                    }
                }
            }
            // Benchmark "time to first image" — fires once per session as soon as ANY preview
            // is stored in the cache, decoupled from MTKView attachment, user navigation, and
            // displayCurrentImage success. Measures real app readiness, not user-click latency.
            self.prefetchCache?.onFirstPreviewStored = { [weak self] in
                Task { @MainActor in
                    self?.benchmarkStats.markFirstImageDisplayed()
                }
            }
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
        if let v = AppSettings.loadFloat(for: .fontScale) { fontScale = CGFloat(v) }
        // Right-side Session Overview panel: user-controlled, persists across sessions & iCloud.
        // First-run default remains false (clean single-column layout until user opens it once).
        if let v = AppSettings.loadBool(for: .showSessionOverviewPanel) { showSessionOverview = v }

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

    // MARK: - Compare with Best

    func compareWithBest() {
        guard let entry = selectedImage,
              let tier = entry.qualityTier, tier != .excellent,
              let device = renderer?.device else { return }

        let targetKey = entry.canonicalTarget ?? TargetCatalog.canonicalName(entry.target ?? "")
        let filterKey = (entry.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        let expKey = entry.exposure.map { Int($0.rounded()) } ?? 0
        // Focal length bucket — RASA 620mm and RC12 1964mm must never compare
        let flKey = entry.focalLength.map { Int(($0 / 50).rounded()) * 50 } ?? 0

        let groupImages = images.filter { img in
            let t = img.canonicalTarget ?? TargetCatalog.canonicalName(img.target ?? "")
            let f = (img.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
            let e = img.exposure.map { Int($0.rounded()) } ?? 0
            let fl = img.focalLength.map { Int(($0 / 50).rounded()) * 50 } ?? 0
            return t == targetKey && f == filterKey && e == expKey && fl == flKey
        }

        // Find the best frame for comparison.
        // Priority: same filter group → same target+exposure (any filter) → same target (any filter/exposure).
        // When the group's best is also garbage, widen the search to find a genuinely good reference.
        var best: ImageEntry? = groupImages
            .filter { $0.url != entry.url }
            .max(by: { ($0.qualityZScore ?? -100) < ($1.qualityZScore ?? -100) })

        // Cross-filter fallback: SAME FILTER with different exposure first,
        // then same filter class as absolute last resort.
        // L vs R looks different (star brightness, noise profile), Ha vs L is completely wrong.
        // Always prefer same filter. Only fall back within class (NB↔NB, BB↔BB) if nothing else.
        let selectedCanonical = ColorCombineEngine.canonicalFilterName(filterKey)

        // Fallback 1: same filter + same setup, any exposure (e.g., Ha 300s best is garbage → try Ha 180s)
        if best == nil || (best!.qualityTier != .excellent && best!.qualityTier != .good) {
            let sameFilterAnyExp = images.filter { img in
                let t = img.canonicalTarget ?? TargetCatalog.canonicalName(img.target ?? "")
                let f = (img.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                let fl = img.focalLength.map { Int(($0 / 50).rounded()) * 50 } ?? 0
                return t == targetKey && f == filterKey && fl == flKey && img.url != entry.url
            }
            if let sfBest = sameFilterAnyExp.max(by: { ($0.qualityZScore ?? -100) < ($1.qualityZScore ?? -100) }),
               (sfBest.qualityZScore ?? -100) > (best?.qualityZScore ?? -100) {
                best = sfBest
            }
        }

        // Fallback 2 (last resort): same filter CLASS + same setup + same target.
        // NB↔NB (Ha can compare to OIII — both show nebula structure, similar star profiles).
        // BB↔BB (L can compare to R — both broadband, similar star fields).
        // Never NB↔BB (Ha vs L looks completely different).
        // Always same setup (FL) — never compare RASA to RC12.
        if best == nil || (best!.qualityTier != .excellent && best!.qualityTier != .good) {
            let selectedIsNarrowband = QualityEstimator.narrowbandCanonical.contains(selectedCanonical)
            let sameClass = images.filter { img in
                let t = img.canonicalTarget ?? TargetCatalog.canonicalName(img.target ?? "")
                let f = ColorCombineEngine.canonicalFilterName((img.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces))
                let isNB = QualityEstimator.narrowbandCanonical.contains(f)
                let fl = img.focalLength.map { Int(($0 / 50).rounded()) * 50 } ?? 0
                return t == targetKey && fl == flKey && img.url != entry.url && isNB == selectedIsNarrowband
            }
            if let classBest = sameClass.max(by: { ($0.qualityZScore ?? -100) < ($1.qualityZScore ?? -100) }),
               (classBest.qualityZScore ?? -100) > (best?.qualityZScore ?? -100) {
                best = classBest
            }
        }

        guard let best = best, best.url != entry.url else { return }

        // Determine fallback reason for display in compare window
        let bestFilter = (best.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        let bestExp = best.exposure.map { Int($0.rounded()) } ?? 0
        let fallbackReason: String?
        if bestFilter == filterKey && bestExp == expKey {
            fallbackReason = nil  // exact group match
        } else if bestFilter == filterKey {
            fallbackReason = "\(bestExp)s exposure"
        } else {
            fallbackReason = "\(bestFilter.isEmpty ? "?" : bestFilter) filter"
        }

        // Show loading indicator while compare images are decoded and stretched
        statusMessage = "Preparing Compare..."
        let loadingWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        loadingWindow.title = ""
        loadingWindow.isFloatingPanel = true
        loadingWindow.level = .floating
        let label = NSTextField(labelWithString: "  Preparing Compare...")
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 20, y: 18, width: 220, height: 24)
        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 8, width: 220, height: 4))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        container.addSubview(label)
        container.addSubview(progress)
        loadingWindow.contentView = container
        loadingWindow.center()
        loadingWindow.orderFront(nil)
        // Auto-dismiss after 4s or when compare window opens
        Task {
            // Poll for compare window opening (check every 200ms, max 4s)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let windowCount = await MainActor.run { NSApp.windows.filter { $0.title.hasPrefix("Compare:") }.count }
                if windowCount > 0 { break }
            }
            await MainActor.run {
                loadingWindow.close()
                self.statusMessage = ""
            }
        }

        CompareWindowController.open(
            selectedEntry: entry, bestEntry: best,
            device: device, nightMode: nightMode, debayerEnabled: debayerEnabled,
            rotateSelected: shouldRotateForMeridian(entry),
            rotateBest: shouldRotateForMeridian(best),
            fallbackReason: fallbackReason
        )
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

        wireSessionOverviewCallbacks()

        // Separate directories and files
        var directories: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                directories.append(url)
            } else {
                files.append(url)
            }
        }

        if directories.count == 1 && files.isEmpty {
            // Single directory — standard folder scan
            loadSession(url: directories[0])
        } else if directories.count >= 1 && files.isEmpty {
            // Multiple directories only — merge into one session
            loadMultipleFolders(urls: directories)
        } else if directories.isEmpty && !files.isEmpty {
            // Individual files only — no folders picked
            loadFiles(urls: files)
        } else {
            // Mixed selection: files + at least one folder. Pre-v5.22.1 silently
            // dropped the folders because loadFiles filtered by .fits extension.
            // Now we route through a dedicated mixed path that scans every picked
            // directory and merges each picked file as its own ImageEntry.
            loadMixedSelection(files: files, directories: directories)
        }
    }

    /// Handle a mixed NSOpenPanel selection of loose files + one or more folders.
    /// Each directory is scanned via SessionScanner; each standalone file produces
    /// its own ImageEntry. Results are deduped by standardizedFileURL so a file
    /// listed both inside a picked folder and as a top-level pick appears once.
    private func loadMixedSelection(files: [URL], directories: [URL]) {
        let fileEntries = files.filter {
            SessionScanner.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !fileEntries.isEmpty || !directories.isEmpty else {
            statusMessage = "No FITS/XISF files or folders in selection"
            return
        }

        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        isLoading = true
        isCaching = false
        cacheProgress = 0
        cachingStopped = false
        loadingPhase = .scanning

        // Deepest common ancestor across every picked URL (files' parents + dirs),
        // used as sessionRootURL / PRE-DELETE location.
        let parentsAndDirs: [URL] = fileEntries.map { $0.deletingLastPathComponent() } + directories
        let uniqueScopes = Array(Set(parentsAndDirs.map { $0.standardizedFileURL }))
        let rootURL: URL
        if uniqueScopes.count == 1 {
            rootURL = uniqueScopes[0]
            multiSourceSession = false
        } else {
            rootURL = Self.commonAncestor(of: uniqueScopes)
            multiSourceSession = true
        }
        multiSourcePreDeleteConfirmed = false

        // Claim scopes for every picked folder, every file parent, and the files
        // themselves — the sandbox needs the individual file URLs to move them
        // into PRE-DELETE.
        stopAllAccessedURLs()
        beginSecurityScopes(for: uniqueScopes + fileEntries)

        sessionRootURL = rootURL
        prefetchCache?.clear()
        downloadCancelled.lock(); _downloadCancelled = true; downloadCancelled.unlock()
        isDownloading = false; isCaching = false

        let summary = "\(fileEntries.count) file\(fileEntries.count == 1 ? "" : "s") + \(directories.count) folder\(directories.count == 1 ? "" : "s")"
        statusMessage = "Scanning \(summary)..."

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

            await MainActor.run {
                guard let self = self else { return }
                self.benchmarkStats.markScanComplete(
                    fileCount: sorted.count,
                    totalBytes: sorted.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
                self.images = sorted
                self.assignSessionIndices()
                self.isLoading = false
                self.needsTableRefresh = true
                self.needsQualityResort = false

                if !sorted.isEmpty {
                    self.selectImage(at: 0)
                    self.needsScrollToTop = true
                }

                self.sessionOverviewModel.updateStats(from: sorted)
                // Respect user-persisted Session Overview visibility.
                self.showInspector = true
                self.applyAllEnabled = true
                self.triggerApplyAll()
                self.enrichWithHeaders()
                self.focusTableAfterDelay()

                self.statusMessage = "\(sorted.count) frames loaded from \(summary)"
            }
        }
    }

    /// Wire session overview tap callbacks (idempotent — safe to call multiple times)
    private func wireSessionOverviewCallbacks() {
        sessionOverviewModel.onObjectTapped = { [weak self] name in self?.navigateToObject(name) }
        sessionOverviewModel.onFilterTapped = { [weak self] obj, filter, exposure, night in self?.navigateToObject(obj, filter: filter, exposure: exposure, night: night) }
    }

    // Load specific files (user selected individual files, not a folder)
    func loadFiles(urls: [URL]) {
        let imageURLs = urls.filter { SessionScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else {
            statusMessage = "No FITS/XISF files in selection"
            return
        }

        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        isLoading = true
        isCaching = false
        cacheProgress = 0
        cachingStopped = false
        loadingPhase = .scanning

        // Session root: if all files share the same parent, use that; otherwise
        // compute the deepest common ancestor across the picked file URLs so
        // PRE-DELETE lands somewhere every picked file is reachable from.
        let parentFolders = imageURLs.map { $0.deletingLastPathComponent() }
        let uniqueParents = Array(Set(parentFolders.map { $0.standardizedFileURL }))
        let rootURL: URL
        if uniqueParents.count == 1 {
            rootURL = uniqueParents[0]
            multiSourceSession = false
        } else {
            rootURL = Self.commonAncestor(of: uniqueParents)
            multiSourceSession = true
        }
        multiSourcePreDeleteConfirmed = false

        // Release previous security-scoped resources and grab scopes for every
        // distinct parent folder + each explicit file URL.
        stopAllAccessedURLs()
        beginSecurityScopes(for: uniqueParents + imageURLs)

        sessionRootURL = rootURL
        prefetchCache?.clear()
        downloadCancelled.lock(); _downloadCancelled = true; downloadCancelled.unlock()
        isDownloading = false; isCaching = false

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
                self.assignSessionIndices()
                self.isLoading = false
                self.needsTableRefresh = true
                self.needsQualityResort = false  // Reset for new session

                if !entries.isEmpty {
                    self.selectImage(at: 0)
                    self.needsScrollToTop = true
                }

                self.sessionOverviewModel.updateStats(from: entries)
                // Session Overview visibility is user-persisted (AppSettings.showSessionOverviewPanel).
                // Do not force-show on every load — respects the user's last choice.
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

    // Load multiple folders as a merged session. sessionRootURL is set to the
    // deepest common ancestor of the picked folders (not the first folder's
    // parent) and security scope is held for EVERY folder so PRE-DELETE moves
    // succeed for frames originating from any of them.
    func loadMultipleFolders(urls: [URL]) {
        guard !urls.isEmpty else { return }

        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        isLoading = true
        isCaching = false
        cacheProgress = 0
        cachingStopped = false
        loadingPhase = .scanning

        // Deepest common ancestor across all picked folders — the single
        // location PRE-DELETE will be created in (single-folder case still
        // falls through to that same folder).
        let rootURL: URL
        if urls.count == 1 {
            rootURL = urls[0]
            multiSourceSession = false
        } else {
            rootURL = Self.commonAncestor(of: urls)
            multiSourceSession = true
        }
        multiSourcePreDeleteConfirmed = false

        // Release previous session scopes, then claim a scope for every picked
        // folder so moveMarkedToPreDelete can move frames from any source.
        stopAllAccessedURLs()
        beginSecurityScopes(for: urls)

        sessionRootURL = rootURL
        prefetchCache?.clear()
        downloadCancelled.lock(); _downloadCancelled = true; downloadCancelled.unlock()
        isDownloading = false; isCaching = false

        let folderNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        statusMessage = "Scanning \(urls.count) folders: \(folderNames)..."

        Task.detached(priority: .userInitiated) { [weak self] in
            var allEntries: [ImageEntry] = []
            for url in urls {
                let entries = SessionScanner.scan(rootURL: url)
                allEntries.append(contentsOf: entries)
            }

            allEntries.sort { ($0.dateTime ?? "") < ($1.dateTime ?? "") }

            await MainActor.run {
                guard let self = self else { return }
                self.benchmarkStats.markScanComplete(fileCount: allEntries.count, totalBytes: allEntries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
                self.images = allEntries
                self.assignSessionIndices()
                self.isLoading = false
                self.needsTableRefresh = true
                self.needsQualityResort = false

                if !allEntries.isEmpty {
                    self.selectImage(at: 0)
                    self.needsScrollToTop = true
                }

                self.sessionOverviewModel.updateStats(from: allEntries)
                // Session Overview visibility is user-persisted; do not force-show.
                self.showInspector = true
                self.applyAllEnabled = true

                self.checkMemoryBudgetAndCache(for: allEntries)
            }
        }
    }

    func loadSession(url: URL) {
        currentSessionId = UUID().uuidString
        wireSessionOverviewCallbacks()
        benchmarkStats.markSessionStart()
        prefetchCache?.resetFirstPreviewTracking()
        print("[Bench] LOAD START at \(Date().timeIntervalSince1970) — \(url.lastPathComponent)")
        isLoading = true
        isCaching = false
        cacheProgress = 0
        loadingPhase = .scanning
        statusMessage = "Scanning \(url.lastPathComponent)..."

        // Release previous session's security-scoped resources before starting a
        // new session. Single-folder load: one scope on the picked folder.
        stopAllAccessedURLs()
        multiSourceSession = false
        multiSourcePreDeleteConfirmed = false

        sessionRootURL = url
        prefetchCache?.clear()
        // Reset the display aligner — each session establishes its own per-target references
        displayAligner.reset()
        // Cancel any in-progress NAS downloads
        downloadCancelled.lock()
        _downloadCancelled = true
        downloadCancelled.unlock()
        isDownloading = false
        isCaching = false

        beginSecurityScopes(for: [url])
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
            let headerMs = Int(Date().timeIntervalSince(headerStart) * 1000)
            let wcsCount = entries.filter { $0.wcsCD11 != nil && $0.wcsCRPIX1 != nil }.count
            print("[Bench] WCS pre-scan: \(wcsCount)/\(entries.count) frames have WCS (\(headerMs)ms)")

            await MainActor.run {
                guard let self = self else { return }
                self.benchmarkStats.markScanComplete(fileCount: entries.count, totalBytes: entries.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) })
                self.images = entries
                self.assignSessionIndices()
                // Disable prefetch star-matching when ANY frame has WCS. Reasoning:
                // when WCS frames exist, applyWCSAlignment defines the global reference.
                // Frames WITHOUT WCS would otherwise star-match against each other,
                // forming a separate reference group inconsistent with WCS.
                // applyWCSAlignment now also handles the WCS-less frames via a
                // rotator-based synthetic transform, all anchored to the same reference.
                let anyHasWCS = entries.contains { $0.wcsCD11 != nil && $0.wcsCRPIX1 != nil }
                self.prefetchCache?.skipStarMatchingForAlignment = anyHasWCS
                self.isLoading = false
                self.needsTableRefresh = true

                if !entries.isEmpty {
                    self.selectImage(at: 0)
                    self.needsScrollToTop = true
                }

                // Refresh overview stats but honor user-persisted visibility.
                self.sessionOverviewModel.updateStats(from: entries)
                // Session Overview visibility is user-persisted; do not force-show.
                self.showInspector = true

                // Enable Apply All by default so cached previews are instant from the start
                self.applyAllEnabled = true

                if isNetwork {
                    self.statusMessage = "Downloading \(entries.count) images to local cache..."
                    // Clear scanning overlay — download fuel bar takes over from here
                    self.loadingPhase = .none
                    // Header enrichment deferred to after downloads complete — reading headers
                    // from local SSD cache is 100x faster than reading from NAS over SMB
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
                // Interleaved pipeline: cacheNetworkFiles starts pre-caching
                // automatically after first 4 files download — no separate triggerApplyAll
                await self?.cacheNetworkFiles()
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
        cachingStartTime = Date()
        cachingEstimatedSecondsRemaining = nil

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

        // Identify frames that have cached previews but missing analysis data.
        // These frames were skipped in a prior prefetch because their preview was cached,
        // but the metric callbacks (onNoiseStats, onStarMetrics) never fired.
        let needsAnalysis = Set(images.filter { $0.noiseMAD == nil && $0.computedStarCount == nil }
                                       .map { $0.url })

        prefetchCache.prefetchAll(
            images: images,
            debayerEnabled: debayerEnabled,
            targetBackground: lockedParams != nil ? nil : targetBg,  // locked params override target
            lockedSTFParams: lockedParams,
            postProcessParams: ppParams,
            needsAnalysis: needsAnalysis,
            onProgress: { [weak self] completed, total in
                guard let self = self else { return }
                self.cachingCount = completed
                self.cachingTotal = total
                self.cacheProgress = total > 0 ? Double(completed) / Double(total) : 0

                // Refresh table periodically so cache checkmarks appear (every 4 images)
                if completed % 4 == 0 || completed == total {
                    self.needsTableRefresh = true
                    // Compute caching time estimate after 20 items
                    if completed >= 20, let startTime = self.cachingStartTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let avgPerItem = elapsed / Double(completed)
                        let remaining = Int(avgPerItem * Double(total - completed))
                        self.cachingEstimatedSecondsRemaining = max(1, remaining)
                    }
                }

                if completed < total {
                    self.statusMessage = "Analyzing \(completed)/\(total)..."
                } else {
                    self.isCaching = false
                    self.cachingEstimatedSecondsRemaining = nil
                    self.cachingStartTime = nil
                    self.needsTableRefresh = true
                    self.statusMessage = "instant navigation ready"
                    self.benchmarkStats.markCachingEnd()
                    print("[Bench] LOAD READY at \(Date().timeIntervalSince1970) — caching complete, \(self.images.count) frames")
                    // Fire-and-forget anonymous upload of session load stats (community telemetry)
                    self.benchmarkService.autoUploadSessionLoad(
                        stats: self.benchmarkStats,
                        sessionRootURL: self.sessionRootURL
                    )
                    // Release App Nap assertion when caching completes
                    self.appNapAssertion = nil
                    // Update session overview with noise stats now that all images are measured
                    self.sessionOverviewModel.updateStats(from: self.images)
                    // Recompute quality scores now that noiseMAD is populated for all images
                    self.recomputeQualityScores()
                    // Fix for MainActor Task delivery race: metric callbacks for individual
                    // frames are dispatched as separate MainActor Tasks which may not have
                    // executed yet when onProgress(total,total) fires. Re-check after a
                    // short delay to catch any frames whose metrics arrived late.
                    self.scheduleQualityRescore()
                    // Jump to first image after precaching + quality scoring complete
                    if !self.images.isEmpty {
                        self.selectImage(at: 0)
                    }
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
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    if metrics.medianHFR > 0 { self.images[idx].computedHFR = metrics.medianHFR }
                    if metrics.medianFWHM > 0 { self.images[idx].computedFWHM = metrics.medianFWHM }
                    self.images[idx].computedStarCount = metrics.totalStarCount
                    self.images[idx].computedEccentricity = metrics.medianEccentricity
                    self.images[idx].psfFluxSum = metrics.psfFluxSum
                    self.images[idx].psfMeanFlux = metrics.psfMeanFlux
                    self.images[idx].starChainFraction = metrics.starChainFraction
                    if !metrics.starDetails.isEmpty {
                        self.images[idx].starDetails = metrics.starDetails
                    }

                    // Run trailing analysis with orientation consensus.
                    // focalLength may not be available yet (header enrichment runs in parallel)
                    // — trailing scores are recomputed in recomputeQualityScores() after enrichment
                    if !metrics.starDetails.isEmpty {
                        let trailing = TrailingAnalyzer.analyze(
                            starDetails: metrics.starDetails,
                            focalLength: self.images[idx].focalLength,
                            pixelSizeMicrons: self.images[idx].pixelSizeMicrons
                        )
                        if let t = trailing {
                            self.images[idx].trailingScore = t.trailingScore
                            self.images[idx].trailingPA = t.consensusPA
                            self.images[idx].trailingAxisRatio = t.medianAxisRatio
                            self.images[idx].trailingConsensus = t.consensusFraction
                        }
                    }
                }
            },
            onFileHash: { [weak self] url, hash in
                guard let self = self else { return }
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    self.images[idx].fileHash = hash
                    // Restore persisted per-frame user state from Frame History DB.
                    // fileHash is the stable cross-machine identity, so this also
                    // picks up feedback given on another Mac via the iCloud-synced DB.
                    if let record = try? FrameHistoryDatabase.shared.frameRecord(fileHash: hash) {
                        self.images[idx].userConfidence = record.userConfidence
                        self.images[idx].qualityFeedback = QualityFeedback(rawValue: record.qualityFeedback) ?? .none
                    }
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

    // Interleaved NAS pipeline: download files and pre-cache concurrently.
    // As each file downloads to local SSD, it becomes available for pre-caching.
    // Pre-caching starts after the first 4 files are downloaded.
    private func cacheNetworkFiles() async {
        guard let rootURL = sessionRootURL else { return }
        sessionCache.prepareSession(rootURL: rootURL)

        let total = images.count
        let sourceURLs = images.map { $0.url }

        // Reset cancellation flag for new download session
        downloadCancelled.lock()
        _downloadCancelled = false
        downloadCancelled.unlock()

        // Set up dedicated download fuel bar
        isDownloading = true
        downloadCount = 0
        downloadTotal = total
        downloadProgress = 0
        downloadStartTime = Date()
        downloadEstimatedSecondsRemaining = nil

        let sessionCacheRef = sessionCache
        let progressCounter = NSLock()
        var progressCount = 0
        var precacheStarted = false

        // Parallel download with 4 concurrent streams
        let cancelledRef = self.downloadCancelled
        var cancelledFlag: Bool { cancelledRef.lock(); defer { cancelledRef.unlock() }; return self._downloadCancelled }

        await Task.detached(priority: .utility) { [weak self] in
            DispatchQueue.concurrentPerform(iterations: total) { index in
                // Early exit if session changed (user opened another folder)
                self?.downloadCancelled.lock()
                let cancelled = self?._downloadCancelled ?? true
                self?.downloadCancelled.unlock()
                guard !cancelled else { return }

                let localURL = sessionCacheRef.cacheFile(sourceURL: sourceURLs[index])

                // Update decodingURL + thread-safe URL map for prefetch pipeline
                if let localURL = localURL {
                    Task { @MainActor [weak self] in
                        guard let self = self, index < self.images.count else { return }
                        self.images[index].decodingURL = localURL
                    }
                    // Update thread-safe URL map (no main-thread hop needed)
                    Task { @MainActor [weak self] in
                        self?.networkURLUpdater?(sourceURLs[index], localURL)
                    }
                }

                progressCounter.lock()
                progressCount += 1
                let current = progressCount
                progressCounter.unlock()

                if current % 4 == 0 || current == total {
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.downloadCount = current
                        self.downloadTotal = total
                        self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                        // Time estimate after 20 files
                        if current >= 20, let startTime = self.downloadStartTime {
                            let elapsed = Date().timeIntervalSince(startTime)
                            let avgPerItem = elapsed / Double(current)
                            let remaining = Int(avgPerItem * Double(total - current))
                            self.downloadEstimatedSecondsRemaining = max(1, remaining)
                        }

                        // Start pre-caching after first 4 files are downloaded
                        if !precacheStarted && current >= 4 {
                            precacheStarted = true
                            self.applyAllEnabled = true
                            self.startFullPrefetchInterleaved()
                        }
                    }
                }
            }
        }.value

        isDownloading = false
        downloadEstimatedSecondsRemaining = nil
        downloadStartTime = nil
        networkURLUpdater = nil  // Release closure + captured URL map

        // Bail out if session was cancelled (user opened another folder)
        downloadCancelled.lock()
        let wasCancelled = _downloadCancelled
        downloadCancelled.unlock()
        guard !wasCancelled else { return }

        // If fewer than 4 files (small session), start prefetch now
        if !precacheStarted {
            applyAllEnabled = true
            triggerApplyAll()
        }

        // Now that files are local, enrich headers from SSD cache (instant vs NAS)
        // This populates filter, gain, temp, etc. from FITS/XISF headers
        enrichWithHeaders()

        Task.detached(priority: .background) {
            SessionCache.cleanupOldCaches()
        }
    }

    // Start pre-caching with late URL resolution for interleaved NAS pipeline.
    // Operations resolve decodingURL at execution time, so they use the local
    // cache file even if it was downloaded after the operation was created.
    private func startFullPrefetchInterleaved() {
        guard let prefetchCache = prefetchCache else { return }

        // Update applied settings so cacheMatchesCurrentSettings returns true
        // after prefetch completes (same as triggerApplyAll does)
        appliedStretch = stretchStrength
        appliedSharpening = sharpening
        appliedContrast = contrast
        appliedDarkLevel = darkLevel
        appliedLocked = isSTFLocked

        benchmarkStats.markCachingStart()
        isCaching = true
        cachingStopped = false
        cachingTotal = images.count
        cachingCount = 0
        cacheProgress = 0
        cachingStartTime = Date()
        cachingEstimatedSecondsRemaining = nil

        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Pre-caching astrophotography images"
        )

        let targetBg: Float? = abs(appliedStretch - STFCalculator.defaultTargetBackground) > 0.001
            ? appliedStretch : nil
        let lockedParams: [STFParams]? = appliedLocked ? renderer?.lockedSTFParams : nil
        let ppParams: (sharpening: Float, contrast: Float, darkLevel: Float)?
        if abs(appliedSharpening) > 0.001 || abs(appliedContrast) > 0.001 || appliedDarkLevel > 0.001 {
            ppParams = (appliedSharpening, appliedContrast, appliedDarkLevel)
        } else {
            ppParams = nil
        }

        // Thread-safe URL lookup for late resolution — avoids DispatchQueue.main.sync
        // bottleneck that would serialize background operations.
        // Downloads update this dictionary as files arrive; prefetch reads it lock-free-ish.
        let urlLock = NSLock()
        var urlMap: [URL: URL] = [:]
        for entry in images {
            urlMap[entry.url] = entry.decodingURL
        }
        // Expose updater for download callback
        networkURLUpdater = { url, localURL in
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

        // Identify frames that need re-analysis (cached preview but missing metrics)
        let needsAnalysisNAS = Set(images.filter { $0.noiseMAD == nil && $0.computedStarCount == nil }
                                          .map { $0.url })

        prefetchCache.prefetchAll(
            images: images,
            debayerEnabled: debayerEnabled,
            targetBackground: lockedParams != nil ? nil : targetBg,
            lockedSTFParams: lockedParams,
            postProcessParams: ppParams,
            resolveDecodingURL: resolveURL,
            needsAnalysis: needsAnalysisNAS,
            onProgress: { [weak self] completed, total in
                guard let self = self else { return }
                self.cachingCount = completed
                self.cachingTotal = total
                self.cacheProgress = total > 0 ? Double(completed) / Double(total) : 0

                if completed % 4 == 0 || completed == total {
                    self.needsTableRefresh = true
                    if completed >= 20, let startTime = self.cachingStartTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let avgPerItem = elapsed / Double(completed)
                        let remaining = Int(avgPerItem * Double(total - completed))
                        self.cachingEstimatedSecondsRemaining = max(1, remaining)
                    }
                }

                if completed < total {
                    self.statusMessage = "Analyzing \(completed)/\(total)..."
                } else {
                    self.isCaching = false
                    self.cachingEstimatedSecondsRemaining = nil
                    self.cachingStartTime = nil
                    self.needsTableRefresh = true
                    self.statusMessage = "instant navigation ready"
                    self.benchmarkStats.markCachingEnd()
                    // Fire-and-forget anonymous upload of session load stats (community telemetry)
                    self.benchmarkService.autoUploadSessionLoad(
                        stats: self.benchmarkStats,
                        sessionRootURL: self.sessionRootURL
                    )
                    self.appNapAssertion = nil
                    // Don't compute quality scores here — header enrichment hasn't run yet
                    // for NAS sessions. enrichWithHeaders() completion handles quality scoring
                    // + session overview update after all header data is available.
                    if !self.images.isEmpty {
                        self.selectImage(at: 0)
                    }
                }
            },
            onNoiseStats: { [weak self] url, stats in
                guard let self = self else { return }
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    self.images[idx].noiseMedian = stats.median
                    self.images[idx].noiseMAD = stats.normalizedMAD
                }
            },
            onStarMetrics: { [weak self] url, metrics in
                guard let self = self else { return }
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    if metrics.medianHFR > 0 { self.images[idx].computedHFR = metrics.medianHFR }
                    if metrics.medianFWHM > 0 { self.images[idx].computedFWHM = metrics.medianFWHM }
                    self.images[idx].computedStarCount = metrics.totalStarCount
                    self.images[idx].computedEccentricity = metrics.medianEccentricity
                    self.images[idx].psfFluxSum = metrics.psfFluxSum
                    self.images[idx].psfMeanFlux = metrics.psfMeanFlux
                    self.images[idx].starChainFraction = metrics.starChainFraction
                    if !metrics.starDetails.isEmpty {
                        self.images[idx].starDetails = metrics.starDetails
                    }
                    // Trailing analysis
                    if !metrics.starDetails.isEmpty {
                        let trailing = TrailingAnalyzer.analyze(
                            starDetails: metrics.starDetails,
                            focalLength: self.images[idx].focalLength,
                            pixelSizeMicrons: self.images[idx].pixelSizeMicrons
                        )
                        if let t = trailing {
                            self.images[idx].trailingScore = t.trailingScore
                            self.images[idx].trailingPA = t.consensusPA
                            self.images[idx].trailingAxisRatio = t.medianAxisRatio
                            self.images[idx].trailingConsensus = t.consensusFraction
                        }
                    }
                }
            },
            onFileHash: { [weak self] url, hash in
                guard let self = self else { return }
                if let idx = self.images.firstIndex(where: { $0.url == url }) {
                    self.images[idx].fileHash = hash
                    // Restore persisted per-frame user state from Frame History DB.
                    // fileHash is the stable cross-machine identity, so this also
                    // picks up feedback given on another Mac via the iCloud-synced DB.
                    if let record = try? FrameHistoryDatabase.shared.frameRecord(fileHash: hash) {
                        self.images[idx].userConfidence = record.userConfidence
                        self.images[idx].qualityFeedback = QualityFeedback(rawValue: record.qualityFeedback) ?? .none
                    }
                }
            }
        )
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
        // Use decodingURL for actual file I/O (points to local cache for NAS files)
        // but keep original url as the dictionary key for matching
        let urls = images.map { $0.url }
        let readURLs = images.map { $0.decodingURL }
        let total = urls.count
        loadingPhase = .readingHeaders
        benchmarkStats.markHeaderEnrichStart()
        headerReadCount = 0
        headerReadTotal = total
        headerProgress = 0
        headerReadStartTime = Date()
        headerEstimatedSecondsRemaining = nil

        // Cap concurrency: ~8 for local SSD (queue depth), ~4 for network
        let concurrency = min(8, ProcessInfo.processInfo.activeProcessorCount)

        headerEnrichmentTask = Task.detached(priority: .utility) { [weak self] in
            // Read all headers in parallel using concurrentPerform
            var allHeaders = Array(repeating: [String: String](), count: total)
            let headerLock = NSLock()
            let progressCounter = NSLock()
            var progressCount = 0

            DispatchQueue.concurrentPerform(iterations: total) { index in
                let headers = MetadataExtractor.readHeaders(from: readURLs[index])
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
                        // Compute time estimate after 20 items (enough for stable average)
                        if currentProgress >= 20, let startTime = self.headerReadStartTime {
                            let elapsed = Date().timeIntervalSince(startTime)
                            let avgPerItem = elapsed / Double(currentProgress)
                            let remaining = Int(avgPerItem * Double(total - currentProgress))
                            self.headerEstimatedSecondsRemaining = max(1, remaining)
                        }
                    }
                }
            }

            // Apply all headers in one batch on main actor.
            // Use URL-based lookup instead of index-based to handle reordering:
            // images may get sorted by quality scoring while headers are being read.
            var headersByURL: [URL: [String: String]] = [:]
            headersByURL.reserveCapacity(total)
            for index in 0..<total {
                let headers = allHeaders[index]
                if !headers.isEmpty { headersByURL[urls[index]] = headers }
            }

            await MainActor.run {
                guard let self = self else { return }
                var foundOSC = false

                for index in self.images.indices {
                    guard let headers = headersByURL[self.images[index].url] else { continue }

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
                    // Focal length and pixel size for adaptive trailing thresholds
                    if let fl = headers["FOCALLEN"], let val = Double(fl), val > 0 {
                        self.images[index].focalLength = val
                    }
                    if let px = headers["XPIXSZ"], let val = Double(px), val > 0 {
                        self.images[index].pixelSizeMicrons = val
                    }
                    // Plate-solved center coordinates for pointing offset detection
                    // CRVAL1/CRVAL2 = plate-solved WCS center (primary)
                    // RA/DEC = NINA writes target coords in decimal degrees (fallback)
                    if let ra = headers["CRVAL1"], let val = Double(ra) {
                        self.images[index].solvedRA = val
                    } else if self.images[index].solvedRA == nil,
                              let ra = headers["RA"], let val = Double(ra) {
                        self.images[index].solvedRA = val
                    }
                    if let dec = headers["CRVAL2"], let val = Double(dec) {
                        self.images[index].solvedDec = val
                    } else if self.images[index].solvedDec == nil,
                              let dec = headers["DEC"], let val = Double(dec) {
                        self.images[index].solvedDec = val
                    }
                    // WCS rotation from plate solve for meridian flip detection
                    if self.images[index].wcsRotation == nil {
                        if let crota2 = headers["CROTA2"], let val = Double(crota2) {
                            self.images[index].wcsRotation = val
                        } else if let cd11 = headers["CD1_1"], let cd12 = headers["CD1_2"],
                                  let v11 = Double(cd11), let v12 = Double(cd12) {
                            self.images[index].wcsRotation = atan2(-v12, v11) * 180.0 / .pi
                        }
                    }
                    // Full WCS plate-solve data for CD-matrix based display alignment.
                    // Used by DisplayAligner as the primary alignment path — exact,
                    // filter-independent, ~100x faster than star matching.
                    if let v = headers["CRPIX1"] { self.images[index].wcsCRPIX1 = Double(v) }
                    if let v = headers["CRPIX2"] { self.images[index].wcsCRPIX2 = Double(v) }
                    if let v = headers["CD1_1"]  { self.images[index].wcsCD11 = Double(v) }
                    if let v = headers["CD1_2"]  { self.images[index].wcsCD12 = Double(v) }
                    if let v = headers["CD2_1"]  { self.images[index].wcsCD21 = Double(v) }
                    if let v = headers["CD2_2"]  { self.images[index].wcsCD22 = Double(v) }
                    // Image dimensions from FITS headers — needed by WCS alignment to
                    // normalize the pixel-space transform into UV space. Populated here
                    // so applyWCSAlignment() doesn't have to wait for frame decode.
                    if self.images[index].width == nil,
                       let v = headers["NAXIS1"], let w = Int(v), w > 0 {
                        self.images[index].width = w
                    }
                    if self.images[index].height == nil,
                       let v = headers["NAXIS2"], let h = Int(v), h > 0 {
                        self.images[index].height = h
                    }
                    // Site coordinates for AIsaac location-aware language detection
                    // NINA writes SITELAT/SITELONG, some software uses LAT-OBS/LONG-OBS or OBSLAT/OBSLONG
                    if self.images[index].siteLatitude == nil {
                        for key in ["SITELAT", "LAT-OBS", "OBSLAT", "SITELAT "] {
                            if let raw = headers[key], let val = Double(raw) {
                                self.images[index].siteLatitude = val
                                break
                            }
                        }
                    }
                    if self.images[index].siteLongitude == nil {
                        for key in ["SITELONG", "LONG-OBS", "OBSLONG", "SITELONG"] {
                            if let raw = headers[key], let val = Double(raw) {
                                self.images[index].siteLongitude = val
                                break
                            }
                        }
                    }
                    // DATE-LOC (NINA local capture time) is authoritative — always overrides filename date.
                    // DATE-OBS is only used as fallback when no date exists yet (it may contain
                    // unexpected values in some FITS writers, e.g. session-start or file-creation date).
                    if let dateLoc = headers["DATE-LOC"], !dateLoc.isEmpty, dateLoc.count >= 10 {
                        // DATE-LOC: unconditional override (fixes NINA $$DATENOW$$ after-midnight issue)
                        self.images[index].date = String(dateLoc.prefix(10))
                        if dateLoc.count >= 19, let tIndex = dateLoc.firstIndex(of: "T") {
                            let timeStart = dateLoc.index(after: tIndex)
                            let timeEnd = dateLoc.index(timeStart, offsetBy: 8, limitedBy: dateLoc.endIndex) ?? dateLoc.endIndex
                            self.images[index].time = String(dateLoc[timeStart..<timeEnd])
                        }
                    } else if let dateObs = headers["DATE-OBS"], !dateObs.isEmpty, dateObs.count >= 10 {
                        // DATE-OBS: fallback only — fill in if no date set yet
                        self.images[index].date = self.images[index].date ?? String(dateObs.prefix(10))
                        if dateObs.count >= 19, let tIndex = dateObs.firstIndex(of: "T") {
                            let timeStart = dateObs.index(after: tIndex)
                            let timeEnd = dateObs.index(timeStart, offsetBy: 8, limitedBy: dateObs.endIndex) ?? dateObs.endIndex
                            self.images[index].time = self.images[index].time ?? String(dateObs[timeStart..<timeEnd])
                        }
                    }

                    // Twilight phase: classify sun position at capture time
                    // DATE-OBS is UTC (FITS standard), use with site coordinates
                    if self.images[index].twilightPhase == nil,
                       let lat = self.images[index].siteLatitude,
                       let lon = self.images[index].siteLongitude,
                       let dateObs = headers["DATE-OBS"], dateObs.count >= 19 {
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                        df.timeZone = TimeZone(identifier: "UTC")
                        df.locale = Locale(identifier: "en_US_POSIX")
                        // Try with fractional seconds first, then without
                        let cleanDate = String(dateObs.prefix(19))
                        if let utcDate = df.date(from: cleanDate) {
                            self.images[index].twilightPhase = SunCalculator.twilightPhase(
                                utcDate: utcDate, latitude: lat, longitude: lon
                            )
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
                self.headerEstimatedSecondsRemaining = nil
                self.headerReadStartTime = nil
                self.benchmarkStats.markHeaderEnrichEnd()
                self.sessionOverviewModel.updateStats(from: self.images)
                self.hasOSCImages = foundOSC
                // Compute moon illumination + target distance (needs date + coordinates from headers)
                self.computeMoonData()
                // Refine Bortle online (one call per unique coordinate, fire-and-forget)
                self.refineBortleOnline()
                // Compute relative quality scores now that all header metadata is available
                self.recomputeQualityScores()
                // Fix for MainActor Task delivery race (same as local path)
                self.scheduleQualityRescore()
                self.detectMeridianFlip()
                // Apply WCS-based alignment (fast, exact) now that headers are available.
                // For every frame with complete plate-solve data, overrides whatever the
                // star-based prefetch alignment computed earlier with an exact transform.
                self.applyWCSAlignment()

                // Fetch community baseline for cold-start calibration (async, non-blocking)
                if let fp = self.currentSetupFingerprint {
                    Task {
                        let baseline = await CommunityDetectionService.shared.fetchCommunityBaseline(fingerprint: fp)
                        await MainActor.run {
                            if let bl = baseline, self.communityBaseline == nil {
                                self.communityBaseline = bl
                                // Recompute scores with community baseline if local calibration insufficient
                                if !CalibrationDatabase.shared.profile(for: fp).hasLearned {
                                    self.recomputeQualityScores()
                                }
                            }
                        }
                    }
                }

                // Learn equipment/location/targets for AIsaac user profile
                var profile = AIsaacUserProfile.load()
                profile.learnFrom(images: self.images)
                profile.save()

                // Auto-reorder columns based on session composition (4 cases)
                // Always apply — each session type needs its own layout
                let uniqueTargets = Set(self.images.compactMap { $0.target?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                let uniqueFilters = Set(self.images.compactMap { $0.filter?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                let isMultiObject = uniqueTargets.count > 1
                let isMultiFilter = uniqueFilters.count > 1
                self.pendingColumnOrder = ColumnDefinition.recommendedColumnOrder(
                    isMultiObject: isMultiObject, isMultiFilter: isMultiFilter
                )
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

    /// Delayed quality rescore: catches frames whose MainActor metric callbacks
    /// haven't delivered yet when the initial scoring ran. Retries up to 3 times
    /// at 0.5s intervals until all analyzable frames have quality scores.
    private var rescoreRetryCount = 0
    private func scheduleQualityRescore() {
        rescoreRetryCount = 0
        scheduleQualityRescoreStep()
    }
    private func scheduleQualityRescoreStep() {
        guard rescoreRetryCount < 3 else { return }
        rescoreRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // Check if any frames have metrics but no quality score
            let unscoredWithMetrics = self.images.filter {
                $0.qualityBreakdown == nil && ($0.noiseMAD != nil || $0.computedStarCount != nil)
            }
            if !unscoredWithMetrics.isEmpty {
                self.recomputeQualityScores()
                self.needsTableRefresh = true
                self.sessionOverviewModel.updateStats(from: self.images)
                // Retry in case more metrics are still arriving
                self.scheduleQualityRescoreStep()
            }
        }
    }

    // Compute or recompute quality tiers for all images using QualityEstimator.
    // Called after header enrichment completes (FWHM, HFR, StarCount are now populated).
    // Also call this after adding a new folder to the session (new images may change group stats).
    func recomputeQualityScores() {
        // Recompute trailing scores with current focal length info (may have been populated
        // by header enrichment since initial star metrics were computed)
        for index in images.indices {
            if let details = images[index].starDetails, !details.isEmpty {
                let trailing = TrailingAnalyzer.analyze(
                    starDetails: details,
                    focalLength: images[index].focalLength,
                    pixelSizeMicrons: images[index].pixelSizeMicrons
                )
                if let t = trailing {
                    images[index].trailingScore = t.trailingScore
                    images[index].trailingPA = t.consensusPA
                    images[index].trailingAxisRatio = t.medianAxisRatio
                    images[index].trailingConsensus = t.consensusFraction
                }
            }
        }

        // Query historical baselines from Frame History Database (if enough past data exists)
        let histBaselines: HistoricalBaselines? = {
            guard let setupHash = currentSetupFingerprint?.hash else { return nil }
            let records = try? FrameHistoryDatabase.shared.historicalFrames(
                setupHash: setupHash,
                excludingSession: currentSessionId
            )
            guard let records, records.count >= 30 else { return nil }
            return HistoricalBaselines.build(from: records)
        }()

        let scores = QualityEstimator.computeScores(
            for: images,
            calibrationDB: CalibrationDatabase.shared,
            fingerprint: currentSetupFingerprint,
            communityBaseline: communityBaseline,
            historicalBaselines: histBaselines
        )
        for index in images.indices {
            images[index].qualityBreakdown = scores[images[index].url]
        }
        // Notify table that quality column cells need redrawing
        needsTableRefresh = true

        // Re-sort directly whenever quality z-scores change.
        // Previously used needsQualityResort flag consumed by FileListView.updateNSView,
        // but the indirect mechanism had timing issues (flag consumed before metrics were ready).
        // Direct sort ensures the correct order immediately after scoring.
        let hasStarMetrics = images.contains { $0.computedStarCount != nil || $0.computedFWHM != nil }
        if hasStarMetrics && !scores.isEmpty {
            let uniqueTargets = Set(images.compactMap { $0.target?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let uniqueFilters = Set(images.compactMap { $0.filter?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let order = ColumnDefinition.recommendedColumnOrder(
                isMultiObject: uniqueTargets.count > 1, isMultiFilter: uniqueFilters.count > 1
            )
            applySortByColumnOrder(order)
        }

        let scored = scores.count
        let total  = images.count
        let lockedCount = scores.values.filter { $0.isLockedKeep }.count
        if scored > 0 {
            var msg = "Quality scored: \(scored)/\(total) images in \(countGroups(scores)) group(s)"
            if lockedCount > 0 {
                msg += " — \(lockedCount) locked KEEP"
            }
            // Show calibration learning status
            if let fp = currentSetupFingerprint {
                msg += " [\(CalibrationDatabase.shared.learningStatus(for: fp))]"
            }
            // Append session guidance hints if applicable
            if let guidance = generateSessionGuidance() {
                msg += " | \(guidance)"
            }
            statusMessage = msg
        }

        updateConvergence()

        // Save frame records to history database (async, non-blocking)
        saveToFrameHistory()
    }

    // MARK: - Frame History Persistence

    /// Compute moon phase and distance for all images that have date + location data.
    /// Called during header enrichment when site coordinates become available.
    private func computeMoonData() {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.timeZone = TimeZone(identifier: "UTC")

        for index in images.indices {
            guard let dateStr = images[index].date, let timeStr = images[index].time else { continue }
            let dateTimeStr = "\(dateStr) \(timeStr)"
            guard let utcDate = fallbackFormatter.date(from: dateTimeStr) else { continue }

            // Moon illumination (needs only date, no location)
            images[index].moonIllumination = MoonCalculator.illumination(utcDate: utcDate)

            // Moon-target distance (needs target RA/Dec)
            if let solvedRA = images[index].solvedRA, let solvedDec = images[index].solvedDec {
                images[index].moonDistance = MoonCalculator.moonTargetDistance(
                    utcDate: utcDate, targetRADeg: solvedRA, targetDecDeg: solvedDec
                )
            } else if let ra = images[index].objctRA, let dec = images[index].objctDec {
                images[index].moonDistance = MoonCalculator.moonTargetDistance(
                    utcDate: utcDate, targetRA: ra, targetDec: dec
                )
            }

            // Bortle class (needs site coordinates)
            if images[index].bortleClass == nil,
               let lat = images[index].siteLatitude,
               let lon = images[index].siteLongitude {
                // Local grid instant (integer precision)
                images[index].bortleClass = BortleEstimator.estimate(latitude: lat, longitude: lon).map(Double.init)
            }

            // Canonical target name (normalized for grouping across sessions)
            if images[index].canonicalTarget == nil, let target = images[index].target {
                images[index].canonicalTarget = TargetCatalog.canonicalName(target)
            }
            // Major (parent) target for sub-target association
            if images[index].majorTarget == nil, let canonical = images[index].canonicalTarget {
                images[index].majorTarget = TargetCatalog.majorTarget(canonical)
            }
        }
    }

    /// Refine Bortle values via Supabase (one call per unique lat/lon, not per frame).
    /// Called once after header enrichment completes. Fire-and-forget.
    private func refineBortleOnline() {
        // Collect unique coordinates
        var uniqueCoords: [String: (lat: Double, lon: Double, indices: [Int])] = [:]
        for (i, img) in images.enumerated() {
            guard let lat = img.siteLatitude, let lon = img.siteLongitude else { continue }
            let key = String(format: "%.2f,%.2f", lat, lon)
            if uniqueCoords[key] == nil {
                uniqueCoords[key] = (lat, lon, [i])
            } else {
                uniqueCoords[key]!.indices.append(i)
            }
        }
        guard !uniqueCoords.isEmpty else { return }

        Task.detached(priority: .utility) {
            for (_, coord) in uniqueCoords {
                if let bortle = await BortleEstimator.estimateOnline(latitude: coord.lat, longitude: coord.lon) {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        for idx in coord.indices where idx < self.images.count {
                            self.images[idx].bortleClass = bortle
                        }
                    }
                }
            }
        }
    }

    /// Save all frame records to the Frame History Database.
    /// Called after quality scoring completes. Runs on a background thread.
    private func saveToFrameHistory() {
        guard !images.isEmpty else { return }
        let sessionId = currentSessionId
        let setupHash = currentSetupFingerprint?.hash
        let sessionPath = sessionRootURL?.path ?? ""

        // Build records from current image state
        let records: [FrameRecord] = images.compactMap { entry in
            guard let hash = entry.fileHash else { return nil }
            return FrameRecord.from(entry: entry, fileHash: hash, sessionId: sessionId, setupHash: setupHash)
        }

        guard !records.isEmpty else { return }

        // Build session record
        let trashCount = images.filter { $0.qualityTier == .trash }.count
        let deletedCount = images.filter { $0.isMarkedForDeletion }.count
        let sessionRecord = SessionRecord(
            id: sessionId,
            sessionPath: sessionPath,
            observingNight: images.first?.observingNight,
            setupHash: setupHash,
            telescope: images.first?.telescope,
            camera: images.first?.camera,
            target: images.first?.target,
            frameCount: images.count,
            trashCount: trashCount,
            deletedCount: deletedCount,
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )

        // Save on background to avoid blocking UI
        Task.detached {
            do {
                try FrameHistoryDatabase.shared.saveFrameRecords(records)
                try FrameHistoryDatabase.shared.saveSessionRecord(sessionRecord)
                // Export to iCloud after save
                FrameHistoryDatabase.shared.exportToICloud()
                print("FrameHistory: saved \(records.count) frames for session \(sessionId)")
            } catch {
                print("FrameHistory: save failed: \(error)")
            }
        }
    }

    /// Generate session guidance hints about scoring accuracy
    private func generateSessionGuidance() -> String? {
        guard !images.isEmpty else { return nil }

        // Build group sizes: filter+object+exposure
        var groupSizes: [String: Int] = [:]
        for entry in images {
            let f = (entry.filter ?? "").uppercased()
            let t = (entry.target ?? "").trimmingCharacters(in: .whitespaces)
            let e = entry.exposure.map { Int($0.rounded()) } ?? 0
            let key = "\(f)|\(t)|\(e)"
            groupSizes[key, default: 0] += 1
        }

        var hints: [String] = []

        // Check for small groups
        let tooSmall = groupSizes.filter { $0.value < QualityEstimator.minGroupSize }.count
        let small = groupSizes.filter { $0.value >= QualityEstimator.minGroupSize && $0.value < 8 }.count
        if tooSmall > 0 {
            hints.append("\(tooSmall) group(s) too small for scoring (<\(QualityEstimator.minGroupSize) frames)")
        } else if small > 0 {
            hints.append("\(small) group(s) with reduced confidence (<8 frames)")
        }

        // Suggest multi-night for better accuracy
        let uniqueNights = Set(images.compactMap { $0.observingNight })
        if uniqueNights.count <= 1 && images.count > 10 {
            hints.append("Tip: loading multiple nights improves scoring accuracy")
        }

        return hints.isEmpty ? nil : hints.joined(separator: " | ")
    }

    /// Count distinct groups that produced at least one score
    private func countGroups(_ scores: [URL: QualityBreakdown]) -> Int {
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

    // MARK: - Live SNR Retention

    /// Recompute SNR retention after mark/unmark toggles.
    /// Uses cached snrSquared from QualityBreakdown for O(N) performance.
    /// Falls back to simple frame count ratio when noise stats are unavailable.
    func recomputeSNRRetention() {
        // Group images by filter+target+exposure (same grouping as QualityEstimator)
        struct GroupKey: Hashable {
            let filter: String; let target: String; let exposure: Int
        }

        var groups: [GroupKey: (totalSNRSq: Double, retainedSNRSq: Double, total: Int, marked: Int)] = [:]
        var fallbackTotal = 0
        var fallbackRetained = 0
        var hasSNRData = false

        for entry in images {
            let key = GroupKey(
                filter: (entry.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces),
                target: (entry.target ?? "").trimmingCharacters(in: .whitespaces),
                exposure: entry.exposure.map { Int($0.rounded()) } ?? 0
            )

            var g = groups[key, default: (0, 0, 0, 0)]
            g.total += 1
            if entry.isMarkedForDeletion { g.marked += 1 }

            if let snrSq = entry.qualityBreakdown?.snrSquared {
                hasSNRData = true
                g.totalSNRSq += snrSq
                if !entry.isMarkedForDeletion {
                    g.retainedSNRSq += snrSq
                }
            }
            groups[key] = g

            fallbackTotal += 1
            if !entry.isMarkedForDeletion { fallbackRetained += 1 }
        }

        if hasSNRData {
            // Weighted average retention across groups (weighted by total SNR²)
            var weightedRetention = 0.0
            var totalWeight = 0.0
            var detailLines: [String] = []

            for (key, g) in groups.sorted(by: { $0.key.filter < $1.key.filter }) {
                guard g.totalSNRSq > 0 else { continue }
                let retention = (g.retainedSNRSq / g.totalSNRSq).squareRoot() * 100.0
                weightedRetention += retention * g.totalSNRSq
                totalWeight += g.totalSNRSq

                if g.marked > 0 {
                    let filterLabel = key.filter.isEmpty ? "All" : key.filter
                    detailLines.append("  \(filterLabel): \(String(format: "%.1f", retention))% (\(g.marked) of \(g.total) marked)")
                }
            }

            let overall = totalWeight > 0 ? weightedRetention / totalWeight : 100.0
            snrRetention = overall

            if detailLines.isEmpty {
                snrRetentionDetail = "SNR Retention: 100%\nNo frames marked for deletion."
            } else {
                let lossPercent = 100.0 - overall
                let markedCount = images.filter { $0.isMarkedForDeletion }.count
                let totalExposure = images.reduce(0.0) { $0 + ($1.exposure ?? 0) }
                let markedExposure = images.filter { $0.isMarkedForDeletion }.reduce(0.0) { $0 + ($1.exposure ?? 0) }
                let integrationLoss = totalExposure > 0 ? markedExposure / totalExposure * 100.0 : 0
                let integrationStr = markedExposure >= 3600 ? String(format: "%.1fh", markedExposure / 3600) : String(format: "%.0fm", markedExposure / 60)
                let totalStr = totalExposure >= 3600 ? String(format: "%.1fh", totalExposure / 3600) : String(format: "%.0fm", totalExposure / 60)

                var tooltip = "SNR Retention: \(String(format: "%.1f", overall))%\n"
                tooltip += detailLines.joined(separator: "\n")
                tooltip += "\n\nRemoving \(markedCount) frames loses \(String(format: "%.1f", lossPercent))% SNR"
                tooltip += "\nwhile removing \(integrationStr) of \(totalStr) total (\(String(format: "%.0f", integrationLoss))% integration)."
                if lossPercent < integrationLoss * 0.5 {
                    tooltip += "\n→ Good trade-off: mostly cutting low-quality frames."
                } else if lossPercent > integrationLoss * 0.9 {
                    tooltip += "\n→ Caution: cutting nearly as much SNR as integration time."
                }
                snrRetentionDetail = tooltip
            }
        } else {
            // Fallback: simple frame count ratio
            snrRetention = fallbackTotal > 0 ? Double(fallbackRetained) / Double(fallbackTotal) * 100.0 : 100.0
            snrRetentionDetail = "SNR Retention: \(String(format: "%.1f", snrRetention))%\n(Estimated from frame count — noise stats not yet available)"
        }
    }

    // MARK: - Convergence & Stack Readiness

    /// Update culling status after mark/unmark or quality recomputation.
    /// Simple actionable state: how many trash remain, SNR warning, convergence.
    func updateConvergence() {
        let hasScores = images.contains { $0.qualityBreakdown != nil }

        guard hasScores else {
            cullingStatus = nil
            isConverged = false
            convergenceResult = nil
            return
        }

        // Run full convergence analysis
        let result = ConvergenceDetector.analyze(
            entries: images,
            snrRetention: snrRetention,
            calibrationDB: CalibrationDatabase.shared,
            fingerprint: currentSetupFingerprint
        )
        convergenceResult = result
        isConverged = result.isConverged

        // Map convergence result to status bar display
        let unmarkedTrash = images.filter { !$0.isMarkedForDeletion && $0.qualityTier == .trash }.count
        let unmarkedBorderline = images.filter { !$0.isMarkedForDeletion && $0.qualityTier == .borderline }.count

        if unmarkedTrash > 0 {
            cullingStatus = CullingStatus(level: .trash, text: "\(unmarkedTrash)\u{00D7} trash remaining")
        } else if result.snrStopReached {
            let snrLossPct = 100.0 - snrRetention
            let totalExposure = images.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
            let markedExposure = images.filter { $0.isMarkedForDeletion }.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
            let integrationLossPct = totalExposure > 0 ? markedExposure / totalExposure * 100 : 0
            cullingStatus = CullingStatus(
                level: .warning,
                text: "SNR: -\(String(format: "%.0f", snrLossPct))% vs integration -\(String(format: "%.0f", integrationLossPct))%"
            )
        } else if result.isConverged {
            let spreadStr = String(format: "%.2f", result.qualitySpread)
            if unmarkedBorderline > 0 {
                cullingStatus = CullingStatus(level: .done, text: "Uniform (spread \(spreadStr)) — \(unmarkedBorderline) borderline remain")
            } else {
                cullingStatus = CullingStatus(level: .done, text: "Culling complete (spread \(spreadStr))")
            }
        } else if unmarkedBorderline > 0 {
            cullingStatus = CullingStatus(level: .done, text: "Culling done (\(unmarkedBorderline) borderline remain)")
        } else {
            cullingStatus = CullingStatus(level: .done, text: "Culling complete")
        }
    }

    // MARK: - SSWEIGHT Export

    /// Export SSWEIGHT keyword to FITS/XISF headers for WBPP integration.
    /// Operates on highlighted files if any are selected, otherwise all scored files.
    /// Weight formula: clamp(0, 100, 50 + qualityZScore * 20) * (1 - trailingScore * 0.5 * filterTrailingMult)
    func exportSSWEIGHT() {
        // Use selected files if highlighted, otherwise all scored images
        let selected = selectedEntries.filter { $0.qualityBreakdown != nil }
        let scoredImages = selected.isEmpty
            ? images.filter { $0.qualityBreakdown != nil }
            : selected
        let scope = selected.isEmpty ? "all \(scoredImages.count)" : "\(scoredImages.count) selected"
        guard !scoredImages.isEmpty else {
            statusMessage = "No quality scores available — load and cache images first"
            return
        }

        // Confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Export SSWEIGHT to \(scope) files?"
        alert.informativeText = "This writes the SSWEIGHT keyword (float, 0-100) into each file's header.\n\nPixInsight WBPP can use this for weighted integration.\n\nA CSV backup will also be created."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var succeeded = 0
        var failed = 0
        var csvLines: [String] = ["Filename,SSWEIGHT,PSFSWGHT,QualityTier,TrailingScore,FWHM,HFR,Ecc,SNR,StarCount"]

        for entry in scoredImages {
            guard let bd = entry.qualityBreakdown else { continue }

            // Compute SSWEIGHT: 50 + z*20, penalized by trailing (filter-aware)
            var weight = 50.0 + bd.combinedZScore * 20.0
            if let ts = entry.trailingScore {
                weight *= (1.0 - ts * 0.5 * bd.filterTrailingMultiplier)
            }
            // Locked KEEP frames get minimum weight of 50
            if bd.isLockedKeep {
                weight = max(weight, 50.0)
            }
            weight = max(0.0, min(100.0, weight))

            let weightStr = String(format: "%.2f", weight)
            let path = entry.decodingURL.path

            // Compute PSFSignalWeight: psfFluxSum / (noiseMAD² + ε)
            // Normalized to ~0-100 range via log scaling for PI compatibility
            var psfswStr = ""
            if let flux = entry.psfFluxSum, let mad = entry.noiseMAD, mad > 0 {
                // PSF Signal Weight: total star flux normalized by noise²
                // Log scale compresses the dynamic range to a usable weight
                let rawPSFSW = flux / (Double(mad) * Double(mad) + 1e-10)
                let psfsw = max(0.0, min(100.0, log10(max(1, rawPSFSW)) * 10.0))
                psfswStr = String(format: "%.2f", psfsw)
            }

            // Write SSWEIGHT and PSFSW to file header
            var writeOK = false
            if entry.isXISF {
                let r1 = write_xisf_keyword(path, path, "SSWEIGHT", weightStr)
                writeOK = r1.success == 1
                if !psfswStr.isEmpty {
                    _ = write_xisf_keyword(path, path, "PSFSWGHT", psfswStr)
                }
            } else if entry.isFITS {
                let r1 = write_fits_keyword(path, "SSWEIGHT", weightStr)
                writeOK = r1.success == 1
                if !psfswStr.isEmpty {
                    _ = write_fits_keyword(path, "PSFSWGHT", psfswStr)
                }
            } else {
                continue
            }

            if writeOK {
                succeeded += 1
            } else {
                failed += 1
            }

            // CSV line
            let tierName = bd.tier == .excellent ? "excellent" : bd.tier == .good ? "good" : bd.tier == .borderline ? "borderline" : "trash"
            let ts = entry.trailingScore.map { String(format: "%.3f", $0) } ?? ""
            let fwhm = entry.displayFWHM.map { String(format: "%.2f", $0) } ?? ""
            let hfr = entry.displayHFR.map { String(format: "%.2f", $0) } ?? ""
            let ecc = entry.computedEccentricity.map { String(format: "%.3f", $0) } ?? ""
            let snr: String
            if let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 {
                snr = String(format: "%.1f", Double(med) / Double(mad))
            } else {
                snr = ""
            }
            let stars = entry.displayStarCount.map { "\($0)" } ?? ""
            csvLines.append("\(entry.filename),\(weightStr),\(psfswStr),\(tierName),\(ts),\(fwhm),\(hfr),\(ecc),\(snr),\(stars)")
        }

        // Write CSV backup
        if let rootURL = sessionRootURL {
            let csvURL = rootURL.appendingPathComponent("AstroBlinkV2_SSWEIGHT.csv")
            let csvContent = csvLines.joined(separator: "\n")
            try? csvContent.write(to: csvURL, atomically: true, encoding: .utf8)
        }

        if failed > 0 {
            statusMessage = "SSWEIGHT exported: \(succeeded) files (\(failed) failed)"
        } else {
            statusMessage = "SSWEIGHT exported to \(succeeded) files + CSV backup"
        }
    }

    // SSWEIGHT removal: use Batch Rename → scope "Delete Key", keyword "SSWEIGHT"
    // No separate removeSSWEIGHT() needed — batch rename handles deletion with
    // backup, undo, and verification. CSV cleanup is separate if needed.

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
        if let rendererImage = renderer?.currentImage, let mtkView = findMTKView(), let renderer = renderer {
            let stfParams = STFCalculator.calculate(from: rendererImage, targetBackground: value)
            renderer.setSTFParams(stfParams)
            // If locked, update the locked params too so all images use the new stretch
            if isSTFLocked { renderer.lockSTF() }
            mtkView.needsDisplay = true
            return
        }

        // If showing a cached preview, decode raw data so the slider change is visible
        guard let entry = selectedImage, let device = device else { return }
        let targetURL = entry.url
        let decodeURL = entry.decodingURL
        let bayerPattern = debayerEnabled ? entry.bayerPattern : nil
        let locked = isSTFLocked

        currentDecodeTask?.cancel()
        currentDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = ImageDecoder.decode(url: decodeURL, device: device)
            await MainActor.run {
                guard let self = self, self.selectedImage?.url == targetURL else { return }
                if case .success(let decoded) = result {
                    self.currentDecodedImage = decoded
                    if let mtkView = self.findMTKView(), let renderer = self.renderer {
                        renderer.setImage(decoded, in: mtkView,
                                          bayerPattern: bayerPattern,
                                          targetBackground: value)
                        // If locked, update the locked params with new stretch
                        if locked { renderer.lockSTF() }
                        renderer.setPostProcessParams(
                            sharpening: self.sharpening, contrast: self.contrast,
                            darkLevel: self.darkLevel)
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

    // Determine whether the current image needs 180° rotation to match the reference
    // orientation for its target group. Uses XOR logic:
    //   piersideFlipped XOR rotatorFlipped → needs visual flip
    //   Both flipped = cancel out. Neither flipped = no flip.
    func shouldRotateForMeridian(_ entry: ImageEntry) -> Bool {
        guard autoMeridianEnabled, hasMeridianFlip else { return false }

        // Find reference for this target
        let targetKey = canonicalTargetKey(for: entry)
        guard let ref = targetOrientationRefs[targetKey] else { return false }

        // OR logic: if ANY of the three available signals indicates a flip, rotate.
        // This is the correct behavior for 99% of amateur setups (ASIAIR/AM5, physical rotators,
        // no-rotator mounts). The previous XOR logic was incorrect for ASIAIR/AM5 where BOTH
        // PIERSIDE and ROTATOR change during a flip — XOR cancelled them out.

        // Signal 1: PIERSIDE change
        if let refSide = ref.pierSide, let entrySide = entry.pierSide,
           refSide.uppercased() != entrySide.uppercased() {
            return true
        }

        // Signal 2: ROTATOR angle change (any large rotation ≥ 90° = flip)
        if let refAngle = ref.rotatorAngle, let entryAngle = entry.rotatorAngle {
            let diff = angleDifference(entryAngle, refAngle)
            if diff >= 90.0 { return true }
        }

        // Signal 3: WCS rotation from plate solve (any change ≥ 90° = flip)
        if let refWCS = ref.wcsRotation, let entryWCS = entry.wcsRotation {
            let diff = angleDifference(entryWCS, refWCS)
            if diff >= 90.0 { return true }
        }

        return false
    }

    // Update display alignment for the currently displayed image.
    // Preference order:
    //   1. Star-based alignment transform (computed by DisplayAligner in prefetch pipeline)
    //   2. Header-based 180° flip (fallback when star alignment hasn't completed or failed)
    //   3. Identity (no correction)
    private func updateMeridianRotation() {
        guard let renderer = renderer else { return }
        guard let entry = selectedImage else {
            renderer.displayTransform = .identity
            renderer.rotate180 = false
            if let mtkView = findMTKView() { mtkView.needsDisplay = true }
            return
        }

        if autoMeridianEnabled, let transform = entry.alignmentTransform {
            // Star-based alignment succeeded — use the precise per-frame transform
            renderer.displayTransform = transform
            renderer.rotate180 = false
        } else if autoMeridianEnabled, shouldRotateForMeridian(entry) {
            // Fall back to header-based 180° flip
            renderer.displayTransform = .identity
            renderer.rotate180 = true
        } else {
            renderer.displayTransform = .identity
            renderer.rotate180 = false
        }

        if let mtkView = findMTKView() { mtkView.needsDisplay = true }
    }

    // Assign unique 1-based session indices to all images
    private func assignSessionIndices() {
        for i in images.indices {
            images[i].sessionIndex = i + 1  // 1-based for user display
        }
        // Reset AIsaac state tracking when a new session is loaded
        AIsaacWindowController.shared.model.resetStateTracking()
        AIsaacWindowController.shared.model.clearConversation()
    }

    // Detect orientation changes across a session (multi-night, multi-target).
    // Builds per-target reference from the first image of each target group.
    // Uses XOR logic: piersideFlipped XOR rotatorFlipped = needs visual correction.
    func detectMeridianFlip() {
        targetOrientationRefs.removeAll()

        // Build per-target reference orientation from first image of each target
        for img in images {
            let key = canonicalTargetKey(for: img)
            if targetOrientationRefs[key] == nil {
                targetOrientationRefs[key] = OrientationRef(
                    pierSide: img.pierSide,
                    rotatorAngle: img.rotatorAngle,
                    wcsRotation: img.wcsRotation
                )
            }
        }

        // Detect if ANY image in ANY target group needs flipping.
        // OR logic: any of PIERSIDE change, large rotator change (>=90°), or WCS rotation
        // change (>=90°) triggers a flip. This handles ASIAIR/AM5, physical rotators, and
        // plate-solved setups uniformly.
        var flipCount = 0
        var totalChecked = 0
        for img in images {
            let key = canonicalTargetKey(for: img)
            guard let ref = targetOrientationRefs[key] else { continue }

            let piersideFlipped: Bool
            if let refSide = ref.pierSide, let side = img.pierSide {
                piersideFlipped = refSide.uppercased() != side.uppercased()
            } else {
                piersideFlipped = false
            }

            var rotatorDiff: Double?
            let rotatorFlipped: Bool
            if let refAngle = ref.rotatorAngle, let angle = img.rotatorAngle {
                let diff = angleDifference(angle, refAngle)
                rotatorDiff = diff
                rotatorFlipped = diff >= 90.0
            } else {
                rotatorFlipped = false
            }

            var wcsDiff: Double?
            let wcsFlipped: Bool
            if let refWCS = ref.wcsRotation, let wcs = img.wcsRotation {
                let diff = angleDifference(wcs, refWCS)
                wcsDiff = diff
                wcsFlipped = diff >= 90.0
            } else {
                wcsFlipped = false
            }

            let needsFlip = piersideFlipped || rotatorFlipped || wcsFlipped
            if needsFlip { flipCount += 1 }
            totalChecked += 1

            // Detailed logging for flip-relevant images (any signal changed or rotator moved >30°)
            if piersideFlipped || rotatorFlipped || wcsFlipped || (rotatorDiff ?? 0) > 30 {
                let parts = [
                    rotatorDiff.map { String(format: "rot diff=%.1f°", $0) },
                    wcsDiff.map { String(format: "wcs diff=%.1f°", $0) },
                    img.pierSide.map { "pier=\($0)" }
                ].compactMap { $0 }.joined(separator: ", ")
                print("[Meridian] \(img.filename): \(parts), decision=\(needsFlip ? "FLIP" : "NO_FLIP")")
            }
        }

        hasMeridianFlip = flipCount > 0

        if hasMeridianFlip {
            print("[Meridian] Orientation correction needed: \(flipCount)/\(totalChecked) images across \(targetOrientationRefs.count) target(s)")
            for (target, ref) in targetOrientationRefs {
                let refDesc = [
                    ref.pierSide.map { "pier=\($0)" },
                    ref.rotatorAngle.map { String(format: "rot=%.0f°", $0) },
                    ref.wcsRotation.map { String(format: "wcs=%.0f°", $0) }
                ].compactMap { $0 }.joined(separator: ", ")
                print("[Meridian]   \(target): ref (\(refDesc))")
            }
        } else {
            print("[Meridian] No orientation differences detected (\(totalChecked) images, \(targetOrientationRefs.count) target(s))")
        }
    }

    /// Canonical target key for orientation grouping. Uses target name or "UNKNOWN".
    private func canonicalTargetKey(for entry: ImageEntry) -> String {
        if let target = entry.target, !target.isEmpty {
            return TargetCatalog.canonicalName(target)
        }
        return "UNKNOWN"
    }

    /// Apply WCS-based alignment transforms to all frames that have complete plate-solve data.
    /// Runs on the main actor after header enrichment completes, when CRVAL/CRPIX/CD matrix
    /// values are finally populated on every ImageEntry.
    ///
    /// The math is direct matrix algebra (CD_ref⁻¹ × CD_frame for rotation/scale, plus CRVAL
    /// offsets scaled by cos(dec) for translation) and takes microseconds per frame. Overrides
    /// any star-matching-based transform computed earlier in the prefetch pipeline because
    /// the WCS-based transform is mathematically exact while star matching is heuristic.
    ///
    /// Smart reference selection: picks the frame closest to the median CRVAL across all
    /// frames in the target group. This means the reference represents the typical pointing,
    /// not whichever frame happened to be first in the array — outliers (e.g. a frame where
    /// the mount lost center) won't accidentally become the reference everyone else aligns to.
    ///
    /// Frames without WCS retain their prefetch-computed star-matching transform (or nil).
    private func applyWCSAlignment() {
        // Collect entries that have complete WCS data, grouped by target
        var targetEntries: [String: [(idx: Int, wcs: DisplayAligner.WCSData)]] = [:]
        for (idx, entry) in images.enumerated() {
            guard let wcs = PrefetchCache.wcsDataIfComplete(entry) else { continue }
            let key = canonicalTargetKey(for: entry)
            targetEntries[key, default: []].append((idx, wcs))
        }

        guard !targetEntries.isEmpty else { return }

        var updatedCount = 0
        var fallbackCount = 0
        var referenceLog: [String] = []

        for (targetKey, entries) in targetEntries {
            guard !entries.isEmpty else { continue }

            // Smart reference selection: find the frame closest to the median CRVAL.
            // Median is robust against outliers (a frame where the mount lost center
            // by 50% won't drag the median much, so the chosen reference stays in the
            // bulk of the pointing distribution).
            let sortedRA  = entries.map { $0.wcs.crval1 }.sorted()
            let sortedDec = entries.map { $0.wcs.crval2 }.sorted()
            let medianRA  = sortedRA[sortedRA.count / 2]
            let medianDec = sortedDec[sortedDec.count / 2]

            var refIdx = entries[0].idx
            var refWCS = entries[0].wcs
            var bestDistSq = Double.infinity
            for entry in entries {
                let dx = entry.wcs.crval1 - medianRA
                let dy = entry.wcs.crval2 - medianDec
                let distSq = dx * dx + dy * dy
                if distSq < bestDistSq {
                    bestDistSq = distSq
                    refIdx = entry.idx
                    refWCS = entry.wcs
                }
            }
            referenceLog.append("\(targetKey)→\(images[refIdx].filename)")
            let refRotator = images[refIdx].rotatorAngle

            // Apply WCS-based transform to every frame in this target group
            for entry in entries {
                guard let width = images[entry.idx].width,
                      let height = images[entry.idx].height,
                      width > 0, height > 0
                else { continue }

                guard let pixelTransform = DisplayAligner.transformFromWCS(
                    frame: entry.wcs, reference: refWCS
                ) else { continue }

                let inv = pixelTransform.inverse ?? .identity
                images[entry.idx].alignmentTransform = inv.normalized(width: width, height: height)
                updatedCount += 1
            }

            // Fallback for frames in this target that don't have WCS but DO have a
            // rotator angle in their headers: compute a synthetic rotation transform
            // from the rotator angle delta vs the reference's rotator. This is less
            // accurate than full WCS (no precise translation) but correctly handles
            // the rotation, which is what users notice most.
            if let refRot = refRotator {
                for idx in images.indices where canonicalTargetKey(for: images[idx]) == targetKey {
                    // Skip frames that already have alignment from the WCS pass
                    guard images[idx].alignmentTransform == nil,
                          let frameRot = images[idx].rotatorAngle,
                          let width = images[idx].width,
                          let height = images[idx].height,
                          width > 0, height > 0
                    else { continue }

                    // Rotation needed: frame_rotator - ref_rotator (in degrees)
                    let deltaDeg = frameRot - refRot
                    let theta = Float(deltaDeg * .pi / 180.0)
                    let cosT = cosf(theta)
                    let sinT = sinf(theta)
                    let W = Float(width)
                    let H = Float(height)
                    // Pixel-space rotation around image center (W/2, H/2):
                    //   p' = R*(p - c) + c = R*p + (c - R*c)
                    let txPix = W * 0.5 * (1 - cosT) + H * 0.5 * sinT
                    let tyPix = -W * 0.5 * sinT + H * 0.5 * (1 - cosT)
                    let pixelTransform = AffineTransform2D(
                        a: cosT, b: -sinT, tx: txPix,
                        c: sinT, d: cosT, ty: tyPix
                    )
                    let inv = pixelTransform.inverse ?? .identity
                    images[idx].alignmentTransform = inv.normalized(width: width, height: height)
                    fallbackCount += 1
                }
            }
        }

        print("[AutoRotate] WCS alignment: \(updatedCount) frames via WCS, \(fallbackCount) via rotator-fallback, \(targetEntries.count) target group(s); reference: \(referenceLog.joined(separator: ", "))")
        if let selected = selectedImage, selected.alignmentTransform != nil {
            updateMeridianRotation()
        }
        needsTableRefresh = true
    }

    // MARK: - Filename-based Grouping Helpers (for DisplayAligner)

    /// Extract a canonical filter key for grouping. Tries entry.filter first (which the
    /// parser fills when header data is available), then falls back to parsing the filename
    /// for common filter tokens like "_B_", "_L_", "_Ha_", etc. Returns "?" only when both
    /// sources fail, which is safe but collapses all such frames into one group.
    static func extractFilterKey(from entry: ImageEntry) -> String {
        if let f = entry.filter, !f.isEmpty {
            return f.uppercased()
        }
        // Common astro filter tokens, longer ones first so "Ha" wins over "H"
        let filterTokens = [
            "SII", "Ha", "OIII", "Hbeta", "NII",  // narrowband
            "Lum", "Luminance",                    // luminance
            "L", "R", "G", "B", "H", "O", "S",     // broadband + single-letter narrowband
            "UV", "IR", "CLS", "UHC", "Lpro", "Lextreme", "Duo", "Tri", "Quad"
        ]
        let lowered = entry.filename.lowercased()
        for token in filterTokens {
            let needle = "_\(token.lowercased())_"
            if lowered.contains(needle) {
                return token.uppercased()
            }
        }
        return "?"
    }

    /// Extract exposure (rounded to integer seconds) for grouping. Tries entry.exposure first,
    /// then parses the filename for patterns like "180.0s", "300s", "60.00s".
    static func extractExposureKey(from entry: ImageEntry) -> Int {
        if let exp = entry.exposure, exp > 0 {
            return Int(exp.rounded())
        }
        // Regex: one or more digits, optional decimal, followed by "s" and end-of-token
        // Common patterns: "_180.0s_", "_300s_", "_60.00s_"
        let pattern = #"_(\d+(?:\.\d+)?)s[_.]"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
            in: entry.filename,
            range: NSRange(entry.filename.startIndex..., in: entry.filename)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: entry.filename) {
            let str = String(entry.filename[range])
            if let val = Double(str) {
                return Int(val.rounded())
            }
        }
        return 0
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

    // True pixel zoom percentage: fitScale × zoomScale × 100
    private func trueZoomPct() -> CGFloat? {
        guard let renderer = renderer, let mtkView = findMTKView() else { return nil }
        let fitScale = renderer.fitScale(viewBounds: mtkView.bounds.size)
        return fitScale * renderer.zoomScale * 100
    }

    private func setTrueZoom(_ pct: CGFloat) {
        guard let renderer = renderer, let mtkView = findMTKView() else { return }
        let fitScale = renderer.fitScale(viewBounds: mtkView.bounds.size)
        guard fitScale > 0 else { return }
        renderer.zoomScale = (pct / 100.0) / fitScale
        renderer.panOffset = .zero
        mtkView.needsDisplay = true
        (mtkView as? ZoomableMTKView)?.updateZoomLabel()
        statusMessage = String(format: "Zoom: %.0f%%", pct)
    }

    // Zoom in by 25% true-pixel step (Cmd+)
    func zoomIn() {
        guard let current = trueZoomPct() else { return }
        let nextPct = (floor(current / 25.0) + 1) * 25
        setTrueZoom(min(nextPct, 800))
    }

    // Zoom out by 25% true-pixel step (Cmd-)
    func zoomOut() {
        guard let current = trueZoomPct() else { return }
        let nextPct = (ceil(current / 25.0) - 1) * 25
        setTrueZoom(max(nextPct, 25))
    }

    // Reset zoom to fit-to-view
    func resetZoom() {
        guard let renderer = renderer, let mtkView = findMTKView() else { return }
        renderer.resetZoom()
        mtkView.needsDisplay = true
        (mtkView as? ZoomableMTKView)?.updateZoomLabel()
        statusMessage = "Zoom: Fit to view"
    }

    // Cmd+1: zoom to 100% (1:1 actual pixels — Photoshop standard)
    func zoomPresetSmall() {
        setTrueZoom(100)
    }

    // Cmd+2: zoom to 200%
    func zoomPresetLarge() {
        setTrueZoom(200)
    }

    // MARK: - Quick Stack

    // Start quick stack with the currently selected images from the file list.
    // Validates that all selected images target the same object (by name or RA/DEC proximity).
    // Quick Stack V2 (LightspeedStacker): GPU warp, hash-based matching, parallel star detection
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
        benchmarkStats.markQuickStackStart(
            frameCount: entries.count,
            engine: "lightspeed",
            imageWidth: entries.first?.width ?? 0,
            imageHeight: entries.first?.height ?? 0
        )
        engine.startStack(entries: entries, debayerEnabled: debayerEnabled)
    }

    // Color Combine: groups all visible images by filter, stacks each group, combines to RGB
    func startColorCombine() {
        let entries = visibleImages
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Images"
            alert.informativeText = "Open a session first, then use Color Combine."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Got it")
            alert.runModal()
            return
        }

        // Create engine
        guard let device = device else { return }
        let engine = ColorCombineEngine(device: device)
        guard let engine = engine else { return }

        engine.scanFilters(entries: entries)

        // Validate: need at least 2 filters with >= 3 frames
        guard engine.availableFilters.count >= 2 else {
            let alert = NSAlert()
            alert.messageText = "Not Enough Filters"
            alert.informativeText = "Color Combine needs at least 2 different filters with 3+ frames each.\n\nDetected filters: \(engine.availableFilters.map { "\($0.display)(\($0.count))" }.joined(separator: ", "))"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Got it")
            alert.runModal()
            return
        }

        colorCombineEngine = engine
        showColorCombine = true
    }

    // Validate all entries target the same sky object. Returns error message if mismatch found, nil if OK.
    // Checks by object name first; when names differ, falls back to RA/DEC coordinate proximity
    // (1° tolerance) since nearby targets (e.g. M81 & M82, ~0.6° apart) share the same FOV.
    private func validateSameTarget(_ entries: [ImageEntry]) -> String? {
        // Collect unique target names (ignoring nil/empty/unknown)
        let targets = Set(entries.compactMap { entry -> String? in
            guard let t = entry.target, !t.isEmpty, t.lowercased() != "unknown" else { return nil }
            return t.trimmingCharacters(in: .whitespaces).lowercased()
        })

        // When names match (or no names), skip straight to coordinate check if needed
        let namesMismatch = targets.count > 1

        // RA/DEC proximity check: allows stacking of nearby targets sharing the same FOV.
        // Prefer plate-solved coordinates (CRVAL1/CRVAL2), fall back to OBJCTRA/OBJCTDEC.
        let coords = entries.compactMap { entry -> (ra: Double, dec: Double)? in
            if let ra = entry.solvedRA, let dec = entry.solvedDec { return (ra, dec) }
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
                if separation > 1.0 {  // >1° apart = truly different field
                    if namesMismatch {
                        let names = Set(entries.compactMap { entry -> String? in
                            guard let t = entry.target, !t.isEmpty, t.lowercased() != "unknown" else { return nil }
                            return t.trimmingCharacters(in: .whitespaces)
                        })
                        return "Cannot stack: mixed targets detected (\(names.sorted().joined(separator: ", "))). Select only images of the same object."
                    }
                    return "Cannot stack: images point to different sky regions (>1° apart). Select only images of the same target field."
                }
            }
            // Coordinates within 1° — same FOV, allow stacking regardless of name difference
            return nil
        }

        // No coordinates available — fall back to name check only
        if namesMismatch {
            let names = Set(entries.compactMap { entry -> String? in
                guard let t = entry.target, !t.isEmpty, t.lowercased() != "unknown" else { return nil }
                return t.trimmingCharacters(in: .whitespaces)
            })
            return "Cannot stack: mixed targets detected (\(names.sorted().joined(separator: ", "))). Select only images of the same object."
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

    // Update histogram from the pre-computed bins in CachedPreview.
    func updateHistogram() {
        guard let image = selectedImage,
              let preview = prefetchCache?.getPreview(for: image.url),
              let bins = preview.histogramBins else {
            histogramBins = []
            return
        }
        histogramBins = bins
    }

    // GBE disabled for now — needs GPU-native texture-level approach for interactive speed
    // func toggleGradientRemoval() { ... }

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

    /// Navigate to the first image matching the given object name (and optionally filter, exposure, night).
    /// Called from session overview when user clicks an object or filter name.
    func navigateToObject(_ objectName: String, filter: String? = nil, exposure: Double? = nil, night: String? = nil) {
        let name = objectName.trimmingCharacters(in: .whitespaces)
        // Session overview groups nil/empty targets as "unknown" — match that here
        let isUnknownGroup = name == "unknown"
        guard let idx = images.firstIndex(where: { entry in
            let target = (entry.target ?? "").trimmingCharacters(in: .whitespaces)
            let targetMatches = isUnknownGroup ? target.isEmpty : target.caseInsensitiveCompare(name) == .orderedSame
            guard targetMatches else { return false }
            if let f = filter {
                // Session overview defaults nil filters to "none" — match that convention
                let entryFilter = (entry.filter ?? "none").uppercased().trimmingCharacters(in: .whitespaces)
                guard entryFilter == f.uppercased().trimmingCharacters(in: .whitespaces) else { return false }
            }
            // Match exposure if provided (distinguishes e.g. L@180s vs L@300s groups)
            if let exp = exposure, exp > 0 {
                guard let entryExp = entry.exposure, Swift.abs(entryExp - exp) < 0.5 else { return false }
            }
            // Match observing night if provided (multi-night sessions)
            if let n = night {
                guard entry.observingNight == n else { return false }
            }
            return true
        }) else { return }
        // Do NOT set needsTableRefresh here — it triggers a table reload that saves and restores
        // the old selection, which can block the scroll to the new row (especially with multi-select).
        // The selectedIndex @Published change already triggers updateNSView and scrolls correctly.
        selectImage(at: idx)
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

    // MARK: - Visual Validation (VLM Mosaic)

    /// Generate mosaic wallpapers from remaining frames and show in floating window.
    /// Optionally runs Claude Vision anomaly detection if API key is available.
    /// If files are highlighted (multi-selected), uses those regardless of mark status.
    /// Otherwise uses all unmarked frames.
    func startVisualValidation() {
        guard !images.isEmpty else { return }
        isGeneratingMosaic = true
        mosaicProgress = "Collecting preview textures..."

        // Determine frame set: highlighted selection (any status) or all unmarked
        // Require >= 2 highlighted — single selection is just normal navigation focus
        let highlighted = selectedEntries
        let useHighlighted = highlighted.count >= 2
        let highlightedURLs = Set(highlighted.map { $0.url })

        // Collect textures from PrefetchCache (we're @MainActor, so this is safe)
        var textures: [URL: MTLTexture] = [:]
        for entry in images {
            // If highlighted: only collect those. Otherwise: only unmarked.
            if useHighlighted {
                guard highlightedURLs.contains(entry.url) else { continue }
            } else {
                guard !entry.isMarkedForDeletion else { continue }
            }
            if let preview = prefetchCache?.getPreview(for: entry.url) {
                textures[entry.url] = preview.texture
            }
        }

        let cachedCount = textures.count
        let totalTarget = useHighlighted ? highlighted.count : images.filter { !$0.isMarkedForDeletion }.count
        let scope = useHighlighted ? "highlighted" : "active"
        mosaicProgress = "Generating mosaics (\(cachedCount)/\(totalTarget) \(scope) cached)..."

        // Capture immutable copies for background work
        let entriesCopy = images
        let texturesCopy = textures
        let skipDeletionFilter = useHighlighted
        let rotationCheck: (ImageEntry) -> Bool = { [weak self] entry in
            self?.shouldRotateForMeridian(entry) ?? false
        }

        // Generate mosaics on background thread (GPU readback is heavy)
        vlmGenerationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let generator = MosaicGenerator()
            let pages = generator.generatePages(
                entries: entriesCopy,
                textures: texturesCopy,
                shouldRotate: rotationCheck,
                skipDeletionFilter: skipDeletionFilter
            ) { completed, total in
                Task { @MainActor [weak self] in
                    self?.mosaicProgress = "Generating mosaic \(completed)/\(total)..."
                }
            }

            // Check cancellation before presenting results
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.isGeneratingMosaic = false
                    self?.mosaicProgress = ""
                    self?.statusMessage = "VLM Check cancelled"
                    self?.vlmGenerationTask = nil
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isGeneratingMosaic = false
                self.vlmGenerationTask = nil

                if pages.isEmpty {
                    self.statusMessage = "Not enough cached frames for mosaic (need ≥4 per group)"
                    return
                }

                // Show floating mosaic window
                let jumpTo: (Int) -> Void = { [weak self] entryIndex in
                    self?.selectImage(at: entryIndex)
                }
                let markFrames: ([Int]) -> Void = { [weak self] entryIndices in
                    guard let self = self else { return }
                    for idx in entryIndices where self.images.indices.contains(idx) {
                        self.images[idx].isMarkedForDeletion = true
                    }
                    self.needsTableRefresh = true
                    let marked = entryIndices.count
                    self.statusMessage = "Marked \(marked) VLM-flagged frames for deletion"
                }

                let analyzeCallback: ([MosaicPage]) -> Void = { [weak self] pagesToAnalyze in
                    self?.runVisualAnalysis(pages: pagesToAnalyze)
                }
                let unmarkFrames: ([Int]) -> Void = { [weak self] entryIndices in
                    guard let self = self else { return }
                    for idx in entryIndices where self.images.indices.contains(idx) {
                        self.images[idx].isMarkedForDeletion = false
                    }
                    self.needsTableRefresh = true
                    self.statusMessage = "Unmarked \(entryIndices.count) VLM-flagged frames"
                }

                let wc = VisualValidationWindowController.shared
                wc.show(
                    pages: pages,
                    onJumpToFrame: jumpTo,
                    onMarkFrames: markFrames,
                    onUnmarkFrames: unmarkFrames,
                    onAnalyze: analyzeCallback
                )

                // Show computational center anomalies immediately (no API call needed)
                let centerAnomalies = pages.reduce(into: [GroupKey: [AnomalyResult]]()) { dict, page in
                    if !page.centerAnomalies.isEmpty {
                        dict[page.group, default: []].append(contentsOf: page.centerAnomalies)
                    }
                }
                if !centerAnomalies.isEmpty {
                    wc.updateAnomalies(centerAnomalies)
                }

                let tileCount = pages.reduce(0) { $0 + $1.tiles.count }
                let centerCount = centerAnomalies.values.reduce(0) { $0 + $1.count }
                let scopeLabel = useHighlighted ? " (highlighted)" : ""
                let centerInfo = centerCount > 0 ? " — \(centerCount) center anomaly detected" : ""
                self.statusMessage = "Mosaic: \(pages.count) group(s), \(tileCount) tiles\(scopeLabel)\(centerInfo) — click Analyze for VLM check"
            }
        }
    }

    /// Cancel an in-progress VLM mosaic generation
    func cancelVisualValidation() {
        vlmGenerationTask?.cancel()
        vlmGenerationTask = nil
        isGeneratingMosaic = false
        mosaicProgress = ""
        statusMessage = "VLM Check cancelled"
    }

    /// Run Claude Vision anomaly detection on generated mosaics.
    /// Routes through Supabase edge function (works out of the box, no API key needed).
    /// Falls back to user's own API key if edge function is unavailable.
    func runVisualAnalysis(pages: [MosaicPage]) {
        mosaicProgress = "Analyzing with Claude Vision..."
        let wc = VisualValidationWindowController.shared
        wc.updateAnalysisProgress("Sending \(pages.count) mosaic(s) to Claude Vision...")

        Task {
            let detector = VisualAnomalyDetector()
            do {
                let results = try await detector.analyzeAll(
                    pages: pages
                ) { completed, total, status in
                    Task { @MainActor [weak self] in
                        self?.mosaicProgress = "Analyzing \(completed)/\(total): \(status)"
                        wc.updateAnalysisProgress("Analyzing \(completed)/\(total): \(status)")
                    }
                }

                // Merge VLM results with existing center anomalies (don't replace them)
                let centerAnomalies = pages.reduce(into: [GroupKey: [AnomalyResult]]()) { dict, page in
                    if !page.centerAnomalies.isEmpty {
                        dict[page.group, default: []].append(contentsOf: page.centerAnomalies)
                    }
                }
                var merged = centerAnomalies
                for (key, vlmResults) in results {
                    merged[key, default: []].append(contentsOf: vlmResults)
                }
                let totalAnomalies = merged.values.reduce(0) { $0 + $1.count }
                wc.updateAnomalies(merged)
                let remaining = detector.remainingChecks.map { " (\($0) checks remaining today)" } ?? ""
                statusMessage = "Visual check: \(totalAnomalies) anomalies in \(pages.count) group(s)\(remaining)"
                mosaicProgress = ""
                print("[VLM] Analysis complete: \(totalAnomalies) anomalies across \(results.count) groups")
            } catch {
                let errMsg = error.localizedDescription
                statusMessage = "Visual analysis: \(errMsg)"
                mosaicProgress = ""
                wc.analysisFinished(error: errMsg)
                print("[VLM] Analysis error: \(errMsg)")
            }
        }
    }

    // MARK: - Blink Playback

    /// Start blinking through images. Uses highlighted rows if multi-selected,
    /// otherwise all currently visible (unhidden/filtered) images.
    func startPlayback(highlightedRows: IndexSet?) {
        guard !images.isEmpty else { return }

        // Build list of indices to cycle through — always respect visibility
        if let rows = highlightedRows, rows.count > 1 {
            // Multi-selected rows are table rows (visible list indices) — map to real indices
            let visible = visibleImages
            playbackIndices = rows.compactMap { row -> Int? in
                guard row < visible.count else { return nil }
                return images.firstIndex(where: { $0.url == visible[row].url })
            }
        } else {
            // All visible images — map to their real indices in the images array
            let visible = visibleImages
            playbackIndices = visible.compactMap { entry in
                images.firstIndex(where: { $0.url == entry.url })
            }
        }
        guard !playbackIndices.isEmpty else { return }

        // Start at current image if it's in the list, otherwise start from beginning
        if let pos = playbackIndices.firstIndex(of: selectedIndex) {
            playbackPosition = pos
        } else {
            playbackPosition = 0
        }

        isPlaying = true
        schedulePlaybackTimer()
    }

    func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackIndices = []
        playbackPosition = 0
    }

    private func schedulePlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: playbackDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advancePlayback()
            }
        }
    }

    private func advancePlayback() {
        guard isPlaying, !playbackIndices.isEmpty else { return }
        playbackPosition = (playbackPosition + 1) % playbackIndices.count
        let idx = playbackIndices[playbackPosition]
        if idx >= 0, idx < images.count {
            selectImage(at: idx)
        }
        schedulePlaybackTimer()
    }

    // MARK: - Blink Video Export

    enum BlinkExportFormat: String, CaseIterable { case mov, gif }

    @Published var isExportingVideo: Bool = false
    @Published var videoExportProgress: Double = 0

    /// Export blink sequence as HEVC .mov or animated GIF.
    /// - Parameter cropToZoom: If true, crops to the current zoom/pan view.
    func exportBlinkVideo(format: BlinkExportFormat, loops: Int, scalePercent: Int,
                          maxSizeMB: Double, highlightedRows: IndexSet?, fps: Double,
                          cropToZoom: Bool = false) {
        guard !images.isEmpty else { return }

        // Build frame indices (same logic as startPlayback)
        var frameIndices: [Int] = []
        if let rows = highlightedRows, rows.count > 1 {
            let visible = visibleImages
            frameIndices = rows.compactMap { row -> Int? in
                guard row < visible.count else { return nil }
                return images.firstIndex(where: { $0.url == visible[row].url })
            }
        } else {
            let visible = visibleImages
            frameIndices = visible.compactMap { entry in
                images.firstIndex(where: { $0.url == entry.url })
            }
        }
        guard !frameIndices.isEmpty else { statusMessage = "No images to export"; return }

        guard let cache = prefetchCache else { statusMessage = "Cache not ready"; return }
        var textures: [MTLTexture] = []
        for idx in frameIndices {
            if let preview = cache.getPreview(for: images[idx].url) {
                textures.append(preview.texture)
            }
        }
        guard !textures.isEmpty else { statusMessage = "No cached frames — browse images first"; return }

        // Compute crop rect from current zoom/pan if requested
        let cropRect: CGRect? = cropToZoom ? visibleCropRect() : nil

        let srcW = textures[0].width, srcH = textures[0].height
        let cropW = cropRect != nil ? Int(cropRect!.width * CGFloat(srcW)) : srcW
        let cropH = cropRect != nil ? Int(cropRect!.height * CGFloat(srcH)) : srcH
        let scale = max(10, min(100, scalePercent))
        let outW = (cropW * scale / 100) & ~1
        let outH = (cropH * scale / 100) & ~1

        let dateStr = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; return f.string(from: Date()) }()
        let target = images[selectedIndex >= 0 && selectedIndex < images.count ? selectedIndex : 0].target ?? "Blink"
        let ext = format == .gif ? "gif" : "mov"
        let defaultName = "AstroBlink_\(target)_\(dateStr).\(ext)"

        // Use NSSavePanel for sandbox-compatible file access
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .gif ? [.gif] : [.movie]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExportingVideo = true
        videoExportProgress = 0
        statusMessage = "Exporting blink \(ext)..."
        let totalFrames = textures.count * loops

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if format == .gif {
                    try Self.writeBlinkGIF(textures: textures, loops: loops, outputURL: outputURL,
                                           width: outW, height: outH, fps: fps, maxSizeMB: maxSizeMB,
                                           cropRect: cropRect,
                                           onProgress: { p in Task { @MainActor [weak self] in self?.videoExportProgress = p } })
                } else {
                    try await Self.writeBlinkMOV(textures: textures, loops: loops, outputURL: outputURL,
                                                 width: outW, height: outH, fps: fps, cropRect: cropRect,
                                                 onProgress: { p in Task { @MainActor [weak self] in self?.videoExportProgress = p } })
                }
                await MainActor.run { [weak self] in
                    self?.isExportingVideo = false
                    let sizeMB = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64)
                        .map { Double($0) / (1024 * 1024) } ?? 0
                    self?.statusMessage = String(format: "%@ saved to Desktop (%.1f MB, %d frames)", ext.uppercased(), sizeMB, totalFrames)
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isExportingVideo = false
                    self?.statusMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Texture → CGImage helper

    /// Convert BGRA8 MTLTexture to CGImage, optionally cropped and scaled.
    /// GPU-compressed textures are blitted to a readable staging texture first.
    /// - Parameters:
    ///   - cropRect: Normalized crop rect (0-1 range) within the texture. nil = full image.
    private nonisolated static func textureToImage(_ texture: MTLTexture, width: Int, height: Int,
                                                    cropRect: CGRect? = nil) -> CGImage? {
        let srcW = texture.width, srcH = texture.height

        // If texture uses private/managed storage, blit to a shared staging texture
        let readableTex: MTLTexture
        if texture.storageMode != .shared {
            let device = texture.device
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: srcW, height: srcH, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            guard let staging = device.makeTexture(descriptor: desc),
                  let queue = device.makeCommandQueue(),
                  let cmdBuf = queue.makeCommandBuffer(),
                  let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: srcW, height: srcH, depth: 1),
                      to: staging, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin())
            blit.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            readableTex = staging
        } else {
            readableTex = texture
        }

        var pixels = [UInt8](repeating: 0, count: srcW * srcH * 4)
        readableTex.getBytes(&pixels, bytesPerRow: srcW * 4,
                             from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: srcW, height: srcH, depth: 1)),
                             mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let srcCtx = CGContext(data: &pixels, width: srcW, height: srcH,
                                      bitsPerComponent: 8, bytesPerRow: srcW * 4, space: cs, bitmapInfo: bi),
              let fullImg = srcCtx.makeImage() else { return nil }

        // Apply crop if specified
        let srcImg: CGImage
        if let crop = cropRect {
            let cx = Int(crop.origin.x * CGFloat(srcW))
            let cy = Int(crop.origin.y * CGFloat(srcH))
            let cw = max(2, Int(crop.width * CGFloat(srcW)))
            let ch = max(2, Int(crop.height * CGFloat(srcH)))
            let clampedRect = CGRect(x: max(0, cx), y: max(0, cy),
                                     width: min(cw, srcW - max(0, cx)),
                                     height: min(ch, srcH - max(0, cy)))
            srcImg = fullImg.cropping(to: clampedRect) ?? fullImg
        } else {
            srcImg = fullImg
        }

        if srcImg.width == width && srcImg.height == height { return srcImg }

        // Scale to output size
        guard let destCtx = CGContext(data: nil, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: bi) else { return nil }
        destCtx.interpolationQuality = .high
        destCtx.draw(srcImg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return destCtx.makeImage()
    }

    /// Compute the visible crop rectangle (normalized 0-1) from the current zoom/pan state.
    /// Returns nil if showing the full image (zoom = fit-to-view).
    func visibleCropRect() -> CGRect? {
        guard let renderer = renderer, renderer.zoomScale > 1.01 else { return nil }
        guard let mtkView = findMTKView() else { return nil }

        let viewW = mtkView.bounds.width
        let viewH = mtkView.bounds.height
        // Get image dimensions from cached preview or current decoded image
        let imgW: CGFloat
        let imgH: CGFloat
        if let tex = renderer.cachedPreviewTexture {
            imgW = CGFloat(renderer.cachedPreviewWidth > 0 ? renderer.cachedPreviewWidth : tex.width)
            imgH = CGFloat(renderer.cachedPreviewHeight > 0 ? renderer.cachedPreviewHeight : tex.height)
        } else if let img = renderer.currentImage {
            imgW = CGFloat(img.width)
            imgH = CGFloat(img.height)
        } else {
            return nil
        }

        let baseFit = min(viewW / imgW, viewH / imgH)
        let effectiveScale = baseFit * renderer.zoomScale

        // Visible region in image coordinates
        let visW = viewW / effectiveScale
        let visH = viewH / effectiveScale
        let centerX = imgW / 2.0 - renderer.panOffset.x / effectiveScale
        let centerY = imgH / 2.0 - renderer.panOffset.y / effectiveScale

        let x = (centerX - visW / 2.0) / imgW
        let y = (centerY - visH / 2.0) / imgH
        let w = visW / imgW
        let h = visH / imgH

        return CGRect(x: max(0, x), y: max(0, y),
                      width: min(w, 1.0 - max(0, x)),
                      height: min(h, 1.0 - max(0, y)))
    }

    // MARK: - Animated GIF writer

    /// Write animated GIF with optional size constraint. If the result exceeds maxSizeMB,
    /// frames are dropped (every 2nd, then 3rd...) until it fits.
    private nonisolated static func writeBlinkGIF(
        textures: [MTLTexture], loops: Int, outputURL: URL,
        width: Int, height: Int, fps: Double, maxSizeMB: Double,
        cropRect: CGRect? = nil,
        onProgress: @Sendable (Double) -> Void
    ) throws {
        // Convert all textures to CGImages once
        var cgImages: [CGImage] = []
        for (i, tex) in textures.enumerated() {
            if let img = textureToImage(tex, width: width, height: height, cropRect: cropRect) {
                cgImages.append(img)
            }
            onProgress(Double(i + 1) / Double(textures.count) * 0.5)  // 50% for conversion
        }
        guard !cgImages.isEmpty else {
            throw NSError(domain: "BlinkExport", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to convert textures"])
        }

        // Build full frame sequence with loops
        var allFrames: [CGImage] = []
        for _ in 0..<loops { allFrames.append(contentsOf: cgImages) }

        // Try writing, reduce frames if over size limit
        var stride = 1
        let maxBytes = Int64(maxSizeMB * 1024 * 1024)

        while stride <= allFrames.count {
            let frames = Swift.stride(from: 0, to: allFrames.count, by: stride).map { allFrames[$0] }
            let delay = 1.0 / fps * Double(stride)

            // Write GIF to data
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
                                                               frames.count, nil) else { continue }
            let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
            CGImageDestinationSetProperties(dest, gifProps)

            for (i, frame) in frames.enumerated() {
                let frameProps = [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]] as CFDictionary
                CGImageDestinationAddImage(dest, frame, frameProps)
                onProgress(0.5 + Double(i + 1) / Double(frames.count) * 0.5)
            }

            guard CGImageDestinationFinalize(dest) else { continue }

            if maxSizeMB <= 0 || Int64(data.length) <= maxBytes {
                try (data as Data).write(to: outputURL)
                return
            }

            // Over limit — skip more frames
            stride += 1
        }

        throw NSError(domain: "BlinkExport", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot fit within \(Int(maxSizeMB)) MB even with 1 frame"])
    }

    // MARK: - HEVC MOV writer

    private nonisolated static func writeBlinkMOV(
        textures: [MTLTexture], loops: Int, outputURL: URL,
        width: Int, height: Int, fps: Double, cropRect: CGRect? = nil,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(500_000, width * height * 2),
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
            ])
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw NSError(domain: "BlinkExport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "Write failed"])
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = textures.count * loops
        var frameIndex = 0
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        for _ in 0..<loops {
            for texture in textures {
                while !writerInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard let pool = adaptor.pixelBufferPool else { continue }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pixelBuffer = pb else { continue }

                // Use textureToImage which handles GPU-compressed textures via blit
                guard let img = textureToImage(texture, width: width, height: height, cropRect: cropRect) else { continue }

                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let dest = CVPixelBufferGetBaseAddress(pixelBuffer)!
                let destBPR = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let ctx = CGContext(data: dest, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: destBPR,
                                    space: colorSpace, bitmapInfo: bi)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)))
                frameIndex += 1
                onProgress(Double(frameIndex) / Double(totalFrames))
            }
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
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
        recomputeSNRRetention()
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
        recomputeSNRRetention()
    }

    // Clear all deletion marks across the entire session
    func unmarkAll() {
        var count = 0
        for i in images.indices where images[i].isMarkedForDeletion {
            images[i].isMarkedForDeletion = false
            count += 1
        }
        guard count > 0 else {
            statusMessage = "No marks to clear"
            return
        }
        needsTableRefresh = true
        recomputeSNRRetention()
        updateConvergence()
        statusMessage = "Cleared \(count) marks"
    }

    // MARK: - User Confidence Rating

    /// Set confidence rating for frames at given row indices. Same value toggles off (clears to 0).
    func setUserConfidence(_ rating: Int, forRows rows: IndexSet) {
        guard !rows.isEmpty else {
            statusMessage = "No frames selected"
            return
        }

        var changed = 0
        var lastRating = 0
        for idx in rows where idx >= 0 && idx < images.count {
            let current = images[idx].userConfidence
            let newVal = (current == rating) ? 0 : rating
            images[idx].userConfidence = newVal
            lastRating = newVal
            changed += 1

            // Persist to Frame History DB if file hash available
            if let hash = images[idx].fileHash {
                let conf = newVal
                Task {
                    try? FrameHistoryDatabase.shared.updateUserConfidence(
                        fileHash: hash, confidence: conf)
                }
            }
        }

        needsTableRefresh = true
        if lastRating == 0 {
            statusMessage = "Cleared confidence rating for \(changed) frame\(changed == 1 ? "" : "s")"
        } else {
            let stars = String(repeating: "★", count: lastRating)
            statusMessage = "\(stars) confidence set for \(changed) frame\(changed == 1 ? "" : "s")"
        }
    }

    // MARK: - Quality Feedback

    /// Cycle quality feedback for frames at given row indices.
    /// Cycle: none → agree → disagree → partly → none
    func cycleQualityFeedback(forRows rows: IndexSet) {
        guard !rows.isEmpty else {
            statusMessage = "No frames selected"
            return
        }

        var changed = 0
        var lastFeedback: QualityFeedback = .none
        for idx in rows where idx >= 0 && idx < images.count {
            // Only allow feedback on frames that have a quality tier
            guard images[idx].qualityTier != nil else { continue }

            let next = images[idx].qualityFeedback.next
            images[idx].qualityFeedback = next
            lastFeedback = next
            changed += 1

            // Persist to Frame History DB
            if let hash = images[idx].fileHash {
                let fb = next.rawValue
                Task {
                    try? FrameHistoryDatabase.shared.updateQualityFeedback(
                        fileHash: hash, feedback: fb)
                }
            }

            // Record to CalibrationDatabase for learning
            if let fp = currentSetupFingerprint {
                CalibrationDatabase.shared.recordFeedback(
                    entry: images[idx], feedback: next, fingerprint: fp)
            }
        }

        needsTableRefresh = true
        if changed == 0 {
            statusMessage = "No scored frames in selection"
            return
        }
        let label: String
        switch lastFeedback {
        case .none:     label = "Cleared"
        case .agree:    label = "Agree"
        case .disagree: label = "Disagree"
        case .partly:   label = "Partly"
        }
        statusMessage = "Quality feedback: \(label) for \(changed) frame\(changed == 1 ? "" : "s")"
    }

    /// Set a specific quality feedback value for frames at given row indices.
    /// Used by context menu — toggle behavior (same value again clears it).
    func setQualityFeedback(_ feedback: QualityFeedback, forRows rows: IndexSet) {
        guard !rows.isEmpty else { return }

        var changed = 0
        for idx in rows where idx >= 0 && idx < images.count {
            guard images[idx].qualityTier != nil else { continue }
            let current = images[idx].qualityFeedback
            let newVal: QualityFeedback = (current == feedback) ? .none : feedback
            images[idx].qualityFeedback = newVal
            changed += 1

            if let hash = images[idx].fileHash {
                let fb = newVal.rawValue
                Task {
                    try? FrameHistoryDatabase.shared.updateQualityFeedback(
                        fileHash: hash, feedback: fb)
                }
            }
            if let fp = currentSetupFingerprint {
                CalibrationDatabase.shared.recordFeedback(
                    entry: images[idx], feedback: newVal, fingerprint: fp)
            }
        }
        needsTableRefresh = true
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
        // Force single selection after filter toggle — prevents multi-selection carryover
        // from N marked files staying highlighted after they disappear
        let visible = visibleImages
        if !visible.isEmpty {
            if let currentURL = selectedImage?.url,
               let visIdx = visible.firstIndex(where: { $0.url == currentURL }) {
                if let realIdx = images.firstIndex(where: { $0.url == visible[visIdx].url }) {
                    selectedIndex = realIdx
                }
            } else {
                // Current image was hidden — select nearest visible
                let targetIdx = max(0, min(selectedIndex, images.count - 1))
                var bestVisibleIdx = 0
                var bestDist = Int.max
                for (vi, vImg) in visible.enumerated() {
                    if let ri = images.firstIndex(where: { $0.url == vImg.url }) {
                        let dist = abs(ri - targetIdx)
                        if dist < bestDist {
                            bestDist = dist
                            bestVisibleIdx = vi
                        }
                    }
                }
                if let realIdx = images.firstIndex(where: { $0.url == visible[bestVisibleIdx].url }) {
                    selectImage(at: realIdx)
                }
            }
        }
        needsForceSingleSelection = true
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
        statusMessage = ""
        needsTableRefresh = true
        recomputeSNRRetention()

        // Record action for calibration learning
        if let fp = currentSetupFingerprint {
            CalibrationDatabase.shared.recordAction(
                entry: images[index], wasMarked: marked, fingerprint: fp
            )
        }
        updateConvergence()
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

        statusMessage = ""
        needsTableRefresh = true
        recomputeSNRRetention()
        updateConvergence()
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

        // Build deletion impact summary for the confirmation dialog
        // Each section is clearly separated with blank lines for readability
        var sections: [String] = []
        let totalExposure = images.reduce(0.0) { $0 + ($1.exposure ?? 0) }
        let markedExposure = markedImages.reduce(0.0) { $0 + ($1.exposure ?? 0) }

        if totalExposure > 0 {
            let integrationLoss = markedExposure / totalExposure * 100.0
            let markedStr = markedExposure >= 3600 ? String(format: "%.1fh", markedExposure / 3600) : String(format: "%.0fm", markedExposure / 60)
            let totalStr = totalExposure >= 3600 ? String(format: "%.1fh", totalExposure / 3600) : String(format: "%.0fm", totalExposure / 60)
            sections.append("Integration lost:\n    \(markedStr) of \(totalStr) total (\(String(format: "-%.0f", integrationLoss))%)")
        }

        // SNR impact from live retention bar
        let snrLoss = 100.0 - snrRetention
        if snrLoss > 0.05 {
            sections.append("Estimated SNR impact:\n    \(String(format: "-%.1f", snrLoss))%")
        }

        // Breakdown by quality tier
        let trashCount = markedImages.filter { $0.qualityTier == .trash }.count
        let borderlineCount = markedImages.filter { $0.qualityTier == .borderline }.count
        let goodCount = markedImages.filter { $0.qualityTier == .good }.count
        let excellentCount = markedImages.filter { $0.qualityTier == .excellent }.count
        let unscoredCount = markedImages.filter { $0.qualityTier == nil }.count

        var breakdown: [String] = []
        if trashCount > 0 { breakdown.append("\(trashCount)× trash") }
        if borderlineCount > 0 { breakdown.append("\(borderlineCount)× borderline") }
        if goodCount > 0 { breakdown.append("\(goodCount)× good") }
        if excellentCount > 0 { breakdown.append("\(excellentCount)× excellent") }
        if unscoredCount > 0 { breakdown.append("\(unscoredCount)× unscored") }
        if !breakdown.isEmpty {
            sections.append("Tier breakdown:\n    \(breakdown.joined(separator: ", "))")
        }

        sections.append("Files will be moved to \"PRE-DELETE\" — not permanently deleted.\nUndo with \u{2318}Z.")

        // Multi-source sessions: show the user WHERE PRE-DELETE will be created
        // on the first delete, since the location is the deepest common ancestor
        // across the picked folders (not any one folder the user picked). After
        // they confirm once, subsequent deletes in the same session stay quiet.
        if multiSourceSession && !multiSourcePreDeleteConfirmed {
            sections.append("This session spans multiple picked folders.\nAll marked frames will be moved to:\n    \(rootURL.appendingPathComponent("PRE-DELETE", isDirectory: true).path)")
        }

        let infoText = sections.joined(separator: "\n\n")

        // Show confirmation dialog with impact summary
        let alert = NSAlert()
        alert.messageText = "Move \(markedImages.count) marked images to PRE-DELETE?"
        alert.informativeText = infoText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to PRE-DELETE")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Latch the multi-source confirmation for the remainder of this session.
        if multiSourceSession { multiSourcePreDeleteConfirmed = true }

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

            // Start security-scoped access to the granted folder. ADD to the
            // existing scopes rather than replacing — we still want to keep
            // scope on the original session folders so we can read the source
            // files during the move.
            if grantedURL.startAccessingSecurityScopedResource() {
                accessedURLs.append(grantedURL)
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

        // Commit retained frames to calibration database for learning
        if let fp = currentSetupFingerprint {
            CalibrationDatabase.shared.commitSession(entries: images, fingerprint: fp)
            // Upload anonymous session summary to community (if opted in)
            CommunityDetectionService.shared.uploadSessionData(entries: images, fingerprint: fp)
        }

        // Mark deleted frames in Frame History Database
        let deletedHashes = images.filter { $0.isMarkedForDeletion }.compactMap { $0.fileHash }
        if !deletedHashes.isEmpty {
            Task.detached {
                try? FrameHistoryDatabase.shared.markDeleted(fileHashes: deletedHashes)
            }
        }

        // Do NOT re-score after deletion — prevents "spiral of death" where z-scores
        // recalculate on the smaller group, shifting the median upward, making previously-good
        // frames now "relatively bad", leading to iterative over-culling.
        // Scores from the original analysis are preserved. User can reload folder to re-score.
        updateConvergence()
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
        recomputeSNRRetention()
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

    // MARK: - Global Quarantine (Q key)

    // Move all marked files to ~/Desktop/Astro-Quarantine/ regardless of source folder.
    // Creates the quarantine folder if needed. Same undo mechanism as PRE-DELETE.
    func moveMarkedToQuarantine() {
        let markedImages = images.filter { $0.isMarkedForDeletion }
        guard !markedImages.isEmpty else {
            statusMessage = "No images marked — checkmark files first (Space)"
            return
        }

        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        var quarantineDir = desktopURL.appendingPathComponent("Astro-Quarantine", isDirectory: true)

        // Confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Move \(markedImages.count) marked images to Quarantine?"
        alert.informativeText = "Files will be moved to:\n    ~/Desktop/Astro-Quarantine/\n\nThis collects files from any session into one folder.\nUndo with \u{2318}Z."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Quarantine")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default

        // Create quarantine folder — sandbox may block ~/Desktop, so use NSOpenPanel fallback
        do {
            if !fm.fileExists(atPath: quarantineDir.path) {
                try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
            }
        } catch {
            // Sandbox blocked — ask user to select/confirm the quarantine folder
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = desktopURL
            panel.message = "Select or create the Astro-Quarantine folder on your Desktop"
            panel.prompt = "Use This Folder"

            guard panel.runModal() == .OK, let grantedURL = panel.url else {
                statusMessage = "Quarantine cancelled — folder access not granted"
                return
            }
            quarantineDir = grantedURL
            // Ensure it exists
            do {
                if !fm.fileExists(atPath: quarantineDir.path) {
                    try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
                }
            } catch {
                statusMessage = "Error creating quarantine folder: \(error.localizedDescription)"
                return
            }
        }

        let firstMarkedIndex = images.firstIndex(where: { $0.isMarkedForDeletion }) ?? selectedIndex

        var movedCount = 0
        var failedCount = 0
        var undoEntries: [PreDeleteUndoEntry] = []

        for entry in markedImages {
            var finalDest = quarantineDir.appendingPathComponent(entry.filename)
            var suffix = 1
            while fm.fileExists(atPath: finalDest.path) {
                let name = entry.url.deletingPathExtension().lastPathComponent
                let ext = entry.url.pathExtension
                finalDest = quarantineDir.appendingPathComponent("\(name)_\(suffix).\(ext)")
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

        // Push to undo stack (same as PRE-DELETE — Cmd+Z undoes both)
        if !undoEntries.isEmpty {
            preDeleteUndoStack.append(undoEntries)
        }

        // Remove moved images from the list
        let markedURLs = Set(markedImages.map { $0.url })
        images.removeAll { markedURLs.contains($0.url) }

        if !images.isEmpty {
            let newIndex = min(firstMarkedIndex, images.count - 1)
            selectImage(at: max(0, newIndex))
        } else {
            selectedIndex = -1
            currentDecodedImage = nil
        }

        needsTableRefresh = true
        sessionOverviewModel.updateStats(from: images)
        recomputeSNRRetention()

        if failedCount > 0 {
            statusMessage = "Quarantined \(movedCount) files (\(failedCount) failed) — Undo available"
        } else {
            statusMessage = "Quarantined \(movedCount) file(s) to ~/Desktop/Astro-Quarantine — Undo available"
        }
    }

    // MARK: - Header Inspector

    func toggleHeaderInspector() {
        showInspector.toggle()
        if showInspector, let image = selectedImage {
            headerInspectorModel.update(for: image.decodingURL, filename: image.filename)
            headerInspectorModel.updateQualityMetrics(from: image.qualityBreakdown, entry: image)
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
            // If showing a cached preview, currentSTFParams may be stale.
            // Decode the current image to get correct STF params before locking.
            if renderer.currentImage == nil, let entry = selectedImage, let device = device {
                let decodeURL = entry.decodingURL
                let bayerPattern = debayerEnabled ? entry.bayerPattern : nil
                if case .success(let decoded) = ImageDecoder.decode(url: decodeURL, device: device) {
                    currentDecodedImage = decoded
                    if let mtkView = findMTKView() {
                        renderer.setImage(decoded, in: mtkView,
                                          bayerPattern: bayerPattern,
                                          targetBackground: stretchStrength)
                    }
                }
            }
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
        AppSettings.saveFloat(stretchStrength, for: .stretchStrength)
        sharpening = 0.0
        contrast = 0.0
        darkLevel = 0.0
        isSTFLocked = false
        renderer?.unlockSTF()

        // Update live display
        updatePostProcessParams()

        // Re-cache with defaults and re-enable Apply All (same state as initial folder load)
        applyAllEnabled = true
        appliedStretch = stretchStrength
        appliedSharpening = 0.0
        appliedContrast = 0.0
        appliedDarkLevel = 0.0
        appliedLocked = false
        prefetchCache?.invalidateAll()
        statusMessage = "Resetting — re-caching with defaults..."
        startFullPrefetch()

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
            // Find the file list table specifically (not header inspector or other tables)
            func findFileListTable(in view: NSView?) -> NSTableView? {
                guard let view = view else { return nil }
                if let tv = view as? NSTableView,
                   tv.identifier == NSUserInterfaceItemIdentifier("fileListTable") {
                    return tv
                }
                for sub in view.subviews {
                    if let found = findFileListTable(in: sub) { return found }
                }
                return nil
            }
            if let tableView = findFileListTable(in: window.contentView) {
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
            // Implicit tiebreaker: night descending (newest first), then time ascending
            let nightA = a.observingNight ?? ""
            let nightB = b.observingNight ?? ""
            if nightA != nightB { return nightA > nightB }
            return (a.dateTime ?? "") < (b.dateTime ?? "")
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
        // Build sort chain: grouping columns + first metric column only.
        // Additional metric columns (contrib, stars, snr after quality) are skipped
        // to preserve the implicit tiebreaker: night descending, time ascending.
        let groupingColumns: Set<String> = [
            "filter", "target", "exposure", "night", "date", "time",
            "subfolder", "filename", "camera", "telescope", "binning",
            "frameType", "pierSide"
        ]

        var sortColumns: [String] = []
        var foundMetric = false

        for colId in columnIdentifiers {
            if colId == "marked" || colId == "frameNumber" { continue }
            if groupingColumns.contains(colId) && !foundMetric {
                sortColumns.append(colId)
            } else if !foundMetric {
                // First metric/value column (quality, snr, fwhm, etc.) — include and stop
                sortColumns.append(colId)
                foundMetric = true
            }
            // Skip additional metric columns — tiebreaker handles the rest
        }

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

        // GBE disabled for now
        // if gradientRemovalEnabled { gradientRemovalEnabled = false }

        // Update header inspector model (panel updates reactively via SwiftUI)
        headerInspectorModel.update(for: image.decodingURL, filename: image.filename)
        headerInspectorModel.updateQualityMetrics(from: image.qualityBreakdown, entry: image)

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
                updateHistogram()
            }

            statusMessage = isCaching
                ? "Analyzing \(cachingCount)/\(cachingTotal)..."
                : ""
            return
        }

        // Slow path: decode on demand (image not yet cached or settings don't match cache)
        // During active caching, request priority decode for current neighborhood (±2 images).
        // The priority queue uses .userInteractive QoS to get P-core scheduling priority.
        // When the priority preview completes, onPriorityPreviewReady auto-refreshes the display.
        if isCaching, cacheMatchesCurrentSettings {
            let targetBg: Float? = abs(appliedStretch - STFCalculator.defaultTargetBackground) > 0.001
                ? appliedStretch : nil
            let lockedParams: [STFParams]? = appliedLocked ? renderer?.lockedSTFParams : nil
            let ppParams: (sharpening: Float, contrast: Float, darkLevel: Float)?
            if abs(appliedSharpening) > 0.001 || abs(appliedContrast) > 0.001 || appliedDarkLevel > 0.001 {
                ppParams = (appliedSharpening, appliedContrast, appliedDarkLevel)
            } else {
                ppParams = nil
            }
            prefetchCache?.prioritizeCaching(
                around: selectedIndex,
                images: images,
                debayerEnabled: debayerEnabled,
                targetBackground: lockedParams != nil ? nil : targetBg,
                lockedSTFParams: lockedParams,
                postProcessParams: ppParams,
                onNoiseStats: { [weak self] url, stats in
                    guard let self = self else { return }
                    if let idx = self.images.firstIndex(where: { $0.url == url }) {
                        self.images[idx].noiseMedian = stats.median
                        self.images[idx].noiseMAD = stats.normalizedMAD
                    }
                },
                onStarMetrics: { [weak self] url, metrics in
                    guard let self = self else { return }
                    if let idx = self.images.firstIndex(where: { $0.url == url }) {
                        if metrics.medianHFR > 0 { self.images[idx].computedHFR = metrics.medianHFR }
                        if metrics.medianFWHM > 0 { self.images[idx].computedFWHM = metrics.medianFWHM }
                        self.images[idx].computedStarCount = metrics.totalStarCount
                        self.images[idx].computedEccentricity = metrics.medianEccentricity
                        if !metrics.starDetails.isEmpty {
                            self.images[idx].starDetails = metrics.starDetails
                        }
                    }
                },
                onFileHash: { [weak self] url, hash in
                    guard let self = self else { return }
                    if let idx = self.images.firstIndex(where: { $0.url == url }) {
                        self.images[idx].fileHash = hash
                    }
                }
            )
        }
        // Skip "Loading..." status during blink playback to avoid status bar flickering
        if !isPlaying {
            statusMessage = "Loading \(image.filename)..."
        }
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

                    self.statusMessage = ""

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

    // MARK: - Batch Rename / Header Edit

    var batchUndoStack: [BatchUndoEntry] = []
    var canUndoBatch: Bool { !batchUndoStack.isEmpty }

    /// Apply a batch result: update entry URLs, re-parse filenames, mark as modified
    func applyBatchResult(_ result: BatchResult) {
        // Update URLs for renamed files
        for i in images.indices {
            if let newURL = result.affectedURLs[images[i].url] {
                images[i] = ImageEntry(url: newURL, subfolder: images[i].subfolder)
                // Re-parse filename tokens for the new name
                let tokens = NINAFilenameParser.parse(newURL.lastPathComponent)
                images[i].date = tokens.date
                images[i].time = tokens.time
                images[i].target = tokens.target
                images[i].frameNumber = tokens.frameNumber
                images[i].exposure = tokens.exposure
                images[i].filter = tokens.filter
                images[i].frameType = tokens.frameType
                images[i].gain = tokens.gain
                images[i].offset = tokens.offset
                images[i].binning = tokens.binning
                images[i].sensorTemp = tokens.sensorTemp
                images[i].telescope = tokens.telescope
                images[i].camera = tokens.camera
                images[i].fwhm = tokens.fwhm
                images[i].focuserTemp = tokens.focuserTemp
                images[i].hfr = tokens.hfr
                images[i].starCount = tokens.starCount
                images[i].batchModified = true
            }
        }

        // Mark header-only modified files
        // (files that were modified but not renamed — still at original URL)
        for i in images.indices {
            if !result.affectedURLs.keys.contains(images[i].url) {
                // Check if this file was in the preview as a header-only change
                // by looking at backup directory contents
                let backupFile = result.backupDirectory.appendingPathComponent(images[i].filename)
                if FileManager.default.fileExists(atPath: backupFile.path) {
                    images[i].batchModified = true
                }
            }
        }

        // Store undo entry
        batchUndoStack.append(BatchUndoEntry(
            backupDirectory: result.backupDirectory,
            result: result,
            timestamp: Date()
        ))

        // Recompute quality scores (filter/exposure may have changed)
        let batchScores = QualityEstimator.computeScores(
            for: images,
            calibrationDB: CalibrationDatabase.shared,
            fingerprint: currentSetupFingerprint
        )
        for i in images.indices {
            images[i].qualityBreakdown = batchScores[images[i].url]
        }

        statusMessage = "Batch: \(result.succeeded) files modified — reload folder to apply header changes"
        needsTableRefresh = true
    }

    func undoBatchRename() {
        guard let entry = batchUndoStack.popLast() else { return }
        let (restored, errors) = BatchOperations.undo(entry: entry)

        // Reload session to pick up restored files
        if let rootURL = sessionRootURL {
            loadSession(url: rootURL)
        }

        if errors.isEmpty {
            statusMessage = "Batch undo: \(restored) files restored"
        } else {
            statusMessage = "Batch undo: \(restored) restored, \(errors.count) errors"
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

    // MARK: - In-App Messaging

    /// Check for messages from Supabase. Called on launch (deferred) and periodically.
    func checkForMessages() {
        Task {
            let message = await AppMessageService.shared.checkForMessages()
            bannerMessage = message
            if let msg = message {
                AppMessageService.shared.recordImpression(messageId: msg.id)
            }
        }
    }

    /// Start periodic message check timer (every hour, but service gates to 24h fetch interval)
    func startMessageCheckTimer() {
        messageCheckTimer?.invalidate()
        messageCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForMessages()
            }
        }
    }

    func dismissBannerMessage() {
        guard let msg = bannerMessage else { return }
        Task {
            await AppMessageService.shared.dismiss(messageId: msg.id)
        }
        withAnimation(.easeOut(duration: 0.3)) {
            bannerMessage = nil
        }
    }

    func snoozeBannerMessage() {
        guard let msg = bannerMessage else { return }
        Task {
            await AppMessageService.shared.snooze(messageId: msg.id)
        }
        withAnimation(.easeOut(duration: 0.3)) {
            bannerMessage = nil
        }
    }

    func respondToBannerMessage(actionType: String, value: String?) {
        guard let msg = bannerMessage else { return }
        Task {
            await AppMessageService.shared.respond(messageId: msg.id, actionType: actionType, value: value)
        }
        // For yes/no/radio/slider: show thank-you then remove
        // The banner view handles the "submitted" state animation
    }
}
