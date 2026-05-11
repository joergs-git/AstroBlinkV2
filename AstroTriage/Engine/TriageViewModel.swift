// v4.3.0
import Foundation
import Combine
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

    /// UI state holder for selection / filter toggles / pending column hints.
    /// Forwarded properties on this view model expose the underlying storage
    /// (selectedIndex, hideMarked, …) so SwiftUI bindings keep working;
    /// stateCancellable wires the sub-object's objectWillChange into ours.
    /// See TriageState.swift for the full motivation.
    let state = TriageState()
    private var stateCancellable: AnyCancellable?

    /// Selected row in the file table. Forwards to TriageState.selectedIndex.
    var selectedIndex: Int {
        get { state.selectedIndex }
        set { state.selectedIndex = newValue }
    }
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
        let width: Int?      // Reference frame dimensions for mixed-sensor guard
        let height: Int?
        // Unweighted mean of detected star positions in full-res pixel coords. Used
        // by the centroid-mirror signal in `shouldRotateForMeridian` to catch flips
        // when PIERSIDE/ROTATOR/WCS are all silent or missing. A flip maps
        // centroid `(cx, cy)` to `(W-cx, H-cy)`; if the frame's centroid is
        // significantly closer to that mirror than to the reference, we flip.
        // nil when the reference frame doesn't have starDetails yet (populated
        // lazily as star metrics arrive during prefetch).
        let starCentroidX: Double?
        let starCentroidY: Double?
        // 32×32 pixel fingerprint of the reference frame. Used by the fingerprint
        // mirror test in `shouldRotateForMeridian` and the tiebreaker in
        // `updateMeridianRotation`. Populated when the reference frame's
        // fingerprint is available (either at detectMeridianFlip time for
        // frames already prefetched, or overwritten by applyWCSAlignment when
        // it picks a different reference frame). Null-safe lookup via
        // referenceFingerprintLookup provides a fallback to any frame of
        // the target that has a fingerprint.
        let fingerprint: [UInt8]?
    }
    private var targetOrientationRefs: [String: OrientationRef] = [:]  // key = canonical target name

    // Frame History: unique session ID for the current session (reset on each folder open).
    // Visibility raised from `private` to default (internal) so SessionOrchestrator can reset
    // it on every loadSession() — see SessionHost protocol.
    var currentSessionId = UUID().uuidString

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
    // Cancellation flag for network downloads (checked per-file in
    // concurrentPerform). nonisolated(unsafe) is correct here — every
    // access goes through the NSLock above, so the storage is thread-safe
    // even though TriageViewModel itself is @MainActor. This lets the
    // nonisolated `isDownloadCancelled` / `setDownloadCancelled` accessors
    // be called from worker threads without trapping.
    nonisolated(unsafe) private let downloadCancelled = NSLock()
    nonisolated(unsafe) private var _downloadCancelled = false
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

    // Blink playback. Timer + index iteration live in PlaybackController;
    // TriageViewModel keeps `isPlaying` and `playbackDelay` as @Published mirrors
    // so existing SwiftUI bindings (toolbar Play button, delay slider) keep working.
    @Published var isPlaying: Bool = false
    @Published var playbackDelay: Double = 0.1 {
        didSet { playback.delaySeconds = playbackDelay }
    }
    private let playback = PlaybackController()

    // Visual Validation (VLM mosaic anomaly detection).
    // @Published mirrors stay here so SwiftUI bindings (toolbar progress,
    // overlay) keep working — orchestrator drives them via SessionHost.
    // The cancellable generation task moved to SessionOrchestrator (step 6).
    @Published var isGeneratingMosaic: Bool = false
    @Published var mosaicProgress: String = ""

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
    /// Pending column order — consumed by FileListView.updateNSView. Forwards to TriageState.
    var pendingColumnOrder: [String]? {
        get { state.pendingColumnOrder }
        set { state.pendingColumnOrder = newValue }
    }

    /// Pending quality-driven re-sort flag. Forwards to TriageState.
    var needsQualityResort: Bool {
        get { state.needsQualityResort }
        set { state.needsQualityResort = newValue }
    }

    // Blind Curation mode — hides all metric columns + quality icons so the user
    // rates frames purely on visual impression (1/2/3 stars → userConfidence).
    // Ground-truth dataset builder: pairs with the Export Curated Dataset feature.
    @Published var isBlindCurationMode: Bool = false
    private var preBlindVisibleColumns: [String]?
    private var preBlindInspectorShown: Bool = false
    // FileListView consumes this and applies a bulk column-visibility change.
    // Set to nil after the change is applied.
    /// Pending column visibility set used when entering / leaving Blind Curation. Forwards to TriageState.
    var pendingColumnVisibility: Set<String>? {
        get { state.pendingColumnVisibility }
        set { state.pendingColumnVisibility = newValue }
    }

    // Minimal column set while in Blind Curation — intentionally excludes every
    // metric column, tier icons, and the feedback column so the user can't see
    // the algorithm's judgment before scoring the frame.
    static let blindCurationColumnIds: [String] = [
        "marked", "frameNumber", "userConfidence",
        "filter", "nightDate", "time", "filename"
    ]

    // Hide marked images: when true, marked images are invisible in the list
    /// Hide marked-for-deletion frames from the file list. Forwards to TriageState.
    var hideMarked: Bool {
        get { state.hideMarked }
        set { state.hideMarked = newValue }
    }

    // Show only marked: inverted view — when true, only marked images are shown
    // Mutually exclusive with hideMarked (Shift+H toggles this)
    /// Inverted view: show ONLY marked frames. Forwards to TriageState.
    var showOnlyMarked: Bool {
        get { state.showOnlyMarked }
        set { state.showOnlyMarked = newValue }
    }

    // Skip marked images during arrow-key navigation
    /// Skip marked frames during arrow-key navigation. Forwards to TriageState.
    var skipMarked: Bool {
        get { state.skipMarked }
        set { state.skipMarked = newValue }
    }

    // Image viewer overlay — big filter letter, time, and 5%-size mini-map
    // pinned to the top-left of the image viewer. Anchored in viewport space
    // (zoom/pan do not affect it). Auto-enabled when entering Blind Curation,
    // restored on exit. Default ON for new installs (see AppSettings.registerDefaults);
    // persisted via AppSettings + iCloud once the user toggles.
    @Published var showViewerOverlay: Bool = true
    // Remembers the user's explicit overlay preference so Blind Curation can
    // auto-enable it and restore the prior value when the user exits blind mode.
    private var preBlindViewerOverlay: Bool = false

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

    // Real-time system stats (CPU + memory), updated every 2 seconds.
    // Equatable so the 2 s timer can no-op when neither field has changed —
    // assigning the same value to a non-Equatable @Published still fires
    // objectWillChange, which previously rebuilt every SwiftUI view bound to
    // the view model 14,400 times overnight even when the strings were
    // identical. With Equatable + a value guard in updateSystemStats(), idle
    // sessions emit zero @Published events from this path.
    struct SystemStats: Equatable {
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

    // Session-lifecycle orchestrator (post-launch refactor, Patch 2).
    // Initialized in init() after prefetchCache; methods migrate over the next slices.
    let orchestrator: SessionOrchestrator

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
    // Visibility raised to internal so SessionOrchestrator can read/mutate via
    // the SessionHost protocol.
    var accessedURLs: [URL] = []

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
    // Internal so SessionOrchestrator can mutate during session loads.
    var multiSourceSession: Bool = false

    // One-time-per-session flag: set after the user confirms the multi-source
    // PRE-DELETE location so subsequent deletes in the same session don't re-prompt.
    // Internal so SessionOrchestrator can reset on every load.
    var multiSourcePreDeleteConfirmed: Bool = false

    /// Stop accessing every URL we currently hold a scope for and clear the list.
    /// Internal so SessionOrchestrator can call between session loads.
    func stopAllAccessedURLs() {
        for u in accessedURLs { u.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
    }

    /// Start security-scoped access to each URL and store those that succeeded.
    /// Callers should call stopAllAccessedURLs() before invoking this to release
    /// any previous session's scopes.
    /// Internal so SessionOrchestrator can claim scopes during loads.
    func beginSecurityScopes(for urls: [URL]) {
        for u in urls {
            if u.startAccessingSecurityScopedResource() {
                accessedURLs.append(u)
            }
        }
    }

    /// Lock-protected read of the NAS download cancellation flag.
    /// Exposed via SessionHost so the orchestrator can observe cancellation
    /// without owning the underlying NSLock. The lock + flag stay private here.
    /// Nonisolated so `DispatchQueue.concurrentPerform` workers can poll it
    /// directly without trapping in `MainActor.assumeIsolated`.
    nonisolated var isDownloadCancelled: Bool {
        downloadCancelled.lock(); defer { downloadCancelled.unlock() }
        return _downloadCancelled
    }

    /// Lock-protected setter for the NAS download cancellation flag.
    /// Used by SessionOrchestrator at the start of every session load to
    /// abort any in-flight downloads from a previous session.
    nonisolated func setDownloadCancelled(_ value: Bool) {
        downloadCancelled.lock(); _downloadCancelled = value; downloadCancelled.unlock()
    }

    init() {
        // All stored properties without inline defaults must be assigned before
        // any `self.x` access. `device`, `prefetchCache`, and `orchestrator` are
        // those properties — initialize them first, then proceed with wiring.
        self.device = MTLCreateSystemDefaultDevice()
        // Falls back to nil only when the system has no Metal device — we still
        // construct the orchestrator in that case so call sites can dispatch
        // through it uniformly.
        let cache = self.device.map { PrefetchCache(device: $0) }
        self.prefetchCache = cache
        // Build the session orchestrator with its long-lived dependencies. The
        // weak host back-reference is wired immediately after init via attach().
        self.orchestrator = SessionOrchestrator(
            prefetchCache: cache,
            benchmarkStats: benchmarkStats,
            benchmarkService: benchmarkService,
            sessionCache: sessionCache,
            sessionOverviewModel: sessionOverviewModel,
            displayAligner: displayAligner
        )

        // Wire playback controller — the controller owns the timer and the
        // index list, this view model owns the published flags and image-array
        // logic. When the timer advances, this hands the new index to selectImage.
        playback.delaySeconds = playbackDelay
        playback.onAdvance = { [weak self] idx in
            guard let self else { return }
            if idx >= 0, idx < self.images.count {
                self.selectImage(at: idx)
            }
        }
        if cache != nil {
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
        if let v = AppSettings.loadBool(for: .nightMode) {
            nightMode = v
        } else {
            // Default night mode to match system dark/light appearance
            nightMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        if let v = AppSettings.loadBool(for: .debayerEnabled) { debayerEnabled = v }
        if let v = AppSettings.loadBool(for: .skipMarked) { skipMarked = v }
        if let v = AppSettings.loadBool(for: .hideMarked) { hideMarked = v }
        if let v = AppSettings.loadBool(for: .autoMeridian) { autoMeridianEnabled = v }
        if let v = AppSettings.loadFloat(for: .fontScale) { fontScale = CGFloat(v) }
        // Right-side Session Overview panel: user-controlled, persists across sessions & iCloud.
        // First-run default remains false (clean single-column layout until user opens it once).
        if let v = AppSettings.loadBool(for: .showSessionOverviewPanel) { showSessionOverview = v }
        if let v = AppSettings.loadBool(for: .showViewerOverlay) { showViewerOverlay = v }

        // Start lightweight system stats polling (CPU + memory every 2s)
        startStatsPolling()

        // Wire the orchestrator's weak back-reference now that self is fully initialized.
        orchestrator.attach(host: self)

        // Forward TriageState's objectWillChange into ours so SwiftUI views
        // observing this view model repaint when the sub-object's @Published
        // storage changes (selectedIndex, hideMarked, skipMarked, …).
        // Without this, mutating viewModel.selectedIndex would update the
        // backing store but not redraw any views bound to viewModel itself.
        stateCancellable = state.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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

        // Only publish when something actually changed. The string formats
        // step in 1 MB / 1 % buckets, so an idle app emits zero updates here
        // — see the Equatable note on SystemStats above.
        let next = SystemStats(memory: memGB, cpu: cpuStr)
        if systemStats != next {
            systemStats = next
        }
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

        // True only when `best` is non-nil AND has a usable tier — keeps the
        // two fallback predicates consistent and removes the need for `best!`.
        func isAcceptable(_ entry: ImageEntry?) -> Bool {
            guard let e = entry else { return false }
            return e.qualityTier == .excellent || e.qualityTier == .good
        }

        // Fallback 1: same filter + same setup, any exposure (e.g., Ha 300s best is garbage → try Ha 180s)
        if !isAcceptable(best) {
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
        if !isAcceptable(best) {
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

        // Each orchestrator entry point internally re-wires the session overview
        // tap callbacks, so no separate wireSessionOverviewCallbacks() call is
        // needed here.
        if directories.count == 1 && files.isEmpty {
            // Single directory — standard folder scan
            orchestrator.loadSession(url: directories[0])
        } else if directories.count >= 1 && files.isEmpty {
            // Multiple directories only — merge into one session
            orchestrator.loadMultipleFolders(urls: directories)
        } else if directories.isEmpty && !files.isEmpty {
            // Individual files only — no folders picked
            orchestrator.loadFiles(urls: files)
        } else {
            // Mixed selection: files + at least one folder. Pre-v5.22.1 silently
            // dropped the folders because loadFiles filtered by .fits extension.
            // Now we route through a dedicated mixed path that scans every picked
            // directory and merges each picked file as its own ImageEntry.
            orchestrator.loadMixedSelection(files: files, directories: directories)
        }
    }

    /// Thin forwarder so external callers (drag-and-drop in ContentViewSupport)
    /// don't need to know about the orchestrator. Kept on the view model until
    /// later slices when the orchestrator's API replaces direct view-model calls.
    func loadSession(url: URL) {
        orchestrator.loadSession(url: url)
    }

    // Tracks whether caching was stopped by user (for continue button).
    // @Published so SwiftUI bindings on the toolbar's continue button update;
    // the cache lifecycle itself is now driven by SessionOrchestrator (step 3).
    @Published var cachingStopped: Bool = false

    /// Stop the current caching process (keeps already-cached previews).
    /// Thin forwarder — the cache pipeline lives on SessionOrchestrator.
    /// External callers in ContentView's pause/continue toolbar binding.
    func stopCaching() {
        orchestrator.stopCaching()
    }

    /// Continue caching from where it left off.
    /// Thin forwarder — see stopCaching above.
    func continueCaching() {
        orchestrator.continueCaching()
    }

    // MARK: - Scoring Forwarders
    //
    // Quality scoring, SNR retention, and convergence detection live on
    // SessionOrchestrator+Scoring.swift after step 5. The forwarders here
    // exist because PRE-DELETE / batch-op flows in this file and external
    // bindings in ContentViewSupport drive them after every mark/unmark.

    /// Recompute SNR retention after mark/unmark toggles.
    func recomputeSNRRetention() {
        orchestrator.recomputeSNRRetention()
    }

    /// Refresh culling status / convergence after mark/unmark or scoring changes.
    func updateConvergence() {
        orchestrator.updateConvergence()
    }

    // MARK: - VLM Mosaic Forwarders
    //
    // VLM mosaic generation + Claude Vision anomaly detection live on
    // SessionOrchestrator+VLM.swift after step 6. Forwarders kept so the
    // toolbar buttons in ContentView can keep calling viewModel.startVisualValidation()
    // / viewModel.cancelVisualValidation() without needing the orchestrator handle.

    /// Generate mosaic wallpapers and present the visual validation window.
    func startVisualValidation() {
        orchestrator.startVisualValidation()
    }

    /// Cancel an in-progress VLM mosaic generation.
    func cancelVisualValidation() {
        orchestrator.cancelVisualValidation()
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
            await MainActor.run { [weak self] in
                guard let self, self.selectedImage?.url == targetURL else { return }
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
        orchestrator.startFullPrefetch()
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

        // Skip rotation for frames with different dimensions than the reference.
        // Mixed sensor sizes (e.g. ASI6200 9576×6388 vs ASI2600 6248×4176)
        // cannot be meaningfully rotation-matched across different cameras.
        if let refW = ref.width, let refH = ref.height,
           let entW = entry.width, let entH = entry.height,
           (refW != entW || refH != entH) {
            return false
        }

        // OR logic across signals — any hit means the frame needs a 180° flip.
        //
        // Rotator is deliberately NOT part of this chain: across the 6 210-frame
        // corpus many targets show rotator delta between sessions that does
        // NOT correspond to a physical image rotation (manual recalibration,
        // rotator home resets, camera re-mount). Arbitrary rotations are
        // captured by the precise `headerRotationDeg` path, not this binary
        // signal — see `updateMeridianRotation`.

        // Signal 1: PIERSIDE change — reliable within and across sessions
        // because pier side is a physical mount state, not a software setting.
        if let refSide = ref.pierSide, let entrySide = entry.pierSide,
           refSide.uppercased() != entrySide.uppercased() {
            return true
        }

        // Signal 2: Star-centroid mirror test.
        //
        // Runs when the first three signals are silent or missing — typical case
        // for frames captured without a plate solver, without PIERSIDE, and on a
        // mount that doesn't log rotator angle (or where the rotator physically
        // didn't move during the flip).
        //
        // A physical 180° rotation maps the reference's centroid `(cx, cy)` to
        // `(W-cx, H-cy)`. For asymmetric star fields — galaxies, bright stars
        // near an edge, gradient-induced detection bias — this produces a
        // measurable displacement. We flip when:
        //   • the reference centroid is clearly off-center (≥8% of each dim
        //     from image center — small asymmetries are noise),
        //   • the frame's centroid is at least 2× closer to the mirrored
        //     position than to the reference position.
        //
        // The 2× margin keeps normal dithers/drift (20–200 px) from flipping
        // anything, because a real flip produces a much bigger displacement
        // (typically > 400 px for an off-center reference).
        if let refCX = ref.starCentroidX, let refCY = ref.starCentroidY,
           let details = entry.starDetails,
           let c = Self.meanStarCentroid(of: details),
           let w = entry.width ?? ref.width, let h = entry.height ?? ref.height,
           w > 0, h > 0 {
            let centerX = Double(w) / 2.0
            let centerY = Double(h) / 2.0
            let refOffFracX = (refCX - centerX).magnitude / Double(w)
            let refOffFracY = (refCY - centerY).magnitude / Double(h)
            let refIsOffCenter = max(refOffFracX, refOffFracY) >= 0.08
            if refIsOffCenter {
                let distToRef = hypot(c.x - refCX, c.y - refCY)
                let mirX = Double(w) - refCX
                let mirY = Double(h) - refCY
                let distToMirror = hypot(c.x - mirX, c.y - mirY)
                if distToMirror < distToRef * 0.5 {
                    return true
                }
            }
        }

        // Signal 3: 32×32 pixel fingerprint mirror test.
        //
        // The last-resort signal — runs on raw pixel structure so it's
        // immune to missing headers (the 20.8 % of frames without PIERSIDE
        // or rotator, mostly RASA setups) and to rotation-invariant star
        // fields where triangle matching fails. Uses the reference
        // fingerprint stored on OrientationRef by detectMeridianFlip or
        // applyWCSAlignment so both pipelines compare against the same
        // canonical reference frame; falls back to a per-target scan if
        // the ref doesn't have a fingerprint yet.
        if let entryFP = entry.orientationFingerprint {
            let refFP = ref.fingerprint ?? self.referenceFingerprintLookup(targetKey: targetKey)
            if let refFP = refFP,
               OrientationFingerprint.mirrorIsBetterMatch(reference: refFP, frame: entryFP) {
                return true
            }
        }

        return false
    }

    /// Find the first frame belonging to a target that has a computed
    /// orientation fingerprint. Used as the reference fingerprint for the
    /// pixel-based mirror test. Returns nil if no frame of this target has
    /// a fingerprint yet (e.g. prefetch hasn't touched the reference).
    ///
    /// O(n) first call per target; callers should avoid hammering this on
    /// every display tick — the current path only invokes it inside
    /// `shouldRotateForMeridian`, which itself is called once per frame
    /// display.
    private func referenceFingerprintLookup(targetKey: String) -> [UInt8]? {
        // Uses the INSTANCE's canonicalTargetKey so the lookup key matches the
        // full `Target|Scope|FL|Cam` grouping used everywhere else. Also
        // opportunistically caches the discovered fingerprint back onto the
        // target's OrientationRef so subsequent lookups hit the fast path in
        // O(1) instead of scanning `images` again.
        for img in images {
            if canonicalTargetKey(for: img) == targetKey,
               let fp = img.orientationFingerprint {
                if var ref = targetOrientationRefs[targetKey], ref.fingerprint == nil {
                    ref = OrientationRef(
                        pierSide: ref.pierSide,
                        rotatorAngle: ref.rotatorAngle,
                        wcsRotation: ref.wcsRotation,
                        width: ref.width,
                        height: ref.height,
                        starCentroidX: ref.starCentroidX,
                        starCentroidY: ref.starCentroidY,
                        fingerprint: fp
                    )
                    targetOrientationRefs[targetKey] = ref
                }
                return fp
            }
        }
        return nil
    }

    /// Unweighted mean (centroid) of detected star positions in full-res pixel
    /// coords. Returns nil if fewer than 3 stars are available — below that the
    /// asymmetry signal is too noisy to be trustworthy for flip detection.
    static func meanStarCentroid(of details: [StarDetail]?) -> (x: Double, y: Double)? {
        guard let details = details, details.count >= 3 else { return nil }
        var sx = 0.0, sy = 0.0
        for d in details { sx += Double(d.x); sy += Double(d.y) }
        let n = Double(details.count)
        return (sx / n, sy / n)
    }

    // Update display alignment for the currently displayed image.
    //
    // Preference order:
    //   1. Star-based alignment transform (sub-pixel precise), IF its rotation
    //      is within 15° of the header-derived rotation angle — or there is no
    //      header-derived rotation to validate against.
    //   2. Header-derived rotation transform (precise to whatever the rotator/
    //      WCS headers give), for cases where:
    //        • star matching failed or wasn't run yet, OR
    //        • the matcher landed on a spurious rotation (common on rotation-
    //          invariant star fields where triangle ratios alone can't
    //          disambiguate the match).
    //      Uses `AffineTransform2D.rotationAroundCenterNormalized(-θ)` so the
    //      applied rotation EXACTLY undoes the physical camera rotation
    //      between reference and current frame — not just a 180° snap.
    //   3. Clean 180° flip for the legacy case: PIERSIDE differs but no
    //      rotator angle available (no way to compute a precise θ).
    //   4. Identity.
    func updateMeridianRotation() {
        guard let renderer = renderer else { return }
        guard let entry = selectedImage else {
            renderer.displayTransform = .identity
            renderer.rotate180 = false
            if let mtkView = findMTKView() { mtkView.needsDisplay = true }
            return
        }

        // Precise header-derived rotation in degrees (or nil if no header signal
        // or the net rotation is below the significance threshold). This is the
        // ground-truth target — `headerRotationDeg` combines PIERSIDE flip
        // (180°) with signed rotator/WCS differences.
        let headerRotDeg: Double? = {
            guard autoMeridianEnabled else { return nil }
            let key = canonicalTargetKey(for: entry)
            guard let ref = targetOrientationRefs[key] else { return nil }
            return Self.headerRotationDeg(entry: entry, ref: ref)
        }()

        if autoMeridianEnabled, let transform = entry.alignmentTransform {
            // Use the precise per-frame transform — but cross-check it with
            // the pixel-level fingerprint before blindly trusting.
            //
            // The transform's failure modes (each addressed below):
            //   (a) Triangle matcher returned a spurious near-identity on a
            //       rotation-invariant star field while a flip is physically
            //       needed. Detected when: transform rot ≈ 0° but headers
            //       strongly insist on a flip AND the fingerprint confirms
            //       the mirror is a much better match.
            //   (b) Plate solver returned a 90°-off false solution
            //       (happens on repetitive star fields, especially across
            //       sessions where we can't sanity-check against rotator).
            //       Detected when: transform rot ≥ 45° BUT the fingerprint
            //       says the mirror (= 180° flip) is a much better match —
            //       which can only be true if the transform's rotation is
            //       wrong. Reject the transform and apply a 180° flip.
            //
            // In all other cases — transform near-identity with no flip
            // needed, transform with ≈180° rotation agreeing with fingerprint,
            // non-trivial rotation without fingerprint disagreement — trust
            // the transform.
            let transformRotDeg = Double(atan2f(transform.c, transform.a) * 180.0 / .pi)
            let transformIsNearIdentity = transformRotDeg.magnitude < 15.0
            let transformIsSignificantlyRotated = transformRotDeg.magnitude >= 45.0
            let headerSaysBigRotation: Bool = {
                guard let h = headerRotDeg else { return false }
                return h.magnitude >= 45.0
            }()

            // Does the pixel fingerprint say the frame is a 180° flip of the
            // reference? Lookup uses the ref's cached fingerprint first (same
            // across both WCS-picked ref and detectMeridianFlip ref — see
            // applyWCSAlignment), falling back to a per-target scan.
            let fingerprintSaysFlip: Bool = {
                guard let entryFP = entry.orientationFingerprint else { return false }
                let tk = canonicalTargetKey(for: entry)
                let refFP: [UInt8]? = targetOrientationRefs[tk]?.fingerprint
                    ?? self.referenceFingerprintLookup(targetKey: tk)
                guard let refFP = refFP else { return false }
                return OrientationFingerprint.mirrorIsBetterMatch(reference: refFP, frame: entryFP)
            }()

            // Case (b): transform rotated but fingerprint says the real relationship
            // is a 180° mirror — transform is wrong (likely a plate-solve 90° off).
            // Force a clean 180° flip from the header path.
            // Case (a): transform near-identity but headers + fingerprint agree on flip.
            let isCaseB = transformIsSignificantlyRotated && fingerprintSaysFlip
            let isCaseA = transformIsNearIdentity && headerSaysBigRotation && fingerprintSaysFlip

            if (isCaseA || isCaseB), let h = headerRotDeg {
                let theta = Float(-h * .pi / 180.0)
                renderer.displayTransform = AffineTransform2D.rotationAroundCenterNormalized(theta)
                renderer.rotate180 = false
                let why = isCaseB
                    ? "transform claims \(String(format: "%.1f", transformRotDeg))° but fingerprint says mirror (plate-solve 90°-off?)"
                    : "spurious identity, fingerprint confirms flip"
                print("[Meridian] \(entry.filename): \(why), applying 180° via header rot=\(String(format: "%.1f", h))°")
            } else if isCaseB {
                // Transform wrong (per fingerprint) and we have no header angle
                // to fall back to — best we can do is rotate 180°, which is
                // what the fingerprint implies.
                renderer.displayTransform = AffineTransform2D.rotate180Normalized
                renderer.rotate180 = false
                print("[Meridian] \(entry.filename): transform rot=\(String(format: "%.1f", transformRotDeg))° contradicts fingerprint mirror — forcing 180°")
            } else {
                // Transform looks legit; trust it for sub-pixel alignment.
                renderer.displayTransform = transform
                renderer.rotate180 = false
            }
        } else if autoMeridianEnabled, let h = headerRotDeg {
            // No star alignment available but headers give us a precise angle —
            // apply exact rotation (not just a 180° snap).
            let theta = Float(-h * .pi / 180.0)
            renderer.displayTransform = AffineTransform2D.rotationAroundCenterNormalized(theta)
            renderer.rotate180 = false
        } else if autoMeridianEnabled, shouldRotateForMeridian(entry) {
            // Legacy path: headers say "flip" but we couldn't compute a precise
            // angle (e.g. PIERSIDE differs, no rotator/WCS available). Clean 180°.
            renderer.displayTransform = .identity
            renderer.rotate180 = true
        } else {
            renderer.displayTransform = .identity
            renderer.rotate180 = false
        }

        if let mtkView = findMTKView() { mtkView.needsDisplay = true }
    }

    /// Header-derived rotation in degrees that, when inverted and applied as
    /// a display transform, aligns `entry` to the per-target reference.
    /// Returns nil when no reliable header signal is available.
    ///
    /// Signal sources (in priority order):
    ///   1. **WCS rotation diff** — ground truth when both frames have
    ///      plate-solve data (CROTA2 or CD matrix). Captures the actual sky
    ///      orientation regardless of what the mount or rotator did.
    ///   2. **PIERSIDE binary flip** — 180° when pier sides differ. Reliable
    ///      across sessions because pier side is a physical mount state.
    ///
    /// Rotator angle diff is DELIBERATELY NOT used: across 6 210 frames in
    /// the local Frame History DB, many targets (Cosmic Horseshoe, M81 …)
    /// show the rotator taking 7–13 distinct positions across sessions,
    /// reflecting manual recalibrations / home-resets / camera re-mounts
    /// that aren't captured in the header — the rotator delta then does NOT
    /// correspond to an actual image rotation. Star matching (empirical)
    /// handles arbitrary camera rotations correctly; the fingerprint signal
    /// handles the "no pier no stars" fallback.
    private static func headerRotationDeg(entry: ImageEntry, ref: OrientationRef) -> Double? {
        // 1. WCS path: most accurate when available (derived from actual stars).
        if let refWCS = ref.wcsRotation, let entryWCS = entry.wcsRotation {
            let diff = signedAngleDiff(entryWCS, refWCS)
            return diff.magnitude >= 5.0 ? diff : nil
        }

        // 2. PIERSIDE binary flip (180°).
        if let refSide = ref.pierSide, let entrySide = entry.pierSide,
           refSide.uppercased() != entrySide.uppercased() {
            return 180.0
        }

        return nil
    }

    /// Shortest signed angular difference (a - b) in degrees, normalised to
    /// (-180°, 180°]. Positive = a is counter-clockwise of b.
    private static func signedAngleDiff(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d >   180 { d -= 360 }
        while d <= -180 { d += 360 }
        return d
    }

    // Assign unique 1-based session indices to all images
    func assignSessionIndices() {
        for i in images.indices {
            images[i].sessionIndex = i + 1  // 1-based for user display
        }
        // Reset AIsaac state tracking when a new session is loaded
        AIsaacWindowController.shared.model.resetStateTracking()
        AIsaacWindowController.shared.model.clearConversation()
    }

    // Detect orientation changes across a session (multi-night, multi-target).
    // Builds per-target reference from the first image of each target group,
    // then uses the unified `shouldRotateForMeridian` logic to decide whether
    // any frame needs flipping — guarantees the summary count, the per-frame
    // display decision, and the UI-enable state all use the exact same rules.
    func detectMeridianFlip() {
        targetOrientationRefs.removeAll()

        // Build per-target reference orientation from first image of each target
        for img in images {
            let key = canonicalTargetKey(for: img)
            if targetOrientationRefs[key] == nil {
                let c = Self.meanStarCentroid(of: img.starDetails)
                targetOrientationRefs[key] = OrientationRef(
                    pierSide: img.pierSide,
                    rotatorAngle: img.rotatorAngle,
                    wcsRotation: img.wcsRotation,
                    width: img.width,
                    height: img.height,
                    starCentroidX: c?.x,
                    starCentroidY: c?.y,
                    fingerprint: img.orientationFingerprint
                )
            }
        }

        var flipCount = 0
        var totalChecked = 0
        for img in images {
            let key = canonicalTargetKey(for: img)
            guard targetOrientationRefs[key] != nil else { continue }

            // hasMeridianFlip must be set before calling shouldRotateForMeridian,
            // but we're computing it below — bypass that gate for the survey pass.
            let wasGate = hasMeridianFlip
            hasMeridianFlip = true
            let needsFlip = shouldRotateForMeridian(img)
            hasMeridianFlip = wasGate

            if needsFlip { flipCount += 1 }
            totalChecked += 1
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

    /// Canonical orientation-grouping key: `target | telescope | focalLength | camera`.
    ///
    /// Why per-setup and not per-target: each setup has its own rotator-
    /// encoder zero, its own plate scale, and its own WCS solve quality.
    /// When frames of a target were captured across multiple setups (e.g.
    /// RC12 native + RC12red08 focal-reduced), merging them into a single
    /// group forces the auto-rotate logic to compare rotator values /
    /// fingerprint patterns / WCS transforms that are structurally
    /// different — and the only reliable cross-setup alignment signal
    /// (WCS math) requires BOTH frames to be plate-solved. Frames captured
    /// before WCS was enabled (typically older RC12 sessions) can't be
    /// cross-aligned and would render as chaos when grouped with newer
    /// WCS-capable frames. Keeping orientation groups per-setup means each
    /// group is internally consistent — that's the strongest guarantee we
    /// can make with the data available.
    ///
    /// Trade-off: frames from different setups will render in setup-local
    /// orientations when blinking. Within one setup (the common case —
    /// most sessions use a single rig) everything is consistent.
    ///
    /// Falls back to "UNKNOWN" when the target name is missing.
    private func canonicalTargetKey(for entry: ImageEntry) -> String {
        let targetName: String
        if let target = entry.target, !target.isEmpty {
            targetName = TargetCatalog.canonicalName(target)
        } else {
            targetName = "UNKNOWN"
        }
        let scope = entry.telescope ?? ""
        let cam = entry.camera ?? ""
        let fl = entry.focalLength.map { String(Int($0.rounded())) } ?? ""
        return "\(targetName)|\(scope)|\(fl)|\(cam)"
    }

    /// Detect mixed image dimensions after header enrichment and warn the user.
    /// Different cameras (e.g. ASI6200 full-frame 9576×6388 vs ASI2600 APS-C 6248×4176)
    /// produce images with vastly different star counts and FOV. Quality scoring separates
    /// them into distinct groups via GroupKey, but the user should know about the mix.
    func checkForMixedDimensions() {
        let withDims = images.filter { $0.width != nil && $0.height != nil }
        let dimensionGroups = Dictionary(grouping: withDims) { "\($0.width!)×\($0.height!)" }
        guard dimensionGroups.count > 1 else { return }

        let sorted = dimensionGroups.sorted { $0.value.count > $1.value.count }
        let descriptions = sorted.map { "\($0.key) (\($0.value.count) frames)" }
        print("[Session] Mixed image dimensions detected: \(descriptions.joined(separator: ", "))")

        // Collect camera names per dimension group for informative display
        let details = sorted.map { (dim, frames) -> String in
            let cameras = Set(frames.compactMap { $0.camera }).sorted()
            let cameraInfo = cameras.isEmpty ? "" : " — \(cameras.joined(separator: ", "))"
            return "  • \(dim): \(frames.count) frames\(cameraInfo)"
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Mixed Sensor Dimensions Detected"
        alert.informativeText = """
        This session contains images with different resolutions:
        \(details)

        Quality scoring automatically groups frames by resolution, so each \
        sensor is compared against its own peers. Auto-rotation is skipped \
        for frames that don't match the reference dimensions.

        For best results, load each camera setup in a separate folder.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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
    func applyWCSAlignment() {
        // Collect entries that have complete WCS data, grouped by target
        var targetEntries: [String: [(idx: Int, wcs: DisplayAligner.WCSData)]] = [:]
        for (idx, entry) in images.enumerated() {
            guard let wcs = PrefetchCache.wcsDataIfComplete(entry) else { continue }
            let key = canonicalTargetKey(for: entry)
            targetEntries[key, default: []].append((idx, wcs))
        }

        guard !targetEntries.isEmpty else { return }

        var updatedCount = 0
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

            // Synchronise the header-path reference with the WCS-chosen one.
            // Previously `detectMeridianFlip` built `targetOrientationRefs`
            // from the first frame in load order, while `applyWCSAlignment`
            // chose its reference from the median CRVAL across plate-solved
            // frames — when the two picked frames had different pier sides
            // and/or different rotator positions, the WCS-aligned 58 frames
            // and the header-aligned 256 frames ended up in *different*
            // orientations on the same target, visible as a 180° offset
            // between the two groups while blinking. Overwriting the header
            // ref with the WCS-chosen one means both pipelines agree on
            // "what reference orientation means".
            let refEntry = images[refIdx]
            let refCentroid = Self.meanStarCentroid(of: refEntry.starDetails)
            targetOrientationRefs[targetKey] = OrientationRef(
                pierSide: refEntry.pierSide,
                rotatorAngle: refEntry.rotatorAngle,
                wcsRotation: refEntry.wcsRotation,
                width: refEntry.width,
                height: refEntry.height,
                starCentroidX: refCentroid?.x,
                starCentroidY: refCentroid?.y,
                fingerprint: refEntry.orientationFingerprint
            )

            // Apply WCS-based transform to every frame in this target group.
            //
            // Sanity check against rotator: plate solvers occasionally lock onto
            // a 90°-rotated false solution on repetitive star fields, which
            // produces a WCS transform with a large apparent rotation even when
            // the camera physically didn't move. When BOTH frame and reference
            // report nearly-identical rotator angles (Δ < 5° → same session,
            // same rotator calibration → camera definitely didn't rotate), any
            // WCS-implied rotation greater than 45° must be a plate-solve error.
            // Reject the transform for that frame — it will fall through to the
            // header/fingerprint pipeline which is more robust on ambiguous
            // plate solves.
            let refRotator = images[refIdx].rotatorAngle
            let refTelescope = images[refIdx].telescope
            let refObservingNight = images[refIdx].observingNight
            var wcsRejectedCount = 0

            for entry in entries {
                guard let width = images[entry.idx].width,
                      let height = images[entry.idx].height,
                      width > 0, height > 0
                else { continue }

                guard let pixelTransform = DisplayAligner.transformFromWCS(
                    frame: entry.wcs, reference: refWCS
                ) else { continue }

                // Rotation embedded in the WCS transform (pixel-space 2×2 block).
                let wcsRotationDeg = Double(atan2f(pixelTransform.c, pixelTransform.a)) * 180.0 / .pi

                // Within-session consistency gate: require same observing night,
                // same telescope (= same rotator zero) AND same physical rotator
                // angle. When the rotator hasn't moved, no WCS rotation is
                // physically possible; anything ≥ 45° means the plate solver
                // found a rotationally-ambiguous false solution.
                let frameEntry = images[entry.idx]
                let sameSetup = (frameEntry.telescope == refTelescope)
                let sameNight = (frameEntry.observingNight != nil &&
                                 frameEntry.observingNight == refObservingNight)
                let rotatorMatches: Bool = {
                    guard let rRef = refRotator, let rFrame = frameEntry.rotatorAngle else { return false }
                    var d = rFrame - rRef
                    while d > 180 { d -= 360 }
                    while d <= -180 { d += 360 }
                    return d.magnitude < 5.0
                }()

                if sameSetup, sameNight, rotatorMatches, wcsRotationDeg.magnitude > 45.0 {
                    // Plate-solve rotational outlier — discard this frame's WCS
                    // transform so `updateMeridianRotation` can use the header /
                    // fingerprint path instead.
                    wcsRejectedCount += 1
                    continue
                }

                let inv = pixelTransform.inverse ?? .identity
                images[entry.idx].alignmentTransform = inv.normalized(width: width, height: height)
                updatedCount += 1
            }

            if wcsRejectedCount > 0 {
                print("[AutoRotate] \(targetKey): rejected \(wcsRejectedCount) frame(s) with bad plate-solve rotation (rotator says no rotation, WCS says ≥ 45°)")
            }

            // NOTE: the former "rotator-fallback" branch used to synthesize an
            // alignmentTransform from `rotator_frame − rotator_ref` for frames
            // without WCS data. That math is only valid when the rotator
            // encoder hasn't been re-homed or recalibrated between captures —
            // an assumption that routinely fails across sessions (homed at a
            // different zero, camera re-mounted, etc.). Empirical DB survey
            // showed 7–13 distinct rotator positions per target across
            // sessions — i.e. the rotator delta is ambiguous between
            // "real camera rotation" and "rotator recalibration". Leaving
            // `alignmentTransform` nil for WCS-less frames now lets
            // `updateMeridianRotation` fall back to the correct pipeline:
            // PIERSIDE binary flip (reliable, physical mount state) →
            // centroid/fingerprint mirror test (pixel-based, immune to
            // recalibration noise).
        }

        print("[AutoRotate] WCS alignment: \(updatedCount) frames via WCS, 0 via rotator-fallback (disabled), \(targetEntries.count) target group(s); reference: \(referenceLog.joined(separator: ", "))")

        // Echo the post-sync targetOrientationRefs so the log shows the *final*
        // reference used by the header-based fallback pipeline. Previously the
        // `[Meridian]` line printed before this function ran, so it showed the
        // first-in-list reference — misleading when applyWCSAlignment picks a
        // different frame as its WCS ref and synchronises both pipelines to it.
        for (target, ref) in targetOrientationRefs {
            let refDesc = [
                ref.pierSide.map { "pier=\($0)" },
                ref.rotatorAngle.map { String(format: "rot=%.0f°", $0) },
                ref.wcsRotation.map { String(format: "wcs=%.1f°", $0) },
                ref.fingerprint != nil ? "fingerprint=YES" : "fingerprint=no"
            ].compactMap { $0 }.joined(separator: ", ")
            print("[Meridian] post-sync ref \(target): \(refDesc)")
        }
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

    // Zoom in by step (5% steps below 25%, 25% steps above)
    func zoomIn() {
        guard let current = trueZoomPct() else { return }
        let nextPct: Double
        if current < 25 {
            // Fine 5% steps below 25%
            nextPct = (floor(current / 5.0) + 1) * 5
        } else {
            nextPct = (floor(current / 25.0) + 1) * 25
        }
        setTrueZoom(min(nextPct, 800))
    }

    // Zoom out by step (25% steps above 25%, 5% steps below)
    func zoomOut() {
        guard let current = trueZoomPct() else { return }
        let nextPct: Double
        if current <= 25 {
            // Fine 5% steps below 25%
            nextPct = (ceil(current / 5.0) - 1) * 5
        } else {
            nextPct = (ceil(current / 25.0) - 1) * 25
        }
        setTrueZoom(max(nextPct, 5))
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

    // Move selection by `rows` (signed; negative = up, positive = down).
    // Respects skipMarked: counts only unmarked frames towards the page step,
    // landing on the n-th unmarked frame in the requested direction. Clamps
    // to the first/last (unmarked) frame when the step would overshoot.
    func navigateByPage(_ rows: Int) {
        guard !images.isEmpty, rows != 0 else { return }
        let step = rows > 0 ? 1 : -1
        let count = abs(rows)
        var index = selectedIndex
        var moved = 0
        var lastValid = index
        while moved < count {
            let next = index + step
            if next < 0 || next >= images.count { break }
            index = next
            if !skipMarked || !images[index].isMarkedForDeletion {
                lastValid = index
                moved += 1
            }
        }
        if lastValid != selectedIndex {
            selectImage(at: lastValid)
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

    // MARK: - Blink Playback

    /// Start blinking through images. Uses highlighted rows if multi-selected,
    /// otherwise all currently visible (unhidden/filtered) images.
    func startPlayback(highlightedRows: IndexSet?) {
        guard !images.isEmpty else { return }

        // Build list of indices to cycle through — always respect visibility
        let indices: [Int]
        if let rows = highlightedRows, rows.count > 1 {
            // Multi-selected rows are table rows (visible list indices) — map to real indices
            let visible = visibleImages
            indices = rows.compactMap { row -> Int? in
                guard row < visible.count else { return nil }
                return images.firstIndex(where: { $0.url == visible[row].url })
            }
        } else {
            // All visible images — map to their real indices in the images array
            let visible = visibleImages
            indices = visible.compactMap { entry in
                images.firstIndex(where: { $0.url == entry.url })
            }
        }
        guard !indices.isEmpty else { return }

        // Start at current image if it's in the list, otherwise start from beginning
        let startPos = indices.firstIndex(of: selectedIndex) ?? 0

        playback.delaySeconds = playbackDelay
        playback.start(indices: indices, startAt: startPos)
        isPlaying = true
    }

    func stopPlayback() {
        isPlaying = false
        playback.stop()
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
        let cropW: Int
        let cropH: Int
        if let r = cropRect {
            cropW = Int(r.width * CGFloat(srcW))
            cropH = Int(r.height * CGFloat(srcH))
        } else {
            cropW = srcW
            cropH = srcH
        }
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
                                           onProgress: { [weak self] p in Task { @MainActor [weak self] in self?.videoExportProgress = p } })
                } else {
                    try await Self.writeBlinkMOV(textures: textures, loops: loops, outputURL: outputURL,
                                                 width: outW, height: outH, fps: fps, cropRect: cropRect,
                                                 onProgress: { [weak self] p in Task { @MainActor [weak self] in self?.videoExportProgress = p } })
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
                guard let dest = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    // Lock succeeded technically but base address is nil — drop this frame
                    // rather than crash mid-export. Unlock first to keep CV's refcount sane.
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    continue
                }
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
        var autoMarked = 0
        for idx in rows where idx >= 0 && idx < images.count {
            let current = images[idx].userConfidence
            let newVal = (current == rating) ? 0 : rating
            images[idx].userConfidence = newVal
            lastRating = newVal
            changed += 1

            // 1-star = garbage: auto-mark for deletion so user doesn't need Space.
            // One-way only — clearing 1-star does NOT auto-unmark (image may have
            // been marked independently by algorithm or Space key).
            if newVal == 1 && !images[idx].isMarkedForDeletion {
                images[idx].isMarkedForDeletion = true
                autoMarked += 1
            }

            // Persist to Frame History DB if file hash available
            if let hash = images[idx].fileHash {
                let conf = newVal
                Task {
                    try? FrameHistoryDatabase.shared.updateUserConfidence(
                        fileHash: hash, confidence: conf)
                }

                // Mirror to Supabase curated_frames so the ground-truth label
                // is queryable from any future session via MCP. Fire-and-forget.
                // newVal > 0 → upsert; newVal == 0 → delete the stale row.
                if newVal > 0 {
                    CurationService.uploadCuratedFrame(images[idx])
                } else {
                    CurationService.deleteCuratedFrame(fileHash: hash)
                }
            }
        }

        needsTableRefresh = true
        if lastRating == 0 {
            statusMessage = "Cleared confidence rating for \(changed) frame\(changed == 1 ? "" : "s")"
        } else {
            // 1-star uses outline ☆ to visually distinguish garbage
            let stars = lastRating == 1 ? "☆" : String(repeating: "★", count: lastRating)
            let markNote = autoMarked > 0 ? " + marked for deletion" : ""
            statusMessage = "\(stars) confidence set for \(changed) frame\(changed == 1 ? "" : "s")\(markNote)"
        }

        // Update SNR retention bar if any frames were auto-marked
        if autoMarked > 0 { recomputeSNRRetention() }
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

        // Use current sessionRootURL (may have been updated by folder access grant
        // above, or reset to nil if the user revoked access mid-flow).
        guard let sessionRoot = sessionRootURL else {
            statusMessage = "Session folder unavailable — reopen the folder and try again"
            return
        }
        let activePreDeleteDir = sessionRoot.appendingPathComponent("PRE-DELETE", isDirectory: true)

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

        // Commit retained frames to the calibration database (for learning)
        // and upload the anonymous session summary to the community service.
        // Both happen inside SessionOrchestrator.commitSession (step 7) so the
        // PRE-DELETE flow only has to invoke a single session-lifecycle hook.
        orchestrator.commitSession()

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
            // In Blind Curation, suppress the Quality Metrics section so the
            // algorithm's tier / z-scores / reasoning stay hidden. Raw FITS
            // keywords still show — the user can peek if they really want to,
            // but the explicit algorithm verdict is gone.
            if isBlindCurationMode {
                headerInspectorModel.updateQualityMetrics(from: nil, entry: nil)
            } else {
                headerInspectorModel.updateQualityMetrics(from: image.qualityBreakdown, entry: image)
            }
        }
    }

    // MARK: - Blind Curation Mode

    /// Toggle Blind Curation mode. Hides every metric column + quality tier icon +
    /// the Quality Metrics section of the Header Inspector so the user rates frames
    /// purely on visual impression. 1/2/3 keys still work (→ userConfidence).
    /// Prior column layout and Header Inspector visibility are restored on exit.
    func toggleBlindCurationMode() {
        if !isBlindCurationMode {
            // Entering blind mode
            guard !images.isEmpty else {
                statusMessage = "Blind Curation: load a session first"
                return
            }
            preBlindVisibleColumns = AppSettings.loadStrings(for: .visibleColumns)
                ?? ColumnDefinition.allColumns.filter(\.isDefaultVisible).map(\.identifier)
            preBlindInspectorShown = showInspector
            showInspector = false
            pendingColumnVisibility = Set(Self.blindCurationColumnIds)
            // Force the viewer overlay on for blind curation — the user can't see
            // column metadata, so they need filter + time + mini-map floating over
            // the image. Remember the prior state so we can restore on exit.
            preBlindViewerOverlay = showViewerOverlay
            showViewerOverlay = true
            isBlindCurationMode = true
            needsTableRefresh = true
            statusMessage = "Blind Curation ON — rate frames with 1/2/3, ⌘⇧B to exit"
        } else {
            // Exiting blind mode — restore prior layout
            let prior = preBlindVisibleColumns
                ?? ColumnDefinition.allColumns.filter(\.isDefaultVisible).map(\.identifier)
            pendingColumnVisibility = Set(prior)
            isBlindCurationMode = false
            showInspector = preBlindInspectorShown
            showViewerOverlay = preBlindViewerOverlay
            preBlindVisibleColumns = nil
            needsTableRefresh = true
            let rated = images.filter { $0.userConfidence > 0 }.count
            statusMessage = "Blind Curation OFF — rated \(rated)/\(images.count) frames"
        }
    }

    /// Toggle the floating viewer overlay (filter letter / time / mini-map, top-left).
    /// Independent of Blind Curation — useful at any time for at-a-glance context
    /// while zoomed in.
    func toggleViewerOverlay() {
        showViewerOverlay.toggle()
        AppSettings.saveBool(showViewerOverlay, for: .showViewerOverlay)
        statusMessage = showViewerOverlay
            ? "Image overlay ON — filter / time / mini-map"
            : "Image overlay OFF"
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
    // Setters internal so SessionOrchestrator can update them when starting an
    // interleaved NAS prefetch (it needs to seed the applied-* mirrors before
    // dispatching to PrefetchCache); see SessionHost protocol.
    var appliedStretch: Float = STFCalculator.defaultTargetBackground
    var appliedSharpening: Float = 0.0
    var appliedContrast: Float = 0.0
    var appliedDarkLevel: Float = 0.0
    var appliedLocked: Bool = false  // Were locked STF params baked in?

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
            orchestrator.startFullPrefetch()
        }
    }

    // Internal: run the apply-all re-cache with current settings
    func triggerApplyAll() {
        appliedStretch = stretchStrength
        appliedSharpening = sharpening
        appliedContrast = contrast
        appliedDarkLevel = darkLevel
        appliedLocked = isSTFLocked
        prefetchCache?.invalidateAll()
        statusMessage = "Applying settings to all images..."
        orchestrator.startFullPrefetch()
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
        orchestrator.startFullPrefetch()

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

        // Sort comparator — pure function over a pair of ImageEntry, no
        // captures of the (potentially stale) sorted snapshot.
        let comparator: (ImageEntry, ImageEntry) -> Bool = { a, b in
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

        let sortInfo = descriptors.map { d in
            "\(d.key ?? "?") \(d.ascending ? "↑" : "↓")"
        }.joined(separator: " > ")

        // Defer the @Published mutation off the current runloop tick. Two
        // callers (FileListView.updateNSView line ~149 and ~179) are inside
        // a SwiftUI update closure, where mutating an owned ObservableObject
        // produces the "Publishing changes from within view updates" runtime
        // warning. Dispatching pushes it to the next tick.
        //
        // We sort IN PLACE on `self.images` instead of pre-sorting a snapshot
        // and reassigning. Reassignment would silently overwrite any prefetch
        // metric callback (noiseStats / starMetrics) that landed on
        // `self.images[idx]` between the snapshot capture and the dispatch
        // execution — that race left 40+ frames per session permanently
        // unrated on fast f/2.2 loads where the prefetch pipeline finishes
        // a wave of measurements in exactly that gap.
        DispatchQueue.main.async {
            self.images.sort(by: comparator)
            if let url = selectedURL,
               let idx = self.images.firstIndex(where: { $0.url == url }) {
                self.selectedIndex = idx
            }
            self.needsTableRefresh = true
            self.statusMessage = "Sorted: \(sortInfo)"
        }
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
    func displayCurrentImage() {
        guard let image = selectedImage, let device = device else { return }

        currentDecodeTask?.cancel()

        // GBE disabled for now
        // if gradientRemovalEnabled { gradientRemovalEnabled = false }

        // Update header inspector model (panel updates reactively via SwiftUI).
        // Blind Curation suppresses the Quality Metrics section so the algorithm's
        // tier / z-scores / reasoning don't leak into the user's rating.
        headerInspectorModel.update(for: image.decodingURL, filename: image.filename)
        if isBlindCurationMode {
            headerInspectorModel.updateQualityMetrics(from: nil, entry: nil)
        } else {
            headerInspectorModel.updateQualityMetrics(from: image.qualityBreakdown, entry: image)
        }

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
                },
                onOrientationFingerprint: { [weak self] url, fp in
                    guard let self = self else { return }
                    if let idx = self.images.firstIndex(where: { $0.url == url }) {
                        self.images[idx].orientationFingerprint = fp
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

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
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
    func checkForReviewPrompt() {
        let count = (AppSettings.defaults.object(forKey: AppSettings.Key.sessionCount.rawValue) as? Int ?? 0) + 1
        AppSettings.defaults.set(count, forKey: AppSettings.Key.sessionCount.rawValue)

        // Trigger on 5th and every 50th session after that (Apple rate-limits anyway)
        let reviewDue = (count == 5) || (count > 5 && count % 50 == 0)

        // Review prompt fires at 2s — Apple rate-limits this anyway and the user
        // is just landing on the session, so a quick prompt is fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if reviewDue {
                SKStoreReviewController.requestReview()
            }
        }

        // Coffee dialog fires at 120s — gives the user real time to use the app
        // before being asked for support, feels much less pushy than firing on
        // session-load. Skipped entirely when the review prompt is due so the
        // two prompts can't stack on the same session.
        if !reviewDue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120.0) { [weak self] in
                guard let self else { return }
                CoffeeSupportDialog.presentIfDue(
                    currentSessionCount: count,
                    nightMode: self.nightMode
                )
            }
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

// MARK: - SessionHost conformance
//
// All members required by SessionHost already exist on TriageViewModel.
// Conformance is declared in an extension to keep the main class body
// untouched and to make the seam visible while session methods migrate
// into SessionOrchestrator over the next refactor slices.
extension TriageViewModel: SessionHost {}
