// Tests for writing a solved WCS back into the original files.
//
// This is the only part of plate solving that touches the user's data, so it is also the part
// that has to be proven rather than assumed: every keyword must survive the round trip, the
// pixel data must be untouched, and a failure must restore the file from its backup.
//
// v6.9.0
// v6.12.0 — OBJECT replacement, A→B filename replacement, pre-save preview.

import XCTest
@testable import AstroTriage
import ImageDecoderBridge

final class PlateSolveWriteBackTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("writeback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// A realistic RC12 solution.
    private func solution() -> WCSSolution {
        let s = 0.316 / 3600.0
        return WCSSolution(crval1: 44.2556, crval2: 60.6446,
                           crpix1: 4788.5, crpix2: 3194.5,
                           cd11: -s, cd12: 3.0e-9, cd21: 3.0e-9, cd22: s,
                           crota2: 269.998)
    }

    private func testFrame(named name: String) throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("TestImages").appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "test frame \(name) not present — skipping")
        let copy = work.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func report(for url: URL, identification: TargetIdentification? = nil) -> PlateSolveReport {
        var report = PlateSolveReport()
        report.solved = [solvedFrame(for: url, identification: identification)]
        return report
    }

    /// One solved frame; `target` stands in for the header-enriched OBJECT the preview reads.
    private func solvedFrame(for url: URL,
                             identification: TargetIdentification? = nil,
                             target: String? = nil) -> SolvedFrame {
        var entry = ImageEntry(url: url)
        entry.focalLength = 2455
        entry.pixelSizeMicrons = 3.76
        entry.target = target
        return SolvedFrame(entry: entry, solution: solution(), previous: nil, identification: identification)
    }

    /// Catalogue identification for the OBJECT / rename tests.
    private func identification(_ canonicalName: String) throws -> TargetIdentification {
        let target = try XCTUnwrap(DeepSkyTargetDatabase.lookup(canonicalName),
                                   "\(canonicalName) missing from the catalogue")
        return TargetIdentification(target: target, separationArcmin: 1.0, centreInsideObject: true)
    }

    /// A copy of the FITS test frame under `name`, with OBJECT set to `object` through the same
    /// writer the save uses (the fixture frame carries no object name of its own).
    private func fitsFrame(named name: String, object: String?) throws -> URL {
        let source = try testFrame(named: "Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        let url = work.appendingPathComponent(name)
        try FileManager.default.moveItem(at: source, to: url)
        if let object {
            XCTAssertNil(BatchOperations.writeHeaders(url: url, values: [("OBJECT", object)]))
            XCTAssertEqual(BatchOperations.readHeaderValue(url: url, keyword: "OBJECT"), object)
        }
        return url
    }

    /// Every keyword the solver writes must be readable afterwards, with the value intact.
    private func assertKeywordsSurvived(in url: URL, file: StaticString = #filePath, line: UInt = #line) {
        for (keyword, written) in PlateSolveEngine.keywords(for: solution()) {
            guard let readBack = BatchOperations.readHeaderValue(url: url, keyword: keyword) else {
                XCTFail("\(keyword) missing after write-back", file: file, line: line)
                continue
            }
            if let a = Double(written), let b = Double(readBack) {
                let scale = max(abs(a), abs(b), 1e-12)
                XCTAssertEqual(a, b, accuracy: scale * 1e-6,
                               "\(keyword) changed value", file: file, line: line)
            } else {
                XCTAssertEqual(written.trimmingCharacters(in: CharacterSet(charactersIn: "' ")),
                               readBack.trimmingCharacters(in: CharacterSet(charactersIn: "' ")),
                               "\(keyword) changed value", file: file, line: line)
            }
        }
    }

    // MARK: - OBJECT and filename (6.12.0)

    /// Until 6.11.4 a differing OBJECT was never touched: the user's five NGC 6888 frames stayed
    /// labelled M45 after a save that reported success. With the backup copy as the safety net
    /// the identified name now replaces it — and the report says so.
    func testDifferentObjectIsReplacedWhenNamingIsOn() throws {
        let frame = try fitsFrame(named: "Light_M45_0001.fit", object: "M45")
        var r = report(for: frame, identification: try identification("NGC6888"))
        PlateSolveEngine().writeBack(&r, sessionRoot: work,
                                     options: PlateSolveWriteOptions(scope: .all, writeObjectName: true))

        XCTAssertEqual(r.written, 1, "\(r.writeFailures)")
        XCTAssertEqual(r.objectNamesWritten, 1)
        XCTAssertEqual(r.objectNamesReplaced.count, 1)
        XCTAssertEqual(r.objectNamesReplaced.first?.existing, "M45")
        XCTAssertEqual(BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT"), "NGC6888")
        XCTAssertEqual(r.objectWritten[r.solved[0].entry.id], "NGC6888")
        XCTAssertEqual(r.solved[0].entry.target, "NGC6888", "the report's own entry adopts the written name")
        XCTAssertEqual(r.affectedURLs[frame], frame, "header-only write records an identity mapping for undo")
        // The original name is one copy away.
        let backup = try XCTUnwrap(r.backupDirectory).appendingPathComponent(frame.lastPathComponent)
        XCTAssertEqual(BatchOperations.readHeaderValue(url: backup, keyword: "OBJECT"), "M45")
        assertKeywordsSurvived(in: frame)
    }

    func testObjectUntouchedWhenNamingIsOff() throws {
        let frame = try fitsFrame(named: "Light_M45_0002.fit", object: "M45")
        var r = report(for: frame, identification: try identification("NGC6888"))
        PlateSolveEngine().writeBack(&r, sessionRoot: work,
                                     options: PlateSolveWriteOptions(scope: .all, writeObjectName: false))
        XCTAssertEqual(r.written, 1, "\(r.writeFailures)")
        XCTAssertEqual(r.objectNamesWritten, 0)
        XCTAssertTrue(r.objectNamesReplaced.isEmpty)
        XCTAssertTrue(r.objectWritten.isEmpty)
        XCTAssertEqual(BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT"), "M45")
    }

    func testMatchingObjectIsNotCountedAsReplaced() throws {
        let frame = try fitsFrame(named: "Light_NGC6888_0003.fit", object: "ngc6888")
        var r = report(for: frame, identification: try identification("NGC6888"))
        PlateSolveEngine().writeBack(&r, sessionRoot: work)
        XCTAssertEqual(r.written, 1, "\(r.writeFailures)")
        XCTAssertEqual(r.objectNamesWritten, 0, "an OBJECT that already names the object is left alone")
        XCTAssertTrue(r.objectNamesReplaced.isEmpty)
        XCTAssertEqual(BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT"), "ngc6888")
    }

    /// Two frames both named M45 in the file: the real M45 frame keeps its name, the NGC 6888
    /// frame is renamed — the rename follows the IDENTIFIED object, not the text alone.
    func testRenameAppliesOnlyToFramesOfAnotherObject() throws {
        let m45 = try fitsFrame(named: "Light_M45_300s_0010.fit", object: "M45")
        let crescent = try fitsFrame(named: "Light_M45_300s_0011.fit", object: "M45")
        var r = PlateSolveReport()
        r.solved = [solvedFrame(for: m45, identification: try identification("M45")),
                    solvedFrame(for: crescent, identification: try identification("NGC6888"))]
        var options = PlateSolveWriteOptions(scope: .all, writeObjectName: true)
        options.rename = FilenameReplacement(search: "M45", replacement: "NGC6888")
        PlateSolveEngine().writeBack(&r, sessionRoot: work, options: options)

        XCTAssertEqual(r.written, 2, "\(r.writeFailures)")
        XCTAssertEqual(r.renamed, 1)
        let renamed = work.appendingPathComponent("Light_NGC6888_300s_0011.fit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path), "NGC 6888 frame not renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: crescent.path), "old name still present")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m45.path), "the real M45 frame must keep its name")
        XCTAssertEqual(r.affectedURLs[m45], m45)
        XCTAssertEqual(r.affectedURLs[crescent], renamed)
        XCTAssertEqual(BatchOperations.readHeaderValue(url: renamed, keyword: "OBJECT"), "NGC6888")
        XCTAssertEqual(BatchOperations.readHeaderValue(url: m45, keyword: "OBJECT"), "M45")
        XCTAssertEqual(r.solved[1].entry.url, renamed, "the report's entry follows the renamed file")
        XCTAssertEqual(r.objectNamesReplaced.count, 1)
        // The backup holds the original under its ORIGINAL name — that is what undo restores.
        let backup = try XCTUnwrap(r.backupDirectory)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backup.appendingPathComponent(crescent.lastPathComponent).path))
        assertKeywordsSurvived(in: renamed)
    }

    func testRenameRefusesAnExistingTargetAndRestoresTheFrame() throws {
        let crescent = try fitsFrame(named: "Light_M45_300s_0020.fit", object: "M45")
        let before = try Data(contentsOf: crescent)
        let blocker = work.appendingPathComponent("Light_NGC6888_300s_0020.fit")
        try Data("not a FITS file".utf8).write(to: blocker)
        var r = report(for: crescent, identification: try identification("NGC6888"))
        var options = PlateSolveWriteOptions(scope: .all, writeObjectName: true)
        options.rename = FilenameReplacement(search: "M45", replacement: "NGC6888")
        PlateSolveEngine().writeBack(&r, sessionRoot: work, options: options)

        XCTAssertEqual(r.written, 0)
        XCTAssertEqual(r.renamed, 0)
        XCTAssertEqual(r.writeFailures.count, 1)
        XCTAssertTrue(r.writeFailures.first?.reason.contains("already exists") == true,
                      r.writeFailures.first?.reason ?? "no failure recorded")
        XCTAssertEqual(try Data(contentsOf: blocker), Data("not a FITS file".utf8),
                       "the existing file must not be overwritten")
        // Restored from backup byte for byte: the OBJECT write before the refused rename is gone too.
        XCTAssertEqual(try Data(contentsOf: crescent), before)
    }

    func testRenameRulesFollowTheIdentifiedObject() throws {
        let url = work.appendingPathComponent("Light_M45_300s_0030.fit")   // need not exist
        let crescent = solvedFrame(for: url, identification: try identification("NGC6888"))
        let pleiades = solvedFrame(for: url, identification: try identification("M45"))
        let unknown = solvedFrame(for: url, identification: nil)
        let m45ToCrescent = FilenameReplacement(search: "M45", replacement: "NGC6888")

        XCTAssertEqual(PlateSolveEngine.renamedFilename(for: crescent, replacement: m45ToCrescent),
                       "Light_NGC6888_300s_0030.fit")
        XCTAssertNil(PlateSolveEngine.renamedFilename(for: pleiades, replacement: m45ToCrescent),
                     "a frame that IS M45 keeps its name")
        XCTAssertNil(PlateSolveEngine.renamedFilename(
                        for: pleiades, replacement: FilenameReplacement(search: "M 45", replacement: "X")),
                     "the catalogue spelling of the search text is recognised too")
        XCTAssertNil(PlateSolveEngine.renamedFilename(for: unknown, replacement: m45ToCrescent),
                     "no identification → no rename")
        XCTAssertNil(PlateSolveEngine.renamedFilename(
                        for: crescent, replacement: FilenameReplacement(search: "IC1805", replacement: "X")),
                     "search text absent from the name")
        XCTAssertNil(PlateSolveEngine.renamedFilename(
                        for: crescent, replacement: FilenameReplacement(search: "", replacement: "X")),
                     "an empty search text matches nothing — never everything")
        XCTAssertFalse(FilenameReplacement(search: "M45", replacement: "a/b").isUsable,
                       "a path separator would turn the rename into a move")
    }

    func testPreviewCountsTheObjectsTheSaveWouldChange() throws {
        let url = work.appendingPathComponent("Light_M45_300s_0040.fit")   // need not exist
        var r = PlateSolveReport()
        r.solved = [solvedFrame(for: url, identification: try identification("M45"), target: "M45"),
                    solvedFrame(for: url, identification: try identification("NGC6888"), target: "M45"),
                    solvedFrame(for: url, identification: try identification("NGC6888"), target: "M45"),
                    solvedFrame(for: url, identification: try identification("NGC6888"), target: nil)]
        let changes = r.objectChanges(in: .all)
        XCTAssertEqual(changes.count, 3, "the real M45 frame is no change; the empty OBJECT is one")
        let pair = try XCTUnwrap(PlateSolveReport.dominantPair(of: changes))
        XCTAssertEqual(pair.existing, "M45")
        XCTAssertEqual(pair.new, "NGC6888")
        XCTAssertEqual(pair.count, 2, "frames with an empty OBJECT have nothing to replace")
        XCTAssertEqual(r.renamePreview(in: .all,
                                       replacement: FilenameReplacement(search: "M45", replacement: "NGC6888")).count,
                       3, "every NGC 6888 frame named M45 is renamed, the M45 frame is not")
    }

    // MARK: - FITS

    func testWriteBackIntoFITS() throws {
        let frame = try testFrame(named: "Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: frame.path)[.size] as? Int

        var r = report(for: frame)
        let started = Date()
        PlateSolveEngine().writeBack(&r, sessionRoot: work)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.written, 1, "write-back reported no success: \(r.writeFailures)")
        XCTAssertTrue(r.writeFailures.isEmpty, "\(r.writeFailures)")
        assertKeywordsSurvived(in: frame)

        // Keywords go into the existing header block — the image must not be rewritten.
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: frame.path)[.size] as? Int
        XCTAssertEqual(sizeBefore, sizeAfter, "FITS file size changed — pixel data was rewritten?")
        print("WRITEBACK fits elapsed=\(String(format: "%.2f", elapsed))s")
    }

    /// 6.10.0: WCS keywords must be NUMERIC cards. Until then every keyword went through
    /// fits_update_key_str and the file ended up with `CRVAL1 = '22.7545063223'` — readable by
    /// AstroBlink (its reader strips the quotes) but not standard FITS, and other software may
    /// ignore the solution. The raw header bytes are the only honest witness here, because the
    /// app's own reader hides the difference.
    func testWriteBackWritesNumericWCSCards() throws {
        let frame = try testFrame(named: "Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        var r = report(for: frame)
        PlateSolveEngine().writeBack(&r, sessionRoot: work)
        XCTAssertEqual(r.written, 1, "\(r.writeFailures)")

        let handle = try FileHandle(forReadingFrom: frame)
        defer { try? handle.close() }
        let headerBytes = try XCTUnwrap(handle.read(upToCount: 2880 * 16))
        let header = String(decoding: headerBytes, as: UTF8.self)

        for keyword in ["CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD2_2", "CROTA2"] {
            let card = keyword.padding(toLength: 8, withPad: " ", startingAt: 0) + "= "
            guard let range = header.range(of: card) else {
                XCTFail("\(keyword) card missing"); continue
            }
            // Fixed-format card: the value sits in columns 11-30, the comment follows a "/".
            let value = header[range.upperBound...].prefix(20)
            XCTAssertFalse(value.contains("'"), "\(keyword) is a quoted string card: \(value)")
            XCTAssertNotNil(Double(value.trimmingCharacters(in: .whitespaces)),
                            "\(keyword) value field is not a number: \(value)")
        }
        XCTAssertTrue(header.contains("CTYPE1  = 'RA---TAN'"), "CTYPE1 stays a string card")
    }

    // MARK: - XISF

    func testWriteBackIntoXISF() throws {
        let frame = try testFrame(named: "2026-03-03_IC1848_00-06-44_RC12_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0004__bin1x1_gain100_O50_T-10.00c.xisf")

        // BAYERPAT/OBJECT stand in for "everything else in the header" — a full rewrite that
        // dropped unrelated keywords would be silent data loss.
        let objectBefore = BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT")
        let exposureBefore = BatchOperations.readHeaderValue(url: frame, keyword: "EXPTIME")

        var r = report(for: frame)
        let started = Date()
        PlateSolveEngine().writeBack(&r, sessionRoot: work)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.written, 1, "write-back reported no success: \(r.writeFailures)")
        XCTAssertTrue(r.writeFailures.isEmpty, "\(r.writeFailures)")
        assertKeywordsSurvived(in: frame)

        XCTAssertEqual(BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT"), objectBefore,
                       "an unrelated keyword changed")
        XCTAssertEqual(BatchOperations.readHeaderValue(url: frame, keyword: "EXPTIME"), exposureBefore,
                       "an unrelated keyword changed")

        // The pixels must still decode to the same image.
        var decoded = decode_xisf(frame.path)
        defer { free_decode_result(&decoded) }
        XCTAssertEqual(decoded.success, 1, "file no longer decodes after write-back")
        XCTAssertEqual(decoded.width, 9576)
        XCTAssertEqual(decoded.height, 6388)

        print("WRITEBACK xisf elapsed=\(String(format: "%.2f", elapsed))s")
        // libxisf cannot update a header in place: every save rewrites the whole file. Writing
        // the ~11 WCS keywords one at a time took 1.47 s on this 116 MB frame (and eleven times
        // the traffic over a NAS); batching them into one open/save cycle takes 0.14 s. This
        // bound sits between the two, so a regression to per-keyword writes fails here.
        XCTAssertLessThan(elapsed, 0.7,
                          "XISF write-back is rewriting the file per keyword again")
    }

    // MARK: - Reproduction: solve → write → re-solve must agree

    func testResolvingAfterWriteBackAgreesWithWhatWasWritten() throws {
        let locator = ASTAPLocator.shared
        let binary = try XCTUnwrap(locator.findBinary(), "ASTAP not installed — skipping")
        let database = URL(fileURLWithPath: "/usr/local/opt/astap")
        try XCTSkipUnless(locator.isStarDatabase(database), "No ASTAP star database — skipping")

        let frame = try testFrame(named: "2026-03-03_IC1848_00-06-44_RC12_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0004__bin1x1_gain100_O50_T-10.00c.xisf")

        var entry = ImageEntry(url: frame)
        entry.focalLength = 2455
        entry.pixelSizeMicrons = 3.76
        entry.binning = "1x1"
        entry.width = 9576
        entry.height = 6388

        let fov = ASTAPSolver.fieldOfViewDegrees(heightPixels: entry.height,
                                                 arcsecPerPixel: entry.arcsecPerPixel,
                                                 binning: entry.binning)
        let solver = ASTAPSolver()

        // 1. Solve.
        guard case .solved(let first) = solver.solve(url: frame, fovDegrees: fov,
                                                     binary: binary, database: database) else {
            return XCTFail("first solve failed")
        }

        // 2. Write it back.
        var r = PlateSolveReport()
        r.solved = [SolvedFrame(entry: entry, solution: first, previous: nil, identification: nil)]
        PlateSolveEngine().writeBack(&r, sessionRoot: work)
        XCTAssertEqual(r.written, 1, "\(r.writeFailures)")

        // 3. Re-read the WCS out of the file, exactly as loading a session would.
        let keys = ["CRVAL1","CRVAL2","CRPIX1","CRPIX2","CD1_1","CD1_2","CD2_1","CD2_2","CROTA2"]
        let stored = BatchOperations.readHeaderValues(url: frame, keywords: keys)
        var reloaded = ImageEntry(url: frame)
        reloaded.solvedRA   = stored["CRVAL1"].flatMap(Double.init)
        reloaded.solvedDec  = stored["CRVAL2"].flatMap(Double.init)
        reloaded.wcsCRPIX1  = stored["CRPIX1"].flatMap(Double.init)
        reloaded.wcsCRPIX2  = stored["CRPIX2"].flatMap(Double.init)
        reloaded.wcsCD11    = stored["CD1_1"].flatMap(Double.init)
        reloaded.wcsCD12    = stored["CD1_2"].flatMap(Double.init)
        reloaded.wcsCD21    = stored["CD2_1"].flatMap(Double.init)
        reloaded.wcsCD22    = stored["CD2_2"].flatMap(Double.init)
        reloaded.wcsRotation = stored["CROTA2"].flatMap(Double.init)

        let previous = try XCTUnwrap(WCSSolution(existingOn: reloaded),
                                     "the written WCS did not read back as a complete solution")

        // The values in the file must BE the values we solved.
        XCTAssertEqual(previous.crval1, first.crval1, accuracy: 1e-6, "CRVAL1 round trip")
        XCTAssertEqual(previous.crpix1, first.crpix1, accuracy: 1e-3, "CRPIX1 round trip")
        XCTAssertEqual(previous.cd11, first.cd11, accuracy: abs(first.cd11) * 1e-6, "CD1_1 round trip")

        // 4. Solve again and compare, as the app does on a re-solve.
        guard case .solved(let second) = solver.solve(url: frame, fovDegrees: fov,
                                                      binary: binary, database: database) else {
            return XCTFail("second solve failed")
        }
        let comparison = PlateSolveComparison(existing: previous, fresh: second)
        print("REPRO comparison: \(comparison.summary) significant=\(comparison.isSignificant)")
        XCTAssertFalse(comparison.isSignificant,
                       "re-solving a frame we just wrote must confirm it, not differ: \(comparison.summary)")
    }

    // MARK: - Batch header access

    func testBatchReadReturnsTheSameValuesAsSingleReads() throws {
        for name in ["Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit",
                     "2026-03-03_IC1848_00-06-44_RC12_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0004__bin1x1_gain100_O50_T-10.00c.xisf"] {
            let frame = try testFrame(named: name)
            let keywords = ["FOCALLEN", "XPIXSZ", "EXPTIME", "FILTER", "NOT_A_REAL_KEY"]

            let batch = BatchOperations.readHeaderValues(url: frame, keywords: keywords)
            for keyword in keywords {
                let single = BatchOperations.readHeaderValue(url: frame, keyword: keyword)
                XCTAssertEqual(batch[keyword.uppercased()], single,
                               "\(keyword) differs between batch and single read in \(name)")
            }
            XCTAssertNil(batch["NOT_A_REAL_KEY"], "an absent key must be absent, not empty")
        }
    }

    func testBatchWriteAndSingleWriteProduceTheSameHeader() throws {
        // The batch path must not be a second, subtly different implementation.
        let viaBatch = try testFrame(named: "2026-03-03_IC1848_00-06-44_RC12_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0004__bin1x1_gain100_O50_T-10.00c.xisf")
        let viaSingle = work.appendingPathComponent("single.xisf")
        try FileManager.default.copyItem(at: viaBatch, to: viaSingle)

        let pairs = PlateSolveEngine.keywords(for: solution())

        XCTAssertNil(BatchOperations.writeHeaders(url: viaBatch, values: pairs))
        for (keyword, value) in pairs {
            XCTAssertNil(BatchOperations.writeHeader(url: viaSingle, keyword: keyword, value: value))
        }

        let batchValues = BatchOperations.readHeaderValues(url: viaBatch, keywords: pairs.map(\.0))
        let singleValues = BatchOperations.readHeaderValues(url: viaSingle, keywords: pairs.map(\.0))
        XCTAssertEqual(batchValues, singleValues)
    }

    // MARK: - Safety contract

    func testBackupIsCreatedAndHoldsTheOriginal() throws {
        let frame = try testFrame(named: "Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        var r = report(for: frame)
        PlateSolveEngine().writeBack(&r, sessionRoot: work)

        let backupDir = try XCTUnwrap(r.backupDirectory)
        let backup = backupDir.appendingPathComponent(frame.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "no backup was made")
        // The backup must predate the write: it must NOT carry the new WCS.
        XCTAssertNil(BatchOperations.readHeaderValue(url: backup, keyword: "CRPIX1")
                        .flatMap { Double($0) }.map { abs($0 - 4788.5) < 0.01 ? true : nil } ?? nil,
                     "the backup already contains the written value")
    }

    /// The identification found at the solved centre lands in OBJECT — into an empty keyword, and
    /// since 6.12.0 also over a different existing name (reported as replaced). Only a header that
    /// already carries the identified name is left alone.
    func testObjectNameIsWrittenWhereEmptyOrDifferent() throws {
        let frame = try testFrame(named: "Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        let existing = BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "' ")) ?? ""

        var entry = ImageEntry(url: frame)
        entry.focalLength = 467
        entry.pixelSizeMicrons = 3.76
        var r = PlateSolveReport()
        r.solved = [SolvedFrame(
            entry: entry,
            solution: solution(),
            previous: nil,
            identification: TargetIdentifier.identify(raDeg: 83.84, decDeg: -5.35,
                                                      fieldRadiusArcmin: 90)
        )]
        PlateSolveEngine().writeBack(&r, sessionRoot: work,
                                     options: PlateSolveWriteOptions(scope: .all, writeObjectName: true))

        let after = BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        XCTAssertEqual(after, "M42")

        if existing.caseInsensitiveCompare("M42") == .orderedSame {
            XCTAssertEqual(r.objectNamesWritten, 0, "a header that already names the object is left alone")
        } else {
            XCTAssertEqual(r.objectNamesWritten, 1)
            XCTAssertEqual(r.objectNamesReplaced.count, existing.isEmpty ? 0 : 1,
                           "a different existing name is reported as replaced, an empty one is not")
        }
    }
}
