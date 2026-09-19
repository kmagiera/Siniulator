import Foundation
import Combine
import SimulatorBridge

struct XcodeInstallation: Equatable {
    let developerDirectory: String
    let version: String

    static func preferred(override: String?, selected: String, installed: [XcodeInstallation]) -> String {
        if let override, !override.isEmpty { return normalize(override) }
        let selected = normalize(selected)
        return installed.max {
            let order = $0.version.compare($1.version, options: .numeric)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.developerDirectory == selected { return false }
            if $1.developerDirectory == selected { return true }
            return $0.developerDirectory < $1.developerDirectory
        }?.developerDirectory ?? selected
    }

    static func normalize(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer").path : url.path
    }
}

enum DeveloperDirectory {
    static func environment(_ inherited: [String: String] = ProcessInfo.processInfo.environment,
                            developerDirectory: String = preferred) -> [String: String] {
        var environment = inherited
        environment["DEVELOPER_DIR"] = developerDirectory
        return environment
    }
    static let preferred: String = {
        let environment = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        let selected = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
            ?? "/Applications/Xcode.app/Contents/Developer"
        let applications = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let installed = applications.compactMap { url -> XcodeInstallation? in
            guard url.pathExtension == "app", let bundle = Bundle(url: url),
                  bundle.bundleIdentifier == "com.apple.dt.Xcode",
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
            return XcodeInstallation(developerDirectory: url.appendingPathComponent("Contents/Developer").path, version: version)
        }
        return XcodeInstallation.preferred(override: environment, selected: selected, installed: installed)
    }()
}

struct SimulatorDevice: Decodable, Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let deviceTypeIdentifier: String?
    var runtime: String = ""
    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
    var runtimeName: String {
        runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: "iOS.", with: "iOS ")
    }
    enum CodingKeys: String, CodingKey { case udid, name, state, isAvailable, deviceTypeIdentifier }
}

