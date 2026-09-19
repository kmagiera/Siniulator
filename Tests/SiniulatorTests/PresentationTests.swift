import AppKit
import XCTest
@testable import Siniulator

final class PresentationTests: XCTestCase {
    func testBezelFreeScreenTouchesHeaderAndUsesEntireRemainingWindow() {
        for size in [CGSize(width: 620, height: 1200), CGSize(width: 324, height: 900), CGSize(width: 1100, height: 650)] {
            for turn in 0..<4 {
                let device = ChromeGeometry(screenSize: CGSize(width: 440, height: 956), border: NSEdgeInsetsZero,
                    padding: NSEdgeInsetsZero, quarterTurns: turn)
                let bounds = CGRect(origin: .zero, size: size)
                let headerHeight = SimulatorToolbarMetrics(titleWidth: 140).layout(width: size.width).height
                let layout = NormalPresentationLayout(bounds: bounds, headerHeight: headerHeight,
                    device: device, maximumScale: nil, showsBezels: false)
                XCTAssertEqual(layout.canvas.minY, layout.header.maxY)
                XCTAssertEqual(layout.canvas.minX, bounds.minX)
                XCTAssertEqual(layout.canvas.maxX, bounds.maxX)
                XCTAssertEqual(layout.canvas.maxY, bounds.maxY)
                XCTAssertEqual(layout.header.union(layout.canvas), bounds)
                XCTAssertTrue(layout.canvas.contains(device.fit(in: layout.canvas).rect))
            }
        }
    }

    @MainActor func testBezelToggleJoinsWindowWithoutChangingScreenScaleAndFullScreenStaysTransparent() async throws {
        _ = NSApplication.shared
        let device = SimulatorDevice(udid: "presentation-test", name: "Test iPhone", state: "Shutdown",
            isAvailable: true, deviceTypeIdentifier: nil, runtime: "iOS")
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let root = DevicePresentationView(screen: screen, chrome: DeviceChrome.load(for: device), device: device) { _ in }
        let window = DeviceHostWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 1200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = root
        let chrome = FullScreenChrome(window: window, controls: root.controls) { _ in }
        root.controls.attach(to: window)
        let originalButtons = root.controls.windowButtons
        for turn in 0..<4 {
            screen.quarterTurns = turn
            for bezels in [true, false, true, false] {
                root.canvas.showsBezels = bezels
                for scale in [CGFloat(0.5), 1] {
                    root.canvas.maximumScale = scale
                    let size = root.normalSize(scale: scale)
                    window.setFrame(CGRect(origin: window.frame.origin, size: size), display: false, animate: false)
                    root.refreshGeometry()
                    root.layoutSubtreeIfNeeded()
                    XCTAssertEqual(root.canvas.geometry.fit(in: root.canvas.bounds, maximumScale: scale).scale, scale, accuracy: 0.000001)
                    XCTAssertEqual(root.normalScaleToFit(in: size), scale, accuracy: 0.000001)
                    XCTAssertEqual(root.canvas.frame.minY - root.controls.frame.maxY, bezels ? 12 : 0)
                    XCTAssertEqual(window.isOpaque, !bezels)
                    XCTAssertEqual(window.backgroundColor, bezels ? .clear : .black)
                    if !bezels {
                        XCTAssertEqual(root.deviceRect.minY, root.controls.frame.maxY, accuracy: 0.000001)
                        XCTAssertEqual(root.canvas.frame.maxY, root.bounds.maxY)
                        XCTAssertEqual(root.canvas.frame.width, root.bounds.width)
                        XCTAssertEqual(root.controls.layer?.cornerRadius, 0)
                        XCTAssertEqual(root.layer?.backgroundColor?.alpha, 1)
                        XCTAssertNil(root.resizeCorner(at: CGPoint(x: root.deviceRect.minX, y: root.deviceRect.minY)))
                    }
                    XCTAssertTrue(zip(originalButtons, root.controls.windowButtons).allSatisfy { $0 === $1 })
                }
            }
        }
        window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: 620, height: 1500)), display: false, animate: false)
        root.refreshGeometry()
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.deviceRect.minY, root.controls.frame.maxY, accuracy: 0.000001,
            "A tall restored window must not introduce a gap above the screen")
        root.isFullScreen = true
        root.refreshGeometry()
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertNil(root.layer?.backgroundColor)
        XCTAssertFalse(root.backdrop.isHidden)
        XCTAssertEqual(root.backdrop.blendingMode, .behindWindow)
        XCTAssertEqual(root.controls.layer?.backgroundColor?.alpha, 1)
        root.isFullScreen = false
        root.refreshGeometry()
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(root.backdrop.isHidden)
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .black)
        withExtendedLifetime(chrome) {}
    }

    func testIPadBezelStaysBelowToolbarInTallRestoredWindowsAndEveryOrientation() {
        // Installed iPad (A16) chrome includes a 59-point bezel and top/right
        // hardware-button padding. The old 560x900 startup frame added a gap.
        for turn in 0..<4 {
            let device = ChromeGeometry(screenSize: CGSize(width: 820, height: 1180),
                border: NSEdgeInsets(top: 59, left: 59, bottom: 59, right: 59),
                padding: NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 10), quarterTurns: turn)
            for size in [CGSize(width: 560, height: 900), CGSize(width: 560, height: 1400),
                         CGSize(width: 1100, height: 600), CGSize(width: 324, height: 900)] {
                let headerHeight = SimulatorToolbarMetrics(titleWidth: 140).layout(width: size.width).height
                let bounds = CGRect(origin: .zero, size: size)
                let layout = NormalPresentationLayout(bounds: bounds, headerHeight: headerHeight, device: device, maximumScale: nil)
                let fit = device.fit(in: layout.canvas)
                let bezel = ChromeGeometry.placed(device.rotated(device.body), in: fit.rect, scale: fit.scale)
                XCTAssertTrue(bounds.contains(layout.canvas))
                XCTAssertEqual(layout.canvas.minY, layout.header.maxY + 12, accuracy: 0.001)
                XCTAssertEqual(fit.rect.minY, layout.canvas.minY, accuracy: 0.001)
                XCTAssertEqual(bezel.minY - layout.header.maxY,
                    12 + device.rotated(device.body).minY * fit.scale, accuracy: 0.001)
                XCTAssertTrue(layout.canvas.insetBy(dx: -0.001, dy: -0.001).contains(bezel))
            }
        }
    }

    func testReducedScaleKeepsBezelAtTopAndHorizontalCenter() {
        let device = ChromeGeometry(screenSize: CGSize(width: 400, height: 800),
            border: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20),
            padding: NSEdgeInsetsZero, quarterTurns: 0)
        let layout = NormalPresentationLayout(bounds: CGRect(x: 0, y: 0, width: 560, height: 900),
            headerHeight: 52, device: device, maximumScale: 0.5)
        let fit = device.fit(in: layout.canvas, maximumScale: 0.5)
        XCTAssertEqual(fit.scale, 0.5)
        XCTAssertEqual(fit.rect.minY, layout.header.maxY + 12)
        XCTAssertEqual(fit.rect.midX, 280)
    }
}
