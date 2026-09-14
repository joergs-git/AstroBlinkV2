// Tests for the XISF → temporary FITS path, and for converting a solution measured on a
// binned grid back to the original pixel grid.
//
// The binning round-trip is the part that can silently produce a plausible-but-wrong WCS:
// every coordinate would be off by a factor of two with no error anywhere.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class ASTAPFrameExporterTests: XCTestCase {

    // MARK: - Format gate

    func testXISFIsNowAccepted() {
        XCTAssertTrue(ASTAPSolver.supportedExtensions.contains("xisf"))
        XCTAssertTrue(ASTAPSolver.convertedExtensions.contains("xisf"),
                      "XISF must go through conversion — ASTAP cannot read it directly")
        XCTAssertFalse(ASTAPSolver.nativeExtensions.contains("xisf"),
                       "handing an XISF straight to ASTAP makes it hang on its GUI")
    }

    func testFITSStillGoesStraightToASTAP() {
        for ext in ["fit", "fits", "fts"] {
            XCTAssertTrue(ASTAPSolver.nativeExtensions.contains(ext))
        }
    }

    func testAnUnknownFormatIsStillRejectedWithoutLaunchingASTAP() {
        let outcome = ASTAPSolver().solve(
            url: URL(fileURLWithPath: "/tmp/nope.tif"),
            fovDegrees: 1.9,
            binary: URL(fileURLWithPath: "/nonexistent/astap"),
            database: URL(fileURLWithPath: "/nonexistent/db")
        )
        XCTAssertEqual(outcome, .unsupportedFormat("tif"))
    }

    // MARK: - Binning

    func testBin2x2AveragesEachBlock() {
        // 4x2 image; each 2x2 block averages to a known value.
        let source: [UInt16] = [
            10, 20, 100, 200,
            30, 40, 300, 400
        ]
        let (binned, w, h) = source.withUnsafeBufferPointer {
            ASTAPFrameExporter.bin2x2($0, width: 4, height: 2)
        }
        XCTAssertEqual(w, 2)
        XCTAssertEqual(h, 1)
        XCTAssertEqual(binned, [25, 250])       // (10+20+30+40)/4, (100+200+300+400)/4
    }

    func testBin2x2CannotOverflowOn16BitMaxima() {
        // Summing four 65535s overflows UInt16 — the implementation must widen before dividing.
        let source = [UInt16](repeating: 65535, count: 4)
        let (binned, _, _) = source.withUnsafeBufferPointer {
            ASTAPFrameExporter.bin2x2($0, width: 2, height: 2)
        }
        XCTAssertEqual(binned, [65535])
    }

    func testBin2x2DropsAnOddEdgeRatherThanReadingPastTheBuffer() {
        // 3x3 → 1x1. Reading a half-block would run off the end of the row.
        let source: [UInt16] = [1, 2, 3,
                                4, 5, 6,
                                7, 8, 9]
        let (binned, w, h) = source.withUnsafeBufferPointer {
            ASTAPFrameExporter.bin2x2($0, width: 3, height: 3)
        }
        XCTAssertEqual(w, 1)
        XCTAssertEqual(h, 1)
        XCTAssertEqual(binned, [3])             // (1+2+4+5)/4
    }

    // MARK: - Un-binning the solution

    private func solution(crpix1: Double = 100.5, crpix2: Double = 50.5,
                          scaleArcsec: Double = 3.32) -> WCSSolution {
        let deg = scaleArcsec / 3600.0
        return WCSSolution(crval1: 83.84, crval2: -5.35,
                           crpix1: crpix1, crpix2: crpix2,
                           cd11: -deg, cd12: 0, cd21: 0, cd22: deg, crota2: 12)
    }

    func testRescaleLeavesTheSkyPositionAlone() {
        let binned = solution()
        let full = ASTAPSolver.rescale(binned, byBinningFactor: 2)
        // Binning changes the pixel grid, never where the telescope was pointing.
        XCTAssertEqual(full.crval1, binned.crval1)
        XCTAssertEqual(full.crval2, binned.crval2)
        XCTAssertEqual(full.crota2, binned.crota2, "rotation is scale-invariant")
    }

    func testRescaleHalvesThePlateScale() {
        let binned = solution(scaleArcsec: 3.32)
        let full = ASTAPSolver.rescale(binned, byBinningFactor: 2)
        // A 2x2 binned pixel spans twice the sky of an original one.
        XCTAssertEqual(full.arcsecPerPixel, 1.66, accuracy: 0.001)
    }

    func testRescaleMapsPixelCentresCorrectly() {
        // FITS pixel coordinates are 1-based and refer to pixel CENTRES, so the mapping is
        // x_full = f*(x_binned - 0.5) + 0.5. A bare multiplication would be off by half a
        // binned pixel — small, plausible, and wrong.
        let full = ASTAPSolver.rescale(solution(crpix1: 1.0, crpix2: 1.0), byBinningFactor: 2)
        XCTAssertEqual(full.crpix1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(full.crpix2, 1.5, accuracy: 1e-9)

        let centre = ASTAPSolver.rescale(solution(crpix1: 100.5, crpix2: 50.5), byBinningFactor: 2)
        XCTAssertEqual(centre.crpix1, 200.5, accuracy: 1e-9)
        XCTAssertEqual(centre.crpix2, 100.5, accuracy: 1e-9)
    }

    func testRescaleByOneIsIdentity() {
        let s = solution()
        let same = ASTAPSolver.rescale(s, byBinningFactor: 1)
        XCTAssertEqual(same, s)
    }

    // MARK: - Integration: a real XISF through the real chain

    /// Decode a real XISF, write the temporary FITS, and solve it with the installed ASTAP.
    /// Skips cleanly when ASTAP, the star database or the test frame is absent.
    func testRealXISFSolvesEndToEnd() throws {
        let locator = ASTAPLocator.shared
        let binary = try XCTUnwrap(locator.findBinary(), "ASTAP not installed — skipping")
        let database = URL(fileURLWithPath: "/usr/local/opt/astap")
        try XCTSkipUnless(locator.isStarDatabase(database), "No ASTAP star database — skipping")

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let frame = repoRoot.appendingPathComponent("TestImages")
            .appendingPathComponent("2026-03-03_IC1848_00-06-44_RC12_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0004__bin1x1_gain100_O50_T-10.00c.xisf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: frame.path),
                          "XISF test frame not present — skipping")

        // The exporter alone must produce a readable FITS.
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xisf-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let exported = try ASTAPFrameExporter.exportForSolving(source: frame, into: work)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.url.path))
        XCTAssertEqual(exported.binning, 2, "a 9576px frame should be binned")
        XCTAssertGreaterThan(exported.width, 1000)

        // …and the whole chain must land on the sky where this frame actually points.
        // The XISF header carries CRVAL1 44.2556 / CRVAL2 60.6446 (IC1848).
        // Use the hint the app actually computes: RC12 2455 mm with 3.76 µm pixels is
        // 0.316"/px, and the sensor is 6388 px tall → 0.561° of field. Binning does NOT change
        // the field of view, only the pixel count, so the hint is the same either way — that
        // equivalence is precisely what this asserts.
        let solver = ASTAPSolver()
        let started = Date()
        let outcome = solver.solve(url: frame,
                                   fovDegrees: 0.561,
                                   binary: binary,
                                   database: database)
        let elapsed = Date().timeIntervalSince(started)

        guard case .solved(let s) = outcome else {
            return XCTFail("real XISF solve failed: \(outcome.shortDescription)")
        }

        // Decode + write + solve. A blind solve of this frame takes ~30 s; if the hint stopped
        // reaching ASTAP through the conversion path, this is where it would show.
        XCTAssertLessThan(elapsed, 15, "hinted XISF solve took \(elapsed)s — FOV hint not effective?")
        XCTAssertEqual(s.crval1, 44.2556, accuracy: 0.5, "RA off target")
        XCTAssertEqual(s.crval2, 60.6446, accuracy: 0.5, "Dec off target")

        // RC12 at 2455 mm with 3.76 µm pixels → 0.316"/px. If the binning were not undone
        // this would come out at 0.63 and every downstream scale check would be wrong.
        XCTAssertEqual(s.arcsecPerPixel, 0.316, accuracy: 0.03,
                       "binning was not undone — solution still describes the binned grid")

        // The original must be untouched: no sidecars, no rewrite.
        let dir = frame.deletingLastPathComponent()
        let base = frame.deletingPathExtension().lastPathComponent
        for sidecar in ["\(base).ini", "\(base).wcs"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(sidecar).path),
                           "ASTAP littered \(sidecar) next to the original")
        }
    }
}
