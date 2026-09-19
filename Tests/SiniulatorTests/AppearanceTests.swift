import AppKit
import XCTest
@testable import Siniulator

final class AppearanceTests: XCTestCase {
    @MainActor private func presentation() throws -> (DeviceHostWindow, DevicePresentationView, FullScreenChrome) {
        _ = NSApplication.shared
        let device = SimulatorDevice(udid: "appearance-test", name: "Test iPhone", state: "Shutdown",
            isAvailable: true, deviceTypeIdentifier: nil, runtime: "iOS")
        let root = DevicePresentationView(screen: SimulatorScreenView(renderer: try ScreenRenderer()),
            chrome: DeviceChrome.load(for: device), device: device) { _ in }
        let window = DeviceHostWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 1200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = root
        let chrome = FullScreenChrome(window: window, controls: root.controls) { _ in }
        root.controls.attach(to: window)
        root.layoutSubtreeIfNeeded()
        return (window, root, chrome)
    }

    @MainActor private func windowBackground(for appearance: NSAppearance) -> CGColor {
        var color = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance { color = NSColor.windowBackgroundColor.cgColor }
        return color
    }

    @MainActor func testLiveAppearanceChangesUpdateOpaqueToolbarWithoutOverridingNativeActions() async throws {
        let (window, root, chrome) = try presentation()
        let bar = root.controls
        let originalButtons = bar.windowButtons
        let originalCanvas = root.canvas.frame
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .aqua,
                               .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            await Task.yield()
            root.layoutSubtreeIfNeeded()
            let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            XCTAssertNil(bar.appearance)
            XCTAssertNil(bar.surface.appearance)
            XCTAssertNil(root.backdrop.appearance)
            XCTAssertEqual(bar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), dark ? .darkAqua : .aqua)
            XCTAssertEqual(bar.layer?.backgroundColor?.alpha, 1)
            XCTAssertEqual(bar.contentView.layer?.backgroundColor, bar.layer?.backgroundColor)
            XCTAssertEqual(bar.layer?.backgroundColor, windowBackground(for: window.effectiveAppearance),
                "Toolbar backgrounds must follow the system palette, including increased contrast")
            XCTAssertTrue(window.toolbar === bar.actions.toolbar)
            XCTAssertEqual(bar.actionItems.count, 3)
            XCTAssertTrue(bar.actionItems.allSatisfy { $0.view == nil }, "AppKit creates and styles every action control")
            for label in bar.contentView.subviews.compactMap({ $0 as? NSTextField }) {
                let expected: NSColor = label.font?.pointSize == 13 ? .labelColor : .secondaryLabelColor
                XCTAssertEqual(label.textColor, expected)
            }
            XCTAssertEqual(root.canvas.frame, originalCanvas, "Appearance must not resize the device")
            XCTAssertTrue(zip(originalButtons, bar.windowButtons).allSatisfy { $0 === $1 })
        }
        withExtendedLifetime(chrome) {}
    }

    @MainActor func testFullScreenKeepsOpaqueHeaderAndSystemBackdropInBothAppearances() async throws {
        let (window, root, chrome) = try presentation()
        root.isFullScreen = true
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            await Task.yield()
            root.layoutSubtreeIfNeeded()
            let dark = appearanceName == .darkAqua
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor, .clear)
            XCTAssertNil(root.layer?.backgroundColor)
            XCTAssertFalse(root.backdrop.isHidden)
            XCTAssertNil(root.backdrop.appearance)
            XCTAssertEqual(root.backdrop.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), dark ? .darkAqua : .aqua)
            XCTAssertEqual(root.backdrop.blendingMode, .behindWindow)
            XCTAssertEqual(root.controls.layer?.backgroundColor?.alpha, 1)
            XCTAssertNil(root.controls.contentView.layer?.backgroundColor)
            let background = root.controls.layer?.backgroundColor
            XCTAssertEqual(background, windowBackground(for: window.effectiveAppearance))
            for progress in [CGFloat(0), 0.5, 1, 0] {
                root.controls.setFullScreenRevealProgress(progress)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.controls.layer?.backgroundColor, background)
            }
        }
        withExtendedLifetime(chrome) {}
    }
}
