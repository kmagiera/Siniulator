import AppKit
import IOSurface
import SimulatorBridge
import XCTest
@testable import Siniulator

final class DuoInputTests: XCTestCase {
    @MainActor func testPendingConnectionKeepsItsPanelWhenTheRequestedPoseChanges() async throws {
        let device = SimulatorDevice(udid: "duo-connect-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let inner = DeviceChrome.load(for: device, displayMode: .innerFullyOpen)
        let cover = DeviceChrome.load(for: device, displayMode: .cover)
        for initial in [inner, cover] {
            var requested = initial
            let display = SIDisplay()
            let panel = try await SimulatorPanelConnection.connect(device.id, chrome: requested) { id, screenID, width, height in
                XCTAssertEqual(id, device.id)
                XCTAssertEqual(screenID, initial.screenID)
                XCTAssertEqual(width, initial.pixelWidth)
                XCTAssertEqual(height, initial.pixelHeight)
                await Task.yield()
                requested = initial === inner ? cover : inner
                return (SICoreSimulator(), NSObject(), display)
            }
            XCTAssertTrue(panel.chrome === initial)
            XCTAssertFalse(panel.chrome === requested)
            XCTAssertTrue(panel.display === display)
            let screen = SimulatorScreenView(renderer: try ScreenRenderer())
            let root = DevicePresentationView(screen: screen, chrome: requested, device: device) { _ in }
            screen.setDisplay(panel.display, chrome: panel.chrome)
            root.canvas.setChrome(requested)
            XCTAssertTrue(screen.displayChrome === initial)
            XCTAssertEqual(screen.nativeQuarterTurns, initial.nativeQuarterTurns)
        }
    }

#if DEBUG
    @MainActor func testFlatOptionDragRetainsRotationAndOverlayWithAndWithoutBezels() throws {
        let surface = try XCTUnwrap(IOSurfaceCreate([kIOSurfaceWidth: 256, kIOSurfaceHeight: 256,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 1024] as CFDictionary))
        for type in ["iPhone-17-Pro", "iPhone-Duo"] { for bezels in [false, true] {
            if type == "iPhone-Duo" && bezels { continue } // 3D path tested separately.
            let device = SimulatorDevice(udid: "flat-input-test", name: type, state: "Booted",
                isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.\(type)",
                runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
            for turn in 0..<4 {
                let screen = SimulatorScreenView(renderer: try ScreenRenderer())
                screen.quarterTurns = turn
                let chrome = DeviceChrome.load(for: device)
                let root = DevicePresentationView(screen: screen, chrome: chrome, device: device) { _ in }
                root.canvas.showsBezels = bezels
                root.frame = CGRect(x: 0, y: 0, width: 800, height: 640)
                screen.setDisplay(Display(surface), chrome: chrome)
                root.layoutSubtreeIfNeeded()
                XCTAssertNil(screen.coordinateMapper)
                let rect = ScreenGeometry.imageRect(image: screen.framebufferSize, in: screen.bounds)
                let local = CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.4)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: screen.convert(local, to: nil),
                    modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                screen.mouseDown(with: event)
                let expected = ScreenGeometry.originalPoint(CGPoint(x: 0.3, y: 0.4), quarterTurns: screen.displayQuarterTurns)
                let first = try XCTUnwrap(screen.diagnosticContacts.first)
                XCTAssertEqual(first.x, expected.x, accuracy: 0.001)
                XCTAssertEqual(first.y, expected.y, accuracy: 0.001)
                XCTAssertTrue(screen.gestureOverlay.superview === screen.superview)
                XCTAssertEqual(screen.gestureOverlay.frame, screen.frame)
                XCTAssertFalse(screen.gestureOverlay.isHiddenOrHasHiddenAncestor)
                let marker = try XCTUnwrap(screen.gestureOverlay.layer?.sublayers?.first as? CAShapeLayer)
                let markerBounds = try XCTUnwrap(marker.path).boundingBox
                XCTAssertFalse(marker.isHidden)
                XCTAssertEqual(markerBounds.midX, local.x, accuracy: 0.1)
                XCTAssertEqual(markerBounds.midY, local.y, accuracy: 0.1)
                screen.releaseKeys()
                XCTAssertTrue(marker.isHidden)
                XCTAssertTrue(screen.diagnosticContacts.isEmpty)
            }
        } }
    }
#endif

    @MainActor func testCameraStartsTurningEarlierAndKeepsTheInputHandoffAligned() {
        XCTAssertEqual(DuoModelView.cameraOrbit(forHingeAngle: 40), 0)
        XCTAssertLessThan(DuoModelView.cameraOrbit(forHingeAngle: 30), 0,
            "At 150° closed the camera must already be turning")
        XCTAssertEqual(DuoModelView.cameraOrbit(forHingeAngle: CGFloat(DeviceDisplayMode.coverHandoffAngle)), -.pi / 4,
            accuracy: 0.0001)
        XCTAssertEqual(DuoModelView.cameraOrbit(forHingeAngle: 0), -.pi / 2, accuracy: 0.0001)
        var previous: CGFloat = 0
        for angle in stride(from: CGFloat(180), through: 0, by: -0.1) {
            let orbit = DuoModelView.cameraOrbit(forHingeAngle: angle)
            XCTAssertLessThanOrEqual(orbit, previous + 0.0001)
            XCTAssertLessThan(abs(orbit - previous), 0.006, "No camera jump at the display handoff")
            previous = orbit
        }
    }

    private final class Display: SIDisplay {
        let framebuffer: IOSurface
        init(_ framebuffer: IOSurface) { self.framebuffer = framebuffer; super.init() }
        override var surface: Any? { framebuffer }
    }

    @MainActor func testTouchCoordinatesMatchRenderedFramebufferInEveryPoseAndRotation() throws {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The selected Xcode does not include the Duo model")
        }
        let device = SimulatorDevice(udid: "duo-uv-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        // Encode framebuffer x/y in red/green. The rendered pixels provide an
        // independent oracle, including skinning, perspective and texture rotation.
        let side = 256
        let surface = try XCTUnwrap(IOSurfaceCreate([
            kIOSurfaceWidth: side, kIOSurfaceHeight: side, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: side * 4, kIOSurfacePixelFormat: UInt32(0x42475241)
        ] as CFDictionary))
        IOSurfaceLock(surface, [], nil)
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
        for y in 0..<side { for x in 0..<side {
            pixels[y * side + x] = 0xff0000ff | UInt32(x << 16) | UInt32(y << 8)
        } }
        IOSurfaceUnlock(surface, [], nil)
        let display = Display(surface)
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let openChrome = DeviceChrome.load(for: device, displayMode: .innerFullyOpen)
        let model = try XCTUnwrap(DuoModelView(screen: screen, chrome: openChrome))
        model.frame = CGRect(x: 0, y: 0, width: 640, height: 640)
        for mode in DeviceDisplayMode.allCases {
            let chrome = DeviceChrome.load(for: device, displayMode: mode)
            model.updateDisplay(display, engine: screen.renderer.engine, chrome: chrome)
            for turn in 0..<4 {
                screen.quarterTurns = turn
                model.setHingeAngle(mode == .cover ? 0 : mode == .innerPartiallyOpen ? 120 : 180,
                    chrome: chrome, screen: screen)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(model.snapshot().tiffRepresentation)))
                var samples = 0
                for y in stride(from: 80, to: bitmap.pixelsHigh - 80, by: 65) {
                    for x in stride(from: 80, to: bitmap.pixelsWide - 80, by: 65) {
                        // snapshot's bitmap already holds sRGB channel values.
                        // colorAt creates an NSCalibratedRGBColor; converting it
                        // again would reinterpret the encoded test coordinates.
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                        guard color.alphaComponent > 0.99, color.blueComponent > 0.99,
                              color.redComponent < 0.95, color.greenComponent < 0.95 else { continue }
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(bitmap.pixelsWide) * model.bounds.width,
                            y: (1 - (CGFloat(y) + 0.5) / CGFloat(bitmap.pixelsHigh)) * model.bounds.height)
                        let context = "mode=\(mode), turn=\(turn), pixel=(\(x),\(y))"
                        guard let touch = model.normalizedScreenPoint(at: point, clamped: false) else {
                            XCTFail("No hit on a visible screen pixel: \(context)"); continue
                        }
                        XCTAssertEqual(touch.x, color.redComponent, accuracy: 0.015, context)
                        XCTAssertEqual(touch.y, color.greenComponent, accuracy: 0.015, context)
                        samples += 1
                    }
                }
                XCTAssertGreaterThan(samples, 10, "Must sample both halves of each pose, mode=\(mode), turn=\(turn)")
                XCTAssertNil(model.normalizedScreenPoint(at: .zero, clamped: false))
                for outside in [CGPoint(x: -100, y: 320), CGPoint(x: 740, y: 320),
                                CGPoint(x: 320, y: -100), CGPoint(x: 320, y: 740), .zero] {
                    let touch = try XCTUnwrap(model.normalizedScreenPoint(at: outside, clamped: true),
                        "Dragging outside must clamp to the mesh: mode=\(mode), turn=\(turn)")
                    XCTAssertTrue((0...1).contains(touch.x) && (0...1).contains(touch.y))
                    let projected = try XCTUnwrap(model.projectedScreenPoint(touch))
                    let roundtrip = try XCTUnwrap(model.normalizedScreenPoint(at: projected, clamped: true))
                    XCTAssertEqual(roundtrip.x, touch.x, accuracy: 0.001)
                    XCTAssertEqual(roundtrip.y, touch.y, accuracy: 0.001)
                }
            }
        }
    }

