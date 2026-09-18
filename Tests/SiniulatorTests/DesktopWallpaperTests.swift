import AppKit
import XCTest
@testable import Siniulator

final class DesktopWallpaperTests: XCTestCase {
    func testWallpaperFitsOrCropsWithoutDistortingItsAspectRatio() {
        let desktop = CGRect(x: 494, y: -982, width: 1512, height: 982)
        let image = CGSize(width: 4000, height: 2000)
        let fit = DesktopWallpaperView.imageFrame(image: image, desktop: desktop, scaling: .scaleProportionallyUpOrDown, clipping: false)
        let crop = DesktopWallpaperView.imageFrame(image: image, desktop: desktop, scaling: .scaleProportionallyUpOrDown, clipping: true)
        XCTAssertEqual(fit, CGRect(x: 494, y: -869, width: 1512, height: 756))
        XCTAssertEqual(crop, CGRect(x: 268, y: -982, width: 1964, height: 982))
        XCTAssertEqual(fit.width / fit.height, 2)
        XCTAssertEqual(crop.width / crop.height, 2)
    }

    func testDesktopScalingOptionsRetainDisplayOriginAndImageCenter() {
        let desktop = CGRect(x: -1920, y: 80, width: 1920, height: 1080)
        let image = CGSize(width: 800, height: 600)
        XCTAssertEqual(DesktopWallpaperView.imageFrame(image: image, desktop: desktop, scaling: .scaleAxesIndependently, clipping: false), desktop)
        XCTAssertEqual(DesktopWallpaperView.imageFrame(image: image, desktop: desktop, scaling: .scaleNone, clipping: false),
            CGRect(x: -1360, y: 320, width: 800, height: 600))
        XCTAssertEqual(DesktopWallpaperView.imageFrame(image: .zero, desktop: desktop, scaling: .scaleProportionallyUpOrDown, clipping: true), desktop)
    }

    func testScaleDownNeverEnlargesSmallWallpaper() {
        let desktop = CGRect(x: -1920, y: 80, width: 1920, height: 1080)
        let image = CGSize(width: 800, height: 600)
        for clipping in [false, true] {
            let frame = DesktopWallpaperView.imageFrame(image: image, desktop: desktop,
                scaling: .scaleProportionallyDown, clipping: clipping)
            XCTAssertEqual(frame.size, image)
            XCTAssertEqual(frame.midX, desktop.midX)
            XCTAssertEqual(frame.midY, desktop.midY)
        }
    }

    func testScaleDownStillFitsAndCropsLargeWallpaper() {
        let desktop = CGRect(x: 100, y: -800, width: 1000, height: 800)
        let image = CGSize(width: 4000, height: 2000)
        XCTAssertEqual(DesktopWallpaperView.imageFrame(image: image, desktop: desktop,
            scaling: .scaleProportionallyDown, clipping: false), CGRect(x: 100, y: -650, width: 1000, height: 500))
        XCTAssertEqual(DesktopWallpaperView.imageFrame(image: image, desktop: desktop,
            scaling: .scaleProportionallyDown, clipping: true), CGRect(x: -200, y: -800, width: 1600, height: 800))
    }

    @MainActor func testWallpaperRemainsAlignedWithDisplayAcrossWindowTiles() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 800),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let view = DesktopWallpaperView(frame: .zero)
        window.contentView = view
        for x in [CGFloat(100), 650] {
            window.setFrameOrigin(CGPoint(x: x, y: 100))
            view.refresh()
            guard let screen = window.screen, let image = view.imageView.image else {
                throw XCTSkip("Configured desktop image is unavailable")
            }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
            let expected = DesktopWallpaperView.imageFrame(image: image.size, desktop: screen.frame, scaling: scaling,
                clipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? false)
            let placed = window.convertToScreen(view.convert(view.imageView.frame, to: nil))
            XCTAssertEqual(placed, expected)
            XCTAssertNotNil(view.imageView.image)
            XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)))
        }
    }
}
