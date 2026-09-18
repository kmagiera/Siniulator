import AppKit
import XCTest
@testable import Siniulator

final class ResizeTests: XCTestCase {
    func testMinimumToolbarWidthStillAllowsShrinkingTheDevice() {
        let original = CGRect(x: 700, y: 400, width: 464, height: 1028)
        let session = DeviceResizeSession(corner: .bottomRight, initialFrame: original, initialPointer: .zero,
            deviceSize: CGSize(width: 440, height: 940), initialScale: 1,
            visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1662), minimumSize: CGSize(width: 440, height: 360))
        let reduced = session.frame(at: CGPoint(x: -220, y: 470))
        XCTAssertEqual(reduced.width, 440)
        XCTAssertEqual(reduced.height, 558)
        XCTAssertEqual(reduced.minX, original.minX)
        XCTAssertEqual(reduced.maxY, original.maxY)
    }
    func testStartingAnotherResizeAtMinimumWidthDoesNotTurnEmptySpaceIntoBezelPadding() {
        let original = CGRect(x: 700, y: 1000, width: 324, height: 394)
        let session = DeviceResizeSession(corner: .bottomRight, initialFrame: original, initialPointer: .zero,
            deviceSize: CGSize(width: 440, height: 940), initialScale: 0.3,
            visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1662), minimumSize: CGSize(width: 324, height: 360),
            titleWidth: 140)
        XCTAssertEqual(session.frame(at: .zero), original)
        let expanded = session.geometry(at: CGPoint(x: 440 * 0.6, y: -940 * 0.6))
        XCTAssertEqual(expanded.scale, 0.9, accuracy: 0.000001)
        XCTAssertEqual(expanded.frame.width, 440 * 0.9 + 24, accuracy: 0.000001)
        XCTAssertEqual(expanded.frame.height, 940 * 0.9 + 52 + 36, accuracy: 0.000001)
        XCTAssertEqual(expanded.frame.maxY, original.maxY, accuracy: 0.000001)
    }
    func testAllCornersPreserveOppositeCornerShapeAndFixedChrome() {
        for device in [CGSize(width: 440, height: 940), CGSize(width: 940, height: 440)] {
            let original = CGRect(x: 700, y: 400, width: device.width + 24, height: device.height + 88)
            for corner in DeviceResizeCorner.allCases {
                let session = DeviceResizeSession(corner: corner, initialFrame: original, initialPointer: .zero,
                    deviceSize: device, initialScale: 1, visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1662),
                    minimumSize: CGSize(width: 360, height: 360))
                XCTAssertEqual(session.frame(at: .zero), original)
                let next = session.frame(at: CGPoint(x: corner.isLeft ? -44 : 44, y: corner.isTop ? 94 : -94))
                XCTAssertGreaterThan(next.width, original.width)
                XCTAssertEqual(corner.isLeft ? next.maxX : next.minX, corner.isLeft ? original.maxX : original.minX, accuracy: 0.001)
                XCTAssertEqual(corner.isTop ? next.minY : next.maxY, corner.isTop ? original.minY : original.maxY, accuracy: 0.001)
                XCTAssertEqual((next.width - 24) / (next.height - 88), device.width / device.height, accuracy: 0.001)
            }
        }
    }
    func testDragClampsToMinimumAndDisplayIncludingNegativeCoordinates() {
        let display = CGRect(x: 668, y: -982, width: 1512, height: 950)
        let original = CGRect(x: 1100, y: -800, width: 244, height: 558)
        for corner in DeviceResizeCorner.allCases {
            let session = DeviceResizeSession(corner: corner, initialFrame: original, initialPointer: .zero,
                deviceSize: CGSize(width: 440, height: 940), initialScale: 0.5,
                visibleFrame: display, minimumSize: CGSize(width: 180, height: 300))
            let expanded = session.frame(at: CGPoint(x: corner.isLeft ? -10000 : 10000, y: corner.isTop ? 10000 : -10000))
            XCTAssertTrue(display.insetBy(dx: -0.001, dy: -0.001).contains(expanded))
            let reduced = session.frame(at: CGPoint(x: corner.isLeft ? 10000 : -10000, y: corner.isTop ? -10000 : 10000))
            XCTAssertGreaterThanOrEqual(reduced.width, 180)
            XCTAssertGreaterThanOrEqual(reduced.height, 300)
        }
    }
}
