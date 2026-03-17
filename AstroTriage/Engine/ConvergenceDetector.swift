// v4.3.0 — Convergence Detection & Stack Readiness
//
// Prevents the "death spiral" where repeated culling removes all frames.
// Stateless struct (like QualityEstimator) — pure functions, no side effects.
//
// Three components:
// 1. Quality spread: std dev of z-scores per group — when < 0.3, culling is complete
// 2. SNR stopping: flags when SNR loss % > integration loss %
// 3. Stack readiness: 0-100% composite score combining uniformity + SNR + floor coverage

import Foundation

// Result of convergence analysis for the current session state
struct ConvergenceResult {
    let isConverged: Bool               // Quality spread < threshold
    let qualitySpread: Double           // Std dev of z-scores among retained frames
    let readinessPercent: Double        // 0-100% composite score
    let readinessLabel: String          // Human-readable status
    let snrStopReached: Bool            // SNR loss % > integration loss %
    let message: String?                // Alert message for the user (nil = no alert)
}

enum ConvergenceDetector {

    // Quality spread threshold: below this, all remaining frames are similar quality
    static let convergenceSpread: Double = 0.3

    // Readiness thresholds
    static let readinessGreen: Double = 95.0
    static let readinessYellow: Double = 80.0
    static let readinessOrange: Double = 60.0

    /// Analyze convergence state of the current session.
    ///
    /// - Parameters:
    ///   - entries: All images in the session (including marked ones)
    ///   - snrRetention: Current SNR retention percentage (from TriageViewModel)
    ///   - calibrationDB: Calibration database for absolute floor checks
    ///   - fingerprint: Current setup fingerprint (nil if not available)
    static func analyze(
        entries: [ImageEntry],
        snrRetention: Double,
        calibrationDB: CalibrationDatabase,
        fingerprint: SetupFingerprint?
    ) -> ConvergenceResult {
        let retained = entries.filter { !$0.isMarkedForDeletion }
        let marked = entries.filter { $0.isMarkedForDeletion }

        guard !retained.isEmpty else {
            return ConvergenceResult(
                isConverged: false, qualitySpread: 0, readinessPercent: 0,
                readinessLabel: "No frames", snrStopReached: false, message: nil
            )
        }

        // 1. Quality spread: std dev of z-scores among retained frames
        let zScores = retained.compactMap { $0.qualityZScore }
        let spread = standardDeviation(zScores)

        let isConverged = zScores.count >= 5 && spread < convergenceSpread

        // 2. SNR stopping criterion
        let totalExposure = entries.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
        let markedExposure = marked.reduce(0.0) { $0 + ($1.exposure ?? 0.0) }
        let integrationLossPercent = totalExposure > 0 ? (markedExposure / totalExposure) * 100.0 : 0
        let snrLossPercent = 100.0 - snrRetention
        let snrStopReached = snrLossPercent > integrationLossPercent && marked.count > 0

        // 3. Stack readiness: composite score
        //    40% uniformity (quality spread → 100% when spread < 0.3)
        //    35% SNR retention (100% = nothing lost)
        //    25% absolute floor coverage (% of retained frames meeting calibration floor)
        let uniformityScore = max(0, min(100, (1.0 - spread / 1.0) * 100.0))

        var floorCoverage: Double = 100.0  // Default 100% when no calibration available
        if let fp = fingerprint, calibrationDB.profile(for: fp).hasLearned {
            let meetFloor = retained.filter { calibrationDB.meetsAbsoluteFloor(entry: $0, fingerprint: fp) }.count
            floorCoverage = retained.isEmpty ? 100.0 : Double(meetFloor) / Double(retained.count) * 100.0
        }

        let readiness = uniformityScore * 0.40 + snrRetention * 0.35 + floorCoverage * 0.25

        // Readiness label
        let readinessLabel: String
        if readiness >= readinessGreen {
            readinessLabel = "Ready for WBPP"
        } else if readiness >= readinessYellow {
            readinessLabel = "Nearly ready"
        } else if readiness >= readinessOrange {
            readinessLabel = "More culling needed"
        } else {
            readinessLabel = "Review quality"
        }

        // Convergence message
        var message: String? = nil
        if isConverged {
            message = "Culling complete — remaining frames are uniform quality (spread: \(String(format: "%.2f", spread)))"
        } else if snrStopReached {
            message = "SNR stop: losing \(String(format: "%.1f", snrLossPercent))% SNR vs \(String(format: "%.0f", integrationLossPercent))% integration — consider keeping remaining frames"
        }

        return ConvergenceResult(
            isConverged: isConverged,
            qualitySpread: spread,
            readinessPercent: readiness,
            readinessLabel: readinessLabel,
            snrStopReached: snrStopReached,
            message: message
        )
    }

    // MARK: - Helpers

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }
}
