import AppKit
import XCTest
@testable import Siniulator

/// Opt-in integration test against a booted Duo. This does not replace an
/// on-screen recording: timing below measures display callbacks and CPU pose
/// updates, while exported frames come from the production SceneKit renderer.
#if DEBUG
final class DuoLiveTests: XCTestCase {
    @MainActor func testLivePanelsAndRetargetedMotion() async throws {
        guard let id = ProcessInfo.processInfo.environment["DUO_LIVE_UDID"],
              let path = ProcessInfo.processInfo.environment["DUO_LIVE_ARTIFACTS"] else {
            throw XCTSkip("Set DUO_LIVE_UDID and DUO_LIVE_ARTIFACTS for live CoreSimulator verification")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DeviceStore()
        await store.refresh()
        let device = try XCTUnwrap(store.devices.first { $0.id == id && $0.isBooted })
        let controller = try DeviceWindowController(device: device, store: store, capturePreviews: CapturePreviewPresenter())
        controller.diagnosticCollectMotion = true
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.orderBack(nil)
        controller.presentation.layoutSubtreeIfNeeded()
        // Polling only observes async native readiness; motion is exclusively
        // driven by the production display link, including in this test.
        func waitUntil(_ condition: () -> Bool, timeout: Double = 10) async throws {
            let deadline = CACurrentMediaTime() + timeout
            while !condition(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard condition() else { throw SimulatorError(message: "Timed out waiting for live Duo state; connected=\(controller.isConnected), angle=\(controller.diagnosticHingeAngle), motion=\(controller.diagnosticHingeAnimationInProgress)") }
        }
        try await waitUntil({ controller.isConnected }, timeout: 45)
        let frame = window.frame
        let toolbar = controller.presentation.controls.frame
        let viewport = controller.presentation.canvas.frame
        XCTAssertEqual(viewport.width, viewport.height)
        XCTAssertGreaterThan(viewport.width, 0)
        XCTAssertLessThanOrEqual(viewport.width * controller.presentation.canvas.duoMaximumProjectedSpan,
            (window.screen?.visibleFrame.height ?? 1000) - toolbar.height - DuoStage.toolbarGap - DuoStage.outerMargin)
        XCTAssertEqual(controller.presentation.visualDeviceRect.minY - toolbar.maxY, DuoStage.toolbarGap, accuracy: 0.001)
        controller.perform(.coverScreen)
        try await waitUntil({ !controller.diagnosticHingeAnimationInProgress && !controller.diagnosticDisplaySwitchInProgress })
        XCTAssertEqual(controller.diagnosticHingeAngle, 0, accuracy: 0.01)
        controller.perform(.innerFullyOpen)
        XCTAssertEqual(controller.presentation.controls.displayModeControl?.selectedSegment, 2)
        try await waitUntil({ !controller.diagnosticHingeAnimationInProgress && !controller.diagnosticDisplaySwitchInProgress })
        XCTAssertEqual(controller.diagnosticHingeAngle, 180, accuracy: 0.01)
        controller.perform(.coverScreen)
        XCTAssertEqual(controller.presentation.controls.displayModeControl?.selectedSegment, 0)
        try await waitUntil({ controller.diagnosticHingeAngle < 65 })
        controller.diagnosticMagnify(0, phase: .began)
        controller.diagnosticMagnify(0.5, phase: .changed)
        controller.diagnosticMagnify(0, phase: .ended)
        try await waitUntil({ !controller.diagnosticHingeAnimationInProgress })
        XCTAssertEqual(controller.diagnosticHingeAngle, 180, accuracy: 0.01)
        for command in [DeviceCommand.landscapeRight, .portraitUpsideDown, .landscapeLeft, .portrait] {
            controller.perform(command)
            try await waitUntil({ !controller.diagnosticHingeAnimationInProgress })
            XCTAssertEqual(window.frame.maxY, frame.maxY, accuracy: 0.001)
            XCTAssertEqual(controller.presentation.controls.frame.size, toolbar.size)
        }
        let samples = controller.diagnosticMotionFrames
        XCTAssertGreaterThan(samples.count, 240)
        for sample in samples {
            XCTAssertEqual(sample.frame.midX, frame.midX, accuracy: 0.5, "The toolbar must not drift while a fold/roll changes the crop")
            XCTAssertEqual(sample.frame.maxY, frame.maxY, accuracy: 0.001)
            XCTAssertEqual(sample.toolbar.width, toolbar.width)
            XCTAssertEqual(sample.hardware.minY - sample.toolbar.maxY, DuoStage.toolbarGap, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(sample.frame.height - sample.hardware.maxY, DuoStage.outerMargin - 0.001)
            XCTAssertLessThan(sample.frame.height - sample.hardware.maxY, DuoStage.outerMargin + 1.001)
            XCTAssertEqual(sample.viewport, viewport.width)
        }
        let costs = samples.map(\.cost).sorted()
        let intervals = zip(samples, samples.dropFirst()).map { $1.time - $0.time }.filter { $0 < 0.1 }.sorted()
        let report = """
        Live CoreSimulator Duo: \(id)
        Initial tightly fitted window: \(frame.size), fixed toolbar: \(toolbar.size)
        Display-link callbacks: \(samples.count)
        CPU pose update p95: \(costs[costs.count * 95 / 100] * 1000) ms
        Callback interval p95 (excluding idle gaps): \(intervals[intervals.count * 95 / 100] * 1000) ms
        Buttons, mid-turn reversal, 0.5 pinch range, 4 rotations: passed
        Frame export below is deterministic at 60 fps with real panel textures, not a wall-clock screen recording.
        """
        print(report)
        try report.write(to: directory.appendingPathComponent("live-test.txt"), atomically: true, encoding: .utf8)
        let csv = "timestamp,hinge,quarterTurns,cpuSeconds\n" + samples.map { "\($0.time),\($0.angle),\($0.turns),\($0.cost)" }.joined(separator: "\n")
        try csv.write(to: directory.appendingPathComponent("timings.csv"), atomically: true, encoding: .utf8)

        // Cache both genuine native panels before exporting the complete sweep.
        // No guest HID events are generated by these deterministic render frames.
        controller.perform(.coverScreen)
        try await waitUntil({ !controller.diagnosticHingeAnimationInProgress })
        controller.perform(.innerFullyOpen)
        try await waitUntil({ !controller.diagnosticHingeAnimationInProgress })
        var motion = DuoMotion(angle: 0, quarterTurns: 0)
        var index = 0
        for target in [1.0, 0.0] {
            motion.fold.target = target
            for _ in 0..<120 {
                motion.advance(seconds: 1 / 60)
                controller.presentation.canvas.setRenderedDuoPose(motion.renderedPose)
                let image = try XCTUnwrap(controller.presentation.canvas.duoSnapshot())
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(String(format: "frame-%04d.png", index)))
                index += 1
            }
        }
    }
}
#endif
