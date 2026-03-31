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

    private let dbQueue: DatabaseQueue
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
                sql += " AND COALESCE(canonicalTarget, target) = ?"
                args.append(target)
            }

            sql += " GROUP BY observingNight, filter ORDER BY observingNight ASC"

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
                sql += " AND COALESCE(canonicalTarget, target) = ?"
                args.append(target)
            }

            sql += " GROUP BY observingNight, filter ORDER BY observingNight ASC"

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
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) as total,
                    AVG(computedFWHM) as avgFWHM,
                    AVG(CAST(computedStarCount AS REAL)) as avgStars,
                    AVG(noiseMAD) as avgNoise,
                    AVG(trailingScore) as avgTrailing,
                    SUM(CASE WHEN qualityTier = 0 THEN 1 ELSE 0 END) as trashCount,
                    MIN(observingNight) as firstNight,
                    MAX(observingNight) as lastNight
                FROM frame_record WHERE setupHash = ?
                """, arguments: [setupHash])

            guard let row, let total: Int = row["total"], total > 0 else { return nil }

            let sessionCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT sessionId) FROM frame_record WHERE setupHash = ?
                """, arguments: [setupHash]) ?? 0

            let targets = try String.fetchAll(db, sql: """
                SELECT DISTINCT target FROM frame_record
                WHERE setupHash = ? AND target IS NOT NULL
                """, arguments: [setupHash])

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
                sql += " AND COALESCE(canonicalTarget, target) = ?"
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
                    let count = (try? self.databaseStats())?.frameCount ?? 0
                    print("FrameHistoryDatabase: imported \(count) frames from iCloud")
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

            DispatchQueue.main.async { completion(importResult) }
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
}
