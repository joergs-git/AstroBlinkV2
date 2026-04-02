import XCTest
import GRDB
@testable import AstroTriage

final class FrameHistoryDatabaseTests: XCTestCase {

    // Use a temporary in-memory or file-based DB for each test
    private var testDB: DatabaseQueue!
    private var testDBPath: String!

    override func setUp() {
        super.setUp()
        testDBPath = NSTemporaryDirectory() + "test_frame_history_\(UUID().uuidString).sqlite"
        testDB = try! DatabaseQueue(path: testDBPath)
        // Run migrations on test DB
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "frame_record") { t in
                t.primaryKey("fileHash", .text).notNull()
                t.column("shortId", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("observingNight", .text)
                t.column("captureDate", .text)
                t.column("captureTime", .text)
                t.column("sessionId", .text).notNull()
                t.column("telescope", .text)
                t.column("camera", .text)
                t.column("focalLength", .double)
                t.column("pixelSizeMicrons", .double)
                t.column("setupHash", .text)
                t.column("target", .text)
                t.column("filter", .text)
                t.column("exposure", .double)
                t.column("gain", .integer)
                t.column("offsetVal", .integer)
                t.column("binning", .text)
                t.column("pierSide", .text)
                t.column("rotatorAngle", .double)
                t.column("mount", .text)
                t.column("computedFWHM", .double)
                t.column("computedHFR", .double)
                t.column("computedStarCount", .integer)
                t.column("computedEccentricity", .double)
                t.column("noiseMedian", .double)
                t.column("noiseMAD", .double)
                t.column("trailingScore", .double)
                t.column("trailingPA", .double)
                t.column("trailingConsensus", .double)
                t.column("trailingAxisRatio", .double)
                t.column("starChainFraction", .double)
                t.column("sensorTemp", .double)
                t.column("focuserTemp", .double)
                t.column("ambientTemp", .double)
                t.column("twilightPhase", .text)
                t.column("moonIllumination", .double)
                t.column("moonDistance", .double)
                t.column("qualityTier", .integer)
                t.column("combinedZScore", .double)
                t.column("garbageReasons", .text)
                t.column("isLockedKeep", .integer).notNull().defaults(to: 0)
                t.column("filterTrailingMultiplier", .double)
                t.column("wasDeleted", .integer).notNull().defaults(to: 0)
                t.column("algorithmVersion", .integer).notNull().defaults(to: 1)
                t.column("recordedAt", .text).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
            }
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
        }
        try! migrator.migrate(testDB)
    }

    override func tearDown() {
        testDB = nil
        try? FileManager.default.removeItem(atPath: testDBPath)
        super.tearDown()
    }

    // MARK: - Helper

    private func makeRecord(
        hash: String = "abc123",
        filename: String = "test.xisf",
        filter: String = "Ha",
        exposure: Double = 300,
        fwhm: Double = 2.5,
        stars: Int = 500,
        noise: Double = 0.003,
        trailing: Double = 0.1,
        moon: Double = 0.5,
        moonDist: Double = 45.0,
        tier: Int = 2,
        zScore: Double = 0.5,
        sessionId: String = "session1",
        setupHash: String = "setup1",
        target: String = "NGC7000",
        night: String = "2026-03-18"
    ) -> FrameRecord {
        FrameRecord(
            fileHash: hash, shortId: ImageEntry.computeShortId(from: hash),
            filename: filename, filePath: "/test/\(filename)",
            observingNight: night, captureDate: "2026-03-18", captureTime: "22:30:00",
            sessionId: sessionId,
            telescope: "RC12", camera: "ASI6200MM",
            focalLength: 2423, pixelSizeMicrons: 3.76, setupHash: setupHash,
            target: target, filter: filter, exposure: exposure,
            gain: 100, offsetVal: 50, binning: "1x1",
            pierSide: "EAST", rotatorAngle: nil, mount: "EQ6-R",
            computedFWHM: fwhm, computedHFR: 1.8,
            computedStarCount: stars, computedEccentricity: 0.3,
            noiseMedian: 0.15, noiseMAD: noise,
            trailingScore: trailing, trailingPA: 45.0,
            trailingConsensus: 0.8, trailingAxisRatio: 0.85,
            starChainFraction: 0.0,
            sensorTemp: -10.0, focuserTemp: 5.0, ambientTemp: 3.0,
            twilightPhase: "Night",
            moonIllumination: moon, moonDistance: moonDist,
            qualityTier: tier, combinedZScore: zScore,
            garbageReasons: nil, isLockedKeep: 0,
            filterTrailingMultiplier: 1.0, userConfidence: 0, wasDeleted: 0,
            algorithmVersion: 1,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            width: 9576, height: 6388
        )
    }

    // MARK: - Basic CRUD

    func testInsertAndFetch() throws {
        let record = makeRecord(hash: "hash001")
        try testDB.write { db in try record.save(db) }

        let fetched = try testDB.read { db in
            try FrameRecord.fetchOne(db, key: "hash001")
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.filename, "test.xisf")
        XCTAssertEqual(fetched?.filter, "Ha")
        XCTAssertEqual(fetched?.computedFWHM, 2.5)
        XCTAssertEqual(fetched?.computedStarCount, 500)
        XCTAssertEqual(fetched?.moonIllumination, 0.5)
        XCTAssertEqual(fetched?.moonDistance, 45.0)
        XCTAssertEqual(fetched?.qualityTier, 2)
        XCTAssertEqual(fetched?.telescope, "RC12")
        XCTAssertEqual(fetched?.width, 9576)
    }

    func testUpsertOverwritesExisting() throws {
        let r1 = makeRecord(hash: "hash001", fwhm: 2.5, stars: 500)
        try testDB.write { db in try r1.save(db) }

        // Same hash, updated metrics
        let r2 = makeRecord(hash: "hash001", fwhm: 3.0, stars: 450)
        try testDB.write { db in try r2.save(db) }

        let count = try testDB.read { db in try FrameRecord.fetchCount(db) }
        XCTAssertEqual(count, 1, "UPSERT should not create duplicate")

        let fetched = try testDB.read { db in try FrameRecord.fetchOne(db, key: "hash001") }
        XCTAssertEqual(fetched?.computedFWHM, 3.0, "Should have updated FWHM")
        XCTAssertEqual(fetched?.computedStarCount, 450, "Should have updated star count")
    }

    func testNoDuplicatesOnReload() throws {
        // Simulate loading same session twice
        for _ in 0..<3 {
            let records = (0..<10).map { i in
                makeRecord(hash: "hash\(i)", filename: "frame_\(i).xisf")
            }
            try testDB.write { db in
                for r in records { try r.save(db) }
            }
        }

        let count = try testDB.read { db in try FrameRecord.fetchCount(db) }
        XCTAssertEqual(count, 10, "Three loads of same 10 files should still be 10 records")
    }

    // MARK: - All Fields Preserved

    func testAllFieldsRoundTrip() throws {
        let record = makeRecord(hash: "roundtrip")
        try testDB.write { db in try record.save(db) }
        let fetched = try testDB.read { db in try FrameRecord.fetchOne(db, key: "roundtrip")! }

        XCTAssertEqual(fetched.fileHash, record.fileHash)
        XCTAssertEqual(fetched.shortId, record.shortId)
        XCTAssertEqual(fetched.filename, record.filename)
        XCTAssertEqual(fetched.filePath, record.filePath)
        XCTAssertEqual(fetched.observingNight, record.observingNight)
        XCTAssertEqual(fetched.captureDate, record.captureDate)
        XCTAssertEqual(fetched.captureTime, record.captureTime)
        XCTAssertEqual(fetched.sessionId, record.sessionId)
        XCTAssertEqual(fetched.telescope, record.telescope)
        XCTAssertEqual(fetched.camera, record.camera)
        XCTAssertEqual(fetched.focalLength, record.focalLength)
        XCTAssertEqual(fetched.pixelSizeMicrons, record.pixelSizeMicrons)
        XCTAssertEqual(fetched.setupHash, record.setupHash)
        XCTAssertEqual(fetched.target, record.target)
        XCTAssertEqual(fetched.filter, record.filter)
        XCTAssertEqual(fetched.exposure, record.exposure)
        XCTAssertEqual(fetched.gain, record.gain)
        XCTAssertEqual(fetched.offsetVal, record.offsetVal)
        XCTAssertEqual(fetched.binning, record.binning)
        XCTAssertEqual(fetched.pierSide, record.pierSide)
        XCTAssertEqual(fetched.mount, record.mount)
        XCTAssertEqual(fetched.computedFWHM, record.computedFWHM)
        XCTAssertEqual(fetched.computedHFR, record.computedHFR)
        XCTAssertEqual(fetched.computedStarCount, record.computedStarCount)
        XCTAssertEqual(fetched.computedEccentricity, record.computedEccentricity)
        XCTAssertEqual(fetched.noiseMedian, record.noiseMedian)
        XCTAssertEqual(fetched.noiseMAD, record.noiseMAD)
        XCTAssertEqual(fetched.trailingScore, record.trailingScore)
        XCTAssertEqual(fetched.trailingPA, record.trailingPA)
        XCTAssertEqual(fetched.trailingConsensus, record.trailingConsensus)
        XCTAssertEqual(fetched.trailingAxisRatio, record.trailingAxisRatio)
        XCTAssertEqual(fetched.starChainFraction, record.starChainFraction)
        XCTAssertEqual(fetched.sensorTemp, record.sensorTemp)
        XCTAssertEqual(fetched.focuserTemp, record.focuserTemp)
        XCTAssertEqual(fetched.ambientTemp, record.ambientTemp)
        XCTAssertEqual(fetched.twilightPhase, record.twilightPhase)
        XCTAssertEqual(fetched.moonIllumination, record.moonIllumination)
        XCTAssertEqual(fetched.moonDistance, record.moonDistance)
        XCTAssertEqual(fetched.qualityTier, record.qualityTier)
        XCTAssertEqual(fetched.combinedZScore, record.combinedZScore)
        XCTAssertEqual(fetched.isLockedKeep, record.isLockedKeep)
        XCTAssertEqual(fetched.filterTrailingMultiplier, record.filterTrailingMultiplier)
        XCTAssertEqual(fetched.wasDeleted, record.wasDeleted)
        XCTAssertEqual(fetched.algorithmVersion, record.algorithmVersion)
        XCTAssertEqual(fetched.width, record.width)
        XCTAssertEqual(fetched.height, record.height)
    }

    // MARK: - Mark Deleted

    func testMarkDeleted() throws {
        let records = (0..<5).map { i in makeRecord(hash: "del\(i)") }
        try testDB.write { db in for r in records { try r.save(db) } }

        // Mark 2 as deleted
        try testDB.write { db in
            try db.execute(sql: "UPDATE frame_record SET wasDeleted = 1 WHERE fileHash IN (?, ?)",
                          arguments: ["del1", "del3"])
        }

        let deleted = try testDB.read { db in
            try FrameRecord.filter(Column("wasDeleted") == 1).fetchCount(db)
        }
        XCTAssertEqual(deleted, 2)

        let retained = try testDB.read { db in
            try FrameRecord.filter(Column("wasDeleted") == 0).fetchCount(db)
        }
        XCTAssertEqual(retained, 3)
    }

    // MARK: - Performance

    func testBulkInsertPerformance() throws {
        let records = (0..<1000).map { i in
            makeRecord(hash: "perf\(i)", filename: "frame_\(i).xisf",
                      fwhm: Double.random(in: 1.5...5.0),
                      stars: Int.random(in: 100...2000))
        }

        measure {
            try! testDB.write { db in
                try db.execute(sql: "DELETE FROM frame_record")
                for r in records { try r.save(db) }
            }
        }
        // Expectation: 1000 inserts < 1 second
    }

    func testBulkQueryPerformance() throws {
        // Insert 5000 records across 5 filters and 10 nights
        let filters = ["Ha", "OIII", "SII", "L", "R"]
        let nights = (0..<10).map { "2026-03-\(String(format: "%02d", $0 + 1))" }
        var records: [FrameRecord] = []
        for i in 0..<5000 {
            records.append(makeRecord(
                hash: "q\(i)", filter: filters[i % 5],
                sessionId: "s\(i / 500)",
                night: nights[i % 10]
            ))
        }
        try testDB.write { db in for r in records { try r.save(db) } }

        measure {
            let _ = try! testDB.read { db in
                try FrameRecord
                    .filter(Column("setupHash") == "setup1")
                    .filter(Column("filter") == "Ha")
                    .fetchAll(db)
            }
        }
        // Expectation: query 1000 Ha records from 5000 total < 50ms
    }

    // MARK: - Short ID

    func testShortIdDeterministic() {
        let id1 = ImageEntry.computeShortId(from: "abc123def456")
        let id2 = ImageEntry.computeShortId(from: "abc123def456")
        XCTAssertEqual(id1, id2, "Same hash should produce same short ID")
    }

    func testShortIdFormat() {
        let id = ImageEntry.computeShortId(from: "a3f29178bcde")
        // Format: XX-NNNN (2 hex uppercase + dash + 4 digits)
        XCTAssertTrue(id.count >= 7, "Short ID should be at least 7 chars")
        XCTAssertTrue(id.contains("-"), "Short ID should contain dash")
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, 2, "Prefix should be 2 chars")
        XCTAssertEqual(parts[1].count, 4, "Number should be 4 digits")
    }

    func testShortIdDifferentHashes() {
        let id1 = ImageEntry.computeShortId(from: "aaaa11112222")
        let id2 = ImageEntry.computeShortId(from: "bbbb33334444")
        XCTAssertNotEqual(id1, id2, "Different hashes should produce different IDs")
    }

    // MARK: - Session Record

    func testSessionRecordCRUD() throws {
        let session = SessionRecord(
            id: "sess1", sessionPath: "/test/path",
            observingNight: "2026-03-18", setupHash: "setup1",
            telescope: "RC12", camera: "ASI6200MM", target: "NGC7000",
            frameCount: 100, trashCount: 15, deletedCount: 10,
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
        try testDB.write { db in try session.save(db) }

        let fetched = try testDB.read { db in try SessionRecord.fetchOne(db, key: "sess1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.frameCount, 100)
        XCTAssertEqual(fetched?.trashCount, 15)
        XCTAssertEqual(fetched?.target, "NGC7000")
    }

    // MARK: - Historical Baselines

    func testHistoricalBaselinesBuilding() {
        // Create 50 records with known distributions
        var records: [FrameRecord] = []
        for i in 0..<50 {
            records.append(makeRecord(
                hash: "hist\(i)",
                filter: "Ha", exposure: 300,
                fwhm: 2.0 + Double(i) * 0.02,  // 2.0 to 2.98
                stars: 400 + i * 2,              // 400 to 498
                noise: 0.003 + Double(i) * 0.0001 // 0.003 to 0.0079
            ))
        }

        let baselines = HistoricalBaselines.build(from: records)
        XCTAssertFalse(baselines.baselines.isEmpty)

        let group = baselines.baselines["HA|300"]
        XCTAssertNotNil(group, "Should have baseline for HA|300")
        XCTAssertEqual(group!.frameCount, 50)
        XCTAssertEqual(group!.fwhmMedian, 2.49, accuracy: 0.02, "Median FWHM should be ~2.49")
        XCTAssertGreaterThan(group!.fwhmMAD, 0, "MAD should be positive")
    }

    func testHistoricalBaselinesMinimumFrames() {
        // Only 3 records — should not create baseline (minimum 5)
        let records = (0..<3).map { i in
            makeRecord(hash: "few\(i)", filter: "L", exposure: 60)
        }
        let baselines = HistoricalBaselines.build(from: records)
        XCTAssertNil(baselines.baselines["L|60"], "Should not create baseline with < 5 frames")
    }

    // MARK: - File Hasher

    func testFileHasherDeterministic() {
        // Create a temp file with known content
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory() + "test_hash_\(UUID().uuidString).bin")
        let data = Data(repeating: 0xAB, count: 1024)
        try! data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let hash1 = FileHasher.hash(for: tmpURL)
        let hash2 = FileHasher.hash(for: tmpURL)
        XCTAssertNotNil(hash1)
        XCTAssertEqual(hash1, hash2, "Same file should produce same hash")
        XCTAssertEqual(hash1!.count, 64, "SHA256 hex should be 64 chars")
    }

    func testFileHasherDifferentContent() {
        let tmp1 = URL(fileURLWithPath: NSTemporaryDirectory() + "test_hash1_\(UUID().uuidString).bin")
        let tmp2 = URL(fileURLWithPath: NSTemporaryDirectory() + "test_hash2_\(UUID().uuidString).bin")
        try! Data(repeating: 0xAA, count: 1024).write(to: tmp1)
        try! Data(repeating: 0xBB, count: 1024).write(to: tmp2)
        defer {
            try? FileManager.default.removeItem(at: tmp1)
            try? FileManager.default.removeItem(at: tmp2)
        }

        let h1 = FileHasher.hash(for: tmp1)
        let h2 = FileHasher.hash(for: tmp2)
        XCTAssertNotEqual(h1, h2, "Different content should produce different hashes")
    }

    func testFileHasherNonExistentFile() {
        let hash = FileHasher.hash(for: URL(fileURLWithPath: "/nonexistent/file.fits"))
        XCTAssertNil(hash, "Non-existent file should return nil")
    }
}

// MARK: - Moon Calculator Tests

final class MoonCalculatorTests: XCTestCase {

    // Known full moon: 2024-08-19 (Super Blue Moon)
    func testFullMoonIllumination() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let fullMoon = formatter.date(from: "2024-08-19 18:26")!

        let illumination = MoonCalculator.illumination(utcDate: fullMoon)
        XCTAssertGreaterThan(illumination, 0.95, "Full moon should be >95% illuminated, got \(illumination)")
    }

    // Known new moon: 2024-09-03
    func testNewMoonIllumination() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let newMoon = formatter.date(from: "2024-09-03 01:56")!

        let illumination = MoonCalculator.illumination(utcDate: newMoon)
        XCTAssertLessThan(illumination, 0.05, "New moon should be <5% illuminated, got \(illumination)")
    }

    // Quarter moon: ~50%
    func testFirstQuarterIllumination() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        // First quarter: 2024-08-12
        let quarter = formatter.date(from: "2024-08-12 15:19")!

        let illumination = MoonCalculator.illumination(utcDate: quarter)
        XCTAssertGreaterThan(illumination, 0.35, "First quarter should be >35%, got \(illumination)")
        XCTAssertLessThan(illumination, 0.65, "First quarter should be <65%, got \(illumination)")
    }

    func testMoonPositionReturnsValues() {
        let date = Date()
        let pos = MoonCalculator.position(utcDate: date)
        XCTAssertNotNil(pos, "Moon position should not be nil")
        if let p = pos {
            XCTAssertGreaterThanOrEqual(p.ra, 0)
            XCTAssertLessThan(p.ra, 360)
            XCTAssertGreaterThanOrEqual(p.dec, -90)
            XCTAssertLessThanOrEqual(p.dec, 90)
        }
    }

    func testAngularSeparation() {
        // Same point = 0 degrees
        let sep0 = MoonCalculator.angularSeparation(ra1: 100, dec1: 30, ra2: 100, dec2: 30)
        XCTAssertEqual(sep0, 0.0, accuracy: 0.001)

        // Opposite points on sky = 180 degrees
        let sep180 = MoonCalculator.angularSeparation(ra1: 0, dec1: 0, ra2: 180, dec2: 0)
        XCTAssertEqual(sep180, 180.0, accuracy: 0.1)

        // 90 degrees apart
        let sep90 = MoonCalculator.angularSeparation(ra1: 0, dec1: 0, ra2: 90, dec2: 0)
        XCTAssertEqual(sep90, 90.0, accuracy: 0.1)
    }

    func testMoonTargetDistanceWithFITSCoords() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let date = formatter.date(from: "2024-08-19 22:00")!

        // M82: RA 09h 55m 52s, Dec +69° 40' 47"
        let dist = MoonCalculator.moonTargetDistance(
            utcDate: date, targetRA: "09 55 52", targetDec: "+69 40 47"
        )
        XCTAssertNotNil(dist, "Should compute distance from FITS coords")
        if let d = dist {
            XCTAssertGreaterThan(d, 0, "Distance should be positive")
            XCTAssertLessThan(d, 180, "Distance should be < 180°")
        }
    }

    func testMoonTargetDistanceWithDegrees() {
        let date = Date()
        let dist = MoonCalculator.moonTargetDistance(
            utcDate: date, targetRADeg: 148.97, targetDecDeg: 69.68
        )
        XCTAssertNotNil(dist)
    }

    func testIlluminationRange() {
        // Test 30 dates across a month — all should be [0, 1]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        for day in 1...30 {
            let date = formatter.date(from: "2024-08-\(String(format: "%02d", day))")!
            let ill = MoonCalculator.illumination(utcDate: date)
            XCTAssertGreaterThanOrEqual(ill, 0.0, "Illumination should be >= 0 on day \(day)")
            XCTAssertLessThanOrEqual(ill, 1.0, "Illumination should be <= 1 on day \(day)")
        }
    }
}
