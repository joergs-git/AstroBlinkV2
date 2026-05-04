// v4.3.0 — Per-Setup Calibration Database
//
// Learns from user actions to build per-setup quality baselines.
// Uses Welford's online algorithm for incremental mean/variance/MAD
// without storing all historical values — O(1) per update, O(1) lookup.
//
// Persistence: JSON files in ~/Library/Application Support/AstroBlinkV2/Calibration/
// One file per setup hash (telescope+camera+focalLength+pixelSize).
//
// Designed for future Supabase integration: fingerprint.hash is anonymized,
// hardware names stay local, no filenames/paths/user identity uploaded.

import Foundation
import CryptoKit

// MARK: - Setup Fingerprint

/// Uniquely identifies an imaging setup by its hardware configuration.
/// The hash is anonymized (SHA256) and safe for remote upload.
/// Hardware names are kept locally for the UI but never transmitted.
struct SetupFingerprint: Codable, Hashable {
    let hash: String            // SHA256 of normalized hardware string
    let telescope: String       // Local-only: human-readable telescope name
    let camera: String          // Local-only: human-readable camera name
    let focalLength: Int        // Rounded to nearest mm
    let pixelSizeMicrons: Int   // Rounded to nearest micron ×10 (e.g. 3.76µm → 38)

    init(telescope: String?, camera: String?, focalLength: Double?, pixelSizeMicrons: Double?) {
        let tel = (telescope ?? "unknown").trimmingCharacters(in: .whitespaces).lowercased()
        let cam = (camera ?? "unknown").trimmingCharacters(in: .whitespaces).lowercased()
        let fl = focalLength.map { Int($0.rounded()) } ?? 0
        let px = pixelSizeMicrons.map { Int(($0 * 10).rounded()) } ?? 0

        self.telescope = telescope ?? "Unknown"
        self.camera = camera ?? "Unknown"
        self.focalLength = fl
        self.pixelSizeMicrons = px

        // SHA256 of normalized string for anonymized remote use
        let raw = "\(tel)|\(cam)|\(fl)|\(px)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        self.hash = digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Welford Online Statistics

/// Incremental mean/variance using Welford's online algorithm.
/// Allows computing statistics over thousands of frames without storing any values.
struct MetricBaseline: Codable, Hashable {
    var count: Int = 0
    var mean: Double = 0
    var m2: Double = 0              // Running sum of squared deviations
    var runningMAD: Double = 0      // Exponential moving average of |x - mean| (approximates MAD)

    var variance: Double {
        count < 2 ? 0 : m2 / Double(count)
    }

    var stdDev: Double {
        variance.squareRoot()
    }

    /// Update with a new observation using Welford's algorithm
    mutating func update(value: Double) {
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        let delta2 = value - mean
        m2 += delta * delta2

        // Exponential moving average of absolute deviation (approximates MAD)
        // Alpha = 0.05 gives smooth convergence after ~20 samples
        let alpha = count < 20 ? 1.0 / Double(count) : 0.05
        runningMAD += alpha * (Swift.abs(value - mean) - runningMAD)
    }

    /// Check if a value is within N MADs of the mean (for absolute quality floor)
    func isWithinMAD(_ value: Double, multiplier: Double = 1.0) -> Bool {
        guard count >= 30, runningMAD > 0 else { return false }
        return Swift.abs(value - mean) <= runningMAD * multiplier
    }
}

// MARK: - Per-Filter/Exposure Baseline

/// Per-group (filter+exposure) learned baselines for quality metrics.
struct FilterExposureBaseline: Codable, Hashable {
    var fwhm: MetricBaseline = MetricBaseline()
    var hfr: MetricBaseline = MetricBaseline()
    var starCount: MetricBaseline = MetricBaseline()
    var noise: MetricBaseline = MetricBaseline()
    var trailingScore: MetricBaseline = MetricBaseline()
    var snr: MetricBaseline = MetricBaseline()
    var framesAnalyzed: Int = 0
}

// MARK: - Learned Thresholds (Phase 2 — curation-driven)

/// Per-setup soft adjustments to QualityEstimator's tier cutoffs, learned
/// from the user's curated star ratings via grid search (see
/// ThresholdLearner.computeLearnedThresholds). Hard Stage 1 backstops are
/// untouched — only the borderline z-score and the absolute trailing
/// ceiling shift. Activates once `sampleCount >= learningThreshold`.
struct LearnedThresholds: Codable, Hashable {
    /// Added to QualityEstimator.thresholdBorderline (-2.0).
    /// Negative = stricter (more frames slip into trash);
    /// positive = more lenient (rescues z-score-only trash).
    /// Clamped to ±0.8 by the learner.
    var borderlineOffset: Double = 0.0

    /// Added to QualityEstimator.absoluteTrailingCeilingScore (0.60).
    /// Negative = stricter ceiling, positive = more lenient.
    /// Clamped to [-0.15, +0.20] by the learner.
    var trailingCeilingOffset: Double = 0.0

    /// Number of curated frames the offsets were derived from.
    var sampleCount: Int = 0
    var lastComputed: Date?

    // Diagnostics from the grid search at last compute.
    var fpRate: Double?
    var fnRate: Double?
    var cost: Double?

    /// Minimum sample count before learned offsets apply.
    static let learningThreshold = 50
}

// MARK: - Calibration Profile

/// Complete per-setup calibration profile. Codable for JSON persistence,
/// anonymizable for Supabase upload.
struct CalibrationProfile: Codable {
    let fingerprint: SetupFingerprint
    var filterBaselines: [String: FilterExposureBaseline]  // Key: "FILTER|EXPOSURE"
    var totalSessionsAnalyzed: Int
    var totalFramesAnalyzed: Int
    var globalFWHM: MetricBaseline       // Aggregated across all filters
    var globalTrailing: MetricBaseline
    var algorithmFlagged: Int            // Frames algorithm marked as trash
    var userOverrodeKeep: Int            // Frames user unmarked (algorithm was wrong)
    // Explicit quality feedback counters (from 'A' key cycling)
    var userAgreed: Int
    var userDisagreed: Int
    var userPartlyAgreed: Int
    /// Phase 2 — soft tier-cutoff adjustments learned from curated ratings.
    /// nil until `ThresholdLearner.computeLearnedThresholds` finds enough
    /// data; nil and `sampleCount < LearnedThresholds.learningThreshold`
    /// both fall back to QualityEstimator's static defaults.
    var learnedThresholds: LearnedThresholds?
    var createdAt: Date
    var lastUpdated: Date

    /// Agreement rate: how often user agrees with algorithm (mark/unmark based)
    var agreementRate: Double {
        let total = algorithmFlagged + userOverrodeKeep
        guard total > 0 else { return 1.0 }
        return Double(algorithmFlagged) / Double(total)
    }

    /// Feedback-based agreement rate (from explicit user feedback via A key).
    /// Returns nil if fewer than 5 feedback entries exist.
    var feedbackAgreementRate: Double? {
        let total = userAgreed + userDisagreed + userPartlyAgreed
        guard total >= 5 else { return nil }
        // Partly counts as 0.5 agreement
        return Double(userAgreed) + Double(userPartlyAgreed) * 0.5 / Double(total)
    }

    /// Minimum frames before applying absolute quality floor
    static let learningThreshold = 30

    /// Whether this profile has enough data for absolute quality floor
    var hasLearned: Bool {
        totalFramesAnalyzed >= Self.learningThreshold
    }

    init(fingerprint: SetupFingerprint) {
        self.fingerprint = fingerprint
        self.filterBaselines = [:]
        self.totalSessionsAnalyzed = 0
        self.totalFramesAnalyzed = 0
        self.globalFWHM = MetricBaseline()
        self.globalTrailing = MetricBaseline()
        self.algorithmFlagged = 0
        self.userOverrodeKeep = 0
        self.userAgreed = 0
        self.userDisagreed = 0
        self.userPartlyAgreed = 0
        self.learnedThresholds = nil
        self.createdAt = Date()
        self.lastUpdated = Date()
    }

    // Custom decoder for backward compatibility — old JSON files lack feedback counters
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try container.decode(SetupFingerprint.self, forKey: .fingerprint)
        filterBaselines = try container.decode([String: FilterExposureBaseline].self, forKey: .filterBaselines)
        totalSessionsAnalyzed = try container.decode(Int.self, forKey: .totalSessionsAnalyzed)
        totalFramesAnalyzed = try container.decode(Int.self, forKey: .totalFramesAnalyzed)
        globalFWHM = try container.decode(MetricBaseline.self, forKey: .globalFWHM)
        globalTrailing = try container.decode(MetricBaseline.self, forKey: .globalTrailing)
        algorithmFlagged = try container.decode(Int.self, forKey: .algorithmFlagged)
        userOverrodeKeep = try container.decode(Int.self, forKey: .userOverrodeKeep)
        userAgreed = try container.decodeIfPresent(Int.self, forKey: .userAgreed) ?? 0
        userDisagreed = try container.decodeIfPresent(Int.self, forKey: .userDisagreed) ?? 0
        userPartlyAgreed = try container.decodeIfPresent(Int.self, forKey: .userPartlyAgreed) ?? 0
        learnedThresholds = try container.decodeIfPresent(LearnedThresholds.self, forKey: .learnedThresholds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
    }

    /// Get baseline for a filter+exposure group (returns empty if not learned yet)
    func baseline(filter: String, exposure: Int) -> FilterExposureBaseline {
        let key = Self.groupKey(filter: filter, exposure: exposure)
        return filterBaselines[key] ?? FilterExposureBaseline()
    }

    /// Update baseline for a filter+exposure group
    mutating func updateBaseline(_ baseline: FilterExposureBaseline, filter: String, exposure: Int) {
        let key = Self.groupKey(filter: filter, exposure: exposure)
        filterBaselines[key] = baseline
    }

    static func groupKey(filter: String, exposure: Int) -> String {
        let f = filter.uppercased().trimmingCharacters(in: .whitespaces)
        return "\(f.isEmpty ? "ALL" : f)|\(exposure)"
    }
}

// MARK: - Calibration Database

/// Singleton database that persists per-setup calibration profiles.
/// Only accessed from main thread via TriageViewModel (no concurrent access).
final class CalibrationDatabase {

    static let shared = CalibrationDatabase()

    /// In-memory cache of profiles keyed by setup hash
    private var profiles: [String: CalibrationProfile] = [:]

    /// Directory for JSON persistence (local)
    private let storageDirectory: URL
    /// iCloud directory for cross-device sync (nil if iCloud unavailable)
    private let iCloudDirectory: URL?

    private init() {
        // Local: ~/Library/Containers/.../Application Support/AstroBlinkV2/Calibration/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDirectory = appSupport.appendingPathComponent("AstroBlinkV2/Calibration", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        // iCloud: syncs calibration data across devices
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.joergsflow.AstroBlinkV2") {
            let dir = container.appendingPathComponent("Documents/Calibration", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            iCloudDirectory = dir
        } else {
            iCloudDirectory = nil
        }

        // Load profiles from both locations (iCloud takes precedence for newer data)
        loadAllProfiles()
    }

    // MARK: - Public API

    /// Get profile for a setup, creating one if it doesn't exist
    func profile(for fingerprint: SetupFingerprint) -> CalibrationProfile {
        if let existing = profiles[fingerprint.hash] {
            return existing
        }
        let new = CalibrationProfile(fingerprint: fingerprint)
        profiles[fingerprint.hash] = new
        return new
    }

    /// Record a user action (mark/unmark) for learning.
    /// Called on every togglePreDelete.
    func recordAction(entry: ImageEntry, wasMarked: Bool, fingerprint: SetupFingerprint) {
        var prof = profile(for: fingerprint)

        // Track algorithm agreement: if the algorithm flagged it as trash
        // and the user unmarked it, that's an override
        if let tier = entry.qualityTier {
            if tier == .trash && !wasMarked {
                // User unmarked a trash frame → algorithm was wrong
                prof.userOverrodeKeep += 1
            } else if tier == .trash && wasMarked {
                // User confirmed algorithm's trash assessment
                prof.algorithmFlagged += 1
            }
        }

        prof.lastUpdated = Date()
        profiles[fingerprint.hash] = prof
        save(profile: prof)
    }

    /// Record explicit quality feedback (agree/disagree/partly) from user.
    /// Called when user presses 'A' key or uses context menu.
    func recordFeedback(entry: ImageEntry, feedback: QualityFeedback, fingerprint: SetupFingerprint) {
        guard feedback != .none else { return }
        var prof = profile(for: fingerprint)

        switch feedback {
        case .agree:
            prof.userAgreed += 1
        case .disagree:
            prof.userDisagreed += 1
            // Disagree is a strong signal — also count as override when algorithm flagged trash
            if entry.qualityTier == .trash {
                prof.userOverrodeKeep += 1
            }
        case .partly:
            prof.userPartlyAgreed += 1
        case .none:
            break
        }

        prof.lastUpdated = Date()
        profiles[fingerprint.hash] = prof
        save(profile: prof)
    }

    /// Commit a session's metrics to the calibration database.
    /// Called after PRE-DELETE confirmation to learn from the accepted set.
    /// Only learns from RETAINED frames (not marked for deletion) — these represent
    /// the user's quality standard for this setup.
    func commitSession(entries: [ImageEntry], fingerprint: SetupFingerprint) {
        var prof = profile(for: fingerprint)

        let retained = entries.filter { !$0.isMarkedForDeletion }
        guard !retained.isEmpty else { return }

        for entry in retained {
            let filter = (entry.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
            let exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
            var baseline = prof.baseline(filter: filter, exposure: exposure)

            // Update per-metric baselines with Welford's algorithm
            if let fwhm = entry.displayFWHM {
                baseline.fwhm.update(value: fwhm)
                prof.globalFWHM.update(value: fwhm)
            }
            if let hfr = entry.displayHFR {
                baseline.hfr.update(value: hfr)
            }
            if let stars = entry.displayStarCount {
                baseline.starCount.update(value: Double(stars))
            }
            if let median = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 {
                baseline.noise.update(value: Double(mad))
                baseline.snr.update(value: Double(median) / Double(mad))
            }
            if let ts = entry.trailingScore {
                baseline.trailingScore.update(value: ts)
                prof.globalTrailing.update(value: ts)
            }

            baseline.framesAnalyzed += 1
            prof.updateBaseline(baseline, filter: filter, exposure: exposure)
        }

        prof.totalSessionsAnalyzed += 1
        prof.totalFramesAnalyzed += retained.count
        prof.lastUpdated = Date()
        profiles[fingerprint.hash] = prof
        save(profile: prof)
    }

    /// Check if a frame meets the absolute quality floor for its setup.
    /// Returns true if ALL available metrics are within 1 MAD of the learned median.
    /// Only applies when the setup has enough learned data (≥30 frames).
    func meetsAbsoluteFloor(entry: ImageEntry, fingerprint: SetupFingerprint) -> Bool {
        let prof = profile(for: fingerprint)
        guard prof.hasLearned else { return false }

        let filter = (entry.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        let exposure = entry.exposure.map { Int($0.rounded()) } ?? 0
        let baseline = prof.baseline(filter: filter, exposure: exposure)

        // Need at least the filter-group to have learned data
        guard baseline.framesAnalyzed >= CalibrationProfile.learningThreshold else { return false }

        // Check each available metric — ALL must be within 1 MAD
        var checksPerformed = 0
        var checksPassed = 0

        if let fwhm = entry.displayFWHM, baseline.fwhm.count >= CalibrationProfile.learningThreshold {
            checksPerformed += 1
            if baseline.fwhm.isWithinMAD(fwhm) { checksPassed += 1 }
        }
        if let hfr = entry.displayHFR, baseline.hfr.count >= CalibrationProfile.learningThreshold {
            checksPerformed += 1
            if baseline.hfr.isWithinMAD(hfr) { checksPassed += 1 }
        }
        if let stars = entry.displayStarCount, baseline.starCount.count >= CalibrationProfile.learningThreshold {
            checksPerformed += 1
            if baseline.starCount.isWithinMAD(Double(stars)) { checksPassed += 1 }
        }
        if let ts = entry.trailingScore, baseline.trailingScore.count >= CalibrationProfile.learningThreshold {
            checksPerformed += 1
            if baseline.trailingScore.isWithinMAD(ts) { checksPassed += 1 }
        }

        // Must have checked at least 2 metrics and ALL must pass
        return checksPerformed >= 2 && checksPassed == checksPerformed
    }

    /// Learning progress string for tooltips (e.g. "Learning... (15/30 frames)")
    func learningStatus(for fingerprint: SetupFingerprint) -> String {
        let prof = profile(for: fingerprint)
        if prof.hasLearned {
            return "Calibrated (\(prof.totalFramesAnalyzed) frames across \(prof.totalSessionsAnalyzed) session\(prof.totalSessionsAnalyzed == 1 ? "" : "s"))"
        }
        return "Learning... (\(prof.totalFramesAnalyzed)/\(CalibrationProfile.learningThreshold) frames)"
    }

    /// Phase 2 — store curation-driven threshold offsets for a setup. Pulled
    /// from `ThresholdLearner.computeLearnedThresholds`; called after every
    /// commitSession() once enough curated data is available.
    func updateLearnedThresholds(_ thresholds: LearnedThresholds, for fingerprint: SetupFingerprint) {
        var profile = profiles[fingerprint.hash] ?? CalibrationProfile(fingerprint: fingerprint)
        profile.learnedThresholds = thresholds
        profile.lastUpdated = Date()
        profiles[fingerprint.hash] = profile
        save(profile: profile)
    }

    // MARK: - Persistence

    private func save(profile: CalibrationProfile) {
        let filename = "\(profile.fingerprint.hash).json"
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            // Local (instant backup)
            try data.write(to: storageDirectory.appendingPathComponent(filename), options: .atomic)
            // iCloud (cross-device sync)
            if let icloudDir = iCloudDirectory {
                try data.write(to: icloudDir.appendingPathComponent(filename), options: .atomic)
            }
        } catch {
            print("CalibrationDatabase: failed to save profile \(profile.fingerprint.hash): \(error)")
        }
    }

    private func loadAllProfiles() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Load from local first
        loadProfiles(from: storageDirectory, decoder: decoder)
        // Then merge iCloud (more frames = newer data wins)
        if let icloudDir = iCloudDirectory {
            loadProfiles(from: icloudDir, decoder: decoder)
        }
    }

    private func loadProfiles(from directory: URL, decoder: JSONDecoder) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let profile = try decoder.decode(CalibrationProfile.self, from: data)
                // Keep the version with more data (more frames analyzed = more learning)
                if let existing = profiles[profile.fingerprint.hash] {
                    if profile.totalFramesAnalyzed > existing.totalFramesAnalyzed {
                        profiles[profile.fingerprint.hash] = profile
                    }
                } else {
                    profiles[profile.fingerprint.hash] = profile
                }
            } catch {
                print("CalibrationDatabase: failed to load \(file.lastPathComponent): \(error)")
            }
        }
    }
}
