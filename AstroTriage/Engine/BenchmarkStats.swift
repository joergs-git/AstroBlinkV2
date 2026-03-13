// v3.3.0 — Lightweight benchmark timing for session loading performance
import Foundation

// Collects timestamps at key points during session loading.
// Zero overhead: just stores Date() values, no extra computation.
@MainActor
class BenchmarkStats: ObservableObject {

    // Raw timestamps — set once at the corresponding event
    var sessionStartTime: Date?        // User selected folder / files
    var scanCompleteTime: Date?        // File list populated in UI
    var firstImageDisplayTime: Date?   // First image rendered to MTKView
    var headerEnrichStartTime: Date?   // Header reading started
    var headerEnrichEndTime: Date?     // All headers read and applied
    var cachingStartTime: Date?        // Pre-caching pipeline started (decode + STF stretch + preview)
    var cachingEndTime: Date?          // All previews cached
    var quickStackStartTime: Date?     // Quick Stack started
    var quickStackEndTime: Date?       // Quick Stack completed
    var quickStackFrameCount: Int = 0  // Number of frames stacked
    var quickStackEngine: String = "lightspeed"  // "lightspeed" or "normal"
    var quickStackImageWidth: Int = 0
    var quickStackImageHeight: Int = 0

    // Session metadata
    @Published var fileCount: Int = 0
    @Published var totalFileSizeBytes: Int64 = 0  // Sum of all file sizes in session
    @Published var isComplete: Bool = false  // True when caching finishes (or is skipped)

    // MARK: - Computed durations (seconds)

    // a) Total file loading: from user action to file list populated
    var fileLoadingDuration: Double? {
        guard let start = sessionStartTime, let end = scanCompleteTime else { return nil }
        return end.timeIntervalSince(start)
    }

    // b) Time to first image: from user action to first image on screen
    var firstImageDuration: Double? {
        guard let start = sessionStartTime, let end = firstImageDisplayTime else { return nil }
        return end.timeIntervalSince(start)
    }

    // c) Header enrichment duration
    var headerEnrichDuration: Double? {
        guard let start = headerEnrichStartTime, let end = headerEnrichEndTime else { return nil }
        return end.timeIntervalSince(start)
    }

    // d) Pre-caching duration: decode + STF stretch + preview generation for all images
    var cachingDuration: Double? {
        guard let start = cachingStartTime, let end = cachingEndTime else { return nil }
        return end.timeIntervalSince(start)
    }

    // e) Quick Stack duration
    var quickStackDuration: Double? {
        guard let start = quickStackStartTime, let end = quickStackEndTime else { return nil }
        return end.timeIntervalSince(start)
    }

    // f) Total session ready: from user action to everything cached and ready
    var totalSessionDuration: Double? {
        guard let start = sessionStartTime else { return nil }
        // Use the latest of caching end or header end as "fully ready"
        let candidates = [cachingEndTime, headerEnrichEndTime].compactMap { $0 }
        guard let latest = candidates.max() else { return nil }
        return latest.timeIntervalSince(start)
    }

    // MARK: - Recording helpers

    // Reset all timestamps for a new session
    func reset() {
        sessionStartTime = nil
        scanCompleteTime = nil
        firstImageDisplayTime = nil
        headerEnrichStartTime = nil
        headerEnrichEndTime = nil
        cachingStartTime = nil
        cachingEndTime = nil
        quickStackStartTime = nil
        quickStackEndTime = nil
        quickStackFrameCount = 0
        quickStackEngine = "lightspeed"
        quickStackImageWidth = 0
        quickStackImageHeight = 0
        fileCount = 0
        totalFileSizeBytes = 0
        isComplete = false
    }

    func markSessionStart() {
        reset()
        sessionStartTime = Date()
    }

    func markScanComplete(fileCount: Int, totalBytes: Int64) {
        scanCompleteTime = Date()
        self.fileCount = fileCount
        self.totalFileSizeBytes = totalBytes
    }

    // Formatted total file size string (e.g. "23.4 GB" or "850 MB")
    var formattedTotalSize: String {
        let mb = Double(totalFileSizeBytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }

    func markFirstImageDisplayed() {
        // Only record the first time (don't overwrite on subsequent navigations)
        guard firstImageDisplayTime == nil else { return }
        firstImageDisplayTime = Date()
    }

    func markHeaderEnrichStart() {
        headerEnrichStartTime = Date()
    }

    func markHeaderEnrichEnd() {
        headerEnrichEndTime = Date()
    }

    func markCachingStart() {
        cachingStartTime = Date()
    }

    func markCachingEnd() {
        cachingEndTime = Date()
        isComplete = true
    }

    func markQuickStackStart(frameCount: Int, engine: String = "lightspeed", imageWidth: Int = 0, imageHeight: Int = 0) {
        quickStackStartTime = Date()
        quickStackEndTime = nil
        quickStackFrameCount = frameCount
        quickStackEngine = engine
        quickStackImageWidth = imageWidth
        quickStackImageHeight = imageHeight
    }

    func markQuickStackEnd() {
        quickStackEndTime = Date()
    }

    // MARK: - Memory info (snapshot, not continuous polling)

    struct MemorySnapshot {
        let appResidentMB: Double    // App's physical memory usage
        let systemTotalGB: Double    // Total physical RAM
        let swapUsedMB: Double       // Swap usage (0 = no swap pressure)
    }

    // Take a memory snapshot at the time of viewing stats
    nonisolated func captureMemorySnapshot() -> MemorySnapshot {
        // App memory via mach_task_basic_info
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let appMB: Double
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        appMB = result == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : 0

        // System total RAM
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

        // Swap usage via sysctl (xsu_used = actual swap bytes in use)
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapMB: Double
        if sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 {
            swapMB = Double(swapUsage.xsu_used) / (1024 * 1024)
        } else {
            swapMB = 0
        }

        return MemorySnapshot(appResidentMB: appMB, systemTotalGB: totalGB, swapUsedMB: swapMB)
    }

    // Format duration for display
    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 0.1 {
            return String(format: "%.0f ms", seconds * 1000)
        } else if seconds < 1.0 {
            return String(format: "%.0f ms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1f s", seconds)
        } else {
            return String(format: "%.1f min", seconds / 60)
        }
    }
}
