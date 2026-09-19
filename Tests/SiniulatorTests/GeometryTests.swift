import AppKit
import XCTest
@testable import Siniulator

final class GeometryTests: XCTestCase {
    func testDuoPresetAnimationEasesBothEndsWithoutOvershooting() {
        for (start, target) in [(0.0, 180.0), (180, 0), (60, 120), (120, 60)] {
            let animation = DuoHingeAnimation(start: start, target: target)
            XCTAssertEqual(animation.angle(at: -1), start)
            XCTAssertEqual(animation.angle(at: 0), start)
            XCTAssertEqual(animation.angle(at: 1), target)
            XCTAssertEqual(animation.angle(at: 2), target)
            XCTAssertEqual(animation.angle(at: 0.5), (start + target) / 2, accuracy: 1e-9)
            let distance = abs(target - start)
            XCTAssertLessThan(abs(animation.angle(at: 0.1) - start), distance * 0.02)
            XCTAssertLessThan(abs(target - animation.angle(at: 0.9)), distance * 0.02)
            var previous = start
            for step in 1...100 {
                let current = animation.angle(at: Double(step) / 100)
                XCTAssertTrue((min(start, target)...max(start, target)).contains(current))
                XCTAssertGreaterThanOrEqual((current - previous) * (target - start), 0)
                previous = current
            }
        }
        let closing = DuoHingeAnimation(start: 180, target: 0)
        let visible = closing.angle(at: 0.4)
        let retargeted = DuoHingeAnimation(start: visible, target: 120)
        XCTAssertEqual(retargeted.angle(at: 0), visible, "Retargeting must not jump to the previous preset")
    }

