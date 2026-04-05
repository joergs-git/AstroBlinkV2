// v5.18.0
// MosaicGenerator — Assembles tiled mosaics from cached preview textures for VLM anomaly detection.
// Groups frames by target+filter+setup, sorts chronologically, composites center-cropped tiles
// with metadata annotations into JPEG images suitable for Claude Vision analysis.

import Foundation
import Metal
import AppKit
import CoreGraphics

// MARK: - Configuration

struct MosaicConfig {
    let tileWidth: Int = 320
    let tileHeight: Int = 240           // 4:3, smaller tiles → more frames per page → AI sees full sequence
    let centerCropFraction: Float = 0.80 // Crop 80% center (removes edge aberrations)
    let maxTilesPerPage: Int = 80        // 80 tiles at 320x240 = 9x9 grid = 2880x2160 → fits under 5MB at 0.95
    let jpegQuality: Float = 0.95        // High quality for display + VLM detection
    let labelFontSize: CGFloat = 10      // Annotation font size
    let twilightBarHeight: CGFloat = 3   // Bottom twilight color bar
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
    let tiles: [TileMetadata]        // Ordered by capture time
    let gridCols: Int
    let gridRows: Int
    let mosaicWidth: Int
    let mosaicHeight: Int

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
    let type: String                 // ICE_CRYSTAL, DEW, CLOUD, LIGHT_LEAK, SATELLITE, AMP_GLOW, FOCUS_SHIFT, UNKNOWN
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
    /// - Returns: Array of MosaicPage, one or more per group
    func generatePages(
        entries: [ImageEntry],
        textures: [URL: MTLTexture],
        shouldRotate: (ImageEntry) -> Bool,
        progress: ((Int, Int) -> Void)? = nil
    ) -> [MosaicPage] {

        // Filter to active (non-marked) frames that have cached textures
        let activeEntries = entries.enumerated().compactMap { idx, entry -> (Int, ImageEntry)? in
            guard !entry.isMarkedForDeletion,
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
                altitude: nil, // TODO: compute from AltAz if needed
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

        // Export to JPEG
        guard let mosaicImage = ctx.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: mosaicImage, size: NSSize(width: mosaicW, height: mosaicH))
        let rep = NSBitmapImageRep(cgImage: mosaicImage)
        guard let jpegData = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: config.jpegQuality)]
        ) else { return nil }

        return MosaicPage(
            group: group,
            jpegData: jpegData,
            nsImage: nsImage,
            tiles: tiles,
            gridCols: cols,
            gridRows: rows,
            mosaicWidth: mosaicW,
            mosaicHeight: mosaicH
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
