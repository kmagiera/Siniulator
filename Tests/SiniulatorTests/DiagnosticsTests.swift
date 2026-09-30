#if DEBUG
import XCTest
@testable import Siniulator

final class DiagnosticsTests: XCTestCase {
    @MainActor func testOrdinaryPresentationChecksExcludeDuoAndShutdownDevices() throws {
        let duo = SimulatorDevice(udid: "diagnostics-duo", name: "iPhone Duo", state: "Booted", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard !DeviceChrome.displayModes(for: duo).isEmpty else { throw XCTSkip("Duo profile not installed") }
        let phone = SimulatorDevice(udid: "diagnostics-phone", name: "iPhone", state: "Booted", isAvailable: true,
            deviceTypeIdentifier: nil, runtime: duo.runtime)
        let stopped = SimulatorDevice(udid: "diagnostics-stopped", name: "iPhone", state: "Shutdown", isAvailable: true,
            deviceTypeIdentifier: nil, runtime: duo.runtime)
        XCTAssertEqual(Diagnostics.ordinaryPresentationDevices(in: [duo, stopped, phone]).map(\.id), [phone.id])
        XCTAssertTrue(Diagnostics.ordinaryPresentationDevices(in: [duo, stopped]).isEmpty)
    }
}
#endif
