import AppKit
import Combine

@MainActor protocol DefaultDeviceApplications {
    func defaultApplication() -> URL?
    func deviceHubApplication() async throws -> URL
    func setDefaultApplication(at url: URL) async throws
}

extension SystemDeviceApplications: DefaultDeviceApplications {
    static let siniulatorBundleID = "app.siniulator.Siniulator"

    static var mainApplicationURL: URL? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier == siniulatorBundleID else { return nil }
        return bundle.bundleURL
    }

    func defaultApplication() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "devices://")!)
    }

    func setDefaultApplication(at url: URL) async throws {
        // LaunchServices handles the association and any system confirmation.
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "devices")
    }
}

@MainActor final class DefaultSimulatorApplication: ObservableObject {
    @Published private(set) var currentApplicationURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    let applicationURL: URL?
    private let applications: any DefaultDeviceApplications

    init(applicationURL: URL? = SystemDeviceApplications.mainApplicationURL,
         applications: any DefaultDeviceApplications = SystemDeviceApplications()) {
        self.applicationURL = applicationURL
        self.applications = applications
        refresh()
    }

    var isDefault: Bool {
        guard let currentApplicationURL else { return false }
        return currentApplicationURL.resolvingSymlinksInPath() == applicationURL?.resolvingSymlinksInPath()
            || Bundle(url: currentApplicationURL)?.bundleIdentifier == SystemDeviceApplications.siniulatorBundleID
    }

    func refresh() { currentApplicationURL = applications.defaultApplication() }

    func makeDefault() async {
        guard !isBusy else { return }
        guard let applicationURL else {
            errorMessage = "Run Siniulator.app to set it as the default application."
            return
        }
        await changeDefault { applicationURL }
    }

    func useDeviceHub() async {
        guard !isBusy else { return }
        await changeDefault { try await self.applications.deviceHubApplication() }
    }

    private func changeDefault(to resolveApplication: () async throws -> URL) async {
        isBusy = true
        errorMessage = nil
        defer { refresh(); isBusy = false }
        do {
            let target = try await resolveApplication()
            try await applications.setDefaultApplication(at: target)
            refresh()
            let selectedID = currentApplicationURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
            let targetID = Bundle(url: target)?.bundleIdentifier
            guard currentApplicationURL?.resolvingSymlinksInPath() == target.resolvingSymlinksInPath()
                    || (targetID != nil && selectedID == targetID) else {
                throw SimulatorError(message: "macOS did not change the default application. Try again and allow the change if macOS asks.")
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
