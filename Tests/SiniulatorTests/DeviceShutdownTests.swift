import XCTest
@testable import Siniulator

final class DeviceShutdownTests: XCTestCase {
    private func device(_ state: String, id: String = "closing-device") -> SimulatorDevice {
        SimulatorDevice(udid: id, name: "iPhone", state: state, isAvailable: true, deviceTypeIdentifier: nil)
    }

    @MainActor func testShutdownTargetsOnlySelectedDevice() async throws {
        let selected = device("Booted"), other = device("Booted", id: "other-device")
        var current = [selected, other]
        var commands: [[String]] = []
        let store = DeviceStore(fetchDevices: { current }, runSimctl: { arguments in
            commands.append(arguments)
            current = [self.device("Shutdown"), other]
            return Data()
        })
        try await store.shutdown(selected)
        XCTAssertEqual(commands, [["shutdown", selected.id]])
        XCTAssertEqual(store.devices, [device("Shutdown"), other])
    }

    @MainActor func testShutdownSkipsStoppedStoppingAndDeletedDevices() async throws {
        for current in [[device("Shutdown")], [device("Shutting Down")], []] {
            let store = DeviceStore(fetchDevices: { current }, runSimctl: { _ in
                XCTFail("A stopped, stopping or deleted device does not need another shutdown")
                return Data()
            })
            try await store.shutdown(device("Booted"))
            XCTAssertEqual(store.devices, current)
        }
    }

    @MainActor func testShutdownWaitsForInFlightBoot() async throws {
        let booting = expectation(description: "Boot is in flight")
        var finishBoot: CheckedContinuation<Void, Never>?
        var current = device("Shutdown")
        var commands: [[String]] = []
        var bootFinished = false
        let store = DeviceStore(fetchDevices: { [current] }, runSimctl: { arguments in
            commands.append(arguments)
            switch arguments.first {
            case "boot": current = self.device("Booted")
            case "bootstatus":
                await withCheckedContinuation { finishBoot = $0; booting.fulfill() }
                bootFinished = true
            case "shutdown":
                XCTAssertTrue(bootFinished, "The pending boot must not restart a closed device")
                current = self.device("Shutdown")
            default: XCTFail("Unexpected command")
            }
            return Data()
        })
        let starting = Task { try await store.boot(current) }
        await fulfillment(of: [booting], timeout: 1)
        let closing = Task { try await store.shutdown(current) }
        await Task.yield()
        finishBoot?.resume()
        try await starting.value
        try await closing.value
        XCTAssertEqual(commands.map { $0[0] }, ["boot", "bootstatus", "shutdown"])
        XCTAssertEqual(store.devices.first?.state, "Shutdown")
    }

    @MainActor func testSimultaneousShutdownRequestsShareCommand() async throws {
        let shuttingDown = expectation(description: "Shutdown is in flight")
        var finishShutdown: CheckedContinuation<Void, Never>?
        let booted = device("Booted")
        var commandCount = 0
        // Keep the fake snapshot booted to ensure duplicate prevention comes from
        // sharing the in-flight operation rather than skipping a stopped device.
        let store = DeviceStore(fetchDevices: { [booted] }, runSimctl: { _ in
            commandCount += 1
            await withCheckedContinuation { finishShutdown = $0; shuttingDown.fulfill() }
            return Data()
        })
        let first = Task { try await store.shutdown(booted) }
        await fulfillment(of: [shuttingDown], timeout: 1)
        let joined = expectation(description: "Second request queued")
        let second = Task { joined.fulfill(); try await store.shutdown(booted) }
        await fulfillment(of: [joined], timeout: 1)
        finishShutdown?.resume()
        try await first.value
        try await second.value
        XCTAssertEqual(commandCount, 1)
    }

    @MainActor func testCommandFailureIsIgnoredOnlyIfDeviceStoppedExternally() async throws {
        for externalShutdown in [false, true] {
            var current = device("Booted")
            let store = DeviceStore(fetchDevices: { [current] }, runSimctl: { _ in
                if externalShutdown { current = self.device("Shutdown") }
                throw SimulatorError(message: "Shutdown failed")
            })
            do {
                try await store.shutdown(current)
                XCTAssertTrue(externalShutdown, "A real failure must reach the window")
            } catch {
                XCTAssertFalse(externalShutdown)
                XCTAssertEqual(error.localizedDescription, "Shutdown failed")
            }
        }
    }
}
