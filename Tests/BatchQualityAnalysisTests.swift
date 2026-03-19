// Batch Quality Analysis — processes all images in a setup folder, generates annotated
// JPEG thumbnails with metric overlays, and exports a CSV for ground-truth calibration.
//
// Workflow:
// 1. Run testAnalyzeM82() or testAnalyzeAllSetups()
// 2. Review 800px thumbnails in _analysis/ folder (metrics burned into image)
// 3. Move frames you consider BAD into _analysis/_bad/
// 4. Compare _bad/ contents vs algorithm's trash/borderline → calibrate thresholds

import XCTest
@testable import AstroTriage
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

final class BatchQualityAnalysisTests: XCTestCase {

    let testDataRoot = "/Users/joergklaas/Desktop/claude-code/AstroTriage-blinkV2/TestImages/QUALITYCHECKDATA"
    let outputRoot = NSTemporaryDirectory() + "AstroTriage_QualityAnalysis"
    let imageExtensions = Set(["fit", "fits", "fts", "xisf"])
    var device: MTLDevice!
    var previewGenerator: PreviewGenerator!

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required")
        previewGenerator = PreviewGenerator(device: device)
        XCTAssertNotNil(previewGenerator, "PreviewGenerator init failed")
    }

    // MARK: - Test Entry Points

    /// Analyze M82 setup only (119 images, ~60s)
    func testAnalyzeM82() throws {
        let setupDir = testDataRoot + "/M82"
        guard FileManager.default.fileExists(atPath: setupDir) else {
            throw XCTSkip("M82 test data not available at \(setupDir)")
        }
        try analyzeSetup(name: "M82", path: setupDir)
    }

    /// Analyze ALL setups under QUALITYCHECKDATA
    func testAnalyzeAllSetups() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: testDataRoot) else {
            throw XCTSkip("QUALITYCHECKDATA not available at \(testDataRoot)")
        }

        let setupFolders = ((try? fm.contentsOfDirectory(atPath: testDataRoot)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "_analysis" }
            .map { (name: $0, path: testDataRoot + "/" + $0) }
            .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
            .sorted { $0.name < $1.name }

        guard !setupFolders.isEmpty else {
            throw XCTSkip("No setup folders found under QUALITYCHECKDATA")
        }

        for setup in setupFolders {
            try analyzeSetup(name: setup.name, path: setup.path)
        }
    }

    // MARK: - Core Analysis Pipeline

    private func analyzeSetup(name: String, path: String) throws {
        let fm = FileManager.default

        // Output directory: temp location (sandbox-safe). Survives until reboot or manual cleanup.
        let outputDir = outputRoot + "/" + name
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Create empty _bad/ subfolder for user to populate
        let badDir = outputDir + "/_bad"
        if !fm.fileExists(atPath: badDir) {
            try fm.createDirectory(atPath: badDir, withIntermediateDirectories: true)
        }

        // Collect all image files (including Session_* subfolders, excluding PRE-DELETE*)
        let allFiles = collectImageFiles(in: path)
        guard !allFiles.isEmpty else {
            print("  No image files found in \(name)")
            return
        }

        print("\n" + String(repeating: "=", count: 70))
        print("  BATCH QUALITY ANALYSIS: \(name)")
        print("  Images: \(allFiles.count)")
        print("  Output: \(outputDir)")
        print(String(repeating: "=", count: 70))

        // Phase 1: Process each image sequentially (autoreleasepool per image for ~120MB each)
        var entries: [ImageEntry] = []
        var perImageData: [URL: PerImageData] = [:]

        for (idx, url) in allFiles.enumerated() {
            autoreleasepool {
                let data = processImage(url: url, index: idx, total: allFiles.count, outputDir: outputDir)
                if let d = data {
                    entries.append(d.entry)
                    perImageData[url] = d
                }
            }
        }

        // Phase 2: Run QualityEstimator on all entries (two-pass night-aware scoring)
        print("\n  Running QualityEstimator.computeScores() on \(entries.count) entries...")
        let scores = QualityEstimator.computeScores(for: entries)

        // Apply scores back to entries
        for i in 0..<entries.count {
            entries[i].qualityBreakdown = scores[entries[i].url]
        }

        // Phase 3: Write CSV with all metrics + quality scores
        let csvPath = outputDir + "/quality_analysis.csv"
        let csvContent = buildCSV(entries: entries, perImageData: perImageData)
        try csvContent.write(toFile: csvPath, atomically: true, encoding: .utf8)

        // Phase 4: Now regenerate thumbnails with quality tier overlay (needs scoring results)
        print("  Updating thumbnails with quality scores...")
        for entry in entries {
            guard let data = perImageData[entry.url] else { continue }
            let jpegPath = outputDir + "/" + entry.url.deletingPathExtension().lastPathComponent + ".jpg"
            saveThumbnailWithOverlay(data: data, entry: entry, path: jpegPath)
        }

        // Summary
        let tierCounts = entries.compactMap { $0.qualityTier }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        print("\n  Results for \(name):")
        print("    Excellent: \(tierCounts[.excellent, default: 0])")
        print("    Good:      \(tierCounts[.good, default: 0])")
        print("    Borderline:\(tierCounts[.borderline, default: 0])")
        print("    Trash:     \(tierCounts[.trash, default: 0])")
        print("    Unscored:  \(entries.filter { $0.qualityTier == nil }.count)")
        print("    CSV: \(csvPath)")
        print("    Thumbnails: \(outputDir)/*.jpg")
        print("    Move bad thumbnails to: \(badDir)/")
    }

    // MARK: - Per-Image Processing

    // Intermediate data kept between Phase 1 (processing) and Phase 4 (thumbnail generation)
    struct PerImageData {
        let entry: ImageEntry
        let noiseStats: STFCalculator.NoiseStats
        let starMetrics: StarMetrics?
        let trailing: TrailingAnalysis?
        let stfParams: [STFParams]
        let thumbnailPixels: [UInt8]  // RGBA pixel data at thumbnail resolution
        let thumbWidth: Int
        let thumbHeight: Int
    }

    private func processImage(url: URL, index: Int, total: Int, outputDir: String) -> PerImageData? {
        let filename = url.lastPathComponent
        print("  [\(index + 1)/\(total)] \(filename)")

        // Step 1: Metadata extraction (headers + filename tokens)
        let parsed = NINAFilenameParser.parse(filename)
        var entry = MetadataExtractor.extractAndMerge(url: url, filenameParsed: parsed)

        // Step 2: Decode FITS/XISF → MTLBuffer
        let decodeResult = ImageDecoder.decode(url: url, device: device)
        guard case .success(let decoded) = decodeResult else {
            print("    DECODE FAILED")
            return nil
        }
        entry.width = decoded.width
        entry.height = decoded.height
        entry.channelCount = decoded.channelCount

        // Step 3: Noise measurement (background median + MAD)
        let noiseStats = STFCalculator.measureNoise(from: decoded)
        entry.noiseMedian = noiseStats.median
        entry.noiseMAD = noiseStats.normalizedMAD

        // Step 4: GPU star detection
        let channel = decoded.channelCount == 3 ? 1 : 0  // Green for OSC
        let stars = previewGenerator.detectStarsFromImage(decoded, channel: channel)
        let totalStarCount = previewGenerator.lastTotalStarCount

        // Step 5: Star metrics measurement (FWHM, HFR, eccentricity)
        var starMetrics: StarMetrics? = nil
        if !stars.isEmpty {
            starMetrics = StarMetricsCalculator.measure(
                stars: stars, fullResImage: decoded, channel: channel,
                totalStarCount: totalStarCount
            )
        }
        if let m = starMetrics {
            entry.computedFWHM = m.medianFWHM
            entry.computedHFR = m.medianHFR
            entry.computedStarCount = m.measuredStarCount > 0 ? m.totalStarCount : nil
            entry.computedEccentricity = m.medianEccentricity
            entry.starDetails = m.starDetails
        }

        // Step 6: Trailing analysis (consensus-based, FL-adaptive)
        let trailing = TrailingAnalyzer.analyze(
            starDetails: starMetrics?.starDetails ?? [],
            focalLength: entry.focalLength,
            pixelSizeMicrons: entry.pixelSizeMicrons
        )
        if let t = trailing {
            entry.trailingScore = t.trailingScore
            entry.trailingPA = t.consensusPA
            entry.trailingAxisRatio = t.medianAxisRatio
            entry.trailingConsensus = t.consensusFraction
        }

        // Step 7: STF calculate + generate preview → get BGRA8 texture
        let stfParams = STFCalculator.calculate(from: decoded)
        let preview = previewGenerator.generatePreview(from: decoded, stfParams: stfParams)

        // Convert BGRA8 texture to 800px-wide thumbnail pixel data
        var thumbPixels: [UInt8] = []
        var thumbW = 0
        var thumbH = 0

        if let tex = preview?.texture {
            let srcW = tex.width
            let srcH = tex.height
            // Target 800px wide
            let targetW = 800
            let scale = Double(targetW) / Double(srcW)
            let targetH = Int(Double(srcH) * scale)
            thumbW = targetW
            thumbH = targetH

            // Preview texture is .private (GPU-only) — blit to .shared for CPU read
            let readDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: tex.pixelFormat, width: srcW, height: srcH, mipmapped: false)
            readDesc.storageMode = .shared
            readDesc.usage = []
            guard let readTex = device.makeTexture(descriptor: readDesc),
                  let cmdBuf = device.makeCommandQueue()?.makeCommandBuffer(),
                  let blit = cmdBuf.makeBlitCommandEncoder() else {
                print("    Failed to create readback resources")
                return nil
            }
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: srcW, height: srcH, depth: 1),
                      to: readTex, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin())
            blit.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()

            // Read from shared texture
            var fullPixels = [UInt8](repeating: 0, count: srcW * srcH * 4)
            readTex.getBytes(&fullPixels, bytesPerRow: srcW * 4,
                             from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: srcW, height: srcH, depth: 1)),
                             mipmapLevel: 0)

            // BGRA → RGBA swap
            for i in stride(from: 0, to: fullPixels.count, by: 4) {
                let b = fullPixels[i]; fullPixels[i] = fullPixels[i + 2]; fullPixels[i + 2] = b
            }

            // Scale down to 800px with simple nearest-neighbor (good enough for thumbnails)
            thumbPixels = [UInt8](repeating: 0, count: thumbW * thumbH * 4)
            for y in 0..<thumbH {
                let srcY = min(Int(Double(y) / scale), srcH - 1)
                for x in 0..<thumbW {
                    let srcX = min(Int(Double(x) / scale), srcW - 1)
                    let srcIdx = (srcY * srcW + srcX) * 4
                    let dstIdx = (y * thumbW + x) * 4
                    thumbPixels[dstIdx] = fullPixels[srcIdx]
                    thumbPixels[dstIdx + 1] = fullPixels[srcIdx + 1]
                    thumbPixels[dstIdx + 2] = fullPixels[srcIdx + 2]
                    thumbPixels[dstIdx + 3] = 255
                }
            }
        }

        let snr: String
        if let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 {
            snr = String(format: "%.1f", med / mad)
        } else {
            snr = "n/a"
        }
        let fwhm = entry.displayFWHM.map { String(format: "%.2f", $0) } ?? "n/a"
        let ecc = entry.computedEccentricity.map { String(format: "%.3f", $0) } ?? "n/a"
        let trail = entry.trailingScore.map { String(format: "%.2f", $0) } ?? "n/a"
        print("    Stars:\(entry.displayStarCount ?? 0) FWHM:\(fwhm) SNR:\(snr) Ecc:\(ecc) Trail:\(trail)")

        return PerImageData(
            entry: entry,
            noiseStats: noiseStats,
            starMetrics: starMetrics,
            trailing: trailing,
            stfParams: stfParams,
            thumbnailPixels: thumbPixels,
            thumbWidth: thumbW,
            thumbHeight: thumbH
        )
    }

    // MARK: - Thumbnail Generation with Metric Overlay

    private func saveThumbnailWithOverlay(data: PerImageData, entry: ImageEntry, path: String) {
        let w = data.thumbWidth
        let h = data.thumbHeight
        guard w > 0, h > 0, !data.thumbnailPixels.isEmpty else { return }

        // Create CGImage from pixel data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = data.thumbnailPixels
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let baseImage = ctx.makeImage() else { return }

        // Create NSImage and draw overlay text
        let nsImage = NSImage(cgImage: baseImage, size: NSSize(width: w, height: h))
        nsImage.lockFocus()

        // Build overlay text lines
        let filter = entry.filter ?? "?"
        let frame = entry.frameNumber.map { "#\(String(format: "%04d", $0))" } ?? ""
        let night = entry.observingNight ?? entry.date ?? "?"
        let stars = entry.displayStarCount.map { "\($0)" } ?? "n/a"
        let fwhm = entry.displayFWHM.map { String(format: "%.2f", $0) } ?? "n/a"
        let hfr = entry.displayHFR.map { String(format: "%.2f", $0) } ?? "n/a"
        let snr: String
        if let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 {
            snr = String(format: "%.1f", med / mad)
        } else {
            snr = "n/a"
        }
        let ecc = entry.computedEccentricity.map { String(format: "%.3f", $0) } ?? "n/a"
        let trail = entry.trailingScore.map { String(format: "%.2f", $0) } ?? "n/a"

        let tier = entry.qualityTier.map { tierLabel($0) } ?? "unscored"
        let combinedZ = entry.qualityZScore.map { String(format: "%+.2f", $0) } ?? "n/a"
        let garbageReason = entry.qualityBreakdown?.garbageReason?.rawValue ?? ""
        let locked = entry.qualityBreakdown?.isLockedKeep == true ? " [LOCKED]" : ""

        let line1 = "\(filter) \(frame)  Night: \(night)"
        let line2 = "Stars:\(stars)  FWHM:\(fwhm)  HFR:\(hfr)  SNR:\(snr)"
        let line3 = "Ecc:\(ecc)  Trail:\(trail)  Q:\(tier) Z:\(combinedZ)\(locked)"
        let line4 = garbageReason.isEmpty ? "" : "Reason: \(garbageReason)"

        var lines = [line1, line2, line3]
        if !line4.isEmpty { lines.append(line4) }

        // Draw semi-transparent background bar at bottom
        let lineHeight: CGFloat = 16
        let padding: CGFloat = 6
        let barHeight = CGFloat(lines.count) * lineHeight + padding * 2
        let barRect = NSRect(x: 0, y: 0, width: CGFloat(w), height: barHeight)
        NSColor(white: 0, alpha: 0.75).setFill()
        barRect.fill()

        // Draw text lines
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let tierColor = tierNSColor(entry.qualityTier)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tierColor
        ]

        for (i, line) in lines.enumerated() {
            let y = barHeight - padding - CGFloat(i + 1) * lineHeight + 2
            (line as NSString).draw(at: NSPoint(x: padding, y: y), withAttributes: attrs)
        }

        nsImage.unlockFocus()

        // Save as JPEG (smaller than PNG, fine for review thumbnails)
        guard let tiffData = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return
        }
        try? jpegData.write(to: URL(fileURLWithPath: path))
    }

    private func tierLabel(_ tier: QualityTier) -> String {
        switch tier {
        case .excellent:  return "EXCELLENT"
        case .good:       return "GOOD"
        case .borderline: return "BORDERLINE"
        case .trash:      return "TRASH"
        }
    }

    private func tierNSColor(_ tier: QualityTier?) -> NSColor {
        switch tier {
        case .excellent:  return NSColor(red: 0.3, green: 1.0, blue: 0.3, alpha: 1.0)
        case .good:       return NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1.0)
        case .borderline: return NSColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1.0)
        case .trash:      return NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
        case .none:       return NSColor.white
        }
    }

    // MARK: - CSV Export

    private func buildCSV(entries: [ImageEntry], perImageData: [URL: PerImageData]) -> String {
        let header = [
            "filename", "filter", "night", "stars", "fwhm", "hfr", "snr", "ecc",
            "trailingScore", "trailingConsensus", "noiseMedian", "noiseMAD",
            "qualityTier", "combinedZ", "starsZ", "fwhmZ", "hfrZ", "noiseZ", "trailingZ",
            "garbageReason", "snrContrib", "isNarrowband", "starWeight"
        ].joined(separator: ",")

        var lines = [header]

        for entry in entries {
            let bd = entry.qualityBreakdown
            let snr: Double? = {
                guard let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return nil }
                return Double(med / mad)
            }()

            let rawFilter = entry.filter ?? ""
            let canonical = ColorCombineEngine.canonicalFilterName(rawFilter)
            let isBroadband = QualityEstimator.broadbandCanonical.contains(canonical)
                || canonical.isEmpty || canonical.lowercased() == "none"

            let cols: [String] = [
                entry.filename,
                entry.filter ?? "",
                entry.observingNight ?? "",
                entry.displayStarCount.map { "\($0)" } ?? "",
                entry.displayFWHM.map { String(format: "%.3f", $0) } ?? "",
                entry.displayHFR.map { String(format: "%.3f", $0) } ?? "",
                snr.map { String(format: "%.2f", $0) } ?? "",
                entry.computedEccentricity.map { String(format: "%.4f", $0) } ?? "",
                entry.trailingScore.map { String(format: "%.4f", $0) } ?? "",
                entry.trailingConsensus.map { String(format: "%.4f", $0) } ?? "",
                entry.noiseMedian.map { String(format: "%.6f", $0) } ?? "",
                entry.noiseMAD.map { String(format: "%.6f", $0) } ?? "",
                bd.map { tierLabel($0.tier) } ?? "",
                bd.map { String(format: "%.4f", $0.combinedZScore) } ?? "",
                bd?.starsZ.map { String(format: "%.4f", $0) } ?? "",
                bd?.fwhmZ.map { String(format: "%.4f", $0) } ?? "",
                bd?.hfrZ.map { String(format: "%.4f", $0) } ?? "",
                bd?.noiseZ.map { String(format: "%.4f", $0) } ?? "",
                bd?.trailingZ.map { String(format: "%.4f", $0) } ?? "",
                bd?.garbageReason?.rawValue ?? "",
                bd?.snrContribution.map { String(format: "%.2f", $0) } ?? "",
                isBroadband ? "false" : "true",
                isBroadband ? "1.2" : "0.5"
            ]

            lines.append(cols.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - File Discovery

    private func collectImageFiles(in setupDir: String) -> [URL] {
        let fm = FileManager.default
        let topItems = ((try? fm.contentsOfDirectory(atPath: setupDir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()

        var files: [URL] = []

        // Direct files in setup folder
        files += topItems
            .filter { imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .map { URL(fileURLWithPath: setupDir + "/" + $0) }

        // Session_* subfolders (e.g. IC 63 Ghost style)
        for sub in topItems where sub.lowercased().hasPrefix("session_") {
            let subPath = setupDir + "/" + sub
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let subFiles = ((try? fm.contentsOfDirectory(atPath: subPath)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .filter { imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                .sorted()
                .map { URL(fileURLWithPath: subPath + "/" + $0) }
            files += subFiles
        }

        // Exclude PRE-DELETE* subfolders (those are ground truth for the existing StarAnalyzerTests)
        return files
    }
}
