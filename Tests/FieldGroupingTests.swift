// FieldGroupingTests.swift
// Sky-field grouping + the LightspeedStacker gate (6.10.0). The numbers of the first three tests
// are the real headers of the session that triggered the change: an 85 mm refractor (468 mm,
// ASI2600MC, 1.657"/px, 2.88° × 1.92° field) with SH2-157 and SH2-188 in one folder.

import XCTest
@testable import AstroTriage

final class FieldGroupingTests: XCTestCase {

    // MARK: - Fixtures

    /// ASI2600MC on the 85 mm (468 mm) — the user's setup.
    private func frame(_ name: String, ra: Double?, dec: Double?, target: String? = nil,
                       focalLength: Double? = 468, pixelSize: Double? = 3.76,
                       width: Int? = 6248, height: Int? = 4176) -> ImageEntry {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(name).fit"))
        entry.solvedRA = ra
        entry.solvedDec = dec
        entry.target = target
        entry.focalLength = focalLength
        entry.pixelSizeMicrons = pixelSize
        entry.width = width
        entry.height = height
        entry.binning = "1x1"
        return entry
    }

    private func sh2157(_ n: Int) -> [ImageEntry] {
        (0..<n).map { i in
            frame("SH2-157_\(i)", ra: 349.002 + Double(i % 3) * 0.004, dec: 60.062 - Double(i % 2) * 0.003, target: "SH2-157")
        }
    }

    private func sh2188(_ n: Int) -> [ImageEntry] {
        (0..<n).map { i in
            frame("SH2-188_\(i)", ra: 22.713 + Double(i % 3) * 0.005, dec: 58.357 + Double(i % 2) * 0.004, target: "SH2-188")
        }
    }

    // MARK: - Separation

    func testHaversineAcrossZeroHours() {
        let sep = FieldGrouping.angularSeparation(ra1: 359.8, dec1: 60, ra2: 0.3, dec2: 60)
        XCTAssertEqual(sep, 0.5 * cos(60 * Double.pi / 180), accuracy: 0.002,
                       "a field straddling 0h RA is 0.25° wide, not 359°")
    }

    func testSeparationOfTheTwoRealObjects() {
        let sep = FieldGrouping.angularSeparation(ra1: 349.002, dec1: 60.062, ra2: 22.713, dec2: 58.357)
        XCTAssertEqual(sep, 17.15, accuracy: 0.05)
    }

    // MARK: - Field of view & tolerance

    func testFieldSizeAndToleranceFollowTheOptics() throws {
        let entries = sh2157(4)
        let size = try XCTUnwrap(FieldGrouping.fieldSize(of: entries[0]))
        XCTAssertEqual(size.width, 2.88, accuracy: 0.02)
        XCTAssertEqual(size.height, 1.92, accuracy: 0.02)
        let tolerance = FieldGrouping.tolerance(for: entries)
        XCTAssertEqual(tolerance.degrees, 0.6 * 2.88, accuracy: 0.02, "60% of the larger edge")
    }

    func testLongFocalLengthShrinksTheTolerance() {
        // RC12 + ASI6200: 0.85° × 0.57° — two frames 0.7° apart share almost nothing
        let a = frame("rc_a", ra: 10.0, dec: 40.0, focalLength: 2423, width: 9576, height: 6388)
        let b = frame("rc_b", ra: 10.0 + 0.7 / cos(40 * Double.pi / 180), dec: 40.0,
                      focalLength: 2423, width: 9576, height: 6388)
        let tolerance = FieldGrouping.tolerance(for: [a, b])
        XCTAssertEqual(tolerance.degrees, 0.51, accuracy: 0.02)
        XCTAssertEqual(FieldGrouping.group([a, b, a, b]).fields.count, 2,
                       "0.7° apart on a 0.85° field = two fields (the old fixed 1° let this through)")
    }

    func testUnknownOpticsFallBackToOneDegree() {
        let a = frame("nofl_a", ra: 100.0, dec: 10.0, focalLength: nil, pixelSize: nil)
        let b = frame("nofl_b", ra: 100.0 + 1.2 / cos(10 * Double.pi / 180), dec: 10.0, focalLength: nil, pixelSize: nil)
        let tolerance = FieldGrouping.tolerance(for: [a, b])
        XCTAssertEqual(tolerance.degrees, 1.0)
        XCTAssertNil(tolerance.fieldSize)
        XCTAssertEqual(FieldGrouping.group([a, b, a]).fields.count, 2)
    }

