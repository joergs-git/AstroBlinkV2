// MCP-specific query methods on FrameHistoryDatabase.
//
// Returns plain Codable structs so MCPToolRegistry can JSON-encode them
// without leaking the app's internal model types into the wire format.
import Foundation
import GRDB

// MARK: - Result models

struct MCPSetupRow: Codable {
    let setupHash: String
    let nickname: String?
    let telescope: String?
    let camera: String?
    let focalLengthMm: Double?
    let frameCount: Int
    let firstNight: String?
    let lastNight: String?
}

struct MCPNightSummaryRow: Codable {
    let night: String
    let target: String?
    let filter: String?
    let frameCount: Int
    let trashCount: Int
    let medianFWHM: Double?
    let medianHFR: Double?
    let medianStars: Int?
    let medianNoiseMAD: Double?
    let medianTrailing: Double?
    let totalIntegrationSeconds: Double
    let medianAmbientTemp: Double?
    let medianMoonIllumination: Double?
}

struct MCPSessionRow: Codable {
    let id: String
    let observingNight: String?
    let setupHash: String?
    let telescope: String?
    let camera: String?
    let target: String?
    let frameCount: Int
    let trashCount: Int
    let deletedCount: Int
    let recordedAt: String
}

struct MCPSetupSummaryRow: Codable {
    let setupHash: String
    let nickname: String?
    let telescope: String?
    let camera: String?
    let focalLengthMm: Double?
    let totalFrames: Int
    let sessionCount: Int
    let distinctTargets: Int
    let firstNight: String?
    let lastNight: String?
    let medianFWHM: Double?
    let medianHFR: Double?
    let trashRatePct: Double
}

struct MCPTargetIntegrationRow: Codable {
    let filter: String
    let totalSeconds: Double
    let totalMinutes: Double
    let totalHours: Double
    let frameCount: Int
    let goodOrExcellentCount: Int
}

struct MCPFrameRow: Codable {
    let fileHash: String
    let shortId: String?
    let filename: String
    let filePath: String
    let observingNight: String?
    let target: String?
    let filter: String?
    let exposure: Double?
    let setupHash: String?
    let qualityTier: Int?
    let combinedZScore: Double?
    let computedFWHM: Double?
    let computedHFR: Double?
    let computedStarCount: Int?
    let trailingScore: Double?
    let garbageReasons: String?
    let wasDeleted: Bool
    let isLockedKeep: Bool
}

struct MCPQualitySummary: Codable {
    let scope: String
    let totalFrames: Int
    let perFilter: [PerFilterStats]
    let qualityTierCounts: [String: Int]
    let topGarbageReasons: [GarbageReasonCount]
    let topWorstFrames: [WorstFrame]

    struct PerFilterStats: Codable {
        let filter: String
        let frameCount: Int
        let trashCount: Int
        let medianFWHM: Double?
        let medianHFR: Double?
        let medianStars: Int?
        let totalIntegrationSeconds: Double
    }
    struct GarbageReasonCount: Codable {
        let reason: String
        let count: Int
    }
    struct WorstFrame: Codable {
        let filename: String
        let observingNight: String?
        let filter: String?
        let combinedZScore: Double?
        let garbageReasons: String?
    }
}

struct MCPFilterAdvice: Codable {
    let target: String
    let perFilter: [PerFilterIntegration]
    let recommendedNext: String?
    let notes: String
    struct PerFilterIntegration: Codable {
        let filter: String
        let totalHours: Double
        let goodOrExcellentHours: Double
        let frameCount: Int
    }
}

// MARK: - FrameHistoryDatabase extension

extension FrameHistoryDatabase {

