import XCTest
import ImageDecoderBridge

/// Decoder tests against tiny XISF fixtures embedded as Base64. They exercise the parts of
/// XISF 1.0 Revision 1 (September 2026) that changed what a reader has to cope with:
///
/// - `zstd` / `zstd+sh` are standard codecs now (and the recommended ones); libxisf's zstd
///   path is compiled in via the vendored zstd (see Package.swift).
/// - An empty vector or matrix property is serialized as an inline block with empty
///   contents — the only zero-length data block the format has. It used to throw
///   `std::out_of_range` deep inside libxisf and take the whole file with it.
///
/// The fixtures are 8×4 (zstd) and 4×2 (empty-vector) UInt16 grayscale images written by
/// libxisf's own XISFWriter and a hand-built header respectively. Pixel `i` holds
/// `i * 1000 + 7` for the writer-made files and `i * 1000` for the hand-built one.
final class ImageDecoderTests: XCTestCase {

    // 8×4 UInt16 gray, compression="zstd:64", plus an empty F64Vector property and EXPTIME.
    private static let zstdFixture = """
    WElTRjAxMDA8AwAAAAAAADw/eG1sIHZlcnNpb249IjEuMCI/PjwhLS0KRXh0ZW5zaWJsZSBJbWFnZSBTZXJpYWxpemF0aW9uIEZvcm1hdCAtIFhJU0YgdmVyc2lvbiAxLjAKQ3JlYXRlZCB3aXRoIGxpYlhJU0YgLSBodHRwczovL25vdXNwaXJvLnNwYWNlCi0tPjx4aXNmIHZlcnNpb249IjEuMCIgeG1sbnM9Imh0dHA6Ly93d3cucGl4aW5zaWdodC5jb20veGlzZiIgeG1sbnM6eHNpPSJodHRwOi8vd3d3LnczLm9yZy8yMDAxL1hNTFNjaGVtYS1pbnN0YW5jZSIgeHNpOnNjaGVtYUxvY2F0aW9uPSJodHRwOi8vd3d3LnBpeGluc2lnaHQuY29tL3hpc2YgaHR0cDovL3BpeGluc2lnaHQuY29tL3hpc2YveGlzZi0xLjAueHNkIj48SW1hZ2UgZ2VvbWV0cnk9Ijg6NDoxIiBzYW1wbGVGb3JtYXQ9IlVJbnQxNiIgY29sb3JTcGFjZT0iR3JheSIgaW1hZ2VUeXBlPSJMaWdodCIgcGl4ZWxTdG9yYWdlPSJQbGFuYXIiIGxvY2F0aW9uPSJhdHRhY2htZW50Ojg0NDo3MyIgY29tcHJlc3Npb249InpzdGQ6NjQiPjxQcm9wZXJ0eSBpZD0iVGVzdDpFbXB0eSIgdHlwZT0iRjY0VmVjdG9yIiBsZW5ndGg9IjAiIGxvY2F0aW9uPSJpbmxpbmU6YmFzZTY0Ij48L1Byb3BlcnR5PjxGSVRTS2V5d29yZCBuYW1lPSJFWFBUSU1FIiB2YWx1ZT0iMzAwIiBjb21tZW50PSJzZWNvbmRzIi8+PC9JbWFnZT48TWV0YWRhdGE+PFByb3BlcnR5IGlkPSJYSVNGOkNyZWF0aW9uVGltZSIgdHlwZT0iVGltZVBvaW50IiB2YWx1ZT0iMjAyNi0wOS0xOVQxMzo0OToxMFoiLz48UHJvcGVydHkgaWQ9IlhJU0Y6Q3JlYXRvckFwcGxpY2F0aW9uIiB0eXBlPSJTdHJpbmciPkxpYlhJU0Y8L1Byb3BlcnR5PjwvTWV0YWRhdGE+PC94aXNmPii1L/0gQAECAAcA7wPXB78Lpw+PE3cXXxtHHy8jFyf/KucuzzK3Np86hz5vQldGP0onTg9S91XfWcddr2GXZX9pZ21PcTd1H3k=
    """

