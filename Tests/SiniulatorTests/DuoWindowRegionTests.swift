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
        window.contentView = root
        return (window, root, screen, device)
    }

    @MainActor func testTransparentMarginsPassThroughButToolbarScreenAndResizeTargetsStayInteractive() throws {
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
            for corner in DeviceResizeCorner.allCases {
                let target = root.resizeTarget(for: corner)
                XCTAssertFalse(target.isEmpty, context)
                check(CGPoint(x: target.midX, y: target.midY), accepts: true)
                // Include the transparent portion of each resize handle.
                check(CGPoint(x: target.minX + 1, y: target.minY + 1), accepts: true)
            }
            // Compare hit ownership to rendered alpha, not just to a second
            // copy of the same geometry formula. Clear pixels beyond the mesh
            // must not block another app, except for the small resize handles.
            for y in stride(from: 30, to: bitmap.pixelsHigh - 30, by: 71) {
                for x in stride(from: 30, to: bitmap.pixelsWide - 30, by: 71) {
                    let alpha = try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
                    let point = root.convert(CGPoint(x: CGFloat(x) / CGFloat(bitmap.pixelsWide) * screen.bounds.width,
                        y: CGFloat(y) / CGFloat(bitmap.pixelsHigh) * screen.bounds.height), from: screen)
                    if alpha == 0 && root.resizeCorner(at: point) == nil {
                        XCTAssertFalse(root.acceptsMouse(at: point), "Clear pixel captured the pointer: \(context), \(point)")
                    }
                }
            }
        } }
    }

    @MainActor func testPointerOwnershipIsRetainedUntilReleaseAndOpaqueModesResetPassthrough() throws {
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
        for fullscreen in [true, false] {
            root.isFullScreen = fullscreen
            root.canvas.showsBezels = fullscreen
            window.ignoresMouseEvents = true
            root.layoutSubtreeIfNeeded()
            window.updateMousePassthrough(at: outside, buttonsPressed: false)
            XCTAssertFalse(window.ignoresMouseEvents, "Fullscreen and bezel-free windows own their whole rectangle")
        }
    }

    @MainActor func testWindowResizesFromEveryVisibleCornerInEveryPoseAndRotation() throws {
        let (window, root, screen, device) = try makeWindow()
        defer { window.close() }
        let primary = try XCTUnwrap(NSScreen.screens.first)
        // Deliver events directly to the test window; never post OS input.
        func event(_ type: CGEventType, at point: CGPoint) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: point.x, y: primary.frame.maxY - point.y), mouseButton: .left))
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        for mode in DeviceDisplayMode.allCases { for turn in 0..<4 {
            screen.quarterTurns = turn
            root.canvas.setChrome(DeviceChrome.load(for: device, displayMode: mode))
            root.canvas.setHingeAngle(CGFloat(mode.hingeAngle))
            for corner in DeviceResizeCorner.allCases {
                root.canvas.maximumScale = nil
                window.setFrame(CGRect(x: 100, y: 100, width: 800, height: 640), display: false)
                root.refreshGeometry()
                root.layoutSubtreeIfNeeded()
                _ = root.canvas.duoSnapshot()
                let target = root.resizeTarget(for: corner)
                let pointer = window.convertPoint(toScreen: root.convert(CGPoint(x: target.midX, y: target.midY), to: nil))
                let initial = window.frame
                window.updateMousePassthrough(at: pointer, buttonsPressed: false)
                XCTAssertFalse(window.ignoresMouseEvents)
                window.sendEvent(try event(.leftMouseDown, at: pointer))
                guard window.isCornerResizing else {
                    XCTFail("Resize did not begin: \(mode), turn=\(turn), corner=\(corner)")
                    continue
                }
                let moved = CGPoint(x: pointer.x + (corner.isLeft ? 35 : -35),
                    y: pointer.y + (corner.isTop ? -35 : 35))
                window.sendEvent(try event(.leftMouseDragged, at: moved))
                XCTAssertLessThan(window.frame.height, initial.height)
                XCTAssertLessThan(window.frame.width, initial.width)
                window.sendEvent(try event(.leftMouseUp, at: moved))
                XCTAssertFalse(window.isCornerResizing)
            }
        } }
    }
}
#endif
