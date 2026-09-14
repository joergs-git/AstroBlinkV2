// Tests for the ASTAP plate-solving logic that needs no ASTAP installation:
// .ini parsing, field-of-view derivation and the header keywords written back.
//
// The .ini samples are VERBATIM ASTAP output captured during the feasibility spike on a real
// 26 MP ASIAIR frame — not hand-written approximations.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class PlateSolveTests: XCTestCase {

    // MARK: - .ini parsing

    /// Real ASTAP output from a successful solve.
    private let solvedINI = """
    PLTSOLVD=T
    CRPIX1= 3.1245000000000000E+003
    CRPIX2= 2.0885000000000000E+003
    CRVAL1= 8.3840512504517406E+001
    CRVAL2=-5.3513386999708761E+000
    CDELT1= 4.6084433707660103E-004
    CDELT2= 4.6095361095934692E-004
    CROTA1= 9.6504829685836569E+001
    CROTA2= 9.6613897244908472E+001
    CD1_1=-5.2207656483851631E-005
    CD1_2=-4.5787756400596442E-004
    CD2_1= 4.5788589925331249E-004
    CD2_2=-5.3091757565994505E-005
    CMDLINE=/Applications/ASTAP.app/Contents/MacOS/astap -f /tmp/t1.fit -r 180 -fov 0 -wcs
    DIMENSIONS=6248 x 4176
    WARNING=Warning inexact scale! Set FOV=1.92d or scale=1.7"/pix or FL=467mm
    """

    /// Real ASTAP output when handed a file it cannot read (this is what XISF produces).
    private let failedINI = """
    PLTSOLVD=F
    CMDLINE=/Applications/ASTAP.app/Contents/MacOS/astap -f /tmp/t2.xisf -r 30 -wcs
    DIMENSIONS=100 x 100
    ERROR=Error reading image file.
    """

    func testParsesSuccessfulSolve() throws {
        let outcome = ASTAPSolver.parse(ini: solvedINI)
        guard case .solved(let s) = outcome else {
            return XCTFail("expected a solution, got \(outcome)")
        }
        XCTAssertEqual(s.crval1, 83.840512504517406, accuracy: 1e-9)
        XCTAssertEqual(s.crval2, -5.3513386999708761, accuracy: 1e-9)
        XCTAssertEqual(s.crpix1, 3124.5, accuracy: 1e-6)
        XCTAssertEqual(s.cd11, -5.2207656483851631E-005, accuracy: 1e-15)
        XCTAssertEqual(s.cd22, -5.3091757565994505E-005, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(s.crota2), 96.613897244908472, accuracy: 1e-9)
    }

    func testDerivedPixelScaleMatchesASTAPsOwnWarning() {
        // ASTAP itself reported 1.7"/pix for this frame; the CD matrix must agree.
        guard case .solved(let s) = ASTAPSolver.parse(ini: solvedINI) else {
            return XCTFail("expected a solution")
        }
        XCTAssertEqual(s.arcsecPerPixel, 1.66, accuracy: 0.05)
    }

    func testFailedSolveCarriesASTAPsOwnReason() {
        let outcome = ASTAPSolver.parse(ini: failedINI)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        // The reason must survive intact — it is the only diagnostic the user gets.
        XCTAssertEqual(reason, "Error reading image file.")
    }

    func testUnsolvedWithoutErrorKeyStillFails() {
        XCTAssertEqual(ASTAPSolver.parse(ini: "PLTSOLVD=F\nDIMENSIONS=10 x 10"),
                       .failed(reason: "no solution found"))
    }

    func testSolvedButIncompleteIsTreatedAsFailure() {
        // Never write a partial WCS: a CD matrix missing an element is not a solution.
        let partial = """
        PLTSOLVD=T
        CRVAL1= 8.0E+001
        CRVAL2=-5.0E+000
        CRPIX1= 1.0E+003
        CRPIX2= 1.0E+003
        CD1_1=-5.0E-005
        """
        XCTAssertEqual(ASTAPSolver.parse(ini: partial), .failed(reason: "solution was incomplete"))
    }

    func testEmptyOutputFails() {
        guard case .failed = ASTAPSolver.parse(ini: "") else {
            return XCTFail("empty .ini must not parse as solved")
        }
    }

    func testKeysContainingFurtherEqualsSignsDoNotCorruptParsing() {
        // CMDLINE and WARNING both contain '=' and '!'; splitting on every '=' would break.
        guard case .solved = ASTAPSolver.parse(ini: solvedINI) else {
            return XCTFail("expected a solution")
        }
    }

    // MARK: - Field of view

    func testFOVForTheSpikeFrame() {
        // 4176 px at 1.66"/px ≈ 1.93° — the value that turned a 4.2 s solve into 0.3 s.
        let fov = ASTAPSolver.fieldOfViewDegrees(heightPixels: 4176,
                                                 arcsecPerPixel: 1.66,
                                                 binning: "1x1")
        XCTAssertEqual(try XCTUnwrap(fov), 1.926, accuracy: 0.01)
    }

    func testBinningDoublesTheField() {
        // XPIXSZ is the PHYSICAL pixel size, so a 2x2 frame covers twice the sky per pixel.
        let unbinned = ASTAPSolver.fieldOfViewDegrees(heightPixels: 2000, arcsecPerPixel: 1.0, binning: "1x1")
        let binned   = ASTAPSolver.fieldOfViewDegrees(heightPixels: 2000, arcsecPerPixel: 1.0, binning: "2x2")
        XCTAssertEqual(try XCTUnwrap(binned), try XCTUnwrap(unbinned) * 2, accuracy: 1e-9)
    }

    func testBinningFactorParsing() {
        XCTAssertEqual(ASTAPSolver.binningFactor("1x1"), 1)
        XCTAssertEqual(ASTAPSolver.binningFactor("2x2"), 2)
        XCTAssertEqual(ASTAPSolver.binningFactor("4X4"), 4)
        // Anything unexpected must degrade to 1, never to 0 or a wild value.
        XCTAssertEqual(ASTAPSolver.binningFactor(nil), 1)
        XCTAssertEqual(ASTAPSolver.binningFactor(""), 1)
        XCTAssertEqual(ASTAPSolver.binningFactor("garbage"), 1)
        XCTAssertEqual(ASTAPSolver.binningFactor("99x99"), 1)
    }

    func testMissingOpticsYieldsNoHint() {
        // No hint is fine — ASTAP searches for the scale. A WRONG hint is what costs us.
        XCTAssertNil(ASTAPSolver.fieldOfViewDegrees(heightPixels: nil, arcsecPerPixel: 1.6, binning: "1x1"))
        XCTAssertNil(ASTAPSolver.fieldOfViewDegrees(heightPixels: 4176, arcsecPerPixel: nil, binning: "1x1"))
        XCTAssertNil(ASTAPSolver.fieldOfViewDegrees(heightPixels: 0, arcsecPerPixel: 1.6, binning: "1x1"))
    }

    func testImplausibleFieldIsRejectedRatherThanPassedOn() {
        // A broken FOCALLEN header produces absurd scales; passing those on is worse than nil.
        XCTAssertNil(ASTAPSolver.fieldOfViewDegrees(heightPixels: 4176, arcsecPerPixel: 1000, binning: "1x1"))
        XCTAssertNil(ASTAPSolver.fieldOfViewDegrees(heightPixels: 10, arcsecPerPixel: 0.0001, binning: "1x1"))
    }

    // MARK: - Write-back keywords

    func testWrittenKeywordsCoverEverythingMetadataExtractorReads() {
        guard case .solved(let s) = ASTAPSolver.parse(ini: solvedINI) else {
            return XCTFail("expected a solution")
        }
        let keys = Set(PlateSolveEngine.keywords(for: s).map(\.0))
        for required in ["CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2",
                         "CD1_1", "CD1_2", "CD2_1", "CD2_2", "CROTA2"] {
            XCTAssertTrue(keys.contains(required), "missing \(required)")
        }
        // Without CTYPE the frame is not a valid WCS for other tools.
        XCTAssertTrue(keys.contains("CTYPE1"))
        XCTAssertTrue(keys.contains("CTYPE2"))
    }

    func testCDMatrixSurvivesFormattingRoundTrip() throws {
        // CD elements are ~1e-5 deg/px; fixed-point formatting would quantise the plate
        // scale away entirely. This is the regression guard for that.
        guard case .solved(let s) = ASTAPSolver.parse(ini: solvedINI) else {
            return XCTFail("expected a solution")
        }
        let pairs = Dictionary(uniqueKeysWithValues: PlateSolveEngine.keywords(for: s))
        let roundTripped = try XCTUnwrap(Double(try XCTUnwrap(pairs["CD1_1"])))
        XCTAssertEqual(roundTripped, s.cd11, accuracy: abs(s.cd11) * 1e-9)
        XCTAssertNotEqual(roundTripped, 0, "CD1_1 must not be flattened to zero")
    }

    // MARK: - Format gate

    func testXISFIsNeverHandedDirectlyToASTAP() {
        // ASTAP cannot read XISF and hangs on its GUI when handed one. Since v6.9.0 XISF IS
        // supported — but only through in-process conversion to a temporary FITS, never by
        // passing the file itself. That distinction is the whole safety of the format gate.
        XCTAssertTrue(ASTAPSolver.supportedExtensions.contains("xisf"))
        XCTAssertFalse(ASTAPSolver.nativeExtensions.contains("xisf"))
        for ext in ["fit", "fits", "fts"] {
            XCTAssertTrue(ASTAPSolver.nativeExtensions.contains(ext))
        }
    }

    func testSolveRejectsUnsupportedFormatWithoutLaunchingASTAP() {
        // Must fail fast on the extension, before any process is spawned — the binary and
        // database URLs here are deliberately bogus.
        let outcome = ASTAPSolver().solve(
            url: URL(fileURLWithPath: "/tmp/does-not-exist.tif"),
            fovDegrees: 1.9,
            binary: URL(fileURLWithPath: "/nonexistent/astap"),
            database: URL(fileURLWithPath: "/nonexistent/db")
        )
        XCTAssertEqual(outcome, .unsupportedFormat("tif"))
    }

    // MARK: - Integration: a real solve through the real chain

    /// Runs ASTAP for real on a real frame and checks the whole chain
    /// (copy → spawn → timeout guard → .ini → WCSSolution). Skips cleanly when ASTAP or the
    /// star database is not installed, so CI stays green.
    ///
    /// NOT a sandbox test: Xcode grants the app-hosted test host extensions for the project
    /// directory, so paths this reaches say nothing about what the shipped app may read.
    /// The sandbox question was answered separately with a standalone signed probe — see
    /// `memory/feedback_sandbox_probe_needs_negative_control.md`.
    func testRealSolveEndToEnd() throws {
        let locator = ASTAPLocator.shared
        let binary = try XCTUnwrap(locator.findBinary(), "ASTAP not installed — skipping")

        let dbPath = "/usr/local/opt/astap"
        let database = URL(fileURLWithPath: dbPath)
        try XCTSkipUnless(locator.isStarDatabase(database),
                          "No ASTAP star database at \(dbPath) — skipping")

        // A frame with real stars. Resolved relative to this source file so the test does not
        // depend on the working directory.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // repo root
        let frame = repoRoot
            .appendingPathComponent("TestImages")
            .appendingPathComponent("Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-205213_-20.0C_0008.fit")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: frame.path),
                          "Test frame not present — skipping")

        let solver = ASTAPSolver()
        let started = Date()
        let outcome = solver.solve(url: frame,
                                   fovDegrees: 1.93,   // 4176 px × 1.66"/px
                                   binary: binary,
                                   database: database)
        let elapsed = Date().timeIntervalSince(started)

        guard case .solved(let s) = outcome else {
            return XCTFail("real solve failed: \(outcome.shortDescription)")
        }

        // This frame is a known Orion field — the solved centre must land there, which also
        // proves we did not simply echo back the header.
        XCTAssertEqual(s.crval1, 83.84, accuracy: 0.5, "RA off target")
        XCTAssertEqual(s.crval2, -5.35, accuracy: 0.5, "Dec off target")
        XCTAssertEqual(s.arcsecPerPixel, 1.66, accuracy: 0.1, "plate scale off")

        // The hinted solve measured 0.3 s; anything near the timeout means the hint stopped
        // working and every future batch would crawl.
        XCTAssertLessThan(elapsed, 15, "hinted solve took \(elapsed)s — FOV hint not effective?")

        // The original must be untouched: no sidecars, no rewrite. This is the guarantee that
        // lets us run against a user's session folder (often a read-only NAS share).
        let dir = frame.deletingLastPathComponent()
        let base = frame.deletingPathExtension().lastPathComponent
        for sidecar in ["\(base).ini", "\(base).wcs"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(sidecar).path),
                           "ASTAP littered \(sidecar) next to the original")
        }
    }

    // MARK: - Readiness messaging

    func testEveryUnreadyStateExplainsItself() {
        // The menu shows these verbatim; an empty or generic one strands the user.
        let states: [ASTAPReadiness] = [
            .binaryMissing,
            .databaseMissing,
            .databaseNeedsPermission(path: "/usr/local/opt/astap")
        ]
        for state in states {
            XCTAssertFalse(state.isReady)
            XCTAssertGreaterThan(state.explanation.count, 30, "too terse: \(state)")
        }
        XCTAssertTrue(ASTAPReadiness.databaseNeedsPermission(path: "/usr/local/opt/astap")
            .explanation.contains("/usr/local/opt/astap"))
    }
}
