import XCTest
@testable import AstroTriage

final class SessionScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionScannerTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create an empty file at the given path relative to tempDir
    private func createFile(_ relativePath: String) {
        let url = tempDir.appendingPathComponent(relativePath)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    // MARK: - Calibration Detection Tests

    func testIsCalibrationDetectsDarkFolder() {
        // Folder named "Dark" should be skipped when lightsOnly=true
        createFile("Dark/test_001.xisf")
        createFile("LIGHT_H_001.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: true)

        // Root has one image → scans root only (smart subfolder logic)
        // The root-level file should be found, Dark folder should be excluded
        XCTAssertTrue(entries.allSatisfy { !$0.url.path.contains("/Dark/") },
                      "Dark folder should be excluded with lightsOnly=true")
    }

    func testIsCalibrationDetectsFlatFolder() {
        createFile("FlatFrames/flat_001.xisf")
        createFile("Ha/light_001.xisf")

        // Root has no direct images → recurses into subfolders
        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: true)

        XCTAssertTrue(entries.allSatisfy { !$0.url.path.contains("/FlatFrames/") },
                      "Flat folder should be excluded with lightsOnly=true")
        XCTAssertFalse(entries.isEmpty, "Ha folder files should still be included")
    }

    func testIsCalibrationDetectsBiasInFilename() {
        // File with "bias" in its name should be excluded
        createFile("BIAS_001.xisf")
        createFile("LIGHT_H_001.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: true)

        XCTAssertTrue(entries.allSatisfy { !$0.filename.lowercased().contains("bias") },
                      "Files with 'bias' in filename should be excluded")
    }

    func testTargetNameContainingCalibrationKeyword() {
        // Fixed bug: "Dark_Nebula" was falsely excluded because contains("dark") matched.
        // Now uses frame type token parsing: LIGHT frame should NOT be excluded.
        createFile("2026-03-06_Dark_Nebula_23-54-58_LIGHT_H_300.00s_#0001.xisf")
        createFile("2026-03-06_IC1848_23-55-00_LIGHT_H_300.00s_#0002.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: true)

        let darkNebulaFound = entries.contains { $0.filename.contains("Dark_Nebula") }
        XCTAssertTrue(darkNebulaFound,
                      "Target 'Dark Nebula' LIGHT frame should NOT be excluded as calibration")
        XCTAssertEqual(entries.count, 2, "Both LIGHT frames should be included")
    }

    func testActualDarkFrameExcluded() {
        // A DARK frame (frame type = DARK) should still be excluded
        createFile("2026-03-06_IC1848_23-54-58_DARK_300.00s_#0001.xisf")
        createFile("2026-03-06_IC1848_23-55-00_LIGHT_H_300.00s_#0002.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: true)

        XCTAssertEqual(entries.count, 1, "DARK frame should be excluded")
        XCTAssertTrue(entries.first?.filename.contains("LIGHT") ?? false)
    }

    func testScanSkipsPredelFolder() {
        createFile("_predel/deleted_001.xisf")
        createFile("LIGHT_H_001.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: false)

        XCTAssertTrue(entries.allSatisfy { !$0.url.path.contains("/_predel/") },
                      "_predel folder should always be excluded")
    }

    func testScanLightsOnlyFalseIncludesCalibration() {
        createFile("Dark/dark_001.xisf")
        createFile("Ha/light_001.xisf")

        // Root has no direct images → recurses
        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: false)

        let hasDark = entries.contains { $0.url.path.contains("/Dark/") }
        XCTAssertTrue(hasDark, "lightsOnly=false should include calibration folders")
    }

    func testScanOnlySupportedExtensions() {
        createFile("image.xisf")
        createFile("image.fits")
        createFile("image.fit")
        createFile("image.fts")
        createFile("image.jpg")
        createFile("image.png")
        createFile("image.tiff")
        createFile("notes.txt")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: false)

        XCTAssertEqual(entries.count, 4, "Only .xisf, .fits, .fit, .fts should be scanned")
    }

    func testSmartSubfolderDetection() {
        // Root has images → only root is scanned (subfolders ignored)
        createFile("root_image.xisf")
        createFile("subfolder/sub_image.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: false)

        XCTAssertEqual(entries.count, 1, "Root with images should only scan root level")
        XCTAssertEqual(entries.first?.filename, "root_image.xisf")
    }

    func testSubfolderRecursionWhenRootEmpty() {
        // Root has no images → recurse into subfolders
        createFile("Ha/light_001.xisf")
        createFile("OIII/light_001.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: false)

        XCTAssertEqual(entries.count, 2, "Empty root should recurse into subfolders")
    }

    func testRelativeSubfolderPath() {
        // Files in subfolders should have correct relative subfolder
        createFile("Ha/light_001.xisf")
        createFile("OIII/nested/light_001.xisf")

        let entries = SessionScanner.scan(rootURL: tempDir, lightsOnly: false)

        let haEntry = entries.first { $0.subfolder == "Ha" }
        let nestedEntry = entries.first { $0.subfolder == "OIII/nested" }

        XCTAssertNotNil(haEntry, "Ha subfolder path should be 'Ha'")
        XCTAssertNotNil(nestedEntry, "Nested subfolder path should be 'OIII/nested'")
    }
}
