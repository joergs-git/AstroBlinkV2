// v5.19.0
// MosaicGenerator — Assembles tiled mosaics from cached preview textures for VLM anomaly detection.
// Groups frames by target+filter+setup, sorts chronologically, composites center-cropped tiles
// with metadata annotations into JPEG images suitable for Claude Vision analysis.

import Foundation
import Metal
import AppKit
import CoreGraphics

// MARK: - Configuration

struct MosaicConfig {
    let tileWidth: Int = 480
    let tileHeight: Int = 360           // 4:3, 50% larger tiles for better anomaly visibility (ice halos, satellite trails)
    let centerCropFraction: Float = 0.80 // Crop 80% center (removes edge aberrations)
    let maxTilesPerPage: Int = 36        // 36 tiles at 480x360 = 6x6 grid = 2880x2160 → fits under 5MB at 0.95
    let jpegQuality: Float = 0.95        // High quality for display + VLM detection
    let labelFontSize: CGFloat = 12      // Annotation font size (scaled up for larger tiles)
    let twilightBarHeight: CGFloat = 4   // Bottom twilight color bar
}

// MARK: - Tile metadata

struct TileMetadata {
    let frameIndex: Int              // 1-based session frame number
    let entryIndex: Int              // Index in viewModel.images array (for jump-to)
    let filename: String
    let captureTime: String?         // "22:47"
    let moonDistance: Double?        // degrees
    let twilightPhase: TwilightPhase?
    let pierSide: String?            // "E" or "W"
    let needsRotation180: Bool       // From shouldRotateForMeridian()
    let altitude: Double?            // Target altitude at capture time

    // Numeric metrics passed in system prompt, NOT burned into tile
    let fwhm: Double?
    let starCount: Int?
    let eccentricity: Double?
    let noiseMAD: Float?
    let trailingScore: Double?
    let qualityTier: String?
}

// MARK: - Mosaic page (one JPEG image)

struct MosaicPage {
    let group: GroupKey
    let jpegData: Data
    let nsImage: NSImage?            // For floating preview window
    let deviationJpegData: Data?     // Deviation map mosaic (bright = different from median)
    let deviationNsImage: NSImage?   // For preview toggle
    let tiles: [TileMetadata]        // Ordered by capture time
    let gridCols: Int
    let gridRows: Int
    let mosaicWidth: Int
    let mosaicHeight: Int

    // Option A: Computational center-vs-edge anomalies (no VLM needed)
    let centerAnomalies: [AnomalyResult]

    // Option B: Most median-like tile (lowest total deviation) — used as reference in VLM prompt
    let referenceTileFrameIndex: Int?

    // Pre-built context for the VLM system prompt
    var sessionContext: String {
        guard let first = tiles.first, let last = tiles.last else { return "" }
        let target = group.object.isEmpty ? "Unknown" : group.object
        let filter = group.filter.isEmpty ? "Unknown" : group.filter
        let fl = group.focalLength > 0 ? "\(group.focalLength)mm" : "unknown FL"
        let exp = group.exposure > 0 ? "\(group.exposure)s" : "unknown exp"
        let timeRange = "\(first.captureTime ?? "?")-\(last.captureTime ?? "?")"

        // Twilight breakdown
        var twilightCounts: [String: Int] = [:]
        for t in tiles {
            let phase = t.twilightPhase?.rawValue ?? "Unknown"
            twilightCounts[phase, default: 0] += 1
        }
        let twilightBreakdown = twilightCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.value)× \($0.key)" }
            .joined(separator: ", ")

        // Moon range
        let moonDists = tiles.compactMap(\.moonDistance)
        let moonRange: String
        if let minM = moonDists.min(), let maxM = moonDists.max() {
            moonRange = String(format: "%.0f°–%.0f°", minM, maxM)
        } else {
            moonRange = "unknown"
        }