#if DEBUG
    @MainActor func testOptionDragUsesNativeCoordinatesAndVisibleOverlay() throws {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The selected Xcode does not include the Duo model")
        }
        let device = SimulatorDevice(udid: "duo-option-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let surface = try XCTUnwrap(IOSurfaceCreate([kIOSurfaceWidth: 256, kIOSurfaceHeight: 256,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 1024] as CFDictionary))
        for mode in DeviceDisplayMode.allCases { for turn in 0..<4 {
            let screen = SimulatorScreenView(renderer: try ScreenRenderer())
            screen.quarterTurns = turn
            let chrome = DeviceChrome.load(for: device, displayMode: mode)
            let root = DevicePresentationView(screen: screen, chrome: chrome, device: device) { _ in }
            root.frame = CGRect(x: 0, y: 0, width: 800, height: 640)
            screen.setDisplay(Display(surface), chrome: chrome)
            root.layoutSubtreeIfNeeded()
            _ = root.canvas.duoSnapshot()
            XCTAssertTrue(screen.gestureOverlay.superview === screen.superview)
            XCTAssertFalse(screen.gestureOverlay.isHiddenOrHasHiddenAncestor)
            XCTAssertNil(screen.gestureOverlay.hitTest(.zero))
            for (index, point) in [CGPoint(x: 0.3, y: 0.35), CGPoint(x: 0.2, y: 0.25)].enumerated() {
                let local = try XCTUnwrap(screen.coordinateProjector?(point))
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: index == 0 ? .leftMouseDown : .leftMouseDragged,
                    location: screen.convert(local, to: nil), modifierFlags: .option, timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: index, clickCount: 1, pressure: 1))
                if index == 0 { screen.mouseDown(with: event) } else { screen.mouseDragged(with: event) }
                XCTAssertEqual(screen.diagnosticContacts.count, 2)
                let first = try XCTUnwrap(screen.diagnosticContacts.first)
                let second = try XCTUnwrap(screen.diagnosticContacts.last)
                XCTAssertEqual(first.x, point.x, accuracy: 0.001)
                XCTAssertEqual(first.y, point.y, accuracy: 0.001)
                XCTAssertEqual(second.x, 1 - point.x, accuracy: 0.001)
                XCTAssertEqual(second.y, 1 - point.y, accuracy: 0.001)
                let marker = try XCTUnwrap(screen.gestureOverlay.layer?.sublayers?.first as? CAShapeLayer)
                XCTAssertFalse(marker.isHidden)
                let markerBounds = try XCTUnwrap(marker.path).boundingBox
                XCTAssertEqual(markerBounds.midX, local.x, accuracy: 0.1)
                XCTAssertEqual(markerBounds.midY, local.y, accuracy: 0.1)
                if index == 1 { screen.mouseUp(with: event) }
            }
            XCTAssertTrue(screen.diagnosticContacts.isEmpty)
        } }
    }

    @MainActor func testRenderedDuoScreenReceivesMouseEventsInEveryPoseAndRotation() throws {
        let device = SimulatorDevice(udid: "duo-input-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The selected Xcode does not include the Duo model")
        }
        for mode in DeviceDisplayMode.allCases {
            for turn in 0..<4 {
                let screen = SimulatorScreenView(renderer: try ScreenRenderer())
                screen.quarterTurns = turn
                let root = DevicePresentationView(screen: screen,
                    chrome: DeviceChrome.load(for: device, displayMode: mode), device: device) { _ in }
                root.frame = CGRect(x: 0, y: 0, width: 800, height: 640)
                root.layoutSubtreeIfNeeded()
                _ = root.canvas.duoSnapshot()
                // Avoid the exact hinge seam, which is not screen geometry.
                let point = CGPoint(x: screen.bounds.width * 0.6, y: screen.bounds.height * 0.4)
                let hit = root.hitTest(root.convert(point, from: screen))
                XCTAssertTrue(hit === screen,
                    "Duo must deliver mouseDown/drag/up to the touchscreen, not \(String(describing: hit)); mode=\(mode), turn=\(turn)")
                guard let mapped = screen.coordinateMapper?(point, false) else {
                    XCTFail("Missing screen hit: mode=\(mode), turn=\(turn)")
                    continue
                }
                XCTAssertTrue((0...1).contains(mapped.x))
                XCTAssertTrue((0...1).contains(mapped.y))
            }
        }
    }
#endif
}
