import AppKit
import SceneKit
import XCTest
@testable import Siniulator

final class DuoStageTests: XCTestCase {
    @MainActor func testFullscreenRestoresNativeResizeBeforeAppKitChangesContentSize() throws {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else { throw XCTSkip("Duo model not installed") }
        _ = NSApplication.shared
        let device = SimulatorDevice(udid: "duo-hosted-fullscreen", name: "iPhone Duo", state: "Booted", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let store = DeviceStore(fetchDevices: { [device] }, runSimctl: { _ in Data() })
        let controller = try DeviceWindowController(device: device, store: store, capturePreviews: CapturePreviewPresenter())
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let root = controller.presentation!
        root.layoutSubtreeIfNeeded()
        for size in [CGSize(width: 3008, height: 1692), CGSize(width: 1400, height: 900), CGSize(width: 628, height: 919)] {
            XCTAssertFalse(window.styleMask.contains(.resizable))
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
            XCTAssertTrue(window.styleMask.contains(.resizable), "The style mask must be restored before the system changes content size")
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.bounds.size, size)
            let available = FullScreenPresentationLayout(bounds: root.bounds, safeAreaInsets: root.fullScreenSafeAreaInsets).canvas
            XCTAssertEqual(root.canvas.frame.midX, available.midX)
            XCTAssertEqual(root.canvas.frame.midY, available.midY)
            XCTAssertTrue(root.bounds.contains(root.visualDeviceRect))
            controller.windowDidFailToEnterFullScreen(window)
            root.layoutSubtreeIfNeeded()
        }
    }

    @MainActor func testFullscreenUsesTheSameSquareProjectionAndRestoresDesktopScale() throws {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else { throw XCTSkip("Duo model not installed") }
        let device = SimulatorDevice(udid: "duo-fullscreen-square", name: "iPhone Duo", state: "Booted", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let root = DevicePresentationView(screen: screen, chrome: DeviceChrome.load(for: device), device: device) { _ in }
        root.duoViewportSide = 560
        for size in [CGSize(width: 1400, height: 900), CGSize(width: 900, height: 1400), CGSize(width: 800, height: 800)] {
            root.frame = CGRect(origin: .zero, size: size)
            root.isFullScreen = true
            root.layoutSubtreeIfNeeded()
            let available = FullScreenPresentationLayout(bounds: root.bounds, safeAreaInsets: root.fullScreenSafeAreaInsets).canvas
            XCTAssertEqual(root.canvas.frame.width, min(available.width, available.height))
            XCTAssertEqual(root.canvas.frame.width, root.canvas.frame.height)
            XCTAssertEqual(root.canvas.frame.midX, available.midX)
            XCTAssertEqual(root.canvas.frame.midY, available.midY)
            for turn in 0..<4 { for mode in DeviceDisplayMode.allCases {
                root.canvas.setChrome(DeviceChrome.load(for: device, displayMode: mode))
                root.canvas.setRenderedDuoPose(DuoRenderPose(angle: CGFloat(mode.hingeAngle), quarterTurns: CGFloat(turn)))
                root.layoutSubtreeIfNeeded()
                XCTAssertTrue(root.canvas.bounds.contains(root.canvas.duoHardwareBounds ?? .zero))
                XCTAssertNil(root.resizeCorner(at: root.visualDeviceRect.origin))
                XCTAssertEqual(root.duoViewportSide, 560, "Fullscreen cannot overwrite the saved desktop scale")
            } }
            root.isFullScreen = false
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.canvas.bounds.size, CGSize(width: 560, height: 560))
            XCTAssertEqual(root.visualDeviceRect.minY - root.controls.frame.maxY, DuoStage.toolbarGap, accuracy: 0.001)
        }
    }