    /// All known equipment setups with metadata. FL is median per setupHash so
    /// noisy plate-solves / user FL overrides don't blur the value.
    func listSetupsForMCP() throws -> [MCPSetupRow] {
        try queueForMCPRead().read { db in
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
                return MCPSetupRow(
                    setupHash: setupHash,
                    nickname: row["nickname"],
                    telescope: row["telescope"],
                    camera: row["camera"],
                    focalLengthMm: try Self.medianFocalLength(db: db, setupHash: setupHash),
                    frameCount: row["frameCount"],
                    firstNight: row["firstNight"],
                    lastNight: row["lastNight"]
                )
            }
        }
    }

    func setupSummaryForMCP(setupHash: String) throws -> MCPSetupSummaryRow? {
        try queueForMCPRead().read { db in
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
            let trashRate = try Self.trashRatePct(db: db, setupHash: setupHash)
            let fl = try Self.medianFocalLength(db: db, setupHash: setupHash)
            return MCPSetupSummaryRow(
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

    func availableNightsForMCP(setupHash: String?, target: String?) throws -> [String] {
        try queueForMCPRead().read { db in
            var sql = "SELECT DISTINCT observingNight FROM frame_record WHERE observingNight IS NOT NULL"
            var args: [DatabaseValueConvertible] = []
            if let s = setupHash { sql += " AND setupHash = ?"; args.append(s) }
            if let t = target { sql += " AND canonicalTarget = ?"; args.append(t) }
            sql += " ORDER BY observingNight DESC"
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func nightSummaryForMCP(date: String, setupHash: String?, target: String?) throws -> [MCPNightSummaryRow] {
        try queueForMCPRead().read { db in
            var where_ = "observingNight = ?"
            var args: [DatabaseValueConvertible] = [date]
            if let s = setupHash { where_ += " AND setupHash = ?"; args.append(s) }
            if let t = target { where_ += " AND canonicalTarget = ?"; args.append(t) }
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
            return try groups.map { g in
                let t: String? = g["target"]
                let f: String? = g["filter"]
                let extra = try Self.medianMetricsForNightFilter(
                    db: db, baseWhere: where_, baseArgs: args, target: t, filter: f)
                return MCPNightSummaryRow(
                    night: date, target: t, filter: f,
                    frameCount: g["frameCount"], trashCount: g["trashCount"],
                    medianFWHM: extra.fwhm, medianHFR: extra.hfr, medianStars: extra.stars,
                    medianNoiseMAD: extra.noise, medianTrailing: extra.trailing,
                    totalIntegrationSeconds: (g["totalIntegrationSeconds"] as Double?) ?? 0,
                    medianAmbientTemp: g["medianAmbientTemp"],
                    medianMoonIllumination: g["medianMoonIllumination"]
                )
            }
        }
    }

    func recentSessionsForMCP(limit: Int, setupHash: String?) throws -> [MCPSessionRow] {
        try queueForMCPRead().read { db in
            var sql = "SELECT * FROM session_record"
            var args: [DatabaseValueConvertible] = []
            if let s = setupHash { sql += " WHERE setupHash = ?"; args.append(s) }
            sql += " ORDER BY recordedAt DESC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { r in
                MCPSessionRow(
                    id: r["id"], observingNight: r["observingNight"], setupHash: r["setupHash"],
                    telescope: r["telescope"], camera: r["camera"], target: r["target"],
                    frameCount: r["frameCount"], trashCount: r["trashCount"],
                    deletedCount: r["deletedCount"], recordedAt: r["recordedAt"]
                )
            }
        }
    }

    func targetIntegrationForMCP(target: String) throws -> [MCPTargetIntegrationRow] {
        try queueForMCPRead().read { db in
            try Row.fetchAll(db, sql: """
                SELECT
                    filter,
                    SUM(exposure) AS totalSeconds,
                    COUNT(*) AS frameCount,
                    SUM(CASE WHEN qualityTier >= 2 AND wasDeleted = 0 THEN 1 ELSE 0 END) AS goodOrExcellentCount
                FROM frame_record
                WHERE canonicalTarget = ? AND wasDeleted = 0
                GROUP BY filter
                ORDER BY totalSeconds DESC
                """, arguments: [target]).map { r in
                let s: Double = (r["totalSeconds"] as Double?) ?? 0
                return MCPTargetIntegrationRow(
                    filter: (r["filter"] as String?) ?? "(none)",
                    totalSeconds: s, totalMinutes: s / 60, totalHours: s / 3600,
                    frameCount: r["frameCount"], goodOrExcellentCount: r["goodOrExcellentCount"]
                )
            }
        }
    }

    func framesForMCP(night: String?, target: String?, filter: String?, qualityMin: Int?, setupHash: String?, limit: Int) throws -> [MCPFrameRow] {
        try queueForMCPRead().read { db in
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
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { r in
                MCPFrameRow(
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

    func qualitySummaryForMCP(setupHash: String?, night: String?, sessionId: String?) throws -> MCPQualitySummary {
        try queueForMCPRead().read { db in
            var where_ = "1=1"
            var args: [DatabaseValueConvertible] = []
            if let s = setupHash { where_ += " AND setupHash = ?"; args.append(s) }
            if let n = night { where_ += " AND observingNight = ?"; args.append(n) }
            if let sid = sessionId { where_ += " AND sessionId = ?"; args.append(sid) }

            let scope: String = sessionId.map { "session:\($0)" }
                ?? night.map { "night:\($0)" }
                ?? setupHash.map { "setup:\($0.prefix(8))" }
                ?? "global"

            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_record WHERE \(where_)",
                                         arguments: StatementArguments(args)) ?? 0

            let perFilterRows = try Row.fetchAll(db, sql: """
                SELECT filter,
                       COUNT(*) AS frameCount,
                       SUM(CASE WHEN qualityTier = 0 THEN 1 ELSE 0 END) AS trashCount,
                       SUM(exposure) AS integration
                FROM frame_record WHERE \(where_)
                GROUP BY filter ORDER BY frameCount DESC
                """, arguments: StatementArguments(args))
            var perFilter: [MCPQualitySummary.PerFilterStats] = []
            for r in perFilterRows {
                let f = (r["filter"] as String?) ?? "(none)"
                var w = where_
                var a = args
                if let fv = (r["filter"] as String?) { w += " AND filter = ?"; a.append(fv) }
                else { w += " AND filter IS NULL" }
                func med(_ col: String) -> [Double] {
                    (try? Double.fetchAll(db,
                        sql: "SELECT \(col) FROM frame_record WHERE \(w) AND \(col) IS NOT NULL ORDER BY \(col)",
                        arguments: StatementArguments(a))) ?? []
                }
                perFilter.append(.init(
                    filter: f, frameCount: r["frameCount"], trashCount: r["trashCount"],
                    medianFWHM: Self.medianOf(med("computedFWHM")),
                    medianHFR: Self.medianOf(med("computedHFR")),
                    medianStars: Self.medianOf(med("computedStarCount")).map { Int($0.rounded()) },
                    totalIntegrationSeconds: (r["integration"] as Double?) ?? 0
                ))
            }

            let tierRows = try Row.fetchAll(db, sql: """
                SELECT qualityTier, COUNT(*) AS c FROM frame_record WHERE \(where_) GROUP BY qualityTier
                """, arguments: StatementArguments(args))
            var tierCounts: [String: Int] = [:]
            for r in tierRows {
                let label: String
                switch r["qualityTier"] as Int? ?? -1 {
                case 0: label = "trash"
                case 1: label = "borderline"
                case 2: label = "good"
                case 3: label = "excellent"
                case 4: label = "uncertain"
                default: label = "unscored"
                }
                tierCounts[label] = r["c"]
            }

            // Parse garbageReasons (JSON-encoded arrays) and accumulate token counts.
            var reasonCounts: [String: Int] = [:]
            let reasonRows = try Row.fetchAll(db, sql: """
                SELECT garbageReasons FROM frame_record
                WHERE \(where_) AND qualityTier = 0 AND garbageReasons IS NOT NULL
                """, arguments: StatementArguments(args))
            for r in reasonRows {
                guard let raw = r["garbageReasons"] as String?,
                      let data = raw.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { continue }
                for tok in Set(arr) where !tok.isEmpty { reasonCounts[tok, default: 0] += 1 }
            }
            let topReasons = reasonCounts.sorted { $0.value > $1.value }
                .prefix(10)
                .map { MCPQualitySummary.GarbageReasonCount(reason: $0.key, count: $0.value) }

            let worstRows = try Row.fetchAll(db, sql: """
                SELECT filename, observingNight, filter, combinedZScore, garbageReasons
                FROM frame_record
                WHERE \(where_) AND combinedZScore IS NOT NULL
                ORDER BY combinedZScore ASC LIMIT 10
                """, arguments: StatementArguments(args))
            let worst = worstRows.map { r in
                MCPQualitySummary.WorstFrame(
                    filename: r["filename"], observingNight: r["observingNight"],
                    filter: r["filter"], combinedZScore: r["combinedZScore"],
                    garbageReasons: r["garbageReasons"]
                )
            }

            return MCPQualitySummary(
                scope: scope, totalFrames: total,
                perFilter: perFilter, qualityTierCounts: tierCounts,
                topGarbageReasons: Array(topReasons),
                topWorstFrames: worst
            )
        }
    }

    func filterAdviceForMCP(target: String) throws -> MCPFilterAdvice {
        try queueForMCPRead().read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT filter,
                       SUM(exposure) AS totalSec,
                       SUM(CASE WHEN qualityTier >= 2 AND wasDeleted = 0 THEN exposure ELSE 0 END) AS keepSec,
                       COUNT(*) AS frameCount
                FROM frame_record
                WHERE canonicalTarget = ? AND wasDeleted = 0
                GROUP BY filter
                """, arguments: [target])
            let perFilter = rows.map { r in
                MCPFilterAdvice.PerFilterIntegration(
                    filter: (r["filter"] as String?) ?? "(none)",
                    totalHours: (((r["totalSec"] as Double?) ?? 0) / 3600),
                    goodOrExcellentHours: (((r["keepSec"] as Double?) ?? 0) / 3600),
                    frameCount: r["frameCount"]
                )
            }
            let candidates = perFilter
                .filter { $0.filter != "(none)" && $0.goodOrExcellentHours < 5.0 }
                .sorted { $0.goodOrExcellentHours < $1.goodOrExcellentHours }
            let recommended = candidates.first?.filter
            let notes: String
            if perFilter.isEmpty {
                notes = "No history for this target. Anything is a good first choice."
            } else if let r = recommended {
                notes = "Suggest \(r): \(String(format: "%.1f", candidates.first!.goodOrExcellentHours))h kept so far, below the 5h heuristic threshold."
            } else {
                notes = "All filters already have ≥5h of kept integration. Consider improving SNR on the weakest channel or moving to a new target."
            }
            return MCPFilterAdvice(target: target, perFilter: perFilter, recommendedNext: recommended, notes: notes)
        }
    }

    // MARK: - Private helpers (file-internal so the public extension stays clean)

    /// The extension lives in the AstroTriage target alongside FrameHistoryDatabase
    /// so it can reach the private dbQueue via this thin shim.
    fileprivate func queueForMCPRead() -> DatabaseQueue {
        // Same connection the rest of the app uses — GRDB's WAL mode means
        // concurrent reads here don't block scoring writes elsewhere.
        // dbQueue is private to the type; this extension is in the same
        // target so we use a small internal accessor.
        return Self.sharedQueueForMCPHack
    }

    /// Set by the FrameHistoryDatabase initializer on first access. The hack:
    /// we need the queue accessible from this file, but don't want to widen
    /// `dbQueue` to internal globally. Init grabs a reference into this static.
    fileprivate static var sharedQueueForMCPHack: DatabaseQueue {
        // Trigger initialization if needed, then expose via the helper static.
        _ = FrameHistoryDatabase.shared
        return MCPDBQueueAccess.queue!
    }

    fileprivate static func medianFocalLength(db: Database, setupHash: String) throws -> Double? {
        let vals = try Double.fetchAll(db,
            sql: "SELECT focalLength FROM frame_record WHERE setupHash = ? AND focalLength IS NOT NULL ORDER BY focalLength",
            arguments: [setupHash])
        return medianOf(vals)
    }

    fileprivate static func medianMetrics(db: Database, setupHash: String) throws -> (fwhm: Double?, hfr: Double?) {
        let fwhms = try Double.fetchAll(db,
            sql: "SELECT computedFWHM FROM frame_record WHERE setupHash = ? AND computedFWHM IS NOT NULL ORDER BY computedFWHM",
            arguments: [setupHash])
        let hfrs = try Double.fetchAll(db,
            sql: "SELECT computedHFR FROM frame_record WHERE setupHash = ? AND computedHFR IS NOT NULL ORDER BY computedHFR",
            arguments: [setupHash])
        return (medianOf(fwhms), medianOf(hfrs))
    }

    fileprivate static func trashRatePct(db: Database, setupHash: String) throws -> Double {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_record WHERE setupHash = ?",
                                     arguments: [setupHash]) ?? 0
        guard total > 0 else { return 0 }
        let trash = try Int.fetchOne(db,
            sql: "SELECT COUNT(*) FROM frame_record WHERE setupHash = ? AND qualityTier = 0",
            arguments: [setupHash]) ?? 0
        return (Double(trash) / Double(total)) * 100
    }

    fileprivate static func medianMetricsForNightFilter(
        db: Database, baseWhere: String, baseArgs: [DatabaseValueConvertible],
        target: String?, filter: String?
    ) throws -> (fwhm: Double?, hfr: Double?, stars: Int?, noise: Double?, trailing: Double?) {
        var w = baseWhere
        var a = baseArgs
        if let t = target { w += " AND canonicalTarget = ?"; a.append(t) } else { w += " AND canonicalTarget IS NULL" }
        if let f = filter { w += " AND filter = ?"; a.append(f) } else { w += " AND filter IS NULL" }
        func fetch<T: DatabaseValueConvertible>(_ col: String) throws -> [T] {
            try T.fetchAll(db,
                sql: "SELECT \(col) FROM frame_record WHERE \(w) AND \(col) IS NOT NULL ORDER BY \(col)",
                arguments: StatementArguments(a))
        }
        let fwhmVals: [Double] = try fetch("computedFWHM")
        let hfrVals: [Double] = try fetch("computedHFR")
        let starVals: [Double] = try fetch("computedStarCount")
        let noiseVals: [Double] = try fetch("noiseMAD")
        let trailVals: [Double] = try fetch("trailingScore")
        let stars = medianOf(starVals).map { Int($0.rounded()) }
        return (medianOf(fwhmVals), medianOf(hfrVals), stars, medianOf(noiseVals), medianOf(trailVals))
    }

    fileprivate static func medianOf(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let n = values.count
        if n.isMultiple(of: 2) { return (values[n/2 - 1] + values[n/2]) / 2 }
        return values[n/2]
    }
}

/// Hack to surface the private dbQueue across the FrameHistoryDatabase+MCP
/// extension files. `FrameHistoryDatabase.init()` stores its queue here once;
/// subsequent reads use it directly. Set ONLY by `FrameHistoryDatabase.init`.
enum MCPDBQueueAccess {
    static var queue: DatabaseQueue?
}