    // MARK: - Grouping

    func testRealSessionSplitsIntoTwoFieldsSeventeenDegreesApart() {
        let entries = sh2157(7) + sh2188(5)
        let result = FieldGrouping.group(entries)

        XCTAssertEqual(result.fields.count, 2)
        let first = result.fields[0], second = result.fields[1]
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.frameCount, 7, "field 1 = the field with the most frames")
        XCTAssertEqual(first.targetNames, ["SH2-157"])
        XCTAssertEqual(second.frameCount, 5)
        XCTAssertEqual(second.targetNames, ["SH2-188"])
        XCTAssertEqual(second.separationFromFirst, 17.15, accuracy: 0.05)
        XCTAssertEqual(first.centerRA, 349.004, accuracy: 0.01)
        XCTAssertEqual(first.centerDec, 60.06, accuracy: 0.01)
        XCTAssertEqual(Array(result.assignments.prefix(7)), Array(repeating: 1, count: 7))
        XCTAssertEqual(Array(result.assignments.suffix(5)), Array(repeating: 2, count: 5))
        XCTAssertEqual(first.centerText, "23h16m +60°04'")
    }

    func testStaleCopiedSolveStaysInsideItsField() {
        // ASIAIR copies its last plate solve (the centering step, BEFORE the correction slew) into
        // the following frames: measured up to 1.38° off on this session. On a 2.88° field that is still the
        // same field — the old first-frame + fixed-1° gate refused the single object.
        var entries = sh2188(10)
        let stale = frame("SH2-188_stale", ra: 22.713 + 1.38 / cos(58.36 * Double.pi / 180), dec: 58.357, target: "SH2-188")
        entries.insert(stale, at: 0)      // as the FIRST frame — the old gate's reference
        let result = FieldGrouping.group(entries)
        XCTAssertEqual(result.fields.count, 1)
        XCTAssertEqual(result.fields[0].frameCount, 11)
        XCTAssertTrue(FieldGrouping.checkStackability(entries).isSingleField)
    }

    func testFieldStraddlingZeroHoursIsOneField() {
        let a = frame("z_a", ra: 359.9, dec: 67.0)
        let b = frame("z_b", ra: 0.2, dec: 67.0)
        let c = frame("z_c", ra: 0.05, dec: 67.1)
        let result = FieldGrouping.group([a, b, c])
        XCTAssertEqual(result.fields.count, 1)
        XCTAssertEqual(result.fields[0].centerRA, 0.05, accuracy: 0.1)
    }

    func testFramesWithoutCoordinatesAreUnassigned() {
        var entries = sh2157(3)
        entries.append(frame("blind", ra: nil, dec: nil, target: "SH2-157"))
        let result = FieldGrouping.group(entries)
        XCTAssertEqual(result.fields.count, 1)
        XCTAssertNil(result.assignments[3])
        XCTAssertEqual(result.assignments[0], 1)
    }

    func testObjctraFallbackWhenNoSolve() throws {
        var entry = frame("hdr", ra: nil, dec: nil)
        entry.objctRA = "23 16 00"
        entry.objctDec = "+60 02 00"
        let center = try XCTUnwrap(FieldGrouping.skyCenter(of: entry))
        XCTAssertEqual(center.ra, 349.0, accuracy: 0.001)
        XCTAssertEqual(center.dec, 60.0333, accuracy: 0.001)
        XCTAssertEqual(FieldGrouping.parseRA("23:16:00"), 349.0)
        XCTAssertEqual(FieldGrouping.parseDec("-12:30:00"), -12.5)
    }

    // MARK: - Stacking gate

    func testGateRefusesTheTwoRealObjectsWithAnHonestMessage() throws {
        let entries = sh2157(7) + sh2188(5)
        let check = FieldGrouping.checkStackability(entries)
        XCTAssertFalse(check.isSingleField)
        XCTAssertEqual(check.alertTitle, "Frames Point to Different Sky Fields")
        XCTAssertTrue(check.alertMessage.contains("Field 1: 7 frames · SH2-157"), check.alertMessage)
        XCTAssertTrue(check.alertMessage.contains("Field 2: 5 frames · SH2-188"), check.alertMessage)
        XCTAssertTrue(check.alertMessage.contains("° from field 1"), check.alertMessage)
        XCTAssertEqual(check.fields[1].separationFromFirst, 17.15, accuracy: 0.05)
        XCTAssertTrue(check.alertMessage.contains("Field of view 2.88° × 1.92°"), check.alertMessage)
        XCTAssertTrue(check.alertMessage.contains("1.73° apart"), check.alertMessage)
        // The lead frame for "Stack Anyway" belongs to field 1
        let lead = try XCTUnwrap(check.leadingEntryIndex)
        XCTAssertEqual(check.assignments[lead], 1)
    }

    func testGateAcceptsDifferentNamesInOneField() {
        // Two names, same patch of sky (an alias, a mosaic panel name, a typo) — coordinates win.
        var entries = sh2157(4)
        entries += sh2157(3).map { e in var c = e; c.target = "Lobster Claw"; return c }
        let check = FieldGrouping.checkStackability(entries)
        XCTAssertTrue(check.isSingleField)
        XCTAssertEqual(check.fields.first?.targetNames, ["Lobster Claw", "SH2-157"])
    }

    func testGateFallsBackToNamesWithoutAnyCoordinates() {
        let a = frame("n_a", ra: nil, dec: nil, target: "M81")
        let b = frame("n_b", ra: nil, dec: nil, target: "M82")
        let mixed = FieldGrouping.checkStackability([a, b, a])
        XCTAssertFalse(mixed.isSingleField)
        XCTAssertEqual(mixed.namesWithoutCoordinates, ["M81", "M82"])
        XCTAssertEqual(mixed.alertTitle, "Mixed Object Names")
        XCTAssertTrue(mixed.alertMessage.contains("M81, M82"))

        let same = FieldGrouping.checkStackability([a, a, a])
        XCTAssertTrue(same.isSingleField)
        let unknown = frame("n_u", ra: nil, dec: nil, target: "unknown")
        XCTAssertTrue(FieldGrouping.checkStackability([a, unknown, a]).isSingleField, "'unknown' is not a name")
    }

    func testFortyPercentOffsetStillStacks() {
        // The user's request: a frame 40% of the field width off-center must pass without a dialog.
        var entries = sh2157(6)
        let offset = 0.4 * 2.88
        entries.append(frame("off", ra: 349.002 + offset / cos(60.06 * Double.pi / 180), dec: 60.062, target: "SH2-157"))
        XCTAssertTrue(FieldGrouping.checkStackability(entries).isSingleField)
    }
}

