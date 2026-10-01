import AppKit
import XCTest
@testable import Siniulator

final class ResizeTests: XCTestCase {
    private let duoToolbar = DuoToolbarSizing(widthFraction: 0.7, minimumWidth: 400)

    func testDuoCornersScaleHardwareAndToolbarAndPreserveItsOppositeCorner() {
        let device = CGRect(x: 450, y: 400, width: 300, height: 410)
        let header: CGFloat = 52
        let original = CGRect(x: device.midX - 261, y: device.minY - 16, width: 522, height: 498)
        for corner in DeviceResizeCorner.allCases {
            let session = DuoResizeSession(corner: corner, initialFrame: original, initialDevice: device,
                initialPointer: .zero, initialViewport: 700, headerHeight: header,
                visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1500), toolbarSizing: duoToolbar)
            XCTAssertEqual(session.geometry(at: .zero).frame, original)
            let next = session.geometry(at: CGPoint(x: corner.isLeft ? -30 : 30, y: corner.isTop ? 41 : -41))
            XCTAssertEqual(next.viewport, 770, accuracy: 0.001)
            XCTAssertEqual(next.frame.width, 572)
            XCTAssertEqual(next.frame.height, 539)
            let projected = CGRect(x: next.frame.midX - 165, y: next.frame.maxY - header - 20 - 451,
                width: 330, height: 451)
            XCTAssertEqual(corner.isLeft ? projected.maxX : projected.minX,
                corner.isLeft ? device.maxX : device.minX, accuracy: 0.001)
            XCTAssertEqual(corner.isTop ? projected.minY : projected.maxY,
                corner.isTop ? device.minY : device.maxY, accuracy: 0.001)
        }
    }

    func testDuoResizeClampsCompleteSweepToDisplayAndDoesNotSaveToolbarSlack() {
        let device = CGRect(x: 600, y: -800, width: 240, height: 310)
        let original = CGRect(x: device.midX - 226, y: device.minY - 16, width: 452, height: 398)
        let display = CGRect(x: 0, y: -1000, width: 1512, height: 950)
        for corner in DeviceResizeCorner.allCases {
            let session = DuoResizeSession(corner: corner, initialFrame: original, initialDevice: device,
                initialPointer: .zero, initialViewport: 600, headerHeight: 52, visibleFrame: display, toolbarSizing: duoToolbar)
            let expanded = session.geometry(at: CGPoint(x: corner.isLeft ? -10000 : 10000,
                y: corner.isTop ? 10000 : -10000))
            XCTAssertEqual(expanded.viewport, 862)
            XCTAssertTrue(display.contains(expanded.frame))
            let shrunk = session.geometry(at: CGPoint(x: corner.isLeft ? 10000 : -10000,
                y: corner.isTop ? -10000 : 10000))
            XCTAssertEqual(shrunk.viewport, 280)
            XCTAssertEqual(shrunk.frame.width, 432)
            XCTAssertEqual(shrunk.frame.height, ceil(310 * 280 / 600 + 88))
        }
    }
    func testDuoMaximumSizeUsesProjectedSweepNotEmptySquareViewport() {
        let device = CGRect(x: 600, y: 500, width: 240, height: 310)
        let session = DuoResizeSession(corner: .bottomRight,
            initialFrame: CGRect(x: 394, y: 484, width: 652, height: 398),
            initialDevice: device, initialPointer: .zero, initialViewport: 700,
            headerHeight: 52, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            toolbarSizing: duoToolbar, maximumSpan: 0.6)
        let expanded = session.geometry(at: CGPoint(x: 10000, y: -10000))
        XCTAssertEqual(expanded.viewport, 862 / 0.6, accuracy: 0.001)
        XCTAssertLessThanOrEqual(expanded.frame.height, 950)
        XCTAssertGreaterThan(expanded.frame.height, 700, "Do not limit the phone using the unused render-surface margins")
    }
    func testDuoResizeUsesTheWiderToolbarWhenCrossingCompactWidth() {
        let device = CGSize(width: 600, height: 440)
        let initial = CGRect(x: 100, y: 300, width: 624, height: 512)
        let session = DeviceResizeSession(corner: .bottomRight, initialFrame: initial, initialPointer: .zero,
            deviceSize: device, initialScale: 1, visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1500),
            minimumSize: CGSize(width: 300, height: 300),
            toolbarMetrics: SimulatorToolbarMetrics(titleWidth: 80, modeSize: CGSize(width: 128, height: 36)))
        XCTAssertEqual(session.frame(at: .zero), initial)
        let smaller = session.geometry(at: CGPoint(x: -180, y: 132))
        XCTAssertEqual(smaller.scale, 0.7, accuracy: 0.001)
        XCTAssertEqual(smaller.frame.width, 444, accuracy: 0.001)
        // A 444 pt bar fits the ordinary controls but not the Duo controls.
        XCTAssertEqual(smaller.frame.height, 440 * 0.7 + 76 + 20, accuracy: 0.001)
        XCTAssertEqual(smaller.frame.maxY, initial.maxY)
    }

    func testCornerHitTargetFollowsTheVisibleRoundedOutline() {
        let device = CGRect(x: 100, y: 200, width: 500, height: 320)
        let radius: CGFloat = 60
        for corner in DeviceResizeCorner.allCases {
            let offset = radius * (1 - 1 / sqrt(2))
            let visibleCurve = CGPoint(x: corner.isLeft ? device.minX + offset : device.maxX - offset,
                y: corner.isTop ? device.minY + offset : device.maxY - offset)
            let target = corner.hitRect(in: device, radius: radius)
            XCTAssertTrue(target.contains(visibleCurve))
            XCTAssertEqual(target.size, CGSize(width: 28, height: 28))
        }
    }

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
            toolbarMetrics: SimulatorToolbarMetrics(titleWidth: 140))
        XCTAssertEqual(session.frame(at: .zero), original)
        let expanded = session.geometry(at: CGPoint(x: 440 * 0.6, y: -940 * 0.6))
        XCTAssertEqual(expanded.scale, 0.9, accuracy: 0.000001)
        XCTAssertEqual(expanded.frame.width, 440 * 0.9 + 24, accuracy: 0.000001)
        XCTAssertEqual(expanded.frame.height, 940 * 0.9 + 52 + 36, accuracy: 0.000001)
        XCTAssertEqual(expanded.frame.maxY, original.maxY, accuracy: 0.000001)
    }
    func testResizeDoesNotJumpWhenFoldableRetainsAWiderFrameAcrossModes() {
        let original = CGRect(x: 700, y: 800, width: 520, height: 440)
        let session = DeviceResizeSession(corner: .bottomRight, initialFrame: original, initialPointer: .zero,
            deviceSize: CGSize(width: 440, height: 940), initialScale: 0.35,
            visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1662), minimumSize: CGSize(width: 300, height: 300),
            toolbarMetrics: SimulatorToolbarMetrics(titleWidth: 140))
        XCTAssertEqual(session.frame(at: .zero), original)
        let expanded = session.frame(at: CGPoint(x: 44, y: -94))
        XCTAssertGreaterThan(expanded.width, original.width)
        XCTAssertGreaterThan(expanded.height, original.height)
        XCTAssertEqual(expanded.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(expanded.maxY, original.maxY, accuracy: 0.001)
        let reduced = session.frame(at: CGPoint(x: -220, y: 470))
        XCTAssertLessThan(reduced.width, original.width)
        XCTAssertLessThan(reduced.height, original.height)
        XCTAssertGreaterThanOrEqual(reduced.width, 300)
        XCTAssertGreaterThanOrEqual(reduced.height, 300)
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
