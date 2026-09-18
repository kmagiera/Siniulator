import Foundation

@MainActor final class AppSettings {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var bootMostRecentSimulatorOnStart: Bool {
        get { defaults.object(forKey: "bootMostRecentSimulatorOnStart") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "bootMostRecentSimulatorOnStart") }
    }

    var mostRecentSimulatorID: String? {
        get { defaults.string(forKey: "lastDevice") }
        set { defaults.set(newValue, forKey: "lastDevice") }
    }

    var leaveSimulatorRunningAfterWindowClose: Bool {
        get { !shutdownSimulatorOnWindowClose }
        set { shutdownSimulatorOnWindowClose = !newValue }
    }

    // Retain the existing storage key so changing the label doesn't invert saved preferences.
    var shutdownSimulatorOnWindowClose: Bool {
        get { defaults.object(forKey: "shutdownSimulatorOnWindowClose") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shutdownSimulatorOnWindowClose") }
    }

    func simulatorToOpenOnStart(in devices: [SimulatorDevice], mostRecentID: String?,
                                hasExplicitDeviceRequest: Bool) -> SimulatorDevice? {
        guard bootMostRecentSimulatorOnStart, !hasExplicitDeviceRequest, let mostRecentID else { return nil }
        return devices.first { $0.id == mostRecentID && $0.isAvailable && ($0.state == "Shutdown" || $0.isBooted) }
    }
}
