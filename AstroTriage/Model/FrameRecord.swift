import Foundation
import GRDB

// MARK: - Algorithm Version

/// Current algorithm version for quality scoring and star metrics.
/// Bump this whenever scoring logic, detection algorithms, or metric calculations change.
/// Records in the Frame History DB with older versions can be identified for re-analysis.
///
/// IMPORTANT: When bumping this version, you MUST also update ALGORITHM_CHANGELOG.md
/// with a detailed entry describing what changed and why.
///
/// See: ALGORITHM_CHANGELOG.md for full version history.
let kAlgorithmVersion = 32

// MARK: - FrameRecord

/// Persistent per-frame quality record for the Frame History Database.
/// Maps 1:1 to the `frame_record` SQLite table via GRDB.
/// Primary key is fileHash (SHA256 of first 64KB) — UPSERT semantics ensure no duplicates.
struct FrameRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "frame_record"

    // Identity
    var fileHash: String           // SHA256 of first 64KB — PRIMARY KEY
    var shortId: String            // Human-readable ID e.g. "A3-2917"
    var filename: String
    var filePath: String
    var observingNight: String?
    var captureDate: String?
    var captureTime: String?
    var sessionId: String

    // Equipment
    var telescope: String?
    var camera: String?
    var focalLength: Double?
    var pixelSizeMicrons: Double?
    var setupHash: String?

    // Capture parameters
    var target: String?
    var filter: String?
    var exposure: Double?
    var gain: Int?
    var offsetVal: Int?
    var binning: String?
    var pierSide: String?
    var rotatorAngle: Double?
    var mount: String?

    // Quality metrics (computed from image data)
    var computedFWHM: Double?
    var computedHFR: Double?
    var computedStarCount: Int?
    var computedEccentricity: Double?
    var noiseMedian: Double?        // Float → Double for DB storage
    var noiseMAD: Double?
    var psfFlux: Double?            // Total PSF flux (Σ 2π·A·σ² per star, scaled to full image)

    // Trailing analysis
    var trailingScore: Double?
    var trailingPA: Double?
    var trailingConsensus: Double?
    var trailingAxisRatio: Double?
    var starChainFraction: Double?

    // Environment
    var sensorTemp: Double?
    var focuserTemp: Double?
    var ambientTemp: Double?
    var twilightPhase: String?      // TwilightPhase.rawValue

    // Moon data (computed from date + location)
    var moonIllumination: Double?   // 0.0 = new moon, 1.0 = full moon
    var moonDistance: Double?       // Degrees from target

    // Results
    var qualityTier: Int?           // QualityTier.rawValue (0-4)
    var combinedZScore: Double?
    var garbageReasons: String?     // JSON array of strings
    var isLockedKeep: Int           // 0 or 1
    var filterTrailingMultiplier: Double?

    // Light pollution + target clustering
    var bortleClass: Double?        // Bortle 1.0-9.0 fractional from BortleEstimator
    var canonicalTarget: String?    // Normalized target name for grouping
    var majorTarget: String?        // Parent target for sub-targets (e.g., "IC1805" for "MEL15")

    var userConfidence: Int          // 0 = unrated, 1-3 = star rating
    var qualityFeedback: Int        // 0=none, 1=agree, 2=disagree, 3=partly (QualityFeedback.rawValue)
    var wasDeleted: Int             // 0 or 1

    // Meta
    var algorithmVersion: Int
    var recordedAt: String          // ISO 8601
    var width: Int?
    var height: Int?

    // MARK: - GRDB Persistence

    /// Use INSERT OR REPLACE (UPSERT) — fileHash is the primary key
    func willInsert(_ db: Database) throws {
        // No-op, just using default INSERT OR REPLACE via save()
    }

    /// Persist using INSERT OR REPLACE semantics
    static let persistenceConflictPolicy = PersistenceConflictPolicy(
        insert: .replace,
        update: .replace
    )
}

// MARK: - Factory

extension FrameRecord {