    // Same image, compression="zstd+sh:64:2" (Zstandard with 16-bit byte shuffling).
    private static let zstdShuffledFixture = """
    WElTRjAxMDBBAwAAAAAAADw/eG1sIHZlcnNpb249IjEuMCI/PjwhLS0KRXh0ZW5zaWJsZSBJbWFnZSBTZXJpYWxpemF0aW9uIEZvcm1hdCAtIFhJU0YgdmVyc2lvbiAxLjAKQ3JlYXRlZCB3aXRoIGxpYlhJU0YgLSBodHRwczovL25vdXNwaXJvLnNwYWNlCi0tPjx4aXNmIHZlcnNpb249IjEuMCIgeG1sbnM9Imh0dHA6Ly93d3cucGl4aW5zaWdodC5jb20veGlzZiIgeG1sbnM6eHNpPSJodHRwOi8vd3d3LnczLm9yZy8yMDAxL1hNTFNjaGVtYS1pbnN0YW5jZSIgeHNpOnNjaGVtYUxvY2F0aW9uPSJodHRwOi8vd3d3LnBpeGluc2lnaHQuY29tL3hpc2YgaHR0cDovL3BpeGluc2lnaHQuY29tL3hpc2YveGlzZi0xLjAueHNkIj48SW1hZ2UgZ2VvbWV0cnk9Ijg6NDoxIiBzYW1wbGVGb3JtYXQ9IlVJbnQxNiIgY29sb3JTcGFjZT0iR3JheSIgaW1hZ2VUeXBlPSJMaWdodCIgcGl4ZWxTdG9yYWdlPSJQbGFuYXIiIGxvY2F0aW9uPSJhdHRhY2htZW50Ojg0OTo3MyIgY29tcHJlc3Npb249InpzdGQrc2g6NjQ6MiI+PFByb3BlcnR5IGlkPSJUZXN0OkVtcHR5IiB0eXBlPSJGNjRWZWN0b3IiIGxlbmd0aD0iMCIgbG9jYXRpb249ImlubGluZTpiYXNlNjQiPjwvUHJvcGVydHk+PEZJVFNLZXl3b3JkIG5hbWU9IkVYUFRJTUUiIHZhbHVlPSIzMDAiIGNvbW1lbnQ9InNlY29uZHMiLz48L0ltYWdlPjxNZXRhZGF0YT48UHJvcGVydHkgaWQ9IlhJU0Y6Q3JlYXRpb25UaW1lIiB0eXBlPSJUaW1lUG9pbnQiIHZhbHVlPSIyMDI2LTA5LTE5VDEzOjQ5OjEwWiIvPjxQcm9wZXJ0eSBpZD0iWElTRjpDcmVhdG9yQXBwbGljYXRpb24iIHR5cGU9IlN0cmluZyI+TGliWElTRjwvUHJvcGVydHk+PC9NZXRhZGF0YT48L3hpc2Y+KLUv/SBAAQIAB+/Xv6ePd19HLxf/58+3n4dvVz8nD/ffx6+Xf2dPNx8AAwcLDxMXGx8jJyouMjY6PkJGSk5SVVldYWVpbXF1eQ==
    """

