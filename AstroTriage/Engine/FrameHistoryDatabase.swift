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

    /// True if the existing DB file was corrupt at startup and got renamed in favor of a fresh one.
    /// The renamed file (FrameHistory.corrupt-<ts>.sqlite) stays in Application Support for manual recovery.
    private(set) var recoveredFromCorruption: Bool = false

    /// iCloud rotating-backup helper. Owns iCloud directory resolution, the
    /// export-with-rotation flow, the meta.json freshness check, and the
    /// import-and-reopen flow. Initialized from init() once self is fully
    /// set up. See FrameHistoryICloudSync.swift.
    private let icloudSync: FrameHistoryICloudSync

    private static let dbFilename = "FrameHistory.sqlite"
    private static let iCloudSubdir = "Documents/FrameHistory"
    private static let iCloudContainer = "iCloud.com.joergsflow.AstroBlinkV2"

    private init() {
        // Local: ~/Library/Application Support/AstroBlinkV2/
        // Fallback to tmp keeps init nil-safe on weird sandbox states (in practice this branch never fires).
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("AstroBlinkV2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent(Self.dbFilename)

        // Open or create database. On corruption: rename the bad file to
        // FrameHistory.corrupt-<timestamp>.sqlite and start fresh, so the app boots.
        // The renamed file is left in place for manual recovery. UI listeners can
        // observe `.frameHistoryRecoveredFromCorruption` to surface a notice.
        do {
            dbQueue = try DatabaseQueue(path: storageURL.path)
            try Self.migrate(dbQueue)
        } catch {
            let ts = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = dir.appendingPathComponent("FrameHistory.corrupt-\(ts).sqlite")
            print("FrameHistoryDatabase: failed to open existing DB (\(error)); renaming to \(backupURL.lastPathComponent) and creating fresh")
            try? FileManager.default.moveItem(at: storageURL, to: backupURL)
            do {
                dbQueue = try DatabaseQueue(path: storageURL.path)
                try Self.migrate(dbQueue)
                recoveredFromCorruption = true
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .frameHistoryRecoveredFromCorruption, object: backupURL)
                }
            } catch {
                // Fresh DB creation also failed (disk full, permissions, …) — fall back to
                // in-memory so the app at least starts. History won't persist this session.
                print("FrameHistoryDatabase: fresh DB creation failed (\(error)); using in-memory fallback")
                do {
                    dbQueue = try DatabaseQueue()
                    try Self.migrate(dbQueue)
                } catch {
                    // In-memory init failing is system-unusable territory. Keep a hard stop
                    // here so the failure mode is loud, not silently corrupted state.
                    fatalError("FrameHistoryDatabase: even in-memory init failed: \(error)")
                }
            }
        }

        // Build the iCloud helper now that storageURL + dbQueue are stable, then
        // kick off background resolution (fire-and-forget, non-blocking).
        self.icloudSync = FrameHistoryICloudSync(
            database: nil,  // patched immediately below — Swift won't allow self before this property is set
            localDBURL: storageURL,
            localDBFilename: Self.dbFilename,
            iCloudSubdir: Self.iCloudSubdir,
            containerIdentifier: Self.iCloudContainer
        )
        icloudSync.attach(database: self)
        icloudSync.startResolution()
    }

    // MARK: - iCloud Forwarders
    //
    // External callers (AstroTriageApp, ArchiveScanner, SessionOrchestrator+Scoring)
    // keep using FrameHistoryDatabase.shared.exportToICloud() etc. The bodies live
    // on FrameHistoryICloudSync; these forwarders preserve the call-site API.

    /// Register a callback for when iCloud directory resolution completes.
    /// If already resolved, callback fires immediately. Must be called from main thread.
    func onICloudResolved(_ callback: @escaping (URL?) -> Void) {
        icloudSync.onResolved(callback)
    }

    /// Export database to iCloud container with rotating backup.
    func exportToICloud() {
        icloudSync.exportToICloud()
    }

    /// Async check if iCloud has a newer/larger database than local.
    func checkICloudForNewerDBAsync(completion: @escaping ((local: FrameHistoryMeta, iCloud: FrameHistoryMeta)?) -> Void) {
        icloudSync.checkICloudForNewerDBAsync(completion: completion)
    }

    /// Import database from iCloud (replaces local DB). Call after user confirmation.
    func importFromICloudAsync(completion: @escaping (Result<Int, Error>) -> Void) {
        icloudSync.importFromICloudAsync(completion: completion)
    }

    /// Replace the local DB file with the contents at `replacingWith` and reopen
    /// the GRDB queue against the new file. Internal API used exclusively by
    /// FrameHistoryICloudSync.importFromICloudAsync — the helper can't swap the
    /// dbQueue itself because dbQueue + storageURL are private to this type.
    /// Returns the number of frame records in the freshly imported database.
    func reopenAfterImport(replacingWith readURL: URL) throws -> Int {
        try? FileManager.default.removeItem(at: storageURL)
        try FileManager.default.copyItem(at: readURL, to: storageURL)
        // Reopen database connection (old DatabaseQueue still points to deleted inode)
        dbQueue = try DatabaseQueue(path: storageURL.path)
        try Self.migrate(dbQueue)
        return (try? databaseStats())?.frameCount ?? 0
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

    /// Fetch all frame records that the user has personally rated (userConfidence > 0).
    /// These are the ground-truth labels for the curated quality-check dataset — every
    /// row here is a frame the user explicitly rated ★1/★2/★3 in Blind Curation mode.
    /// Ordered by setup, then filter, then capture time for reproducible exports.
    func curatedFrameRecords() throws -> [FrameRecord] {
        try dbQueue.read { db in
            try FrameRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM frame_record
                    WHERE userConfidence > 0
                    ORDER BY setupHash, filter, captureDate, captureTime
                    """
            )
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

        // 2. Delete iCloud backups (helper owns iCloud directory state)
        icloudSync.destroyAllData()

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

extension Notification.Name {
    /// Posted once if FrameHistoryDatabase had to recover from a corrupt SQLite file at launch.
    /// `object` is the URL of the renamed corrupt file (for manual recovery).
    static let frameHistoryRecoveredFromCorruption = Notification.Name("FrameHistoryRecoveredFromCorruption")
}
