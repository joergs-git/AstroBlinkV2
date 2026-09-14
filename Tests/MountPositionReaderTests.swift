// Tests for reading the mount's pointing out of frame headers.
//
// This is what turns a whole-sky search into a local one: without it ASTAP's `-r` radius has
// no centre to be a radius around, and a real RC12 narrowband frame took 33 s instead of 4 s.
//
// The sign handling is the trap: "-05 21 04" is minus five degrees twenty-one minutes, not
// minus five PLUS twenty-one minutes.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class MountPositionReaderTests: XCTestCase {

    // MARK: - Right ascension

    func testDecimalRightAscensionIsDegrees() throws {
        // What NINA writes into RA — the value from the IC1848 test frame.
        let ra = try XCTUnwrap(MountPositionReader.parseRightAscension("44.2476579730193"))
        XCTAssertEqual(ra, 44.2477, accuracy: 0.001)
    }

    func testSexagesimalRightAscensionIsHours() throws {
        // OBJCTRA on the same frame: '02 57 00' = 2h57m = 44.25°. Reading it as DEGREES
        // instead of hours would put the search 41° away and the solve would fail.
        let ra = try XCTUnwrap(MountPositionReader.parseRightAscension("'02 57 00'"))
        XCTAssertEqual(ra, 44.25, accuracy: 0.01)
    }

    func testRightAscensionAcceptsColonsAndQuotes() throws {
        XCTAssertEqual(try XCTUnwrap(MountPositionReader.parseRightAscension("02:57:00")),
                       44.25, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(MountPositionReader.parseRightAscension("\"02 57 00\"")),
                       44.25, accuracy: 0.01)
    }

    // MARK: - Declination

    func testDecimalDeclination() throws {
        XCTAssertEqual(try XCTUnwrap(MountPositionReader.parseDeclination("60.6337836806696")),
                       60.6338, accuracy: 0.001)
    }

    func testSexagesimalDeclinationWithExplicitPlus() throws {
        // '+60 38 02' = 60 + 38/60 + 2/3600
        XCTAssertEqual(try XCTUnwrap(MountPositionReader.parseDeclination("'+60 38 02'")),
                       60.6339, accuracy: 0.001)
    }

    func testNegativeSexagesimalDeclinationAppliesTheSignToTheWholeValue() throws {
        // THE trap: -5°21'04.8" is -5.3513, NOT -5 + 0.35 = -4.65.
        let dec = try XCTUnwrap(MountPositionReader.parseDeclination("-05 21 04.8"))
        XCTAssertEqual(dec, -5.3513, accuracy: 0.001)
        XCTAssertLessThan(dec, -5.0, "the sign must cover minutes and seconds too")
    }

    func testNegativeDeclinationJustBelowZero() throws {
        // -00 30 00 is half a degree SOUTH; a sign attached only to the degrees field would
        // lose it entirely, because -0 is 0.
        let dec = try XCTUnwrap(MountPositionReader.parseDeclination("-00 30 00"))
        XCTAssertEqual(dec, -0.5, accuracy: 1e-6)
    }

    // MARK: - Rejection

    func testGarbageIsRejectedRatherThanGuessed() {
        for text in ["", "   ", "not a number", "''"] {
            XCTAssertNil(MountPositionReader.parseRightAscension(text), "accepted \(text)")
            XCTAssertNil(MountPositionReader.parseDeclination(text), "accepted \(text)")
        }
    }

    func testOutOfRangeSexagesimalFieldsAreRejected() {
        // 75 minutes is not a time; better no hint than a hint pointing somewhere wrong.
        XCTAssertNil(MountPositionReader.parseDeclination("+60 75 00"))
        XCTAssertNil(MountPositionReader.parseRightAscension("02 57 90"))
    }

    // MARK: - ASTAP's units

    func testConversionToWhatASTAPExpects() {
        // -ra is in HOURS, -spd is "south pole distance" = declination + 90.
        let position = MountPosition(raDegrees: 44.25, decDegrees: 60.6338)
        XCTAssertEqual(position.raHours, 2.95, accuracy: 0.001)
        XCTAssertEqual(position.southPoleDistance, 150.6338, accuracy: 0.001)

        let south = MountPosition(raDegrees: 83.84, decDegrees: -5.35)
        XCTAssertEqual(south.southPoleDistance, 84.65, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(south.southPoleDistance, 0, "spd must stay in [0,180]")
    }

    // MARK: - Reading a real frame

    func testReadsTheMountPositionFromARealXISF() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let frame = repoRoot.appendingPathComponent("TestImages")
            .appendingPathComponent("2026-03-03_IC1848_00-06-44_RC12_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0004__bin1x1_gain100_O50_T-10.00c.xisf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: frame.path),
                          "XISF test frame not present — skipping")

        let position = try XCTUnwrap(MountPositionReader.read(from: frame),
                                     "no pointing found — the solver would fall back to a whole-sky search")
        XCTAssertEqual(position.raDegrees, 44.2477, accuracy: 0.01)
        XCTAssertEqual(position.decDegrees, 60.6338, accuracy: 0.01)
    }

    func testReadsTheMountPositionFromARealFITS() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let frame = repoRoot.appendingPathComponent("TestImages")
            .appendingPathComponent("Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: frame.path),
                          "FITS test frame not present — skipping")

        let position = try XCTUnwrap(MountPositionReader.read(from: frame))
        XCTAssertEqual(position.raDegrees, 84.0959, accuracy: 0.01)
        XCTAssertEqual(position.decDegrees, -5.3581, accuracy: 0.01)
    }
}
