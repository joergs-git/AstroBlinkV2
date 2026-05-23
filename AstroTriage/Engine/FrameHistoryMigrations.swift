// GRDB schema migrations for FrameHistoryDatabase.
// Pure DDL — no instance state, called from FrameHistoryDatabase.init() and
// importFromICloudAsync() after replacing the local file. Add new migrations
// at the bottom; never edit existing ones (would break already-migrated DBs).
import Foundation
import GRDB

extension FrameHistoryDatabase {

    static func migrate(_ db: DatabaseQueue) throws {
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

        // v10: MCP integration scaffolding.
        //   astro_root          — user-configured default folders containing astro files,
        //                         resolvable by an external MCP server via list_astro_roots.
        //                         bookmark column stores a security-scoped bookmark so the
        //                         app can re-access the folder without re-prompting.
        //   mcp_command_status  — async rendezvous table. MCP server inserts a row with a
        //                         fresh command_id, fires a URL-scheme verb on the app,
        //                         then polls this row until state == "completed"|"failed".
        migrator.registerMigration("v10_mcp_integration") { db in
            try db.create(table: "astro_root") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob)
                t.column("setupTag", .text)
                t.column("nickname", .text)
                t.column("createdAt", .text).notNull()
                t.column("lastUsedAt", .text)
            }

            try db.create(table: "mcp_command_status") { t in
                t.primaryKey("commandId", .text).notNull()
                t.column("verb", .text).notNull()
                t.column("state", .text).notNull()
                t.column("startedAt", .text)
                t.column("completedAt", .text)
                t.column("progressCurrent", .integer)
                t.column("progressTotal", .integer)
                t.column("resultSummary", .text)
                t.column("errorMessage", .text)
            }
            try db.create(index: "idx_mcp_status_state", on: "mcp_command_status", columns: ["state"])
        }

        try migrator.migrate(db)
    }
}