// MARK: - Reference pixel placement (6.11.2)

extension FieldGroupingTests {

    /// ASIAIR puts CRPIX anywhere in the frame, so one stable pointing produced CRVALs 1.7° apart
    /// — right at the 1.73° tolerance of this field — and the C 9 session split into F1/F2
    /// frame by frame. The position must be the image center, which agrees to 4 arcseconds.
    func testScatteredReferencePixelsOfOnePointingAreOneField() {
        let entries = (0..<8).map { i in
            WCSProjectionTests.entry("c9_\(i)", i % 2 == 0 ? WCSProjectionTests.solutionA
                                                           : WCSProjectionTests.solutionB)
        }
        let result = FieldGrouping.group(entries)
        XCTAssertEqual(result.fields.count, 1, "one pointing, one field — whatever the reference pixel")
        XCTAssertEqual(result.assignments.compactMap { $0 }, Array(repeating: 1, count: 8))
        let center = result.fields[0]
        XCTAssertEqual(center.centerRA, 344.2287, accuracy: 0.002)
        XCTAssertEqual(center.centerDec, 62.6210, accuracy: 0.002)
    }
}

// MARK: - Move other fields into subfolders (6.12.0)

extension FieldGroupingTests {

    /// A frame already assigned to a sky field, the way the file list holds it.
    private func fieldFrame(_ name: String, field: Int?, target: String? = nil,
                            identified: String? = nil) -> ImageEntry {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/session/\(name).fit"))
        entry.fieldIndex = field
        entry.target = target
        entry.identifiedObject = identified
        return entry
    }

