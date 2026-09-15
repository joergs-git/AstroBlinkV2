// Every frame handed to the engine must appear in the report exactly once.
//
// Reported from live use: 381 frames were solved but the result window said "6 of 6".
// The engine appends to a captured struct from up to four concurrent operations, so a lost
// append would silently shrink the report — and the summary would read as if that were all
// there ever was.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class PlateSolveAccumulationTests: XCTestCase {

    /// Bogus binary/database: every frame fails fast, which is all this needs — the question
    /// is whether every OUTCOME is recorded, not what the outcome is.
    private let nowhere = URL(fileURLWithPath: "/nonexistent/astap")

    private func entries(_ count: Int) -> [ImageEntry] {
        (0..<count).map { ImageEntry(url: URL(fileURLWithPath: "/tmp/plate-accum-\($0).fit")) }
    }

    func testEveryFrameAppearsInTheReport() {
        let input = entries(200)
        var progressCalls = 0
        let progressLock = NSLock()

        let report = PlateSolveEngine().solve(
            entries: input,
            binary: nowhere,
            database: nowhere,
            skipAlreadySolved: false,
            progress: { _, _, _ in
                progressLock.lock(); progressCalls += 1; progressLock.unlock()
            }
        )

        XCTAssertEqual(report.attempted, input.count,
                       "the report lost frames: \(report.attempted) of \(input.count) recorded")
        XCTAssertEqual(report.failed.count, input.count)
        XCTAssertEqual(progressCalls, input.count, "progress was not reported for every frame")

        // Each frame exactly once — a duplicated append would also corrupt the count.
        let names = Set(report.failed.map { $0.entry.filename })
        XCTAssertEqual(names.count, input.count, "a frame was recorded more than once")
    }

    func testUnsupportedFramesAreAllRecordedToo() {
        let input = (0..<50).map { ImageEntry(url: URL(fileURLWithPath: "/tmp/x-\($0).tif")) }
        let report = PlateSolveEngine().solve(
            entries: input, binary: nowhere, database: nowhere,
            skipAlreadySolved: false, progress: { _, _, _ in }
        )
        XCTAssertEqual(report.skippedUnsupported.count, 50)
    }

    func testAlreadySolvedAreCountedNotDropped() {
        var input = entries(30)
        for index in 0..<10 {
            input[index].solvedRA = 83.84
            input[index].solvedDec = -5.35
            input[index].wcsCRPIX1 = 100; input[index].wcsCRPIX2 = 100
            input[index].wcsCD11 = -4.6e-4; input[index].wcsCD12 = 0
            input[index].wcsCD21 = 0; input[index].wcsCD22 = 4.6e-4
        }
        let report = PlateSolveEngine().solve(
            entries: input, binary: nowhere, database: nowhere,
            skipAlreadySolved: true, progress: { _, _, _ in }
        )
        XCTAssertEqual(report.skippedAlreadySolved, 10)
        XCTAssertEqual(report.attempted, 20, "the remaining frames must all be attempted")
    }
}
