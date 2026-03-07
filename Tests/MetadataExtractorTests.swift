import XCTest
@testable import AstroTriage

final class MetadataExtractorTests: XCTestCase {

    // Test that filename parsing provides baseline metadata
    func testFilenameParsedEntry() {
        let filename = "2026-03-06_IC1848_23-54-58_RASA_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0016__bin1x1_gain100_O50_T-10.00c__FWHM_4.15_FOCT_4.46.xisf"
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        let tokens = NINAFilenameParser.parse(filename)

        var entry = ImageEntry(url: url)
        entry.date = tokens.date
        entry.filter = tokens.filter
        entry.gain = tokens.gain

        XCTAssertEqual(entry.date, "2026-03-06")
        XCTAssertEqual(entry.filter, "H")
        XCTAssertEqual(entry.gain, 100)
        XCTAssertEqual(entry.filename, filename)
    }

    // Test column value extraction
    func testColumnValues() {
        let url = URL(fileURLWithPath: "/tmp/test.xisf")
        var entry = ImageEntry(url: url, subfolder: "Ha")
        entry.frameNumber = 16
        entry.filter = "H"
        entry.exposure = 300.0
        entry.gain = 100
        entry.sensorTemp = -10.0
        entry.hfr = 2.34
        entry.target = "IC1848"

        XCTAssertEqual(ColumnDefinition.value(for: "frameNumber", from: entry), "16")
        XCTAssertEqual(ColumnDefinition.value(for: "filter", from: entry), "H")
        XCTAssertEqual(ColumnDefinition.value(for: "exposure", from: entry), "300s")
        XCTAssertEqual(ColumnDefinition.value(for: "gain", from: entry), "100")
        XCTAssertEqual(ColumnDefinition.value(for: "sensorTemp", from: entry), "-10.0")
        XCTAssertEqual(ColumnDefinition.value(for: "hfr", from: entry), "2.34")
        XCTAssertEqual(ColumnDefinition.value(for: "subfolder", from: entry), "Ha")
        XCTAssertEqual(ColumnDefinition.value(for: "filename", from: entry), "test.xisf")
        XCTAssertEqual(ColumnDefinition.value(for: "target", from: entry), "IC1848")
        XCTAssertEqual(ColumnDefinition.value(for: "date", from: entry), "")
    }
}
