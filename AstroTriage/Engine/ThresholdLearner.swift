// Phase 2 — Curation-Driven Threshold Learning
//
// Per-setup soft adjustments to QualityEstimator's tier cutoffs, learned by
// grid search over the user's curated star ratings. Output is a
// `LearnedThresholds` struct stored in the `CalibrationProfile`.
//
// Design rules (see `~/.claude/plans/mutable-singing-glacier.md`):
//   - Z-score COMPUTATION unchanged — only the tier CUTOFF moves.
//   - Stage 1 hard backstops stay immovable; offsets are soft overrides.
//   - Past curated data informs the current session (no feedback loop).
//   - Never learn from frames flagged decentered / background / twilight —
//     those are physical issues a zoomed-in human cannot judge from the
//     thumbnail, so the curated rating carries no useful signal there.
//   - Asymmetric cost FP × 1.5 + FN × 2.5 (false negatives — keeping a
//     frame the user rated 1★ — are punished harder than rejecting a frame
//     the user rated ≥2★).
//   - Tie-break: prefer `offset = 0.0` (regularization toward defaults).

import Foundation

enum ThresholdLearner {

    // MARK: - Tunables (kept here so the plan + CLAUDE.md cross-ref by name)

    /// Garbage reasons the human curator cannot reliably judge from the
    /// zoomed view we present, so frames carrying them are excluded from the
    /// grid search regardless of star rating.
    static let nonLearnableReasons: Set<String> = [
        GarbageReason.decenteredTarget.rawValue,
        GarbageReason.backgroundAnomaly.rawValue,
        GarbageReason.twilightExposure.rawValue,
    ]

    /// Min curated frames overall + min frames per rating class before the
    /// borderline grid search runs. Matches `LearnedThresholds.learningThreshold`.
    static let minBorderlineSamples = 50
    static let minBorderlineSamplesPerClass = 10

    /// Min curated frames with relevant trailing data before the trailing
    /// ceiling grid search runs.
    static let minTrailingSamples = 20

    /// Search ranges + step sizes. Capping the offsets prevents the learner
    /// from getting too aggressive when the user's curation is noisy.
    static let borderlineOffsetRange: ClosedRange<Double> = -0.8 ... 0.8
    static let borderlineOffsetStep: Double = 0.1
    static let trailingOffsetRange: ClosedRange<Double> = -0.15 ... 0.20
    static let trailingOffsetStep: Double = 0.05

    /// Asymmetric cost weighting: false negatives (algorithm keeps a frame
    /// the user rated 1★) are 2.5×; false positives (algorithm rejects a
    /// frame the user rated ≥2★) are 1.5×.
    static let costFalsePositive: Double = 1.5
    static let costFalseNegative: Double = 2.5

    // MARK: - Entry point

    /// Run grid search on a curated set for one setup. Returns nil when the
    /// data is too thin for stable thresholds — the caller falls back to
    /// QualityEstimator's static defaults.
    ///
    /// - Parameters:
    ///   - curatedFrames: FrameRecords with `userConfidence > 0` for ONE
    ///     setupHash (caller filters via
    ///     `FrameHistoryDatabase.curatedFrameRecords(setupHash:)`).
    ///   - currentBorderline: `QualityEstimator.thresholdBorderline` (-2.0).
    ///   - currentTrailingCeiling: `QualityEstimator.absoluteTrailingCeilingScore` (0.60).
    static func computeLearnedThresholds(
        curatedFrames: [FrameRecord],
        currentBorderline: Double = -2.0,
        currentTrailingCeiling: Double = 0.60
    ) -> LearnedThresholds? {
        let borderline = computeBorderlineOffset(
            frames: curatedFrames,
            currentThreshold: currentBorderline
        )
        let trailing = computeTrailingCeilingOffset(
            frames: curatedFrames,
            currentCeiling: currentTrailingCeiling
        )

        // Need at least the borderline result — trailing is optional.
        guard let bl = borderline else { return nil }

        return LearnedThresholds(
            borderlineOffset: bl.offset,
            trailingCeilingOffset: trailing?.offset ?? 0.0,
            sampleCount: bl.sampleCount,
            lastComputed: Date(),
            fpRate: bl.fpRate,
            fnRate: bl.fnRate,
            cost: bl.cost
        )
    }

    // MARK: - Borderline z-score offset

    private struct GridResult {
        let offset: Double
        let sampleCount: Int
        let cost: Double
        let fpRate: Double
        let fnRate: Double
    }

