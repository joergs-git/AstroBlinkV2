import XCTest
@testable import AstroTriage
import ImageDecoderBridge
import Metal

final class DecoderTests: XCTestCase {

    let testImagesPath = "/Users/joergklaas/Desktop/claude-code/AstroTriage-blinkV2/TestImages"

    // Test XISF decode with real NINA file
    func testDecodeXISF() {
        let path = testImagesPath + "/2025-11-12_NGC 6960 Veil_20-48-31_RC12_ZWO ASI6200MM Pro_LIGHT_O_300.00s_#0002__bin1x1_gain100_T-10.00c.xisf"

        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        var result = decode_xisf(path)
        defer { free_decode_result(&result) }

        XCTAssertEqual(result.success, 1, "XISF decode should succeed")
        XCTAssertGreaterThan(result.width, 0, "Width should be positive")
        XCTAssertGreaterThan(result.height, 0, "Height should be positive")
        XCTAssertGreaterThan(result.channelCount, 0, "Channel count should be positive")
        XCTAssertNotNil(result.pixels, "Pixels should not be nil")

        print("XISF decoded: \(result.width)x\(result.height), channels=\(result.channelCount)")
    }

    // Test FITS decode with real NINA file
    func testDecodeFITS() {
        let path = testImagesPath + "/Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-203709_-20.0C_0005.fit"

        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        var result = decode_fits(path)
        defer { free_decode_result(&result) }

        XCTAssertEqual(result.success, 1, "FITS decode should succeed")
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        XCTAssertNotNil(result.pixels)

        print("FITS decoded: \(result.width)x\(result.height), channels=\(result.channelCount)")
    }

    // Test XISF header extraction
    func testReadXISFHeaders() {
        let path = testImagesPath + "/2025-11-12_NGC 6960 Veil_20-48-31_RC12_ZWO ASI6200MM Pro_LIGHT_O_300.00s_#0002__bin1x1_gain100_T-10.00c.xisf"

        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        var result = read_xisf_headers(path)
        defer { free_header_result(&result) }

        XCTAssertEqual(result.success, 1, "Header read should succeed")
        XCTAssertGreaterThan(result.count, 0, "Should have headers")

        print("XISF headers: \(result.count) entries")
    }

    // Test FITS header extraction
    func testReadFITSHeaders() {
        let path = testImagesPath + "/Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-203709_-20.0C_0005.fit"

        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        var result = read_fits_headers(path)
        defer { free_header_result(&result) }

        let errorMsg = withUnsafePointer(to: result.error) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }

        XCTAssertEqual(result.success, 1, "Header read should succeed: \(errorMsg)")
        XCTAssertGreaterThan(result.count, 0, "Should have headers")

        // Print first few headers for diagnostic
        if let entries = result.entries {
            for i in 0..<min(Int(result.count), 5) {
                let key = withUnsafePointer(to: entries[i].key) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                let val = withUnsafePointer(to: entries[i].value) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                print("  \(key) = \(val)")
            }
        }
        print("FITS headers: \(result.count) entries")
    }

    // Test Metal buffer creation from decoded image
    func testMetalBufferCreation() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("No Metal device available")
            return
        }

        let path = testImagesPath + "/Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-203709_-20.0C_0005.fit"
        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        let url = URL(fileURLWithPath: path)
        let result = ImageDecoder.decode(url: url, device: device)

        switch result {
        case .success(let decoded):
            XCTAssertGreaterThan(decoded.width, 0)
            XCTAssertGreaterThan(decoded.height, 0)
            // The macOS bridge page-aligns the allocation so MTLBuffer.bytesNoCopy
            // can wrap it zero-copy. So buffer.length is rounded up to a multiple
            // of the page size — it must be ≥ totalBytes and page-aligned, not
            // exactly equal. The pre-aligned remainder past totalBytes is unused.
            let pageSize = Int(getpagesize())
            XCTAssertGreaterThanOrEqual(decoded.buffer.length, decoded.totalBytes)
            XCTAssertEqual(decoded.buffer.length % pageSize, 0,
                "Buffer length must be page-aligned for bytesNoCopy")
            XCTAssertLessThan(decoded.buffer.length - decoded.totalBytes, pageSize,
                "Padding cannot exceed one page")
            print("Metal buffer: \(decoded.width)x\(decoded.height), \(decoded.buffer.length) bytes (\(decoded.buffer.length - decoded.totalBytes) page padding)")
        case .failure(let error):
            XCTFail("Decode failed: \(error)")
        }
    }

    // MARK: - Bounds check: malicious headers must error, not crash

    // Hand-craft a minimal FITS primary HDU with dimensions far beyond any
    // real astro camera (~62 MP top-end today). cfitsio either refuses to
    // allocate the implied 8.6 GB data block (returning failure on the spot)
    // or passes the dimensions back so the Swift-level 200-MP cap in
    // ImageDecoder.swift trips. Either branch must surface as Result.failure
    // — never a crash, never a runaway allocation.
    func testFITSBoundsCheck_RejectsAbsurdDimensions() throws {
        let headerData = Self.makeMinimalFITSHeader(naxis1: 65535, naxis2: 65535, bitpix: 16)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrotriage-bounds-test-\(UUID().uuidString).fits")
        try headerData.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available on test runner.")
        }

        let result = ImageDecoder.decode(url: tmpURL, device: device)
        switch result {
        case .success(let decoded):
            XCTFail("65535×65535 FITS must be rejected; got \(decoded.width)×\(decoded.height).")
        case .failure(let error):
            let msg = "\(error)"
            XCTAssertFalse(msg.isEmpty, "Failure should carry a diagnostic message.")
            print("[BoundsCheck] Rejected as expected: \(msg)")
        }
    }

    /// Build a 2880-byte FITS primary header block (no data unit) with the
    /// requested NAXIS1/NAXIS2/BITPIX. Sufficient for header-parsing tests.
    private static func makeMinimalFITSHeader(naxis1: Int, naxis2: Int, bitpix: Int) -> Data {
        func card(_ s: String) -> String {
            var c = s
            while c.count < 80 { c += " " }
            return String(c.prefix(80))
        }
        func intCard(_ key: String, _ value: Int) -> String {
            let keyPad = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            return card("\(keyPad)= " + String(format: "%20d", value))
        }
        let cards = [
            card("SIMPLE  = " + String(repeating: " ", count: 19) + "T"),
            intCard("BITPIX", bitpix),
            intCard("NAXIS", 2),
            intCard("NAXIS1", naxis1),
            intCard("NAXIS2", naxis2),
            card("END")
        ]
        var blob = cards.joined()
        while blob.count % 2880 != 0 { blob += " " }  // pad to one 2880-byte FITS block
        return Data(blob.utf8)
    }
}
