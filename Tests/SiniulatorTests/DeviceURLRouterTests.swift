import AppKit
import XCTest
@testable import Siniulator

@MainActor private final class FakeDeviceApplications: DeviceApplications {
    var hub: URL? = URL(fileURLWithPath: "/Applications/Test DeviceHub.app")
    var opened: [(urls: [URL], application: URL)] = []

    func deviceHubApplication() async throws -> URL {
        guard let hub else { throw SimulatorError(message: "Device Hub not found") }
        return hub
    }

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        opened.append((urls, applicationURL))
    }
}

final class DeviceURLRouterTests: XCTestCase {
    @MainActor func testSupportedSimulatorURLsStayInSiniulator() async throws {
        let system = FakeDeviceApplications()
        let router = DeviceURLRouter(applications: system)
        let id = UUID().uuidString
        var device = SimulatorDevice(udid: id, name: "iPhone", state: "Shutdown", isAvailable: true, deviceTypeIdentifier: nil)
        device.runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        for link in ["siniulator://open?udid=\(id)", "devices://device/open?id=\(id)",
                     "devices:///device/open?id=\(id)", "devices://manage/select?id=\(id)",
                     "devices:///manage/select?id=\(id.lowercased())"] {
            var selected: SimulatorDevice?
            try await router.open(URL(string: link)!, devices: [device]) { selected = $0 }
            XCTAssertEqual(selected, device, link)
        }
        XCTAssertTrue(system.opened.isEmpty)
    }

    @MainActor func testOtherDeviceURLsAreForwardedUnmodifiedToExplicitDeviceHub() async throws {
        let system = FakeDeviceApplications()
        // Forward explicitly to Device Hub to avoid looping through the default handler.
        let router = DeviceURLRouter(applications: system)
        let id = UUID().uuidString
        var unsupported = SimulatorDevice(udid: id, name: "Apple TV", state: "Booted", isAvailable: true, deviceTypeIdentifier: nil)
        unsupported.runtime = "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"
        let links = ["devices://device/open?id=\(id)", "devices://device/open?id=00008110-000123ABC",
                     "devices:///manage", "devices:///delete?id=\(id)", "devices://unknown?text=a%20b#section",
                     "devices://device/open?id=\(UUID().uuidString)", "devices://manage/select?id=\(id)&action=pair"]
        for link in links {
            let url = URL(string: link)!
            try await router.open(url, devices: [unsupported]) { _ in XCTFail("Unsupported URL must go to Device Hub") }
            XCTAssertEqual(system.opened.last?.urls, [url])
            XCTAssertEqual(system.opened.last?.application, system.hub)
        }
        XCTAssertEqual(system.opened.count, links.count)
    }

    @MainActor func testInvalidOwnURLsAndMissingDeviceHubReportErrorWithoutForwardingLoop() async {
        let system = FakeDeviceApplications()
        system.hub = nil
        let router = DeviceURLRouter(applications: system)
        for link in ["siniulator://open?udid=invalid", "siniulator://open?udid=\(UUID().uuidString)", "devices:///manage"] {
            do {
                try await router.open(URL(string: link)!, devices: []) { _ in XCTFail("Unexpected simulator") }
                XCTFail("Expected unavailable device or application error")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        XCTAssertTrue(system.opened.isEmpty)
    }

    func testBundleRegistersBothLaunchSchemes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("siniulator"))
        XCTAssertTrue(schemes.contains("devices"))
    }
}
