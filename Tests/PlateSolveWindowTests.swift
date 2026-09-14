// Regression tests for the plate-solve result WINDOW itself.
//
// This window broke twice in the same way: SwiftUI content whose intrinsic width exceeded the
// window forced NSHostingController to size to the content, which made the window unresizable
// and clipped everything on the left. Both times it was found by eye, in a screenshot. These
// tests pin the property that was actually violated — the window must be able to shrink to its
// stated minimum — so the next wide column cannot reintroduce it silently.
//
// v6.9.0

import XCTest
import AppKit
@testable import AstroTriage

@MainActor
final class PlateSolveWindowTests: XCTestCase {

    private func entry(_ name: String) -> ImageEntry {
        ImageEntry(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func solution(ra: Double, dec: Double) -> WCSSolution {
        let s = 1.66 / 3600.0
        return WCSSolution(crval1: ra, crval2: dec, crpix1: 100, crpix2: 100,
                           cd11: -s, cd12: 0, cd21: 0, cd22: s, crota2: 0)
    }

    /// A report exercising the widest layout: every column populated, including the
    /// comparison columns that only appear on a re-solve.
    private func wideReport() -> PlateSolveReport {
        var report = PlateSolveReport()
        for index in 0..<12 {
            var e = entry("2026-09-14_IC1318_20-16-53_RC12_ASI6200MM_LIGHT_Ha_300s_#\(index).fit")
            e.focalLength = 469
            e.pixelSizeMicrons = 3.76
            e.binning = "1x1"
            let fresh = solution(ra: 305.2 + Double(index) * 0.01, dec: 41.95)
            report.solved.append(SolvedFrame(
                entry: e,
                solution: fresh,
                previous: solution(ra: 305.9, dec: 41.95),   // forces the Δ columns to appear
                identification: TargetIdentifier.identify(raDeg: 305.2, decDeg: 41.95,
                                                          fieldRadiusArcmin: 90)
            ))
        }
        report.failed = [(entry: entry("broken.fit"), reason: "no solution found")]
        report.duration = 1.6
        return report
    }

    private func showWindow(_ report: PlateSolveReport) throws -> NSWindow {
        PlateSolveResultWindowController.shared.show(
            report: report,
            unsupportedCount: 2,
            onSelectFrame: { _ in true },
            onSave: nil
        )
        return try XCTUnwrap(NSApp.windows.first { $0.title == "Plate Solve Results" },
                             "result window was not created")
    }

    override func tearDown() async throws {
        NSApp.windows.first { $0.title == "Plate Solve Results" }?.close()
        try await super.tearDown()
    }

    func testWindowIsResizableAndMovable() throws {
        let window = try showWindow(wideReport())
        XCTAssertTrue(window.styleMask.contains(.resizable), "user must be able to resize the table")
        XCTAssertTrue(window.styleMask.contains(.titled), "a titled window is what gives it a drag bar")
        XCTAssertTrue(window.styleMask.contains(.closable))
    }

    func testWindowCanActuallyShrinkToItsStatedMinimum() throws {
        let window = try showWindow(wideReport())
        let minimum = window.minSize

        // THE regression: if the SwiftUI content demands more width than this, AppKit refuses
        // the resize and the window stays stuck at the content's size.
        window.setContentSize(NSSize(width: minimum.width, height: minimum.height))

        let achieved = window.contentRect(forFrameRect: window.frame)
        XCTAssertEqual(achieved.width, minimum.width, accuracy: 2,
                       "window would not shrink to its minimum width — content is forcing it wider")
        XCTAssertEqual(achieved.height, minimum.height, accuracy: 2,
                       "window would not shrink to its minimum height")
    }

    func testWindowCanGrowBeyondItsDefaultSize() throws {
        let window = try showWindow(wideReport())
        window.setContentSize(NSSize(width: 1400, height: 900))

        let achieved = window.contentRect(forFrameRect: window.frame)
        XCTAssertEqual(achieved.width, 1400, accuracy: 2, "window would not grow")
        XCTAssertEqual(achieved.height, 900, accuracy: 2)
    }

    func testContentViewDoesNotExtendBeyondTheWindow() throws {
        let window = try showWindow(wideReport())
        window.setContentSize(NSSize(width: 800, height: 500))
        window.layoutIfNeeded()

        let content = try XCTUnwrap(window.contentView)
        // Content wider than its window is exactly what pushed the left-hand columns off
        // screen with no way to scroll back to them.
        XCTAssertLessThanOrEqual(content.frame.width, window.frame.width + 2,
                                 "content is wider than the window it lives in")
        XCTAssertEqual(content.frame.minX, 0, accuracy: 2,
                       "content is offset — the left edge is clipped")
    }

    func testWindowFloatsSoItDoesNotHideTheFrameItIsDriving() throws {
        let window = try showWindow(wideReport())
        // Clicking a row selects a frame in the main window; at normal level this panel would
        // cover the very thing the user is trying to look at.
        XCTAssertEqual(window.level, .floating)
    }

    func testReshowingUpdatesTheSameWindowRatherThanStacking() throws {
        _ = try showWindow(wideReport())
        _ = try showWindow(wideReport())
        let count = NSApp.windows.filter { $0.title == "Plate Solve Results" }.count
        XCTAssertEqual(count, 1, "a second run must reuse the window, not open another")
    }
}
