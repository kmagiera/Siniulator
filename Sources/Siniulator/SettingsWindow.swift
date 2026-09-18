import AppKit
import SwiftUI

@MainActor final class SettingsWindowController: NSWindowController {
    private let defaultApplication: DefaultSimulatorApplication

    init(updater: AppUpdater = AppUpdater(), settings: AppSettings = .shared,
         defaultApplication: DefaultSimulatorApplication = DefaultSimulatorApplication()) {
        self.defaultApplication = defaultApplication
        let view = SettingsView(updater: updater, settings: settings, defaultApplication: defaultApplication)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func showWindow(_ sender: Any?) {
        defaultApplication.refresh()
        super.showWindow(sender)
    }
}

@MainActor private struct SettingsView: View {
    @ObservedObject var updater: AppUpdater
    @ObservedObject var defaultApplication: DefaultSimulatorApplication
    private let settings: AppSettings
    @State private var bootMostRecentOnStart: Bool
    @State private var leaveRunningAfterClose: Bool
    @State private var errorMessage: String?

    init(updater: AppUpdater, settings: AppSettings, defaultApplication: DefaultSimulatorApplication) {
        self.updater = updater
        self.settings = settings
        self.defaultApplication = defaultApplication
        _bootMostRecentOnStart = State(initialValue: settings.bootMostRecentSimulatorOnStart)
        _leaveRunningAfterClose = State(initialValue: settings.leaveSimulatorRunningAfterWindowClose)
    }

    var body: some View {
        Form {
            Section("Simulator Lifetime") {
                Toggle("Boot most recent simulator on start", isOn: Binding(
                    get: { bootMostRecentOnStart },
                    set: { value in
                        settings.bootMostRecentSimulatorOnStart = value
                        bootMostRecentOnStart = value
                    }
                ))
                .accessibilityIdentifier("settings.bootMostRecentOnStart")

                Toggle("Leave simulator running after window is closed", isOn: Binding(
                    get: { leaveRunningAfterClose },
                    set: { value in
                        settings.leaveSimulatorRunningAfterWindowClose = value
                        leaveRunningAfterClose = value
                    }
                ))
                .accessibilityIdentifier("settings.leaveRunningAfterClose")
            }

            Section("Device Hub") {
                LabeledContent {
                    Button(defaultApplication.isDefault ? "Use Device Hub" : "Make Siniulator Default") {
                        let makeDefault = !defaultApplication.isDefault
                        Task {
                            if makeDefault { await defaultApplication.makeDefault() }
                            else { await defaultApplication.useDeviceHub() }
                            errorMessage = defaultApplication.errorMessage
                        }
                    }
                    .accessibilityIdentifier("settings.defaultApplication")
                    .disabled(defaultApplication.isBusy || defaultApplication.applicationURL == nil)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open Device Hub links in Siniulator")
                        Text(defaultApplicationStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Updates") {
                Toggle("Install updates automatically", isOn: Binding(
                    get: { updater.automaticUpdatesEnabled },
                    set: { updater.setAutomaticUpdatesEnabled($0) }
                ))
                .help(updater.isAvailable
                    ? "Checks for updates and downloads them in the background. Updates can be installed when you quit Siniulator."
                    : "Updates are unavailable in this development build.")
                .accessibilityIdentifier("settings.automaticUpdates")
                .disabled(!updater.isAvailable)
            }

            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Siniulator").font(.headline)
                        Text(appVersion).font(.subheadline).foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .accessibilityIdentifier("settings.checkForUpdates")
                            .disabled(!updater.canCheckForUpdates)
                        Link("GitHub", destination: URL(string: "https://github.com/kmagiera/Siniulator")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .toggleStyle(.switch)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Couldn’t Change Default App", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if (notification.object as? NSWindow)?.contentViewController is NSHostingController<SettingsView> {
                refresh()
            }
        }
    }

    private var defaultApplicationStatus: String {
        if defaultApplication.applicationURL == nil { return "Run Siniulator.app to change the default app." }
        if defaultApplication.isBusy { return "Updating the default app…" }
        if defaultApplication.isDefault { return "Siniulator is the default app." }
        if let url = defaultApplication.currentApplicationURL {
            return "Current default: \(FileManager.default.displayName(atPath: url.path))"
        }
        return "No default app selected."
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version, let build { return "Version \(version) (\(build))" }
        if let version { return "Version \(version)" }
        if let build { return "Build \(build)" }
        return "Development build"
    }

    private func refresh() {
        bootMostRecentOnStart = settings.bootMostRecentSimulatorOnStart
        leaveRunningAfterClose = settings.leaveSimulatorRunningAfterWindowClose
        defaultApplication.refresh()
    }
}
