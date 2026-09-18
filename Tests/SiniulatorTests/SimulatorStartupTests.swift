import XCTest
@testable import Siniulator

final class SimulatorStartupTests: XCTestCase {
    @MainActor private func settings() -> AppSettings {
        let domain = "app.siniulator.startup-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return AppSettings(defaults: defaults)
    }

    private func device(_ id: String, state: String = "Shutdown", available: Bool = true) -> SimulatorDevice {
        SimulatorDevice(udid: id, name: id, state: state, isAvailable: available, deviceTypeIdentifier: nil)
    }

    @MainActor func testStartupUsesSavedDeviceBeforeRunningWindowsChangeRecency() {
        let settings = settings()
        settings.mostRecentSimulatorID = "recent"
        let capturedID = settings.mostRecentSimulatorID
        // Mirroring another already-running window must not change the startup selection.
        settings.mostRecentSimulatorID = "running"
        let devices = [device("running", state: "Booted"), device("recent")]
        XCTAssertEqual(settings.simulatorToOpenOnStart(in: devices, mostRecentID: capturedID,
            hasExplicitDeviceRequest: false)?.id, "recent")
    }

    @MainActor func testOptOutAndExplicitLinksPreventOpeningSavedDevice() {
        let settings = settings()
        let devices = [device("recent")]
        XCTAssertNil(settings.simulatorToOpenOnStart(in: devices, mostRecentID: "recent",
            hasExplicitDeviceRequest: true))
        settings.bootMostRecentSimulatorOnStart = false
        XCTAssertNil(settings.simulatorToOpenOnStart(in: devices, mostRecentID: "recent",
            hasExplicitDeviceRequest: false))
    }

    @MainActor func testMissingUnavailableAndTransitioningDevicesDoNotBootAnotherDevice() {
        let settings = settings()
        XCTAssertNil(settings.simulatorToOpenOnStart(in: [device("other")], mostRecentID: nil,
            hasExplicitDeviceRequest: false))
        XCTAssertNil(settings.simulatorToOpenOnStart(in: [device("other")], mostRecentID: "deleted",
            hasExplicitDeviceRequest: false))
        for candidate in [device("recent", available: false), device("recent", state: "Booting"),
                          device("recent", state: "Shutting Down")] {
            XCTAssertNil(settings.simulatorToOpenOnStart(in: [candidate, device("other")], mostRecentID: "recent",
                hasExplicitDeviceRequest: false))
        }
        XCTAssertEqual(settings.simulatorToOpenOnStart(in: [device("recent", state: "Booted")],
            mostRecentID: "recent", hasExplicitDeviceRequest: false)?.id, "recent")
    }

    @MainActor func testDefaultsAndSavedLifetimePreferencesSurviveNewSettingsInstance() {
        let domain = "app.siniulator.startup-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.bootMostRecentSimulatorOnStart)
        XCTAssertFalse(settings.leaveSimulatorRunningAfterWindowClose)
        defaults.set(false, forKey: "shutdownSimulatorOnWindowClose")
        defaults.set("existing-device", forKey: "lastDevice")
        XCTAssertTrue(settings.leaveSimulatorRunningAfterWindowClose)
        XCTAssertEqual(settings.mostRecentSimulatorID, "existing-device")
        settings.bootMostRecentSimulatorOnStart = false
        settings.leaveSimulatorRunningAfterWindowClose = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.bootMostRecentSimulatorOnStart)
        XCTAssertTrue(reloaded.shutdownSimulatorOnWindowClose)
    }
}
