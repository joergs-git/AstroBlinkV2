// AstroScoreCLI — headless, non-sandboxed scoring driver for the auto-mark pipeline.
//
// Phase 0 of the tuning-rig work. This command-line tool runs the EXACT same decode→measure→
// score chain as the app (via the shared ScoringRunner), but as a plain SPM/xcodegen `tool`
// target — so it is NOT app-sandboxed and can read any NAS/Desktop folder. It scores a golden-
// set root (<CASE>/good + <CASE>/PRE-DELETE) or a flat folder of frames, writes a per-frame CSV,
// and prints an agreement report (confusion matrix of human label vs assigned tier).
//
// Usage:
//   AstroScoreCLI --data-root <folder> [--csv <out.csv>] [--config <config.json>] [--report]
//
// Phase 0 changes NO thresholds; --config is accepted but the default reproduces today's
// scoring exactly. Threshold externalization is wired in a later step.

import Foundation
import Metal

// MARK: - Arg parsing

struct Args {
    var dataRoot: String?
    var csvPath: String?
    var configPath: String?
    var report = false
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--data-root": a.dataRoot = it.next()
        case "--csv":       a.csvPath = it.next()
        case "--config":    a.configPath = it.next()
        case "--report":    a.report = true
        case "--dump-config":
            print(ScoringConfig.default.jsonString()); exit(0)
        case "-h", "--help":
            printUsage(); exit(0)
        default:
            FileHandle.standardError.write("Unknown argument: \(arg)\n".data(using: .utf8)!)
            printUsage(); exit(2)
        }
    }
    return a
}

func printUsage() {
    print("""
    AstroScoreCLI — headless scoring driver

    Usage:
      AstroScoreCLI --data-root <folder> [--csv <out.csv>] [--config <config.json>] [--report]

    --data-root  Golden-set root (<CASE>/good + <CASE>/PRE-DELETE) or a flat folder of frames.
    --csv        Write per-frame results to this CSV path.
    --config     Scoring-config JSON override (partial: only the keys you set; rest = default).
    --report     Print an agreement report (label vs tier confusion matrix) to stdout.
    --dump-config  Print the default scoring-config JSON (template for --config) and exit.
    """)
}

// MARK: - Metal library loading (bundle-less tool → load default.metallib next to the binary)

func loadMetalLibrary(_ device: MTLDevice) -> MTLLibrary? {
    if let lib = device.makeDefaultLibrary() { return lib }
    // A command-line tool has no .app bundle; the compiled default.metallib sits next to the
    // executable in the build products dir. Load it explicitly and inject it into PreviewGenerator.
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let url = exeDir.appendingPathComponent("default.metallib")
    return try? device.makeLibrary(URL: url)
}

// MARK: - CSV

func csvHeader() -> String {
    "case,label,filename,tier,combinedZ,fwhm,hfr,stars,ecc,trailingScore,trailingConsensus,momentEcc,fitEcc,momentPreferredFrac,fitAcceptedFrac,noiseMedian,noiseMAD,snr,starsZ,fwhmZ,noiseZ,trailingZ,garbageReasons,recommendation"
}

func csvRow(_ o: ScoringRunner.FrameOutcome) -> String {
    let e = o.entry
    let b = e.qualityBreakdown
    func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
    func fF(_ v: Float?) -> String { v.map { String(format: "%.4f", Double($0)) } ?? "" }
    func i(_ v: Int?) -> String { v.map(String.init) ?? "" }
    let snr: String = {
        if let m = e.noiseMedian, let mad = e.noiseMAD, mad > 0 { return String(format: "%.3f", Double(m / mad)) }
        return ""
    }()
    let tier = (b?.tier).map { "\($0)" } ?? "unscored"
    let reasons = (b?.garbageReasons.map { $0.rawValue }.joined(separator: "|")) ?? ""
    let rec = b?.recommendationLabel ?? ""
    // Escape any commas in text fields.
    func esc(_ s: String) -> String { s.contains(",") ? "\"\(s)\"" : s }
    return [
        esc(o.caseID), o.label.rawValue, esc(e.filename),
        tier, f(b?.combinedZScore),
        f(e.computedFWHM), f(e.computedHFR), i(e.computedStarCount), f(e.computedEccentricity),
        f(e.trailingScore), f(e.trailingConsensus),
        f(e.momentEccentricity), f(e.fitEccentricity), f(e.momentPreferredFraction), f(e.fitAcceptedFraction),
        fF(e.noiseMedian), fF(e.noiseMAD), snr,
        f(b?.starsZ), f(b?.fwhmZ), f(b?.noiseZ), f(b?.trailingZ),
        esc(reasons), esc(rec)
    ].joined(separator: ",")
}

