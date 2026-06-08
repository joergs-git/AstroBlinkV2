// Golden Mini-Set regression gate.
//
// Replaces the 331 GB QUALITYCHECKDATA marathon with a small curated set that is a REAL
// pass/fail gate (not just an informational harness). Layout:
//
//   TestImages/QUALITYCHECKMINI/<CASE>/good/         representative GOOD frames
//                              <CASE>/PRE-DELETE/     representative BAD frames
//
// Each CASE must hold ≥6 frames of ONE GroupKey (filter+target+exposure+FL+sensor) so
// QualityEstimator.computeScores (minGroupSize=6) actually scores them — see the group-size
// guard below. For each case the real pipeline (decode → measure → TrailingAnalyzer →
// QualityEstimator) runs and the gate asserts good↔bad separation.
//
// The set is gitignored (TestImages/*); absent data → clean XCTSkip so CI still builds green.
// The synthetic ScoringRegressionTests / ScoringValidationTests remain the always-on logic
// gates; this gate validates the end-to-end measurement pipeline on real pixels.

import XCTest
@testable import AstroTriage
import Metal

// MARK: - Shared data-root resolver

enum MiniSetSupport {
    /// Repo root derived from this source file's path (…/Tests/GoldenMiniSetTests.swift → repo).
    static var repoRoot: String {
        // #filePath = <repo>/Tests/GoldenMiniSetTests.swift
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Resolution precedence: ASTRO_TEST_DATA_ROOT env → QUALITYCHECKMINI → QUALITYCHECKDATA → nil.
    static func resolveDataRoot() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["ASTRO_TEST_DATA_ROOT"],
           fm.fileExists(atPath: env) { return env }
        let mini = repoRoot + "/TestImages/QUALITYCHECKMINI"
        if fm.fileExists(atPath: mini) { return mini }
        let full = repoRoot + "/TestImages/QUALITYCHECKDATA"
        if fm.fileExists(atPath: full) { return full }
        return nil
    }

    static let imageExtensions: Set<String> = ["fit", "fits", "fts", "xisf"]
}

final class GoldenMiniSetTests: XCTestCase {

    // Gate constants (tunable — mirror QualityEstimator's own thresholds).
    private let minGoodMedianRank = 2          // good-side median must be Good(2) or Excellent(3)
    private let minBadCaughtFraction = 0.80    // ≥80% of labeled-bad frames must NOT be Good/Excellent
    private let trailDelta = 0.10              // bad trailing median must exceed good by this
    private let snrRatioMax = 0.65             // bad SNR median < 0.65 × good SNR median
    private let fwhmRatioMin = 1.30            // bad FWHM median > 1.30 × good FWHM median

