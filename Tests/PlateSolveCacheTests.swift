// PlateSolveCacheTests.swift
// Disk cache behind "Plate-Solve on Load" (6.11.0): a solve made in memory must survive a
// relaunch, and a file that changed size must miss.

import XCTest
@testable import AstroTriage

final class PlateSolveCacheTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlateSolveCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func entry(_ name: String, size: Int64) -> ImageEntry {
        var e = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(name)"))
        e.fileSize = size
        return e
    }

    private func solution(ra: Double) -> WCSSolution {
        WCSSolution(crval1: ra, crval2: 60.06, crpix1: 3124.5, crpix2: 2088.5,
                    cd11: -0.000437, cd12: 0.00014, cd21: 0.00014, cd22: 0.000437, crota2: 162.1)
    }

    func testStoreAndReloadFromDisk() throws {
        let file = work.appendingPathComponent("cache.json")
        let cache = PlateSolveCache(fileURL: file)
        let frame = entry("Light_SH2-157_0001.fit", size: 52_000_000)
        XCTAssertNil(cache.solution(for: frame))

        cache.store([SolvedFrame(entry: frame, solution: solution(ra: 349.0), previous: nil, identification: nil)])
        XCTAssertEqual(cache.solution(for: frame)?.crval1, 349.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "cache must be persisted")

        // A fresh instance (a relaunch) reads the same file back.
        let relaunched = PlateSolveCache(fileURL: file)
        XCTAssertEqual(relaunched.count, 1)
        XCTAssertEqual(relaunched.solution(for: frame)?.crota2, 162.1)
    }

    func testChangedFileSizeMisses() {
        let cache = PlateSolveCache(fileURL: work.appendingPathComponent("cache.json"))
        let frame = entry("Light_0002.fit", size: 100)
        cache.store([SolvedFrame(entry: frame, solution: solution(ra: 10), previous: nil, identification: nil)])
        XCTAssertNotNil(cache.solution(for: frame))
        XCTAssertNil(cache.solution(for: entry("Light_0002.fit", size: 101)), "same name, new size = different file")
        XCTAssertNil(cache.solution(for: entry("Light_0003.fit", size: 100)))
    }

    func testOldestRecordsArePrunedAtTheCap() {
        let cache = PlateSolveCache(fileURL: work.appendingPathComponent("cache.json"), maxRecords: 3)
        for i in 0..<5 {
            cache.store([SolvedFrame(entry: entry("f\(i).fit", size: 1), solution: solution(ra: Double(i)), previous: nil, identification: nil)])
        }
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.solution(for: entry("f0.fit", size: 1)), "oldest record pruned first")
        XCTAssertNotNil(cache.solution(for: entry("f4.fit", size: 1)))
    }
}