    /// Build a FrameRecord from an ImageEntry and session context.
    static func from(
        entry: ImageEntry,
        fileHash: String,
        sessionId: String,
        setupHash: String?
    ) -> FrameRecord {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // Compute short ID from file hash: first 2 hex chars uppercase + 4-digit number
        let shortId = ImageEntry.computeShortId(from: fileHash)

        // Encode garbage reasons as JSON array
        var garbageJSON: String?
        if let reasons = entry.qualityBreakdown?.garbageReasons, !reasons.isEmpty {
            let reasonStrings = reasons.map { $0.rawValue }
            if let data = try? JSONEncoder().encode(reasonStrings) {
                garbageJSON = String(data: data, encoding: .utf8)
            }
        }

        return FrameRecord(
            fileHash: fileHash,
            shortId: shortId,
            filename: entry.filename,
            filePath: entry.url.path,
            observingNight: entry.observingNight,
            captureDate: entry.date,
            captureTime: entry.time,
            sessionId: sessionId,
            telescope: entry.telescope,
            camera: entry.camera,
            focalLength: entry.focalLength,
            pixelSizeMicrons: entry.pixelSizeMicrons,
            setupHash: setupHash,
            target: entry.target,
            filter: entry.filter,
            exposure: entry.exposure,
            gain: entry.gain,
            offsetVal: entry.offset,
            binning: entry.binning,
            pierSide: entry.pierSide,
            rotatorAngle: entry.rotatorAngle,
            mount: entry.mount,
            computedFWHM: entry.computedFWHM,
            computedHFR: entry.computedHFR,
            computedStarCount: entry.computedStarCount,
            computedEccentricity: entry.computedEccentricity,
            noiseMedian: entry.noiseMedian.map(Double.init),
            noiseMAD: entry.noiseMAD.map(Double.init),
            psfFlux: entry.psfFluxSum,
            trailingScore: entry.trailingScore,
            trailingPA: entry.trailingPA,
            trailingConsensus: entry.trailingConsensus,
            trailingAxisRatio: entry.trailingAxisRatio,
            starChainFraction: entry.starChainFraction,
            sensorTemp: entry.sensorTemp,
            focuserTemp: entry.focuserTemp,
            ambientTemp: entry.ambientTemp,
            twilightPhase: entry.twilightPhase?.rawValue,
            moonIllumination: entry.moonIllumination,
            moonDistance: entry.moonDistance,
            qualityTier: entry.qualityTier?.rawValue,
            combinedZScore: entry.qualityZScore,
            garbageReasons: garbageJSON,
            isLockedKeep: (entry.qualityBreakdown?.isLockedKeep ?? false) ? 1 : 0,
            filterTrailingMultiplier: entry.qualityBreakdown?.filterTrailingMultiplier,
            bortleClass: entry.bortleClass,
            canonicalTarget: entry.canonicalTarget,
            majorTarget: entry.majorTarget,
            userConfidence: entry.userConfidence,
            qualityFeedback: entry.qualityFeedback.rawValue,
            wasDeleted: entry.isMarkedForDeletion ? 1 : 0,
            algorithmVersion: kAlgorithmVersion,
            recordedAt: iso.string(from: Date()),
            width: entry.width,
            height: entry.height
        )
    }

    // Short ID computation delegated to ImageEntry.computeShortId(from:)
}

// MARK: - SessionRecord

/// Persistent per-session summary record.
struct SessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_record"

    var id: String                  // UUID string
    var sessionPath: String
    var observingNight: String?
    var setupHash: String?
    var telescope: String?
    var camera: String?
    var target: String?
    var frameCount: Int
    var trashCount: Int
    var deletedCount: Int
    var recordedAt: String          // ISO 8601

    static let persistenceConflictPolicy = PersistenceConflictPolicy(
        insert: .replace,
        update: .replace
    )
}

// MARK: - ScanProgress (for Archive Scanner)