        return """
        Target: \(target), Filter: \(filter), FL: \(fl), Exposure: \(exp)
        Frames: \(tiles.count), Time range: \(timeRange)
        Twilight: \(twilightBreakdown)
        Moon distance range: \(moonRange)
        Grid: \(gridCols)×\(gridRows) (\(mosaicWidth)×\(mosaicHeight)px)
        """
    }

    // Per-frame metrics table for the system prompt
    var metricsTable: String {
        tiles.map { t in
            var parts = ["#\(t.frameIndex)"]
            if let f = t.fwhm { parts.append(String(format: "FWHM=%.1f", f)) }
            if let s = t.starCount { parts.append("stars=\(s)") }
            if let e = t.eccentricity { parts.append(String(format: "ecc=%.2f", e)) }
            if let n = t.noiseMAD { parts.append(String(format: "noise=%.4f", n)) }
            if let tr = t.trailingScore, tr > 0.01 { parts.append(String(format: "trail=%.2f", tr)) }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

// MARK: - Anomaly result from VLM

struct AnomalyResult: Codable {
    let frame: Int                   // Frame number (1-based, matches tile annotation)
    let type: String                 // Short label: ICE, DEW, CLOUD, OBSTRUCTION, SOFT_FOCUS, or custom
    let confidence: Double           // 0.0-1.0
    let description: String
    let temporalNote: String?        // "progressive from #34" or "sudden at #47"
}

// MARK: - Generator

class MosaicGenerator {

    private let config: MosaicConfig

    init(config: MosaicConfig = MosaicConfig()) {
        self.config = config
    }

    // MARK: - Generate all mosaic pages for a session

    /// Groups remaining (non-marked) frames by GroupKey, generates one or more mosaic pages per group.
    /// Caller must pre-collect textures from PrefetchCache (@MainActor) before calling this.
    /// - Parameters:
    ///   - entries: All image entries in the session (filtered to active frames internally)
    ///   - textures: Pre-collected preview textures keyed by URL (from PrefetchCache.getPreview)
    ///   - shouldRotate: Closure that checks meridian flip for an entry
    ///   - progress: Called with (completed, total) for UI progress
    /// - Parameters:
    ///   - skipDeletionFilter: When true, include marked-for-deletion frames (used for highlighted selection)
    /// - Returns: Array of MosaicPage, one or more per group
    func generatePages(
        entries: [ImageEntry],
        textures: [URL: MTLTexture],
        shouldRotate: (ImageEntry) -> Bool,
        skipDeletionFilter: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) -> [MosaicPage] {

        // Filter to frames that have cached textures (optionally skip deletion filter for highlighted sets)
        let activeEntries = entries.enumerated().compactMap { idx, entry -> (Int, ImageEntry)? in
            guard (skipDeletionFilter || !entry.isMarkedForDeletion),
                  textures[entry.url] != nil else { return nil }
            return (idx, entry)
        }

        guard activeEntries.count >= 4 else { return [] } // Too few frames for comparison

        // Group by GroupKey (target+filter+FL+exposure, no night dimension)
        var groups: [GroupKey: [(Int, ImageEntry)]] = [:]
        for (idx, entry) in activeEntries {
            let key = GroupKey(entry: entry, useNight: false)
            groups[key, default: []].append((idx, entry))
        }

        let totalGroups = groups.values.filter { $0.count >= 4 }.count
        var completedGroups = 0
        var allPages: [MosaicPage] = []

        for (groupKey, groupEntries) in groups {
            guard groupEntries.count >= 4 else { continue } // Skip tiny groups

            // Sort by capture time (chronological)
            let sorted = groupEntries.sorted { a, b in
                (a.1.dateTime ?? "") < (b.1.dateTime ?? "")
            }

            // Split into pages if > maxTilesPerPage
            let chunks = sorted.chunked(into: config.maxTilesPerPage)

            for chunk in chunks {
                if let page = generateSinglePage(
                    group: groupKey,
                    entries: chunk,
                    textures: textures,
                    shouldRotate: shouldRotate
                ) {
                    allPages.append(page)
                }
            }

            completedGroups += 1
            progress?(completedGroups, totalGroups)
        }

        return allPages
    }

    // MARK: - Single page generation

    private func generateSinglePage(
        group: GroupKey,
        entries: [(Int, ImageEntry)],
        textures: [URL: MTLTexture],
        shouldRotate: (ImageEntry) -> Bool
    ) -> MosaicPage? {

        let count = entries.count
        guard count > 0 else { return nil }

        // Calculate grid dimensions (roughly square)
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))

        let mosaicW = cols * config.tileWidth
        let mosaicH = rows * config.tileHeight

        // Create mosaic CGContext
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: mosaicW,
            height: mosaicH,
            bitsPerComponent: 8,
            bytesPerRow: mosaicW * 4,
            space: cs,
            bitmapInfo: bi
        ) else { return nil }

        // Dark background
        ctx.setFillColor(NSColor(white: 0.08, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: mosaicW, height: mosaicH))

        var tiles: [TileMetadata] = []
        var tileImages: [CGImage] = []  // Keep for deviation computation

        for (tileIdx, (entryIdx, entry)) in entries.enumerated() {
            let col = tileIdx % cols
            // CGContext origin is bottom-left; we want top-left ordering for chronological layout
            let row = rows - 1 - (tileIdx / cols)

            let tileX = col * config.tileWidth
            let tileY = row * config.tileHeight

            // Get pre-collected preview texture
            guard let texture = textures[entry.url] else { continue }

            let needsFlip = shouldRotate(entry)

            // Extract center-cropped, scaled tile as CGImage
            guard let tileImage = extractTile(
                from: texture,
                rotate180: needsFlip
            ) else { continue }

            tileImages.append(tileImage)

            // Draw tile into mosaic
            let tileRect = CGRect(x: tileX, y: tileY, width: config.tileWidth, height: config.tileHeight)
            ctx.draw(tileImage, in: tileRect)

            // Build tile metadata
            let metadata = TileMetadata(
                frameIndex: entry.sessionIndex > 0 ? entry.sessionIndex : tileIdx + 1,
                entryIndex: entryIdx,
                filename: entry.filename,
                captureTime: entry.time.map { String($0.prefix(5)) }, // "22:47"
                moonDistance: entry.moonDistance,
                twilightPhase: entry.twilightPhase,
                pierSide: entry.pierSide,
                needsRotation180: needsFlip,
                altitude: nil,
                fwhm: entry.displayFWHM,
                starCount: entry.displayStarCount,
                eccentricity: entry.computedEccentricity,
                noiseMAD: entry.noiseMAD,
                trailingScore: entry.trailingScore,
                qualityTier: entry.qualityTier.map { "\($0)" }
            )
            tiles.append(metadata)

            // Burn annotations into tile area
            drawTileAnnotations(ctx: ctx, rect: tileRect, metadata: metadata)
        }

        guard !tiles.isEmpty else { return nil }

        // Export original mosaic to JPEG
        guard let mosaicImage = ctx.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: mosaicImage, size: NSSize(width: mosaicW, height: mosaicH))
        let rep = NSBitmapImageRep(cgImage: mosaicImage)
        guard let jpegData = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: config.jpegQuality)]
        ) else { return nil }

        // Compute deviation mosaic (bright = different from group median)
        let deviation = computeDeviationMosaic(
            tileImages: tileImages, tiles: tiles,
            gridCols: cols, gridRows: rows,
            tileW: config.tileWidth, tileH: config.tileHeight)

        return MosaicPage(
            group: group,
            jpegData: jpegData,
            nsImage: nsImage,
            deviationJpegData: deviation?.jpegData,
            deviationNsImage: deviation?.nsImage,
            tiles: tiles,
            gridCols: cols,
            gridRows: rows,
            mosaicWidth: mosaicW,
            mosaicHeight: mosaicH,
            centerAnomalies: deviation?.centerAnomalies ?? [],
            referenceTileFrameIndex: deviation?.referenceTileFrameIndex
        )
    }

    // MARK: - Tile extraction (center crop 80%, resize, optional 180° rotation)

    private func extractTile(from texture: MTLTexture, rotate180: Bool) -> CGImage? {
        let srcW = texture.width
        let srcH = texture.height

        // Center crop 80%
        let cropFrac = CGFloat(config.centerCropFraction)
        let offsetFrac = (1.0 - cropFrac) / 2.0
        let cropRect = CGRect(x: offsetFrac, y: offsetFrac, width: cropFrac, height: cropFrac)

        // Use the same blit-to-shared + crop + scale approach as TriageViewModel.textureToImage
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

        // Read pixels from texture
        var pixels = [UInt8](repeating: 0, count: srcW * srcH * 4)
        readableTex.getBytes(&pixels, bytesPerRow: srcW * 4,
                             from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: srcW, height: srcH, depth: 1)),
                             mipmapLevel: 0)

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let fullCtx = CGContext(data: &pixels, width: srcW, height: srcH,
                                       bitsPerComponent: 8, bytesPerRow: srcW * 4,
                                       space: cs, bitmapInfo: bitmapInfo),
              let fullImg = fullCtx.makeImage() else { return nil }

        // Apply center crop
        let cx = Int(cropRect.origin.x * CGFloat(srcW))
        let cy = Int(cropRect.origin.y * CGFloat(srcH))
        let cw = Int(cropRect.width * CGFloat(srcW))
        let ch = Int(cropRect.height * CGFloat(srcH))
        guard let croppedImg = fullImg.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) else { return nil }

        // Scale to tile size, optionally rotate 180°
        let tileW = config.tileWidth
        let tileH = config.tileHeight
        let outBI = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let tileCtx = CGContext(data: nil, width: tileW, height: tileH,
                                       bitsPerComponent: 8, bytesPerRow: tileW * 4,
                                       space: cs, bitmapInfo: outBI) else { return nil }

        tileCtx.interpolationQuality = .high

        if rotate180 {
            // Rotate 180°: translate to center, rotate, translate back
            tileCtx.translateBy(x: CGFloat(tileW), y: CGFloat(tileH))
            tileCtx.rotate(by: .pi)
        }

        tileCtx.draw(croppedImg, in: CGRect(x: 0, y: 0, width: tileW, height: tileH))
        return tileCtx.makeImage()
    }

    // MARK: - Tile annotations (burned into mosaic)

    private func drawTileAnnotations(ctx: CGContext, rect: CGRect, metadata: TileMetadata) {
        let fontSize = config.labelFontSize
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let smallFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)

        // Semi-transparent background for text readability
        let pillColor = NSColor(white: 0.0, alpha: 0.55)
        let textColor = NSColor.white

        // Top-left: Frame number
        let frameLabel = "#\(metadata.frameIndex)"
        drawPill(ctx: ctx, text: frameLabel, font: font, textColor: textColor,
                 pillColor: pillColor, x: rect.minX + 4, y: rect.maxY - fontSize - 6, anchor: .left)

        // Top-right: Capture time + moon distance
        var topRight = metadata.captureTime ?? ""
        if let moon = metadata.moonDistance {
            topRight += String(format: " \u{263D}%.0f°", moon) // ☽
        }
        if !topRight.isEmpty {
            drawPill(ctx: ctx, text: topRight, font: smallFont, textColor: textColor,
                     pillColor: pillColor, x: rect.maxX - 4, y: rect.maxY - fontSize - 6, anchor: .right)
        }

        // Bottom-left: Twilight phase + pier side
        var bottomLeft = ""
        if let twi = metadata.twilightPhase {
            switch twi {
            case .night: bottomLeft = "N"
            case .astronomical: bottomLeft = "A"
            case .nautical: bottomLeft = "Na"
            case .civil: bottomLeft = "C"
            case .daylight: bottomLeft = "D"
            }
        }
        if let pier = metadata.pierSide {
            bottomLeft += " \(pier.prefix(1).uppercased())"
        }
        if !bottomLeft.isEmpty {
            drawPill(ctx: ctx, text: bottomLeft.trimmingCharacters(in: .whitespaces), font: smallFont,
                     textColor: textColor, pillColor: pillColor,
                     x: rect.minX + 4, y: rect.minY + config.twilightBarHeight + 4, anchor: .left)
        }

        // Bottom-right: Star count
        if let stars = metadata.starCount {
            let starsLabel = "★\(stars)"
            drawPill(ctx: ctx, text: starsLabel, font: smallFont, textColor: textColor,
                     pillColor: pillColor, x: rect.maxX - 4,
                     y: rect.minY + config.twilightBarHeight + 4, anchor: .right)
        }

        // Bottom edge: Twilight color bar (2px)
        if let twi = metadata.twilightPhase, twi != .night {
            let barColor: NSColor
            switch twi {
            case .astronomical: barColor = NSColor(red: 0.1, green: 0.1, blue: 0.5, alpha: 0.8)
            case .nautical:     barColor = NSColor(red: 0.15, green: 0.15, blue: 0.6, alpha: 0.8)
            case .civil:        barColor = NSColor(red: 0.8, green: 0.5, blue: 0.1, alpha: 0.8)
            case .daylight:     barColor = NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 0.8)
            case .night:        barColor = .clear
            }
            ctx.setFillColor(barColor.cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY,
                            width: rect.width, height: config.twilightBarHeight))
        }
    }

    // MARK: - Text pill drawing

    private enum TextAnchor { case left, right }

    private func drawPill(ctx: CGContext, text: String, font: NSFont, textColor: NSColor,
                          pillColor: NSColor, x: CGFloat, y: CGFloat, anchor: TextAnchor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()

        let padding: CGFloat = 3
        let pillW = size.width + padding * 2
        let pillH = size.height + padding

        let pillX: CGFloat
        switch anchor {
        case .left:  pillX = x
        case .right: pillX = x - pillW
        }

        // Draw pill background
        ctx.saveGState()
        ctx.setFillColor(pillColor.cgColor)
        let pillRect = CGRect(x: pillX, y: y, width: pillW, height: pillH)
        let path = CGPath(roundedRect: pillRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        // Draw text using NSGraphicsContext bridging
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        str.draw(at: NSPoint(x: pillX + padding, y: y + 1))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Deviation analysis result

    struct DeviationAnalysis {
        let jpegData: Data
        let nsImage: NSImage
        let centerAnomalies: [AnomalyResult]   // Tiles with abnormal center-vs-edge darkening
        let referenceTileFrameIndex: Int?       // Most median-like tile for VLM reference
    }

    // MARK: - Deviation mosaic (bright = tile differs from group median)

    /// Computes a per-pixel deviation map for each tile against the group median.
    /// Also runs center-vs-edge analysis (Option A) and identifies the reference tile (Option B).
    private func computeDeviationMosaic(
        tileImages: [CGImage], tiles: [TileMetadata],
        gridCols: Int, gridRows: Int,
        tileW: Int, tileH: Int
    ) -> DeviationAnalysis? {

        let tileCount = tileImages.count
        guard tileCount >= 4 else { return nil }
        let pixelCount = tileW * tileH

        // 1) Extract grayscale luminance from each tile
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue
        var tileLum: [[UInt8]] = []
        tileLum.reserveCapacity(tileCount)

        for tile in tileImages {
            var rgba = [UInt8](repeating: 0, count: tileW * tileH * 4)
            guard let tileCtx = CGContext(
                data: &rgba, width: tileW, height: tileH,
                bitsPerComponent: 8, bytesPerRow: tileW * 4,
                space: cs, bitmapInfo: bi
            ) else { continue }
            tileCtx.draw(tile, in: CGRect(x: 0, y: 0, width: tileW, height: tileH))

            // Luminance: 0.299R + 0.587G + 0.114B
            var lum = [UInt8](repeating: 0, count: pixelCount)
            for i in 0..<pixelCount {
                let r = Float(rgba[i * 4])
                let g = Float(rgba[i * 4 + 1])
                let b = Float(rgba[i * 4 + 2])
                lum[i] = UInt8(min(255.0, 0.299 * r + 0.587 * g + 0.114 * b))
            }
            tileLum.append(lum)
        }
        guard tileLum.count == tileCount else { return nil }

        // 1b) Bin 4x4 for anomaly detection — suppresses fine detail (stars, nebula filaments),
        // amplifies large-scale features (ice blobs, obstructions, gradients).
        // Full-res tileLum is kept for the deviation map rendering.
        let binFactor = 4
        let binW = tileW / binFactor
        let binH = tileH / binFactor
        let binPixelCount = binW * binH
        var tileLumBinned: [[Float]] = []
        tileLumBinned.reserveCapacity(tileCount)

        for t in 0..<tileCount {
            var binned = [Float](repeating: 0, count: binPixelCount)
            for by in 0..<binH {
                for bx in 0..<binW {
                    var sum: Float = 0
                    for dy in 0..<binFactor {
                        for dx in 0..<binFactor {
                            let sx = bx * binFactor + dx
                            let sy = by * binFactor + dy
                            sum += Float(tileLum[t][sy * tileW + sx])
                        }
                    }
                    binned[by * binW + bx] = sum / Float(binFactor * binFactor)
                }
            }
            tileLumBinned.append(binned)
        }

        // 2) Pass 1: Compute per-pixel median across ALL tiles (for deviation map rendering)
        var medianTile = [UInt8](repeating: 0, count: pixelCount)
        var sortBuf = [UInt8](repeating: 0, count: tileCount)
        for px in 0..<pixelCount {
            for t in 0..<tileCount {
                sortBuf[t] = tileLum[t][px]
            }
            sortBuf.sort()
            medianTile[px] = sortBuf[tileCount / 2]
        }

        // 2b) Identify clean reference tiles using STAR COUNT from metadata.
        // Ice/frost obscures stars → tiles with MOST stars are cleanest.
        let cleanCount = max(2, tileCount / 4)  // Top 25%, at least 2

        let tilesWithStars = tiles.enumerated().filter { $0.element.starCount != nil }
        let cleanTileIndices: [Int]

        if tilesWithStars.count >= cleanCount {
            cleanTileIndices = tilesWithStars
                .sorted { ($0.element.starCount ?? 0) > ($1.element.starCount ?? 0) }
                .prefix(cleanCount)
                .map { $0.offset }
        } else {
            // Fallback: use binned luminance uniformity (low variance = clean)
            var tileBlockVariances: [(Int, Float)] = []
            for t in 0..<tileCount {
                let mean = tileLumBinned[t].reduce(Float(0), +) / Float(binPixelCount)
                let variance = tileLumBinned[t].reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
                    / Float(binPixelCount)
                tileBlockVariances.append((t, variance))
            }
            cleanTileIndices = tileBlockVariances
                .sorted { $0.1 < $1.1 }
                .prefix(cleanCount)
                .map { $0.0 }
        }

        // 2c) Build BINNED clean reference — per-pixel median from clean tiles only
        var cleanRefBinned = [Float](repeating: 0, count: binPixelCount)
        var cleanSortBufF = [Float](repeating: 0, count: cleanTileIndices.count)
        for px in 0..<binPixelCount {
            for (idx, t) in cleanTileIndices.enumerated() {
                cleanSortBufF[idx] = tileLumBinned[t][px]
            }
            cleanSortBufF[0..<cleanTileIndices.count].sort()
            cleanRefBinned[px] = cleanSortBufF[cleanTileIndices.count / 2]
        }

        // 3) Compute per-tile deviation from GLOBAL median (full-res, for rendering)
        var devMaps: [[Float]] = []
        devMaps.reserveCapacity(tileCount)
        var globalMax: Float = 1.0

        for t in 0..<tileCount {
            var devMap = [Float](repeating: 0, count: pixelCount)
            for px in 0..<pixelCount {
                let dev = abs(Float(tileLum[t][px]) - Float(medianTile[px]))
                devMap[px] = dev
                if dev > globalMax { globalMax = dev }
            }
            devMaps.append(devMap)
        }

        // Use 97th percentile as normalization cap for better contrast
        var allDevsSorted = [Float]()
        for t in stride(from: 0, to: tileCount, by: max(1, tileCount / 8)) {
            for px in stride(from: 0, to: pixelCount, by: 8) {
                allDevsSorted.append(devMaps[t][px])
            }
        }
        allDevsSorted.sort()
        let p97 = allDevsSorted.isEmpty ? globalMax :
            allDevsSorted[min(allDevsSorted.count - 1, Int(Float(allDevsSorted.count) * 0.97))]
        let normMax = max(p97, 1.0)

        // 3b) Option A: Anomaly detection on BINNED data (bin4 = 120x90)
        // Binning suppresses fine detail (stars, nebula filaments) and amplifies
        // large-scale features (ice blobs, obstructions, gradients).
        // Two detectors:
        //   1. Total deviation from clean reference (any localized anomaly)
        //   2. Center-vs-edge ratio (centered optical defects)
        var totalBinnedDevs: [Float] = []
        totalBinnedDevs.reserveCapacity(tileCount)

        let binMarginX = Int(Float(binW) * 0.275)  // ~20% center area on binned
        let binMarginY = Int(Float(binH) * 0.275)
        var centerRatios: [Float] = []
        centerRatios.reserveCapacity(tileCount)

        for t in 0..<tileCount {
            var totalDev: Float = 0
            var centerSum: Float = 0
            var centerCount: Int = 0
            var edgeSum: Float = 0
            var edgeCount: Int = 0

            for y in 0..<binH {
                for x in 0..<binW {
                    let px = y * binW + x
                    let dev = abs(tileLumBinned[t][px] - cleanRefBinned[px])
                    totalDev += dev

                    let inCenter = x >= binMarginX && x < (binW - binMarginX) &&
                                   y >= binMarginY && y < (binH - binMarginY)
                    if inCenter {
                        centerSum += dev
                        centerCount += 1
                    } else {
                        edgeSum += dev
                        edgeCount += 1
                    }
                }
            }

            totalBinnedDevs.append(totalDev)
            let cMean = centerCount > 0 ? centerSum / Float(centerCount) : 0
            let eMean = edgeCount > 0 ? edgeSum / Float(edgeCount) : 0
            centerRatios.append(eMean > 0.1 ? cMean / eMean : 0)
        }

        // Flag anomalies
        var centerAnomalies: [AnomalyResult] = []
        var flaggedFrames = Set<Int>()

        if tileCount >= 4 {
            // Detector 1: Total binned deviation from clean reference
            // Catches ANY large-scale anomaly (dark blobs, obstructions) regardless of position
            let sortedTotalDevs = totalBinnedDevs.sorted()
            let medianTotalDev = sortedTotalDevs[tileCount / 2]
            let totalDevAbsDevs = totalBinnedDevs.map { abs($0 - medianTotalDev) }
            let sortedAbsDevs = totalDevAbsDevs.sorted()
            let totalDevMAD = sortedAbsDevs[tileCount / 2] * 1.4826

            for t in 0..<tileCount where t < tiles.count {
                let frameIdx = tiles[t].frameIndex
                let dev = totalBinnedDevs[t]
                let zScore = totalDevMAD > 0.01 ? (dev - medianTotalDev) / totalDevMAD : 0
                if zScore > 2.0 && dev > medianTotalDev * 1.3 {
                    let confidence = min(1.0, Double(zScore) / 5.0)
                    centerAnomalies.append(AnomalyResult(
                        frame: frameIdx,
                        type: "ANOMALY",
                        confidence: confidence,
                        description: String(format: "Large-scale deviation from clean reference (%.1fσ)", zScore),
                        temporalNote: nil
                    ))
                    flaggedFrames.insert(frameIdx)
                }
            }

            // Detector 2: Center-vs-edge ratio on binned data (centered defects)
            let sortedRatios = centerRatios.sorted()
            let medianRatio = sortedRatios[tileCount / 2]
            let ratioAbsDevs = centerRatios.map { abs($0 - medianRatio) }
            let sortedRatioDevs = ratioAbsDevs.sorted()
            let ratioMAD = sortedRatioDevs[tileCount / 2] * 1.4826

            for t in 0..<tileCount where t < tiles.count {
                let frameIdx = tiles[t].frameIndex
                guard !flaggedFrames.contains(frameIdx) else { continue }
                let ratio = centerRatios[t]
                let zScore = ratioMAD > 0.01 ? (ratio - medianRatio) / ratioMAD : 0
                if zScore > 2.5 && ratio > 1.3 {
                    let confidence = min(1.0, Double(zScore) / 5.0)
                    centerAnomalies.append(AnomalyResult(
                        frame: frameIdx,
                        type: "CENTER",
                        confidence: confidence,
                        description: String(format: "Center deviates %.1f× more than edges (%.1fσ)", ratio, zScore),
                        temporalNote: nil
                    ))
                    flaggedFrames.insert(frameIdx)
                }
            }
        }

        // 3c) Option B: Reference tile — clean tile with lowest binned deviation
        var referenceTileFrameIndex: Int? = nil
        if let bestIdx = cleanTileIndices.min(by: { totalBinnedDevs[$0] < totalBinnedDevs[$1] }),
           bestIdx < tiles.count {
            referenceTileFrameIndex = tiles[bestIdx].frameIndex
        }

        // 4) Render deviation mosaic with annotations
        let mosaicW = gridCols * tileW
        let mosaicH = gridRows * tileH
        let outBI = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let devCtx = CGContext(
            data: nil, width: mosaicW, height: mosaicH,
            bitsPerComponent: 8, bytesPerRow: mosaicW * 4,
            space: cs, bitmapInfo: outBI
        ) else { return nil }

        // Black background
        devCtx.setFillColor(NSColor.black.cgColor)
        devCtx.fill(CGRect(x: 0, y: 0, width: mosaicW, height: mosaicH))

        for (tileIdx, devMap) in devMaps.enumerated() {
            let col = tileIdx % gridCols
            let row = gridRows - 1 - (tileIdx / gridCols)
            let tileX = col * tileW
            let tileY = row * tileH

            // Create grayscale deviation tile (hot palette: black → orange → white)
            var tileRGBA = [UInt8](repeating: 0, count: pixelCount * 4)
            for px in 0..<pixelCount {
                let normalized = min(1.0, devMap[px] / normMax)
                // Enhanced contrast: apply gamma 0.5 to boost subtle differences
                let boosted = sqrt(normalized)
                let (r, g, b) = deviationColor(boosted)
                tileRGBA[px * 4]     = r
                tileRGBA[px * 4 + 1] = g
                tileRGBA[px * 4 + 2] = b
                tileRGBA[px * 4 + 3] = 255
            }

            // Create CGImage from deviation pixels
            guard let provider = CGDataProvider(data: Data(tileRGBA) as CFData),
                  let devTileImg = CGImage(
                    width: tileW, height: tileH,
                    bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: tileW * 4, space: cs,
                    bitmapInfo: CGBitmapInfo(rawValue: outBI),
                    provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent
                  ) else { continue }

            let tileRect = CGRect(x: tileX, y: tileY, width: tileW, height: tileH)
            devCtx.draw(devTileImg, in: tileRect)

            // Burn frame number annotation (same as original)
            if tileIdx < tiles.count {
                drawTileAnnotations(ctx: devCtx, rect: tileRect, metadata: tiles[tileIdx])
            }
        }

        // Export deviation mosaic
        guard let devImage = devCtx.makeImage() else { return nil }
        let devNSImage = NSImage(cgImage: devImage, size: NSSize(width: mosaicW, height: mosaicH))
        let devRep = NSBitmapImageRep(cgImage: devImage)
        guard let devJpeg = devRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: config.jpegQuality)]
        ) else { return nil }

        return DeviationAnalysis(
            jpegData: devJpeg,
            nsImage: devNSImage,
            centerAnomalies: centerAnomalies,
            referenceTileFrameIndex: referenceTileFrameIndex
        )
    }

    /// Hot color palette for deviation map: black → blue → cyan → yellow → red → white
    private func deviationColor(_ value: Float) -> (UInt8, UInt8, UInt8) {
        let v = min(1.0, max(0.0, value))
        let r, g, b: Float
        if v < 0.2 {
            // Black to dark blue
            let t = v / 0.2
            r = 0; g = 0; b = t * 0.5
        } else if v < 0.4 {
            // Dark blue to cyan
            let t = (v - 0.2) / 0.2
            r = 0; g = t * 0.8; b = 0.5 + t * 0.5
        } else if v < 0.6 {
            // Cyan to yellow
            let t = (v - 0.4) / 0.2
            r = t; g = 0.8 + t * 0.2; b = 1.0 - t
        } else if v < 0.8 {
            // Yellow to red
            let t = (v - 0.6) / 0.2
            r = 1.0; g = 1.0 - t; b = 0
        } else {
            // Red to white
            let t = (v - 0.8) / 0.2
            r = 1.0; g = t; b = t
        }
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }
}

// MARK: - Array chunking helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
