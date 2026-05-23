// Read-only access to the FrameHistory SQLite written by AstroBlinkV2.app.
//
// Opens the DB at the same path the app writes to:
//   ~/Library/Application Support/AstroBlinkV2/FrameHistory.sqlite
// (override with the ASTROBLINKV2_DB_PATH env var for development.)
//
// All access goes through PRAGMA query_only=1 so a bug here can never corrupt
// the app's data. GRDB's WAL handling lets us read concurrently with the app
// writing — there is no locking conflict for reads.
import Foundation
import GRDB

struct ReadOnlyFrameHistoryDB {
    let queue: DatabaseQueue

    init() throws {
        let path = Self.resolveDBPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "AstroBlinkMCPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "FrameHistory.sqlite not found at \(path). Open AstroBlinkV2.app once to create it, or set ASTROBLINKV2_DB_PATH."])
        }
        var config = Configuration()
        config.readonly = true
        self.queue = try DatabaseQueue(path: path, configuration: config)
    }

    static func resolveDBPath() -> String {
        if let env = ProcessInfo.processInfo.environment["ASTROBLINKV2_DB_PATH"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        let fm = FileManager.default

        // AstroBlinkV2.app is sandboxed, so its "Application Support" lives inside
        // the app's container — NOT the user's bare ~/Library/Application Support.
        // The MCP server (a non-sandboxed CLI tool) has to read from the container
        // path explicitly. Try the sandboxed location first; fall back to the
        // non-sandboxed path so unit tests / fresh installs / dev builds still work.
        let home = NSString(string: "~").expandingTildeInPath
        let sandboxed = home
            + "/Library/Containers/com.joergsflow.AstroBlinkV2/Data/Library/Application Support/AstroBlinkV2/FrameHistory.sqlite"
        if fm.fileExists(atPath: sandboxed) { return sandboxed }

        let userScope = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AstroBlinkV2", isDirectory: true)
            .appendingPathComponent("FrameHistory.sqlite")
        return userScope.path
    }

    // MARK: - Astro Roots

    func listAstroRoots() throws -> [MCPAstroRoot] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, setupTag, nickname, createdAt, lastUsedAt
                FROM astro_root
                ORDER BY createdAt ASC
                """)
            return rows.map { row in
                let nickname: String? = row["nickname"]
                let setupTag: String? = row["setupTag"]
                let path: String = row["path"]
                let display = nickname?.isEmpty == false ? nickname! :
                              (setupTag?.isEmpty == false ? setupTag! :
                              (path as NSString).lastPathComponent)
                return MCPAstroRoot(
                    id: row["id"], path: path,
                    setupTag: setupTag, nickname: nickname, displayName: display,
                    createdAt: row["createdAt"], lastUsedAt: row["lastUsedAt"]
                )
            }
        }
    }

    // MARK: - Setups

    func listSetups() throws -> [MCPSetup] {
        try queue.read { db in
            // Aggregate from frame_record so a fresh DB without explicit setup_nickname
            // rows still returns useful entries. LEFT JOIN to enrich with nicknames.
            // FL is computed as the MEDIAN per setupHash (not AVG) so noisy
            // plate-solve values and user FL overrides don't blur the value
            // — the app exposes a "Fix Focal Length" override that rewrites
            // all frames in a setup, and median honors that bulk update.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    f.setupHash,
                    sn.nickname AS nickname,
                    MIN(f.telescope) AS telescope,
                    MIN(f.camera) AS camera,
                    COUNT(*) AS frameCount,
                    MIN(f.observingNight) AS firstNight,
                    MAX(f.observingNight) AS lastNight
                FROM frame_record f
                LEFT JOIN setup_nickname sn ON sn.setupHash = f.setupHash
                WHERE f.setupHash IS NOT NULL
                GROUP BY f.setupHash
                ORDER BY lastNight DESC
                """)
            return try rows.map { row in
                let setupHash: String = row["setupHash"]
                let fl = try Self.medianFocalLength(db: db, setupHash: setupHash)
                return MCPSetup(
                    setupHash: setupHash,
                    nickname: row["nickname"],
                    telescope: row["telescope"],
                    camera: row["camera"],
                    focalLengthMm: fl,
                    frameCount: row["frameCount"],
                    firstNight: row["firstNight"],
                    lastNight: row["lastNight"]
                )
            }
        }
    }

    private static func medianFocalLength(db: Database, setupHash: String) throws -> Double? {
        let vals = try Double.fetchAll(db,
            sql: "SELECT focalLength FROM frame_record WHERE setupHash = ? AND focalLength IS NOT NULL ORDER BY focalLength",
            arguments: [setupHash])
        return Self.medianOf(vals)
    }

    func setupSummary(setupHash: String) throws -> MCPSetupSummary? {
        try queue.read { db in
            let stats = try Row.fetchOne(db, sql: """
                SELECT
                    f.setupHash,
                    sn.nickname,
                    MIN(f.telescope) AS telescope,
                    MIN(f.camera) AS camera,
                    COUNT(*) AS totalFrames,
                    COUNT(DISTINCT f.sessionId) AS sessionCount,
                    COUNT(DISTINCT f.canonicalTarget) AS distinctTargets,
                    MIN(f.observingNight) AS firstNight,
                    MAX(f.observingNight) AS lastNight
                FROM frame_record f
                LEFT JOIN setup_nickname sn ON sn.setupHash = f.setupHash
                WHERE f.setupHash = ?
                GROUP BY f.setupHash
                """, arguments: [setupHash])
            guard let row = stats else { return nil }
            let median = try Self.medianMetrics(db: db, setupHash: setupHash)
            let trashRate = try Self.trashRate(db: db, setupHash: setupHash)
            let fl = try Self.medianFocalLength(db: db, setupHash: setupHash)
            return MCPSetupSummary(
                setupHash: row["setupHash"],
                nickname: row["nickname"],
                telescope: row["telescope"],
                camera: row["camera"],
                focalLengthMm: fl,
                totalFrames: row["totalFrames"],
                sessionCount: row["sessionCount"],
                distinctTargets: row["distinctTargets"],
                firstNight: row["firstNight"],
                lastNight: row["lastNight"],
                medianFWHM: median.fwhm,
                medianHFR: median.hfr,
                trashRatePct: trashRate
            )
        }
    }

    private static func medianMetrics(db: Database, setupHash: String) throws -> (fwhm: Double?, hfr: Double?) {
        // SQLite has no MEDIAN; use the avg-of-middle-two from sorted in-Swift values.
        // Frame counts per setup are typically <50k so in-memory sort is fine.
        let fwhms = try Double.fetchAll(db,
            sql: "SELECT computedFWHM FROM frame_record WHERE setupHash = ? AND computedFWHM IS NOT NULL ORDER BY computedFWHM",
            arguments: [setupHash])
        let hfrs = try Double.fetchAll(db,
            sql: "SELECT computedHFR FROM frame_record WHERE setupHash = ? AND computedHFR IS NOT NULL ORDER BY computedHFR",
            arguments: [setupHash])
        return (Self.medianOf(fwhms), Self.medianOf(hfrs))
    }

    private static func trashRate(db: Database, setupHash: String) throws -> Double {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_record WHERE setupHash = ?",
                                     arguments: [setupHash]) ?? 0
        guard total > 0 else { return 0 }
        let trash = try Int.fetchOne(db,
            sql: "SELECT COUNT(*) FROM frame_record WHERE setupHash = ? AND qualityTier = 0",
            arguments: [setupHash]) ?? 0
        return (Double(trash) / Double(total)) * 100.0
    }

    private static func medianOf(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let n = values.count
        if n.isMultiple(of: 2) { return (values[n/2 - 1] + values[n/2]) / 2 }
        return values[n/2]
    }

    // MARK: - Nights

    func availableNights(setupHash: String? = nil, target: String? = nil) throws -> [String] {
        try queue.read { db in
            var sql = "SELECT DISTINCT observingNight FROM frame_record WHERE observingNight IS NOT NULL"
            var args: [DatabaseValueConvertible] = []
            if let s = setupHash { sql += " AND setupHash = ?"; args.append(s) }
            if let t = target { sql += " AND canonicalTarget = ?"; args.append(t) }
            sql += " ORDER BY observingNight DESC"
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func nightSummary(date: String, setupHash: String? = nil, target: String? = nil) throws -> [MCPNightSummary] {
        try queue.read { db in
            var where_ = "observingNight = ?"
            var args: [DatabaseValueConvertible] = [date]
            if let s = setupHash { where_ += " AND setupHash = ?"; args.append(s) }
            if let t = target { where_ += " AND canonicalTarget = ?"; args.append(t) }
            // Per-(target, filter) aggregate. Median computed in Swift below.
            let groups = try Row.fetchAll(db, sql: """
                SELECT
                    canonicalTarget AS target,
                    filter,
                    COUNT(*) AS frameCount,
                    SUM(CASE WHEN qualityTier = 0 THEN 1 ELSE 0 END) AS trashCount,
                    SUM(exposure) AS totalIntegrationSeconds,
                    AVG(ambientTemp) AS medianAmbientTemp,
                    AVG(moonIllumination) AS medianMoonIllumination
                FROM frame_record
                WHERE \(where_)
                GROUP BY canonicalTarget, filter
                ORDER BY filter
                """, arguments: StatementArguments(args))
            var result: [MCPNightSummary] = []
            for g in groups {
                let target: String? = g["target"]
                let filter: String? = g["filter"]
                let extra = try Self.medianForNightFilter(db: db, where_: where_, args: args,
                                                         target: target, filter: filter)
                result.append(MCPNightSummary(
                    night: date,
                    target: target,
                    filter: filter,
                    frameCount: g["frameCount"],
                    trashCount: g["trashCount"],
                    medianFWHM: extra.fwhm,
                    medianHFR: extra.hfr,
                    medianStars: extra.stars,
                    medianNoiseMAD: extra.noise,
                    medianTrailing: extra.trailing,
                    totalIntegrationSeconds: (g["totalIntegrationSeconds"] as Double?) ?? 0,
                    medianAmbientTemp: g["medianAmbientTemp"],
                    medianMoonIllumination: g["medianMoonIllumination"]
                ))
            }
            return result
        }
    }

    private static func medianForNightFilter(
        db: Database, where_: String, args: [DatabaseValueConvertible],
        target: String?, filter: String?
    ) throws -> (fwhm: Double?, hfr: Double?, stars: Int?, noise: Double?, trailing: Double?) {
        var w = where_
        var a = args
        if let t = target { w += " AND canonicalTarget = ?"; a.append(t) } else { w += " AND canonicalTarget IS NULL" }
        if let f = filter { w += " AND filter = ?"; a.append(f) } else { w += " AND filter IS NULL" }
        func median<T>(_ col: String) throws -> [T] where T: DatabaseValueConvertible {
            try T.fetchAll(db,
                sql: "SELECT \(col) FROM frame_record WHERE \(w) AND \(col) IS NOT NULL ORDER BY \(col)",
                arguments: StatementArguments(a))
        }
        let fwhmVals: [Double] = try median("computedFWHM")
        let hfrVals: [Double] = try median("computedHFR")
        let starVals: [Double] = try median("computedStarCount")  // INTEGER → fetched as Double for median math
        let noiseVals: [Double] = try median("noiseMAD")
        let trailVals: [Double] = try median("trailingScore")
        let starMedian: Int? = Self.medianOf(starVals).map { Int($0.rounded()) }
        return (Self.medianOf(fwhmVals), Self.medianOf(hfrVals), starMedian,
                Self.medianOf(noiseVals), Self.medianOf(trailVals))
    }

    // MARK: - Sessions

    func recentSessions(limit: Int, setupHash: String? = nil) throws -> [MCPSession] {
        try queue.read { db in
            var sql = "SELECT * FROM session_record"
            var args: [DatabaseValueConvertible] = []
            if let s = setupHash { sql += " WHERE setupHash = ?"; args.append(s) }
            sql += " ORDER BY recordedAt DESC LIMIT ?"
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { r in
                MCPSession(
                    id: r["id"], observingNight: r["observingNight"], setupHash: r["setupHash"],
                    telescope: r["telescope"], camera: r["camera"], target: r["target"],
                    frameCount: r["frameCount"], trashCount: r["trashCount"],
                    deletedCount: r["deletedCount"], recordedAt: r["recordedAt"]
                )
            }
        }
    }

    // MARK: - Target Integration

    func targetIntegration(target: String) throws -> [MCPTargetIntegration] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    filter,
                    SUM(exposure) AS totalSeconds,
                    COUNT(*) AS frameCount,
                    SUM(CASE WHEN qualityTier >= 2 AND wasDeleted = 0 THEN 1 ELSE 0 END) AS goodOrExcellentCount
                FROM frame_record
                WHERE canonicalTarget = ? AND wasDeleted = 0
                GROUP BY filter
                ORDER BY totalSeconds DESC
                """, arguments: [target])
            return rows.map { r in
                let secs: Double = (r["totalSeconds"] as Double?) ?? 0
                return MCPTargetIntegration(
                    filter: (r["filter"] as String?) ?? "(none)",
                    totalSeconds: secs,
                    totalMinutes: secs / 60.0,
                    totalHours: secs / 3600.0,
                    frameCount: r["frameCount"],
                    goodOrExcellentCount: r["goodOrExcellentCount"]
                )
            }
        }
    }

    // MARK: - MCP Command Status (polling)

    /// Read the latest state of an MCP command launched via the astroblink:// URL scheme.
    /// Returns nil if no row exists yet (handler hasn't fired). Returns the full row
    /// once the app's handler has inserted it; the caller polls until state ∈
    /// {completed, failed} or a timeout elapses.
    func commandStatus(commandId: String) throws -> (state: String, progressCurrent: Int?, progressTotal: Int?, resultSummary: String?, errorMessage: String?)? {
        try queue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT state, progressCurrent, progressTotal, resultSummary, errorMessage FROM mcp_command_status WHERE commandId = ?",
                arguments: [commandId])
            else { return nil }
            return (
                state: row["state"],
                progressCurrent: row["progressCurrent"],
                progressTotal: row["progressTotal"],
                resultSummary: row["resultSummary"],
                errorMessage: row["errorMessage"]
            )
        }
    }

    // MARK: - Frames

    func frames(night: String? = nil, target: String? = nil, filter: String? = nil,
                qualityMin: Int? = nil, setupHash: String? = nil,
                limit: Int = 500) throws -> [MCPFrame] {
        try queue.read { db in
            var where_ = "1=1"
            var args: [DatabaseValueConvertible] = []
            if let n = night { where_ += " AND observingNight = ?"; args.append(n) }
            if let t = target { where_ += " AND canonicalTarget = ?"; args.append(t) }
            if let f = filter { where_ += " AND filter = ?"; args.append(f) }
            if let q = qualityMin { where_ += " AND qualityTier >= ?"; args.append(q) }
            if let s = setupHash { where_ += " AND setupHash = ?"; args.append(s) }
            let sql = """
                SELECT fileHash, shortId, filename, filePath, observingNight,
                       canonicalTarget AS target, filter, exposure, setupHash,
                       qualityTier, combinedZScore, computedFWHM, computedHFR,
                       computedStarCount, trailingScore, garbageReasons,
                       wasDeleted, isLockedKeep
                FROM frame_record
                WHERE \(where_)
                ORDER BY observingNight DESC, captureTime DESC
                LIMIT ?
                """
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { r in
                MCPFrame(
                    fileHash: r["fileHash"], shortId: r["shortId"],
                    filename: r["filename"], filePath: r["filePath"],
                    observingNight: r["observingNight"], target: r["target"],
                    filter: r["filter"], exposure: r["exposure"],
                    setupHash: r["setupHash"], qualityTier: r["qualityTier"],
                    combinedZScore: r["combinedZScore"], computedFWHM: r["computedFWHM"],
                    computedHFR: r["computedHFR"], computedStarCount: r["computedStarCount"],
                    trailingScore: r["trailingScore"], garbageReasons: r["garbageReasons"],
                    wasDeleted: (r["wasDeleted"] as Int? ?? 0) != 0,
                    isLockedKeep: (r["isLockedKeep"] as Int? ?? 0) != 0
                )
            }
        }
    }
}
