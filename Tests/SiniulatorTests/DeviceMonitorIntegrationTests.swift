import AppKit
import Combine
import XCTest
@testable import Siniulator

final class DeviceMonitorIntegrationTests: XCTestCase {
    // Opt in with compatible, installed identifiers. The test creates and deletes only its own device.
    // SINIULATOR_TEST_RUNTIME=... SINIULATOR_TEST_DEVICE_TYPE=... swift test --filter DeviceMonitorIntegrationTests
    @MainActor func testExternalDeviceLifecyclePublishesWithoutManualRefresh() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let runtime = environment["SINIULATOR_TEST_RUNTIME"],
              let deviceType = environment["SINIULATOR_TEST_DEVICE_TYPE"] else {
            throw XCTSkip("Set SINIULATOR_TEST_RUNTIME and SINIULATOR_TEST_DEVICE_TYPE to test a real CoreSimulator service")
        }
        let subscribed = expectation(description: "CoreSimulator subscription established")
        let initial = expectation(description: "Initial snapshot loaded")
        var firstSnapshot = true
        let store = DeviceStore(fetchDevices: {
            let data = try await CommandRunner.simctl(["list", "devices", "--json"])
            let devices = try JSONDecoder().decode(DeviceList.self, from: data).available
            if firstSnapshot { firstSnapshot = false; initial.fulfill() }
            return devices
        }, makeMonitor: { change, invalidate in
            let monitor = try await CoreSimulatorConnection.monitor(changeHandler: change, invalidationHandler: invalidate)
            subscribed.fulfill()
            return monitor
        })
        store.start()
        defer { store.stop() }
        await fulfillment(of: [subscribed, initial], timeout: 15)
        let name = "Siniulator Notification QA \(UUID().uuidString)"
        var deviceID: String?

        func cleanup() async {
            guard let deviceID else { return }
            _ = try? await CommandRunner.simctl(["shutdown", deviceID])
            _ = try? await CommandRunner.simctl(["delete", deviceID])
        }

        do {
            try await observe(store, "Device created", matching: { $0.contains { $0.name == name } }) {
                let data = try await CommandRunner.simctl(["create", name, deviceType, runtime])
                deviceID = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let id = try XCTUnwrap(deviceID)
            try await observe(store, "Device renamed", matching: { $0.contains { $0.id == id && $0.name == name + " renamed" } }) {
                _ = try await CommandRunner.simctl(["rename", id, name + " renamed"])
            }
            try await observe(store, "Device booted", timeout: 60, matching: { $0.contains { $0.id == id && $0.isBooted } }) {
                _ = try await CommandRunner.simctl(["boot", id])
            }
            _ = NSApplication.shared
            let device = try XCTUnwrap(store.devices.first { $0.id == id })
            let domain = "app.siniulator.integration-tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = AppSettings(defaults: defaults)
            let previews = CapturePreviewPresenter()

            let keepRunning = try DeviceWindowController(device: device, store: store,
                capturePreviews: previews, settings: settings)
            settings.shutdownSimulatorOnWindowClose = false
            var viewerClosed = false
            keepRunning.onClose = { viewerClosed = true }
            keepRunning.window?.performClose(nil)
            await keepRunning.waitForClose()
            XCTAssertTrue(viewerClosed)
            let afterClose = try await CommandRunner.simctl(["list", "devices", "--json"])
            XCTAssertTrue(try JSONDecoder().decode(DeviceList.self, from: afterClose).available
                .contains { $0.id == id && $0.isBooted }, "Opting out must leave the real simulator running")

            settings.shutdownSimulatorOnWindowClose = true
            let shutDown = try DeviceWindowController(device: device, store: store,
                capturePreviews: previews, settings: settings)
            var shutdownWindowClosed = false
            shutDown.onClose = { shutdownWindowClosed = true }
            try await observe(store, "Window closed and device shut down", timeout: 30,
                              matching: { $0.contains { $0.id == id && $0.state == "Shutdown" } }) {
                shutDown.window?.performClose(nil)
                await shutDown.waitForClose()
            }
            XCTAssertTrue(shutdownWindowClosed)

            try await observe(store, "Device rebooted", timeout: 60, matching: { $0.contains { $0.id == id && $0.isBooted } }) {
                _ = try await CommandRunner.simctl(["boot", id])
            }
            try await observe(store, "Device shut down", timeout: 30, matching: { $0.contains { $0.id == id && $0.state == "Shutdown" } }) {
                _ = try await CommandRunner.simctl(["shutdown", id])
            }
            try await observe(store, "Device deleted", matching: { !$0.contains { $0.id == id } }) {
                _ = try await CommandRunner.simctl(["delete", id])
            }
            deviceID = nil
            XCTAssertNil(store.error)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @MainActor private func observe(_ store: DeviceStore, _ description: String, timeout: TimeInterval = 15,
                                   matching predicate: @escaping ([SimulatorDevice]) -> Bool,
                                   action: () async throws -> Void) async throws {
        let received = expectation(description: description)
        let subscription = store.$devices.filter(predicate).prefix(1).sink { _ in received.fulfill() }
        defer { subscription.cancel() }
        try await action()
        await fulfillment(of: [received], timeout: timeout)
        XCTAssertTrue(predicate(store.devices), description)
    }
}