/// Tracks progress of background archive scans for crash-safe resume.
struct ScanProgress: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scan_progress"

    var rootPath: String            // PRIMARY KEY
    var lastScannedPath: String?
    var totalFound: Int
    var totalProcessed: Int
    var startedAt: String           // ISO 8601
    var lastUpdatedAt: String       // ISO 8601
    var isComplete: Int             // 0 or 1

    static let persistenceConflictPolicy = PersistenceConflictPolicy(
        insert: .replace,
        update: .replace
    )
}

// MARK: - Query Result Types

/// Nightly quality summary for charts.
struct NightSummary: Identifiable {
    let id = UUID()
    let night: String               // "YYYY-MM-DD"
    let target: String?
    let filter: String?
    let frameCount: Int
    let trashCount: Int
    let goodCount: Int
    let excellentCount: Int
    let borderlineCount: Int
    let medianFWHM: Double?
    let medianHFR: Double?
    let medianStarCount: Double?
    let medianNoise: Double?
    let medianTrailing: Double?
    let medianMoonIllumination: Double?
    let medianMoonDistance: Double?
    let medianExposure: Double?     // Seconds per sub (for integration time calculation)
    let medianAmbientTemp: Double?  // Ambient temperature (°C)
    let medianBortle: Double?       // Bortle sky quality (1-9)
}

/// Aggregate setup history for AIsaac context.
struct SetupHistorySummary {
    let totalFrames: Int
    let sessionCount: Int
    let firstNight: String?
    let lastNight: String?
    let medianFWHM: Double
    let medianStarCount: Double
    let medianNoise: Double
    let medianTrailing: Double
    let trashRate: Double           // Fraction of frames scored as trash
    let targets: [String]           // Distinct targets imaged with this setup
}

/// Historical baselines for cross-session quality scoring (Phase 2).
struct HistoricalBaselines {
    struct GroupBaseline {
        let fwhmMedian: Double
        let fwhmMAD: Double
        let hfrMedian: Double
        let hfrMAD: Double
        let starCountMedian: Double
        let starCountMAD: Double
        let noiseMedian: Double
        let noiseMAD: Double
        let trailingMedian: Double
        let trailingMAD: Double
        let frameCount: Int
    }

    var baselines: [String: GroupBaseline]  // Key: "FILTER|EXPOSURE"

    /// Build baselines from historical frame records.
    static func build(from records: [FrameRecord]) -> HistoricalBaselines {
        var groups: [String: [FrameRecord]] = [:]
        for record in records {
            let filter = (record.filter ?? "").uppercased()
            let exposure = record.exposure.map { Int($0.rounded()) } ?? 0
            let key = "\(filter)|\(exposure)"
            groups[key, default: []].append(record)
        }

        var baselines: [String: GroupBaseline] = [:]
        for (key, frames) in groups {
            guard frames.count >= 5 else { continue }

            let fwhms = frames.compactMap(\.computedFWHM).sorted()
            let hfrs = frames.compactMap(\.computedHFR).sorted()
            let stars = frames.compactMap(\.computedStarCount).map(Double.init).sorted()
            let noises = frames.compactMap(\.noiseMAD).sorted()
            let trails = frames.compactMap(\.trailingScore).sorted()

            baselines[key] = GroupBaseline(
                fwhmMedian: median(fwhms),
                fwhmMAD: mad(fwhms),
                hfrMedian: median(hfrs),
                hfrMAD: mad(hfrs),
                starCountMedian: median(stars),
                starCountMAD: mad(stars),
                noiseMedian: median(noises),
                noiseMAD: mad(noises),
                trailingMedian: median(trails),
                trailingMAD: mad(trails),
                frameCount: frames.count
            )
        }

        return HistoricalBaselines(baselines: baselines)
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2.0 : sorted[mid]
    }

    private static func mad(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let med = median(sorted)
        let deviations = sorted.map { Swift.abs($0 - med) }.sorted()
        return 1.4826 * median(deviations)
    }
}

// MARK: - iCloud Metadata

/// Metadata sidecar for iCloud backup freshness check.
struct FrameHistoryMeta: Codable {
    let lastModified: String        // ISO 8601
    let frameCount: Int
    let sessionCount: Int
    let dbSizeBytes: Int64
}
