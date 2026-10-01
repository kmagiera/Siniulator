import AppKit
import XCTest
@testable import Siniulator

final class DuoWindowGeometryTests: XCTestCase {
#if DEBUG
    @MainActor func testPinchRetargetsTheExactPhaseWithoutAnAngleRoundTrip() throws {
        _ = NSApplication.shared
        let id = "duo-pinch-phase-\(UUID().uuidString)"
        let device = SimulatorDevice(udid: id, name: "iPhone Duo", state: "Shutdown", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard !DeviceChrome.displayModes(for: device).isEmpty else { throw XCTSkip("Duo profile not installed") }
        let controller = try DeviceWindowController(device: device, store: DeviceStore(),
            capturePreviews: CapturePreviewPresenter())
        defer {
            controller.window?.close()
            for prefix in ["display-mode-", "hinge-angle-"] { UserDefaults.standard.removeObject(forKey: prefix + id) }
        }
        controller.perform(.innerFullyOpen)
        controller.diagnosticMagnify(0, phase: .began)
        var progress = 1.0
        for delta in [-0.173, -0.21, 0.023, 0.137, 0.089] {
            progress = min(1, max(0, progress + delta * 2))
            controller.diagnosticMagnify(delta, phase: .changed)
            XCTAssertEqual(controller.diagnosticTargetHingeAngle, DuoPose.angle(at: DuoPose.pinchPhase(progress)))
        }
        controller.diagnosticMagnify(0, phase: .ended)
    }
#endif
    @MainActor func testDuoIgnoresSavedBezelFreeModeAndRejectsBezelToggle() throws {
        _ = NSApplication.shared
        let id = "duo-bezel-policy-\(UUID().uuidString)"
        let key = "show-bezels-\(id)"
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let device = SimulatorDevice(udid: id, name: "iPhone Duo", state: "Shutdown", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard !DeviceChrome.displayModes(for: device).isEmpty else { throw XCTSkip("Duo profile not installed") }
        let controller = try DeviceWindowController(device: device, store: DeviceStore(),
            capturePreviews: CapturePreviewPresenter())
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let frame = window.frame
        XCTAssertTrue(controller.showsBezels)
        XCTAssertFalse(controller.canHideBezels)
        for _ in 0..<3 { controller.perform(.showBezels) }
        XCTAssertTrue(controller.showsBezels)
        XCTAssertEqual(window.frame, frame)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key), "An unavailable command must not mutate preferences")
    }

#if DEBUG
    @MainActor func testCroppingAndRepeatedLayoutUpdateTheCameraOnlyOncePerPose() throws {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else { throw XCTSkip("Duo model not installed") }
        _ = NSApplication.shared
        let device = SimulatorDevice(udid: "duo-camera-layout", name: "iPhone Duo", state: "Shutdown", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let controller = try DeviceWindowController(device: device, store: DeviceStore(),
            capturePreviews: CapturePreviewPresenter())
        defer { controller.window?.close() }
        let root = controller.presentation!
        root.layoutSubtreeIfNeeded()
        for step in 0...120 {
            let before = root.canvas.duoCameraUpdateCount
            controller.diagnosticRenderPose(angle: Double(step) * 1.5, quarterTurns: Double(step) / 120)
            XCTAssertEqual(root.canvas.duoCameraUpdateCount, before + 1,
                "The native crop must not reconfigure SceneKit after rendering its pose")
            let updated = root.canvas.duoCameraUpdateCount
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            root.controls.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.canvas.duoCameraUpdateCount, updated, "Unchanged layout is not a new camera sample")
        }
    }

    @MainActor func testRepeatedRollsDoNotAccumulateWindowCenterDrift() throws {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("Duo DeviceKit model not installed")
        }
        _ = NSApplication.shared
        let device = SimulatorDevice(udid: "duo-window-center", name: "iPhone Duo", state: "Shutdown",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let controller = try DeviceWindowController(device: device, store: DeviceStore(),
            capturePreviews: CapturePreviewPresenter())
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let visible = try XCTUnwrap(window.screen?.visibleFrame)
        controller.presentation.duoViewportSide = min(visible.width - 32, visible.height - 108) * 0.95
            / controller.presentation.canvas.duoMaximumProjectedSpan
        controller.diagnosticRenderPose(angle: 180, quarterTurns: 0)
        window.setFrame(CGRect(x: visible.midX - window.frame.width / 2,
            y: visible.maxY - window.frame.height - 20,
            width: window.frame.width, height: window.frame.height), display: false)
        let center = window.frame.midX, top = window.frame.maxY
        var maximumDrift: CGFloat = 0
        for step in 0...480 {
            controller.diagnosticRenderPose(angle: 180, quarterTurns: Double(step) / 60)
            maximumDrift = max(maximumDrift, abs(window.frame.midX - center))
            XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        }
        print("Repeated roll maximum native window center drift: \(maximumDrift) pt")
        XCTAssertLessThanOrEqual(maximumDrift, 0.5)

        controller.diagnosticRenderPose(angle: 180, quarterTurns: 0)
        window.setFrameOrigin(CGPoint(x: visible.maxX - window.frame.width - 1, y: window.frame.minY))
        let edgeCenter = window.frame.midX
        var edgeDrift: CGFloat = 0
        for step in 0...120 {
            controller.diagnosticRenderPose(angle: 180, quarterTurns: Double(step) / 120)
            edgeDrift = max(edgeDrift, abs(window.frame.midX - edgeCenter))
        }
        print("Right-edge roll maximum native window center drift: \(edgeDrift) pt")
        XCTAssertLessThanOrEqual(edgeDrift, 0.5, "A changing crop must not relocate the toolbar near a display edge")

        window.setFrameOrigin(CGPoint(x: window.frame.minX - 100, y: window.frame.minY - 30))
        let movedCenter = window.frame.midX, movedTop = window.frame.maxY
        for step in 0...60 {
            controller.diagnosticRenderPose(angle: 180, quarterTurns: 1 + Double(step) / 60)
            XCTAssertEqual(window.frame.midX, movedCenter, accuracy: 0.5, "Dragging the toolbar must update its anchor")
            XCTAssertEqual(window.frame.maxY, movedTop, accuracy: 0.5)
        }
    }
#endif
}
