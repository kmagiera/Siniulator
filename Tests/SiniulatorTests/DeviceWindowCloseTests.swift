import AppKit
import XCTest
@testable import Siniulator

final class DeviceWindowCloseTests: XCTestCase {
    private let device = SimulatorDevice(udid: "siniulator-window-close-test", name: "iPhone", state: "Booted", isAvailable: true, deviceTypeIdentifier: nil)

    @MainActor private func settings() -> AppSettings {
        let domain = "app.siniulator.window-close-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return AppSettings(defaults: defaults)
    }

    @MainActor func testDefaultCloseWaitsForShutdownAndRepeatedCloseDoesNotDuplicateIt() async throws {
        _ = NSApplication.shared
        let shuttingDown = expectation(description: "Shutdown started")
        var finishShutdown: CheckedContinuation<Void, Never>?
        var commands: [[String]] = []
        var current = [device]
        let store = DeviceStore(fetchDevices: { current }, runSimctl: { arguments in
            commands.append(arguments)
            await withCheckedContinuation { finishShutdown = $0; shuttingDown.fulfill() }
            current = []
            return Data()
        })
        let controller = try DeviceWindowController(device: device, store: store,
            capturePreviews: CapturePreviewPresenter(), settings: settings())
        var closed = false
        controller.onClose = { closed = true }
        // Closing immediately also exercises cancellation before the boot task starts.
        controller.window?.performClose(nil)
        await fulfillment(of: [shuttingDown], timeout: 2)
        XCTAssertFalse(closed)
        XCTAssertTrue(controller.isClosing)
        controller.window?.performClose(nil)
        finishShutdown?.resume()
        await controller.waitForClose()
        XCTAssertTrue(closed)
        XCTAssertEqual(commands, [["shutdown", device.id]])
    }

    @MainActor func testOptOutAppliesToExistingWindowWithoutAnyDeviceCommand() async throws {
        _ = NSApplication.shared
        let settings = settings()
        let store = DeviceStore(fetchDevices: { [self.device] }, runSimctl: { _ in
            XCTFail("Closing with shutdown disabled must not send a device command")
            return Data()
        })
        let controller = try DeviceWindowController(device: device, store: store,
            capturePreviews: CapturePreviewPresenter(), settings: settings)
        settings.shutdownSimulatorOnWindowClose = false
        var closed = false
        controller.onClose = { closed = true }
        controller.window?.performClose(nil)
        await controller.waitForClose()
        XCTAssertTrue(closed)
        XCTAssertFalse(controller.isClosing)
    }

    @MainActor func testShutdownFailureKeepsWindowOpenAndCanBeRetried() async throws {
        _ = NSApplication.shared
        var attempts = 0
        var current = [device]
        let store = DeviceStore(fetchDevices: { current }, runSimctl: { _ in
            attempts += 1
            if attempts == 1 { throw SimulatorError(message: "Temporary shutdown failure") }
            current = []
            return Data()
        })
        let controller = try DeviceWindowController(device: device, store: store,
            capturePreviews: CapturePreviewPresenter(), settings: settings())
        var closed = false
        controller.onClose = { closed = true }
        let window = try XCTUnwrap(controller.window)
        window.performClose(nil)
        await controller.waitForClose()
        XCTAssertFalse(closed)
        XCTAssertFalse(controller.isClosing)
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet)
        sheet.orderOut(nil)
        window.performClose(nil)
        await controller.waitForClose()
        XCTAssertTrue(closed)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor func testExternalShutdownClosesViewerWithoutAnotherShutdown() async throws {
        _ = NSApplication.shared
        let store = DeviceStore(fetchDevices: { [] }, runSimctl: { _ in
            XCTFail("An external shutdown must only close the viewer")
            return Data()
        })
        let controller = try DeviceWindowController(device: device, store: store,
            capturePreviews: CapturePreviewPresenter(), settings: settings())
        var closed = false
        controller.onClose = { closed = true }
        await store.refresh()
        XCTAssertTrue(closed)
        XCTAssertFalse(controller.isClosing)
    }

    @MainActor func testShutdownSettingDefaultsOnAndPersistsOptOut() {
        let domain = "app.siniulator.window-close-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.shutdownSimulatorOnWindowClose)
        settings.shutdownSimulatorOnWindowClose = false
        XCTAssertFalse(AppSettings(defaults: defaults).shutdownSimulatorOnWindowClose)
        settings.shutdownSimulatorOnWindowClose = true
        XCTAssertTrue(AppSettings(defaults: defaults).shutdownSimulatorOnWindowClose)
    }
}
