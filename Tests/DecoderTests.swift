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
            XCTAssertEqual(decoded.buffer.length, decoded.totalBytes)
            print("Metal buffer: \(decoded.width)x\(decoded.height), \(decoded.buffer.length) bytes")
        case .failure(let error):
            XCTFail("Decode failed: \(error)")
        }
    }
}