    @MainActor func testBezelArtworkDrawsEveryEdgeWithoutAnUnusedScreenAsset() async throws {
        let edge = NSImage(size: CGSize(width: 10, height: 10), flipped: true) { bounds in
            NSColor.red.setFill()
            bounds.fill()
            return true
        }
        let artwork = try XCTUnwrap(DeviceBezelArtwork { name in name == "screen" ? nil : edge })
        let rendered = NSImage(size: CGSize(width: 80, height: 160), flipped: true) { bounds in
            artwork.draw(in: bounds)
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
        for point in [(5, 5), (40, 5), (75, 5), (5, 80), (75, 80), (5, 155), (40, 155), (75, 155)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        }
        XCTAssertEqual(bitmap.colorAt(x: 40, y: 80)?.alphaComponent, 0, "Bezel artwork must not cover the simulator display")
        XCTAssertNil(DeviceBezelArtwork { name in name == "top" ? nil : edge },
            "Incomplete system artwork should use the fallback bezel")
    }

    func testTwoFingerTranslationPreservesSeparationAndStaysInsideScreen() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
        let separation = CGPoint(x: gesture.second.x - gesture.first.x, y: gesture.second.y - gesture.first.y)
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: true)
        gesture.update(pointer: CGPoint(x: 0.4, y: 0.5), translating: true)
        XCTAssertEqual(gesture.center.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(gesture.second.x - gesture.first.x, separation.x, accuracy: 0.0001)
        XCTAssertEqual(gesture.second.y - gesture.first.y, separation.y, accuracy: 0.0001)
        gesture.update(pointer: CGPoint(x: 1, y: 1), translating: true)
        for point in [gesture.first, gesture.second] {
            XCTAssertTrue((0...1).contains(point.x)); XCTAssertTrue((0...1).contains(point.y))
        }
    }
    func testLaunchURLsOnlySelectValidSimulatorIDs() {
        let id = "7CBAD1F7-44F1-40BD-9DC8-C48BCE837ECB"
        XCTAssertEqual(DeviceLaunchURL.deviceID(in: URL(string: "siniulator://open?udid=\(id)")!), id)
        XCTAssertEqual(DeviceLaunchURL.deviceID(in: URL(string: "devices:///manage/select?id=\(id)")!), id)
        XCTAssertEqual(DeviceLaunchURL.deviceID(in: URL(string: "devices://device/open?id=\(id)")!), id)
        XCTAssertNil(DeviceLaunchURL.deviceID(in: URL(string: "devices:///delete?id=\(id)")!))
        XCTAssertNil(DeviceLaunchURL.deviceID(in: URL(string: "siniulator://open?udid=invalid")!))
    }
    func testAspectFitLeavesLetterboxingOutsideTouchArea() {
        let rect = ScreenGeometry.imageRect(image: CGSize(width: 400, height: 800), in: CGRect(x: 0, y: 0, width: 600, height: 600))
        XCTAssertEqual(rect, CGRect(x: 150, y: 0, width: 300, height: 600))
        XCTAssertFalse(rect.contains(CGPoint(x: 100, y: 300)))
    }
    func testTouchCoordinatesForEveryOrientation() {
        let point = CGPoint(x: 0.2, y: 0.7)
        let expected = [CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.7, y: 0.8), CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.3, y: 0.2)]
        for turns in 0..<4 {
            let result = ScreenGeometry.originalPoint(point, quarterTurns: turns)
            XCTAssertEqual(result.x, expected[turns].x, accuracy: 0.00001)
            XCTAssertEqual(result.y, expected[turns].y, accuracy: 0.00001)
        }
    }
    func testNativeDisplayRotationIsAddedToGuestOrientation() {
        XCTAssertEqual(ScreenGeometry.nativeQuarterTurns(degrees: 270), 1)
        XCTAssertEqual(ScreenGeometry.displayQuarterTurns(orientation: 0, nativeRotation: 3), 3)
        XCTAssertEqual(ScreenGeometry.displayQuarterTurns(orientation: 1, nativeRotation: 3), 0)
        XCTAssertEqual(ScreenGeometry.displayQuarterTurns(orientation: 2, nativeRotation: 3), 1)
        XCTAssertEqual(ScreenGeometry.displayQuarterTurns(orientation: 3, nativeRotation: 3), 2)
    }
    func testSystemGestureEdges() {
        XCTAssertEqual(ScreenGeometry.edge(CGPoint(x: 0.5, y: 0.99)), 3)
        XCTAssertEqual(ScreenGeometry.edge(CGPoint(x: 0.5, y: 0.01)), 1)
        XCTAssertEqual(ScreenGeometry.edge(CGPoint(x: 0.01, y: 0.5)), 2)
        XCTAssertEqual(ScreenGeometry.edge(CGPoint(x: 0.5, y: 0.5)), 0)
    }
    func testDeviceAvailabilityAndRuntimeGrouping() throws {
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"A","name":"iPhone","state":"Shutdown","isAvailable":true},{"udid":"B","name":"iPad","state":"Booted","isAvailable":true},{"udid":"C","name":"Removed","state":"Shutdown","isAvailable":false}]}}"#
        let list = try JSONDecoder().decode(DeviceList.self, from: Data(json.utf8))
        XCTAssertEqual(list.available.map(\.id), ["B", "A"])
        XCTAssertEqual(list.available[0].runtimeName, "iOS 27.0")
    }
    func testHIDMappingForTextAndNavigation() {
        XCTAssertEqual(KeyboardMap.usages[0], 4)
        XCTAssertEqual(KeyboardMap.usages[36], 40)
        XCTAssertEqual(KeyboardMap.usages[51], 42)
        XCTAssertEqual(KeyboardMap.usages[123], 80)
    }
    func testFoldableHingePayloadEncodesPresetAngles() throws {
        XCTAssertEqual(DeviceDisplayMode.cover.hingeAngle, 0)
        XCTAssertEqual(DeviceDisplayMode.innerPartiallyOpen.hingeAngle, 120)
        XCTAssertEqual(DeviceDisplayMode.innerFullyOpen.hingeAngle, 180)
        for angle in [0.0, 120.0, 180.0] {
            let data = try XCTUnwrap(SimulatorInput.hingeEventData(angle: angle))
            let encodedAngle = withUnsafeBytes(of: angle.bitPattern.littleEndian) { Data($0) }
            XCTAssertNotNil(data.range(of: encodedAngle))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("hinge-slider-control"))
            XCTAssertTrue(text.contains("range"))
        }
        let orientationValues = ["portrait", "landscape-right", "pud", "landscape-left"]
        for (turns, expected) in orientationValues.enumerated() {
            let data = try XCTUnwrap(SimulatorInput.orientationEventData(quarterTurns: turns))
            XCTAssertGreaterThan(data.count, 100)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(expected))
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("orientation-picker-control"))
        }
    }

    func testContinuousHingeAngleChoosesTheVisibleDuoPanel() {
        XCTAssertEqual(DeviceDisplayMode.mode(forHingeAngle: 0), .cover)
        XCTAssertEqual(DeviceDisplayMode.mode(forHingeAngle: 15), .cover)
        XCTAssertEqual(DeviceDisplayMode.mode(forHingeAngle: 15.1), .innerPartiallyOpen)
        XCTAssertEqual(DeviceDisplayMode.mode(forHingeAngle: 120), .innerPartiallyOpen)
        XCTAssertEqual(DeviceDisplayMode.mode(forHingeAngle: 179), .innerPartiallyOpen)
        XCTAssertEqual(DeviceDisplayMode.mode(forHingeAngle: 180), .innerFullyOpen)
    }
    func testDeviceFrameKeepsItsScreenInsideTheBezelAfterRotation() {
        for turn in 0..<4 {
            let geometry = ChromeGeometry(screenSize: CGSize(width: 400, height: 800), border: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20),
                padding: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10), quarterTurns: turn)
            let fit = geometry.fit(in: CGRect(x: 0, y: 0, width: 1000, height: 700))
            let screen = ChromeGeometry.placed(geometry.screen, in: fit.rect, scale: fit.scale)
            XCTAssertTrue(fit.rect.contains(screen))
            XCTAssertEqual(screen.width / screen.height, turn % 2 == 0 ? 0.5 : 2, accuracy: 0.0001)
            XCTAssertEqual(fit.rect.midX, 500, accuracy: 0.0001)
            XCTAssertEqual(fit.rect.midY, 350, accuracy: 0.0001)
        }
    }

    @MainActor func testFoldableMapsCoverAndInnerDisplayModes() {
        let displays: [[String: Any]] = [
            ["displayType": "integrated", "deviceName": "primary", "screenID": 1, "width": 1398, "height": 2034, "nativeRotation": 0],
            ["displayType": "integrated", "deviceName": "primary-1", "screenID": 3, "width": 2007, "height": 2853, "nativeRotation": 270],
            ["displayType": "tvOut", "deviceName": "external-0", "width": 7680, "height": 4320]
        ]
        let selected = DeviceChrome.preferredDisplay(in: displays)
        XCTAssertEqual(selected["deviceName"] as? String, "primary-1")
        XCTAssertEqual(selected["nativeRotation"] as? Int, 270)
        XCTAssertEqual(DeviceChrome.preferredDigitizerTarget(in: displays), 3)
        let cover = DeviceChrome.preferredDisplay(in: displays, displayMode: .cover)
        XCTAssertEqual(cover["deviceName"] as? String, "primary")
        XCTAssertEqual(DeviceChrome.preferredDigitizerTarget(in: displays, displayMode: .cover), 1)
        XCTAssertEqual(DeviceChrome.preferredDisplay(in: displays, displayMode: .innerPartiallyOpen)["screenID"] as? Int, 3)
        XCTAssertEqual(DeviceChrome.preferredDisplay(in: displays, displayMode: .innerFullyOpen)["screenID"] as? Int, 3)
        XCTAssertEqual(DeviceChrome.preferredDigitizerTarget(in: [displays[0]]), 0)
    }
}
