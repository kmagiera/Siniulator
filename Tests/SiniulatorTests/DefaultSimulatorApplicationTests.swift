import AppKit
import XCTest
@testable import Siniulator

@MainActor private final class FakeDeviceApplications: DefaultDeviceApplications {
    let siniulator = URL(fileURLWithPath: "/Applications/Test Siniulator.app")
    var hub: URL? = URL(fileURLWithPath: "/Applications/Test DeviceHub.app")
    var current: URL?
    var changes: [URL] = []
    var changeError: Error?
    var updatesAssociation = true
    var beforeChange: (() async -> Void)?

    func defaultApplication() -> URL? { current }
    func deviceHubApplication() async throws -> URL {
        guard let hub else { throw SimulatorError(message: "Device Hub not found") }
        return hub
    }
    func setDefaultApplication(at url: URL) async throws {
        changes.append(url)
        await beforeChange?()
        if let changeError { throw changeError }
        if updatesAssociation { current = url }
    }
}

final class DefaultSimulatorApplicationTests: XCTestCase {
    @MainActor func testReadingStatusNeverChangesAssociationAndReflectsExternalChanges() {
        let system = FakeDeviceApplications()
        system.current = system.hub
        let model = DefaultSimulatorApplication(applicationURL: system.siniulator, applications: system)
        XCTAssertFalse(model.isDefault)
        XCTAssertEqual(model.currentApplicationURL, system.hub)
        system.current = system.siniulator
        model.refresh()
        XCTAssertTrue(model.isDefault)
        system.current = system.hub
        model.refresh()
        XCTAssertFalse(model.isDefault)
        XCTAssertTrue(system.changes.isEmpty)
    }

    @MainActor func testMakeDefaultPersistsInSystemAndCanSwitchBackToDeviceHub() async {
        let system = FakeDeviceApplications()
        system.current = system.hub
        let model = DefaultSimulatorApplication(applicationURL: system.siniulator, applications: system)
        await model.makeDefault()
        XCTAssertTrue(model.isDefault)
        XCTAssertNil(model.errorMessage)
        let nextLaunch = DefaultSimulatorApplication(applicationURL: system.siniulator, applications: system)
        XCTAssertTrue(nextLaunch.isDefault)
        await nextLaunch.useDeviceHub()
        XCTAssertFalse(nextLaunch.isDefault)
        XCTAssertEqual(system.current, system.hub)
        XCTAssertEqual(system.changes, [system.siniulator, system.hub!])
    }

    @MainActor func testDeniedAndUnappliedChangesReportFailureWithoutClaimingSuccess() async {
        for denied in [false, true] {
            let system = FakeDeviceApplications()
            system.current = system.hub
            if denied { system.changeError = SimulatorError(message: "Permission denied") }
            else { system.updatesAssociation = false }
            let model = DefaultSimulatorApplication(applicationURL: system.siniulator, applications: system)
            await model.makeDefault()
            XCTAssertFalse(model.isDefault)
            XCTAssertFalse(model.isBusy)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(system.current, system.hub)
            system.changeError = nil
            system.updatesAssociation = true
            await model.makeDefault()
            XCTAssertTrue(model.isDefault)
            XCTAssertNil(model.errorMessage)
        }
    }

    @MainActor func testRepeatedClickWhileAwaitingSystemConsentDoesNotRequestAgain() async {
        let system = FakeDeviceApplications()
        let waiting = expectation(description: "System is awaiting consent")
        var finish: CheckedContinuation<Void, Never>?
        system.beforeChange = { await withCheckedContinuation { finish = $0; waiting.fulfill() } }
        let model = DefaultSimulatorApplication(applicationURL: system.siniulator, applications: system)
        let change = Task { await model.makeDefault() }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertTrue(model.isBusy)
        await model.makeDefault()
        await model.useDeviceHub()
        XCTAssertEqual(system.changes, [system.siniulator])
        finish?.resume()
        await change.value
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.isDefault)
    }

    @MainActor func testMissingAppBundleOrDeviceHubDoesNotChangeAssociation() async {
        let system = FakeDeviceApplications()
        system.current = system.siniulator
        system.hub = nil
        let model = DefaultSimulatorApplication(applicationURL: nil, applications: system)
        await model.makeDefault()
        XCTAssertNotNil(model.errorMessage)
        await model.useDeviceHub()
        XCTAssertEqual(model.errorMessage, "Device Hub not found")
        XCTAssertTrue(system.changes.isEmpty)
    }

    @MainActor func testOpeningSettingsRefreshesDefaultWithoutChangingAssociation() async throws {
        _ = NSApplication.shared
        let system = FakeDeviceApplications()
        system.current = system.hub
        let model = DefaultSimulatorApplication(applicationURL: system.siniulator, applications: system)
        let domain = "app.siniulator.default-app-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = SettingsWindowController(settings: AppSettings(defaults: defaults), defaultApplication: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        XCTAssertEqual(model.currentApplicationURL, system.hub)
        XCTAssertTrue(system.changes.isEmpty)
        // Reopening Settings reflects changes made outside this application.
        system.current = system.siniulator
        controller.showWindow(nil)
        XCTAssertTrue(model.isDefault)
        XCTAssertTrue(system.changes.isEmpty)
    }
}
