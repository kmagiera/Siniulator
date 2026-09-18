import AppKit
import Combine
import Sparkle

@main @MainActor struct SiniulatorApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    let store = DeviceStore()
    private var settingsWindow: SettingsWindowController?
    private var isTerminating = false
    private var hasExplicitDeviceRequest = false
#if DEBUG
    let capturePreviews = CapturePreviewPresenter(saveDirectory: ["--presentation-smoke", "--recording-smoke"].contains(where: CommandLine.arguments.contains)
        ? Diagnostics.outputDirectory().appendingPathComponent("Saved Captures", isDirectory: true) : nil)
#else
    let capturePreviews = CapturePreviewPresenter()
#endif
    private(set) var deviceWindows: [String: DeviceWindowController] = [:]
    let openSimulatorMenu = NSMenu(title: "Open Simulator")
    private weak var selectedWindow: NSWindow?
    private var nextWindowPosition = NSPoint.zero
    private var devicesObserver: AnyCancellable?
    private var observedBooted: Set<String> = []
    private lazy var updater = AppUpdater(controller: updaterController)
    private lazy var updaterController: SPUStandardUpdaterController? = {
        // Source builds without an update signing key stay independent of the official feed.
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty else { return nil }
#if DEBUG
        guard !isDiagnostic && !CommandLine.arguments.contains("--probe") else { return nil }
#endif
#if SINIULATOR_BENCHMARK
        guard !CommandLine.arguments.contains("--benchmark") else { return nil }
#endif
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()
    private var activeDevice: DeviceWindowController? {
        guard let window = NSApp.keyWindow ?? selectedWindow else { return nil }
        return deviceWindows.values.first { $0.window === window }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        buildMenu()
#if SINIULATOR_BENCHMARK
        if CommandLine.arguments.contains("--benchmark") {
            Task { await PerformanceDiagnostics.run(); NSApp.terminate(nil) }
            return
        }
#endif
#if DEBUG
        if CommandLine.arguments.contains("--probe") {
            Task { await Diagnostics.probe(); NSApp.terminate(nil) }
            return
        }
#endif
        // Capture this before mirroring running devices changes which window is active.
        let mostRecentSimulatorID = AppSettings.shared.mostRecentSimulatorID
        store.start()
#if DEBUG
        if launchDiagnosticsIfRequested() {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
#endif
        devicesObserver = store.$devices.dropFirst().sink { [weak self] devices in
            guard let self else { return }
            let booted = Set(devices.filter(\.isBooted).map(\.id))
            let newlyBooted = booted.subtracting(self.observedBooted)
            self.observedBooted = booted
            for device in devices where newlyBooted.contains(device.id) { self.open(device) }
        }
        Task {
            await store.refresh()
            guard !isTerminating else { return }
            // Mirror every running device, including ones not opened here before.
#if DEBUG
            let devicesToOpen = store.devices.filter { $0.isBooted || CommandLine.arguments.contains("--open-all") }
#else
            let devicesToOpen = store.devices.filter(\.isBooted)
#endif
            for device in devicesToOpen { open(device) }
            let startupDevice = AppSettings.shared.simulatorToOpenOnStart(in: store.devices,
                mostRecentID: mostRecentSimulatorID, hasExplicitDeviceRequest: hasExplicitDeviceRequest)
#if DEBUG
            if !isDiagnostic, let startupDevice { open(startupDevice) }
#else
            if let startupDevice { open(startupDevice) }
#endif
#if DEBUG
            if CommandLine.arguments.contains("--startup-smoke") {
                await Diagnostics.startupSmoke(app: self)
                NSApp.terminate(nil)
            }
#endif
        }
        NSApp.activate(ignoringOtherApps: true)
    }
#if DEBUG
    private func launchDiagnosticsIfRequested() -> Bool {
        if let index = CommandLine.arguments.firstIndex(of: "--exercise"), CommandLine.arguments.count > index + 1 {
            Task { await Diagnostics.exercise(app: self, udid: CommandLine.arguments[index + 1]); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--toolbar-smoke") {
            Task { await Diagnostics.toolbarSmoke(); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--recording-smoke") {
            Task { await Diagnostics.recordingSmoke(app: self); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--fullscreen-chrome-smoke") {
            Task { await Diagnostics.fullScreenChromeSmoke(app: self); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--rotation-smoke") {
            Task { await Diagnostics.rotationSmoke(app: self); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--presentation-smoke") || CommandLine.arguments.contains("--window-controls-smoke") {
            Task { await Diagnostics.presentationSmoke(app: self); NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--smoke") {
            Task { await Diagnostics.smoke(app: self); NSApp.terminate(nil) }
        } else { return false }
        return true
    }
#endif
    @objc private func windowBecameKey(_ notification: Notification) {
        selectedWindow = notification.object as? NSWindow
#if DEBUG
        guard !isDiagnostic else { return }
#endif
        if let device = deviceWindows.first(where: { $0.value.window === selectedWindow }) {
            AppSettings.shared.mostRecentSimulatorID = device.key
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        hasExplicitDeviceRequest = true
        Task {
            await store.refresh()
            for url in urls {
                do { try await DeviceURLRouter().open(url, devices: store.devices, openSimulator: open) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !deviceWindows.values.contains(where: { $0.window?.isVisible == true }) {
            Task { await store.refresh(); openLastDevice() }
        }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        capturePreviews.dismissAll()
        for controller in deviceWindows.values { controller.screen.releaseKeys() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        let recordings = deviceWindows.values.filter(\.isRecording)
        guard !recordings.isEmpty || deviceWindows.values.contains(where: \.isClosing) || capturePreviews.hasPendingSaves else {
            return .terminateNow
        }
        isTerminating = true
        Task {
            for controller in recordings { await controller.finishRecording() }
            // Do not exit in the middle of a shutdown requested by closing a window.
            for controller in Array(deviceWindows.values) { await controller.waitForClose() }
            await capturePreviews.savePendingAndDismiss()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func open(_ device: SimulatorDevice) {
        if let existing = deviceWindows[device.id] {
            guard !existing.isClosing else { return }
            selectedWindow = existing.window
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            if !existing.isConnected, !existing.isConnecting { existing.connect() }
            return
        }
        do {
            let controller = try DeviceWindowController(device: device, store: store, capturePreviews: capturePreviews)
            controller.onClose = { [weak self] in
                self?.deviceWindows.removeValue(forKey: device.id)
            }
            deviceWindows[device.id] = controller
            selectedWindow = controller.window
            if let window = controller.window {
                nextWindowPosition = window.cascadeTopLeft(from: nextWindowPosition)
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
#if DEBUG
            if isDiagnostic { return }
#endif
            AppSettings.shared.mostRecentSimulatorID = device.id
        } catch { NSAlert(error: error).runModal() }
    }
#if DEBUG
    private var isDiagnostic: Bool { ["--smoke", "--exercise", "--presentation-smoke", "--window-controls-smoke", "--fullscreen-chrome-smoke", "--toolbar-smoke", "--rotation-smoke", "--recording-smoke", "--startup-smoke"].contains(where: CommandLine.arguments.contains) }
#endif
    private func openLastDevice() {
        let last = AppSettings.shared.mostRecentSimulatorID
        if let device = store.devices.first(where: { $0.id == last }) ?? store.devices.first {
            open(device)
        } else if let error = store.error { NSAlert(error: SimulatorError(message: error)).runModal() }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openSimulatorMenu else { return }
        menu.removeAllItems()
        let groups = Dictionary(grouping: store.devices, by: \.runtimeName)
        for runtime in groups.keys.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let group = NSMenuItem(title: runtime, action: nil, keyEquivalent: "")
            let devices = NSMenu(title: runtime)
            for device in groups[runtime, default: []].sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let item = NSMenuItem(title: device.name, action: #selector(openSimulator(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                item.state = device.isBooted ? .on : .off
                devices.addItem(item)
            }
            group.submenu = devices
            menu.addItem(group)
        }
        if groups.isEmpty {
            let item = NSMenuItem(title: store.isLoading ? "Loading Simulators…" : "No Available Simulators", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }
    @objc private func openSimulator(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let device = store.devices.first(where: { $0.id == id }) { open(device) }
    }
    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(updater: updater) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func paste(_ sender: NSMenuItem) {
        if let activeDevice { activeDevice.perform(.paste) }
        else { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender) }
    }
    @objc private func toggleFullScreen(_ sender: Any?) {
        activeDevice?.window?.toggleFullScreen(sender)
    }
    @objc private func toggleStayOnTop(_ sender: NSMenuItem) {
        activeDevice?.toggleStayOnTop()
    }
    @objc private func action(_ sender: NSMenuItem) {
        if let command = DeviceCommand(rawValue: sender.tag) { activeDevice?.perform(command) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            guard NSPasteboard.general.string(forType: .string) != nil else { return false }
            if let activeDevice { return activeDevice.isConnected }
            return NSApp.keyWindow?.firstResponder?.responds(to: #selector(NSText.paste(_:))) == true
        }
        if item.action == #selector(toggleStayOnTop(_:)) {
            item.state = activeDevice?.staysOnTop == true ? .on : .off
            return activeDevice != nil
        }
        if item.action == #selector(toggleFullScreen(_:)) {
            item.title = activeDevice?.hasEnteredFullScreen == true ? "Exit Full Screen" : "Enter Full Screen"
            return activeDevice != nil
        }
        guard item.action == #selector(action(_:)), let command = DeviceCommand(rawValue: item.tag) else { return true }
        guard let controller = activeDevice else { return false }
        item.state = .off
        if command == .showBezels {
            item.state = controller.showsBezels ? .on : .off
            return true
        }
        let scaling: [DeviceCommand: DeviceScalingMode] = [.physicalSize: .physicalSize, .pointAccurate: .pointAccurate, .pixelAccurate: .pixelAccurate, .fit: .fitScreen]
        if let mode = scaling[command] {
            item.state = controller.scalingMode == mode && (mode == .fitScreen || controller.isAtAccurateScale(mode)) ? .on : .off
            return controller.canSelectScalingMode(mode)
        }
        if command == .keyboard { item.state = controller.screen.keyboardEnabled ? .on : .off }
        if command == .hardwareKeyboard { item.state = controller.hardwareKeyboardEnabled ? .on : .off }
        let orientations: [DeviceCommand: Int] = [.portrait: 0, .landscapeRight: 1, .portraitUpsideDown: 2, .landscapeLeft: 3]
        if let turns = orientations[command] { item.state = controller.screen.quarterTurns == turns ? .on : .off }
        if command == .slowAnimations {
            guard let enabled = controller.slowAnimationsEnabled else { return false }
            item.state = enabled ? .on : .off
        }
        if command == .recording {
            return controller.isConnected && !controller.isRecording
        }
        if command == .stopRecording { return controller.isRecording && !controller.isStoppingRecording }
        return controller.isConnected
    }
    private func buildMenu() {
        let root = NSMenu()
        NSApp.mainMenu = root
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; root.addItem(item); return menu
        }
        @discardableResult func add(_ menu: NSMenu, _ title: String, _ selector: Selector?, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: modifiers.contains(.shift) ? key.uppercased() : key)
            item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item); return item
        }
        @discardableResult func command(_ menu: NSMenu, _ title: String, _ command: DeviceCommand, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = add(menu, title, #selector(action(_:)), key, modifiers: modifiers, target: self)
            item.tag = command.rawValue
            return item
        }
        func branch(_ menu: NSMenu, _ title: String) -> NSMenu {
            let child = NSMenu(title: title)
            add(menu, title, nil).submenu = child
            return child
        }
        let application = submenu("Siniulator")
        add(application, "Settings…", #selector(showSettings), ",", target: self)
        if let updaterController {
            add(application, "Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)), target: updaterController)
        } else {
            add(application, "Check for Updates…", nil).isEnabled = false
        }
        application.addItem(.separator())
        add(application, "Hide Siniulator", #selector(NSApplication.hide(_:)), "h")
        add(application, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(application, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        application.addItem(.separator())
        add(application, "Quit Siniulator", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("File")
        let open = add(file, "Open Simulator", nil)
        open.submenu = openSimulatorMenu
        openSimulatorMenu.delegate = self
        file.addItem(.separator())
        command(file, "Save Screen", .screenshot, "s")
        command(file, "Save Screen…", .exportScreenshot, "s", [.command, .option]).isAlternate = true
        command(file, "Record Screen", .recording, "r")
        command(file, "Stop Recording", .stopRecording)
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        command(edit, "Copy Screen", .copyScreenshot, "c", [.command, .control])
        add(edit, "Paste", #selector(paste(_:)), "v", target: self)
        let device = submenu("Device")
        command(device, "Rotate Left", .rotateLeft, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        command(device, "Rotate Right", .rotateRight, String(UnicodeScalar(NSRightArrowFunctionKey)!))
        let orientation = branch(device, "Orientation")
        command(orientation, "Portrait", .portrait)
        command(orientation, "Landscape Right", .landscapeRight)
        command(orientation, "Portrait Upside Down", .portraitUpsideDown)
        command(orientation, "Landscape Left", .landscapeLeft)
        device.addItem(.separator())
        command(device, "Home", .home, "h", [.command, .shift])
        command(device, "Lock", .lock, "l")
        command(device, "Siri", .siri, "h", [.command, .option, .shift])
        command(device, "Shake", .shake, "z", [.command, .control])
        let io = submenu("I/O")
        let input = branch(io, "Input")
        command(input, "Send Keyboard Input to Device", .keyboard, "k", [.command, .option])
        let keyboard = branch(io, "Keyboard")
        command(keyboard, "Connect Hardware Keyboard", .hardwareKeyboard, "k", [.command, .shift])
        io.addItem(.separator())
        command(io, "Increase Volume", .volumeUp, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        command(io, "Decrease Volume", .volumeDown, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        let features = submenu("Features")
        command(features, "Toggle Appearance", .appearance, "a", [.command, .shift])
        let debug = submenu("Debug")
        command(debug, "Slow Animations", .slowAnimations)
        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Minimize All", #selector(NSApplication.miniaturizeAll(_:)))
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Enter Full Screen", #selector(toggleFullScreen(_:)), "f", modifiers: [.command, .control], target: self)
        command(window, "Show Device Bezels", .showBezels)
        add(window, "Stay On Top", #selector(toggleStayOnTop(_:)), target: self)
        window.addItem(.separator())
        command(window, "Physical Size", .physicalSize, "1")
        command(window, "Point Accurate", .pointAccurate, "2")
        command(window, "Pixel Accurate", .pixelAccurate, "3")
        command(window, "Fit Screen", .fit, "4")
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        window.addItem(.separator())
        NSApp.windowsMenu = window
        let help = submenu("Help")
        add(help, "Siniulator Help", #selector(showHelp), "?", target: self)
        NSApp.helpMenu = help
    }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Siniulator controls"
        alert.informativeText = "Click and drag: touch and swipe\nOption + drag: two fingers (pinch)\nTrackpad pinch: zoom\nScroll: swipe\nKeyboard: type into the active device\n⌘V: paste text into the device\n⇧⌘H: Home   ⌘L: Lock   ⌥⇧⌘H: Siri\n⌘← / ⌘→: Rotate   ⌃⌘Z: Shake\n⌘S: Save Screen   ⌥⌘S: Save Screen…\n⌘R: Record Screen; use File > Stop Recording or the toolbar to stop\n⌥⌘K: Send Keyboard Input to Device\nFile > Open Simulator: choose a device\n⌘4: Fit Screen   ⌃⌘F: Full Screen\nDebug > Slow Animations: slow down UIKit animations\n\nFull screen keeps Home, Screenshot and Rotate in the top header. Drop simulator .app bundles to install, or photos and videos to import. Closing a window shuts down its simulator by default; change this in Settings."
        alert.informativeText += "\n\n⌘1: Physical Size   ⌘2: Point Accurate   ⌘3: Pixel Accurate\nWindow > Show Device Bezels: toggle the device frame"
        alert.runModal()
    }
}
