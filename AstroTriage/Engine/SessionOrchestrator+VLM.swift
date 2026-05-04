// VLM mosaic + visual-validation extension for SessionOrchestrator.
//
// Step 6: pulls the Claude Vision anomaly-detection workflow out of
// TriageViewModel. The methods orchestrate three things end-to-end:
//   1. Collect cached preview textures from PrefetchCache for the
//      active or highlighted frame set.
//   2. Hand them to MosaicGenerator on a background task to render
//      one composite image per group.
//   3. Optionally route those mosaics through VisualAnomalyDetector
//      (Supabase edge function with on-device API-key fallback) and
//      surface anomalies in VisualValidationWindow.
//
// Mosaic + Claude-Vision state (isGeneratingMosaic, mosaicProgress)
// stays as @Published mirrors on TriageViewModel so existing SwiftUI
// progress bindings keep working. Orchestrator drives them through
// SessionHost. The cancellable handle for the in-flight generation
// task lives on the orchestrator since only these methods touch it.
import Foundation
import Metal

extension SessionOrchestrator {
    /// Generate mosaic wallpapers from remaining frames and show in floating window.
    /// Optionally runs Claude Vision anomaly detection if API key is available.
    /// If files are highlighted (multi-selected), uses those regardless of mark status.
    /// Otherwise uses all unmarked frames.
    func startVisualValidation() {
        guard let host = host else { return }
        guard !host.images.isEmpty else { return }
        host.isGeneratingMosaic = true
        host.mosaicProgress = "Collecting preview textures..."

        // Determine frame set: highlighted selection (any status) or all unmarked.
        // Require >= 2 highlighted — single selection is just normal navigation focus.
        let highlighted = host.selectedEntries
        let useHighlighted = highlighted.count >= 2
        let highlightedURLs = Set(highlighted.map { $0.url })

        // Collect textures from PrefetchCache (we're @MainActor, so this is safe)
        var textures: [URL: MTLTexture] = [:]
        for entry in host.images {
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
        let totalTarget = useHighlighted ? highlighted.count : host.images.filter { !$0.isMarkedForDeletion }.count
        let scope = useHighlighted ? "highlighted" : "active"
        host.mosaicProgress = "Generating mosaics (\(cachedCount)/\(totalTarget) \(scope) cached)..."

        // Capture immutable copies for background work
        let entriesCopy = host.images
        let texturesCopy = textures
        let skipDeletionFilter = useHighlighted
        let rotationCheck: (ImageEntry) -> Bool = { [weak self] entry in
            self?.host?.shouldRotateForMeridian(entry) ?? false
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
                    self?.host?.mosaicProgress = "Generating mosaic \(completed)/\(total)..."
                }
            }

            // Check cancellation before presenting results
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.host?.isGeneratingMosaic = false
                    self.host?.mosaicProgress = ""
                    self.host?.statusMessage = "VLM Check cancelled"
                    self.vlmGenerationTask = nil
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self = self, let host = self.host else { return }
                host.isGeneratingMosaic = false
                self.vlmGenerationTask = nil

                if pages.isEmpty {
                    host.statusMessage = "Not enough cached frames for mosaic (need ≥4 per group)"
                    return
                }

                // Show floating mosaic window
                let jumpTo: (Int) -> Void = { [weak host] entryIndex in
                    host?.selectImage(at: entryIndex)
                }
                let markFrames: ([Int]) -> Void = { [weak host] entryIndices in
                    guard let host = host else { return }
                    for idx in entryIndices where host.images.indices.contains(idx) {
                        host.images[idx].isMarkedForDeletion = true
                    }
                    host.needsTableRefresh = true
                    let marked = entryIndices.count
                    host.statusMessage = "Marked \(marked) VLM-flagged frames for deletion"
                }

                let analyzeCallback: ([MosaicPage]) -> Void = { [weak self] pagesToAnalyze in
                    self?.runVisualAnalysis(pages: pagesToAnalyze)
                }
                let unmarkFrames: ([Int]) -> Void = { [weak host] entryIndices in
                    guard let host = host else { return }
                    for idx in entryIndices where host.images.indices.contains(idx) {
                        host.images[idx].isMarkedForDeletion = false
                    }
                    host.needsTableRefresh = true
                    host.statusMessage = "Unmarked \(entryIndices.count) VLM-flagged frames"
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
                host.statusMessage = "Mosaic: \(pages.count) group(s), \(tileCount) tiles\(scopeLabel)\(centerInfo) — click Analyze for VLM check"
            }
        }
    }

    /// Cancel an in-progress VLM mosaic generation.
    func cancelVisualValidation() {
        guard let host = host else { return }
        vlmGenerationTask?.cancel()
        vlmGenerationTask = nil
        host.isGeneratingMosaic = false
        host.mosaicProgress = ""
        host.statusMessage = "VLM Check cancelled"
    }

    /// Run Claude Vision anomaly detection on generated mosaics.
    /// Routes through Supabase edge function (works out of the box, no API key needed).
    /// Falls back to user's own API key if edge function is unavailable.
    func runVisualAnalysis(pages: [MosaicPage]) {
        guard let host = host else { return }
        host.mosaicProgress = "Analyzing with Claude Vision..."
        let wc = VisualValidationWindowController.shared
        wc.updateAnalysisProgress("Sending \(pages.count) mosaic(s) to Claude Vision...")

        Task { [weak self] in
            let detector = VisualAnomalyDetector()
            do {
                let results = try await detector.analyzeAll(
                    pages: pages
                ) { completed, total, status in
                    Task { @MainActor [weak self] in
                        self?.host?.mosaicProgress = "Analyzing \(completed)/\(total): \(status)"
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
                await MainActor.run {
                    guard let host = self?.host else { return }
                    wc.updateAnomalies(merged)
                    let remaining = detector.remainingChecks.map { " (\($0) checks remaining today)" } ?? ""
                    host.statusMessage = "Visual check: \(totalAnomalies) anomalies in \(pages.count) group(s)\(remaining)"
                    host.mosaicProgress = ""
                }
                print("[VLM] Analysis complete: \(totalAnomalies) anomalies across \(results.count) groups")
            } catch {
                let errMsg = error.localizedDescription
                await MainActor.run {
                    guard let host = self?.host else { return }
                    host.statusMessage = "Visual analysis: \(errMsg)"
                    host.mosaicProgress = ""
                    wc.analysisFinished(error: errMsg)
                }
                print("[VLM] Analysis error: \(errMsg)")
            }
        }
    }
}
