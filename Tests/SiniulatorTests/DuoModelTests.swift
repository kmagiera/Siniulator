import AppKit
import IOSurface
import Metal
import SimulatorBridge
import XCTest
@testable import Siniulator

private final class DisplayStub: SIDisplay {
    private let lock = NSLock()
    private var value: IOSurface?
    var framebuffer: IOSurface? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    override var surface: Any? { framebuffer }
}

final class DuoModelTests: XCTestCase {
    @MainActor func testDepartingPanelSurvivesGuestClearingItsLiveSurface() throws {
        let device = SimulatorDevice(udid: "duo-panel-handoff", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }
        let inner = DeviceChrome.load(for: device, displayMode: .innerFullyOpen)
        let cover = DeviceChrome.load(for: device, displayMode: .cover)
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let model = try XCTUnwrap(DuoModelView(screen: screen, chrome: inner))
        model.frame = CGRect(x: 0, y: 0, width: 480, height: 480)
        let display = DisplayStub()
        let surface = try XCTUnwrap(IOSurfaceCreate([
            kIOSurfaceWidth: 64, kIOSurfaceHeight: 64, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 256, kIOSurfacePixelFormat: UInt32(0x42475241)
        ] as CFDictionary))
        func fill(_ pixel: UInt32) {
            IOSurfaceLock(surface, [], nil)
            IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self).update(repeating: pixel, count: 64 * 64)
            IOSurfaceUnlock(surface, [], nil)
        }
        display.framebuffer = surface
        fill(0xff0000ff)
        model.requestPanel(cover: false, engine: screen.renderer.engine)
        model.updateDisplay(display, engine: screen.renderer.engine, chrome: inner)
        model.setHingeAngle(120, chrome: inner, screen: screen)
        model.requestPanel(cover: true, engine: screen.renderer.engine)
        fill(0xff000000)
        // The same shared IOSurface now contains the shutdown frame. Neither
        // the shared memory nor a late callback may black out the old material.
        model.updateDisplay(display, engine: screen.renderer.engine, chrome: inner)
        model.setDisplayChrome(cover)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(model.snapshot().tiffRepresentation)))
        var blue = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.alphaComponent > 0.9 && color.blueComponent > 0.8 && color.redComponent < 0.1 { blue += 1 }
            }
        }
        XCTAssertGreaterThan(blue, 100, "The inner screen must remain lit until the camera has turned away")
    }

    @MainActor func testClosedCoverFacesTheCameraSquarelyInEveryOrientation() throws {
        let device = SimulatorDevice(udid: "duo-closed-cover", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path),
              !DeviceChrome.displayModes(for: device).isEmpty else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }
        let chrome = DeviceChrome.load(for: device, displayMode: .cover)
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let model = try XCTUnwrap(DuoModelView(screen: screen, chrome: chrome))
        model.frame = CGRect(x: 0, y: 0, width: 640, height: 640)
        let display = DisplayStub()
        let surface = try XCTUnwrap(IOSurfaceCreate([
            kIOSurfaceWidth: 64, kIOSurfaceHeight: 64, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 256, kIOSurfacePixelFormat: UInt32(0x42475241)
        ] as CFDictionary))
        IOSurfaceLock(surface, [], nil)
        IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xffff0000, count: 64 * 64)
        IOSurfaceUnlock(surface, [], nil)
        display.framebuffer = surface
        model.updateDisplay(display, engine: screen.renderer.engine, chrome: chrome)

        for turns in 0..<4 {
            screen.quarterTurns = turns
            // Exercise the last few degrees as well as a direct preset, so a
            // stale animation pose cannot make the zero-angle assertion pass.
            for angle: CGFloat in [5, 1, 0] { model.setHingeAngle(angle, chrome: chrome, screen: screen) }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(model.snapshot().tiffRepresentation)))
            if let path = ProcessInfo.processInfo.environment["DUO_COVER_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("cover-\(turns).png"))
            }
            func isScreen(_ x: Int, _ y: Int) -> Bool {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.alphaComponent > 0.9 && color.redComponent > 0.9
                    && color.greenComponent < 0.25 && color.blueComponent < 0.1
            }
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            let xs = (0..<width).filter { isScreen($0, height / 2) }
            let ys = (0..<height).filter { isScreen(width / 2, $0) }
            let left = try XCTUnwrap(xs.first), right = try XCTUnwrap(xs.last)
            let top = try XCTUnwrap(ys.first), bottom = try XCTUnwrap(ys.last)
            var tops: [Int] = [], bottoms: [Int] = [], lefts: [Int] = [], rights: [Int] = []
            for fraction in [0.2, 0.5, 0.8] {
                let x = left + Int(Double(right - left) * fraction)
                let y = top + Int(Double(bottom - top) * fraction)
                let column = (0..<height).filter { isScreen(x, $0) }
                let row = (0..<width).filter { isScreen($0, y) }
                tops.append(try XCTUnwrap(column.first)); bottoms.append(try XCTUnwrap(column.last))
                lefts.append(try XCTUnwrap(row.first)); rights.append(try XCTUnwrap(row.last))
            }
            for edge in [tops, bottoms, lefts, rights] {
                XCTAssertLessThanOrEqual(edge.max()! - edge.min()!, 1,
                    "Closed cover edges must be parallel to the viewport: turns=\(turns), edge=\(edge)")
            }
        }
    }

