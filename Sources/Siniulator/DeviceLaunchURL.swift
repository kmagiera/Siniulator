import Foundation

enum DeviceLaunchURL {
    enum Destination: Equatable {
        case simulator(SimulatorDevice)
        case deviceHub(URL)
    }

    static func deviceID(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased() ?? ""
        let route = (host.isEmpty ? "" : "/" + host) + components.path
        let isOwn = scheme == "siniulator" && host == "open" && ["", "/"].contains(components.path)
        let isDeviceHub = scheme == "devices" && ["/device/open", "/manage/select"].contains(route)
        guard isOwn || isDeviceHub else { return nil }
        let key = isOwn ? "udid" : "id"
        // Extra parameters may request behavior that only Device Hub understands.
        guard let items = components.queryItems, items.count == 1, items[0].name == key,
              let id = items[0].value, let uuid = UUID(uuidString: id) else { return nil }
        return uuid.uuidString
    }

    static func destination(for url: URL, devices: [SimulatorDevice]) throws -> Destination {
        if let id = deviceID(in: url),
           let device = devices.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame && $0.isAvailable }),
           device.runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") {
            return .simulator(device)
        }
        // Forward the complete URL, including unknown actions and physical-device IDs.
        if url.scheme?.lowercased() == "devices" { return .deviceHub(url) }
        throw SimulatorError(message: "This link does not identify an available iOS simulator.")
    }
}

@MainActor struct DeviceURLRouter {
    var applications: any DeviceApplications = SystemDeviceApplications()

    func open(_ url: URL, devices: [SimulatorDevice], openSimulator: (SimulatorDevice) -> Void) async throws {
        switch try DeviceLaunchURL.destination(for: url, devices: devices) {
        case .simulator(let device): openSimulator(device)
        case .deviceHub(let originalURL):
            // Target Device Hub explicitly; reopening through the default handler
            // would route back to Siniulator when it owns the devices scheme.
            let applicationURL = try await applications.deviceHubApplication()
            try await applications.open([originalURL], withApplicationAt: applicationURL)
        }
    }
}
