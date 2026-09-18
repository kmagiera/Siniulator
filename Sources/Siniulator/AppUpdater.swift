import Combine
import Sparkle

/// Shares Sparkle's own preferences and availability with the settings window.
@MainActor final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    private var observers: Set<AnyCancellable> = []
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticUpdatesEnabled = true

    var isAvailable: Bool { controller != nil }

    init(controller: SPUStandardUpdaterController? = nil) {
        self.controller = controller
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticUpdatesEnabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observers)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .combineLatest(updater.publisher(for: \.automaticallyDownloadsUpdates))
            .receive(on: RunLoop.main)
            .sink { [weak self] checks, downloads in
                self?.automaticUpdatesEnabled = checks && downloads
            }
            .store(in: &observers)
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        // Sparkle persists these values; only change them after an explicit user action.
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
        automaticUpdatesEnabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