    @MainActor func testEntireAnimatedSweepHasMarginsAndTightLayoutWithoutCameraRefitting() throws {
        let device = SimulatorDevice(udid: "fixed-stage-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("Duo DeviceKit model not installed")
        }
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let chrome = DeviceChrome.load(for: device, displayMode: .cover)
        let root = DevicePresentationView(screen: screen, chrome: chrome, device: device) { _ in }
        root.frame = CGRect(x: 0, y: 0, width: 732, height: 812)
        root.layoutSubtreeIfNeeded()
        let viewportSize = root.canvas.frame.size, toolbarSize = root.controls.frame.size
        let model = try XCTUnwrap(DuoModelView(screen: screen, chrome: chrome))
        model.frame = CGRect(x: 0, y: 0, width: 480, height: 480)
        let directory = ProcessInfo.processInfo.environment["DUO_STAGE_ARTIFACTS"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var frame = 0, minimumMargin = 480
        for turns in 0..<4 {
            var motion = DuoMotion(angle: 0, quarterTurns: turns)
            for target in [1.0, 0.0] {
                motion.fold.target = target
                for _ in 0..<120 {
                    motion.advance(seconds: 1 / 60)
                    model.setRenderedPose(motion.renderedPose, chrome: chrome)
                    let image = model.snapshot()
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                    let margin = opaqueMargin(bitmap)
                    minimumMargin = min(minimumMargin, margin)
                    XCTAssertGreaterThan(margin, 24, "Clipped model at angle \(motion.angle), orientation \(turns)")
                    if let directory, turns == 0 {
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: directory.appendingPathComponent(String(format: "frame-%04d.png", frame)))
                        frame += 1
                    }
                    root.canvas.setRenderedDuoPose(motion.renderedPose)
                    root.setFrameSize(root.duoWindowSize)
                    root.needsLayout = true
                    root.layoutSubtreeIfNeeded()
                    XCTAssertEqual(root.canvas.frame.size, viewportSize)
                    XCTAssertEqual(root.controls.frame.size, toolbarSize)
                    XCTAssertEqual(root.visualDeviceRect.minY - root.controls.frame.maxY, DuoStage.toolbarGap, accuracy: 0.001)
                    XCTAssertEqual(root.bounds.maxY - root.visualDeviceRect.maxY, DuoStage.outerMargin, accuracy: 0.001)
                }
            }
            // Include every in-between roll, not just axis-aligned endpoints.
            for step in 0...60 {
                model.setRenderedPose(DuoRenderPose(phase: 1, quarterTurns: CGFloat(turns) + CGFloat(step) / 60), chrome: chrome)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(model.snapshot().tiffRepresentation)))
                let margin = opaqueMargin(bitmap)
                minimumMargin = min(minimumMargin, margin)
                XCTAssertGreaterThan(margin, 24)
            }
        }
        print("Duo stage: 1204 rendered poses checked, minimum clear margin \(minimumMargin) px in 480×480 viewport")
    }

    @MainActor func testProjectedEnvelopeCoversPixelsAndScalesLinearly() throws {
        let device = SimulatorDevice(udid: "projected-envelope", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let chrome = DeviceChrome.load(for: device)
        let model = try XCTUnwrap(DuoModelView(screen: screen, chrome: chrome))
        model.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
        var largestSlack: CGFloat = 0
        for turns in stride(from: 0.0, through: 3.75, by: 0.25) {
            for angle in Array(stride(from: 0.0, through: 180.0, by: 5.13)) + [180] {
                model.setRenderedPose(DuoRenderPose(angle: angle, quarterTurns: turns), chrome: chrome)
                let envelope = model.projectedHardwareBounds
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(model.snapshot().tiffRepresentation)))
                let actual = try opaqueBounds(bitmap)
                let pixelScale = CGFloat(bitmap.pixelsWide) / model.bounds.width
                let pixels = CGRect(x: actual.minX / pixelScale,
                    y: model.bounds.height - actual.maxY / pixelScale,
                    width: actual.width / pixelScale, height: actual.height / pixelScale)
                XCTAssertTrue(envelope.insetBy(dx: -1, dy: -1).contains(pixels), "Clipping: \(angle), \(turns), envelope \(envelope), pixels \(pixels)")
                largestSlack = max(largestSlack, envelope.width - pixels.width, envelope.height - pixels.height)
                model.setFrameSize(CGSize(width: 350, height: 350))
                model.layoutSubtreeIfNeeded()
                XCTAssertEqual(model.projectedHardwareBounds.minX, envelope.minX / 2, accuracy: 0.001)
                XCTAssertEqual(model.projectedHardwareBounds.minY, envelope.minY / 2, accuracy: 0.001)
                XCTAssertEqual(model.projectedHardwareBounds.width, envelope.width / 2, accuracy: 0.001)
                model.setFrameSize(CGSize(width: 700, height: 700))
                model.layoutSubtreeIfNeeded()
            }
        }
        print("Projected envelope maximum extra width/height: \(largestSlack) pt at 700 pt viewport")
        XCTAssertLessThan(largestSlack, 3.5, "The viewport guard must not become a large visible margin")
    }

    @MainActor func testTopAnchoredProjectionMatchesRenderedPixelsDuringCombinedFoldAndRoll() throws {
        let device = SimulatorDevice(udid: "anchored-projection", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else { throw XCTSkip("Duo model not installed") }
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let chrome = DeviceChrome.load(for: device)
        let model = try XCTUnwrap(DuoModelView(screen: screen, chrome: chrome))
        model.frame = CGRect(x: 0, y: 0, width: 480, height: 480)
        model.anchorsHardwareToTop = true
        var motion = DuoMotion(angle: 0, quarterTurns: 0)
        var maximumTopGap: CGFloat = 0
        var frameIndex = 0
        for turn in 1...4 {
            motion.rotate(to: turn % 4)
            motion.fold.target = turn.isMultiple(of: 2) ? 0 : 1
            for _ in 0..<120 {
                motion.advance(seconds: 1 / 60)
                model.setRenderedPose(motion.renderedPose, chrome: chrome)
                let hardware = model.projectedHardwareBounds
                XCTAssertEqual(hardware.maxY, model.bounds.maxY - DuoStage.projectionTopInset, accuracy: 0.001)
                XCTAssertEqual(hardware.midX, model.bounds.midX, accuracy: 0.001)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(model.snapshot().tiffRepresentation)))
                if let path = ProcessInfo.processInfo.environment["DUO_ANCHOR_ARTIFACTS"], frameIndex % 60 == 0 {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("anchor-\(frameIndex).png"))
                }
                frameIndex += 1
                let pixels = try opaqueBounds(bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / model.bounds.width
                let topGap = pixels.minY / scale
                maximumTopGap = max(maximumTopGap, topGap)
                XCTAssertGreaterThan(topGap, DuoStage.projectionTopInset - 2, "No geometry may run beyond the top of the backing surface")
                XCTAssertLessThan(topGap, DuoStage.projectionTopInset + 2, "The rendered top must track the pose's envelope, not the previous frame")
                XCTAssertLessThanOrEqual(pixels.maxY / scale, hardware.height + DuoStage.projectionTopInset + 1,
                    "The fitted window must not crop the bottom of a combined fold/roll")
            }
        }
        print("480 combined fold/roll frames: maximum visible top offset from 16 pt backing guard \(maximumTopGap - DuoStage.projectionTopInset) pt")
    }

    private func opaqueBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
        let data = try XCTUnwrap(bitmap.bitmapData)
        let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1
        var x0 = bitmap.pixelsWide, y0 = bitmap.pixelsHigh, x1 = 0, y1 = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            if data[y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + alpha] > 25 {
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
            }
        } }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func opaqueMargin(_ bitmap: NSBitmapImageRep) -> Int {
        guard let pixels = bitmap.bitmapData, bitmap.bitsPerSample == 8, !bitmap.isPlanar, bitmap.hasAlpha else {
            XCTFail("Unexpected snapshot pixel format")
            return 0
        }
        var margin = min(bitmap.pixelsWide, bitmap.pixelsHigh)
        let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1
        // Every border pixel is checked; the interior is sampled only until
        // finding the tightest margin. This catches one-pixel clipped corners.
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let candidate = min(x, y, bitmap.pixelsWide - 1 - x, bitmap.pixelsHigh - 1 - y)
                if candidate < margin,
                   pixels[y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + alpha] > 25 { margin = candidate }
            }
        }
        XCTAssertLessThan(margin, 200, "Empty or implausibly small render")
        return margin
    }
}
