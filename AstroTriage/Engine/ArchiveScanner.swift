import Foundation
import Metal

/// Background folder crawler that builds the Frame History Database from existing image archives.
/// Recursively scans a root folder, decodes each FITS/XISF file, computes quality metrics,
/// and saves results to the database — without requiring interactive triage sessions.
///
/// Features:
/// - Resumable: stores progress in scan_progress table (crash-safe)
/// - Exclusion rules: skips calibration frames, PixInsight files, already-processed images
/// - Low priority: .utility QoS to not interfere with interactive use
/// - Batch processing: 50 files at a time, releases memory between batches
class ArchiveScanner: ObservableObject {
    static let shared = ArchiveScanner()

    // MARK: - Published State

    @Published var isScanning = false
    @Published var isPaused = false
    @Published var currentFolder: String = ""
    @Published var totalFound: Int = 0
    @Published var totalProcessed: Int = 0
    @Published var filesPerSecond: Double = 0
    @Published var estimatedSecondsRemaining: Int?
    @Published var scanSessionId: String = ""

    // MARK: - Private State

    private var scanTask: Task<Void, Never>?
    private var device: MTLDevice?
    private var generator: PreviewGenerator?
    private let batchSize = 50
    private var startTime: Date?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Exclusion Rules

    /// Folder names to skip entirely (case-insensitive, exact match)
    private static let excludedFolders: Set<String> = [
        "dark", "darks", "flat", "flats", "bias", "darkflat", "darkflats",
        "calibration", "calibrate", "masters",
        "subframeselector", "weightedbatchpreprocessing", "wbpp",
        "_predel", ".ds_store", "__macosx",
        "pixinsight", "processed", "integration"
    ]

    /// Keywords that indicate calibration frames — if ANY of these appear anywhere
    /// in the filename OR any parent folder name, the file is skipped.
    /// Case-insensitive substring match. Catches: "FlatWizard", "DARK_", "MasterBias", etc.
    private static let calibrationKeywords: [String] = [
        "flat", "dark", "bias", "defect", "masterbias", "masterdark", "masterflat",
        "flatwizard", "darkframe", "biasframe", "calibrat"
    ]

    /// Filename prefixes to skip (case-insensitive)
    private static let excludedPrefixes: [String] = [
        "dark_", "flat_", "bias_", "master", "defect"
    ]

    /// File extensions to skip
    private static let excludedExtensions: Set<String> = [
        "xosm", "xdrz", "xpsm", "psm", "pi", "tif", "tiff",
        "png", "jpg", "jpeg", "cr2", "cr3", "nef", "arw"
    ]

    /// Valid image extensions we process
    private static let validExtensions: Set<String> = [
        "fits", "fit", "fts", "xisf"
    ]

    // MARK: - Public API