    private static func computeBorderlineOffset(
        frames: [FrameRecord],
        currentThreshold: Double
    ) -> GridResult? {
        // Only learn from frames where the curator's rating is meaningful —
        // exclude non-learnable garbage reasons and missing z-scores.
        let candidates = frames.filter { record in
            guard let _ = record.combinedZScore else { return false }
            guard record.userConfidence >= 1, record.userConfidence <= 3 else { return false }
            return !hasNonLearnableReason(record)
        }

        guard candidates.count >= minBorderlineSamples else { return nil }
        let oneStar = candidates.filter { $0.userConfidence == 1 }.count
        let threeStar = candidates.filter { $0.userConfidence == 3 }.count
        guard oneStar >= minBorderlineSamplesPerClass,
              threeStar >= minBorderlineSamplesPerClass else { return nil }

        return gridSearch(
            range: borderlineOffsetRange,
            step: borderlineOffsetStep,
            sampleCount: candidates.count,
            costForOffset: { offset in
                let threshold = currentThreshold + offset
                var fp = 0
                var fn = 0
                for record in candidates {
                    guard let z = record.combinedZScore else { continue }
                    let wouldBeTrash = z < threshold
                    // FP: would-be-trash but user gave ≥2★ ("worth keeping")
                    // FN: NOT-would-be-trash but user gave 1★ ("garbage")
                    if wouldBeTrash && record.userConfidence >= 2 { fp += 1 }
                    if !wouldBeTrash && record.userConfidence == 1 { fn += 1 }
                }
                return (fp: fp, fn: fn)
            }
        )
    }

    // MARK: - Trailing ceiling offset

    private static func computeTrailingCeilingOffset(
        frames: [FrameRecord],
        currentCeiling: Double
    ) -> GridResult? {
        // Population: anything where trailing is the relevant signal —
        // either the algorithm already flagged it for trailing, OR the
        // trailing score is near the ceiling boundary and the user rated it.
        let candidates = frames.filter { record in
            guard record.userConfidence >= 1, record.userConfidence <= 3 else { return false }
            guard !hasNonLearnableReason(record) else { return false }
            if hasTrailingReason(record) { return true }
            if let ts = record.trailingScore, ts > 0.3 { return true }
            return false
        }

        guard candidates.count >= minTrailingSamples else { return nil }

        return gridSearch(
            range: trailingOffsetRange,
            step: trailingOffsetStep,
            sampleCount: candidates.count,
            costForOffset: { offset in
                let ceiling = currentCeiling + offset
                var fp = 0
                var fn = 0
                for record in candidates {
                    guard let ts = record.trailingScore else { continue }
                    let wouldBeFlagged = ts > ceiling
                    if wouldBeFlagged && record.userConfidence >= 2 { fp += 1 }
                    if !wouldBeFlagged && record.userConfidence == 1 { fn += 1 }
                }
                return (fp: fp, fn: fn)
            }
        )
    }

    // MARK: - Grid search core

    private static func gridSearch(
        range: ClosedRange<Double>,
        step: Double,
        sampleCount: Int,
        costForOffset: (Double) -> (fp: Int, fn: Int)
    ) -> GridResult? {
        var best: GridResult?

        for offset in stride(from: range.lowerBound, through: range.upperBound, by: step) {
            // Floating-point step accumulates rounding noise; snap to step grid
            // so 0.1 + 0.1 + ... actually equals 0.0 etc.
            let snapped = (offset / step).rounded() * step
            let (fp, fn) = costForOffset(snapped)
            let cost = Double(fp) * costFalsePositive + Double(fn) * costFalseNegative
            let candidate = GridResult(
                offset: snapped,
                sampleCount: sampleCount,
                cost: cost,
                fpRate: Double(fp) / Double(sampleCount),
                fnRate: Double(fn) / Double(sampleCount)
            )

            if let current = best {
                // Lower cost wins; ties favor the offset closer to zero
                // (regularization — don't drift from defaults without evidence).
                if cost < current.cost {
                    best = candidate
                } else if cost == current.cost && Swift.abs(snapped) < Swift.abs(current.offset) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }

    // MARK: - GarbageReason inspection

    /// FrameRecord persists garbageReasons as a JSON-encoded array of
    /// `GarbageReason.rawValue` strings; check whether any of them is in the
    /// non-learnable set.
    private static func hasNonLearnableReason(_ record: FrameRecord) -> Bool {
        for reason in decodeReasons(record.garbageReasons) where nonLearnableReasons.contains(reason) {
            return true
        }
        return false
    }

    private static func hasTrailingReason(_ record: FrameRecord) -> Bool {
        let trailingReasons: Set<String> = [
            GarbageReason.elongated.rawValue,
            GarbageReason.trackingHop.rawValue,
        ]
        for reason in decodeReasons(record.garbageReasons) where trailingReasons.contains(reason) {
            return true
        }
        return false
    }

    private static func decodeReasons(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
