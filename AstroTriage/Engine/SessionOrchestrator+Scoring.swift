// Quality scoring + post-scoring cascade extension for SessionOrchestrator.
//
// Step 5: pulls the scoring trigger, SNR retention, convergence detection,
// frame-history persistence, moon data, and Bortle refinement out of
// TriageViewModel. These methods all run after header enrichment finishes,
// or after the user marks/unmarks frames in PRE-DELETE flows — they're
// the "compute and publish" half of the session pipeline.
//
// The methods stay quality-critical: they touch QualityEstimator,
// CalibrationDatabase, ConvergenceDetector, FrameHistoryDatabase, and
// the per-frame qualityBreakdown. Pure mechanical move — kAlgorithmVersion
// stays unchanged because no scoring logic changes here. Golden-Set
// regression run after the move as insurance per CLAUDE.md.
import Foundation

extension SessionOrchestrator {
    // MARK: - Quality Estimation

    /// Delayed quality rescore: catches frames whose MainActor metric callbacks
    /// haven't delivered yet when the initial scoring ran. Retries up to 3 times
    /// at 0.5s intervals until all analyzable frames have quality scores.
    func scheduleQualityRescore() {
        rescoreRetryCount = 0
        scheduleQualityRescoreStep()
    }

    private func scheduleQualityRescoreStep() {
        guard rescoreRetryCount < 3 else { return }
        rescoreRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let host = self.host else { return }
            // Check if any frames have metrics but no quality score
            let unscoredWithMetrics = host.images.filter {
                $0.qualityBreakdown == nil && ($0.noiseMAD != nil || $0.computedStarCount != nil)
            }
            if !unscoredWithMetrics.isEmpty {
                self.recomputeQualityScores()
                host.needsTableRefresh = true
                self.sessionOverviewModel.updateStats(from: host.images)
                // Retry in case more metrics are still arriving
                self.scheduleQualityRescoreStep()
            }
        }
    }

    /// Compute or recompute quality tiers for all images using QualityEstimator.
    /// Called after header enrichment completes (FWHM, HFR, StarCount are now populated).
    /// Also call this after adding a new folder to the session (new images may change group stats).
    func recomputeQualityScores() {
        guard let host = host else { return }
        // Recompute trailing scores with current focal length info (may have been populated
        // by header enrichment since initial star metrics were computed)
        for index in host.images.indices {
            if let details = host.images[index].starDetails, !details.isEmpty {
                let trailing = TrailingAnalyzer.analyze(
                    starDetails: details,
                    focalLength: host.images[index].focalLength,
                    pixelSizeMicrons: host.images[index].pixelSizeMicrons
                )
                if let t = trailing {
                    host.images[index].trailingScore = t.trailingScore
                    host.images[index].trailingPA = t.consensusPA
                    host.images[index].trailingAxisRatio = t.medianAxisRatio
                    host.images[index].trailingConsensus = t.consensusFraction
                }
            }
        }

        // Query historical baselines from Frame History Database (if enough past data exists)
        let histBaselines: HistoricalBaselines? = {
            guard let setupHash = host.currentSetupFingerprint?.hash else { return nil }
            let records = try? FrameHistoryDatabase.shared.historicalFrames(
                setupHash: setupHash,
                excludingSession: host.currentSessionId
            )
            guard let records, records.count >= 30 else { return nil }
            return HistoricalBaselines.build(from: records)
        }()

        // Phase 2 — pull per-setup learned tier offsets if any have been
        // computed (≥50 curated frames per setup). Falls through nil and
        // QualityEstimator uses static defaults.
        let learnedThresholds: LearnedThresholds? = {
            guard let fp = host.currentSetupFingerprint else { return nil }
            return CalibrationDatabase.shared.profile(for: fp).learnedThresholds
        }()

        let scores = QualityEstimator.computeScores(
            for: host.images,
            calibrationDB: CalibrationDatabase.shared,
            fingerprint: host.currentSetupFingerprint,
            communityBaseline: host.communityBaseline,
            historicalBaselines: histBaselines,
            learnedThresholds: learnedThresholds
        )
        for index in host.images.indices {
            host.images[index].qualityBreakdown = scores[host.images[index].url]
        }
        // Notify table that quality column cells need redrawing
        host.needsTableRefresh = true

        // Re-sort directly whenever quality z-scores change.
        // Previously used needsQualityResort flag consumed by FileListView.updateNSView,
        // but the indirect mechanism had timing issues (flag consumed before metrics were ready).
        // Direct sort ensures the correct order immediately after scoring.
        let hasStarMetrics = host.images.contains { $0.computedStarCount != nil || $0.computedFWHM != nil }
        if hasStarMetrics && !scores.isEmpty {
            let uniqueTargets = Set(host.images.compactMap { $0.target?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let uniqueFilters = Set(host.images.compactMap { $0.filter?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let order = ColumnDefinition.recommendedColumnOrder(
                isMultiObject: uniqueTargets.count > 1, isMultiFilter: uniqueFilters.count > 1
            )
            host.applySortByColumnOrder(order)
        }

        let scored = scores.count
        let total  = host.images.count
        let lockedCount = scores.values.filter { $0.isLockedKeep }.count
        if scored > 0 {
            var msg = "Quality scored: \(scored)/\(total) images in \(self.countGroups(scores)) group(s)"
            if lockedCount > 0 {
                msg += " — \(lockedCount) locked KEEP"
            }
            // Show calibration learning status
            if let fp = host.currentSetupFingerprint {
                msg += " [\(CalibrationDatabase.shared.learningStatus(for: fp))]"
            }
            // Phase 2 — surface adapted-threshold provenance so the user can
            // tell whether the current session's tier cutoffs are coming from
            // their own curation or from QualityEstimator's defaults.
            if let lt = learnedThresholds, lt.sampleCount >= LearnedThresholds.learningThreshold {
                msg += " [thresholds adapted from \(lt.sampleCount) curated frames]"
            }
            // Append session guidance hints if applicable
            if let guidance = self.generateSessionGuidance() {
                msg += " | \(guidance)"
            }
            host.statusMessage = msg
        }

        updateConvergence()

        // Save frame records to history database (async, non-blocking)
        saveToFrameHistory()

        // Re-upload curated frames whose quality breakdown changed since initial rating.
        // Fixes race condition: if user rates a frame before scoring completes, the initial
        // upload captures stale quality_tier/z-score/garbage_reasons. This re-sync ensures
        // the Supabase curated_frames table reflects the final scored state.
        let curatedToResync = host.images.filter { $0.userConfidence > 0 && $0.qualityBreakdown != nil && $0.fileHash != nil }
        if !curatedToResync.isEmpty {
            for entry in curatedToResync {
                CurationService.uploadCuratedFrame(entry)
            }
        }
    }

    // MARK: - Moon + Bortle (post-enrichment derived data)

    /// Compute moon phase and distance for all images that have date + location data.
    /// Called during header enrichment when site coordinates become available.
    func computeMoonData() {
        guard let host = host else { return }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.timeZone = TimeZone(identifier: "UTC")

        for index in host.images.indices {
            guard let dateStr = host.images[index].date, let timeStr = host.images[index].time else { continue }
            let dateTimeStr = "\(dateStr) \(timeStr)"
            guard let utcDate = fallbackFormatter.date(from: dateTimeStr) else { continue }

            // Moon illumination (needs only date, no location)
            host.images[index].moonIllumination = MoonCalculator.illumination(utcDate: utcDate)

            // Moon-target distance (needs target RA/Dec)
            if let solvedRA = host.images[index].solvedRA, let solvedDec = host.images[index].solvedDec {
                host.images[index].moonDistance = MoonCalculator.moonTargetDistance(
                    utcDate: utcDate, targetRADeg: solvedRA, targetDecDeg: solvedDec
                )
            } else if let ra = host.images[index].objctRA, let dec = host.images[index].objctDec {
                host.images[index].moonDistance = MoonCalculator.moonTargetDistance(
                    utcDate: utcDate, targetRA: ra, targetDec: dec
                )
            }

            // Bortle class (needs site coordinates)
            if host.images[index].bortleClass == nil,
               let lat = host.images[index].siteLatitude,
               let lon = host.images[index].siteLongitude {
                // Local grid instant (integer precision)
                host.images[index].bortleClass = BortleEstimator.estimate(latitude: lat, longitude: lon).map(Double.init)
            }

            // Canonical target name (normalized for grouping across sessions)
            if host.images[index].canonicalTarget == nil, let target = host.images[index].target {
                host.images[index].canonicalTarget = TargetCatalog.canonicalName(target)
            }
            // Major (parent) target for sub-target association
            if host.images[index].majorTarget == nil, let canonical = host.images[index].canonicalTarget {
                host.images[index].majorTarget = TargetCatalog.majorTarget(canonical)
            }
        }
    }

    /// Refine Bortle values via Supabase (one call per unique lat/lon, not per frame).
    /// Called once after header enrichment completes. Fire-and-forget.
    func refineBortleOnline() {
        guard let host = host else { return }
        // Collect unique coordinates
        var uniqueCoords: [String: (lat: Double, lon: Double, indices: [Int])] = [:]
        for (i, img) in host.images.enumerated() {
            guard let lat = img.siteLatitude, let lon = img.siteLongitude else { continue }
            let key = String(format: "%.2f,%.2f", lat, lon)
            if uniqueCoords[key] == nil {
                uniqueCoords[key] = (lat, lon, [i])
            } else {
                uniqueCoords[key]!.indices.append(i)
            }
        }
        guard !uniqueCoords.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            for (_, coord) in uniqueCoords {
                if let bortle = await BortleEstimator.estimateOnline(latitude: coord.lat, longitude: coord.lon) {
                    await MainActor.run { [weak self] in
                        guard let host = self?.host else { return }
                        for idx in coord.indices where idx < host.images.count {
                            host.images[idx].bortleClass = bortle
                        }
                    }
                }
            }
        }
    }

    // MARK: - Frame History persistence

    /// Save all frame records to the Frame History Database.
    /// Called after quality scoring completes. Runs on a background thread.
    func saveToFrameHistory() {
        guard let host = host else { return }
        guard !host.images.isEmpty else { return }
        let sessionId = host.currentSessionId
        let setupHash = host.currentSetupFingerprint?.hash
        let sessionPath = host.sessionRootURL?.path ?? ""

        // Build records from current image state
        let records: [FrameRecord] = host.images.compactMap { entry in
            guard let hash = entry.fileHash else { return nil }
            return FrameRecord.from(entry: entry, fileHash: hash, sessionId: sessionId, setupHash: setupHash)
        }

        guard !records.isEmpty else { return }

        // Build session record
        let trashCount = host.images.filter { $0.qualityTier == .trash }.count
        let deletedCount = host.images.filter { $0.isMarkedForDeletion }.count
        let sessionRecord = SessionRecord(
            id: sessionId,
            sessionPath: sessionPath,
            observingNight: host.images.first?.observingNight,
            setupHash: setupHash,
            telescope: host.images.first?.telescope,
            camera: host.images.first?.camera,
            target: host.images.first?.target,
            frameCount: host.images.count,
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

    /// Generate session guidance hints about scoring accuracy.
    private func generateSessionGuidance() -> String? {
        guard let host = host else { return nil }
        guard !host.images.isEmpty else { return nil }

        // Build group sizes: filter+object+exposure
        var groupSizes: [String: Int] = [:]
        for entry in host.images {
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
        let uniqueNights = Set(host.images.compactMap { $0.observingNight })
        if uniqueNights.count <= 1 && host.images.count > 10 {
            hints.append("Tip: loading multiple nights improves scoring accuracy")
        }

        return hints.isEmpty ? nil : hints.joined(separator: " | ")
    }

    /// Count distinct groups that produced at least one score.
    private func countGroups(_ scores: [URL: QualityBreakdown]) -> Int {
        guard let host = host else { return 0 }
        // Use a set of GroupKey-equivalent tuples built from scored images
        var groups = Set<String>()
        for entry in host.images where scores[entry.url] != nil {
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
        guard let host = host else { return }
        // Group images by filter+target+exposure (same grouping as QualityEstimator)
        struct GroupKey: Hashable {
            let filter: String; let target: String; let exposure: Int
        }

        var groups: [GroupKey: (totalSNRSq: Double, retainedSNRSq: Double, total: Int, marked: Int)] = [:]
        var fallbackTotal = 0
        var fallbackRetained = 0
        var hasSNRData = false

        for entry in host.images {
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
            host.snrRetention = overall

            if detailLines.isEmpty {
                host.snrRetentionDetail = "SNR Retention: 100%\nNo frames marked for deletion."
            } else {
                let lossPercent = 100.0 - overall
                let markedCount = host.images.filter { $0.isMarkedForDeletion }.count
                let totalExposure = host.images.reduce(0.0) { $0 + ($1.exposure ?? 0) }
                let markedExposure = host.images.filter { $0.isMarkedForDeletion }.reduce(0.0) { $0 + ($1.exposure ?? 0) }
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
                host.snrRetentionDetail = tooltip
            }
        } else {
            // Fallback: simple frame count ratio
            host.snrRetention = fallbackTotal > 0 ? Double(fallbackRetained) / Double(fallbackTotal) * 100.0 : 100.0
            host.snrRetentionDetail = "SNR Retention: \(String(format: "%.1f", host.snrRetention))%\n(Estimated from frame count — noise stats not yet available)"
        }
    }

    // MARK: - Convergence & Stack Readiness

    /// Update culling status after mark/unmark or quality recomputation.
    /// Simple actionable state: how many trash remain, SNR warning, convergence.
    func updateConvergence() {
        guard let host = host else { return }
        let hasScores = host.images.contains { $0.qualityBreakdown != nil }

        guard hasScores else {
            host.cullingStatus = nil
            host.isConverged = false
            host.convergenceResult = nil
            return
        }

        // Run full convergence analysis
        let result = ConvergenceDetector.analyze(
            entries: host.images,
            snrRetention: host.snrRetention,
            calibrationDB: CalibrationDatabase.shared,
            fingerprint: host.currentSetupFingerprint
        )
        host.convergenceResult = result
        host.isConverged = result.isConverged

        // Map convergence result to status bar display
        let unmarkedTrash = host.images.filter { !$0.isMarkedForDeletion && $0.qualityTier == .trash }.count
        let unmarkedBorderline = host.images.filter { !$0.isMarkedForDeletion && $0.qualityTier == .borderline }.count

        if unmarkedTrash > 0 {
            host.cullingStatus = TriageViewModel.CullingStatus(level: .trash, text: "\(unmarkedTrash)\u{00D7} trash remaining")
        } else if result.snrStopReached {
            let snrLossPct = 100.0 - host.snrRetention
            let totalExposure = host.images.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
            let markedExposure = host.images.filter { $0.isMarkedForDeletion }.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
            let integrationLossPct = totalExposure > 0 ? markedExposure / totalExposure * 100 : 0
            host.cullingStatus = TriageViewModel.CullingStatus(
                level: .warning,
                text: "SNR: -\(String(format: "%.0f", snrLossPct))% vs integration -\(String(format: "%.0f", integrationLossPct))%"
            )
        } else if result.isConverged {
            let spreadStr = String(format: "%.2f", result.qualitySpread)
            if unmarkedBorderline > 0 {
                host.cullingStatus = TriageViewModel.CullingStatus(level: .done, text: "Uniform (spread \(spreadStr)) — \(unmarkedBorderline) borderline remain")
            } else {
                host.cullingStatus = TriageViewModel.CullingStatus(level: .done, text: "Culling complete (spread \(spreadStr))")
            }
        } else if unmarkedBorderline > 0 {
            host.cullingStatus = TriageViewModel.CullingStatus(level: .done, text: "Culling done (\(unmarkedBorderline) borderline remain)")
        } else {
            host.cullingStatus = TriageViewModel.CullingStatus(level: .done, text: "Culling complete")
        }
    }
}