    /// Start scanning a root folder. Checks for existing incomplete scan to resume.
    func startScan(rootURL: URL) {
        guard !isScanning else { return }

        guard let dev = MTLCreateSystemDefaultDevice() else {
            print("ArchiveScanner: no Metal device")
            return
        }
        device = dev
        generator = PreviewGenerator(device: dev)

        scanSessionId = UUID().uuidString
        isScanning = true
        isPaused = false
        startTime = Date()

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runScan(rootURL: rootURL)
        }
    }

    /// Resume an incomplete scan from where it stopped.
    func resumeScan(rootPath: String) {
        guard !isScanning else { return }
        let url = URL(fileURLWithPath: rootPath)
        guard FileManager.default.fileExists(atPath: rootPath) else {
            print("ArchiveScanner: root path no longer accessible: \(rootPath)")
            return
        }
        startScan(rootURL: url)
    }

    /// Pause the current scan (can be resumed).
    func pauseScan() {
        isPaused = true
    }

    /// Resume after pause.
    func unpauseScan() {
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    /// Cancel the current scan.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    /// Check for incomplete scans in the database.
    /// Returns the root paths of scans that didn't finish.
    static func incompleteScanPaths() -> [(rootPath: String, processed: Int, total: Int, lastUpdated: String)] {
        guard let db = try? FrameHistoryDatabase.shared.incompleteScanProgress() else { return [] }
        return db
    }

    // MARK: - Scan Engine

    private func runScan(rootURL: URL) async {
        let rootPath = rootURL.path

        // Discover all image files recursively
        await MainActor.run {
            self.currentFolder = "Discovering files..."
            self.totalFound = 0
            self.totalProcessed = 0
        }

        let allFiles = discoverFiles(in: rootURL)
        let total = allFiles.count

        await MainActor.run {
            self.totalFound = total
        }

        guard total > 0 else {
            await MainActor.run {
                self.isScanning = false
                self.currentFolder = "No image files found"
            }
            return
        }

        // Check for existing progress (resume point)
        let existingProgress = try? FrameHistoryDatabase.shared.scanProgress(for: rootPath)
        var startIndex = 0
        if let progress = existingProgress, !progress.isComplete.toBool {
            // Find the index of the last scanned path
            if let lastPath = progress.lastScannedPath,
               let idx = allFiles.firstIndex(where: { $0.path > lastPath }) {
                startIndex = idx
                await MainActor.run {
                    self.totalProcessed = progress.totalProcessed
                }
            }
        }

        // Save initial progress
        let iso = ISO8601DateFormatter()
        let now = iso.string(from: Date())
        let initialProgress = ScanProgress(
            rootPath: rootPath,
            lastScannedPath: existingProgress?.lastScannedPath,
            totalFound: total,
            totalProcessed: startIndex,
            startedAt: existingProgress?.startedAt ?? now,
            lastUpdatedAt: now,
            isComplete: 0
        )
        try? FrameHistoryDatabase.shared.saveScanProgress(initialProgress)

        // Process in batches
        let sessionId = scanSessionId
        var processed = startIndex

        for batchStart in stride(from: startIndex, to: total, by: batchSize) {
            guard !Task.isCancelled else { break }

            // Handle pause
            if await MainActor.run(body: { self.isPaused }) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        self.pauseContinuation = continuation
                    }
                }
            }
            guard !Task.isCancelled else { break }

            let batchEnd = min(batchStart + batchSize, total)
            let batch = Array(allFiles[batchStart..<batchEnd])

            await MainActor.run {
                if let first = batch.first {
                    self.currentFolder = first.deletingLastPathComponent().lastPathComponent
                }
            }

            // Process batch — update UI per file for responsive progress
            var records: [FrameRecord] = []
            for url in batch {
                guard !Task.isCancelled else { break }

                // Skip if already in DB
                let hash = FileHasher.hash(for: url)
                if let hash, (try? FrameHistoryDatabase.shared.recordExists(fileHash: hash)) == true {
                    processed += 1
                    let p = processed; let si = startIndex
                    await MainActor.run { self.updateProgress(processed: p, total: total, startIndex: si) }
                    continue
                }

                // Update current file name
                let filename = url.lastPathComponent
                await MainActor.run { self.currentFolder = filename }

                if let record = processFile(url: url, fileHash: hash, sessionId: sessionId) {
                    records.append(record)
                }
                processed += 1

                // Update UI after each file
                let p = processed; let si = startIndex
                await MainActor.run { self.updateProgress(processed: p, total: total, startIndex: si) }
            }

            // Save batch to DB
            if !records.isEmpty {
                try? FrameHistoryDatabase.shared.saveFrameRecords(records)
            }

            // Save scan progress checkpoint
            let lastPath = batch.last?.path
            let progressUpdate = ScanProgress(
                rootPath: rootPath,
                lastScannedPath: lastPath,
                totalFound: total,
                totalProcessed: processed,
                startedAt: existingProgress?.startedAt ?? now,
                lastUpdatedAt: iso.string(from: Date()),
                isComplete: 0
            )
            try? FrameHistoryDatabase.shared.saveScanProgress(progressUpdate)
        }

        // Mark scan as complete
        if !Task.isCancelled {
            let finalProgress = ScanProgress(
                rootPath: rootPath,
                lastScannedPath: allFiles.last?.path,
                totalFound: total,
                totalProcessed: processed,
                startedAt: existingProgress?.startedAt ?? now,
                lastUpdatedAt: iso.string(from: Date()),
                isComplete: 1
            )
            try? FrameHistoryDatabase.shared.saveScanProgress(finalProgress)
        }

        // Post-scan: compute quality tiers for all scanned frames grouped by setup+target+filter+exposure
        if !Task.isCancelled {
            await MainActor.run { self.currentFolder = "Computing quality scores..." }
            computeQualityTiersForScannedFrames(sessionId: sessionId)
        }

        // Export to iCloud
        FrameHistoryDatabase.shared.exportToICloud()

        await MainActor.run {
            self.isScanning = false
            self.currentFolder = Task.isCancelled ? "Scan cancelled" : "Scan complete"
            self.estimatedSecondsRemaining = nil
        }

        // Cleanup
        generator = nil
        device = nil
    }

    /// Update progress UI (called on MainActor).
    @MainActor
    private func updateProgress(processed: Int, total: Int, startIndex: Int) {
        self.totalProcessed = processed
        if let start = self.startTime {
            let elapsed = Date().timeIntervalSince(start)
            let done = processed - startIndex
            if done > 0 && elapsed > 0 {
                self.filesPerSecond = Double(done) / elapsed
                let remaining = total - processed
                self.estimatedSecondsRemaining = Int(Double(remaining) / self.filesPerSecond)
            }
        }
    }

    // MARK: - File Discovery

    /// Recursively discover all valid image files, applying exclusion rules.
    /// Returns sorted by path for deterministic resume.
    private func discoverFiles(in rootURL: URL) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                let folderName = url.lastPathComponent.lowercased()
                // Skip excluded folders (exact match) and calibration folders (substring match)
                if Self.excludedFolders.contains(folderName) ||
                   SessionScanner.isFolderCalibration(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            guard Self.validExtensions.contains(ext) else { continue }

            let filename = url.lastPathComponent
            let filenameLower = filename.lowercased()
            // Skip hidden files
            if filenameLower.hasPrefix(".") { continue }
            // Skip excluded prefixes
            if Self.excludedPrefixes.contains(where: { filenameLower.hasPrefix($0) }) { continue }

            // Skip calibration frames: uses SessionScanner's detection (NINA token parsing + keyword fallback)
            // Also checks full path for calibration keywords in ANY parent folder
            if SessionScanner.isFileCalibration(filename) { continue }

            // Extra safety: check full path for calibration keywords in parent folders
            // Catches: ".../FlatWizard_06-38.../file.xisf", ".../DarkFrames/file.fits"
            let fullPath = url.deletingLastPathComponent().path.lowercased()
            if Self.calibrationKeywords.contains(where: { fullPath.contains($0) }) { continue }

            result.append(url)
        }

        // Sort by path for deterministic resume
        result.sort { $0.path < $1.path }
        return result
    }

    // MARK: - Single File Processing

    /// Process one file: read headers, decode, measure noise/stars, compute trailing, build record.
    /// Returns nil if file can't be decoded.
    private func processFile(url: URL, fileHash: String?, sessionId: String) -> FrameRecord? {
        guard let device, let generator else { return nil }

        // 1. Compute file hash if not already provided
        let hash = fileHash ?? FileHasher.hash(for: url)
        guard let hash else { return nil }

        // 2. Read headers for metadata
        let headers = MetadataExtractor.readHeaders(from: url)
        let tokens = NINAFilenameParser.parse(url.lastPathComponent)

        // 3. Build a lightweight ImageEntry from headers + filename
        var entry = ImageEntry(url: url)
        entry.fileHash = hash

        // Apply filename tokens
        entry.date = tokens.date
        entry.time = tokens.time
        entry.filter = tokens.filter
        entry.exposure = tokens.exposure
        entry.target = tokens.target
        entry.frameNumber = tokens.frameNumber
        entry.gain = tokens.gain
        entry.offset = tokens.offset
        entry.binning = tokens.binning
        entry.sensorTemp = tokens.sensorTemp
        entry.telescope = tokens.telescope
        entry.camera = tokens.camera
        entry.fwhm = tokens.fwhm
        entry.hfr = tokens.hfr
        entry.starCount = tokens.starCount

        // Apply headers (override filename tokens with authoritative header values)
        applyHeaders(&entry, from: headers)

        // 4. Decode image for metrics
        let decodeResult = ImageDecoder.decode(url: url, device: device)
        guard case .success(let decoded) = decodeResult else { return nil }

        entry.width = decoded.width
        entry.height = decoded.height
        entry.channelCount = decoded.channelCount

        // 5. Measure noise (STF subsample — ~2ms)
        let noiseStats = STFCalculator.measureNoise(from: decoded)
        entry.noiseMedian = noiseStats.median
        entry.noiseMAD = noiseStats.normalizedMAD

        // 6. GPU star detection + CPU metrics (~5-7ms)
        let channel = decoded.channelCount == 3 ? 1 : 0
        let stars = generator.detectStarsFromImage(decoded, channel: channel)
        let totalStarCount = generator.lastTotalStarCount

        if !stars.isEmpty {
            if let metrics = StarMetricsCalculator.measure(
                stars: stars, fullResImage: decoded, channel: channel,
                totalStarCount: totalStarCount,
                arcsecPerPixel: entry.arcsecPerPixel
            ) {
                entry.computedHFR = metrics.medianHFR > 0 ? metrics.medianHFR : nil
                entry.computedFWHM = metrics.medianFWHM > 0 ? metrics.medianFWHM : nil
                entry.computedStarCount = metrics.totalStarCount
                entry.computedEccentricity = metrics.medianEccentricity
                entry.starChainFraction = metrics.starChainFraction
                entry.psfFluxSum = metrics.psfFluxSum > 0 ? metrics.psfFluxSum : nil

                // Trailing analysis
                if !metrics.starDetails.isEmpty {
                    if let trailing = TrailingAnalyzer.analyze(
                        starDetails: metrics.starDetails,
                        focalLength: entry.focalLength,
                        pixelSizeMicrons: entry.pixelSizeMicrons
                    ) {
                        entry.trailingScore = trailing.trailingScore
                        entry.trailingPA = trailing.consensusPA
                        entry.trailingAxisRatio = trailing.medianAxisRatio
                        entry.trailingConsensus = trailing.consensusFraction
                    }
                }
            } else {
                entry.computedStarCount = totalStarCount
            }
        }

        // 7. Compute moon data
        if let dateStr = entry.date, let timeStr = entry.time {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let utcDate = formatter.date(from: "\(dateStr) \(timeStr)") {
                entry.moonIllumination = MoonCalculator.illumination(utcDate: utcDate)
                if let solvedRA = entry.solvedRA, let solvedDec = entry.solvedDec {
                    entry.moonDistance = MoonCalculator.moonTargetDistance(
                        utcDate: utcDate, targetRADeg: solvedRA, targetDecDeg: solvedDec
                    )
                } else if let ra = entry.objctRA, let dec = entry.objctDec {
                    entry.moonDistance = MoonCalculator.moonTargetDistance(
                        utcDate: utcDate, targetRA: ra, targetDec: dec
                    )
                }
            }
        }

        // 8. Twilight phase
        if let dateStr = entry.date, let timeStr = entry.time,
           let lat = entry.siteLatitude, let lon = entry.siteLongitude {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let utcDate = formatter.date(from: "\(dateStr) \(timeStr)") {
                entry.twilightPhase = SunCalculator.twilightPhase(
                    utcDate: utcDate, latitude: lat, longitude: lon
                )
            }
        }

        // 9. File size
        entry.fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)

        // 10. Build setup hash for grouping
        let setupHash = SetupFingerprint(
            telescope: entry.telescope, camera: entry.camera,
            focalLength: entry.focalLength, pixelSizeMicrons: entry.pixelSizeMicrons
        ).hash

        // Build FrameRecord (no quality tier — batch scan doesn't run group scoring)
        return FrameRecord.from(entry: entry, fileHash: hash, sessionId: sessionId, setupHash: setupHash)
    }

    // MARK: - Header Application (lightweight, same logic as TriageViewModel)

    private func applyHeaders(_ entry: inout ImageEntry, from headers: [String: String]) {
        // Helper: only override if header value is non-empty (preserves filename-parsed values
        // when FITS headers are blank — common with ASIAIR, SharpCap, non-NINA software)
        func override(_ current: inout String?, from value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return }
            current = v
        }

        override(&entry.filter, from: headers["FILTER"] ?? headers["Filter"])
        if let v = headers["EXPTIME"] ?? headers["EXPOSURE"] { entry.exposure = Double(v) }
        if let v = headers["CCD-TEMP"] { entry.sensorTemp = Double(v) }
        if let v = headers["GAIN"] { entry.gain = Int(Double(v) ?? 0) }
        if let v = headers["OFFSET"] { entry.offset = Int(Double(v) ?? 0) }
        if let v = headers["XBINNING"] { entry.binning = "\(v)x\(v)" }
        override(&entry.telescope, from: headers["TELESCOP"])
        override(&entry.camera, from: headers["INSTRUME"])
        override(&entry.target, from: headers["OBJECT"])
        if let v = headers["IMAGETYP"] ?? headers["FRAME"] {
            entry.frameType = MetadataExtractor.normalizeFrameType(v)
        }
        if let v = headers["FOCALLEN"] ?? headers["FOCAL"] { entry.focalLength = Double(v) }
        if let v = headers["XPIXSZ"] ?? headers["PIXSIZE1"] { entry.pixelSizeMicrons = Double(v) }
        if let v = headers["FOCTEMP"] { entry.focuserTemp = Double(v) }
        if let v = headers["AMBTEMP"] ?? headers["APTS-AMB"] { entry.ambientTemp = Double(v) }
        if let v = headers["BAYERPAT"] { entry.bayerPattern = v.trimmingCharacters(in: .whitespaces) }
        if let v = headers["PIERSIDE"] ?? headers["PIER"] { entry.pierSide = v.trimmingCharacters(in: .whitespaces) }
        if let v = headers["SITELAT"] { entry.siteLatitude = Double(v) }
        if let v = headers["SITELONG"] { entry.siteLongitude = Double(v) }
        if let v = headers["CRVAL1"] { entry.solvedRA = Double(v) }
        if let v = headers["CRVAL2"] { entry.solvedDec = Double(v) }
        if let v = headers["ROTATOR"] { entry.rotatorAngle = Double(v) }
        // WCS rotation from plate solve: CROTA2 (direct) or CD matrix (computed)
        if let v = headers["CROTA2"], let val = Double(v) {
            entry.wcsRotation = val
        } else if let cd11 = headers["CD1_1"], let cd12 = headers["CD1_2"],
                  let v11 = Double(cd11), let v12 = Double(cd12) {
            entry.wcsRotation = atan2(-v12, v11) * 180.0 / .pi
        }
        // Full WCS plate-solve data for CD-matrix based display alignment
        if let v = headers["CRPIX1"] { entry.wcsCRPIX1 = Double(v) }
        if let v = headers["CRPIX2"] { entry.wcsCRPIX2 = Double(v) }
        if let v = headers["CD1_1"]  { entry.wcsCD11 = Double(v) }
        if let v = headers["CD1_2"]  { entry.wcsCD12 = Double(v) }
        if let v = headers["CD2_1"]  { entry.wcsCD21 = Double(v) }
        if let v = headers["CD2_2"]  { entry.wcsCD22 = Double(v) }
        if let v = headers["OBJCTRA"] { entry.objctRA = v.trimmingCharacters(in: .whitespaces) }
        if let v = headers["OBJCTDEC"] { entry.objctDec = v.trimmingCharacters(in: .whitespaces) }
        if let v = headers["DATE-OBS"] ?? headers["DATE-LOC"] {
            let parts = v.split(separator: "T")
            if parts.count >= 1 { entry.date = String(parts[0]) }
            if parts.count >= 2 { entry.time = String(parts[1].prefix(8)) }
        }
    }

    // MARK: - Post-Scan Quality Scoring

    /// Compute quality tiers for all frames from the scan session.
    /// Groups frames by setup+target+filter+exposure and runs QualityEstimator on each group.
    /// Updates qualityTier and combinedZScore in the database.
    private func computeQualityTiersForScannedFrames(sessionId: String) {
        guard let records = try? FrameHistoryDatabase.shared.frameRecords(forSession: sessionId) else { return }
        guard !records.isEmpty else { return }

        // Convert FrameRecords to lightweight ImageEntries for QualityEstimator
        let entries: [ImageEntry] = records.map { record in
            var entry = ImageEntry(url: URL(fileURLWithPath: record.filePath))
            entry.fileHash = record.fileHash
            entry.filter = record.filter
            entry.exposure = record.exposure
            entry.target = record.target
            entry.computedFWHM = record.computedFWHM
            entry.computedHFR = record.computedHFR
            entry.computedStarCount = record.computedStarCount
            entry.computedEccentricity = record.computedEccentricity
            entry.noiseMedian = record.noiseMedian.map { Float($0) }
            entry.noiseMAD = record.noiseMAD.map { Float($0) }
            entry.psfFluxSum = record.psfFlux
            entry.trailingScore = record.trailingScore
            entry.trailingPA = record.trailingPA
            entry.trailingAxisRatio = record.trailingAxisRatio
            entry.trailingConsensus = record.trailingConsensus
            entry.starChainFraction = record.starChainFraction
            entry.focalLength = record.focalLength
            entry.pixelSizeMicrons = record.pixelSizeMicrons
            entry.date = record.captureDate
            entry.time = record.captureTime
            entry.telescope = record.telescope
            entry.camera = record.camera
            return entry
        }

        // Run quality scoring (no calibration DB — archive scan is standalone)
        let scores = QualityEstimator.computeScores(for: entries)

        // Update DB records with quality tiers
        var updates: [(hash: String, tier: Int, zScore: Double)] = []
        for (i, entry) in entries.enumerated() {
            guard let bd = scores[entry.url] else { continue }
            updates.append((hash: records[i].fileHash, tier: bd.tier.rawValue, zScore: bd.combinedZScore))
        }

        if !updates.isEmpty {
            try? FrameHistoryDatabase.shared.updateQualityTiers(updates)
        }
    }
}

// Helper for ScanProgress isComplete field
private extension Int {
    var toBool: Bool { self != 0 }
}
