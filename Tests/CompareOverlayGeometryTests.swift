import XCTest
@testable import AstroTriage

/// The Compare window draws its star circles from positions measured in FILE coordinates.
/// When Auto Rotate shows a frame rotated by 180° (after a meridian flip), the circles have
/// to be mirrored through the image center — otherwise none of them sits on a star.
final class CompareOverlayGeometryTests: XCTestCase {

    private let center = CGPoint(x: 500, y: 400)
    private let size = CGSize(width: 900, height: 600)

    func testUnrotatedTopLeftStarIsTopLeftInView() {
        // File (0,0) = image top-left; a non-flipped NSView has its top at high Y.
        let p = StarOverlayView.viewPosition(normalizedX: 0, normalizedY: 0,
                                             center: center, displayedSize: size, rotate180: false)
        XCTAssertEqual(p.x, 50, accuracy: 1e-9)
        XCTAssertEqual(p.y, 700, accuracy: 1e-9)
    }

    func testRotatedStarIsMirroredThroughImageCenter() {
        // Real star of frame B #0167 (8409, 5059 on 9576 x 6388): lower right in the file,
        // upper left on a panel that shows the frame rotated by 180°.
        let nx: CGFloat = 8409.0 / 9576.0, ny: CGFloat = 5059.0 / 6388.0
        let plain = StarOverlayView.viewPosition(normalizedX: nx, normalizedY: ny,
                                                 center: center, displayedSize: size, rotate180: false)
        let rotated = StarOverlayView.viewPosition(normalizedX: nx, normalizedY: ny,
                                                   center: center, displayedSize: size, rotate180: true)
        XCTAssertEqual(rotated.x, 2 * center.x - plain.x, accuracy: 1e-9)
        XCTAssertEqual(rotated.y, 2 * center.y - plain.y, accuracy: 1e-9)
        XCTAssertLessThan(rotated.x, center.x)     // left half
        XCTAssertGreaterThan(rotated.y, center.y)  // upper half (non-flipped view)
    }

    func testImageCenterStaysPutUnderRotation() {
        let p = StarOverlayView.viewPosition(normalizedX: 0.5, normalizedY: 0.5,
                                             center: center, displayedSize: size, rotate180: true)
        XCTAssertEqual(p.x, center.x, accuracy: 1e-9)
        XCTAssertEqual(p.y, center.y, accuracy: 1e-9)
    }
}
