import AppKit
import XCTest
@testable import Siniulator

final class ScalingTests: XCTestCase {
    func testPhysicalSizePreservesInchesAcrossDevicesMonitorScalingAndOrientation() throws {
        for (pixels, deviceScale, dpi) in [(CGSize(width: 1320, height: 2868), CGFloat(3), CGFloat(460)),
                                          (CGSize(width: 1640, height: 2360), CGFloat(2), CGFloat(264))] {
            for pointsPerInch in [CGFloat(72), 109, 127, 144] {
                let scale = try XCTUnwrap(DeviceScalingMode.physicalSize.logicalScale(deviceScale: deviceScale,
                    backingScale: 2, deviceDPI: dpi, displayPointsPerInch: pointsPerInch))
                for turn in 0..<4 {
                    let geometry = ChromeGeometry(screenSize: CGSize(width: pixels.width / deviceScale, height: pixels.height / deviceScale),
                        border: NSEdgeInsetsZero, padding: NSEdgeInsetsZero, quarterTurns: turn)
                    let widthInches = geometry.screen.width * scale / pointsPerInch
                    let heightInches = geometry.screen.height * scale / pointsPerInch
                    XCTAssertEqual(widthInches, (turn % 2 == 0 ? pixels.width : pixels.height) / dpi, accuracy: 0.000001)
                    XCTAssertEqual(heightInches, (turn % 2 == 0 ? pixels.height : pixels.width) / dpi, accuracy: 0.000001)
                }
            }
        }
    }

    func testPhysicalSizeRequiresValidDeviceAndDisplayDensity() {
        for dpi in [CGFloat?.none, 0, -1, .infinity, .nan] {
            XCTAssertNil(DeviceScalingMode.physicalSize.logicalScale(deviceScale: 3, backingScale: 2,
                deviceDPI: dpi, displayPointsPerInch: 109))
            XCTAssertNil(DeviceScalingMode.physicalSize.logicalScale(deviceScale: 3, backingScale: 2,
                deviceDPI: 460, displayPointsPerInch: dpi))
        }
    }

    func testPointAccurateMapsUIKitPointsToAppKitPointsAtEveryDisplayDensity() {
        for deviceScale in [CGFloat(1), 2, 3] {
            for backingScale in [CGFloat(1), 2] {
                XCTAssertEqual(DeviceScalingMode.pointAccurate.logicalScale(deviceScale: deviceScale, backingScale: backingScale), 1)
            }
        }
    }
    func testPixelAccurateMapsEachDevicePixelToOneMonitorPixelInEveryOrientation() throws {
        for deviceScale in [CGFloat(1), 2, 3] {
            for backingScale in [CGFloat(1), 2] {
                let scale = try XCTUnwrap(DeviceScalingMode.pixelAccurate.logicalScale(deviceScale: deviceScale, backingScale: backingScale))
                for turn in 0..<4 {
                    let pixels = CGSize(width: 1206, height: 2622)
                    let geometry = ChromeGeometry(screenSize: CGSize(width: pixels.width / deviceScale, height: pixels.height / deviceScale),
                        border: NSEdgeInsetsZero, padding: NSEdgeInsetsZero, quarterTurns: turn)
                    XCTAssertEqual(geometry.screen.width * scale * backingScale, turn % 2 == 0 ? pixels.width : pixels.height, accuracy: 0.000001)
                    XCTAssertEqual(geometry.screen.height * scale * backingScale, turn % 2 == 0 ? pixels.height : pixels.width, accuracy: 0.000001)
                }
            }
        }
    }
}
