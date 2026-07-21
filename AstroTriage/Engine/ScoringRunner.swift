// ScoringRunner — single, headless source of truth for the decode→measure→score chain.
//
// Phase 0 of the auto-mark tuning-rig work. This factors the real end-to-end pipeline
// (previously duplicated in GoldenMiniSetTests.buildEntry and BatchQualityAnalysisTests.
// processImage) into ONE reusable, GUI-free entry point so that:
//   • the unit tests (GoldenMiniSet / BatchQualityAnalysis) call it → no duplicate logic,
//   • a non-sandboxed command-line tool (AstroScoreCLI) can drive the exact same chain
//     against an arbitrary NAS/Desktop folder for threshold tuning and golden-set testing.
//
// It depends only on the headless scoring engine (Foundation / Metal / the decoder bridge) —
// no SwiftUI, no AppKit, no TriageViewModel — which is why it compiles into the CLI target.
//
// NOTE: this is a MEASUREMENT/orchestration helper, not scoring logic — it changes no
// thresholds and no algorithm. kAlgorithmVersion is unaffected.

import Foundation
import Metal

enum ScoringRunner {

    // MARK: - Single-frame pipeline

    /// Decode one image and run the full measurement chain, returning a scored-ready ImageEntry
    /// (metrics populated, quality NOT yet computed — that needs the whole group). Returns nil
    /// if the file can't be decoded. Mirrors GoldenMiniSetTests.buildEntry exactly.
    static func buildEntry(url: URL,
                           device: MTLDevice,
                           previewGenerator: PreviewGenerator) -> ImageEntry? {
        let parsed = NINAFilenameParser.parse(url.lastPathComponent)
        var entry = MetadataExtractor.extractAndMerge(url: url, filenameParsed: parsed)
        guard case .success(let decoded) = ImageDecoder.decode(url: url, device: device) else { return nil }
        entry.width = decoded.width
        entry.height = decoded.height
        entry.channelCount = decoded.channelCount

        let noise = STFCalculator.measureNoise(from: decoded)
        entry.noiseMedian = noise.median
        entry.noiseMAD = noise.normalizedMAD

        let channel = decoded.channelCount == 3 ? 1 : 0
        let stars = previewGenerator.detectStarsFromImage(decoded, channel: channel)
        let totalStarCount = previewGenerator.lastTotalStarCount
        if !stars.isEmpty,
           let m = StarMetricsCalculator.measure(stars: stars, fullResImage: decoded,
                                                 channel: channel, totalStarCount: totalStarCount) {
            entry.computedFWHM = m.medianFWHM
            entry.computedHFR = m.medianHFR
            entry.computedStarCount = m.measuredStarCount > 0 ? m.totalStarCount : nil
            entry.computedEccentricity = m.medianEccentricity
            entry.starDetails = m.starDetails
            entry.starChainFraction = m.starChainFraction
            if let t = TrailingAnalyzer.analyze(starDetails: m.starDetails,
                                                focalLength: entry.focalLength,
                                                pixelSizeMicrons: entry.pixelSizeMicrons) {
                entry.trailingScore = t.trailingScore
                entry.trailingPA = t.consensusPA
                entry.trailingAxisRatio = t.medianAxisRatio
                entry.trailingConsensus = t.consensusFraction
            }
        }
        return entry
    }

    // MARK: - Folder scoring

    /// One frame's role in a labeled golden-set case.
    enum Label: String { case good, bad, unlabeled }

    struct FrameOutcome {
        let url: URL
        let caseID: String       // parent case folder name (or "." for a flat folder)
        let label: Label         // good / bad / unlabeled
        let entry: ImageEntry    // includes qualityBreakdown after scoring
    }

    struct FolderResult {
        var outcomes: [FrameOutcome] = []
        var decodedCount = 0
        var failedCount = 0
        var scoredCaseCount = 0
    }

