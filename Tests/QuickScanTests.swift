// v6.13.0
import XCTest
@testable import AstroTriage

/// Quick Scan (6.13.0): a folder is opened for its metadata only. The frames show their
/// header values and fill the Session Overview; no pixel is decoded, nothing is cached,
/// nothing is scored. These tests run the real load path on FITS files written here.
final class QuickScanTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeFITS(to: folder.appendingPathComponent("a.fits"), filter: "Ha", exposure: 300, object: "M 45")
        try Self.writeFITS(to: folder.appendingPathComponent("b.fits"), filter: "Ha", exposure: 300, object: "M 45")
        try Self.writeFITS(to: folder.appendingPathComponent("c.fits"), filter: "L", exposure: 180, object: "M 45")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Minimal valid FITS: one 2880-byte header block and a 4x4 16-bit image.
    private static func writeFITS(to url: URL, filter: String, exposure: Double, object: String) throws {
        func card(_ text: String) -> String { text.padding(toLength: 80, withPad: " ", startingAt: 0) }
        func quoted(_ key: String, _ value: String) -> String {
            card(key.padding(toLength: 8, withPad: " ", startingAt: 0) + "= '" + value.padding(toLength: 8, withPad: " ", startingAt: 0) + "'")
        }
        func number(_ key: String, _ value: String) -> String {
            card(key.padding(toLength: 8, withPad: " ", startingAt: 0) + "= " + String(repeating: " ", count: max(0, 20 - value.count)) + value)
        }
        var header = [
            number("SIMPLE", "T"), number("BITPIX", "16"), number("NAXIS", "2"),
            number("NAXIS1", "4"), number("NAXIS2", "4"),
            quoted("FILTER", filter), number("EXPTIME", String(exposure)), quoted("OBJECT", object),
            quoted("IMAGETYP", "LIGHT"), quoted("DATE-OBS", "2026-11-04T23:19:17"),
            card("END"),
        ].joined()
        header = header.padding(toLength: 2880, withPad: " ", startingAt: 0)
        var data = Data(header.utf8)
        data.append(Data(count: 2880))   // 4x4x2 bytes of pixels, padded to one block
        try data.write(to: url)
    }

    /// Poll the main actor until `condition` holds or the timeout passes.
    @MainActor
    private func wait(_ seconds: TimeInterval = 15, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func testQuickScanReadsMetadataAndLoadsNoPixels() async {
        let vm = TriageViewModel()
        vm.orchestrator.loadMixedSelection(files: [], directories: [folder], quickScan: true)
        await wait { vm.statusMessage.hasPrefix("Quick Scan:") && vm.statusMessage.contains(" h") }

        XCTAssertTrue(vm.isQuickScan)
        XCTAssertEqual(vm.images.count, 3)
        XCTAssertEqual(vm.loadingPhase, .none, "header pass should have finished")

        // Metadata comes from the headers (the filenames carry none).
        XCTAssertEqual(vm.images.compactMap(\.filter).sorted(), ["Ha", "Ha", "L"])
        XCTAssertEqual(vm.images.reduce(0.0) { $0 + ($1.exposure ?? 0) }, 780, accuracy: 0.01)
        XCTAssertEqual(Set(vm.images.compactMap(\.target)), ["M 45"])

        // The Session Overview is filled.
        XCTAssertEqual(vm.sessionOverviewModel.totalShots, 3)
        XCTAssertEqual(vm.sessionOverviewModel.totalExposure, 780, accuracy: 0.01)

        // Nothing was decoded, cached or rated.
        XCTAssertFalse(vm.isCaching)
        XCTAssertNil(vm.currentDecodedImage)
        XCTAssertTrue(vm.images.allSatisfy { !vm.isImageCached($0.url) }, "a preview was cached in a Quick Scan")
        XCTAssertTrue(vm.images.allSatisfy { $0.qualityTier == nil && $0.qualityBreakdown == nil })
        XCTAssertTrue(vm.images.allSatisfy { $0.noiseMedian == nil && $0.computedStarCount == nil })

        // The commands that would start decoding stay inert.
        vm.triggerApplyAll()
        vm.continueCaching()
        vm.selectImage(at: 1)
        vm.orchestrator.recomputeQualityScores()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(vm.isCaching, "pre-cache started in a Quick Scan")
        XCTAssertNil(vm.currentDecodedImage)
        XCTAssertTrue(vm.images.allSatisfy { !vm.isImageCached($0.url) })
        XCTAssertTrue(vm.images.allSatisfy { $0.qualityTier == nil })
    }

    @MainActor
    func testFullLoadLeavesQuickScanMode() async {
        let vm = TriageViewModel()
        vm.orchestrator.loadMixedSelection(files: [], directories: [folder], quickScan: true)
        await wait { vm.statusMessage.hasPrefix("Quick Scan:") && vm.statusMessage.contains(" h") }
        XCTAssertTrue(vm.isQuickScan)

        vm.loadSession(url: folder)
        XCTAssertFalse(vm.isQuickScan, "a normal load must end Quick Scan mode at once")
        await wait { !vm.isLoading && vm.images.count == 3 }
        XCTAssertEqual(vm.images.count, 3)
        XCTAssertFalse(vm.isQuickScan)
    }
}
