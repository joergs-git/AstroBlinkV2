import XCTest
@testable import AstroTriage

final class NINAFilenameParserTests: XCTestCase {

    // Real NINA filename pattern with all tokens
    func testFullNINAPattern() {
        let filename = "2026-03-06_IC1848_23-54-58_RASA_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0016__bin1x1_gain100_O50_T-10.00c__FWHM_4.15_FOCT_4.46.xisf"
        let tokens = NINAFilenameParser.parse(filename)

        XCTAssertEqual(tokens.date, "2026-03-06")
        XCTAssertEqual(tokens.time, "23:54:58")
        XCTAssertEqual(tokens.target, "IC1848")
        XCTAssertEqual(tokens.frameNumber, 16)
        XCTAssertEqual(tokens.exposure, 300.00)
        XCTAssertEqual(tokens.filter, "H")
        XCTAssertEqual(tokens.frameType, "LIGHT")
        XCTAssertEqual(tokens.gain, 100)
        XCTAssertEqual(tokens.offset, 50)
        XCTAssertEqual(tokens.binning, "1x1")
        XCTAssertEqual(tokens.sensorTemp, -10.00)
        XCTAssertEqual(tokens.telescope, "RASA")
        XCTAssertEqual(tokens.camera, "ZWO ASI6200MM Pro")
        XCTAssertEqual(tokens.fwhm, 4.15)
        XCTAssertEqual(tokens.focuserTemp, 4.46)
    }

    // Real NGC 6960 Veil pattern (no offset, no FWHM tokens)
    func testVeilPattern() {
        let filename = "2025-11-12_NGC 6960 Veil_20-48-31_RC12_ZWO ASI6200MM Pro_LIGHT_O_300.00s_#0002__bin1x1_gain100_T-10.00c.xisf"
        let tokens = NINAFilenameParser.parse(filename)

        XCTAssertEqual(tokens.date, "2025-11-12")
        XCTAssertEqual(tokens.time, "20:48:31")
        XCTAssertEqual(tokens.target, "NGC 6960 Veil")
        XCTAssertEqual(tokens.frameNumber, 2)
        XCTAssertEqual(tokens.exposure, 300.00)
        XCTAssertEqual(tokens.filter, "O")
        XCTAssertEqual(tokens.frameType, "LIGHT")
        XCTAssertEqual(tokens.gain, 100)
        XCTAssertNil(tokens.offset)
        XCTAssertEqual(tokens.sensorTemp, -10.00)
        XCTAssertEqual(tokens.telescope, "RC12")
    }

    // Cosmic Horseshoe with offset
    func testOffsetVsOIII() {
        let filename = "2026-01-24_LRG 3-757 CosmicHorseshoe Gravitational Lense_02-32-15_RC12_ZWO ASI6200MM Pro_LIGHT_L_180.00s_#0040__bin1x1_gain100_O50_T-10.00c.xisf"
        let tokens = NINAFilenameParser.parse(filename)

        XCTAssertEqual(tokens.filter, "L")
        XCTAssertEqual(tokens.offset, 50)
        XCTAssertEqual(tokens.exposure, 180.00)
        XCTAssertEqual(tokens.frameNumber, 40)
    }

    // OSC camera pattern with Lextr filter
    func testOSCCamera() {
        let filename = "2026-03-05_IC1848_23-32-03_RASA_ZWO ASI6200MC Pro_LIGHT_Lextr_300.00s_#0243__bin1x1_gain100_O50_T-10.00c.xisf"
        let tokens = NINAFilenameParser.parse(filename)

        XCTAssertEqual(tokens.filter, "Lextr")
        XCTAssertEqual(tokens.camera, "ZWO ASI6200MC Pro")
        XCTAssertEqual(tokens.frameNumber, 243)
    }

    // FLAT frame type
    func testFlatFrame() {
        let filename = "2026-01-24_LRG 3-757 CosmicHorseshoe Gravitational Lense_03-04-58_RC12_ZWO ASI6200MM Pro_FLAT_L_5.00s_#0011__bin1x1_gain100_O50_T-9.60c.xisf"
        let tokens = NINAFilenameParser.parse(filename)

        XCTAssertEqual(tokens.frameType, "FLAT")
        XCTAssertEqual(tokens.filter, "L")
        XCTAssertEqual(tokens.exposure, 5.00)
    }

    // Old-style FITS filename (different pattern)
    func testOldStyleFITS() {
        let filename = "Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-203709_-20.0C_0005.fit"
        let tokens = NINAFilenameParser.parse(filename)

        XCTAssertEqual(tokens.gain, 100)
        XCTAssertEqual(tokens.sensorTemp, -20.0)
    }

    // HFR token in filename
    func testHFRInFilename() {
        let filename = "2026-03-06_IC1848_23-54-58_RASA_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0016__bin1x1_gain100_O50_T-10.00c__FWHM_4.15_FOCT_4.46.xisf"
        let tokens = NINAFilenameParser.parse(filename)

        XCTAssertEqual(tokens.fwhm, 4.15)
        XCTAssertEqual(tokens.focuserTemp, 4.46)
    }
}
