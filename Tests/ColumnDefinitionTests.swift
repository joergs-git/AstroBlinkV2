import XCTest
@testable import AstroTriage

final class ColumnDefinitionTests: XCTestCase {

    // MARK: - Exposure Formatting

    func testExposureFormattingWholeNumber() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.exposure = 300.0
        XCTAssertEqual(ColumnDefinition.value(for: "exposure", from: entry), "300s")
    }

    func testExposureFormattingDecimal() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.exposure = 0.5
        XCTAssertEqual(ColumnDefinition.value(for: "exposure", from: entry), "0.50s")
    }

    func testExposureFormattingOneSecond() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.exposure = 1.0
        XCTAssertEqual(ColumnDefinition.value(for: "exposure", from: entry), "1s")
    }

    func testExposureFormattingSubSecond() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.exposure = 0.001
        XCTAssertEqual(ColumnDefinition.value(for: "exposure", from: entry), "0.00s")
    }

    func testExposureFormattingNil() {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        XCTAssertEqual(ColumnDefinition.value(for: "exposure", from: entry), "")
    }

    // MARK: - SNR Calculation

    func testSNRCalculation() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.noiseMedian = 0.05
        entry.noiseMAD = 0.001

        let snrStr = ColumnDefinition.value(for: "snr", from: entry)
        XCTAssertEqual(snrStr, "50", "SNR = median/MAD = 0.05/0.001 = 50")
    }

    func testSNRZeroMAD() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.noiseMedian = 0.05
        entry.noiseMAD = 0.0

        let snrStr = ColumnDefinition.value(for: "snr", from: entry)
        XCTAssertEqual(snrStr, "", "SNR with zero MAD should return empty string (not crash)")
    }

    func testSNRNilValues() {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        XCTAssertEqual(ColumnDefinition.value(for: "snr", from: entry), "")
    }

    func testSNRNumericValue() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.noiseMedian = 0.1
        entry.noiseMAD = 0.002

        let numericSNR = ColumnDefinition.numericValue(for: "snr", from: entry)
        XCTAssertNotNil(numericSNR)
        XCTAssertEqual(numericSNR!, 50.0, accuracy: 0.001)
    }

    func testSNRNumericValueZeroMAD() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.noiseMedian = 0.05
        entry.noiseMAD = 0.0

        XCTAssertNil(ColumnDefinition.numericValue(for: "snr", from: entry),
                     "SNR with zero MAD should return nil (not infinity)")
    }

    // MARK: - Numeric Value for Non-Numeric Columns

    func testNumericValueNilForStringColumns() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.filter = "H"
        entry.target = "IC1848"

        XCTAssertNil(ColumnDefinition.numericValue(for: "filter", from: entry))
        XCTAssertNil(ColumnDefinition.numericValue(for: "filename", from: entry))
        XCTAssertNil(ColumnDefinition.numericValue(for: "target", from: entry))
        XCTAssertNil(ColumnDefinition.numericValue(for: "subfolder", from: entry))
        XCTAssertNil(ColumnDefinition.numericValue(for: "camera", from: entry))
        XCTAssertNil(ColumnDefinition.numericValue(for: "telescope", from: entry))
    }

    // MARK: - All Columns No Crash

    func testAllColumnIdsReturnValuesWithoutCrash() {
        // Fully populated entry — every column should return a value without crashing
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"), subfolder: "Ha")
        entry.frameNumber = 16
        entry.filter = "H"
        entry.time = "23:54:58"
        entry.date = "2026-03-06"
        entry.exposure = 300.0
        entry.hfr = 2.34
        entry.starCount = 450
        entry.sensorTemp = -10.0
        entry.fwhm = 3.5
        entry.gain = 100
        entry.offset = 50
        entry.binning = "1x1"
        entry.telescope = "RASA"
        entry.camera = "ASI6200MM"
        entry.target = "IC1848"
        entry.frameType = "LIGHT"
        entry.focuserTemp = 4.5
        entry.ambientTemp = 8.0
        entry.fileSize = 120_000_000
        entry.noiseMedian = 0.05
        entry.noiseMAD = 0.001
        entry.qualityTier = .good

        for col in ColumnDefinition.allColumns {
            // This should never crash
            let _ = ColumnDefinition.value(for: col.identifier, from: entry)
            let _ = ColumnDefinition.numericValue(for: col.identifier, from: entry)
        }
    }

    func testAllColumnIdsWithEmptyEntry() {
        // Minimal entry — should still not crash on any column
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))

        for col in ColumnDefinition.allColumns {
            let _ = ColumnDefinition.value(for: col.identifier, from: entry)
            let _ = ColumnDefinition.numericValue(for: col.identifier, from: entry)
        }
    }

    // MARK: - Default Descending

    func testIsDefaultDescendingNumericColumns() {
        // All numeric columns should be default descending
        let numericColumns = ["frameNumber", "exposure", "hfr", "starCount", "sensorTemp",
                              "fwhm", "gain", "offset", "focuserTemp", "ambientTemp",
                              "fileSize", "snr", "quality"]
        for col in numericColumns {
            XCTAssertTrue(ColumnDefinition.isDefaultDescending(col),
                          "\(col) should be default descending")
        }
    }

    func testIsDefaultDescendingTextColumns() {
        // Text columns should NOT be default descending
        let textColumns = ["filter", "filename", "target", "subfolder", "camera",
                           "telescope", "binning", "frameType"]
        for col in textColumns {
            XCTAssertFalse(ColumnDefinition.isDefaultDescending(col),
                           "\(col) should NOT be default descending")
        }
    }

    // MARK: - Is Numeric Column

    func testIsNumericColumn() {
        XCTAssertTrue(ColumnDefinition.isNumericColumn("fwhm"))
        XCTAssertTrue(ColumnDefinition.isNumericColumn("snr"))
        XCTAssertTrue(ColumnDefinition.isNumericColumn("quality"))
        XCTAssertFalse(ColumnDefinition.isNumericColumn("filter"))
        XCTAssertFalse(ColumnDefinition.isNumericColumn("filename"))
    }

    // MARK: - Quality Column

    func testQualityColumnReturnsEmptyString() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))
        entry.qualityTier = .good

        XCTAssertEqual(ColumnDefinition.value(for: "quality", from: entry), "",
                       "Quality column text should be empty (rendered as icon)")
    }

    func testQualityNumericValue() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test.xisf"))

        // With z-score: returns z-score for fine-grained sorting within tiers
        entry.qualityTier = .excellent
        entry.qualityZScore = 1.5
        XCTAssertEqual(ColumnDefinition.numericValue(for: "quality", from: entry), 1.5)

        // Without z-score: falls back to tier rawValue
        entry.qualityZScore = nil
        entry.qualityTier = .excellent
        XCTAssertEqual(ColumnDefinition.numericValue(for: "quality", from: entry), 3.0)

        entry.qualityTier = .good
        XCTAssertEqual(ColumnDefinition.numericValue(for: "quality", from: entry), 2.0)

        entry.qualityTier = .borderline
        XCTAssertEqual(ColumnDefinition.numericValue(for: "quality", from: entry), 1.0)

        entry.qualityTier = .trash
        XCTAssertEqual(ColumnDefinition.numericValue(for: "quality", from: entry), 0.0)

        entry.qualityTier = nil
        XCTAssertNil(ColumnDefinition.numericValue(for: "quality", from: entry))
    }
}