#if DEBUG
    @MainActor func testFrameCallbacksRefreshLateAndReplacedSurfacesWithoutReconnecting() async throws {
        let device = SimulatorDevice(udid: "duo-frame-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path),
              !DeviceChrome.displayModes(for: device).isEmpty else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }
        let chrome = DeviceChrome.load(for: device, displayMode: .innerFullyOpen)
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let root = DevicePresentationView(screen: screen, chrome: chrome, device: device) { _ in }
        root.frame = CGRect(x: 0, y: 0, width: 520, height: 440)
        root.layoutSubtreeIfNeeded()
        let display = DisplayStub()
        screen.setDisplay(display, chrome: chrome)
        let delivery = screen.frameDelivery
        let observer = screen.onDisplayChange
        var callbacks = 0
        screen.onDisplayChange = { value in callbacks += 1; observer?(value) }

        func surface(_ pixel: UInt32) throws -> IOSurface {
            let properties: [String: Any] = [kIOSurfaceWidth as String: 64, kIOSurfaceHeight as String: 64,
                kIOSurfaceBytesPerElement as String: 4, kIOSurfaceBytesPerRow as String: 256,
                kIOSurfacePixelFormat as String: UInt32(0x42475241)]
            let surface = try XCTUnwrap(IOSurfaceCreate(properties as CFDictionary))
            IOSurfaceLock(surface, [], nil)
            IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self).update(repeating: pixel, count: 64 * 64)
            IOSurfaceUnlock(surface, [], nil)
            return surface
        }
        func coloredFraction(red: Bool) throws -> Double {
            let image = try XCTUnwrap(root.canvas.duoSnapshot())
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            var colored = 0, samples = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.alphaComponent > 0.9 { samples += 1 }
                    if color.alphaComponent > 0.9,
                       (red ? color.redComponent : color.blueComponent) > 0.8,
                       (red ? color.blueComponent : color.redComponent) < 0.1 { colored += 1 }
                }
            }
            return Double(colored) / Double(samples)
        }

        // An initial connection may succeed before the first IOSurface exists.
        display.framebuffer = try surface(0xffff0000)
        for _ in 0..<100 { delivery.requestFrame() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callbacks, 1, "Damage callbacks should be coalesced on the main actor")
        XCTAssertGreaterThan(try coloredFraction(red: true), 0.5)

        // Same SIDisplay, different IOSurface, as during a runtime reallocation.
        display.framebuffer = try surface(0xff0000ff)
        delivery.requestFrame()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(try coloredFraction(red: false), 0.5)
        XCTAssertLessThan(try coloredFraction(red: true), 0.01)

        // Subscribe to the other panel before it becomes active. Its missing
        // initial surface must not clear the visible inner framebuffer.
        let cover = DeviceChrome.load(for: device, displayMode: .cover)
        let replacement = DisplayStub()
        root.canvas.updateDuoDisplay(replacement, chrome: cover)
        XCTAssertGreaterThan(try coloredFraction(red: false), 0.5)
        replacement.framebuffer = try surface(0xffff0000)
        root.canvas.updateDuoDisplay(replacement, chrome: cover)
        XCTAssertGreaterThan(try coloredFraction(red: false), 0.5)
        root.canvas.setHingeAngle(120)
        root.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try coloredFraction(red: false), 0.5,
            "The authored double-sided inner mesh must fill the partially open bezel")
        root.canvas.setHingeAngle(30)
        root.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try coloredFraction(red: true), 0.001,
            "At 150° closed the textured cover must already be coming into view")
        root.canvas.setHingeAngle(20)
        root.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try coloredFraction(red: true), 0.02,
            "The cover must show its image before the 15° input handoff")

        // Layout switches first. Damage on the still-connected inner display
        // must not bind that framebuffer to the requested cover panel.
        root.canvas.setChrome(cover)
        root.canvas.setHingeAngle(0)
        root.refreshGeometry()
        root.layoutSubtreeIfNeeded()
        delivery.requestFrame()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThan(try coloredFraction(red: false), 0.01)
        XCTAssertGreaterThan(try coloredFraction(red: true), 0.35,
            "The cover must already be textured before input/screenshot switches to it")
        screen.setDisplay(replacement, chrome: cover)
        delivery.requestFrame() // a queued callback from the previous connection
        try await Task.sleep(for: .milliseconds(50))
        // The cover now occupies half of the stable unfolded viewport.
        XCTAssertGreaterThan(try coloredFraction(red: true), 0.35)
        XCTAssertLessThan(try coloredFraction(red: false), 0.01)

        // Pending callbacks from the old connection must use the current source
        // and cannot restore a stale image after disconnect.
        delivery.requestFrame()
        screen.display = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThan(try coloredFraction(red: false), 0.01)
        XCTAssertLessThan(try coloredFraction(red: true), 0.01)
    }
