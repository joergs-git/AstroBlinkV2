// Star Detection Analyzer — Blackbox tests using curated QUALITYCHECKDATA
// Produces annotated PNG images showing detected star positions, center crop boundary,
// and per-star eccentricity color coding. Outputs CSV summary for comparison.
//
// Test data structure:
//   TestImages/QUALITYCHECKDATA/M81/           — good frames (round stars)
//   TestImages/QUALITYCHECKDATA/M81/PRE-DELETE_bad_star_form/ — bad frames (elongated stars)

import XCTest
@testable import AstroTriage
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class StarAnalyzerTests: XCTestCase {

    let testDataRoot = "/Users/joergklaas/Desktop/claude-code/AstroTriage-blinkV2/TestImages/QUALITYCHECKDATA"
    let outputDir = NSTemporaryDirectory() + "AstroTriage_StarAnalysis"
    var device: MTLDevice!

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required")
        // Create output directory
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - Main Analysis Test

    /// Analyze ALL setup folders under QUALITYCHECKDATA and produce annotated PNGs + CSV.
    /// Auto-discovers folders: each subfolder = one setup, PRE-DELETE_bad_star_form = bad frames.
    /// Run this test to see detection results visually.
    func testAnalyzeAllSetups() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: testDataRoot) else {
            XCTSkip("QUALITYCHECKDATA not available at \(testDataRoot)")
            return
        }

        let imageExtensions = Set(["fit", "fits", "fts", "xisf"])

        // Auto-discover setup folders (each direct subfolder of QUALITYCHECKDATA)
        let setupFolders = ((try? fm.contentsOfDirectory(atPath: testDataRoot)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "analysis_output" }
            .map { testDataRoot + "/" + $0 }
            .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
            .sorted()

        guard !setupFolders.isEmpty else {
            XCTSkip("No setup folders found under QUALITYCHECKDATA")
            return
        }

        var csvLines = [AnalysisResult.csvHeader]
        var totalGood = 0, totalBad = 0

        for setupDir in setupFolders {
            let setupName = URL(fileURLWithPath: setupDir).lastPathComponent

            // Good frames: files directly in setup folder + files in Session_* subfolders
            var goodFiles: [URL] = []
            let topFiles = (try? fm.contentsOfDirectory(atPath: setupDir)) ?? []
            // Direct files
            goodFiles += topFiles
                .filter { !$0.hasPrefix(".") }
                .filter { imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                .map { URL(fileURLWithPath: setupDir + "/" + $0) }
            // Session_* subfolders (IC 63 Ghost style)
            for sub in topFiles where sub.hasPrefix("Session_") || sub.hasPrefix("session_") {
                let subPath = setupDir + "/" + sub
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
                let subFiles = (try? fm.contentsOfDirectory(atPath: subPath)) ?? []
                goodFiles += subFiles
                    .filter { !$0.hasPrefix(".") }
                    .filter { imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                    .map { URL(fileURLWithPath: subPath + "/" + $0) }
            }

            // Bad frames: files in any PRE-DELETE* subfolder
            var badFiles: [URL] = []
            for sub in topFiles where sub.uppercased().hasPrefix("PRE-DELETE") || sub.uppercased().hasPrefix("PRE_DELETE") {
                let subPath = setupDir + "/" + sub
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
                let subFiles = (try? fm.contentsOfDirectory(atPath: subPath)) ?? []
                badFiles += subFiles
                    .filter { !$0.hasPrefix(".") }
                    .filter { imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                    .map { URL(fileURLWithPath: subPath + "/" + $0) }
            }

            print("\n\(String(repeating: "=", count: 60))")
            print("=== Setup: \(setupName) ===")
            print("Good frames: \(goodFiles.count)")
            print("Bad frames:  \(badFiles.count)")
            print("Output dir:  \(outputDir)/\n")

            totalGood += goodFiles.count
            totalBad += badFiles.count

            // Analyze sample of good frames (first 5 per setup for speed)
            let goodSample = Array(goodFiles.prefix(5))
            for url in goodSample {
                if let result = analyzeImage(url: url, label: "GOOD_\(setupName)") {
                    csvLines.append(result.csvLine)
                }
            }

            // Analyze ALL bad frames
            for url in badFiles {
                if let result = analyzeImage(url: url, label: "BAD_\(setupName)") {
                    csvLines.append(result.csvLine)
                }
            }
        }

        // Write CSV summary
        let csvPath = outputDir + "/analysis_summary.csv"
        try csvLines.joined(separator: "\n").write(toFile: csvPath, atomically: true, encoding: .utf8)
        print("\n\(String(repeating: "=", count: 60))")
        print("TOTAL: \(setupFolders.count) setups, \(totalGood) good frames, \(totalBad) bad frames")
        print("CSV summary: \(csvPath)")
        print("Annotated PNGs: \(outputDir)/")
    }

    // MARK: - Star Distribution Test

    /// Specifically test whether detected stars are evenly distributed across the center crop,
    /// or biased towards one side.
    func testStarDistribution() throws {
        let m81Dir = testDataRoot + "/M81"
        let fm = FileManager.default
        guard fm.fileExists(atPath: m81Dir) else {
            XCTSkip("M81 test data not available")
            return
        }

        // Pick the first available file
        let files = (try? fm.contentsOfDirectory(atPath: m81Dir)) ?? []
        guard let firstFit = files.first(where: { $0.hasSuffix(".fit") && !$0.hasPrefix(".") }) else {
            XCTSkip("No FITS files found")
            return
        }

        let url = URL(fileURLWithPath: m81Dir + "/" + firstFit)
        let result = ImageDecoder.decode(url: url, device: device)
        guard case .success(let decoded) = result else {
            XCTFail("Failed to decode \(url.lastPathComponent)")
            return
        }

        // Detect stars (more than usual — up to 200)
        let detected = StarDetector.detectStarsWithTotalCount(
            in: decoded, maxStars: 200, subsampleFactor: 4, sigmaThreshold: 5.0
        )
        print("\nTotal stars detected: \(detected.totalCount)")
        print("Returned (capped at 200): \(detected.stars.count)")

        let w = Float(decoded.width)
        let h = Float(decoded.height)

        // Check distribution across quadrants
        var q1 = 0, q2 = 0, q3 = 0, q4 = 0  // TL, TR, BL, BR
        for star in detected.stars {
            let nx = star.x / w
            let ny = star.y / h
            if nx < 0.5 && ny < 0.5 { q1 += 1 }
            else if nx >= 0.5 && ny < 0.5 { q2 += 1 }
            else if nx < 0.5 && ny >= 0.5 { q3 += 1 }
            else { q4 += 1 }
        }
        print("Quadrant distribution (TL/TR/BL/BR): \(q1)/\(q2)/\(q3)/\(q4)")

        // Check X distribution
        let xCoords = detected.stars.map { $0.x / w }
        let xMin = xCoords.min() ?? 0
        let xMax = xCoords.max() ?? 0
        let xMean = xCoords.reduce(0, +) / Float(max(xCoords.count, 1))
        print("X range: \(String(format: "%.2f", xMin)) - \(String(format: "%.2f", xMax)), mean: \(String(format: "%.2f", xMean))")

        // Check Y distribution
        let yCoords = detected.stars.map { $0.y / h }
        let yMin = yCoords.min() ?? 0
        let yMax = yCoords.max() ?? 0
        let yMean = yCoords.reduce(0, +) / Float(max(yCoords.count, 1))
        print("Y range: \(String(format: "%.2f", yMin)) - \(String(format: "%.2f", yMax)), mean: \(String(format: "%.2f", yMean))")

        // Now run through StarMetricsCalculator filtering
        let metrics = StarMetricsCalculator.measure(
            stars: detected.stars,
            fullResImage: decoded,
            totalStarCount: detected.totalCount
        )

        if let m = metrics {
            print("\nAfter StarMetricsCalculator filtering:")
            print("  Measured stars: \(m.measuredStarCount)")
            print("  Median FWHM: \(String(format: "%.2f", m.medianFWHM))")
            print("  Median HFR: \(String(format: "%.2f", m.medianHFR))")
            print("  Median Ecc: \(m.medianEccentricity.map { String(format: "%.3f", $0) } ?? "n/a")")
            print("  StarDetails count: \(m.starDetails.count)")

            // Check distribution of measured stars
            let detailX = m.starDetails.map { CGFloat($0.x) / CGFloat(w) }
            let detailY = m.starDetails.map { CGFloat($0.y) / CGFloat(h) }
            if !detailX.isEmpty {
                let dxMin = detailX.min()!, dxMax = detailX.max()!
                let dxMean = detailX.reduce(0, +) / CGFloat(detailX.count)
                print("  Measured X range: \(String(format: "%.2f", dxMin)) - \(String(format: "%.2f", dxMax)), mean: \(String(format: "%.2f", dxMean))")
                let dyMin = detailY.min()!, dyMax = detailY.max()!
                let dyMean = detailY.reduce(0, +) / CGFloat(detailY.count)
                print("  Measured Y range: \(String(format: "%.2f", dyMin)) - \(String(format: "%.2f", dyMax)), mean: \(String(format: "%.2f", dyMean))")

                // Flag if distribution is biased (mean far from 0.5)
                if abs(dxMean - 0.5) > 0.1 {
                    print("  ⚠️  X distribution biased! Mean \(String(format: "%.2f", dxMean)) (expected ~0.50)")
                }
                if abs(dyMean - 0.5) > 0.1 {
                    print("  ⚠️  Y distribution biased! Mean \(String(format: "%.2f", dyMean)) (expected ~0.50)")
                }
            }

            // Generate annotated PNG showing ALL detected stars + measured stars
            generateAnnotatedPNG(
                image: decoded,
                allStars: detected.stars,
                measuredDetails: m.starDetails,
                filename: "distribution_test_\(url.deletingPathExtension().lastPathComponent)",
                label: "DISTRIBUTION TEST"
            )
        }
    }

    // MARK: - Per-Image Analysis

    // FITS header keywords relevant for optical setup characterization
    static let headerKeys = [
        "FOCALLEN", "FOCRATIO", "XPIXSZ", "YPIXSZ",
        "INSTRUME", "TELESCOP", "CAMERAID",
        "IMAGEW", "IMAGEH", "XBINNING", "YBINNING",
        "OFFSET", "GAIN", "EXPTIME", "EXPOSURE",
        "FILTER", "OBJECT", "BAYERPAT",
        "CCD-TEMP", "SET-TEMP",
        "SWCREATE", "SOFTWARE"  // NINA vs ASIAir etc.
    ]

    struct AnalysisResult {
        let filename: String
        let label: String
        let width: Int
        let height: Int
        let totalStars: Int
        let measuredStars: Int
        let medianFWHM: Double
        let medianHFR: Double
        let medianEcc: Double?
        let starDetails: [StarDetail]
        let headers: [String: String]  // FITS header metadata

        var csvLine: String {
            let eccStr = medianEcc.map { String(format: "%.4f", $0) } ?? ""
            // Extract key hardware params
            let scope = headers["TELESCOP"] ?? ""
            let cam = headers["INSTRUME"] ?? ""
            let fl = headers["FOCALLEN"] ?? ""
            let fr = headers["FOCRATIO"] ?? ""
            let pxSz = headers["XPIXSZ"] ?? ""
            let filter = headers["FILTER"] ?? ""
            let exp = headers["EXPTIME"] ?? headers["EXPOSURE"] ?? ""
            let gain = headers["GAIN"] ?? ""
            let sw = headers["SWCREATE"] ?? headers["SOFTWARE"] ?? ""
            return "\(filename),\(label),\(width),\(height),\(totalStars),\(measuredStars),\(String(format: "%.2f", medianFWHM)),\(String(format: "%.2f", medianHFR)),\(eccStr),\(scope),\(cam),\(fl),\(fr),\(pxSz),\(filter),\(exp),\(gain),\(sw)"
        }

        static var csvHeader: String {
            "file,label,width,height,totalStars,measuredStars,medianFWHM,medianHFR,medianEcc,telescope,camera,focalLen,focalRatio,pixelSize,filter,exposure,gain,software"
        }
    }

    private func analyzeImage(url: URL, label: String) -> AnalysisResult? {
        let filename = url.lastPathComponent
        print("Analyzing [\(label)]: \(filename)...")

        // Extract FITS/XISF headers for hardware context
        let headers = MetadataExtractor.readHeaders(from: url)
        let scope = headers["TELESCOP"] ?? "?"
        let cam = headers["INSTRUME"] ?? "?"
        let fl = headers["FOCALLEN"] ?? "?"
        let fr = headers["FOCRATIO"] ?? "?"
        let pxSz = headers["XPIXSZ"] ?? "?"
        let filter = headers["FILTER"] ?? "?"
        let sw = headers["SWCREATE"] ?? headers["SOFTWARE"] ?? "?"
        print("  Setup: \(scope) + \(cam), FL=\(fl)mm f/\(fr), px=\(pxSz)µm, filter=\(filter), sw=\(sw)")

        let result = ImageDecoder.decode(url: url, device: device)
        guard case .success(let decoded) = result else {
            print("  ❌ Failed to decode")
            return nil
        }

        // Detect stars with higher cap for analysis
        let detected = StarDetector.detectStarsWithTotalCount(
            in: decoded, maxStars: 200, subsampleFactor: 4, sigmaThreshold: 5.0
        )

        // Measure metrics
        let metrics = StarMetricsCalculator.measure(
            stars: detected.stars,
            fullResImage: decoded,
            totalStarCount: detected.totalCount
        )

        let totalStars = detected.totalCount
        let measuredStars = metrics?.measuredStarCount ?? 0
        let medianFWHM = metrics?.medianFWHM ?? 0
        let medianHFR = metrics?.medianHFR ?? 0
        let medianEcc = metrics?.medianEccentricity
        let details = metrics?.starDetails ?? []

        let eccStr = medianEcc.map { String(format: "%.3f", $0) } ?? "n/a"

        // Run TrailingAnalyzer for consensus scoring
        let focalLength = Double(headers["FOCALLEN"] ?? "") ?? nil
        let pixelSize = Double(headers["XPIXSZ"] ?? "") ?? nil
        let trailing = TrailingAnalyzer.analyze(
            starDetails: details,
            focalLength: focalLength,
            pixelSizeMicrons: pixelSize
        )

        let trailStr = trailing.map { String(format: "%.3f", $0.trailingScore) } ?? "n/a"
        let consStr = trailing.map { String(format: "%.1f%%", $0.consensusFraction * 100) } ?? "n/a"
        let paStr = trailing?.consensusPA.map { String(format: "%.0f°", $0) } ?? "none"
        let arStr = trailing.map { String(format: "%.3f", $0.medianAxisRatio) } ?? "n/a"
        print("  Stars: \(totalStars) total, \(measuredStars) measured")
        print("  FWHM: \(String(format: "%.2f", medianFWHM)), HFR: \(String(format: "%.2f", medianHFR)), Ecc: \(eccStr)")
        print("  Trailing: score=\(trailStr), consensus=\(consStr), PA=\(paStr), axisRatio=\(arStr)")
        print("  Per-star details: \(details.count)")

        // Generate annotated PNG with trailing info
        generateAnnotatedPNG(
            image: decoded,
            allStars: detected.stars,
            measuredDetails: details,
            trailing: trailing,
            focalLength: focalLength,
            filename: "\(label)_\(url.deletingPathExtension().lastPathComponent)",
            label: label
        )

        return AnalysisResult(
            filename: filename, label: label,
            width: decoded.width, height: decoded.height,
            totalStars: totalStars, measuredStars: measuredStars,
            medianFWHM: medianFWHM, medianHFR: medianHFR,
            medianEcc: medianEcc, starDetails: details,
            headers: headers
        )
    }

    // MARK: - PNG Generation

    /// Generate an annotated PNG showing the stretched image with:
    /// - Green/Orange/Red circles: measured stars with relative eccentricity color coding
    /// - Direction lines through circles: PA of elongation per star
    /// - Large consensus arrow: dominant trailing direction (if detected)
    /// - Dashed rectangle: center crop 70% boundary
    /// - Legend with trailing score and metrics
    private func generateAnnotatedPNG(
        image: DecodedImage,
        allStars: [DetectedStar],
        measuredDetails: [StarDetail],
        trailing: TrailingAnalysis? = nil,
        focalLength: Double? = nil,
        filename: String,
        label: String
    ) {
        let w = image.width
        let h = image.height

        // Bin to max 2000px for reasonable PNG size
        let binFactor = max(1, max(w, h) / 2000)
        let outW = w / binFactor
        let outH = h / binFactor

        // Read raw data and apply simple stretch for visualization
        let planeSize = w * h
        let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: planeSize * image.channelCount)

        // Compute simple STF stretch parameters
        let sampleCount = min(50000, planeSize)
        let stride = max(1, planeSize / sampleCount)
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        for i in Swift.stride(from: 0, to: planeSize, by: stride) {
            samples.append(Float(ptr[i]) / 65535.0)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        // Simple deviation for MAD
        var devs = samples.map { abs($0 - median) }
        devs.sort()
        let mad = 1.4826 * devs[devs.count / 2]
        let c0 = max(0, median + (-1.25) * mad)

        // Create CGContext for output
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Fill with stretched image pixels
        let bufPtr = ctx.data!.bindMemory(to: UInt8.self, capacity: outW * outH * 4)
        for oy in 0..<outH {
            for ox in 0..<outW {
                let srcX = ox * binFactor
                let srcY = oy * binFactor
                let raw = Float(ptr[srcY * w + srcX]) / 65535.0
                // MTF stretch
                let clipped = max(0, min(1, (raw - c0) / max(1 - c0, 0.001)))
                let targetBg: Float = 0.25
                let mNorm = max(0.001, min(0.999, (median - c0) / max(1 - c0, 0.001)))
                let mb = mNorm * (1 - targetBg) / (mNorm * (1 - 2 * targetBg) + targetBg)
                let stretched: Float
                if clipped <= 0 { stretched = 0 }
                else if clipped >= 1 { stretched = 1 }
                else if clipped == mb { stretched = 0.5 }
                else { stretched = (mb - 1) * clipped / ((2 * mb - 1) * clipped - mb) }
                let v = UInt8(max(0, min(255, stretched * 255)))
                let pi = (oy * outW + ox) * 4
                bufPtr[pi] = v; bufPtr[pi+1] = v; bufPtr[pi+2] = v; bufPtr[pi+3] = 255
            }
        }

        // Draw center crop boundary (70% — dashed yellow rectangle)
        let cropMargin = 0.15  // 15% from each edge
        let cropX1 = Int(Double(outW) * cropMargin)
        let cropY1 = Int(Double(outH) * cropMargin)
        let cropX2 = Int(Double(outW) * (1 - cropMargin))
        let cropY2 = Int(Double(outH) * (1 - cropMargin))

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 0, alpha: 0.6))
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 4])
        ctx.stroke(CGRect(x: cropX1, y: cropY1, width: cropX2 - cropX1, height: cropY2 - cropY1))
        ctx.setLineDash(phase: 0, lengths: [])

        // Compute per-image relative eccentricity thresholds for color coding.
        // With adaptive aperture, absolute thresholds don't work across setups.
        // Use the image's own median ecc as anchor: stars significantly above median are flagged.
        let allEcc = measuredDetails.map { $0.eccentricity }.sorted()
        let medEcc = allEcc.isEmpty ? 0.5 : allEcc[allEcc.count / 2]
        // Stars within 1 MAD of median = green (normal for this setup)
        // Stars 1-2 MAD above = orange (borderline)
        // Stars >2 MAD above = red (clearly worse than peers)
        let eccDevs = allEcc.map { Swift.abs($0 - medEcc) }.sorted()
        let eccMAD = eccDevs.isEmpty ? 0.1 : max(0.05, eccDevs[eccDevs.count / 2])
        let orangeThresh = medEcc + eccMAD * 1.0
        let redThresh = medEcc + eccMAD * 2.0

        // Draw measured stars with RELATIVE eccentricity color coding
        for detail in measuredDetails {
            let sx = CGFloat(detail.x) / CGFloat(binFactor)
            let sy = CGFloat(detail.y) / CGFloat(binFactor)
            let radius: CGFloat = 12

            // Color relative to this image's star population
            let color: CGColor
            let lineWidth: CGFloat
            if detail.eccentricity > redThresh {
                color = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                lineWidth = 3
            } else if detail.eccentricity > orangeThresh {
                color = CGColor(red: 1, green: 0.6, blue: 0, alpha: 1)
                lineWidth = 2
            } else {
                color = CGColor(red: 0, green: 1, blue: 0, alpha: 0.8)
                lineWidth = 2
            }

            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.strokeEllipse(in: CGRect(x: sx - radius, y: sy - radius, width: radius * 2, height: radius * 2))

            // Draw PA direction line through circle (shows elongation direction)
            if let pa = detail.positionAngle, let ar = detail.axisRatio, ar < 0.9 {
                let paRad = pa * .pi / 180.0
                let lineLen = radius * 1.5
                let dx = CGFloat(cos(paRad)) * lineLen
                let dy = CGFloat(sin(paRad)) * lineLen
                ctx.setStrokeColor(color)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: sx - dx, y: sy - dy))
                ctx.addLine(to: CGPoint(x: sx + dx, y: sy + dy))
                ctx.strokePath()
            }
        }

        // Draw consensus trailing arrow — length proportional to trailing score
        if let t = trailing, let consensusPA = t.consensusPA, t.consensusFraction > 0.3 {
            let arrowLen: CGFloat = 40 + CGFloat(t.trailingScore) * 80  // 40-120px based on severity
            let paRad = consensusPA * .pi / 180.0
            let centerX = CGFloat(outW) / 2
            let centerY = CGFloat(outH) / 2
            let dx = CGFloat(cos(paRad)) * arrowLen
            let dy = CGFloat(sin(paRad)) * arrowLen

            // Draw thick arrow showing trailing direction
            let arrowColor = t.trailingScore > 0.5
                ? CGColor(red: 1, green: 0, blue: 0, alpha: 0.8)
                : CGColor(red: 1, green: 0.6, blue: 0, alpha: 0.8)
            ctx.setStrokeColor(arrowColor)
            ctx.setLineWidth(4)
            ctx.move(to: CGPoint(x: centerX - dx, y: centerY - dy))
            ctx.addLine(to: CGPoint(x: centerX + dx, y: centerY + dy))
            ctx.strokePath()
            // Arrowhead
            let headLen: CGFloat = 15
            let headAngle: CGFloat = .pi / 6
            ctx.move(to: CGPoint(x: centerX + dx, y: centerY + dy))
            ctx.addLine(to: CGPoint(x: centerX + dx - CGFloat(cos(paRad - headAngle)) * headLen,
                                    y: centerY + dy - CGFloat(sin(paRad - headAngle)) * headLen))
            ctx.move(to: CGPoint(x: centerX + dx, y: centerY + dy))
            ctx.addLine(to: CGPoint(x: centerX + dx - CGFloat(cos(paRad + headAngle)) * headLen,
                                    y: centerY + dy - CGFloat(sin(paRad + headAngle)) * headLen))
            ctx.strokePath()
        }

        // Draw legend
        let legendX: CGFloat = 10
        var legendY: CGFloat = CGFloat(outH) - 20  // CGContext has Y=0 at bottom
        let legendHeight: CGFloat = trailing != nil ? 140 : 110
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        ctx.fill(CGRect(x: 0, y: CGFloat(outH) - legendHeight, width: 500, height: legendHeight))

        // Use Core Text for legend text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let trailLine: String
        if let t = trailing {
            let paStr = t.consensusPA.map { String(format: "PA=%.0f°", $0) } ?? "no consensus"
            trailLine = "Trailing: \(String(format: "%.2f", t.trailingScore)) | consensus=\(String(format: "%.0f%%", t.consensusFraction * 100)) | \(paStr) | AR=\(String(format: "%.2f", t.medianAxisRatio))"
        } else {
            trailLine = "Trailing: n/a (insufficient data)"
        }
        let flStr = focalLength.map { String(format: "FL=%.0fmm", $0) } ?? "FL=unknown"
        let legendLines = [
            "[\(label)] \(filename)",
            "\(flStr) | \(allStars.count) detected, \(measuredDetails.count) measured | ecc=\(String(format: "%.3f", medEcc))",
            trailLine,
            "Circles: green=normal  orange=>+1MAD  red=>+2MAD | Lines=PA direction",
            "Arrow=consensus trailing direction | Yellow dashed=70% crop"
        ]
        for (i, line) in legendLines.enumerated() {
            let str = NSAttributedString(string: line, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(str)
            let path = CGPath(rect: CGRect(x: legendX, y: legendY - CGFloat(i) * 18, width: 390, height: 20), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: str.length), path, nil)
            CTFrameDraw(frame, ctx)
        }

        // Save PNG
        guard let cgImage = ctx.makeImage() else { return }
        let pngPath = outputDir + "/\(filename).png"
        let destURL = URL(fileURLWithPath: pngPath)
        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        print("  → PNG saved: \(pngPath)")
    }
}
