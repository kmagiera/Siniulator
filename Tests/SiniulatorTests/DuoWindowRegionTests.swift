import AppKit
import XCTest
@testable import Siniulator

#if DEBUG
final class DuoWindowRegionTests: XCTestCase {
    @MainActor private func makeWindow() throws -> (DeviceHostWindow, DevicePresentationView, SimulatorScreenView, SimulatorDevice) {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The selected Xcode does not include the Duo model")
        }
        _ = NSApplication.shared
        let device = SimulatorDevice(udid: "duo-mouse-region", name: "iPhone Duo", state: "Booted", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let root = DevicePresentationView(screen: screen, chrome: DeviceChrome.load(for: device), device: device) { _ in }
        let window = DeviceHostWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.contentView = root
        return (window, root, screen, device)
    }

    @MainActor func testTransparentMarginsPassThroughButToolbarAndScreenStayInteractive() throws {
        let (window, root, screen, device) = try makeWindow()
        defer { window.close() }
        for mode in DeviceDisplayMode.allCases { for turn in 0..<4 {
            screen.quarterTurns = turn
            root.canvas.setChrome(DeviceChrome.load(for: device, displayMode: mode))
            root.canvas.setHingeAngle(CGFloat(mode.hingeAngle))
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            let snapshot = try XCTUnwrap(root.canvas.duoSnapshot())
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(snapshot.tiffRepresentation)))
            let context = "mode=\(mode), turn=\(turn)"
            func check(_ point: CGPoint, accepts: Bool) {
                XCTAssertEqual(root.acceptsMouse(at: point), accepts, context)
                let position = window.convertPoint(toScreen: root.convert(point, to: nil))
                window.updateMousePassthrough(at: position, buttonsPressed: false)
                XCTAssertEqual(window.ignoresMouseEvents, !accepts, context)
            }
            check(CGPoint(x: 1, y: root.bounds.midY), accepts: false)
            check(CGPoint(x: root.bounds.maxX - 1, y: root.bounds.midY), accepts: false)
            check(CGPoint(x: root.bounds.midX, y: root.bounds.maxY - 1), accepts: false)
            check(CGPoint(x: root.controls.frame.midX, y: root.controls.frame.midY), accepts: true)
            let screenPoint = try XCTUnwrap(screen.coordinateProjector?(CGPoint(x: 0.3, y: 0.4)))
            check(root.convert(screenPoint, from: screen), accepts: true)
            // Compare hit ownership to rendered alpha, not just to a second
            // copy of the same geometry formula. Clear pixels beyond the mesh
            // must not block another app, except the explicit resize handles.
            for y in stride(from: 30, to: bitmap.pixelsHigh - 30, by: 71) {
                for x in stride(from: 30, to: bitmap.pixelsWide - 30, by: 71) {
                    let alpha = try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
                    let point = root.convert(CGPoint(x: CGFloat(x) / CGFloat(bitmap.pixelsWide) * screen.bounds.width,
                        y: CGFloat(y) / CGFloat(bitmap.pixelsHigh) * screen.bounds.height), from: screen)
                    if alpha == 0 && root.resizeCorner(at: point) == nil && !root.controls.frame.contains(point) {
                        XCTAssertFalse(root.acceptsMouse(at: point), "Clear pixel captured the pointer: \(context), \(point)")
                    }
                }
            }
        } }
    }

    @MainActor func testPointerOwnershipIsRetainedUntilReleaseAndFullscreenResetsPassthrough() throws {
        let (window, root, _, _) = try makeWindow()
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        _ = root.canvas.duoSnapshot()
        let inside = window.convertPoint(toScreen: root.convert(CGPoint(x: root.controls.frame.midX, y: 20), to: nil))
        let outside = CGPoint(x: window.frame.minX + 1, y: window.frame.midY)
        window.updateMousePassthrough(at: inside, buttonsPressed: false)
        XCTAssertFalse(window.ignoresMouseEvents)
        window.updateMousePassthrough(at: outside, buttonsPressed: true)
        XCTAssertFalse(window.ignoresMouseEvents, "A simulator drag must retain its mouse-up")
        window.updateMousePassthrough(at: outside, buttonsPressed: false)
        XCTAssertTrue(window.ignoresMouseEvents)
        window.updateMousePassthrough(at: inside, buttonsPressed: true)
        XCTAssertTrue(window.ignoresMouseEvents, "Do not steal a drag from the app behind")
        window.updateMousePassthrough(at: inside, buttonsPressed: false)
        XCTAssertFalse(window.ignoresMouseEvents)
        root.isFullScreen = true
        window.ignoresMouseEvents = true
        root.layoutSubtreeIfNeeded()
        window.updateMousePassthrough(at: outside, buttonsPressed: false)
        XCTAssertFalse(window.ignoresMouseEvents, "Fullscreen owns its whole rectangle")
        root.isFullScreen = false
        root.layoutSubtreeIfNeeded()
        window.updateMousePassthrough(at: outside, buttonsPressed: false)
        XCTAssertTrue(window.ignoresMouseEvents, "Returning to desktop restores mesh-based ownership")
    }

    @MainActor func testCornerResizeFollowsHardwareInEveryPoseAndRotation() throws {
        let (window, root, screen, device) = try makeWindow()
        defer { window.close() }
        for mode in DeviceDisplayMode.allCases { for turn in 0..<4 {
            screen.quarterTurns = turn
            root.canvas.setChrome(DeviceChrome.load(for: device, displayMode: mode))
            root.canvas.setHingeAngle(CGFloat(mode.hingeAngle))
            for corner in DeviceResizeCorner.allCases {
                root.canvas.maximumScale = nil
                window.setFrame(CGRect(x: 100, y: 100, width: 800, height: 640), display: false)
                root.refreshGeometry()
                root.layoutSubtreeIfNeeded()
                let beforeFirstDraw = root.resizeTarget(for: corner)
                _ = root.canvas.duoSnapshot()
                let target = root.resizeTarget(for: corner)
                XCTAssertEqual(target, beforeFirstDraw, "A rendered frame must not relocate or enable a corner target")
                XCTAssertEqual(target.size, CGSize(width: 44, height: 44))
                XCTAssertEqual(root.resizeCorner(at: CGPoint(x: target.midX, y: target.midY)), corner)
                XCTAssertEqual(root.pointerRegion(at: CGPoint(x: target.midX, y: target.midY)), .resize(corner))
                XCTAssertTrue(root.acceptsMouse(at: CGPoint(x: target.midX, y: target.midY)))
                let center = root.visualDeviceRect
                let dx = target.midX - center.midX, dy = target.midY - center.midY, length = hypot(dx, dy)
                let exterior = CGPoint(x: target.midX + dx / length * 3, y: target.midY + dy / length * 3)
                XCTAssertEqual(root.resizeCorner(at: exterior), corner, "A small exterior edge tolerance should remain usable")
                let interior = CGPoint(x: target.midX - dx / length * 14, y: target.midY - dy / length * 14)
                XCTAssertNil(root.resizeCorner(at: interior), "The broad corner square is not the actual resize region")
                XCTAssertFalse(window.isCornerResizing)
            }
        } }
    }

    @MainActor func testScreenCornersNeverResizeAcrossScalesAndOrientations() throws {
        let (window, root, screen, device) = try makeWindow()
        defer { window.close() }
        for side in [CGFloat(350), 700, 1200] { for turn in 0..<4 {
            screen.quarterTurns = turn
            root.duoViewportSide = side
            for angle in [CGFloat(0), 40, 110, 120, 180] {
                root.canvas.setChrome(DeviceChrome.load(for: device, displayMode: DeviceDisplayMode.mode(forHingeAngle: Double(angle))))
                root.canvas.setHingeAngle(angle)
                root.refreshGeometry()
                root.layoutSubtreeIfNeeded()
                root.setFrameSize(root.duoWindowSize)
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
                for uv in [CGPoint(x: 0.01, y: 0.01), CGPoint(x: 0.99, y: 0.01),
                    CGPoint(x: 0.01, y: 0.99), CGPoint(x: 0.99, y: 0.99), CGPoint(x: 0.5, y: 0.5)] {
                    let screenPoint = try XCTUnwrap(screen.coordinateProjector?(uv))
                    let point = root.convert(screenPoint, from: screen)
                    XCTAssertNil(root.resizeCorner(at: point), "Touch intercepted at angle=\(angle), turn=\(turn), scale=\(side), uv=\(uv)")
                    // The projector snaps rounded-off UV corners to the real
                    // screen edge. Strict ray hits can miss that exact boundary;
                    // the nearby interior must still accept normal input.
                    let interiorUV = CGPoint(x: uv.x < 0.5 ? 0.05 : 0.95, y: uv.y < 0.5 ? 0.05 : 0.95)
                    let interior = try XCTUnwrap(screen.coordinateProjector?(interiorUV))
                    XCTAssertNotNil(screen.coordinateMapper?(interior, false), "Touchscreen interior: angle=\(angle), turn=\(turn), scale=\(side), uv=\(interiorUV)")
                    XCTAssertTrue(root.acceptsMouse(at: root.convert(interior, from: screen)))
                }
            }
        } }
    }

    @MainActor func testEnteringFrameDirectlyFromIgnoredMarginImmediatelyUpdatesCursorAndRetainsDragOwner() throws {
        let (window, root, _, _) = try makeWindow()
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let number = window.windowNumber
        window.pointerWindowAt = { _ in number }
        var cursors: [DeviceResizeCorner?] = []
        window.applyHoverCursor = { cursors.append($0) }
        func sample(_ point: CGPoint, pressed: Bool = false) {
            window.updateMousePassthrough(at: window.convertPoint(toScreen: root.convert(point, to: nil)), buttonsPressed: pressed)
        }
        let clear = CGPoint(x: 1, y: root.bounds.midY)
        for corner in DeviceResizeCorner.allCases {
            sample(clear)
            XCTAssertTrue(window.ignoresMouseEvents)
            let target = root.resizeTarget(for: corner), edge = CGPoint(x: target.midX, y: target.midY)
            sample(edge) // No intermediate move through the touchscreen; no cursor-entry event.
            XCTAssertFalse(window.ignoresMouseEvents)
            XCTAssertEqual(window.hoveredResizeCorner, corner)
            XCTAssertEqual(cursors.last!, corner)
            sample(clear, pressed: true)
            XCTAssertFalse(window.ignoresMouseEvents, "Never yield an in-flight drag")
            sample(clear)
            XCTAssertTrue(window.ignoresMouseEvents)
            XCTAssertNil(window.hoveredResizeCorner)
        }
        sample(CGPoint(x: -20, y: root.bounds.midY))
        XCTAssertFalse(window.ignoresMouseEvents, "Keep the window discoverable before the pointer enters its bounds")
        let target = root.resizeTarget(for: .bottomRight)
        sample(CGPoint(x: target.midX, y: target.midY))
        XCTAssertEqual(cursors.last!, .bottomRight)
        sample(CGPoint(x: root.visualDeviceRect.midX, y: root.visualDeviceRect.midY))
        XCTAssertNil(cursors.last!, "The touchscreen must show the normal cursor immediately")
        let count = cursors.count
        window.pointerWindowAt = { _ in -1 }
        sample(CGPoint(x: target.midX, y: target.midY))
        XCTAssertEqual(cursors.count, count, "A covered/off-space window must not change another app's cursor")
    }

    @MainActor func testOnlyHardwareCornersResizeNormalDuoButFullscreenRemainsAvailable() throws {
        let (window, root, _, _) = try makeWindow()
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.styleMask.contains(.resizable), "Native edge/corner cursors must not exist on the transparent window frame")
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAllowsTiling))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, true,
            "Removing edge resizing must not disable the native fullscreen button")
        let hardware = root.visualDeviceRect
        for point in [CGPoint(x: hardware.midX, y: hardware.minY),
            CGPoint(x: hardware.midX, y: hardware.maxY),
            CGPoint(x: hardware.minX, y: hardware.midY),
            CGPoint(x: hardware.maxX, y: hardware.midY),
            CGPoint(x: 1, y: root.bounds.midY), CGPoint(x: root.bounds.maxX - 1, y: root.bounds.midY)] {
            XCTAssertNil(root.resizeCorner(at: point), "Neither a hardware edge nor a window edge is a resize handle")
        }
        root.isFullScreen = true
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.styleMask.contains(.resizable))
        root.isFullScreen = false
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.styleMask.contains(.resizable))
        root.canvas.showsBezels = false
        root.refreshGeometry()
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(root.canvas.showsBezels, "Duo cannot switch to a flat bezel-free presentation")
        XCTAssertTrue(root.canvas.usesDuoModel)
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    @MainActor func testMouseEventsResizeEveryHardwareCornerAndReleaseTheSession() throws {
        let (window, root, screen, device) = try makeWindow()
        defer { window.close() }
        let visible = try XCTUnwrap(window.screen?.visibleFrame)
        var resizeCallbacks = 0
        window.onManualResize = { resizeCallbacks += 1 }
        func send(_ type: NSEvent.EventType, at pointer: CGPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: window.convertPoint(fromScreen: pointer), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            event.cgEvent?.location = CGPoint(x: pointer.x,
                y: try XCTUnwrap(NSScreen.screens.first).frame.maxY - pointer.y)
            window.sendEvent(event)
        }
        for mode in DeviceDisplayMode.allCases { for turn in 0..<4 { for corner in DeviceResizeCorner.allCases {
            screen.quarterTurns = turn
            root.duoViewportSide = 450
            root.canvas.setChrome(DeviceChrome.load(for: device, displayMode: mode))
            root.canvas.setHingeAngle(CGFloat(mode.hingeAngle))
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            let size = root.duoWindowSize
            window.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                width: ceil(size.width / 2) * 2, height: ceil(size.height)), display: false)
            root.layoutSubtreeIfNeeded()
            let target = root.resizeTarget(for: corner)
            let pointer = window.convertPoint(toScreen: root.convert(CGPoint(x: target.midX, y: target.midY), to: nil))
            let initialFrame = window.frame
            let expectedSession = DuoResizeSession(corner: corner, initialFrame: initialFrame,
                initialDevice: window.convertToScreen(root.convert(root.visualDeviceRect, to: nil)),
                initialPointer: pointer, initialViewport: root.duoViewportSide,
                headerHeight: root.controls.frame.height, visibleFrame: visible,
                toolbarSizing: root.duoToolbarSizing, maximumSpan: root.canvas.duoMaximumProjectedSpan)
            try send(.leftMouseDown, at: pointer)
            XCTAssertTrue(window.isCornerResizing, "mode=\(mode), turn=\(turn), corner=\(corner)")
            let dragged = CGPoint(x: pointer.x + (corner.isLeft ? -18 : 18),
                y: pointer.y + (corner.isTop ? 18 : -18))
            let expected = expectedSession.geometry(at: dragged)
            let callbacksBefore = resizeCallbacks
            try send(.leftMouseDragged, at: dragged)
            XCTAssertEqual(resizeCallbacks, callbacksBefore + 1)
            XCTAssertGreaterThan(root.duoViewportSide, 450)
            XCTAssertEqual(root.duoViewportSide, expected.viewport, accuracy: 0.001)
            XCTAssertEqual(window.frame.minX, expected.frame.minX, accuracy: 1)
            XCTAssertEqual(window.frame.minY, expected.frame.minY, accuracy: 1)
            XCTAssertEqual(window.frame.width, expected.frame.width, accuracy: 1)
            XCTAssertEqual(window.frame.height, expected.frame.height, accuracy: 1)
            XCTAssertEqual(root.canvas.bounds.width, root.duoViewportSide, accuracy: 0.001)
            XCTAssertEqual(root.visualDeviceRect.minY - root.controls.frame.maxY, DuoStage.toolbarGap, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(root.bounds.maxY - root.visualDeviceRect.maxY, DuoStage.outerMargin - 1)
            try send(.leftMouseUp, at: dragged)
            XCTAssertFalse(window.isCornerResizing)
            XCTAssertTrue(window.areCursorRectsEnabled)
        } } }
    }
}
#endif