    /// Discover and score a golden-set root (<CASE>/good + <CASE>/PRE-DELETE) OR a flat folder
    /// of images (treated as a single unlabeled case named "."). Each case is scored as its own
    /// group via QualityEstimator.computeScores so tiers are group-relative exactly as in-app.
    static func scoreFolder(root: URL,
                            device: MTLDevice,
                            previewGenerator: PreviewGenerator,
                            config: ScoringConfig = .default,
                            progress: ((String) -> Void)? = nil) -> FolderResult {
        var result = FolderResult()
        let cases = discoverCases(under: root)

        for c in cases {
            progress?("case \(c.id): \(c.goodFrames.count) good, \(c.badFrames.count) bad")
            var entries: [ImageEntry] = []
            var labelByURL: [URL: Label] = [:]

            for url in c.goodFrames {
                if let e = buildEntry(url: url, device: device, previewGenerator: previewGenerator) {
                    entries.append(e); labelByURL[url] = .good; result.decodedCount += 1
                } else { result.failedCount += 1 }
            }
            for url in c.badFrames {
                if let e = buildEntry(url: url, device: device, previewGenerator: previewGenerator) {
                    entries.append(e); labelByURL[url] = .bad; result.decodedCount += 1
                } else { result.failedCount += 1 }
            }
            for url in c.unlabeledFrames {
                if let e = buildEntry(url: url, device: device, previewGenerator: previewGenerator) {
                    entries.append(e); labelByURL[url] = .unlabeled; result.decodedCount += 1
                } else { result.failedCount += 1 }
            }

            let scores = QualityEstimator.computeScores(for: entries, config: config)
            for i in entries.indices { entries[i].qualityBreakdown = scores[entries[i].url] }
            if !scores.isEmpty { result.scoredCaseCount += 1 }

            for e in entries {
                result.outcomes.append(FrameOutcome(url: e.url,
                                                    caseID: c.id,
                                                    label: labelByURL[e.url] ?? .unlabeled,
                                                    entry: e))
            }
        }
        return result
    }

    // MARK: - Case discovery (mirrors GoldenMiniSetTests.discoverCases + flat-folder fallback)

    struct DiscoveredCase {
        let id: String
        let goodFrames: [URL]
        let badFrames: [URL]
        let unlabeledFrames: [URL]
    }

    static let imageExtensions: Set<String> = ["fit", "fits", "fts", "xisf"]

    static func discoverCases(under root: URL) -> [DiscoveredCase] {
        let fm = FileManager.default
        let rootPath = root.path

        // A golden-set root: subfolders each containing good/ and/or PRE-DELETE/.
        let entries = ((try? fm.contentsOfDirectory(atPath: rootPath)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "_analysis" }
            .sorted()

        var cases: [DiscoveredCase] = []
        var sawStructuredCase = false

        for name in entries {
            let casePath = rootPath + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: casePath, isDirectory: &isDir), isDir.boolValue else { continue }
            let subdirs = (try? fm.contentsOfDirectory(atPath: casePath)) ?? []
            let goodDir = subdirs.first { $0.lowercased() == "good" }
            let badDir = subdirs.first { $0.lowercased().hasPrefix("pre-delete") || $0.lowercased() == "bad" }
            guard goodDir != nil || badDir != nil else { continue }
            sawStructuredCase = true
            let good = goodDir.map { images(inDir: casePath + "/" + $0) } ?? []
            let bad = badDir.map { images(inDir: casePath + "/" + $0) } ?? []
            cases.append(DiscoveredCase(id: name, goodFrames: good, badFrames: bad, unlabeledFrames: []))
        }

        // Flat folder of images (no good/PRE-DELETE structure): one unlabeled case named ".".
        if !sawStructuredCase {
            let flat = images(inDir: rootPath)
            if !flat.isEmpty {
                cases.append(DiscoveredCase(id: ".", goodFrames: [], badFrames: [], unlabeledFrames: flat))
            }
        }
        return cases
    }

    private static func images(inDir dir: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") && imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted()
            .map { URL(fileURLWithPath: dir + "/" + $0) }
    }
}