struct DeviceList: Decodable {
    let devices: [String: [SimulatorDevice]]
    var available: [SimulatorDevice] {
        devices.flatMap { runtime, devices in
            devices.filter(\.isAvailable).map { device in
                var device = device
                device.runtime = runtime
                return device
            }
        }.sorted {
            if $0.isBooted != $1.isBooted { return $0.isBooted }
            if $0.runtime != $1.runtime { return $0.runtime.compare($1.runtime, options: .numeric) == .orderedDescending }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

struct SimulatorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CommandRunner {
    static func run(_ executable: String = "/usr/bin/xcrun", _ arguments: [String], input: Data? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if executable == "/usr/bin/xcrun" {
                    process.environment = DeveloperDirectory.environment()
                }
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                let stdin = Pipe()
                if input != nil { process.standardInput = stdin }
                do {
                    try process.run()
                    // Read both outputs while writing input: a child can fill
                    // stdout before it finishes consuming a large paste.
                    let stdout = CommandOutput(), stderr = CommandOutput()
                    let readGroup = DispatchGroup()
                    for (pipe, result) in [(output, stdout), (errors, stderr)] {
                        readGroup.enter()
                        DispatchQueue.global().async {
                            defer { readGroup.leave() }
                            result.read(from: pipe.fileHandleForReading)
                        }
                    }
                    var inputError: Error?
                    if let input {
                        do { try stdin.fileHandleForWriting.write(contentsOf: input) }
                        catch { inputError = error }
                        try? stdin.fileHandleForWriting.close()
                    }
                    process.waitUntilExit()
                    readGroup.wait()
                    guard process.terminationStatus == 0 else {
                        let message = String(decoding: try stderr.data(), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let fallback = "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(process.terminationStatus)."
                        throw SimulatorError(message: message.isEmpty ? fallback : message)
                    }
                    if let inputError { throw inputError }
                    continuation.resume(returning: try stdout.data())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func simctl(_ arguments: [String], input: Data? = nil) async throws -> Data {
        try await run("/usr/bin/xcrun", ["simctl"] + arguments, input: input)
    }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error> = .success(Data())

    func read(from handle: FileHandle) {
        let result = Result { try handle.readToEnd() ?? Data() }
        lock.withLock { self.result = result }
    }

    func data() throws -> Data { try lock.withLock { try result.get() } }
}

protocol DeviceMonitoring: AnyObject {
    @MainActor func stop()
}

extension SIDeviceMonitor: DeviceMonitoring {}

@MainActor final class DeviceStore: ObservableObject {
    typealias MonitorFactory = (@escaping @Sendable () -> Void, @escaping @Sendable (String) -> Void) async throws -> DeviceMonitoring

    @Published private(set) var devices: [SimulatorDevice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let fetchDevices: () async throws -> [SimulatorDevice]
    private let makeMonitor: MonitorFactory
    private let runSimctl: @MainActor ([String]) async throws -> Data
    private var monitor: DeviceMonitoring?
    private var monitorTask: Task<Void, Never>?
    private var monitorGeneration = UUID()
    private var monitoringError: String?
    private var isStarted = false
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var refreshRetryTask: Task<Void, Never>?
    private var refreshRetryDelay: UInt64 = 1
    private var bootTasks: [String: Task<Void, Error>] = [:]
    private var shutdownTasks: [String: Task<Void, Error>] = [:]

    init(fetchDevices: @escaping () async throws -> [SimulatorDevice] = {
        let data = try await CommandRunner.simctl(["list", "devices", "--json"])
        return try JSONDecoder().decode(DeviceList.self, from: data).available
    }, makeMonitor: @escaping MonitorFactory = CoreSimulatorConnection.monitor,
         runSimctl: @escaping @MainActor ([String]) async throws -> Data = { try await CommandRunner.simctl($0) }) {
        self.fetchDevices = fetchDevices
        self.makeMonitor = makeMonitor
        self.runSimctl = runSimctl
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectMonitor()
    }

    func stop() {
        isStarted = false
        monitorGeneration = UUID()
        monitorTask?.cancel()
        monitorTask = nil
        monitor?.stop()
        monitor = nil
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
    }

    private func connectMonitor(afterDelay initialDelay: UInt64 = 0) {
        monitorTask?.cancel()
        monitor?.stop()
        monitor = nil
        let generation = UUID()
        monitorGeneration = generation
        let makeMonitor = self.makeMonitor
        monitorTask = Task { [weak self] in
            var delay = initialDelay
            var needsInitialSnapshot = true
            while !Task.isCancelled {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                    catch { return }
                }
                do {
                    let monitor = try await makeMonitor({ [weak self] in
                        Task { @MainActor in
                            guard let self, self.isStarted, self.monitorGeneration == generation else { return }
                            await self.refresh()
                        }
                    }, { [weak self] reason in
                        Task { @MainActor in
                            guard let self, self.isStarted, self.monitorGeneration == generation else { return }
                            self.monitoringError = "Simulator monitoring disconnected: \(reason)"
                            self.error = self.monitoringError
                            self.connectMonitor(afterDelay: 1)
                        }
                    })
                    guard let self, self.isStarted, self.monitorGeneration == generation, !Task.isCancelled else {
                        monitor.stop()
                        return
                    }
                    self.monitor = monitor
                    self.monitorTask = nil
                    self.monitoringError = nil
                    // Subscribe before taking the snapshot so changes during startup are not lost.
                    await self.refresh()
                    return
                } catch {
                    guard let self, self.isStarted, self.monitorGeneration == generation, !Task.isCancelled else { return }
                    self.monitoringError = "Cannot monitor simulators: \(error.localizedDescription)"
                    self.error = self.monitoringError
                    // Keep the device picker usable even when subscription fails.
                    if needsInitialSnapshot {
                        needsInitialSnapshot = false
                        await self.refresh()
                    }
                    // Retry only a failed connection, with a capped exponential backoff.
                    delay = delay == 0 ? 1 : min(delay * 2, 30)
                }
            }
        }
    }

    func refresh() async {
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
        refreshRequested = true
        if let refreshTask { await refreshTask.value; return }
        let task = Task {
            isLoading = true
            // An event received during a snapshot requires another snapshot. Concurrent
            // notifications coalesce here without dropping the final device state.
            while refreshRequested {
                refreshRequested = false
                await loadDevices()
            }
            isLoading = false
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }
    private func loadDevices() async {
        do {
            devices = try await fetchDevices()
            error = monitoringError
            refreshRetryDelay = 1
            refreshRetryTask?.cancel()
            refreshRetryTask = nil
        } catch {
            self.error = error.localizedDescription
            // With no polling, a failed snapshot needs its own retry: there may be no
            // further device events to make the list current after a transient error.
            guard isStarted, refreshRetryTask == nil else { return }
            let delay = refreshRetryDelay
            refreshRetryDelay = min(delay * 2, 30)
            refreshRetryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                catch { return }
                guard let self, self.isStarted, !Task.isCancelled else { return }
                self.refreshRetryTask = nil
                await self.refresh()
            }
        }
    }
    func boot(_ device: SimulatorDevice) async throws {
        if let shutdown = shutdownTasks[device.id] { try await shutdown.value }
        try Task.checkCancellation()
        if let existing = bootTasks[device.id] { try await existing.value; return }
        let task = Task { try await bootDevice(device) }
        bootTasks[device.id] = task
        defer { bootTasks[device.id] = nil }
        try await task.value
    }
    private func bootDevice(_ device: SimulatorDevice) async throws {
        // Resolve current state instead of relying on the last device-list refresh.
        let current = try await fetchDevices().first { $0.id == device.id }
        guard let current else { throw SimulatorError(message: "This simulator is no longer available.") }
        if current.state == "Shutdown" { _ = try await runSimctl(["boot", device.id]) }
        _ = try await runSimctl(["bootstatus", device.id, "-b"])
        await refresh()
    }

    func shutdown(_ device: SimulatorDevice) async throws {
        if let existing = shutdownTasks[device.id] { try await existing.value; return }
        let task = Task {
            // An in-flight boot must finish first, or it could turn the device back
            // on after shutdown. Closing a window also cancels its connection task.
            if let boot = bootTasks[device.id] { _ = try? await boot.value }
            func needsShutdown(_ devices: [SimulatorDevice]) -> Bool {
                devices.contains { $0.id == device.id && $0.state != "Shutdown" && $0.state != "Shutting Down" }
            }
            if needsShutdown(try await fetchDevices()) {
                do { _ = try await runSimctl(["shutdown", device.id]) }
                catch {
                    // Another client may have shut down or deleted the device
                    // between our snapshot and the command.
                    guard let current = try? await fetchDevices(), !needsShutdown(current) else { throw error }
                }
            }
            await refresh()
        }
        shutdownTasks[device.id] = task
        defer { shutdownTasks[device.id] = nil }
        try await task.value
    }
}

/// Keep an asynchronously opened framebuffer inseparable from its requested
/// panel metadata, even if the visible pose changes while opening it.
@MainActor struct SimulatorPanelConnection {
    let core: SICoreSimulator
    let device: Any
    let display: SIDisplay
    let chrome: DeviceChrome

    static func connect(_ udid: String, chrome: DeviceChrome,
                        open: @MainActor (String, UInt32, UInt32, UInt32) async throws -> (SICoreSimulator, Any, SIDisplay)
                            = { try await CoreSimulatorConnection.connect($0, screenID: $1, width: $2, height: $3) })
        async throws -> Self {
        let (core, device, display) = try await open(udid, chrome.screenID, chrome.pixelWidth, chrome.pixelHeight)
        return Self(core: core, device: device, display: display, chrome: chrome)
    }
}

enum CoreSimulatorConnection {
    static func monitor(changeHandler: @escaping @Sendable () -> Void,
                        invalidationHandler: @escaping @Sendable (String) -> Void) async throws -> DeviceMonitoring {
        let directory = DeveloperDirectory.preferred
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let monitor = try SIDeviceMonitor(developerDirectory: directory,
                        changeHandler: changeHandler, invalidationHandler: invalidationHandler)
                    continuation.resume(returning: monitor)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func connect(_ udid: String, screenID: UInt32 = 0, width: UInt32 = 0,
                        height: UInt32 = 0) async throws -> (SICoreSimulator, Any, SIDisplay) {
        let directory = DeveloperDirectory.preferred
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let core = try SICoreSimulator(developerDirectory: directory)
                    let device = try core.device(withUDID: udid)
                    let display = try SIDisplay(device: device, screenID: screenID, width: width, height: height)
                    continuation.resume(returning: (core, device, display))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}


extension SICoreSimulator {
    func lookup(_ service: String, device: Any) throws -> UInt32 {
        var error: NSError?
        let port = lookupService(service, device: device, error: &error)
        if let error { throw error }
        return port
    }
}
