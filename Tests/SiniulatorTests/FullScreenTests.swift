import AppKit
import XCTest
@testable import Siniulator

final class FullScreenTests: XCTestCase {
    func testDeviceKeepsItsMarginsInsideAsymmetricSafeAreas() {
        let bounds = CGRect(x: 100, y: 200, width: 1200, height: 800)
        let insets = NSEdgeInsets(top: 32, left: 44, bottom: 8, right: 20)
        let layout = FullScreenPresentationLayout(bounds: bounds, safeAreaInsets: insets)
        XCTAssertEqual(layout.header, CGRect(x: 100, y: 200, width: 1200, height: 84))
        XCTAssertEqual(layout.canvas.minX, bounds.minX + insets.left + 36)
        XCTAssertEqual(layout.canvas.maxX, bounds.maxX - insets.right - 36)
        XCTAssertEqual(layout.canvas.minY, layout.header.maxY + 36)
        XCTAssertEqual(layout.canvas.maxY, bounds.maxY - insets.bottom - 36)
    }

    func testAllDeviceOrientationsFitBelowHeaderInFullScreenAndSplitView() {
        for size in [CGSize(width: 3008, height: 1692), CGSize(width: 1504, height: 1692),
                     CGSize(width: 756, height: 982), CGSize(width: 360, height: 600)] {
            for insets in [NSEdgeInsetsZero, NSEdgeInsets(top: 32, left: 0, bottom: 8, right: 0)] {
                let bounds = CGRect(origin: .zero, size: size)
                let layout = FullScreenPresentationLayout(bounds: bounds, safeAreaInsets: insets)
                XCTAssertEqual(layout.header.width, size.width)
                XCTAssertTrue(bounds.contains(layout.canvas))
                XCTAssertGreaterThanOrEqual(layout.canvas.minY, layout.header.maxY + 36)
                for turn in 0..<4 {
                    let device = ChromeGeometry(screenSize: CGSize(width: 440, height: 956),
                        border: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16),
                        padding: NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9), quarterTurns: turn)
                    let fitted = device.fit(in: layout.canvas).rect
                    XCTAssertTrue(layout.canvas.contains(fitted))
                    XCTAssertEqual(fitted.midX, layout.canvas.midX, accuracy: 0.001)
                    XCTAssertEqual(fitted.midY, layout.canvas.midY, accuracy: 0.001)
                    XCTAssertEqual(fitted.width / fitted.height, device.size.width / device.size.height, accuracy: 0.0001)
                    XCTAssertGreaterThanOrEqual(fitted.minY, layout.header.maxY + 36)
                }
            }
        }
    }
}
