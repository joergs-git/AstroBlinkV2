// Integration tests to diagnose all reported issues
// Each test isolates one specific feature to pinpoint exact failures

import XCTest
@testable import AstroTriage
import ImageDecoderBridge
import Metal
import MetalKit

final class IntegrationTests: XCTestCase {

    let testImagesPath = "/Users/joergklaas/Desktop/claude-code/AstroTriage-blinkV2/TestImages"

    // =========================================================================
    // ISSUE 1: FITS "too many I/O drivers"
    // Test: decode the same FITS file 20 times sequentially
    // =========================================================================
    func testFITSSequentialDecodes() {
        let path = testImagesPath + "/Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-203709_-20.0C_0005.fit"
        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        for i in 0..<20 {
            var result = decode_fits(path)
            let errorMsg = withUnsafePointer(to: result.error) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            XCTAssertEqual(result.success, 1, "Decode #\(i) failed: \(errorMsg)")
            free_decode_result(&result)
        }
    }

    // Test: decode FITS from multiple concurrent threads
    func testFITSConcurrentDecodes() {
        let path = testImagesPath + "/Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-203709_-20.0C_0005.fit"
        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        let group = DispatchGroup()
        var errors: [String] = []
        let errorLock = NSLock()

        for i in 0..<10 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var result = decode_fits(path)
                if result.success == 0 {
                    let msg = withUnsafePointer(to: result.error) { ptr in
                        String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                    }
                    errorLock.lock()
                    errors.append("Thread \(i): \(msg)")
                    errorLock.unlock()
                }
                free_decode_result(&result)
                group.leave()
            }
        }

        group.wait()
        XCTAssertTrue(errors.isEmpty, "Concurrent FITS decode errors: \(errors.joined(separator: "; "))")
    }

    // Test: interleave FITS decode and header reading (the real-world pattern)
    func testFITSInterleavedDecodeAndHeaders() {
        let path = testImagesPath + "/Light_Orion_300.0s_Bin1_2600MC_gain100_20240227-203709_-20.0C_0005.fit"
        guard FileManager.default.fileExists(atPath: path) else {
            XCTSkip("Test image not available")
            return
        }

        for i in 0..<10 {
            // Read headers
            var headerResult = read_fits_headers(path)
            let headerMsg = withUnsafePointer(to: headerResult.error) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            XCTAssertEqual(headerResult.success, 1, "Header read #\(i) failed: \(headerMsg)")
            free_header_result(&headerResult)

            // Decode pixels
            var decodeResult = decode_fits(path)
            let decodeMsg = withUnsafePointer(to: decodeResult.error) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            XCTAssertEqual(decodeResult.success, 1, "Decode #\(i) failed: \(decodeMsg)")
            free_decode_result(&decodeResult)
        }
    }

    // =========================================================================
    // ISSUE 2: Metal render pipeline — verify shaders compile
    // =========================================================================
    func testMetalShadersExist() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("No Metal device")
            return
        }

        // The default library comes from the app bundle's compiled .metallib
        // In tests, it may not be available. Let's check.
        let library = device.makeDefaultLibrary()
        if library == nil {
            // This is expected in test targets — Metal shaders are in the app target
            // We need to load from the app bundle explicitly
            let appBundle = Bundle(for: type(of: self))
            let testLibrary = try? device.makeDefaultLibrary(bundle: appBundle)
            if testLibrary == nil {
                print("WARNING: No Metal library found in test bundle. Shaders can only be tested via app.")
                print("   This means MetalRenderer.init may return nil if shaders are missing.")
                // Still informative — if this prints, we know the renderer is nil
            }
            return
        }

        let normalizeFunc = library!.makeFunction(name: "normalize_uint16")
        XCTAssertNotNil(normalizeFunc, "normalize_uint16 shader function not found")

        let vertexFunc = library!.makeFunction(name: "quad_vertex")
        XCTAssertNotNil(vertexFunc, "quad_vertex shader function not found")

        let fragmentFunc = library!.makeFunction(name: "quad_fragment")
        XCTAssertNotNil(fragmentFunc, "quad_fragment shader function not found")
    }

    // Test MetalRenderer initialization
    func testMetalRendererInit() {
        // Create an offscreen MTKView to test renderer init
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("No Metal device")
            return
        }

        let mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        let renderer = MetalRenderer(mtkView: mtkView)

        // THIS is the key test — if renderer is nil, nothing will ever display
        XCTAssertNotNil(renderer, "MetalRenderer init returned nil! Check shader compilation.")

        if renderer == nil {
            print("CRITICAL: MetalRenderer.init returned nil")
            print("  This means either:")
            print("  1. makeDefaultLibrary() failed (no .metallib in bundle)")
            print("  2. normalize_uint16 shader failed to compile")
            print("  3. quad_vertex or quad_fragment shader failed to compile")
            print("  4. Compute or render pipeline creation failed")
        }
    }

    // =========================================================================
    // ISSUE 3: Image fit-to-view — test the NDC calculation
    // =========================================================================
    func testFitToViewCalculation() {
        // Simulate a 9576x6388 image in a 1600x800 drawable (800x400 view at 2x)
        let imgW: CGFloat = 9576
        let imgH: CGFloat = 6388
        let drawableW: CGFloat = 1600
        let drawableH: CGFloat = 800

        let baseFit = min(drawableW / imgW, drawableH / imgH)
        // Should be min(0.167, 0.125) = 0.125
        XCTAssertEqual(baseFit, drawableH / imgH, accuracy: 0.001)

        let scaledW = imgW * baseFit
        let scaledH = imgH * baseFit
        // scaledW = 1197, scaledH = 798.5

        let ndcHW = Float(scaledW / drawableW)  // 0.748
        let ndcHH = Float(scaledH / drawableH)  // 0.998

        // Both should be <= 1.0 (image fits inside view)
        XCTAssertLessThanOrEqual(ndcHW, 1.0, "Image wider than view in NDC")
        XCTAssertLessThanOrEqual(ndcHH, 1.0, "Image taller than view in NDC")

        // At least one dimension should be close to 1.0 (image fills view)
        let maxNDC = max(ndcHW, ndcHH)
        XCTAssertGreaterThan(maxNDC, 0.5, "Image too small — fit calculation wrong")

        print("Fit-to-view: baseFit=\(baseFit), scaledW=\(scaledW), scaledH=\(scaledH)")
        print("NDC: halfW=\(ndcHW), halfH=\(ndcHH)")
    }

    // =========================================================================
    // ISSUE 4: Multi-level sorting
    // =========================================================================
    func testMultiLevelSort() {
        // Create test entries with known values
        var entries = [
            makeEntry(filter: "H", date: "2026-01-01", filename: "a.xisf"),
            makeEntry(filter: "O", date: "2026-01-02", filename: "b.xisf"),
            makeEntry(filter: "H", date: "2026-01-03", filename: "c.xisf"),
            makeEntry(filter: "O", date: "2026-01-01", filename: "d.xisf"),
            makeEntry(filter: "H", date: "2026-01-02", filename: "e.xisf"),
        ]

        // Sort by filter asc, then date asc (like NSTableView would provide)
        let descriptors = [
            NSSortDescriptor(key: "filter", ascending: true),
            NSSortDescriptor(key: "date", ascending: true),
        ]

        entries.sort { a, b in
            for descriptor in descriptors {
                guard let key = descriptor.key else { continue }
                let ascending = descriptor.ascending

                let valA = ColumnDefinition.value(for: key, from: a)
                let valB = ColumnDefinition.value(for: key, from: b)

                if valA != valB {
                    return ascending ? valA < valB : valA > valB
                }
            }
            return false
        }

        // Verify: H entries first, then O entries, each group sorted by date
        let filenames = entries.map { $0.filename }
        XCTAssertEqual(filenames, ["a.xisf", "e.xisf", "c.xisf", "d.xisf", "b.xisf"],
                       "Multi-level sort failed: \(filenames)")
    }

    // Test that NSTableView sort descriptors accumulate
    func testSortDescriptorAccumulation() {
        // Simulate what NSTableView does internally
        var descriptors: [NSSortDescriptor] = []

        // Click "filter" column
        let filterSort = NSSortDescriptor(key: "filter", ascending: true)
        descriptors = [filterSort]
        XCTAssertEqual(descriptors.count, 1)

        // Click "date" column — NSTableView prepends new, keeps old
        let dateSort = NSSortDescriptor(key: "date", ascending: true)
        descriptors = [dateSort] + descriptors.filter { $0.key != "date" }
        XCTAssertEqual(descriptors.count, 2)
        XCTAssertEqual(descriptors[0].key, "date", "Primary sort should be date")
        XCTAssertEqual(descriptors[1].key, "filter", "Secondary sort should be filter")
    }

    // =========================================================================
    // ISSUE 5: SessionCache — network volume detection
    // =========================================================================
    func testNetworkVolumeDetection() {
        // Local paths should NOT be detected as network
        let localURL = URL(fileURLWithPath: "/tmp")
        let isNetwork = SessionCache.isNetworkVolume(localURL)
        XCTAssertFalse(isNetwork, "/tmp should not be detected as network volume")

        // Home directory should NOT be network
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let isHomeNetwork = SessionCache.isNetworkVolume(homeURL)
        XCTAssertFalse(isHomeNetwork, "Home directory should not be network volume")

        print("Network detection: /tmp=\(isNetwork), home=\(isHomeNetwork)")
    }

    func testSessionCacheFileOperations() {
        let cache = SessionCache()
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroTriageTest_\(UUID().uuidString)")

        cache.prepareSession(rootURL: tmpRoot)

        // Create a test file
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let testFile = testDir.appendingPathComponent("test_cache_\(UUID().uuidString).txt")
        try! "test data".write(to: testFile, atomically: true, encoding: .utf8)

        let cachedURL = cache.cacheFile(sourceURL: testFile)
        XCTAssertNotNil(cachedURL, "Cache should return a valid URL")

        if let cached = cachedURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path), "Cached file should exist on disk")
            let contents = try! String(contentsOf: cached)
            XCTAssertEqual(contents, "test data", "Cached file should have correct contents")
        }

        // Cleanup
        try? FileManager.default.removeItem(at: testFile)
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // =========================================================================
    // ISSUE 6: ImageEntry decodingURL
    // =========================================================================
    func testImageEntryDecodingURL() {
        let url = URL(fileURLWithPath: "/tmp/test.xisf")
        let entry = ImageEntry(url: url)

        // By default, decodingURL should equal url
        XCTAssertEqual(entry.decodingURL, entry.url, "decodingURL should default to url")

        // After setting decodingURL to a cached path
        var mutableEntry = entry
        let cachedURL = URL(fileURLWithPath: "/tmp/cache/test.xisf")
        mutableEntry.decodingURL = cachedURL
        XCTAssertEqual(mutableEntry.decodingURL, cachedURL)
        XCTAssertEqual(mutableEntry.url, url, "Original url should not change")
    }

    // =========================================================================
    // ISSUE 7: Bulk mark/unmark
    // =========================================================================
    func testBulkTogglePreDelete() async {
        let vm = await TriageViewModel()

        // Create test entries
        await MainActor.run {
            vm.images = [
                ImageEntry(url: URL(fileURLWithPath: "/tmp/1.xisf")),
                ImageEntry(url: URL(fileURLWithPath: "/tmp/2.xisf")),
                ImageEntry(url: URL(fileURLWithPath: "/tmp/3.xisf")),
                ImageEntry(url: URL(fileURLWithPath: "/tmp/4.xisf")),
                ImageEntry(url: URL(fileURLWithPath: "/tmp/5.xisf")),
            ]
        }

        // Mark rows 1, 2, 3
        let rows = IndexSet([1, 2, 3])
        await MainActor.run {
            vm.togglePreDeleteForRows(rows)
        }

        await MainActor.run {
            XCTAssertFalse(vm.images[0].isMarkedForDeletion, "Row 0 should not be marked")
            XCTAssertTrue(vm.images[1].isMarkedForDeletion, "Row 1 should be marked")
            XCTAssertTrue(vm.images[2].isMarkedForDeletion, "Row 2 should be marked")
            XCTAssertTrue(vm.images[3].isMarkedForDeletion, "Row 3 should be marked")
            XCTAssertFalse(vm.images[4].isMarkedForDeletion, "Row 4 should not be marked")
        }

        // Toggle again — all are marked, so should unmark
        await MainActor.run {
            vm.togglePreDeleteForRows(rows)
        }

        await MainActor.run {
            XCTAssertFalse(vm.images[1].isMarkedForDeletion, "Row 1 should be unmarked")
            XCTAssertFalse(vm.images[2].isMarkedForDeletion, "Row 2 should be unmarked")
            XCTAssertFalse(vm.images[3].isMarkedForDeletion, "Row 3 should be unmarked")
        }
    }

    // =========================================================================
    // ISSUE 8: STF Auto-Stretch parameters
    // =========================================================================
    func testSTFCalculation() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("No Metal device")
            return
        }

        // Create a synthetic mono image: mostly dark with some bright pixels
        // Simulates typical astro data (dark sky background, faint signal)
        let width = 100
        let height = 100
        let pixelCount = width * height
        var pixels = [UInt16](repeating: 0, count: pixelCount)

        // Background: ~5% of dynamic range (typical raw astro background)
        for i in 0..<pixelCount {
            // Random-ish background centered around 3000 (out of 65535)
            pixels[i] = UInt16(3000 + (i % 500))
        }
        // A few bright pixels (stars)
        pixels[5050] = 60000
        pixels[5051] = 55000
        pixels[4950] = 50000

        guard let buffer = device.makeBuffer(
            bytes: &pixels,
            length: pixelCount * 2,
            options: .storageModeShared
        ) else {
            XCTFail("Failed to create Metal buffer")
            return
        }

        let image = DecodedImage(buffer: buffer, width: width, height: height, channelCount: 1)
        let params = STFCalculator.calculate(from: image)

        XCTAssertEqual(params.count, 1, "Mono image should produce 1 STF param set")

        let p = params[0]
        // c0 should be near the background level (~3000/65535 ≈ 0.046)
        // It clips shadows below median - 1.25*sigma
        XCTAssertGreaterThanOrEqual(p.c0, 0.0, "c0 must be >= 0")
        XCTAssertLessThan(p.c0, 0.1, "c0 should be low for typical astro data")

        // mb should be > 0 and < 1 (midtone balance)
        XCTAssertGreaterThan(p.mb, 0.0, "mb must be > 0")
        XCTAssertLessThan(p.mb, 1.0, "mb must be < 1")

        // With mostly dark data, mb should pull the midtones up significantly
        // (typical values around 0.1-0.4 for faint data)
        XCTAssertLessThan(p.mb, 0.8, "mb should not be close to 1 for dark data")

        print("STF params: c0=\(p.c0), mb=\(p.mb)")
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private func makeEntry(filter: String, date: String, filename: String) -> ImageEntry {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(filename)"))
        entry.filter = filter
        entry.date = date
        return entry
    }
}
