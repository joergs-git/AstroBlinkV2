// Tests for writing a solved WCS back into the original files.
//
// This is the only part of plate solving that touches the user's data, so it is also the part
// that has to be proven rather than assumed: every keyword must survive the round trip, the
// pixel data must be untouched, and a failure must restore the file from its backup.
//
// v6.9.0

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

    private func report(for url: URL) -> PlateSolveReport {
        var entry = ImageEntry(url: url)
        entry.focalLength = 2455
        entry.pixelSizeMicrons = 3.76
        var report = PlateSolveReport()
        report.solved = [SolvedFrame(entry: entry, solution: solution(),
                                     previous: nil, identification: nil)]
        return report
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

    func testObjectNameIsWrittenOnlyWhereEmptyAndNeverOverwrites() throws {
        let frame = try testFrame(named: "Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        let existing = BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "' "))

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
        PlateSolveEngine().writeBack(&r, sessionRoot: work, writeObjectName: true)

        let after = BatchOperations.readHeaderValue(url: frame, keyword: "OBJECT")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "' "))

        if let existing, !existing.isEmpty, existing.caseInsensitiveCompare("M42") != .orderedSame {
            // The user's own naming wins, and the discrepancy is reported instead.
            XCTAssertEqual(after, existing, "an existing OBJECT was overwritten")
            XCTAssertEqual(r.objectNamesKept.count, 1)
            XCTAssertEqual(r.objectNamesWritten, 0)
        } else {
            XCTAssertEqual(after, "M42")
            XCTAssertEqual(r.objectNamesWritten, 1)
        }
    }
}
