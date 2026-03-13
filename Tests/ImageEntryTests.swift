import XCTest
@testable import AstroTriage

final class ImageEntryTests: XCTestCase {

    // MARK: - Observing Night

    func testObservingNightBeforeMidnight() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = "2026-03-11"
        entry.time = "22:30:00"

        XCTAssertEqual(entry.observingNight, "2026-03-11",
                       "Pre-midnight images should keep the same date as observing night")
    }

    func testObservingNightAfterMidnight() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = "2026-03-12"
        entry.time = "03:15:00"

        XCTAssertEqual(entry.observingNight, "2026-03-11",
                       "Post-midnight images should roll back to previous evening")
    }

    func testObservingNightExactMidnight() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = "2026-03-12"
        entry.time = "00:00:00"

        XCTAssertEqual(entry.observingNight, "2026-03-11",
                       "Midnight (00:00) should roll back to previous evening")
    }

    func testObservingNightNoonBoundary() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = "2026-03-12"
        entry.time = "12:00:00"

        XCTAssertEqual(entry.observingNight, "2026-03-12",
                       "Noon and later should keep the current date")
    }

    func testObservingNightNoTime() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = "2026-03-12"
        entry.time = nil

        XCTAssertEqual(entry.observingNight, "2026-03-12",
                       "No time available should return raw date")
    }

    func testObservingNightNoDate() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = nil
        entry.time = "03:15:00"

        XCTAssertNil(entry.observingNight, "No date should return nil")
    }

    // MARK: - Display Helpers (header vs computed priority)

    func testDisplayHFRPrefersHeader() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.hfr = 2.5           // header value
        entry.computedHFR = 3.0   // computed value

        XCTAssertEqual(entry.displayHFR, 2.5,
                       "displayHFR should prefer header value over computed")
        XCTAssertFalse(entry.hfrIsComputed)
    }

    func testDisplayHFRFallsBackToComputed() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.hfr = nil
        entry.computedHFR = 3.0

        XCTAssertEqual(entry.displayHFR, 3.0,
                       "displayHFR should fall back to computed when header is nil")
        XCTAssertTrue(entry.hfrIsComputed)
    }

    func testDisplayFWHMPrefersHeader() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.fwhm = 4.0
        entry.computedFWHM = 5.0

        XCTAssertEqual(entry.displayFWHM, 4.0)
        XCTAssertFalse(entry.fwhmIsComputed)
    }

    func testDisplayFWHMFallsBackToComputed() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.fwhm = nil
        entry.computedFWHM = 5.0

        XCTAssertEqual(entry.displayFWHM, 5.0)
        XCTAssertTrue(entry.fwhmIsComputed)
    }

    func testDisplayStarCountPrefersHeader() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.starCount = 400
        entry.computedStarCount = 500

        XCTAssertEqual(entry.displayStarCount, 400)
        XCTAssertFalse(entry.starCountIsComputed)
    }

    func testDisplayStarCountFallsBackToComputed() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.starCount = nil
        entry.computedStarCount = 500

        XCTAssertEqual(entry.displayStarCount, 500)
        XCTAssertTrue(entry.starCountIsComputed)
    }

    func testDisplayValuesNilWhenBothMissing() {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))

        XCTAssertNil(entry.displayHFR)
        XCTAssertNil(entry.displayFWHM)
        XCTAssertNil(entry.displayStarCount)
    }

    // MARK: - File Size Formatting

    func testFileSizeFormattedMB() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.fileSize = 123_456_789  // ~117.7 MB

        XCTAssertEqual(entry.fileSizeFormatted, "117.7 MB")
    }

    func testFileSizeFormattedGB() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.fileSize = 2_147_483_648  // 2.0 GB

        XCTAssertEqual(entry.fileSizeFormatted, "2.0 GB")
    }

    func testFileSizeFormattedNil() {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        XCTAssertEqual(entry.fileSizeFormatted, "")
    }

    // MARK: - File Type Detection

    func testIsXISF() {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        XCTAssertTrue(entry.isXISF)
        XCTAssertFalse(entry.isFITS)
    }

    func testIsFITS() {
        let fits = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.fits"))
        XCTAssertTrue(fits.isFITS)
        XCTAssertFalse(fits.isXISF)

        let fit = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.fit"))
        XCTAssertTrue(fit.isFITS)

        let fts = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.fts"))
        XCTAssertTrue(fts.isFITS)
    }

    // MARK: - DateTime Combination

    func testDateTimeCombination() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = "2026-03-11"
        entry.time = "22:30:00"

        XCTAssertEqual(entry.dateTime, "2026-03-11 22:30:00")
    }

    func testDateTimeOnlyDate() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = "2026-03-11"
        entry.time = nil

        XCTAssertEqual(entry.dateTime, "2026-03-11")
    }

    func testDateTimeOnlyTime() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.date = nil
        entry.time = "22:30:00"

        XCTAssertEqual(entry.dateTime, "22:30:00")
    }

    func testDateTimeBothNil() {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        XCTAssertNil(entry.dateTime)
    }
}
