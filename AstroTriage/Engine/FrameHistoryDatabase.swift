import Foundation
import GRDB

/// Persistent SQLite database for per-frame quality history across all sessions.
/// Uses GRDB.swift for type-safe SQLite access.
///
/// Design principles:
/// - No garbage collection needed: fileHash PRIMARY KEY → UPSERT semantics (no duplicates)
/// - Every record = a real analyzed file (no orphans by construction)
/// - iCloud: rotating backup with startup freshness check (not real-time sync)
final class FrameHistoryDatabase {
    static let shared = FrameHistoryDatabase()

    private var dbQueue: DatabaseQueue
    private let storageURL: URL

    // iCloud directory resolved once on a background thread.
    // FileManager.url(forUbiquityContainerIdentifier:) can block 10-30s,
    // so we resolve it asynchronously and notify via callback when ready.
    private var _iCloudDirectory: URL?
    private var _iCloudResolutionStarted = false
    private var _iCloudResolved = false
    private var _iCloudReadyCallbacks: [(URL?) -> Void] = []

    /// Register a callback for when iCloud directory resolution completes.
    /// If already resolved, callback fires immediately. Must be called from main thread.
    func onICloudResolved(_ callback: @escaping (URL?) -> Void) {
        if _iCloudResolved {
            callback(_iCloudDirectory)
            return
        }
        _iCloudReadyCallbacks.append(callback)
    }

