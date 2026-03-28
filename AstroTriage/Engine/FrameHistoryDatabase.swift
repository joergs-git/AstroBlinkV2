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
    // so we resolve it asynchronously and only use it when ready.
    private var _iCloudDirectory: URL?
    private var _iCloudReady = false

    private func resolveICloudIfNeeded() {
        guard !_iCloudReady else { return }
        _iCloudReady = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.joergsflow.AstroBlinkV2") {
                let dir = container.appendingPathComponent(Self.iCloudSubdir, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                self?._iCloudDirectory = dir
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
                SELECT observingNight, target, filter,
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
                    AVG(moonDistance) as avgMoonDist
                FROM frame_record
                WHERE setupHash = ? AND observingNight IS NOT NULL
                """
            var args: [DatabaseValueConvertible] = [setupHash]

            if let target {
                sql += " AND target = ?"
                args.append(target)
            }

            sql += " GROUP BY observingNight, filter ORDER BY observingNight ASC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                NightSummary(
                    night: row["observingNight"] ?? "",
                    target: row["target"],
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
                    medianMoonDistance: row["avgMoonDist"]
                )
            }
        }
    }

    /// Per-night quality summary across ALL setups (consolidated view).
    func nightlyTrendAll(target: String? = nil) throws -> [NightSummary] {
        try dbQueue.read { db in
            var sql = """
                SELECT observingNight, target, filter,
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
                    AVG(moonDistance) as avgMoonDist
                FROM frame_record
                WHERE observingNight IS NOT NULL
                """
            var args: [DatabaseValueConvertible] = []

            if let target {
                sql += " AND target = ?"
                args.append(target)
            }

            sql += " GROUP BY observingNight, filter ORDER BY observingNight ASC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                NightSummary(
                    night: row["observingNight"] ?? "",
                    target: row["target"],
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
                    medianMoonDistance: row["avgMoonDist"]
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
        guard let iDir = _iCloudDirectory else { return }

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
        } catch {
            print("FrameHistoryDatabase: iCloud export failed: \(error)")
        }
    }

    /// Check if iCloud has a newer/larger database than local.
    /// Returns (localMeta, iCloudMeta) if iCloud has data, nil otherwise.
    func checkICloudForNewerDB() -> (local: FrameHistoryMeta, iCloud: FrameHistoryMeta)? {
        guard let iDir = _iCloudDirectory else { return nil }
        let metaURL = iDir.appendingPathComponent("FrameHistory_meta.json")

        guard let data = try? Data(contentsOf: metaURL),
              let iCloudMeta = try? JSONDecoder().decode(FrameHistoryMeta.self, from: data) else {
            return nil
        }

        // Build local metadata
        guard let localStats = try? databaseStats() else { return nil }
        let localSize = (try? FileManager.default.attributesOfItem(atPath: storageURL.path)[.size] as? Int64) ?? 0
        let localMeta = FrameHistoryMeta(
            lastModified: ISO8601DateFormatter().string(from: Date()),
            frameCount: localStats.frameCount,
            sessionCount: localStats.sessionCount,
            dbSizeBytes: localSize
        )

        // Only return if iCloud has different data
        if iCloudMeta.frameCount != localMeta.frameCount {
            return (local: localMeta, iCloud: iCloudMeta)
        }
        return nil
    }

    /// Import database from iCloud (replaces local DB). Call after user confirmation.
    func importFromICloud() throws {
        guard let iDir = _iCloudDirectory else {
            throw NSError(domain: "FrameHistoryDatabase", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "iCloud not available"])
        }
        let iCloudDB = iDir.appendingPathComponent(Self.dbFilename)
        guard FileManager.default.fileExists(atPath: iCloudDB.path) else {
            throw NSError(domain: "FrameHistoryDatabase", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No database found in iCloud"])
        }

        // Replace local with iCloud copy
        try? FileManager.default.removeItem(at: storageURL)
        try FileManager.default.copyItem(at: iCloudDB, to: storageURL)
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
