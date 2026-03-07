// v0.9.4
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

        // Use the parent folder of the first file as session root
        let rootURL = imageURLs[0].deletingLastPathComponent()
        sessionRootURL = rootURL
        prefetchCache?.clear()

        // Release previous security-scoped resource
        if let prev = accessedURL {
            prev.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }

        statusMessage = "Loading \(imageURLs.count) files..."

        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [ImageEntry] = []
            let fm = FileManager.default

            for url in imageURLs {
                let tokens = NINAFilenameParser.parse(url.lastPathComponent)
                var entry = MetadataExtractor.extractAndMerge(url: url, filenameParsed: tokens)

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

                self.statusMessage = "\(entries.count) files loaded — pre-caching..."
                self.startFullPrefetch()
            }
        }
    }

    func loadSession(url: URL) {
        isLoading = true
        isCaching = false
        cacheProgress = 0
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

                if isNetwork {
                    self.statusMessage = "Downloading \(entries.count) images to local cache..."
                } else {
                    self.statusMessage = "\(entries.count) images loaded — pre-caching..."
                    self.startFullPrefetch()
                }

                // Security-scoped access tracked in accessedURL, released on next session or quit
            }

            if isNetwork {
                await self?.cacheNetworkFiles()
                await MainActor.run {
                    self?.startFullPrefetch()
                }
            }
        }
    }

    // Start pre-decoding + stretching ALL images (skips already-cached)
    private func startFullPrefetch() {
        guard let prefetchCache = prefetchCache else { return }

        isCaching = true
        cachingStopped = false
        cachingTotal = images.count
        cachingCount = 0
        cacheProgress = 0

        prefetchCache.prefetchAll(images: images) { [weak self] completed, total in
            guard let self = self else { return }
            self.cachingCount = completed
            self.cachingTotal = total
            self.cacheProgress = total > 0 ? Double(completed) / Double(total) : 0

            if completed < total {
                self.statusMessage = "Pre-caching \(completed)/\(total)..."
            } else {
                self.isCaching = false
                self.statusMessage = "\(total) images cached — instant navigation ready"
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
        let cached = prefetchCache?.cachedCount ?? 0
        statusMessage = "Caching paused — \(cached) of \(images.count) images cached"
    }

    // Continue caching from where it left off
    func continueCaching() {
        cachingStopped = false
        startFullPrefetch()
    }

    // Cache all image files from network to local disk
    private func cacheNetworkFiles() async {
        guard let rootURL = sessionRootURL else { return }
        sessionCache.prepareSession(rootURL: rootURL)

        let total = images.count

        // Build a snapshot of URLs to cache (avoid accessing images from background)
        let sourceURLs = images.map { $0.url }

        // Sequential caching to avoid thread-safety issues with network I/O
        // Each file is copied on a background thread, results applied on main actor
        for index in 0..<total {
            let sourceURL = sourceURLs[index]

            let localURL = await Task.detached(priority: .utility) { [sessionCache] () -> URL? in
                return sessionCache.cacheFile(sourceURL: sourceURL)
            }.value

            if let localURL = localURL, index < images.count {
                images[index].decodingURL = localURL
            }

            statusMessage = "Downloading to local cache \(index + 1)/\(total)..."
        }

        statusMessage = "\(total) files cached locally"

        Task.detached(priority: .background) {
            SessionCache.cleanupOldCaches()
        }
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
            // Find next non-marked, wrapping around
            var next = selectedIndex + 1
            if next >= images.count { next = 0 }
            let start = next
            repeat {
                if !images[next].isMarkedForDeletion {
                    selectImage(at: next)
                    return
                }
                next += 1
                if next >= images.count { next = 0 }
            } while next != start
        } else {
            // Wrap around: after last → first
            let next = (selectedIndex + 1) % images.count
            selectImage(at: next)
        }
    }

    func navigatePrevious() {
        guard !images.isEmpty else { return }

        if skipMarked {
            // Find previous non-marked, wrapping around
            var prev = selectedIndex - 1
            if prev < 0 { prev = images.count - 1 }
            let start = prev
            repeat {
                if !images[prev].isMarkedForDeletion {
                    selectImage(at: prev)
                    return
                }
                prev -= 1
                if prev < 0 { prev = images.count - 1 }
            } while prev != start
        } else {
            // Wrap around: before first → last
            let prev = selectedIndex > 0 ? selectedIndex - 1 : images.count - 1
            selectImage(at: prev)
        }
    }

    // MARK: - Skip/Hide Marked

    func toggleSkipMarked() {
        skipMarked.toggle()
        statusMessage = skipMarked ? "Skip marked: ON" : "Skip marked: OFF"
    }

    func toggleHideMarked() {
        hideMarked.toggle()
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
            statusMessage = "Error creating PRE-DELETE folder: \(error.localizedDescription)"
            return
        }

        // Remember the first marked index for re-selection later
        let firstMarkedIndex = images.firstIndex(where: { $0.isMarkedForDeletion }) ?? selectedIndex

        // Move files and build undo entries
        var movedCount = 0
        var failedCount = 0
        var undoEntries: [PreDeleteUndoEntry] = []

        for entry in markedImages {
            let destURL = preDeleteDir.appendingPathComponent(entry.filename)
            do {
                // Handle name collision: add numeric suffix
                var finalDest = destURL
                var suffix = 1
                while fm.fileExists(atPath: finalDest.path) {
                    let name = entry.url.deletingPathExtension().lastPathComponent
                    let ext = entry.url.pathExtension
                    finalDest = preDeleteDir.appendingPathComponent("\(name)_\(suffix).\(ext)")
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

    // MARK: - Stretch Mode

    func toggleStretchMode() {
        guard let renderer = renderer else { return }
        let modeName = renderer.toggleStretchMode()
        statusMessage = modeName

        // Invalidate all cached previews — they were stretched with different params
        prefetchCache?.invalidateAll()

        if renderer.stretchMode == .auto {
            // Re-cache with per-image auto stretch
            statusMessage = "Re-caching with Auto STF..."
            startFullPrefetch()
        } else {
            // Locked mode: re-cache with the locked params
            statusMessage = "Locked STF — re-caching..."
            startFullPrefetch()
        }

        // Force redraw current image from raw data while cache rebuilds
        if let mtkView = findMTKView() {
            if let image = currentDecodedImage {
                renderer.setImage(image, in: mtkView)
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
        if let preview = prefetchCache?.getPreview(for: image.url) {
            currentDecodedImage = nil  // No raw data needed for display
            if selectedIndex >= 0 && selectedIndex < images.count {
                images[selectedIndex].width = preview.originalWidth
                images[selectedIndex].height = preview.originalHeight
                images[selectedIndex].channelCount = preview.channelCount
            }

            // Tell renderer to display the cached texture directly
            if let mtkView = findMTKView(), let renderer = renderer {
                renderer.setPreview(preview, in: mtkView)
            }

            statusMessage = isCaching
                ? "Pre-caching \(cachingCount)/\(cachingTotal)... | \(preview.originalWidth)x\(preview.originalHeight)"
                : "\(preview.originalWidth)x\(preview.originalHeight) \(preview.channelCount == 1 ? "mono" : "RGB")"
            return
        }

        // Slow path: decode on demand (image not yet cached)
        statusMessage = "Loading \(image.filename)..."
        let targetURL = image.url
        let decodeURL = image.decodingURL

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
                    let channels = decoded.channelCount == 1 ? "mono" : "RGB"
                    let bayerInfo = self.selectedImage?.bayerPattern.map { " (\($0) debayer)" } ?? ""
                    self.statusMessage = "\(decoded.width)x\(decoded.height) \(channels)\(bayerInfo)"

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
