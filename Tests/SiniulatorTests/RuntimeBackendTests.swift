import Foundation
import XCTest
@testable import Siniulator

final class RuntimeBackendTests: XCTestCase {
    func testCommandConsumesLargeInputWhileDrainingItsOutput() async throws {
        let input = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        let output = try await CommandRunner.run("/bin/cat", [], input: input)
        XCTAssertEqual(output, input)
    }

    func testCommandDrainsLargeStandardErrorIndependently() async throws {
        let output = try await CommandRunner.run("/bin/sh", ["-c",
            "dd if=/dev/zero bs=65536 count=8 1>&2 2>/dev/null; printf complete"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "complete")
    }

    func testCommandFailureWithoutDiagnosticIncludesExecutableAndExitStatus() async {
        do {
            _ = try await CommandRunner.run("/bin/sh", ["-c", "exit 7"])
            XCTFail("Expected a failed command")
        } catch {
            XCTAssertEqual(error.localizedDescription, "sh exited with status 7.")
        }
    }

    func testCommandDecodesDiagnosticEvenWhenItContainsInvalidUTF8() async {
        do {
            _ = try await CommandRunner.run("/bin/sh", ["-c", "printf 'failure: \\377\\n' >&2; exit 2"])
            XCTFail("Expected a failed command")
        } catch {
            XCTAssertEqual(error.localizedDescription, "failure: \u{FFFD}")
        }
    }

    func testDeviceOrderingUsesNumericRuntimeVersionsAndStableNameTies() {
        func device(_ id: String, name: String = "iPhone", state: String = "Shutdown") -> SimulatorDevice {
            SimulatorDevice(udid: id, name: name, state: state, isAvailable: true, deviceTypeIdentifier: nil)
        }
        let list = DeviceList(devices: [
            "com.apple.CoreSimulator.SimRuntime.iOS-9-0": [device("booted", state: "Booted"), device("old")],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [device("minor")],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [device("B"), device("A"),
                device("phone10", name: "iPhone 10"), device("phone2", name: "iPhone 2")]
        ])
        XCTAssertEqual(list.available.map(\.id), ["booted", "A", "B", "phone2", "phone10", "minor", "old"])
    }
}
