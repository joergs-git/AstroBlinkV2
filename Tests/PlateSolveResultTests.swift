// Tests for how plate-solve results are presented: row ordering, status mapping and the
// clipboard export.
//
// The ordering matters as much as the content — a frame that disagrees with its stored WCS is
// the reason to open the window, so it must not be buried under a hundred confirmations.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class PlateSolveResultTests: XCTestCase {

    // MARK: - Fixtures

    private func entry(_ name: String) -> ImageEntry {
        ImageEntry(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func solution(ra: Double, dec: Double, scaleArcsec: Double = 1.66) -> WCSSolution {
        let s = scaleArcsec / 3600.0
        return WCSSolution(crval1: ra, crval2: dec, crpix1: 100, crpix2: 100,
                           cd11: -s, cd12: 0, cd21: 0, cd22: s, crota2: 0)
    }

    /// A frame solved fresh (no previous WCS).
    private func fresh(_ name: String, ra: Double = 83.84, dec: Double = -5.35) -> SolvedFrame {
        SolvedFrame(entry: entry(name), solution: solution(ra: ra, dec: dec),
                    previous: nil,
                    identification: TargetIdentifier.identify(raDeg: ra, decDeg: dec,
                                                              fieldRadiusArcmin: 90))
    }

    /// A frame re-solved, agreeing with what it already had.
    private func confirmed(_ name: String) -> SolvedFrame {
        let s = solution(ra: 83.84, dec: -5.35)
        return SolvedFrame(entry: entry(name), solution: s, previous: s,
                           identification: TargetIdentifier.identify(raDeg: 83.84, decDeg: -5.35,
                                                                     fieldRadiusArcmin: 90))
    }

    /// A frame re-solved, disagreeing with what it already had.
    private func disagreeing(_ name: String) -> SolvedFrame {
        SolvedFrame(entry: entry(name),
                    solution: solution(ra: 84.84, dec: -5.35),
                    previous: solution(ra: 83.84, dec: -5.35),
                    identification: nil)
    }

    // MARK: - Ordering

    func testDisagreementsAreListedFirst() {
        var report = PlateSolveReport()
        report.solved = [confirmed("a.fit"), fresh("b.fit"), disagreeing("c.fit"), confirmed("d.fit")]

        let rows = PlateSolveResultBuilder.rows(from: report)
        XCTAssertEqual(rows.first?.filename, "c.fit",
                       "the frame that disagrees must be the first thing the user sees")
        XCTAssertEqual(rows.first?.status, .disagrees)
    }

    func testFailuresAndSkipsFollowTheSolvedFrames() {
        var report = PlateSolveReport()
        report.solved = [fresh("ok.fit")]
        report.failed = [(entry: entry("bad.fit"), reason: "no solution found")]
        report.skippedUnsupported = [entry("thing.xisf")]

        let rows = PlateSolveResultBuilder.rows(from: report)
        XCTAssertEqual(rows.map(\.filename), ["ok.fit", "bad.fit", "thing.xisf"])
        XCTAssertEqual(rows[1].status, .failed)
        XCTAssertEqual(rows[2].status, .skipped)
        // The solver's own reason must reach the table, not a generic word.
        XCTAssertEqual(rows[1].detail, "no solution found")
    }

    func testEveryReportedFrameGetsExactlyOneRow() {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit"), confirmed("b.fit"), disagreeing("c.fit")]
        report.failed = [(entry: entry("d.fit"), reason: "x")]
        report.skippedUnsupported = [entry("e.xisf")]

        let rows = PlateSolveResultBuilder.rows(from: report)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(Set(rows.map(\.filename)).count, 5, "no frame may appear twice")
    }

    // MARK: - Status mapping

    func testStatusDistinguishesFreshFromConfirmed() {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit"), confirmed("b.fit")]
        let rows = PlateSolveResultBuilder.rows(from: report)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.filename, $0.status) })
        // "Solved" and "confirmed an existing solve" are different facts and must look different.
        XCTAssertEqual(byName["a.fit"], .solved)
        XCTAssertEqual(byName["b.fit"], .confirmed)
    }

    func testComparisonColumnsAreEmptyWhenThereIsNothingToCompare() {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit")]
        let row = PlateSolveResultBuilder.rows(from: report)[0]
        XCTAssertEqual(row.centre, "")
        XCTAssertEqual(row.scale, "")
        XCTAssertEqual(row.rotation, "")
    }

    func testComparisonColumnsCarryNumbersWhenThereIs() {
        var report = PlateSolveReport()
        report.solved = [disagreeing("c.fit")]
        let row = PlateSolveResultBuilder.rows(from: report)[0]
        XCTAssertTrue(row.centre.hasSuffix("'"), "centre offset should be in arcminutes: \(row.centre)")
        XCTAssertTrue(row.scale.contains("%"))
        XCTAssertTrue(row.rotation.contains("°"))
    }

    func testEveryStatusHasAGlyphAndALabel() {
        let all: [PlateSolveResultRow.Status] = [.solved, .confirmed, .disagrees, .failed, .skipped]
        for status in all {
            XCTAssertFalse(status.glyph.isEmpty)
            XCTAssertFalse(status.label.isEmpty)
        }
        // The two attention states must not look like the calm ones.
        XCTAssertNotEqual(PlateSolveResultRow.Status.disagrees.glyph,
                          PlateSolveResultRow.Status.confirmed.glyph)
        XCTAssertNotEqual(PlateSolveResultRow.Status.failed.glyph,
                          PlateSolveResultRow.Status.solved.glyph)
    }

    // MARK: - Dominant field

    func testDominantFieldIsPlainWhenAllFramesAgree() {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit"), fresh("b.fit")]
        let field = PlateSolveResultBuilder.dominantField(report)
        XCTAssertEqual(field, "M42 (Orion Nebula)")
    }

    func testDominantFieldShowsACountWhenFramesDisagree() throws {
        var report = PlateSolveReport()
        // Two frames on M42, one somewhere else entirely.
        report.solved = [fresh("a.fit"), fresh("b.fit"), fresh("c.fit", ra: 10.68, dec: 41.27)]
        let field = try XCTUnwrap(PlateSolveResultBuilder.dominantField(report))
        XCTAssertTrue(field.contains("2/3"), "expected a minority note, got \(field)")
    }

    func testDominantFieldIsNilWithoutAnyIdentification() {
        var report = PlateSolveReport()
        report.solved = [disagreeing("c.fit")]   // identification: nil
        XCTAssertNil(PlateSolveResultBuilder.dominantField(report))
    }

    // MARK: - Save scope

    func testChangedFramesAreTheOnesWritingWouldActuallyAlter() {
        var report = PlateSolveReport()
        report.solved = [
            fresh("new.fit"),          // had no WCS at all → writing adds information
            confirmed("same.fit"),     // agrees with what it had → writing is a no-op
            disagreeing("wrong.fit")   // contradicts what it had → writing corrects it
        ]
        let changed = report.changedFrames.map { $0.entry.filename }
        XCTAssertEqual(Set(changed), ["new.fit", "wrong.fit"])
        XCTAssertFalse(changed.contains("same.fit"),
                       "rewriting a file to store the value it already has is pointless")
    }

    func testSaveScopeAllCoversEverySolvedFrame() {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit"), confirmed("b.fit"), disagreeing("c.fit")]
        XCTAssertEqual(PlateSolveSaveScope.all.frames(in: report).count, 3)
        XCTAssertEqual(PlateSolveSaveScope.changedOnly.frames(in: report).count, 2)
    }

    func testSaveScopeNeverIncludesFailedOrSkippedFrames() {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit")]
        report.failed = [(entry: entry("bad.fit"), reason: "no solution found")]
        report.skippedUnsupported = [entry("thing.xisf")]

        for scope: PlateSolveSaveScope in [.all, .changedOnly] {
            let names = scope.frames(in: report).map { $0.entry.filename }
            XCTAssertFalse(names.contains("bad.fit"), "a frame without a solution must never be written")
            XCTAssertFalse(names.contains("thing.xisf"))
        }
    }

    func testChangedIsEmptyWhenEveryFrameConfirmedItsExistingSolve() {
        var report = PlateSolveReport()
        report.solved = [confirmed("a.fit"), confirmed("b.fit")]
        // This is what disables the "Save Changed" button rather than silently writing nothing.
        XCTAssertTrue(report.changedFrames.isEmpty)
    }

    // MARK: - Rows carry frame identity (click-to-jump)

    func testEveryRowCarriesTheIdentityOfItsFrame() {
        var report = PlateSolveReport()
        let solvedEntry = entry("a.fit")
        let failedEntry = entry("bad.fit")
        let skippedEntry = entry("thing.xisf")
        report.solved = [SolvedFrame(entry: solvedEntry,
                                     solution: solution(ra: 83.84, dec: -5.35),
                                     previous: nil, identification: nil)]
        report.failed = [(entry: failedEntry, reason: "x")]
        report.skippedUnsupported = [skippedEntry]

        let rows = PlateSolveResultBuilder.rows(from: report)
        let ids = Dictionary(uniqueKeysWithValues: rows.map { ($0.filename, $0.entryID) })
        // Without these, clicking a row could not find the frame in the file list.
        XCTAssertEqual(ids["a.fit"], solvedEntry.id)
        XCTAssertEqual(ids["bad.fit"], failedEntry.id)
        XCTAssertEqual(ids["thing.xisf"], skippedEntry.id)
    }

    // MARK: - Clipboard

    /// Split the clipboard export into its header names and data rows. Resolving columns BY
    /// NAME rather than by position keeps these tests honest when a column is added — the
    /// previous hardcoded indices silently pointed at the wrong data once RA/DEC arrived.
    private func clipboardTable(_ report: PlateSolveReport,
                                unsupportedCount: Int = 0) throws -> (header: [String], rows: [[String]]) {
        let text = PlateSolveResultBuilder.clipboardText(report: report,
                                                         unsupportedCount: unsupportedCount)
        let lines = text.split(separator: "\n").map(String.init)
        let headerIndex = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("STATUS\t") },
                                        "no tab-separated header row — this is what makes it paste into a spreadsheet")
        let header = lines[headerIndex].components(separatedBy: "\t")
        let rows = lines.dropFirst(headerIndex + 1)
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
        return (header, rows)
    }

    func testClipboardTextIsTabSeparatedAndRectangular() throws {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit")]
        report.duration = 1.5

        let table = try clipboardTable(report)
        // Every data row must have the same column count as the header.
        for row in table.rows {
            XCTAssertEqual(row.count, table.header.count,
                           "ragged row: \(row.joined(separator: " | "))")
        }
    }

    func testClipboardCarriesCoordinatesAndOptics() throws {
        var report = PlateSolveReport()
        report.solved = [fresh("a.fit")]

        let table = try clipboardTable(report)
        for column in ["RA", "DEC", "SCALE_FL", "OPTICS"] {
            XCTAssertTrue(table.header.contains(column), "missing column \(column)")
        }
        let raIndex = try XCTUnwrap(table.header.firstIndex(of: "RA"))
        XCTAssertTrue(table.rows[0][raIndex].contains("h"), "RA not sexagesimal: \(table.rows[0][raIndex])")
    }

    func testClipboardStripsUnitsSoNumbersStayNumeric() throws {
        var report = PlateSolveReport()
        report.solved = [disagreeing("c.fit")]

        let table = try clipboardTable(report)
        let row = try XCTUnwrap(table.rows.first { $0.first == "Differs" })

        // The three delta columns must read as numbers in a spreadsheet.
        for column in ["D_CENTRE_ARCMIN", "D_SCALE_PCT", "D_ROT_DEG"] {
            let index = try XCTUnwrap(table.header.firstIndex(of: column))
            XCTAssertNotNil(Double(row[index]), "\(column) not numeric: \(row[index])")
        }
    }

    func testClipboardCarriesTheContextAboveTheTable() {
        var report = PlateSolveReport()
        report.solved = [confirmed("a.fit")]
        report.written = 1
        report.backupDirectory = URL(fileURLWithPath: "/tmp/_platesolve_backup_x")

        let text = PlateSolveResultBuilder.clipboardText(report: report, unsupportedCount: 2)
        XCTAssertTrue(text.contains("AstroBlink plate solve"))
        XCTAssertTrue(text.contains("Confirmed existing solve: 1"))
        XCTAssertTrue(text.contains("WCS written into files: 1"))
        XCTAssertTrue(text.contains("_platesolve_backup_x"))
        XCTAssertTrue(text.contains("Skipped, unsupported format: 2"))
    }

    func testClipboardOfAnEmptyReportStillProducesAHeader() {
        let text = PlateSolveResultBuilder.clipboardText(report: PlateSolveReport(),
                                                         unsupportedCount: 0)
        XCTAssertTrue(text.contains("STATUS\t"))
    }
}