    private var device: MTLDevice!
    private var previewGenerator: PreviewGenerator!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal device required")
        previewGenerator = PreviewGenerator(device: device)
        try XCTSkipIf(previewGenerator == nil, "PreviewGenerator init failed")
    }

    // MARK: - The gate

    func testGoldenMiniSetSeparation() throws {
        guard let root = MiniSetSupport.resolveDataRoot() else {
            throw XCTSkip("No test data root (QUALITYCHECKMINI / QUALITYCHECKDATA / ASTRO_TEST_DATA_ROOT)")
        }
        // Only run the gate against the curated MINI set (the full corpus has a different layout).
        guard root.hasSuffix("QUALITYCHECKMINI") else {
            throw XCTSkip("Mini-set not present (resolved \(root)); gate runs only against QUALITYCHECKMINI")
        }

        let cases = discoverCases(under: root)
        try XCTSkipIf(cases.isEmpty, "No mini-set cases (need <CASE>/good + <CASE>/PRE-DELETE) under \(root)")

        var ran = 0, skipped = 0
        for c in cases {
            let result = evaluateCase(c)
            switch result {
            case .skipped(let why):
                skipped += 1
                print("  [mini] SKIP \(c.id): \(why)")
            case .ran:
                ran += 1
            }
        }
        print("\n  [mini] cases ran=\(ran) skipped=\(skipped) total=\(cases.count)")
        // If every case skipped (e.g. all under-populated), surface it rather than green-vacuous.
        try XCTSkipIf(ran == 0, "All \(cases.count) mini-set cases skipped (under-populated / group<6)")
    }

    // MARK: - Per-case evaluation

    private enum CaseResult { case ran; case skipped(String) }

    private func evaluateCase(_ c: MiniCase) -> CaseResult {
        // Build entries for ALL case frames (good + bad together → one scoring batch).
        var entries: [ImageEntry] = []
        var goodURLs = Set<URL>(), badURLs = Set<URL>()
        for url in c.goodFrames { if let e = buildEntry(url: url) { entries.append(e); goodURLs.insert(url) } }
        for url in c.badFrames  { if let e = buildEntry(url: url) { entries.append(e); badURLs.insert(url) } }

        guard entries.count >= QualityEstimator.minGroupSize else {
            return .skipped("only \(entries.count) decodable frames (< minGroupSize \(QualityEstimator.minGroupSize))")
        }

        // Score the batch.
        let scores = QualityEstimator.computeScores(for: entries)
        for i in entries.indices { entries[i].qualityBreakdown = scores[entries[i].url] }

        let good = entries.filter { goodURLs.contains($0.url) && $0.qualityTier != nil }
        let bad  = entries.filter { badURLs.contains($0.url)  && $0.qualityTier != nil }

        guard good.count >= 3 else {
            return .skipped("only \(good.count) scored good frames (group<6 → unscored). Add more same-GroupKey good frames.")
        }

        // ── HARD assertion A: good-side floor ──
        // Good frames must score Good/Excellent within their own group. Reliable even on a
        // small isolated group (their group median IS the reference).
        let goodRanks = good.map { rank($0.qualityTier!) }.sorted()
        let goodMedian = goodRanks[goodRanks.count / 2]
        XCTAssertGreaterThanOrEqual(goodMedian, minGoodMedianRank,
            "[\(c.id)] good-frame median quality rank \(goodMedian) < \(minGoodMedianRank) (Good). Good frames are being under-rated.")

        // Cases with no labeled bad frames (baseline/clean/orient) only assert the good floor.
        guard !bad.isEmpty else { return .ran }

        // ── HARD assertion B: measured-metric separation (the real measurement-regression gate) ──
        // This is what would have caught the v6.4.2 trailing bug: if the shape measurement
        // collapses trails to "round", bad trailing ≈ good → this fails. Tier separation is
        // deliberately NOT a hard gate here — relative/session-sanity scoring needs full-corpus
        // context a small isolated group can't provide (that's what the synthetic
        // ScoringRegressionTests cover). We assert on the physical defect signal instead.
        assertMetricSeparation(c: c, good: good, bad: bad)

        // ── SOFT (informational): tier caught-fraction, ref threshold 60% (matches synthetic) ──
        let caught = bad.filter { $0.qualityTier != .good && $0.qualityTier != .excellent }.count
        let caughtFrac = bad.isEmpty ? 1.0 : Double(caught) / Double(bad.count)
        let badRanks = bad.map { rank($0.qualityTier!) }.sorted()
        let badMedian = badRanks[badRanks.count / 2]
        print(String(format: "  [mini] %@: good median rank=%d, bad median rank=%d, bad caught %d/%d (%.0f%%, ref ≥%.0f%%)",
                     c.id, goodMedian, badMedian, caught, bad.count, caughtFrac * 100, minBadCaughtFraction * 100))
        if caughtFrac < minBadCaughtFraction {
            print("  [mini]   note: tier caught-fraction below \(Int(minBadCaughtFraction*100))% ref — relative scoring on a small isolated group; measured separation is the gate.")
        }

        return .ran
    }

    /// Defect-specific raw-metric separation — the HARD measurement-regression gate.
    private func assertMetricSeparation(c: MiniCase, good: [ImageEntry], bad: [ImageEntry]) {
        let id = c.id.lowercased()
        if id.contains("trail") || id.contains("badstar") || id.contains("hop") {
            if let gT = median(good.compactMap { $0.trailingScore }),
               let bT = median(bad.compactMap { $0.trailingScore }) {
                XCTAssertGreaterThan(bT, gT + trailDelta,
                    "[\(c.id)] bad trailing median \(fmt(bT)) not > good \(fmt(gT)) + \(trailDelta).")
            }
        } else if id.contains("lowsnr") || id.contains("cloud") {
            if let gS = median(good.compactMap { snr($0) }),
               let bS = median(bad.compactMap { snr($0) }), gS > 0 {
                XCTAssertLessThan(bS, snrRatioMax * gS,
                    "[\(c.id)] bad SNR median \(fmt(bS)) not < \(snrRatioMax) × good \(fmt(gS)).")
            }
        } else if id.contains("wind") || id.contains("fwhm") || id.contains("defocus") {
            if let gF = median(good.compactMap { $0.computedFWHM }),
               let bF = median(bad.compactMap { $0.computedFWHM }), gF > 0 {
                XCTAssertGreaterThan(bF, fwhmRatioMin * gF,
                    "[\(c.id)] bad FWHM median \(fmt(bF)) not > \(fwhmRatioMin) × good \(fmt(gF)).")
            }
        } else if id.contains("twilight") || id.contains("gradient") || id.contains("dawn") {
            // Twilight/dawn/gradient: each bad frame must carry a Stage-1 garbage reason
            // (abnormal background / no signal / low SNR), and the background level must be
            // clearly elevated vs the night good frames.
            for e in bad {
                XCTAssertFalse(e.qualityBreakdown?.garbageReasons.isEmpty ?? true,
                    "[\(c.id)] twilight/dawn frame \(e.filename) has no Stage-1 garbage reason.")
            }
            if let gB = median(good.compactMap { $0.noiseMedian.map(Double.init) }),
               let bB = median(bad.compactMap { $0.noiseMedian.map(Double.init) }), gB > 0 {
                XCTAssertGreaterThan(bB, 3.0 * gB,
                    "[\(c.id)] bad background median \(fmt(bB)) not > 3× good \(fmt(gB)) — twilight gradient not separating.")
            }
        } else if id.contains("dark") || id.contains("dome") {
            for e in bad {
                XCTAssertFalse(e.qualityBreakdown?.garbageReasons.isEmpty ?? true,
                    "[\(c.id)] dark/dome frame \(e.filename) has no Stage-1 garbage reason.")
            }
        }
    }

    // MARK: - Pipeline (lean variant of BatchQualityAnalysisTests.processImage; no thumbnails)

    private func buildEntry(url: URL) -> ImageEntry? {
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

    // MARK: - Case discovery

    private struct MiniCase { let id: String; let goodFrames: [URL]; let badFrames: [URL] }

    private func discoverCases(under root: String) -> [MiniCase] {
        let fm = FileManager.default
        let caseDirs = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "_analysis" }
            .sorted()
        var cases: [MiniCase] = []
        for name in caseDirs {
            let casePath = root + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: casePath, isDirectory: &isDir), isDir.boolValue else { continue }
            let subdirs = (try? fm.contentsOfDirectory(atPath: casePath)) ?? []
            let goodDir = subdirs.first { $0.lowercased() == "good" }
            let badDir = subdirs.first { $0.lowercased().hasPrefix("pre-delete") || $0.lowercased() == "bad" }
            guard let goodDir = goodDir else { continue }  // need at least a good/ folder
            let good = images(in: casePath + "/" + goodDir)
            let bad = badDir.map { images(in: casePath + "/" + $0) } ?? []
            guard !good.isEmpty else { continue }
            cases.append(MiniCase(id: name, goodFrames: good, badFrames: bad))
        }
        return cases
    }

    private func images(in dir: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") && MiniSetSupport.imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted()
            .map { URL(fileURLWithPath: dir + "/" + $0) }
    }

    // MARK: - Helpers

    /// Monotonic quality rank (QualityTier.rawValue is NOT monotonic: uncertain=4).
    private func rank(_ tier: QualityTier) -> Int {
        switch tier {
        case .trash:      return 0
        case .borderline: return 1
        case .uncertain:  return 1
        case .good:       return 2
        case .excellent:  return 3
        }
    }

    private func snr(_ e: ImageEntry) -> Double? {
        guard let med = e.noiseMedian, let mad = e.noiseMAD, mad > 0 else { return nil }
        return Double(med / mad)
    }

    private func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(); return s[s.count / 2]
    }

    private func fmt(_ x: Double) -> String { String(format: "%.3f", x) }
}
