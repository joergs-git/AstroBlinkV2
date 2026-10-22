// v6.9.2
import XCTest
@testable import AstroTriage

/// Regression tests for the shared move machinery behind PRE-DELETE, Move to Folder and
/// Quarantine (`TriageViewModel.moveFrames`).
///
/// 6.9.2 root cause: after the move loop all three commands removed every MARKED frame from
/// the list, whether or not its `moveItem` had succeeded. A session whose root had lost its
/// security scope (NAS, reconstructed multi-folder root) therefore showed an emptied list while
/// every file was still in place. The contract tested here: only frames that physically moved
/// get an undo entry, failures are counted and described, and nothing else is touched.
final class PreDeleteMoveTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var dest: URL!

    override func setUpWithError() throws {
        // The hosted test target runs inside the app sandbox — the container's temp dir is the
        // reliable writable location there (lessons.md 2026-07-01).
        root = fm.temporaryDirectory
            .appendingPathComponent("PreDeleteMoveTests-\(UUID().uuidString)", isDirectory: true)
        dest = root.appendingPathComponent("PRE-DELETE", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Permissions are restored before removal so a failed test cannot leave an
        // undeletable folder behind.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func makeFile(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? root).appendingPathComponent(name)
        try Data([0x53, 0x49, 0x4D, 0x50]).write(to: url)   // "SIMP" — any bytes will do
        return url
    }

    private func frames(_ urls: [URL]) -> [(entry: ImageEntry, originalIndex: Int)] {
        urls.enumerated().map { (entry: ImageEntry(url: $0.element), originalIndex: $0.offset) }
    }

    // MARK: - The 6.9.2 bug

    func testOnlyMovedFramesGetUndoEntries() throws {
        let a = try makeFile("a.fits")
        let b = try makeFile("b.fits")
        let missing = root.appendingPathComponent("missing.fits")   // never created → move fails

        let result = TriageViewModel.moveFrames(frames([a, missing, b]), into: dest)

        XCTAssertEqual(result.movedCount, 2)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertNotNil(result.firstError, "a failure must carry a reason for the user")
        XCTAssertEqual(result.movedURLs, [a, b])
        XCTAssertFalse(result.movedURLs.contains(missing),
                       "a frame whose move failed must never be reported as moved")

        // Undo entries keep the row each frame came from.
        XCTAssertEqual(result.undoEntries.map { $0.originalIndex }, [0, 2])
        XCTAssertEqual(result.undoEntries.map { $0.preDeleteURL.lastPathComponent }, ["a.fits", "b.fits"])

        // And the file system agrees with the report.
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: b.path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("a.fits").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("b.fits").path))
    }

    func testUnwritableDestinationMovesNothingAndReportsEveryFrame() throws {
        // Running as root bypasses POSIX permissions — the probe below would be meaningless.
        try XCTSkipIf(getuid() == 0, "permission test needs a non-root user")

        let a = try makeFile("a.fits")
        let b = try makeFile("b.fits")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dest.path)   // r-x only
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path) }

        let result = TriageViewModel.moveFrames(frames([a, b]), into: dest)

        XCTAssertEqual(result.movedCount, 0)
        XCTAssertEqual(result.failedCount, 2)
        XCTAssertTrue(result.undoEntries.isEmpty, "nothing moved → nothing to undo")
        XCTAssertNotNil(result.firstError)

        // Sources untouched — this is exactly the state the old code hid behind an empty list.
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertTrue(fm.fileExists(atPath: b.path))
    }

    // MARK: - Existing behaviour that must survive the refactor

    func testNameCollisionGetsNumericSuffix() throws {
        let a = try makeFile("a.fits")
        try makeFile("a.fits", in: dest)      // already in PRE-DELETE from an earlier run
        try makeFile("a_1.fits", in: dest)    // …and its first suffix is taken too

        let result = TriageViewModel.moveFrames(frames([a]), into: dest)

        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.undoEntries.first?.preDeleteURL.lastPathComponent, "a_2.fits")
        XCTAssertEqual(result.undoEntries.first?.originalURL, a, "undo must point back at the source")
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("a_2.fits").path))
    }

    func testEmptyBatchIsANoOp() {
        let result = TriageViewModel.moveFrames([], into: dest)
        XCTAssertEqual(result.movedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertNil(result.firstError)
    }
}