    private func resolveICloudIfNeeded() {
        guard !_iCloudResolutionStarted else { return }
        _iCloudResolutionStarted = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.joergsflow.AstroBlinkV2")
            let dir: URL?
            if let container {
                let d = container.appendingPathComponent(Self.iCloudSubdir, isDirectory: true)
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                dir = d
                print("FrameHistoryDatabase: iCloud resolved → \(d.path)")
            } else {
                dir = nil
                print("FrameHistoryDatabase: iCloud not available (not signed in or Drive not enabled)")
            }
            DispatchQueue.main.async {
                self._iCloudDirectory = dir
                self._iCloudResolved = true
                let callbacks = self._iCloudReadyCallbacks
                self._iCloudReadyCallbacks.removeAll()
                for cb in callbacks {
                    cb(dir)
                }
            }
        }
    }

    private static let dbFilename = "FrameHistory.sqlite"
    private static let iCloudSubdir = "Documents/FrameHistory"

    private init() {
        // Local: ~/Library/Application Support/AstroBlinkV2/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AstroBlinkV2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent(Self.dbFilename)

        // Open or create database (local only — no iCloud access here)
        do {
            dbQueue = try DatabaseQueue(path: storageURL.path)
            try Self.migrate(dbQueue)
        } catch {
            fatalError("FrameHistoryDatabase: failed to open database: \(error)")
        }

        // Start iCloud resolution in background (fire-and-forget, non-blocking)
        resolveICloudIfNeeded()
    }

    // MARK: - Schema Migration

    private static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            // frame_record
            try db.create(table: "frame_record") { t in
                t.primaryKey("fileHash", .text).notNull()
                t.column("shortId", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("observingNight", .text)
                t.column("captureDate", .text)
                t.column("captureTime", .text)
                t.column("sessionId", .text).notNull()
                // Equipment
                t.column("telescope", .text)
                t.column("camera", .text)
                t.column("focalLength", .double)
                t.column("pixelSizeMicrons", .double)
                t.column("setupHash", .text)
                // Capture
                t.column("target", .text)
                t.column("filter", .text)
                t.column("exposure", .double)
                t.column("gain", .integer)
                t.column("offsetVal", .integer)
                t.column("binning", .text)
                t.column("pierSide", .text)
                t.column("rotatorAngle", .double)
                t.column("mount", .text)
                // Quality
                t.column("computedFWHM", .double)
                t.column("computedHFR", .double)
                t.column("computedStarCount", .integer)
                t.column("computedEccentricity", .double)
                t.column("noiseMedian", .double)
                t.column("noiseMAD", .double)
                // Trailing
                t.column("trailingScore", .double)
                t.column("trailingPA", .double)
                t.column("trailingConsensus", .double)
                t.column("trailingAxisRatio", .double)
                t.column("starChainFraction", .double)
                // Environment
                t.column("sensorTemp", .double)
                t.column("focuserTemp", .double)
                t.column("ambientTemp", .double)
                t.column("twilightPhase", .text)
                t.column("moonIllumination", .double)
                t.column("moonDistance", .double)
                // Results
                t.column("qualityTier", .integer)
                t.column("combinedZScore", .double)
                t.column("garbageReasons", .text)
                t.column("isLockedKeep", .integer).notNull().defaults(to: 0)
                t.column("filterTrailingMultiplier", .double)
                t.column("wasDeleted", .integer).notNull().defaults(to: 0)
                // Meta
                t.column("algorithmVersion", .integer).notNull().defaults(to: 1)
                t.column("recordedAt", .text).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
            }
            try db.create(index: "idx_frame_setup", on: "frame_record", columns: ["setupHash", "filter", "exposure"])
            try db.create(index: "idx_frame_target", on: "frame_record", columns: ["target"])
            try db.create(index: "idx_frame_night", on: "frame_record", columns: ["observingNight"])
            try db.create(index: "idx_frame_session", on: "frame_record", columns: ["sessionId"])

            // session_record
            try db.create(table: "session_record") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sessionPath", .text).notNull()
                t.column("observingNight", .text)
                t.column("setupHash", .text)
                t.column("telescope", .text)
                t.column("camera", .text)
                t.column("target", .text)
                t.column("frameCount", .integer).notNull()
                t.column("trashCount", .integer).notNull()
                t.column("deletedCount", .integer).notNull().defaults(to: 0)
                t.column("recordedAt", .text).notNull()
            }
            try db.create(index: "idx_session_night", on: "session_record", columns: ["observingNight"])
            try db.create(index: "idx_session_setup", on: "session_record", columns: ["setupHash"])

            // setup_nickname — user-defined names for equipment setups
            try db.create(table: "setup_nickname") { t in
                t.primaryKey("setupHash", .text).notNull()
                t.column("nickname", .text).notNull()
            }

            // scan_progress (for Archive Scanner)
            try db.create(table: "scan_progress") { t in
                t.primaryKey("rootPath", .text).notNull()
                t.column("lastScannedPath", .text)
                t.column("totalFound", .integer).notNull()
                t.column("totalProcessed", .integer).notNull()
                t.column("startedAt", .text).notNull()
                t.column("lastUpdatedAt", .text).notNull()
                t.column("isComplete", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v2_setup_nicknames") { db in
            try db.create(table: "setup_nickname", ifNotExists: true) { t in
                t.primaryKey("setupHash", .text).notNull()
                t.column("nickname", .text).notNull()
            }
        }

        // Set all existing records to algorithm version 10 (v5.6.0 scoring baseline)
        migrator.registerMigration("v3_algorithm_version_baseline") { db in
            try db.execute(sql: "UPDATE frame_record SET algorithmVersion = 10 WHERE algorithmVersion < 10")
        }

        // Add Bortle class + canonical target columns
        migrator.registerMigration("v4_bortle_and_canonical_target") { db in
            try db.alter(table: "frame_record") { t in
                t.add(column: "bortleClass", .integer)
                t.add(column: "canonicalTarget", .text)
            }
            // Backfill canonical target names for existing records
            let rows = try Row.fetchAll(db, sql: "SELECT fileHash, target FROM frame_record WHERE target IS NOT NULL")
            for row in rows {
                let hash: String = row["fileHash"]
                let target: String = row["target"]
                let canonical = TargetCatalog.canonicalName(target)
                try db.execute(sql: "UPDATE frame_record SET canonicalTarget = ? WHERE fileHash = ?",
                              arguments: [canonical, hash])
            }
        }

        // Remove calibration frames (FLAT/DARK/BIAS) that were accidentally scanned
        migrator.registerMigration("v5_remove_calibration_frames") { db in
            try db.execute(sql: """
                DELETE FROM frame_record
                WHERE LOWER(filename) LIKE '%flat%'
                   OR LOWER(filename) LIKE '%dark%'
                   OR LOWER(filename) LIKE '%bias%'
                   OR LOWER(filePath) LIKE '%flatwizard%'
                   OR LOWER(filePath) LIKE '%/dark/%'
                   OR LOWER(filePath) LIKE '%/darks/%'
                   OR LOWER(filePath) LIKE '%/flat/%'
                   OR LOWER(filePath) LIKE '%/flats/%'
                   OR LOWER(filePath) LIKE '%/bias/%'
                """)
        }

        // v6: Add psfFlux column for PSFSignalWeight persistence
        migrator.registerMigration("v6_psf_flux") { db in
            try db.execute(sql: "ALTER TABLE frame_record ADD COLUMN psfFlux DOUBLE")
        }

        // v7: Add userConfidence column for user confidence ratings (1-3 stars)
        migrator.registerMigration("v7_user_confidence") { db in
            try db.execute(sql: "ALTER TABLE frame_record ADD COLUMN userConfidence INTEGER NOT NULL DEFAULT 0")
        }

        // Add majorTarget column for sub-target → parent association
        migrator.registerMigration("v8_major_target") { db in
            try db.alter(table: "frame_record") { t in
                t.add(column: "majorTarget", .text)
            }
            // Backfill major target for existing records that have a canonical target
            let rows = try Row.fetchAll(db, sql: "SELECT fileHash, canonicalTarget FROM frame_record WHERE canonicalTarget IS NOT NULL")
            for row in rows {
                let hash: String = row["fileHash"]
                let canonical: String = row["canonicalTarget"]
                if let major = TargetCatalog.majorTarget(canonical) {
                    try db.execute(sql: "UPDATE frame_record SET majorTarget = ? WHERE fileHash = ?",
                                  arguments: [major, hash])
                }
            }
        }

        // v9: Add qualityFeedback column for user agree/disagree/partly on quality tier
        migrator.registerMigration("v9_quality_feedback") { db in
            try db.execute(sql: "ALTER TABLE frame_record ADD COLUMN qualityFeedback INTEGER NOT NULL DEFAULT 0")
        }

        try migrator.migrate(db)
    }

    // MARK: - Write API

    /// Save a batch of frame records (UPSERT via INSERT OR REPLACE).
    func saveFrameRecords(_ records: [FrameRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    /// Save a session summary record.
    func saveSessionRecord(_ session: SessionRecord) throws {
        try dbQueue.write { db in
            try session.save(db)
        }
    }

    /// Update user confidence rating for a frame by file hash.
    func updateUserConfidence(fileHash: String, confidence: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE frame_record SET userConfidence = ? WHERE fileHash = ?",
                arguments: [confidence, fileHash])
        }
    }

    /// Update quality feedback for a frame by file hash.
    func updateQualityFeedback(fileHash: String, feedback: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE frame_record SET qualityFeedback = ? WHERE fileHash = ?",
                arguments: [feedback, fileHash])
        }
    }

    /// Mark frames as deleted by file hash (called during pre-delete).
    func markDeleted(fileHashes: [String]) throws {
        guard !fileHashes.isEmpty else { return }
        try dbQueue.write { db in
            for hash in fileHashes {
                try db.execute(
                    sql: "UPDATE frame_record SET wasDeleted = 1 WHERE fileHash = ?",
                    arguments: [hash]
                )
            }
        }
    }

    /// Update deletion count for a session.
    func updateSessionDeletedCount(sessionId: String, deletedCount: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE session_record SET deletedCount = ? WHERE id = ?",
                arguments: [deletedCount, sessionId]
            )
        }
    }

    // MARK: - Read API

    /// Fetch a single frame record by file hash.
    func frameRecord(fileHash: String) throws -> FrameRecord? {
        try dbQueue.read { db in
            try FrameRecord.fetchOne(db, key: fileHash)
        }
    }

    /// Historical frames for a setup, optionally filtered by filter/exposure.
    /// Excludes the current session to avoid self-comparison.
    func historicalFrames(
        setupHash: String,
        filter: String? = nil,
        exposure: Int? = nil,
        excludingSession: String? = nil
    ) throws -> [FrameRecord] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM frame_record WHERE setupHash = ?"
            var args: [DatabaseValueConvertible] = [setupHash]

            if let filter {
                sql += " AND UPPER(filter) = ?"
                args.append(filter.uppercased())
            }
            if let exposure {
                sql += " AND CAST(exposure AS INTEGER) = ?"
                args.append(exposure)
            }
            if let excludingSession {
                sql += " AND sessionId != ?"
                args.append(excludingSession)
            }

            return try FrameRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// All sessions for a setup, ordered by night descending.
    func sessions(setupHash: String? = nil) throws -> [SessionRecord] {
        try dbQueue.read { db in
            if let setupHash {
                return try SessionRecord
                    .filter(Column("setupHash") == setupHash)
                    .order(Column("recordedAt").desc)
                    .fetchAll(db)
            } else {
                return try SessionRecord
                    .order(Column("recordedAt").desc)
                    .fetchAll(db)
            }
        }
    }

    /// Per-night quality summary for charts.
    func nightlyTrend(setupHash: String, target: String? = nil) throws -> [NightSummary] {
        try dbQueue.read { db in
            var sql = """
                SELECT observingNight, COALESCE(canonicalTarget, target) as cTarget, filter,
                    COUNT(*) as cnt,
                    SUM(CASE WHEN qualityTier = 0 THEN 1 ELSE 0 END) as trash,
                    SUM(CASE WHEN qualityTier = 2 THEN 1 ELSE 0 END) as good,
                    SUM(CASE WHEN qualityTier = 3 THEN 1 ELSE 0 END) as excellent,
                    SUM(CASE WHEN qualityTier = 1 OR qualityTier = 4 THEN 1 ELSE 0 END) as borderline,
                    AVG(computedFWHM) as avgFWHM,
                    AVG(computedHFR) as avgHFR,
                    AVG(CAST(computedStarCount AS REAL)) as avgStars,
                    AVG(noiseMAD) as avgNoise,
                    AVG(trailingScore) as avgTrailing,
                    AVG(moonIllumination) as avgMoon,
                    AVG(moonDistance) as avgMoonDist,
                    AVG(exposure) as avgExposure,
                    AVG(ambientTemp) as avgTemp,
                    AVG(bortleClass) as avgBortle
                FROM frame_record
                WHERE setupHash = ? AND observingNight IS NOT NULL
                """
            var args: [DatabaseValueConvertible] = [setupHash]

            if let target {
                // Match canonical target OR major target (sub-targets roll up to parent)
                sql += " AND (COALESCE(canonicalTarget, target) = ? OR majorTarget = ?)"
                args.append(target)
                args.append(target)
            }

            // Group by target too — without it, multiple targets on the same night
            // with the same filter get merged into one row, causing misattribution
            sql += " GROUP BY observingNight, cTarget, filter ORDER BY observingNight ASC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                NightSummary(
                    night: row["observingNight"] ?? "",
                    target: row["cTarget"],
                    filter: row["filter"],
                    frameCount: row["cnt"] ?? 0,
                    trashCount: row["trash"] ?? 0,
                    goodCount: row["good"] ?? 0,
                    excellentCount: row["excellent"] ?? 0,
                    borderlineCount: row["borderline"] ?? 0,
                    medianFWHM: row["avgFWHM"],
                    medianHFR: row["avgHFR"],
                    medianStarCount: row["avgStars"],
                    medianNoise: row["avgNoise"],
                    medianTrailing: row["avgTrailing"],
                    medianMoonIllumination: row["avgMoon"],
                    medianMoonDistance: row["avgMoonDist"],
                    medianExposure: row["avgExposure"],
                    medianAmbientTemp: row["avgTemp"],
                    medianBortle: row["avgBortle"]
                )
            }
        }
    }

    /// Per-night quality summary across ALL setups (consolidated view).
    func nightlyTrendAll(target: String? = nil) throws -> [NightSummary] {
        try dbQueue.read { db in
            var sql = """
                SELECT observingNight, COALESCE(canonicalTarget, target) as cTarget, filter,
                    COUNT(*) as cnt,
                    SUM(CASE WHEN qualityTier = 0 THEN 1 ELSE 0 END) as trash,
                    SUM(CASE WHEN qualityTier = 2 THEN 1 ELSE 0 END) as good,
                    SUM(CASE WHEN qualityTier = 3 THEN 1 ELSE 0 END) as excellent,
                    SUM(CASE WHEN qualityTier = 1 OR qualityTier = 4 THEN 1 ELSE 0 END) as borderline,
                    AVG(computedFWHM) as avgFWHM,
                    AVG(computedHFR) as avgHFR,
                    AVG(CAST(computedStarCount AS REAL)) as avgStars,
                    AVG(noiseMAD) as avgNoise,
                    AVG(trailingScore) as avgTrailing,
                    AVG(moonIllumination) as avgMoon,
                    AVG(moonDistance) as avgMoonDist,
                    AVG(exposure) as avgExposure,
                    AVG(ambientTemp) as avgTemp,
                    AVG(bortleClass) as avgBortle
                FROM frame_record
                WHERE observingNight IS NOT NULL
                """
            var args: [DatabaseValueConvertible] = []

            if let target {
                // Match canonical target OR major target (sub-targets roll up to parent)
                sql += " AND (COALESCE(canonicalTarget, target) = ? OR majorTarget = ?)"
                args.append(target)
                args.append(target)
            }

            // Group by target too — without it, multiple targets on the same night
            // with the same filter get merged into one row, causing misattribution
            sql += " GROUP BY observingNight, cTarget, filter ORDER BY observingNight ASC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                NightSummary(
                    night: row["observingNight"] ?? "",
                    target: row["cTarget"],
                    filter: row["filter"],
                    frameCount: row["cnt"] ?? 0,
                    trashCount: row["trash"] ?? 0,
                    goodCount: row["good"] ?? 0,
                    excellentCount: row["excellent"] ?? 0,
                    borderlineCount: row["borderline"] ?? 0,
                    medianFWHM: row["avgFWHM"],
                    medianHFR: row["avgHFR"],
                    medianStarCount: row["avgStars"],
                    medianNoise: row["avgNoise"],
                    medianTrailing: row["avgTrailing"],
                    medianMoonIllumination: row["avgMoon"],
                    medianMoonDistance: row["avgMoonDist"],
                    medianExposure: row["avgExposure"],
                    medianAmbientTemp: row["avgTemp"],
                    medianBortle: row["avgBortle"]
                )
            }
        }
    }

    /// Aggregate setup summary for AIsaac context.
    func setupSummary(setupHash: String) throws -> SetupHistorySummary? {
        try setupSummary(setupHashes: [setupHash])
    }

    /// Summary across multiple setup hashes (for merged setups with similar FL).
    func setupSummary(setupHashes: [String]) throws -> SetupHistorySummary? {
        guard !setupHashes.isEmpty else { return nil }
        let placeholders = setupHashes.map { _ in "?" }.joined(separator: ",")
        return try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) as total,
                    AVG(computedFWHM) as avgFWHM,
                    AVG(CAST(computedStarCount AS REAL)) as avgStars,
                    AVG(noiseMAD) as avgNoise,
                    AVG(trailingScore) as avgTrailing,
                    SUM(CASE WHEN qualityTier = 0 THEN 1 ELSE 0 END) as trashCount,
                    MIN(observingNight) as firstNight,
                    MAX(observingNight) as lastNight
                FROM frame_record WHERE setupHash IN (\(placeholders))
                """, arguments: StatementArguments(setupHashes))

            guard let row, let total: Int = row["total"], total > 0 else { return nil }

            let sessionCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT sessionId) FROM frame_record WHERE setupHash IN (\(placeholders))
                """, arguments: StatementArguments(setupHashes)) ?? 0

            let targets = try String.fetchAll(db, sql: """
                SELECT DISTINCT target FROM frame_record
                WHERE setupHash IN (\(placeholders)) AND target IS NOT NULL
                """, arguments: StatementArguments(setupHashes))

            return SetupHistorySummary(
                totalFrames: total,
                sessionCount: sessionCount,
                firstNight: row["firstNight"],
                lastNight: row["lastNight"],
                medianFWHM: row["avgFWHM"] ?? 0,
                medianStarCount: row["avgStars"] ?? 0,
                medianNoise: row["avgNoise"] ?? 0,
                medianTrailing: row["avgTrailing"] ?? 0,
                trashRate: Double(row["trashCount"] ?? 0) / Double(total),
                targets: targets
            )
        }
    }

    /// Global summary for AIsaac — recent sessions, all targets, all setups.
    func globalSummaryForAIsaac() throws -> String {
        try dbQueue.read { db in
            var lines: [String] = []

            // Recent 5 sessions
            let recentSessions = try Row.fetchAll(db, sql: """
                SELECT observingNight, COALESCE(telescope,'?') || ' + ' || COALESCE(camera,'?') as setup,
                    COALESCE(canonicalTarget, target) as tgt, COUNT(*) as cnt,
                    SUM(CASE WHEN wasDeleted=1 THEN 1 ELSE 0 END) as del
                FROM frame_record WHERE observingNight IS NOT NULL
                GROUP BY observingNight ORDER BY observingNight DESC LIMIT 5
                """)
            if !recentSessions.isEmpty {
                lines.append("RECENT SESSIONS:")
                for row in recentSessions {
                    let night: String = row["observingNight"] ?? "?"
                    let setup: String = row["setup"] ?? "?"
                    let tgt: String = row["tgt"] ?? "?"
                    let cnt: Int = row["cnt"] ?? 0
                    let del: Int = row["del"] ?? 0
                    let delStr = del > 0 ? " (\(del) deleted)" : ""
                    lines.append("  \(night): \(tgt) — \(cnt) frames\(delStr) [\(setup)]")
                }
            }

            // All targets with integration per filter
            let targets = try Row.fetchAll(db, sql: """
                SELECT COALESCE(canonicalTarget, target) as tgt, filter,
                    COUNT(*) as cnt, SUM(COALESCE(exposure,0)) as totalExp,
                    SUM(CASE WHEN wasDeleted=1 THEN 1 ELSE 0 END) as del
                FROM frame_record WHERE target IS NOT NULL AND wasDeleted=0
                GROUP BY tgt, filter ORDER BY totalExp DESC
                """)
            if !targets.isEmpty {
                // Aggregate by target
                var byTarget: [String: [(filter: String, hours: Double, frames: Int)]] = [:]
                for row in targets {
                    let tgt: String = row["tgt"] ?? "?"
                    let filter: String = row["filter"] ?? "?"
                    let exp: Double = row["totalExp"] ?? 0
                    let cnt: Int = row["cnt"] ?? 0
                    byTarget[tgt, default: []].append((filter, exp / 3600.0, cnt))
                }
                lines.append("")
                lines.append("ALL TARGETS (usable frames, by filter):")
                let sorted = byTarget.sorted { a, b in
                    a.value.reduce(0) { $0 + $1.hours } > b.value.reduce(0) { $0 + $1.hours }
                }
                for (target, filters) in sorted.prefix(20) {
                    let totalH = filters.reduce(0) { $0 + $1.hours }
                    let details = filters.map { "\($0.filter) \(String(format: "%.1fh", $0.hours))" }.joined(separator: ", ")
                    lines.append("  \(target): \(String(format: "%.1fh", totalH)) total — \(details)")
                }
            }

            // All setups
            let setups = try Row.fetchAll(db, sql: """
                SELECT COALESCE(telescope,'?') || ' + ' || COALESCE(camera,'?') as setup,
                    COUNT(*) as cnt, MIN(observingNight) as first, MAX(observingNight) as last
                FROM frame_record WHERE setupHash IS NOT NULL
                GROUP BY setupHash ORDER BY cnt DESC
                """)
            if !setups.isEmpty {
                lines.append("")
                lines.append("EQUIPMENT SETUPS:")
                for row in setups {
                    let setup: String = row["setup"] ?? "?"
                    let cnt: Int = row["cnt"] ?? 0
                    let first: String = row["first"] ?? "?"
                    let last: String = row["last"] ?? "?"
                    lines.append("  \(setup): \(cnt) frames (\(first) — \(last))")
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    /// Database statistics for UI display.
    func databaseStats() throws -> (frameCount: Int, sessionCount: Int, firstNight: String?, lastNight: String?) {
        try dbQueue.read { db in
            let frameCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_record") ?? 0
            let sessionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_record") ?? 0
            let firstNight = try String.fetchOne(db, sql: "SELECT MIN(observingNight) FROM frame_record")
            let lastNight = try String.fetchOne(db, sql: "SELECT MAX(observingNight) FROM frame_record")
            return (frameCount, sessionCount, firstNight, lastNight)
        }
    }

    /// Deletion history stats for a target+setup: total frames, deleted frames, deletion %.
    func deletionStats(target: String? = nil, setupHash: String? = nil) throws -> (total: Int, deleted: Int, deletedPct: Double) {
        try dbQueue.read { db in
            var sql = "SELECT COUNT(*) as total, SUM(CASE WHEN wasDeleted = 1 THEN 1 ELSE 0 END) as deleted FROM frame_record WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let target {
                sql += " AND (COALESCE(canonicalTarget, target) = ? OR majorTarget = ?)"
                args.append(target)
                args.append(target)
            }
            if let setupHash {
                sql += " AND setupHash = ?"
                args.append(setupHash)
            }
            let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))
            let total: Int = row?["total"] ?? 0
            let deleted: Int = row?["deleted"] ?? 0
            let pct = total > 0 ? Double(deleted) / Double(total) * 100 : 0
            return (total, deleted, pct)
        }
    }

    /// Per-setup FWHM for a given night (for "All Setups" performance tooltip).
    func perSetupFWHM(night: String) throws -> [(setup: String, fwhm: Double)] {
        // Fetch nicknames OUTSIDE the read block to avoid reentrant DatabaseQueue access
        let nicknames = allNicknames()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT setupHash,
                    COALESCE(telescope, '') || ' + ' || COALESCE(camera, '') as equipment,
                    AVG(computedFWHM) as avgFWHM
                FROM frame_record
                WHERE observingNight = ? AND computedFWHM IS NOT NULL
                GROUP BY setupHash
                ORDER BY avgFWHM ASC
                """, arguments: [night])
            return rows.compactMap { row -> (String, Double)? in
                guard let fwhm: Double = row["avgFWHM"],
                      let hash: String = row["setupHash"] else { return nil }
                let equipment: String = row["equipment"] ?? hash.prefix(8).description
                let label = nicknames[hash].map { "\($0)" } ?? equipment
                return (label, fwhm)
            }
        }
    }

    /// Count records with older algorithm versions (candidates for re-analysis).
    func staleRecordCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_record WHERE algorithmVersion < ?",
                            arguments: [kAlgorithmVersion]) ?? 0
        }
    }

    /// Check if a file hash already exists in the database.
    func recordExists(fileHash: String) throws -> Bool {
        try dbQueue.read { db in
            try FrameRecord.fetchOne(db, key: fileHash) != nil
        }
    }

    // MARK: - File Hash Computation

    /// Compute SHA256 hash of the first 64KB of a file.
    /// Delegates to FileHasher (standalone, no GRDB dependency).
    static func fileHash(for url: URL) -> String? {
        FileHasher.hash(for: url)
    }

    // MARK: - iCloud Backup

    /// Export database to iCloud container with rotating backup.
    func exportToICloud() {
        // If iCloud hasn't resolved yet (e.g. quick quit), try synchronous resolution as fallback
        if _iCloudDirectory == nil && !_iCloudResolved {
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.joergsflow.AstroBlinkV2") {
                let dir = container.appendingPathComponent(Self.iCloudSubdir, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _iCloudDirectory = dir
                print("FrameHistoryDatabase: iCloud resolved synchronously during export")
            }
        }
        guard let iDir = _iCloudDirectory else {
            print("FrameHistoryDatabase: skipping iCloud export — iCloud not available")
            return
        }

        let latestURL = iDir.appendingPathComponent(Self.dbFilename)
        let backupURL = iDir.appendingPathComponent("FrameHistory_backup1.sqlite")
        let metaURL = iDir.appendingPathComponent("FrameHistory_meta.json")

        do {
            // Rotate: current → backup1
            if FileManager.default.fileExists(atPath: latestURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.moveItem(at: latestURL, to: backupURL)
            }

            // Copy current DB to iCloud
            try FileManager.default.copyItem(at: storageURL, to: latestURL)

            // Write metadata sidecar
            let stats = try databaseStats()
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: storageURL.path)[.size] as? Int64) ?? 0
            let meta = FrameHistoryMeta(
                lastModified: ISO8601DateFormatter().string(from: Date()),
                frameCount: stats.frameCount,
                sessionCount: stats.sessionCount,
                dbSizeBytes: fileSize
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(meta)
            try data.write(to: metaURL, options: .atomic)
            print("FrameHistoryDatabase: exported to iCloud — \(stats.frameCount) frames (\(String(format: "%.1f MB", Double(fileSize) / (1024*1024))))")
        } catch {
            print("FrameHistoryDatabase: iCloud export failed: \(error)")
        }
    }

    /// Async check if iCloud has a newer/larger database than local.
    /// Handles evicted (cloud-only) files by triggering download via NSFileCoordinator.
    /// Completion is called on main thread.
    func checkICloudForNewerDBAsync(completion: @escaping ((local: FrameHistoryMeta, iCloud: FrameHistoryMeta)?) -> Void) {
        guard let iDir = _iCloudDirectory else {
            print("FrameHistoryDatabase: sync check skipped — iCloud directory not available")
            completion(nil)
            return
        }
        let metaURL = iDir.appendingPathComponent("FrameHistory_meta.json")

        // Trigger download if file is evicted (cloud-only placeholder on new Mac)
        try? FileManager.default.startDownloadingUbiquitousItem(at: metaURL)

        // Read on background thread — NSFileCoordinator waits for download if needed
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            var coordinatorError: NSError?
            var result: (local: FrameHistoryMeta, iCloud: FrameHistoryMeta)?

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: metaURL, options: [], error: &coordinatorError) { readURL in
                guard let data = try? Data(contentsOf: readURL),
                      let iCloudMeta = try? JSONDecoder().decode(FrameHistoryMeta.self, from: data) else {
                    print("FrameHistoryDatabase: failed to read iCloud meta.json at \(readURL.path)")
                    return
                }

                guard let localStats = try? self.databaseStats() else { return }
                let localSize = (try? FileManager.default.attributesOfItem(atPath: self.storageURL.path)[.size] as? Int64) ?? 0
                let localMeta = FrameHistoryMeta(
                    lastModified: ISO8601DateFormatter().string(from: Date()),
                    frameCount: localStats.frameCount,
                    sessionCount: localStats.sessionCount,
                    dbSizeBytes: localSize
                )

                if iCloudMeta.frameCount != localMeta.frameCount {
                    result = (local: localMeta, iCloud: iCloudMeta)
                    print("FrameHistoryDatabase: iCloud differs — local \(localMeta.frameCount), iCloud \(iCloudMeta.frameCount) frames")
                } else {
                    print("FrameHistoryDatabase: iCloud in sync (\(localMeta.frameCount) frames)")
                }
            }

            if let error = coordinatorError {
                print("FrameHistoryDatabase: NSFileCoordinator error reading meta: \(error)")
            }

            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Import database from iCloud (replaces local DB). Call after user confirmation.
    /// Handles evicted files via download trigger + NSFileCoordinator.
    /// Completion is called on main thread with imported frame count or error.
    func importFromICloudAsync(completion: @escaping (Result<Int, Error>) -> Void) {
        guard let iDir = _iCloudDirectory else {
            completion(.failure(NSError(domain: "FrameHistoryDatabase", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "iCloud not available"])))
            return
        }
        let iCloudDB = iDir.appendingPathComponent(Self.dbFilename)

        // Trigger download if evicted
        try? FileManager.default.startDownloadingUbiquitousItem(at: iCloudDB)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            var coordinatorError: NSError?
            var importResult: Result<Int, Error> = .failure(NSError(domain: "FrameHistoryDatabase", code: 3,
                                                                     userInfo: [NSLocalizedDescriptionKey: "Import did not complete"]))

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: iCloudDB, options: [], error: &coordinatorError) { readURL in
                do {
                    try? FileManager.default.removeItem(at: self.storageURL)
                    try FileManager.default.copyItem(at: readURL, to: self.storageURL)
                    // Reopen database connection (old DatabaseQueue still points to deleted inode)
                    self.dbQueue = try DatabaseQueue(path: self.storageURL.path)
                    try Self.migrate(self.dbQueue)
                    let count = (try? self.databaseStats())?.frameCount ?? 0
                    print("FrameHistoryDatabase: imported \(count) frames from iCloud, DB reopened")
                    importResult = .success(count)
                } catch {
                    print("FrameHistoryDatabase: import failed: \(error)")
                    importResult = .failure(error)
                }
            }

            if let error = coordinatorError {
                print("FrameHistoryDatabase: NSFileCoordinator error on import: \(error)")
                importResult = .failure(error)
            }

            DispatchQueue.main.async {
                // Notify UI to reload Frame History data
                NotificationCenter.default.post(name: .frameHistoryDidImport, object: nil)
                completion(importResult)
            }
        }
    }

    // MARK: - Setup Nicknames

    /// Set a user-defined nickname for a setup (e.g. "Big Rig", "Travel Scope").
    func setNickname(_ nickname: String, for setupHash: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO setup_nickname (setupHash, nickname) VALUES (?, ?)",
                arguments: [setupHash, nickname]
            )
        }
    }

    /// Get nickname for a setup, or nil if not set.
    func nickname(for setupHash: String) -> String? {
        try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT nickname FROM setup_nickname WHERE setupHash = ?",
                               arguments: [setupHash])
        }
    }

    /// Get all nicknames as [setupHash: nickname].
    func allNicknames() -> [String: String] {
        (try? dbQueue.read { db in
            var result: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT setupHash, nickname FROM setup_nickname")
            for row in rows {
                if let hash: String = row["setupHash"], let name: String = row["nickname"] {
                    result[hash] = name
                }
            }
            return result
        }) ?? [:]
    }

    // MARK: - Setup Management (merge, delete, fix FL)

    /// Delete all frame records for a setup hash. Used to remove bad/duplicate setups.
    /// Also cleans session_record and setup_nickname entries.
    func deleteSetup(setupHash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM frame_record WHERE setupHash = ?", arguments: [setupHash])
            try db.execute(sql: "DELETE FROM session_record WHERE setupHash = ?", arguments: [setupHash])
            try db.execute(sql: "DELETE FROM setup_nickname WHERE setupHash = ?", arguments: [setupHash])
        }
    }

    /// Merge setup B into setup A: reassign all frames from sourceHash to targetHash.
    /// After merge, source setup disappears and all its frames belong to target.
    /// Also cleans up session_record and nickname for the source.
    func mergeSetups(from sourceHash: String, into targetHash: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE frame_record SET setupHash = ? WHERE setupHash = ?",
                arguments: [targetHash, sourceHash]
            )
            // Clean up orphaned source entries
            try db.execute(sql: "DELETE FROM session_record WHERE setupHash = ?", arguments: [sourceHash])
            try db.execute(sql: "DELETE FROM setup_nickname WHERE setupHash = ?", arguments: [sourceHash])
        }
    }

    /// Remove orphaned session records that have no matching frames.
    func cleanOrphanedSessions() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM session_record WHERE setupHash NOT IN (
                    SELECT DISTINCT setupHash FROM frame_record WHERE setupHash IS NOT NULL
                )
            """)
        }
    }

    /// Override focal length for all frames in a setup. Fixes bad plate-solve FL values.
    func updateFocalLength(setupHash: String, newFL: Double) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE frame_record SET focalLength = ? WHERE setupHash = ?",
                arguments: [newFL, setupHash]
            )
        }
    }

    /// Returns the most common focal length for a setup hash (mode), or nil if unknown.
    func primaryFocalLength(for setupHash: String) -> Int? {
        try? dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT CAST(ROUND(focalLength) AS INTEGER) as fl, COUNT(*) as cnt
                FROM frame_record WHERE setupHash = ? AND focalLength IS NOT NULL
                GROUP BY fl ORDER BY cnt DESC LIMIT 1
                """, arguments: [setupHash])
            return row?["fl"] as Int?
        }
    }

    /// Returns the most common focal length across multiple setup hashes (for merged setups).
    func primaryFocalLength(for setupHashes: [String]) -> Int? {
        guard !setupHashes.isEmpty else { return nil }
        if setupHashes.count == 1 { return primaryFocalLength(for: setupHashes[0]) }
        let placeholders = setupHashes.map { _ in "?" }.joined(separator: ",")
        return try? dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT CAST(ROUND(focalLength) AS INTEGER) as fl, COUNT(*) as cnt
                FROM frame_record WHERE setupHash IN (\(placeholders)) AND focalLength IS NOT NULL
                GROUP BY fl ORDER BY cnt DESC LIMIT 1
                """, arguments: StatementArguments(setupHashes))
            return row?["fl"] as Int?
        }
    }

    /// Returns the total frame count for a setup hash.
    func frameCount(setupHash: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_record WHERE setupHash = ?",
                             arguments: [setupHash]) ?? 0
        }
    }

    /// Per-night quality summary for multiple merged setup hashes.
    func nightlyTrend(setupHashes: [String], target: String? = nil) throws -> [NightSummary] {
        guard !setupHashes.isEmpty else { return [] }
        if setupHashes.count == 1 { return try nightlyTrend(setupHash: setupHashes[0], target: target) }

        let placeholders = setupHashes.map { _ in "?" }.joined(separator: ",")
        return try dbQueue.read { db in
            var sql = """
                SELECT observingNight, COALESCE(canonicalTarget, target) as cTarget, filter,
                    COUNT(*) as cnt,
                    SUM(CASE WHEN qualityTier = 0 THEN 1 ELSE 0 END) as trash,
                    SUM(CASE WHEN qualityTier = 2 THEN 1 ELSE 0 END) as good,
                    SUM(CASE WHEN qualityTier = 3 THEN 1 ELSE 0 END) as excellent,
                    SUM(CASE WHEN qualityTier = 1 OR qualityTier = 4 THEN 1 ELSE 0 END) as borderline,
                    AVG(computedFWHM) as avgFWHM,
                    AVG(computedHFR) as avgHFR,
                    AVG(CAST(computedStarCount AS REAL)) as avgStars,
                    AVG(noiseMAD) as avgNoise,
                    AVG(trailingScore) as avgTrailing,
                    AVG(moonIllumination) as avgMoon,
                    AVG(moonDistance) as avgMoonDist,
                    AVG(exposure) as avgExposure,
                    AVG(ambientTemp) as avgTemp,
                    AVG(bortleClass) as avgBortle
                FROM frame_record
                WHERE setupHash IN (\(placeholders)) AND observingNight IS NOT NULL
                """
            var args: [DatabaseValueConvertible] = setupHashes

            if let target {
                sql += " AND (COALESCE(canonicalTarget, target) = ? OR majorTarget = ?)"
                args.append(target)
                args.append(target)
            }

            // Group by target too — matches single-setup query fix
            sql += " GROUP BY observingNight, cTarget, filter ORDER BY observingNight ASC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                NightSummary(
                    night: row["observingNight"] ?? "",
                    target: row["cTarget"],
                    filter: row["filter"],
                    frameCount: row["cnt"] ?? 0,
                    trashCount: row["trash"] ?? 0,
                    goodCount: row["good"] ?? 0,
                    excellentCount: row["excellent"] ?? 0,
                    borderlineCount: row["borderline"] ?? 0,
                    medianFWHM: row["avgFWHM"],
                    medianHFR: row["avgHFR"],
                    medianStarCount: row["avgStars"],
                    medianNoise: row["avgNoise"],
                    medianTrailing: row["avgTrailing"],
                    medianMoonIllumination: row["avgMoon"],
                    medianMoonDistance: row["avgMoonDist"],
                    medianExposure: row["avgExposure"],
                    medianAmbientTemp: row["avgTemp"],
                    medianBortle: row["avgBortle"]
                )
            }
        }
    }

    /// Returns the display name for a setup: nickname if set, otherwise "telescope + camera".
    /// Used across the app wherever setup names appear (AIsaac, session overview, compare window).
    func setupDisplayName(telescope: String?, camera: String?, focalLength: Double? = nil, pixelSizeMicrons: Double? = nil) -> String {
        let fp = SetupFingerprint(telescope: telescope, camera: camera, focalLength: focalLength, pixelSizeMicrons: pixelSizeMicrons)
        if let nick = nickname(for: fp.hash), !nick.isEmpty {
            return nick
        }
        return [telescope, camera].compactMap { $0 }.joined(separator: " + ")
    }

    /// Fetch all frames for a telescope+camera combo (equipment match, ignores FL hash differences).
    /// Used by Stage 1.5b historical baseline check — plate-solve FL variations must not
    /// prevent finding historical reference data from the same physical equipment.
    func historicalFramesByEquipment(telescope: String, camera: String) throws -> [FrameRecord] {
        try dbQueue.read { db in
            try FrameRecord.fetchAll(db, sql: """
                SELECT * FROM frame_record
                WHERE LOWER(COALESCE(telescope,'')) = LOWER(?)
                  AND LOWER(COALESCE(camera,'')) = LOWER(?)
                ORDER BY observingNight ASC, captureTime ASC
                """, arguments: [telescope, camera])
        }
    }

    /// Fetch all frames for a target across ALL equipment (cross-equipment comparison).
    /// Used by Stage 1.5b when same-equipment same-target data is insufficient —
    /// trailing score and eccentricity are FL-normalized and comparable across equipment.
    func historicalFramesByTarget(canonicalTarget: String) throws -> [FrameRecord] {
        try dbQueue.read { db in
            try FrameRecord.fetchAll(db, sql: """
                SELECT * FROM frame_record
                WHERE (LOWER(COALESCE(canonicalTarget,'')) = LOWER(?)
                   OR LOWER(COALESCE(target,'')) = LOWER(?))
                ORDER BY observingNight ASC, captureTime ASC
                """, arguments: [canonicalTarget, canonicalTarget])
        }
    }

    // MARK: - Per-Frame Metrics Queries (for Session Metrics chart)

    /// Fetch per-frame records for the metrics chart, ordered by capture time.
    /// - night: if nil, fetches all frames (longterm view); if set, fetches frames for that night
    /// - setupHashes: if provided, restricts to these setups
    /// - target: if provided, restricts to this target
    func metricsFrames(
        night: String? = nil,
        setupHashes: [String]? = nil,
        target: String? = nil
    ) throws -> [FrameRecord] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM frame_record WHERE 1=1"
            var args: [DatabaseValueConvertible] = []

            if let night {
                sql += " AND observingNight = ?"
                args.append(night)
            }
            if let setupHashes, !setupHashes.isEmpty {
                let placeholders = setupHashes.map { _ in "?" }.joined(separator: ",")
                sql += " AND setupHash IN (\(placeholders))"
                args.append(contentsOf: setupHashes)
            }
            if let target, !target.isEmpty {
                sql += " AND (canonicalTarget = ? OR target = ?)"
                args.append(target)
                args.append(target)
            }

            sql += " ORDER BY captureDate ASC, captureTime ASC"

            return try FrameRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Get distinct observing nights, most recent first.
    func availableNights(setupHashes: [String]? = nil, target: String? = nil) throws -> [String] {
        try dbQueue.read { db in
            var sql = "SELECT DISTINCT observingNight FROM frame_record WHERE observingNight IS NOT NULL"
            var args: [DatabaseValueConvertible] = []

            if let setupHashes, !setupHashes.isEmpty {
                let placeholders = setupHashes.map { _ in "?" }.joined(separator: ",")
                sql += " AND setupHash IN (\(placeholders))"
                args.append(contentsOf: setupHashes)
            }
            if let target, !target.isEmpty {
                sql += " AND (canonicalTarget = ? OR target = ?)"
                args.append(target)
                args.append(target)
            }

            sql += " ORDER BY observingNight DESC"

            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - Session Queries (for Archive Scanner scoring)

    /// Fetch all frame records for a specific scan session.
    func frameRecords(forSession sessionId: String) throws -> [FrameRecord] {
        try dbQueue.read { db in
            try FrameRecord
                .filter(Column("sessionId") == sessionId)
                .fetchAll(db)
        }
    }

    /// Batch update quality tiers for frame records.
    func updateQualityTiers(_ updates: [(hash: String, tier: Int, zScore: Double)]) throws {
        try dbQueue.write { db in
            for update in updates {
                try db.execute(
                    sql: "UPDATE frame_record SET qualityTier = ?, combinedZScore = ? WHERE fileHash = ?",
                    arguments: [update.tier, update.zScore, update.hash]
                )
            }
        }
    }

    /// Fetch all records with older algorithm version (candidates for re-analysis).
    /// Groups are needed for QualityEstimator — returns records that can be grouped by setup+target+filter.
    func fetchStaleRecords() throws -> [FrameRecord] {
        try dbQueue.read { db in
            try FrameRecord
                .filter(Column("algorithmVersion") < kAlgorithmVersion)
                .order(Column("observingNight").asc, Column("captureTime").asc)
                .fetchAll(db)
        }
    }

    /// Batch update quality tiers AND bump algorithmVersion after re-analysis.
    func updateQualityTiersAndVersion(_ updates: [(hash: String, tier: Int, zScore: Double)]) throws {
        try dbQueue.write { db in
            for update in updates {
                try db.execute(
                    sql: """
                    UPDATE frame_record
                    SET qualityTier = ?, combinedZScore = ?, algorithmVersion = ?
                    WHERE fileHash = ?
                    """,
                    arguments: [update.tier, update.zScore, kAlgorithmVersion, update.hash]
                )
            }
        }
    }

    /// Bump algorithmVersion only (no tier change) for frames that couldn't be re-scored
    /// (e.g. group too small for QualityEstimator). Keeps existing quality tier intact.
    func bumpAlgorithmVersion(fileHashes: [String]) throws {
        try dbQueue.write { db in
            for hash in fileHashes {
                try db.execute(
                    sql: "UPDATE frame_record SET algorithmVersion = ? WHERE fileHash = ?",
                    arguments: [kAlgorithmVersion, hash]
                )
            }
        }
    }

    // MARK: - Scan Progress

    /// Save or update scan progress (UPSERT).
    func saveScanProgress(_ progress: ScanProgress) throws {
        try dbQueue.write { db in try progress.save(db) }
    }

    /// Get scan progress for a root path.
    func scanProgress(for rootPath: String) throws -> ScanProgress? {
        try dbQueue.read { db in try ScanProgress.fetchOne(db, key: rootPath) }
    }

    /// Get all incomplete scan progresses (for resume dialog).
    func incompleteScanProgress() throws -> [(rootPath: String, processed: Int, total: Int, lastUpdated: String)] {
        try dbQueue.read { db in
            let rows = try ScanProgress
                .filter(Column("isComplete") == 0)
                .order(Column("lastUpdatedAt").desc)
                .fetchAll(db)
            return rows.map { ($0.rootPath, $0.totalProcessed, $0.totalFound, $0.lastUpdatedAt) }
        }
    }

    // MARK: - Advanced: Reset

    /// Delete the entire database and recreate empty. Requires explicit user confirmation first.
    func resetDatabase() throws {
        try dbQueue.erase()
        try Self.migrate(dbQueue)
    }

    /// Destroy ALL data: local DB + iCloud backup + calibration files.
    func destroyAllData() throws {
        // 1. Erase local database
        try dbQueue.erase()
        try Self.migrate(dbQueue)

        // 2. Delete iCloud backups
        if let iDir = _iCloudDirectory {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: iDir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fm.removeItem(at: file)
                }
            }
        }

        // 3. Delete calibration database files
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let calibDir = appSupport?.appendingPathComponent("AstroBlinkV2/Calibration") {
            try? FileManager.default.removeItem(at: calibDir)
            try? FileManager.default.createDirectory(at: calibDir, withIntermediateDirectories: true)
        }

        // 4. Delete setup nicknames (already erased with DB, but explicit for clarity)
        print("FrameHistoryDatabase: ALL data destroyed (local + iCloud + calibration)")
    }
}
