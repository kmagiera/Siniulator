import AppKit
import XCTest
@testable import Siniulator

final class ControlBarTests: XCTestCase {
    func testNarrowBarFitsCombinedTitleAboveCenteredActions() {
        for width in [CGFloat(300), 351, 380] {
            let layout = SimulatorControlBarLayout(width: width, titleWidth: 140, isFullScreen: false)
            let bounds = CGRect(x: 0, y: 0, width: width, height: layout.height)
            XCTAssertTrue(layout.isCompact)
            XCTAssertEqual(layout.height, 76)
            XCTAssertEqual(layout.cornerRadius, 16)
            XCTAssertEqual(layout.buttons.midX, bounds.midX)
            XCTAssertTrue(bounds.contains(layout.name))
            XCTAssertTrue(bounds.contains(layout.buttons))
            XCTAssertGreaterThan(layout.buttons.minY, layout.name.maxY)
            XCTAssertGreaterThan(layout.name.minX, 70)
        }
    }
    func testWideBarAndFullScreenKeepSingleRowWithSeparateRuntimeLabel() {
        let cases: [(CGFloat, Bool, CGFloat)] = [(388, false, 0), (760, false, 0), (300, true, 32)]
        for (width, fullScreen, inset) in cases {
            let layout = SimulatorControlBarLayout(width: width, titleWidth: 140, isFullScreen: fullScreen, topInset: inset)
            XCTAssertFalse(layout.isCompact)
            XCTAssertEqual(layout.height, 52)
            XCTAssertEqual(layout.cornerRadius, fullScreen ? 0 : 26)
            XCTAssertLessThanOrEqual(layout.name.maxY, layout.runtime.minY)
            XCTAssertLessThan(layout.name.maxX, layout.buttons.minX)
            XCTAssertEqual(layout.buttons.maxX, width - 8)
            XCTAssertGreaterThanOrEqual(layout.name.minY, inset)
        }
    }
    func testCornerResizeAccountsForSecondRowWithoutChangingDeviceScale() {
        let session = DeviceResizeSession(corner: .bottomRight, initialFrame: CGRect(x: 700, y: 400, width: 464, height: 1028),
            initialPointer: .zero, deviceSize: CGSize(width: 440, height: 940), initialScale: 1,
            visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1662), minimumSize: CGSize(width: 324, height: 360), titleWidth: 140)
        let resized = session.geometry(at: CGPoint(x: -110, y: 235))
        XCTAssertEqual(resized.scale, 0.75)
        XCTAssertEqual(resized.frame.width, 354)
        XCTAssertEqual(resized.frame.height, 940 * 0.75 + 76 + 36)
        XCTAssertEqual(resized.frame.maxY, 1428)
    }
    func testFullScreenRevealSlidesTitleWithoutMovingActionsOrDeviceHeader() {
        let idle = SimulatorControlBarLayout(width: 756, titleWidth: 140, isFullScreen: true)
        for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            let layout = SimulatorControlBarLayout(width: 756, titleWidth: 140, isFullScreen: true, fullScreenRevealProgress: progress)
            XCTAssertEqual(layout.name.minX, 20 + 88 * progress)
            XCTAssertEqual(layout.runtime.minX, layout.name.minX)
            XCTAssertEqual(layout.name.maxX, idle.name.maxX)
            XCTAssertEqual(layout.name.minY, idle.name.minY)
            XCTAssertEqual(layout.buttons, idle.buttons)
            XCTAssertEqual(layout.height, idle.height)
        }
    }
    func testGrabbingWideWindowAtDisplayLimitDoesNotReserveAnUnusedSecondRow() {
        let scale = (CGFloat(1662) - 88) / 940
        let frame = CGRect(x: 500, y: 0, width: 440 * scale + 24, height: 1662)
        let session = DeviceResizeSession(corner: .bottomRight, initialFrame: frame, initialPointer: .zero,
            deviceSize: CGSize(width: 440, height: 940), initialScale: scale,
            visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1662), minimumSize: CGSize(width: 324, height: 360), titleWidth: 140)
        let unchanged = session.frame(at: .zero)
        XCTAssertEqual(unchanged.width, frame.width, accuracy: 0.001)
        XCTAssertEqual(unchanged.height, frame.height, accuracy: 0.001)
        XCTAssertEqual(unchanged.origin.y, frame.origin.y, accuracy: 0.001)
    }
}
