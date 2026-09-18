import Combine
import XCTest
@testable import Siniulator

@MainActor private final class FakeDeviceMonitor: DeviceMonitoring {
    let change: () -> Void
    let invalidate: (String) -> Void
    var onStop: (() -> Void)?
    var isStopped = false

    init(change: @escaping () -> Void, invalidate: @escaping (String) -> Void) {
        self.change = change
        self.invalidate = invalidate
    }
    func stop() {
        isStopped = true
        onStop?()
    }
}

final class DeviceStoreTests: XCTestCase {
    private let shutdown = SimulatorDevice(udid: "test-device", name: "iPhone", state: "Shutdown", isAvailable: true, deviceTypeIdentifier: nil)
    private let booted = SimulatorDevice(udid: "test-device", name: "iPhone", state: "Booted", isAvailable: true, deviceTypeIdentifier: nil)

    @MainActor func testSubscribesBeforeSnapshotAndDoesNotPoll() async throws {
        var subscriptions = 0
        var snapshots = 0
        let loaded = expectation(description: "Initial snapshot")
        let store = DeviceStore(fetchDevices: {
            XCTAssertEqual(subscriptions, 1)
            snapshots += 1
            loaded.fulfill()
            return []
        }, makeMonitor: { change, invalidate in
            subscriptions += 1
            return FakeDeviceMonitor(change: change, invalidate: invalidate)
        })
        defer { store.stop() }
        store.start()
        store.start()
        await fulfillment(of: [loaded], timeout: 1)
        try await Task.sleep(for: .milliseconds(4200))
        XCTAssertEqual(subscriptions, 1)
        XCTAssertEqual(snapshots, 1, "A healthy idle subscription must not poll simctl")
    }

    @MainActor func testChangeDuringSnapshotIsNotLostAndBurstIsCoalesced() async throws {
        let firstRead = expectation(description: "First snapshot in flight")
        let updated = expectation(description: "Booted snapshot published")
        var finishFirstRead: CheckedContinuation<[SimulatorDevice], Never>?
        var monitor: FakeDeviceMonitor?
        var snapshots = 0
        let store = DeviceStore(fetchDevices: {
            snapshots += 1
            if snapshots == 1 {
                return await withCheckedContinuation {
                    finishFirstRead = $0
                    firstRead.fulfill()
                }
            }
            return [self.booted]
        }, makeMonitor: { change, invalidate in
            let result = FakeDeviceMonitor(change: change, invalidate: invalidate)
            monitor = result
            return result
        })
        defer { store.stop() }
        let subscription = store.$devices.filter { $0.first?.isBooted == true }.prefix(1).sink { _ in updated.fulfill() }
        defer { subscription.cancel() }
        store.start()
        await fulfillment(of: [firstRead], timeout: 1)
        for _ in 0..<20 { monitor?.change() }
        // Let the queued notifications reach the main actor while the first read is suspended.
        let delivered = expectation(description: "Notifications delivered")
        Task { @MainActor in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 1)
        finishFirstRead?.resume(returning: [shutdown])
        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(store.devices, [booted])
    }

    @MainActor func testInvalidationReconnectsAndResynchronizes() async throws {
        let initial = expectation(description: "Initial snapshot")
        let reconnected = expectation(description: "Snapshot after reconnection")
        var monitors: [FakeDeviceMonitor] = []
        var snapshots = 0
        let store = DeviceStore(fetchDevices: {
            snapshots += 1
            if snapshots == 1 { initial.fulfill(); return [self.shutdown] }
            reconnected.fulfill()
            return [self.booted]
        }, makeMonitor: { change, invalidate in
            let monitor = FakeDeviceMonitor(change: change, invalidate: invalidate)
            monitors.append(monitor)
            return monitor
        })
        defer { store.stop() }
        store.start()
        await fulfillment(of: [initial], timeout: 1)
        monitors[0].invalidate("Test disconnection")
        await fulfillment(of: [reconnected], timeout: 3)
        XCTAssertEqual(monitors.count, 2)
        XCTAssertTrue(monitors[0].isStopped)
        XCTAssertEqual(store.devices, [booted])
        XCTAssertNil(store.error)

        store.stop()
        let noMoreSnapshots = snapshots
        // Native callbacks already queued at stop or reconnect must be ignored.
        monitors[0].change()
        monitors[0].invalidate("Late invalidation")
        monitors[1].change()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(snapshots, noMoreSnapshots)
        XCTAssertTrue(monitors[1].isStopped)
    }

    @MainActor func testFailedSubscriptionKeepsSnapshotAndErrorThenRetries() async throws {
        let initial = expectation(description: "Snapshot despite subscription failure")
        let recovered = expectation(description: "Snapshot after successful retry")
        var attempts = 0
        let store = DeviceStore(fetchDevices: {
            if attempts == 1 { initial.fulfill() } else { recovered.fulfill() }
            return [self.shutdown]
        }, makeMonitor: { change, invalidate in
            attempts += 1
            if attempts == 1 { throw SimulatorError(message: "Service unavailable") }
            return FakeDeviceMonitor(change: change, invalidate: invalidate)
        })
        defer { store.stop() }
        store.start()
        await fulfillment(of: [initial], timeout: 1)
        XCTAssertEqual(store.devices, [shutdown])
        XCTAssertTrue(store.error?.contains("Service unavailable") == true)
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(store.error)
    }

    @MainActor func testTransientSnapshotFailureRetriesWithoutAnotherDeviceEvent() async throws {
        let recovered = expectation(description: "Snapshot recovered without another notification")
        var snapshots = 0
        var subscriptions = 0
        let store = DeviceStore(fetchDevices: {
            snapshots += 1
            if snapshots == 1 { throw SimulatorError(message: "Transient simctl failure") }
            recovered.fulfill()
            return [self.booted]
        }, makeMonitor: { change, invalidate in
            subscriptions += 1
            return FakeDeviceMonitor(change: change, invalidate: invalidate)
        })
        defer { store.stop() }
        store.start()
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(subscriptions, 1)
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(store.devices, [booted])
        XCTAssertNil(store.error)
    }

    @MainActor func testStopDuringSubscriptionDisposesLateConnection() async throws {
        let connecting = expectation(description: "Subscription in flight")
        let stopped = expectation(description: "Late connection stopped")
        var finishConnection: CheckedContinuation<DeviceMonitoring, Never>?
        let monitor = FakeDeviceMonitor(change: {}, invalidate: { _ in })
        monitor.onStop = { stopped.fulfill() }
        let store = DeviceStore(fetchDevices: {
            XCTFail("A stopped store must not fetch a snapshot")
            return []
        }, makeMonitor: { _, _ in
            await withCheckedContinuation {
                finishConnection = $0
                connecting.fulfill()
            }
        })
        store.start()
        await fulfillment(of: [connecting], timeout: 1)
        store.stop()
        finishConnection?.resume(returning: monitor)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(monitor.isStopped)
    }
}
