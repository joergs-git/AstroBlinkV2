// ScoringConfig — externalized, JSON-tunable scoring thresholds (Phase 0 of the tuning rig).
//
// The auto-mark pipeline historically compiled all its thresholds as `static let` constants,
// so tuning them meant a recompile. This struct hoists the DECISION-relevant knobs into a
// single value that `QualityEstimator.computeScores` reads, so the CLI (AstroScoreCLI) — and
// later an in-app settings/calibration surface — can override them from a JSON file WITHOUT
// recompiling, enabling batch tuning / ML against a curated golden set.
//
// CRITICAL — `ScoringConfig.default` reproduces today's constants EXACTLY. When the default is
// used (the app's current behavior), scoring output is bit-identical; the `static let` values in
// QualityEstimator remain the canonical source and are only MIRRORED here. This is why Phase 0
// touches quality-critical files but changes no behavior — kAlgorithmVersion is unaffected.
//
// Scope (Phase 0): the group-relative tier cutoffs (the "knife-edge" behind near-identical frames
// getting opposite verdicts), the z-score cap, the relative garbage drop-factor, and the absolute
// trailing ceiling/consensus. Measurement-side constants (StarMetrics apertures, HFR/FWHM px
// bounds) and the filter-trailing multipliers are deliberately NOT threaded yet — a later
// increment, so this change stays small and provably identical.

import Foundation

struct ScoringConfig: Codable, Equatable {

    // Stage-2 tier cutoffs on the group-relative combined z-score.
    var thresholdExcellent: Double      // combinedZ >  this → excellent
    var thresholdGood: Double           // combinedZ >  this → good
    var thresholdBorderline: Double     // combinedZ >  this → borderline, else trash

    // Stage-2 per-metric z-score clamp (±cap).
    var zscoreCap: Double

    // Stage-1 relative garbage drop factor (value < factor × group median → garbage).
    var garbageDropFactor: Double

    // Rule 6a absolute trailing ceiling: trailingScore above this (with consensus above the
    // consensus gate) is trailing-garbage regardless of the group.
    var absoluteTrailingCeilingScore: Double
    var absoluteTrailingCeilingConsensus: Double

    // Physical plausibility corridor for star-shape measurements. A measured FWHM below
    // max(seeing / arcsecPerPixel, sampling) cannot describe a star and is discarded before
    // it can enter any median, z-score or rule. Exposed here so a site with exceptional
    // seeing, or a very different plate scale, can be accommodated without a new build.
    var minPlausibleSeeingArcsec: Double
    var minPlausibleFWHMPixels: Double

    // Dark/dome/cap exemption (algo v43): a frame whose background scatter sits at the read-noise
    // floor ("flat pedestal") is NOT a dark when it carries at least this many PSF-shaped
    // detections per megapixel. Darks keep 2–4 warm-pixel clusters per megapixel after the v41
    // extent gate (ASI6200 at -10 °C); a 60 s H-alpha OSC frame whose sky is below the read
    // noise carries 54–146 real stars per megapixel.
    var pedestalSkyStarsPerMegapixel: Double
    // ...and those detections must be PSF-shaped: median scale-free residual of the circular
    // Gaussian fit below this. Warm-pixel clusters on darks fit at 0.23–0.28, real stars —
    // trailed ones included — at 0.02–0.12. Guards the exemption against a hot sensor whose
    // cluster count alone could pass the density floor.
    var pedestalSkyMaxFitResidual: Double

    /// The canonical defaults — MUST equal the `static let` values in QualityEstimator.swift.
    /// Using this config yields byte-identical scoring to the pre-externalization build.
    static let `default` = ScoringConfig(
        thresholdExcellent: 0.5,
        thresholdGood: -0.5,
        thresholdBorderline: -2.0,
        zscoreCap: 3.0,
        garbageDropFactor: 0.50,
        absoluteTrailingCeilingScore: 0.60,
        absoluteTrailingCeilingConsensus: 0.5,
        minPlausibleSeeingArcsec: 1.0,
        minPlausibleFWHMPixels: 1.2,
        pedestalSkyStarsPerMegapixel: 20,
        pedestalSkyMaxFitResidual: 0.17
    )

