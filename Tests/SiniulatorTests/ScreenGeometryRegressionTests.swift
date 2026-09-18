import AppKit
import XCTest
@testable import Siniulator

final class ScreenGeometryRegressionTests: XCTestCase {
    func testSignedRotationsWrapToTheirEquivalentOrientation() {
        let point = CGPoint(x: 0.2, y: 0.7)
        for turns in -12...12 {
            let normalized = ScreenGeometry.normalizedQuarterTurns(turns)
            XCTAssertTrue((0..<4).contains(normalized))
            XCTAssertEqual(ScreenGeometry.originalPoint(point, quarterTurns: turns),
                ScreenGeometry.originalPoint(point, quarterTurns: normalized))
        }
        XCTAssertEqual(ScreenGeometry.normalizedQuarterTurns(-1), 3)
        XCTAssertEqual(ScreenGeometry.normalizedQuarterTurns(Int.min), 0)
        XCTAssertEqual(ScreenGeometry.normalizedQuarterTurns(Int.max), 3)
    }

    func testInvalidImageOrViewSizeHasNoTouchArea() {
        let image = CGSize(width: 400, height: 800)
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 600)
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 800), CGSize(width: 400, height: CGFloat.nan)] {
            XCTAssertEqual(ScreenGeometry.imageRect(image: size, in: bounds), .zero)
        }
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 600, height: CGFloat.nan)] {
            XCTAssertEqual(ScreenGeometry.imageRect(image: image, in: CGRect(origin: .zero, size: size)), .zero)
        }
    }
}