    /// The user's night: 30 frames of M45, five the mount had already slewed to NGC 6888.
    func testMajorityStaysMinorityMovesNamedAfterTheIdentifiedObject() throws {
        var selection = (0..<30).map { fieldFrame("m45_\($0)", field: 1, target: "M45", identified: "M45") }
        selection += (0..<5).map { fieldFrame("x_\($0)", field: 2, target: "M45", identified: "NGC6888") }
        selection.append(fieldFrame("nocoords", field: nil, target: "M45"))

        let plan = try XCTUnwrap(FieldGrouping.subfolderMovePlan(for: selection))
        XCTAssertEqual(plan.stayingField, 1)
        XCTAssertEqual(plan.stayingCount, 30)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].fieldIndex, 2)
        XCTAssertEqual(plan.groups[0].entries.count, 5)
        XCTAssertEqual(plan.groups[0].folderName, "NGC6888", "the identified object names the folder")
        XCTAssertEqual(plan.movingCount, 5)
        XCTAssertEqual(plan.withoutCoordinates, 1, "a frame without coordinates stays and is counted")
    }

    func testTheSelectionDecidesWhichFieldStaysNotTheSession() throws {
        // F1 is the session's largest field, but the user highlighted mostly F2 frames.
        let selection = (0..<2).map { fieldFrame("a\($0)", field: 1, target: "M45") }
                      + (0..<6).map { fieldFrame("b\($0)", field: 2, target: "NGC6888") }
        let plan = try XCTUnwrap(FieldGrouping.subfolderMovePlan(for: selection))
        XCTAssertEqual(plan.stayingField, 2)
        XCTAssertEqual(plan.groups.map(\.fieldIndex), [1])
        XCTAssertEqual(plan.groups[0].folderName, "M45", "no identification → the field's own OBJECT name")
    }

    func testTieKeepsTheLowerFieldIndex() throws {
        let selection = (0..<3).map { fieldFrame("a\($0)", field: 1) } + (0..<3).map { fieldFrame("b\($0)", field: 2) }
        let plan = try XCTUnwrap(FieldGrouping.subfolderMovePlan(for: selection))
        XCTAssertEqual(plan.stayingField, 1)
        XCTAssertEqual(plan.groups[0].folderName, "Field-F2", "no name at all → the field index")
    }

    func testNamesSharedWithTheStayingFieldDoNotNameTheFolder() throws {
        // Both fields say M45 (the mislabelled case before any OBJECT fix) and nothing was identified.
        let shared = (0..<4).map { fieldFrame("a\($0)", field: 1, target: "M45") }
                   + (0..<2).map { fieldFrame("b\($0)", field: 2, target: "m45") }
        XCTAssertEqual(try XCTUnwrap(FieldGrouping.subfolderMovePlan(for: shared)).groups[0].folderName, "Field-F2")

        // Two panels of one nebula: the identification matches the staying field → fall through.
        let panels = (0..<4).map { fieldFrame("p1_\($0)", field: 1, target: "NGC7000 P1", identified: "NGC7000") }
                   + (0..<3).map { fieldFrame("p2_\($0)", field: 2, target: "NGC7000 P2", identified: "NGC7000") }
        XCTAssertEqual(try XCTUnwrap(FieldGrouping.subfolderMovePlan(for: panels)).groups[0].folderName, "NGC7000 P2",
                       "the shared identification is skipped, the panel's own OBJECT name is not")
    }

    func testThreeFieldsGiveOneGroupPerMinorityField() throws {
        let selection = (0..<5).map { fieldFrame("a\($0)", field: 1, identified: "M45") }
                      + (0..<2).map { fieldFrame("b\($0)", field: 2, identified: "NGC6888") }
                      + [fieldFrame("c0", field: 3, identified: "IC1318")]
        let plan = try XCTUnwrap(FieldGrouping.subfolderMovePlan(for: selection))
        XCTAssertEqual(plan.groups.map(\.fieldIndex), [2, 3])
        XCTAssertEqual(plan.groups.map(\.folderName), ["NGC6888", "IC1318"])
        XCTAssertEqual(plan.movingCount, 3)
    }

    func testSingleFieldSelectionHasNoPlan() {
        let selection = (0..<4).map { fieldFrame("a\($0)", field: 1) } + [fieldFrame("n", field: nil)]
        XCTAssertNil(FieldGrouping.subfolderMovePlan(for: selection))
        XCTAssertNil(FieldGrouping.subfolderMovePlan(for: []))
    }

    func testFolderNamesAreFileSystemSafe() {
        XCTAssertEqual(FieldGrouping.sanitizedFolderName("SH2-157 / Panel: 2"), "SH2-157 - Panel- 2")
        XCTAssertNil(FieldGrouping.sanitizedFolderName("  "))
        XCTAssertNil(FieldGrouping.sanitizedFolderName(".."))
        let odd = [fieldFrame("a", field: 1), fieldFrame("b", field: 2, target: ".")]
        XCTAssertEqual(FieldGrouping.subfolderMovePlan(for: odd)?.groups[0].folderName, "Field-F2",
                       "an unusable name falls back to the field index")
    }
}