#endif

    @MainActor func testSlowFoldKeepsTheModelViewportAndSuppressesTheFlatRenderer() throws {
        let device = SimulatorDevice(udid: "duo-slow-fold", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path),
              !DeviceChrome.displayModes(for: device).isEmpty else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let root = DevicePresentationView(screen: screen,
            chrome: DeviceChrome.load(for: device, displayMode: .innerFullyOpen), device: device) { _ in }
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 640)
        for turns in 0..<4 {
            screen.quarterTurns = turns
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            let viewport = screen.bounds.size
            for angle in Array(stride(from: 180, through: 0, by: -1)) + Array(0...180) {
                root.canvas.setChrome(DeviceChrome.load(for: device,
                    displayMode: .mode(forHingeAngle: Double(angle))))
                root.canvas.setHingeAngle(CGFloat(angle))
                root.refreshGeometry()
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(screen.bounds.size, viewport, "angle=\(angle), turns=\(turns)")
                XCTAssertEqual(screen.renderer.layer.opacity, 0)
                XCTAssertTrue(screen.renderer.layer.isHidden)
            }
        }
    }

    @MainActor func testMissingDuoModelFallsBackToTheOrdinaryFramebufferRenderer() throws {
        guard !FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The selected Xcode includes the Duo model")
        }
        let device = SimulatorDevice(udid: "duo-fallback-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard DeviceChrome.displayModes(for: device) == DeviceDisplayMode.allCases else {
            throw XCTSkip("The machine has no Duo device profile, which is the normal older-Xcode configuration")
        }
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let root = DevicePresentationView(screen: screen, chrome: DeviceChrome.load(for: device, displayMode: .innerFullyOpen),
            device: device) { _ in }
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 640)
        root.layoutSubtreeIfNeeded()

        XCTAssertFalse(screen.renderer.layer.isHidden)
        XCTAssertFalse(screen.frame.isEmpty)
        XCTAssertFalse(root.canvas.usesDuoModel)
        XCTAssertNil(screen.coordinateMapper)
    }

    @MainActor func testSceneKitReceivesDisplayFramebufferAsSRGB() throws {
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: 4,
            kIOSurfaceHeight as String: 4,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfaceBytesPerRow as String: 16,
            kIOSurfacePixelFormat as String: UInt32(0x42475241)
        ]
        let surface = try XCTUnwrap(IOSurfaceCreate(properties as CFDictionary))
        let engine = try MetalScreenEngine.shared.get()
        XCTAssertEqual(engine.texture(for: surface)?.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(engine.texture(for: surface, sRGB: true)?.pixelFormat, .bgra8Unorm_srgb)
    }

    @MainActor func testDeviceKitPosesAreFramedWithoutClipping() throws {
        let device = SimulatorDevice(udid: "duo-model-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard DeviceChrome.displayModes(for: device) == DeviceDisplayMode.allCases,
              FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }

        func snapshot(_ mode: DeviceDisplayMode, turns: Int = 0) throws -> (bitmap: NSBitmapImageRep, png: Data) {
            let screen = SimulatorScreenView(renderer: try ScreenRenderer())
            screen.quarterTurns = turns
            let chrome = DeviceChrome.load(for: device, displayMode: mode)
            guard let model = DuoModelView(screen: screen, chrome: chrome) else {
                throw XCTSkip("The V68 model could not be loaded")
            }
            model.frame = CGRect(x: 0, y: 0, width: 640, height: 640)
            model.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            guard let tiff = model.snapshot().tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                XCTFail("Could not render the V68 model")
                return (NSBitmapImageRep(), Data())
            }
            return (bitmap, data)
        }

        let book = try snapshot(.innerPartiallyOpen)
        let flat = try snapshot(.innerFullyOpen)
        let cover = try snapshot(.cover)
        XCTAssertNotEqual(book.png, flat.png, "The Book preset must apply the V68 fold animation")

        let flatBounds = opaqueBounds(of: flat.bitmap)
        let bookBounds = opaqueBounds(of: book.bitmap)
        let coverBounds = opaqueBounds(of: cover.bitmap)
        for bounds in [flatBounds, bookBounds, coverBounds] {
            XCTAssertGreaterThanOrEqual(bounds.minX, 4)
            XCTAssertGreaterThanOrEqual(bounds.minY, 4)
            XCTAssertLessThanOrEqual(bounds.maxX, 636)
            XCTAssertLessThanOrEqual(bounds.maxY, 636)
            XCTAssertEqual(bounds.midX, 320, accuracy: 24,
                "Every pose should stay centered as the camera changes sides")
        }
        XCTAssertLessThan(bookBounds.height, flatBounds.height * 1.15,
            "Fixed camera allows natural perspective, without refitting its scale")
        XCTAssertLessThan(bookBounds.width, flatBounds.width * 0.97,
            "The partially open pose must have visible perspective")
        XCTAssertLessThan(coverBounds.width, coverBounds.height * 0.85,
            "The closed pose must show the portrait cover instead of an edge or the rear panel")

        for turns in 0..<4 {
            let rotated = opaqueBounds(of: try snapshot(.cover, turns: turns).bitmap)
            XCTAssertGreaterThanOrEqual(rotated.minX, 4)
            XCTAssertGreaterThanOrEqual(rotated.minY, 4)
            XCTAssertLessThanOrEqual(rotated.maxX, 636)
            XCTAssertLessThanOrEqual(rotated.maxY, 636)
            XCTAssertEqual(rotated.midX, 320, accuracy: 24,
                "The cover must stay centered after quarter turn \(turns)")
            XCTAssertEqual(rotated.midY, 320, accuracy: 24,
                "The cover must stay centered after quarter turn \(turns)")
        }
    }

    @MainActor func testFoldableToolbarKeepsFixedWidthAndGapInEveryPreset() throws {
        let device = SimulatorDevice(udid: "duo-toolbar-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard DeviceChrome.displayModes(for: device) == DeviceDisplayMode.allCases,
              FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }

        func geometry(_ mode: DeviceDisplayMode) throws -> (width: CGFloat, midX: CGFloat, modeMidX: CGFloat, gap: CGFloat) {
            let screen = SimulatorScreenView(renderer: try ScreenRenderer())
            let root = DevicePresentationView(screen: screen, chrome: DeviceChrome.load(for: device, displayMode: mode),
                device: device) { _ in }
            root.frame = CGRect(x: 0, y: 0, width: 800, height: 640)
            root.layoutSubtreeIfNeeded()
            root.controls.layoutSubtreeIfNeeded()
            let control = try XCTUnwrap(root.controls.displayModeControl)
            let controlFrame = root.convert(control.bounds, from: control)
            return (root.controls.frame.width, root.controls.frame.midX, controlFrame.midX,
                root.visualDeviceRect.minY - root.controls.frame.maxY)
        }

        let cover = try geometry(.cover)
        let book = try geometry(.innerPartiallyOpen)
        let flat = try geometry(.innerFullyOpen)
        XCTAssertGreaterThan(cover.width, 0)
        XCTAssertEqual(book.width, cover.width)
        XCTAssertEqual(flat.width, cover.width)
        for item in [cover, book, flat] {
            XCTAssertEqual(item.midX, 400, accuracy: 0.5)
            XCTAssertEqual(item.modeMidX, 400, accuracy: 0.5)
            XCTAssertEqual(item.gap, DuoStage.toolbarGap, accuracy: 0.5)
        }
    }

    @MainActor func testToolbarNeverNarrowsPastClosedWidthDuringFolding() throws {
        let device = SimulatorDevice(udid: "duo-toolbar-fold", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard DeviceChrome.displayModes(for: device) == DeviceDisplayMode.allCases,
              FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }
        for turns in 0..<4 {
            let screen = SimulatorScreenView(renderer: try ScreenRenderer())
            screen.quarterTurns = turns
            let root = DevicePresentationView(screen: screen,
                chrome: DeviceChrome.load(for: device, displayMode: .innerFullyOpen), device: device) { _ in }
            for width: CGFloat in [root.controls.minimumCompactWidth + 24, 800, 1800] {
                root.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                root.layoutSubtreeIfNeeded()
                var previous: CGFloat = .greatestFiniteMagnitude
                for angle in stride(from: 180, through: 0, by: -5) {
                    root.canvas.setHingeAngle(CGFloat(angle))
                    root.refreshGeometry()
                    root.layoutSubtreeIfNeeded()
                    let bar = root.controls
                    XCTAssertLessThanOrEqual(bar.frame.width, previous + 0.01,
                        "Closing must not narrow then widen the toolbar: angle=\(angle), turns=\(turns)")
                    previous = bar.frame.width
                    let selector = try XCTUnwrap(bar.displayModeControl)
                    let selectorFrame = bar.convert(selector.bounds, from: selector)
                    XCTAssertEqual(selectorFrame.midX, bar.bounds.midX, accuracy: 0.5)
                    XCTAssertFalse(bar.barLayout.name.intersects(selectorFrame))
                    XCTAssertFalse(bar.barLayout.runtime.intersects(selectorFrame))
                    XCTAssertEqual(bar.barLayout.isCompact, width < bar.minimumExpandedWidth)
                }
            }
        }
    }

