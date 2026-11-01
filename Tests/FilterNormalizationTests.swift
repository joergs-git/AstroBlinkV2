// FilterNormalizationTests.swift
// Filter-name classes for Filter Totals and the Frame History charts (6.11.0).
// Regression for a real session: 460 L-eXtreme ("Extr") frames were counted as "L" next to 40
// true luminance frames, because the dual-band names sat in the luminance alias list.

import XCTest
@testable import AstroTriage

final class FilterNormalizationTests: XCTestCase {

    private func norm(_ raw: String) -> String { FrameHistoryModel.normalizeFilterForChart(raw) }

    func testDualBandFiltersAreNotLuminance() {
        for raw in ["Extr", "EXTR", "Lextr", "L-eXtreme", "L_extreme", "Lext"] {
            XCTAssertEqual(norm(raw), "Lextr", raw)
        }
        for raw in ["Lenh", "L-eNhance", "LE", "Enhance"] {
            XCTAssertEqual(norm(raw), "Lenh", raw)
        }
        for raw in ["Lult", "L-Ultimate"] {
            XCTAssertEqual(norm(raw), "Lult", raw)
        }
        for raw in ["Duo", "DuoBand", "Dual-Band", "ALP-T", "NBZ"] {
            XCTAssertEqual(norm(raw), "Duo", raw)
        }
        for raw in ["L-Quad", "Lqua", "QuadBand"] {
            XCTAssertEqual(norm(raw), "Quad", raw)
        }
    }

    func testLuminanceFamilyStillMapsToL() {
        for raw in ["L", "Lum", "Luminance", "L-Pro", "Clear", "UVIRCut"] {
            XCTAssertEqual(norm(raw), "L", raw)
        }
    }

    func testNarrowbandAndBroadbandAliasesUnchanged() {
        XCTAssertEqual(norm("H"), "Ha")
        XCTAssertEqual(norm("H-Alpha"), "Ha")
        XCTAssertEqual(norm("O3"), "OIII")
        XCTAssertEqual(norm("S2"), "SII")
        XCTAssertEqual(norm("R"), "R")
        XCTAssertEqual(norm("IR-Pass"), "IR")
        XCTAssertEqual(norm("Hbeta"), "Hbeta", "unknown names pass through unchanged")
        XCTAssertEqual(norm(""), "?")
    }

    func testSortOrderPutsDualBandAfterNarrowband() {
        let sorted = FrameHistoryModel.sortedFilters(["Quad", "Lextr", "OIII", "L", "Ha", "Lenh", "IR"])
        XCTAssertEqual(sorted, ["L", "Ha", "OIII", "Lextr", "Lenh", "Quad", "IR"])
    }

    /// Scoring, charts and Color Combine share one table (6.11.1): what the chart calls Lextr,
    /// the scorer treats as narrowband, and an "H" alias canonicalizes the same way everywhere.
    func testScoringClassesAgreeWithDisplayClasses() {
        XCTAssertEqual(FilterClasses.canonicalName("H"), "Ha")
        XCTAssertEqual(FilterClasses.canonicalName("OIII 7nm"), "OIII")
        XCTAssertEqual(FilterClasses.canonicalName("Extr"), "Extr", "no alias → passes through")
        XCTAssertEqual(ColorCombineEngine.canonicalFilterName("S2"), "SII")
        XCTAssertTrue(FilterClasses.isNarrowbandLike("Extr"))
        XCTAssertTrue(FilterClasses.isNarrowbandLike("H"))
        XCTAssertTrue(FilterClasses.isNarrowbandLike("L-Quad"))
        XCTAssertFalse(FilterClasses.isNarrowbandLike("L-Pro"))
        XCTAssertFalse(FilterClasses.isNarrowbandLike("R"))
        XCTAssertEqual(FilterClasses.dualBandClass("Lextr"), "Lextr")
        XCTAssertNil(FilterClasses.dualBandClass("Ha"))
    }

    /// The session that reported it: Extr must get its own row, L keeps only the true L frames.
    func testFilterTotalsRegression() {
        let frames: [(filter: String, count: Int)] = [("Extr", 460), ("L", 40), ("H", 320)]
        var totals: [String: Int] = [:]
        for frame in frames { totals[norm(frame.filter), default: 0] += frame.count }
        XCTAssertEqual(totals, ["Lextr": 460, "L": 40, "Ha": 320])
    }
}