// MARK: - Report

func printAgreementReport(_ result: ScoringRunner.FolderResult) {
    // Monotonic rank: trash/borderline/uncertain = "not good", good/excellent = "good".
    func isGoodTier(_ o: ScoringRunner.FrameOutcome) -> Bool? {
        guard let t = o.entry.qualityBreakdown?.tier else { return nil }
        return t == .good || t == .excellent
    }
    let labeled = result.outcomes.filter { $0.label != .unlabeled }
    guard !labeled.isEmpty else {
        print("\n(no labeled good/bad frames — flat folder; see CSV for per-frame tiers)")
        return
    }
    var truePos = 0, falseNeg = 0, trueNeg = 0, falsePos = 0, unscored = 0
    for o in labeled {
        guard let good = isGoodTier(o) else { unscored += 1; continue }
        switch (o.label, good) {
        case (.good, true):  truePos += 1     // good frame kept  ✓
        case (.good, false): falsePos += 1    // good frame flagged (false alarm)
        case (.bad, false):  trueNeg += 1     // bad frame caught ✓
        case (.bad, true):   falseNeg += 1    // bad frame passed as good (miss)
        default: break
        }
    }
    let goodTotal = truePos + falsePos
    let badTotal = trueNeg + falseNeg
    print("""

    ── Agreement report (human label vs assigned tier) ──
      GOOD frames: \(goodTotal)   kept(good/excellent)=\(truePos)   flagged=\(falsePos)  [false alarms]
      BAD  frames: \(badTotal)   caught(not good)=\(trueNeg)   passed-as-good=\(falseNeg)  [misses]
      unscored (group<6): \(unscored)
    """)
    if goodTotal > 0 {
        print(String(format: "      false-alarm rate (good flagged): %.1f%%", 100.0 * Double(falsePos) / Double(goodTotal)))
    }
    if badTotal > 0 {
        print(String(format: "      catch rate      (bad caught):   %.1f%%", 100.0 * Double(trueNeg) / Double(badTotal)))
    }
}

// MARK: - Main

let args = parseArgs()

guard let dataRoot = args.dataRoot else {
    FileHandle.standardError.write("error: --data-root is required\n".data(using: .utf8)!)
    printUsage(); exit(2)
}
let rootURL = URL(fileURLWithPath: dataRoot)
guard FileManager.default.fileExists(atPath: rootURL.path) else {
    FileHandle.standardError.write("error: data-root not found: \(dataRoot)\n".data(using: .utf8)!)
    exit(1)
}

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("error: no Metal device available\n".data(using: .utf8)!)
    exit(1)
}
let library = loadMetalLibrary(device)
guard let previewGenerator = PreviewGenerator(device: device, library: library) else {
    FileHandle.standardError.write("error: PreviewGenerator init failed (Metal library not loaded)\n".data(using: .utf8)!)
    exit(1)
}

// Load scoring config: --config JSON override, else the canonical default (== app behavior).
var scoringConfig = ScoringConfig.default
if let cfg = args.configPath {
    do {
        scoringConfig = try ScoringConfig.load(from: URL(fileURLWithPath: cfg))
        print("Loaded scoring config from \(cfg)")
    } catch {
        FileHandle.standardError.write("error loading --config \(cfg): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("Scoring \(rootURL.path) …")
let result = ScoringRunner.scoreFolder(root: rootURL, device: device,
                                       previewGenerator: previewGenerator,
                                       config: scoringConfig) { msg in
    print("  \(msg)")
}
print("Decoded \(result.decodedCount) frames (\(result.failedCount) failed), \(result.scoredCaseCount) case(s) scored.")

if let csvPath = args.csvPath {
    var csv = csvHeader() + "\n"
    for o in result.outcomes { csv += csvRow(o) + "\n" }
    do {
        try csv.write(toFile: csvPath, atomically: true, encoding: .utf8)
        print("Wrote CSV: \(csvPath)  (\(result.outcomes.count) rows)")
    } catch {
        FileHandle.standardError.write("error writing CSV: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if args.report {
    printAgreementReport(result)
}