    // MARK: - Partial-override JSON decoding
    //
    // Any missing key falls back to the default, so a tuning JSON can override just one knob:
    //   { "thresholdGood": -0.6 }
    // leaves every other threshold at its default.

    init(thresholdExcellent: Double,
         thresholdGood: Double,
         thresholdBorderline: Double,
         zscoreCap: Double,
         garbageDropFactor: Double,
         absoluteTrailingCeilingScore: Double,
         absoluteTrailingCeilingConsensus: Double,
         minPlausibleSeeingArcsec: Double,
         minPlausibleFWHMPixels: Double,
         pedestalSkyStarsPerMegapixel: Double,
         pedestalSkyMaxFitResidual: Double) {
        self.thresholdExcellent = thresholdExcellent
        self.thresholdGood = thresholdGood
        self.thresholdBorderline = thresholdBorderline
        self.zscoreCap = zscoreCap
        self.garbageDropFactor = garbageDropFactor
        self.absoluteTrailingCeilingScore = absoluteTrailingCeilingScore
        self.absoluteTrailingCeilingConsensus = absoluteTrailingCeilingConsensus
        self.minPlausibleSeeingArcsec = minPlausibleSeeingArcsec
        self.minPlausibleFWHMPixels = minPlausibleFWHMPixels
        self.pedestalSkyStarsPerMegapixel = pedestalSkyStarsPerMegapixel
        self.pedestalSkyMaxFitResidual = pedestalSkyMaxFitResidual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScoringConfig.default
        thresholdExcellent = try c.decodeIfPresent(Double.self, forKey: .thresholdExcellent) ?? d.thresholdExcellent
        thresholdGood = try c.decodeIfPresent(Double.self, forKey: .thresholdGood) ?? d.thresholdGood
        thresholdBorderline = try c.decodeIfPresent(Double.self, forKey: .thresholdBorderline) ?? d.thresholdBorderline
        zscoreCap = try c.decodeIfPresent(Double.self, forKey: .zscoreCap) ?? d.zscoreCap
        garbageDropFactor = try c.decodeIfPresent(Double.self, forKey: .garbageDropFactor) ?? d.garbageDropFactor
        absoluteTrailingCeilingScore = try c.decodeIfPresent(Double.self, forKey: .absoluteTrailingCeilingScore) ?? d.absoluteTrailingCeilingScore
        absoluteTrailingCeilingConsensus = try c.decodeIfPresent(Double.self, forKey: .absoluteTrailingCeilingConsensus) ?? d.absoluteTrailingCeilingConsensus
        minPlausibleSeeingArcsec = try c.decodeIfPresent(Double.self, forKey: .minPlausibleSeeingArcsec) ?? d.minPlausibleSeeingArcsec
        minPlausibleFWHMPixels = try c.decodeIfPresent(Double.self, forKey: .minPlausibleFWHMPixels) ?? d.minPlausibleFWHMPixels
        pedestalSkyStarsPerMegapixel = try c.decodeIfPresent(Double.self, forKey: .pedestalSkyStarsPerMegapixel) ?? d.pedestalSkyStarsPerMegapixel
        pedestalSkyMaxFitResidual = try c.decodeIfPresent(Double.self, forKey: .pedestalSkyMaxFitResidual) ?? d.pedestalSkyMaxFitResidual
    }

    // MARK: - Load / dump

    /// Load a config from a JSON file. Missing keys fall back to defaults (partial override).
    static func load(from url: URL) throws -> ScoringConfig {
        try JSONDecoder().decode(ScoringConfig.self, from: Data(contentsOf: url))
    }

    /// Pretty JSON of the full config (all knobs) — useful as a `--dump-config` template.
    func jsonString() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
