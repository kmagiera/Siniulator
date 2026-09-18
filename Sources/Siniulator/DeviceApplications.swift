import AppKit

@MainActor protocol DeviceApplications {
    func deviceHubApplication() async throws -> URL
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws
}

@MainActor struct SystemDeviceApplications: DeviceApplications {
    private static let deviceHubBundleID = "com.apple.dt.Devices"

    func deviceHubApplication() async throws -> URL {
        // Prefer the selected Xcode; LaunchServices may know several installations.
        if let data = try? await CommandRunner.run("/usr/bin/xcode-select", ["-p"]) {
            let developerDirectory = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = URL(fileURLWithPath: developerDirectory).deletingLastPathComponent()
                .appendingPathComponent("Applications/DeviceHub.app")
            if Bundle(url: candidate)?.bundleIdentifier == Self.deviceHubBundleID { return candidate }
        }
        if let candidate = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.deviceHubBundleID),
           Bundle(url: candidate)?.bundleIdentifier == Self.deviceHubBundleID { return candidate }
        throw SimulatorError(message: "Device Hub could not be found. Install or select an Xcode version that includes Device Hub.")
    }

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration)
    }
}