    // 4×2 UInt16 gray, uncompressed, hand-built header with an empty F64Vector property
    // in the exact form Revision 1 prescribes: `length="0" location="inline:base64"` and
    // no character data.
    private static let emptyVectorFixture = """
    WElTRjAxMDAEAgAAAAAAADw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04Ij8+PHhpc2YgdmVyc2lvbj0iMS4wIiB4bWxucz0iaHR0cDovL3d3dy5waXhpbnNpZ2h0LmNvbS94aXNmIj48SW1hZ2UgZ2VvbWV0cnk9IjQ6MjoxIiBzYW1wbGVGb3JtYXQ9IlVJbnQxNiIgY29sb3JTcGFjZT0iR3JheSIgbG9jYXRpb249ImF0dGFjaG1lbnQ6NTMyOjE2Ij48UHJvcGVydHkgaWQ9IlRlc3Q6RW1wdHkiIHR5cGU9IkY2NFZlY3RvciIgbGVuZ3RoPSIwIiBsb2NhdGlvbj0iaW5saW5lOmJhc2U2NCI+PC9Qcm9wZXJ0eT48RklUU0tleXdvcmQgbmFtZT0iRVhQVElNRSIgdmFsdWU9IjMwMCIgY29tbWVudD0iIi8+PC9JbWFnZT48TWV0YWRhdGE+PFByb3BlcnR5IGlkPSJYSVNGOkNyZWF0aW9uVGltZSIgdHlwZT0iVGltZVBvaW50IiB2YWx1ZT0iMjAyNi0wOS0xOVQwMDowMDowMFoiLz48UHJvcGVydHkgaWQ9IlhJU0Y6Q3JlYXRvckFwcGxpY2F0aW9uIiB0eXBlPSJTdHJpbmciPnRlc3Q8L1Byb3BlcnR5PjwvTWV0YWRhdGE+PC94aXNmPgAA6APQB7gLoA+IE3AXWBs=
    """

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        super.tearDown()
    }

    /// Reads a fixed-size C `char[]` field (imported into Swift as a tuple) as a String.
    private func cString<T>(_ field: T) -> String {
        withUnsafePointer(to: field) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
    }

    /// Decodes the Base64 fixture into a temporary `.xisf` file and returns its path.
    private func materialize(_ base64: String, name: String) throws -> String {
        let cleaned = base64.filter { !$0.isWhitespace }
        let data = try XCTUnwrap(Data(base64Encoded: cleaned), "fixture \(name) is not valid Base64")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDecoderTests-\(name)-\(UUID().uuidString).xisf")
        try data.write(to: url)
        tempFiles.append(url)
        return url.path
    }

    private func assertDecodes(_ base64: String, name: String, width: Int32, height: Int32,
                               pixelStride: Int, pixelOffset: Int,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try materialize(base64, name: name)
        var result = decode_xisf(path)
        defer { free_decode_result(&result) }

        XCTAssertEqual(result.success, 1, "decode_xisf failed: \(cString(result.error))",
                       file: file, line: line)
        guard result.success == 1 else { return }
        XCTAssertEqual(result.width, width, file: file, line: line)
        XCTAssertEqual(result.height, height, file: file, line: line)
        XCTAssertEqual(result.channelCount, 1, file: file, line: line)
        let pixels = try XCTUnwrap(result.pixels, file: file, line: line)
        let count = Int(width * height)
        for i in 0..<count {
            XCTAssertEqual(Int(pixels[i]), i * pixelStride + pixelOffset,
                           "pixel \(i)", file: file, line: line)
        }
    }

    private func assertHeadersReadable(_ base64: String, name: String, width: String, height: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try materialize(base64, name: name)
        var result = read_xisf_headers(path)
        defer { free_header_result(&result) }

        XCTAssertEqual(result.success, 1, file: file, line: line)
        guard result.success == 1, let entries = result.entries else { return }
        var headers: [String: String] = [:]
        for i in 0..<Int(result.count) {
            let entry = entries[i]
            headers[cString(entry.key)] = cString(entry.value)
        }
        XCTAssertEqual(headers["EXPTIME"], "300", file: file, line: line)
        XCTAssertEqual(headers["NAXIS1"], width, file: file, line: line)
        XCTAssertEqual(headers["NAXIS2"], height, file: file, line: line)
    }

    // MARK: - Zstandard (XISF 1.0 Revision 1 standard codec)

    func testDecodesZstdCompressedPixels() throws {
        try assertDecodes(Self.zstdFixture, name: "zstd", width: 8, height: 4,
                          pixelStride: 1000, pixelOffset: 7)
    }

    func testDecodesZstdWithByteShuffling() throws {
        try assertDecodes(Self.zstdShuffledFixture, name: "zstd-sh", width: 8, height: 4,
                          pixelStride: 1000, pixelOffset: 7)
    }

    func testReadsHeadersOfZstdFile() throws {
        // Header reading parses the compression attribute too, so an unsupported codec used to
        // fail here as well — before a single pixel was needed.
        try assertHeadersReadable(Self.zstdFixture, name: "zstd-headers", width: "8", height: "4")
    }

    // MARK: - Empty vector property (zero-length inline data block)

    func testEmptyVectorPropertyDoesNotBreakTheFile() throws {
        try assertDecodes(Self.emptyVectorFixture, name: "empty-vector", width: 4, height: 2,
                          pixelStride: 1000, pixelOffset: 0)
        try assertHeadersReadable(Self.emptyVectorFixture, name: "empty-vector-headers",
                                  width: "4", height: "2")
    }
}
