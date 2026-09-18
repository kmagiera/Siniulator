import AppKit
import XCTest
@testable import Siniulator

final class ScreenshotTests: XCTestCase {
    func testSaveAsReplacesExistingFileAndPreservesTheDragSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let destination = directory.appendingPathComponent("saved.png")
        let data = Data([1, 2, 3])
        try data.write(to: source)
        try Data([4, 5, 6]).write(to: destination)
        try CaptureFile(temporaryURL: source, kind: .screenshot).save(to: destination)
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testFailedSaveAsPreservesTheExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("saved.png")
        let original = Data([4, 5, 6])
        try original.write(to: destination)
        let missing = directory.appendingPathComponent("missing.png")
        XCTAssertThrowsError(try CaptureFile(temporaryURL: missing, kind: .screenshot).save(to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testSaveAsCreatesNewFileAndCanKeepItsOriginalLocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let destination = directory.appendingPathComponent("saved.png")
        let data = Data([1, 2, 3])
        try data.write(to: source)
        let file = CaptureFile(temporaryURL: source, kind: .screenshot)
        try file.save(to: destination)
        try file.save(to: source)
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testSimulatorFilenameUsesLocalTimeAndSafeDeviceName() {
        let date = ISO8601DateFormatter().date(from: "2026-09-17T19:52:17Z")!
        XCTAssertEqual(CaptureFile.filename(deviceName: "iPhone 18 Pro Max", date: date, timeZone: TimeZone(secondsFromGMT: 7200)!),
            "Simulator Screenshot - iPhone 18 Pro Max - 2026-09-17 at 21.52.17.png")
        XCTAssertFalse(CaptureFile.filename(deviceName: "My Phone / QA: One", date: date).contains("/"))
    }

    func testSavingSameSecondScreenshotsPreservesBothAndTheirDragSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_789_674_737)
        let first = try CaptureFile.stage(Data([1, 2, 3]), deviceName: "iPhone", date: date)
        let second = try CaptureFile.stage(Data([4, 5, 6]), deviceName: "iPhone", date: date)
        defer {
            try? FileManager.default.removeItem(at: first.temporaryURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.temporaryURL.deletingLastPathComponent())
        }
        let firstSaved = try first.save(in: directory)
        let secondSaved = try second.save(in: directory)
        XCTAssertEqual(firstSaved.lastPathComponent, first.temporaryURL.lastPathComponent)
        XCTAssertNotEqual(firstSaved, secondSaved)
        XCTAssertEqual(try Data(contentsOf: firstSaved), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: secondSaved), Data([4, 5, 6]))
        XCTAssertEqual(try Data(contentsOf: first.temporaryURL), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second.temporaryURL), Data([4, 5, 6]))
    }

    func testPNGPreservesRectangularFramebufferIncludingCornerPixels() throws {
        for (width, height) in [(80, 160), (160, 80)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
            let source = try XCTUnwrap(context.makeImage())
            let data = try ScreenshotImage.png(source)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data))
            let original = NSBitmapImageRep(cgImage: source)
            XCTAssertEqual(png.pixelsWide, width)
            XCTAssertEqual(png.pixelsHigh, height)
            for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
                let before = try XCTUnwrap(original.colorAt(x: x, y: y))
                let after = try XCTUnwrap(png.colorAt(x: x, y: y))
                XCTAssertEqual(after.alphaComponent, 1)
                XCTAssertEqual(after.redComponent, before.redComponent, accuracy: 0.001)
                XCTAssertEqual(after.blueComponent, before.blueComponent, accuracy: 0.001)
            }
            for y in [height / 4, height * 3 / 4] {
                let before = try XCTUnwrap(original.colorAt(x: width / 2, y: y))
                let after = try XCTUnwrap(png.colorAt(x: width / 2, y: y))
                XCTAssertEqual(after.alphaComponent, 1)
                XCTAssertEqual(after.redComponent, before.redComponent, accuracy: 0.001)
                XCTAssertEqual(after.blueComponent, before.blueComponent, accuracy: 0.001)
            }
        }
    }

    func testPreviewStaysBesideWindowAndFitsRightLeftAndSecondaryDisplay() {
        let size = CGSize(width: 104, height: 200)
        let display = CGRect(x: 0, y: 0, width: 3008, height: 1662)
        let window = CGRect(x: 100, y: 100, width: 400, height: 900)
        let right = CapturePreviewLayout.frame(size: size, beside: window, visibleFrame: display)
        XCTAssertEqual(right.minX + CapturePreviewLayout.shadowInset + CapturePreviewLayout.bezelWidth, window.maxX + CapturePreviewLayout.gap)
        XCTAssertEqual(right.minY, window.minY)
        XCTAssertTrue(display.contains(right))
        let edgeWindow = CGRect(x: 2600, y: 100, width: 400, height: 900)
        let left = CapturePreviewLayout.frame(size: size, beside: edgeWindow, visibleFrame: display)
        XCTAssertEqual(left.maxX - CapturePreviewLayout.shadowInset - CapturePreviewLayout.bezelWidth, edgeWindow.minX - CapturePreviewLayout.gap)
        XCTAssertTrue(display.contains(left))
        let secondary = CGRect(x: 668, y: -982, width: 1512, height: 949)
        let secondaryWindow = CGRect(x: 740, y: -970, width: 700, height: 930)
        XCTAssertTrue(secondary.contains(CapturePreviewLayout.frame(size: size, beside: secondaryWindow, visibleFrame: secondary)))
        // A window may briefly retain coordinates from a disconnected monitor.
        XCTAssertTrue(display.contains(CapturePreviewLayout.frame(size: size,
            beside: CGRect(x: 4000, y: -2000, width: 400, height: 900), visibleFrame: display)))
    }

    func testPreviewMatchesMeasuredSimulatorScreenshotsAtTwoWindowSizes() {
        // Point coordinates measured from the two Retina reference screenshots.
        // Expected rectangles describe captured pixels, excluding the black bezel.
        let cases: [(device: CGRect, screen: CGRect, header: CGRect, expected: CGRect)] = [
            (CGRect(x: 71, y: 76.5, width: 655, height: 1373),
             CGRect(x: 93.5, y: 99, width: 611, height: 1328),
             CGRect(x: 57, y: 1463, width: 684, height: 52),
             CGRect(x: 757, y: 93, width: 153, height: 332)),
            (CGRect(x: 65, y: 75.5, width: 367, height: 770),
             CGRect(x: 77, y: 88.5, width: 343, height: 745),
             CGRect(x: 56, y: 858, width: 384, height: 52),
             CGRect(x: 456, y: 87, width: 86, height: 187))
        ]
        for item in cases {
            let card = CapturePreviewLayout.cardSize(imageSize: CGSize(width: 1320, height: 2868), displayedScreenSize: item.screen.size)
            let frame = CapturePreviewLayout.frame(size: CGSize(width: card.width + 24, height: card.height + 24),
                beside: item.device.union(item.header), visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1700),
                bottom: CapturePreviewLayout.bottom(device: item.device, screen: item.screen))
            let pixels = frame.insetBy(dx: 15, dy: 15)
            XCTAssertEqual(pixels.minX, item.expected.minX, accuracy: 0.5)
            XCTAssertEqual(pixels.minY, item.expected.minY, accuracy: 0.5)
            XCTAssertEqual(pixels.width, item.expected.width, accuracy: 0.5)
            XCTAssertEqual(pixels.height, item.expected.height, accuracy: 1)
            XCTAssertEqual(pixels.width / pixels.height, 1320.0 / 2868.0, accuracy: 0.0001)
        }
    }

    @MainActor func testPreviewDismissalRefreshesHoverStateAfterMovingBetweenPanels() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let pointer = NSEvent.mouseLocation
        let panel = NSPanel(contentRect: CGRect(x: pointer.x + 1_000, y: pointer.y + 1_000, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        defer { panel.close() }
        let preview = CaptureThumbnail(image: image, fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview.png"),
            kind: .screenshot, cornerRadius: 0)
        preview.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
        panel.contentView?.addSubview(preview)
        let trackingEvent = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        preview.mouseEntered(with: trackingEvent)
        XCTAssertFalse(preview.bounds.contains(preview.convert(panel.mouseLocationOutsideOfEventStream, from: nil)))

        preview.completePresentation()
        for _ in 0..<550 where !preview.isFinished {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(preview.isFinished, "A stale hover from the animation panel prevented automatic dismissal")
    }
}
