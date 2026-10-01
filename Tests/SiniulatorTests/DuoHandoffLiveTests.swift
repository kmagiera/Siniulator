import AppKit
import CoreImage
import IOSurface
import XCTest
@testable import Siniulator

/// iOS can cancel a partially completed swap after a pause. Check its actual
/// active panel after dwelling: inactive IOSurfaces stay allocated but black.
#if DEBUG
final class DuoHandoffLiveTests: XCTestCase {
    /// Calibration only: allows targets inside the normally skipped camera
    /// turn, then reads the native panel after its delayed transition settles.
    @MainActor func testCalibrateHeldInnerLimit() async throws {
        guard let id = ProcessInfo.processInfo.environment["DUO_CALIBRATE_UDID"] else {
            throw XCTSkip("Set DUO_CALIBRATE_UDID to measure the native handoff limit")
        }
        let candidates = ProcessInfo.processInfo.environment["DUO_CALIBRATE_ANGLES"]?
            .split(separator: ",").compactMap { Double($0) } ?? [115, 110, 105, 100, 95]
        let store = DeviceStore()
        await store.refresh()
        let device = try XCTUnwrap(store.devices.first { $0.id == id && $0.isBooted })
        let controller = try DeviceWindowController(device: device, store: store, capturePreviews: CapturePreviewPresenter())
        defer { controller.window?.close() }
        controller.window?.orderBack(nil)
        controller.presentation.layoutSubtreeIfNeeded()
        let deadline = CACurrentMediaTime() + 45
        while !controller.isConnected, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.isConnected)
        func hold(_ angle: Double, label: String) async throws {
            controller.diagnosticAnimateHinge(to: angle)
            let deadline = CACurrentMediaTime() + 10
            while controller.diagnosticHingeAnimationInProgress, CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(controller.diagnosticHingeAnimationInProgress)
            XCTAssertEqual(controller.diagnosticHingeAngle, angle, accuracy: 0.001)
            try await Task.sleep(for: .seconds(3))
            let data = try await CommandRunner.run("/usr/bin/xcrun", ["devicectl", "device", "info", "displays",
                "--device", id, "--quiet", "--json-output", "-"])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            let displays = try XCTUnwrap(result["displays"] as? [[String: Any]])
            let active = displays.filter { $0["active"] as? Bool == true }.compactMap { $0["displayId"] as? Int }
            // Deliberately report rather than assert which panel: this probe
            // finds failing candidates; the regression below asserts the fix.
            let line = "CALIBRATION \(label) angle=\(angle) active=\(active)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        try await hold(180, label: "initial-open")
        for angle in candidates { try await hold(angle, label: "slow-close") }
        for candidate in candidates {
            try await hold(0, label: "reset-\(candidate)")
            for angle in [15.0, 30, 40] { try await hold(angle, label: "cover-approach-\(candidate)") }
            for cycle in 1...2 {
                try await hold(candidate, label: "open-\(cycle)")
                try await hold(40, label: "reverse-\(cycle)")
            }
        }
    }

    @MainActor func testHeldPinchTargetsKeepTheVisiblePanelActive() async throws {
        guard let id = ProcessInfo.processInfo.environment["DUO_HANDOFF_UDID"] else {
            throw XCTSkip("Set DUO_HANDOFF_UDID for live Duo panel-handoff verification")
        }
        let store = DeviceStore()
        await store.refresh()
        let device = try XCTUnwrap(store.devices.first { $0.id == id && $0.isBooted })
        let controller = try DeviceWindowController(device: device, store: store, capturePreviews: CapturePreviewPresenter())
        defer { controller.window?.close() }
        controller.window?.orderBack(nil)
        controller.presentation.layoutSubtreeIfNeeded()
        let deadline = CACurrentMediaTime() + 45
        while !controller.isConnected, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.isConnected)
        print("GUEST-SLOW-ANIMATIONS \(String(describing: controller.slowAnimationsEnabled))")
        let artifacts = ProcessInfo.processInfo.environment["DUO_HANDOFF_ARTIFACTS"].map { URL(fileURLWithPath: $0) }
        if let artifacts { try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true) }
        var index = 0
        controller.perform(.innerFullyOpen)
        func settle() async throws {
            let deadline = CACurrentMediaTime() + 10
            while controller.diagnosticHingeAnimationInProgress, CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(controller.diagnosticHingeAnimationInProgress)
        }
        try await settle()
        var previousProgress = 1.0
        // Dwell on both sides, approach each boundary in small increments,
        // then repeatedly reverse at the nearest legal pinch targets.
        let targets: [Double] = [1.0, 0.9, 0.7, 0.5, 0.3, 0.250001, 0.249999, 0.2, 0.1, 0,
                       0.1, 0.2, 0.249999, 0.250001, 0.249999, 0.250001, 0.3, 0.5, 1]
            + Array(repeating: [0.249999, 0.250001], count: 5).flatMap { $0 }
        var cases = targets.map { (progress: $0, orientation: Optional<DeviceCommand>.none) }
        for orientation in [DeviceCommand.landscapeRight, .portraitUpsideDown, .landscapeLeft, .portrait] {
            cases.append((0.249999, orientation))
            cases.append((0.250001, nil))
        }
        for (progress, orientation) in cases {
            if let orientation {
                controller.perform(orientation)
                try await settle()
            }
            let angle = DuoPose.angle(at: DuoPose.pinchPhase(progress))
            controller.diagnosticMagnify(0, phase: .began)
            controller.diagnosticMagnify((progress - previousProgress) / 2, phase: .changed)
            controller.diagnosticMagnify(0, phase: .ended)
            previousProgress = progress
            try await settle()
            XCTAssertEqual(controller.diagnosticHingeAngle, angle, accuracy: 0.001)
            // Observes iOS settling, including its delayed cancellation. This
            // checks resting states; it does not drive animation frames.
            try await Task.sleep(for: .seconds(3))
            let data = try await CommandRunner.run("/usr/bin/xcrun", ["devicectl", "device", "info", "displays",
                "--device", id, "--quiet", "--json-output", "-"])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            let displays = try XCTUnwrap(result["displays"] as? [[String: Any]])
            let active = displays.filter { $0["active"] as? Bool == true }.compactMap { $0["displayId"] as? Int }
            let expected = progress < 0.25 ? 1 : 3
            XCTAssertEqual(active, [expected], "Held pinch=\(progress), angle=\(angle): native panel differs from visible model")
            XCTAssertEqual(controller.diagnosticConnectedScreenID, UInt32(expected))
            let image = try XCTUnwrap(controller.presentation.canvas.duoSnapshot())
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            var lit = 0, opaque = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.alphaComponent > 0.9 {
                        opaque += 1
                        if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.2 { lit += 1 }
                    }
                }
            }
            let fraction = Double(lit) / Double(max(1, opaque))
            XCTAssertGreaterThan(fraction, 0.4, "Visible panel is black at held pinch=\(progress); run with the unlocked home screen")
            print("HELD-PINCH \(index) progress=\(progress) angle=\(angle) active=\(active) lit=\(fraction)")
            if let artifacts {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: artifacts.appendingPathComponent(String(format: "hold-%02d.png", index)))
                if let surface = controller.screen.display?.surface as? IOSurface {
                    let raw = CIImage(ioSurface: surface)
                    let cg = try XCTUnwrap(controller.screen.renderer.engine.images.createCGImage(raw, from: raw.extent))
                    try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                        .write(to: artifacts.appendingPathComponent(String(format: "native-%02d.png", index)))
                }
            }
            index += 1
        }
    }
}
#endif