#if DEBUG
    @MainActor func testHardwareCornerResizingMatchesRenderedCornersInEveryOrientation() throws {
        let device = SimulatorDevice(udid: "duo-resize-test", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard DeviceChrome.displayModes(for: device) == DeviceDisplayMode.allCases,
              FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("The iPhone Duo DeviceKit resources are not installed")
        }

        for size in [CGSize(width: 520, height: 440), CGSize(width: 800, height: 640)] {
            for turns in 0..<4 {
                for mode in DeviceDisplayMode.allCases {
                    let screen = SimulatorScreenView(renderer: try ScreenRenderer())
                    screen.quarterTurns = turns
                    let root = DevicePresentationView(screen: screen, chrome: DeviceChrome.load(for: device, displayMode: mode),
                        device: device) { _ in }
                    root.frame = CGRect(origin: .zero, size: size)
                    root.layoutSubtreeIfNeeded()
                    // AppKit can ask for cursor rects before SceneKit's first draw.
                    let beforeDraw = Dictionary(uniqueKeysWithValues: DeviceResizeCorner.allCases.map {
                        ($0, root.resizeTarget(for: $0))
                    })
                    let image = try XCTUnwrap(root.canvas.duoSnapshot())
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                    // Independently find the rendered pixel nearest each viewport
                    // corner. Never derive the expected target from production's
                    // projection fractions or resize geometry.
                    let rendered = renderedCorners(of: bitmap)
                    let viewport = root.convert(root.canvas.fittedGeometry.rect, from: root.canvas)
                    for corner in DeviceResizeCorner.allCases {
                        let pixel = try XCTUnwrap(rendered[corner])
                        let point = CGPoint(x: viewport.minX + pixel.x / CGFloat(bitmap.pixelsWide) * viewport.width,
                            y: viewport.minY + pixel.y / CGFloat(bitmap.pixelsHigh) * viewport.height)
                        XCTAssertTrue(try XCTUnwrap(beforeDraw[corner]).contains(point),
                            "The visible corner must already be interactive before SceneKit draws")
                        XCTAssertEqual(root.resizeCorner(at: point), corner,
                            "Resize target must match rendered \(corner) for \(mode), turn \(turns)")
                    }
                }
            }
        }
    }
#endif

    private func renderedCorners(of bitmap: NSBitmapImageRep) -> [DeviceResizeCorner: CGPoint] {
        let hardware = opaqueBounds(of: bitmap)
        var result: [DeviceResizeCorner: CGPoint] = [:]
        var distances: [DeviceResizeCorner: CGFloat] = [:]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                for corner in DeviceResizeCorner.allCases {
                    let dx = corner.isLeft ? CGFloat(x) - hardware.minX : hardware.maxX - CGFloat(x)
                    let dy = corner.isTop ? CGFloat(y) - hardware.minY : hardware.maxY - CGFloat(y)
                    let distance = dx * dx + dy * dy
                    if distance < (distances[corner] ?? .greatestFiniteMagnitude) {
                        distances[corner] = distance
                        result[corner] = CGPoint(x: x, y: y)
                    }
                }
            }
        }
        return result
    }

    private func opaqueBounds(of bitmap: NSBitmapImageRep) -> CGRect {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.03 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
