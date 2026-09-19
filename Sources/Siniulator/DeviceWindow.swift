import AppKit
import Combine
import SimulatorBridge
import UniformTypeIdentifiers

enum DeviceCommand: Int {
    case home = 1, lock, volumeUp, volumeDown, siri, rotateLeft, rotateRight, portrait, shake
    case screenshot, copyScreenshot, paste, keyboard, fit
    case appearance, recording, exportScreenshot
    case slowAnimations
    case stopRecording, landscapeRight, portraitUpsideDown, landscapeLeft
    case pointAccurate, pixelAccurate, showBezels
    case hardwareKeyboard
    case physicalSize
    case coverScreen, innerPartiallyOpen, innerFullyOpen
}

@MainActor final class DeviceWindowController: NSWindowController, NSWindowDelegate {
    let deviceInfo: SimulatorDevice
    let screen: SimulatorScreenView
    private let store: DeviceStore
    private let settings: AppSettings
    private let capturePreviews: CapturePreviewPresenter
    private let displayModes: [DeviceDisplayMode]
    private var display: SIDisplay?
    private var input: SimulatorInput?
    private(set) var displayMode: DeviceDisplayMode?
    private(set) var presentation: DevicePresentationView!
    private(set) var hasEnteredFullScreen = false
    private(set) var staysOnTop = false
    private(set) var scalingMode: DeviceScalingMode = .custom
    private(set) var hardwareKeyboardEnabled: Bool
    private var isApplyingScale = false
    var showsBezels: Bool { presentation.canvas.showsBezels }
    private var isEnteringFullScreen = false
    private var fullScreenChrome: FullScreenChrome?
    private let overlay = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "Starting simulator…")
    private let spinner = NSProgressIndicator()
    private lazy var retry = NSButton(title: "Retry Connection", target: self, action: #selector(retryConnection))
    private var connectTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var connectVersion = 0
    private var displaySwitchTask: Task<Void, Never>?
    private var displaySwitchVersion = 0
    private var hingeAnimationTask: Task<Void, Never>?
    private var hingeAnimationVersion = 0
    private var hingeFeedback = DuoHingeFeedback()
    private var currentHingeAngle: Double
    private var connectedScreenID: UInt32?
    private var duoDisplays: [UInt32: SIDisplay] = [:]
    private var displayWarmupTask: Task<Void, Never>?
    private var deviceObservation: AnyCancellable?
    private var hasObservedBooted = false
    private var closed = false
    private var connected = false
    private var dark = false
    private var recording: VideoRecording?
    private var recordingTask: Task<Void, Never>?
    var onClose: (() -> Void)?
    var isConnected: Bool { connected }
    var isConnecting: Bool { connectTask != nil }
    var isClosing: Bool { closeTask != nil }
    var isRecording: Bool { recording != nil }
    var isStoppingRecording: Bool { recording?.isStopping == true }
    var recordingHasStarted: Bool { recording?.hasStarted == true }
#if DEBUG
    var diagnosticConnectedScreenID: UInt32? { connectedScreenID }
    var diagnosticDisplaySwitchInProgress: Bool { displaySwitchTask != nil }
    var diagnosticHingeAngle: Double { currentHingeAngle }
    var diagnosticHingeAnimationInProgress: Bool { hingeAnimationTask != nil }
    var diagnosticShowsConnectionOverlay: Bool { !overlay.isHidden }
    var diagnosticConnectionMessage: String { message.stringValue }
    var diagnosticReadyPanelIDs: [UInt32] {
        duoDisplays.compactMap { $0.value.surface == nil ? nil : $0.key }.sorted()
    }
    func diagnosticSetHingeAngle(_ angle: Double) { setInteractiveHingeAngle(angle) }
#endif
    var slowAnimationsEnabled: Bool? {
        guard connected, let input else { return nil }
        return try? input.slowAnimationsEnabled()
    }

    init(device: SimulatorDevice, store: DeviceStore, capturePreviews: CapturePreviewPresenter,
         settings: AppSettings = .shared) throws {
        self.deviceInfo = device
        let displayModes = DeviceChrome.displayModes(for: device)
        self.displayModes = displayModes
        let savedDisplayMode = (UserDefaults.standard.object(forKey: "display-mode-\(device.id)") as? NSNumber)
            .flatMap { DeviceDisplayMode(rawValue: $0.intValue) }
        let fallbackMode = savedDisplayMode.flatMap { displayModes.contains($0) ? $0 : nil } ?? displayModes.last
        let savedHingeAngle = (UserDefaults.standard.object(forKey: "hinge-angle-\(device.id)") as? NSNumber)?.doubleValue
        let hingeAngle = min(180, max(0, savedHingeAngle ?? fallbackMode?.hingeAngle ?? 180))
        self.displayMode = displayModes.isEmpty ? nil : DeviceDisplayMode.mode(forHingeAngle: hingeAngle)
        self.currentHingeAngle = hingeAngle
        self.hardwareKeyboardEnabled = UserDefaults.standard.object(forKey: "hardware-keyboard-\(device.id)") as? Bool ?? true
        self.store = store
        self.settings = settings
        self.capturePreviews = capturePreviews
        self.hasObservedBooted = device.isBooted
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        if !displayModes.isEmpty {
            screen.quarterTurns = ScreenGeometry.normalizedQuarterTurns(
                UserDefaults.standard.integer(forKey: "orientation-\(device.id)"))
        }
        self.screen = screen
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 950)
        let window = DeviceHostWindow(contentRect: NSRect(x: 0, y: 0, width: device.name.contains("iPad") ? 560 : 440, height: min(900, available.height - 40)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(device.name) – \(device.runtimeName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.updatePresentationBackground()
        // WindowServer derives the shadow from both visible islands: the detached
        // toolbar and device bezel, leaving the transparent space between clear.
        window.hasShadow = true
        // The toolbar and bezel explicitly performDrag. AppKit's automatic
        // background drag must not also move a window during corner resizing.
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: SimulatorControlBar.minimumWidth + 24, height: 360)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("framed-device-\(device.id)")
        let root = DevicePresentationView(screen: screen, chrome: DeviceChrome.load(for: device, displayMode: displayMode), device: device) { [weak self] in self?.perform($0) }
        presentation = root
        window.minSize.width = root.controls.minimumCompactWidth + NormalPresentationLayout.deviceSideMargin * 2
        if window.frame.width < window.minSize.width {
            var frame = window.frame
            frame.size.width = window.minSize.width
            window.setFrame(frame, display: false, animate: false)
        }
        root.controls.update(hingeAngle: currentHingeAngle)
        root.canvas.setHingeAngle(CGFloat(currentHingeAngle))
        if !displayModes.isEmpty {
            screen.magnifyHandler = { [weak self] event in
                self?.handleDuoMagnify(event) ?? false
            }
        }
        root.canvas.showsBezels = UserDefaults.standard.object(forKey: "show-bezels-\(device.id)") as? Bool ?? true
        window.contentView = root
        fullScreenChrome = FullScreenChrome(window: window, controls: root.controls) { [weak self] progress in
            guard let self, self.hasEnteredFullScreen, self.presentation.isFullScreen, !self.closed else { return }
            self.presentation.controls.setFullScreenRevealProgress(progress)
        }
        root.controls.attach(to: window)
        window.onManualResize = { [weak self] in
            self?.scalingMode = .custom
            self?.presentation.canvas.pixelAligned = false
        }
        overlay.orientation = .vertical
        overlay.alignment = .centerX
        overlay.spacing = 16
        overlay.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.usesThreadedAnimation = true
        // Connection feedback sits on the simulated device's black screen.
        overlay.appearance = NSAppearance(named: .darkAqua)
        spinner.setAccessibilityLabel("Starting Simulator")
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 24),
            spinner.heightAnchor.constraint(equalToConstant: 24)
        ])
        message.alignment = .center
        overlay.addArrangedSubview(spinner)
        overlay.addArrangedSubview(message)
        retry.isHidden = true
        overlay.addArrangedSubview(retry)
        root.canvas.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: root.canvas.centerXAnchor), overlay.centerYAnchor.constraint(equalTo: root.canvas.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: root.canvas.widthAnchor, constant: -48)
        ])
        screen.onDrop = { [weak self] urls in self?.importFiles(urls) }
        deviceObservation = store.$devices.dropFirst().sink { [weak self] devices in
            guard let self, !self.closed, !self.isClosing else { return }
            let current = devices.first { $0.id == self.deviceInfo.id }
            if current?.isBooted == true { self.hasObservedBooted = true }
            guard self.hasObservedBooted else { return }
            if current == nil || current?.state == "Shutdown" || current?.state == "Shutting Down" {
                self.window?.close()
            }
        }
        fitWindowToDevice()
        connect()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func toggleStayOnTop() {
        staysOnTop.toggle()
        updateWindowLevel()
    }
    private func updateWindowLevel() {
        // Native full-screen Spaces manage their own window level. Restore the
        // per-window preference once the device returns to the desktop.
        guard !isEnteringFullScreen, !hasEnteredFullScreen, let window,
              !window.styleMask.contains(.fullScreen) else { return }
        window.level = staysOnTop ? .floating : .normal
    }

    @objc private func retryConnection() { connect() }

    func connect() {
        guard !closed, !isClosing else { return }
        displaySwitchTask?.cancel()
        displaySwitchVersion += 1
        connectTask?.cancel()
        connectVersion += 1
        let version = connectVersion
        // A foldable changes the framebuffer, not the CoreDevice HID session.
        // Reusing the live input connections avoids racing XPC cancellation
        // against a second digitizer activation while changing panels.
        let reusableInput = input
        disconnect(message: "Starting \(deviceInfo.name)…", canRetry: false)
        spinner.isHidden = false
        spinner.startAnimation(nil)
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.connectVersion == version { self.connectTask = nil } }
            do {
                try Task.checkCancellation()
                try await store.boot(deviceInfo)
                try Task.checkCancellation()
                // The UI can change pose while boot/display/HID activation is
                // suspended. Never label the returned framebuffer with a later
                // request's metadata; reconcile the current request at commit.
                let requestedChrome = presentation.canvas.chrome
                var connection: SimulatorPanelConnection?
                var lastError: Error?
                // A foldable can take longer than ten seconds to publish the
                // newly active panel after a hinge transition. Successful
                // connections still return immediately.
                for _ in 0..<60 {
                    do { connection = try await SimulatorPanelConnection.connect(deviceInfo.id,
                        chrome: requestedChrome); break }
                    catch { lastError = error; try await Task.sleep(for: .milliseconds(500)) }
                }
                try Task.checkCancellation()
                guard !closed else { return }
                guard let connection else { throw lastError ?? SimulatorError(message: "Display unavailable.") }
                let core = connection.core, device = connection.device, display = connection.display
                let connectionChrome = connection.chrome
                let input: SimulatorInput
                if let reusableInput {
                    input = reusableInput
                    input.setDigitizerTarget(connectionChrome.digitizerTarget)
                } else {
                    input = try SimulatorInput(core: core, device: device,
                                               digitizerTarget: connectionChrome.digitizerTarget)
                    try await input.activate()
                }
                if !displayModes.isEmpty, input.setHingeAngle(currentHingeAngle) {
                    try await Task.sleep(for: .milliseconds(350))
                }
                if !displayModes.isEmpty {
                    guard input.setFoldableOrientation(quarterTurns: screen.quarterTurns) else {
                        throw SimulatorError(message: "The Duo orientation control is unavailable.")
                    }
                    try await Task.sleep(for: .milliseconds(350))
                }
                try input.setHardwareKeyboardEnabled(hardwareKeyboardEnabled)
                let previousOrientation = screen.quarterTurns
                if displayModes.isEmpty {
                    screen.quarterTurns = (try? await input.orientationTurns(udid: deviceInfo.id)) ?? 0
                }
                if screen.quarterTurns != previousOrientation {
                    presentation.refreshGeometry()
                    if scalingMode.isAccurate { reapplyScalingMode() }
                    else { fitWindowToDevice() }
                }
                try Task.checkCancellation()
                input.onError = { [weak self] error in self?.disconnect(message: error.localizedDescription) }
                self.display = display
                self.connectedScreenID = connectionChrome.screenID
                self.input = input
                screen.setDisplay(display, chrome: connectionChrome)
                screen.input = input
                if displayModes.isEmpty {
                    try display.start(frameHandler: screen.frameHandler(observesSurfaceChanges: false))
                } else {
                    try observeDuoDisplay(display, chrome: connectionChrome)
                    warmDuoDisplays()
                }
                screen.needsDisplay = true
                connected = true
                if !displayModes.isEmpty {
                    // Changes made while input was still local to this task
                    // must reach the guest before the final panel selection.
                    _ = input.setHingeAngle(currentHingeAngle)
                    synchronizeDisplay()
                }
                overlay.isHidden = true
                spinner.stopAnimation(nil)
                updateStatus()
                window?.makeFirstResponder(screen)
            } catch is CancellationError { }
            catch { if !closed, !isClosing { disconnect(message: error.localizedDescription) } }
        }
    }
    private func disconnect(message: String, canRetry: Bool = true) {
        displaySwitchTask?.cancel()
        displaySwitchTask = nil
        displaySwitchVersion += 1
        hingeAnimationTask?.cancel()
        hingeAnimationTask = nil
        hingeAnimationVersion += 1
        screen.releaseKeys()
        stopDisplays()
        display = nil; input = nil
        connectedScreenID = nil
        screen.display = nil; screen.input = nil
        connected = false
        overlay.isHidden = false
        self.message.stringValue = message
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        retry.isHidden = !canRetry
        screen.needsDisplay = true
    }
    func updateStatus() {
        presentation.controls.update(isRecording: isRecording, isStoppingRecording: isStoppingRecording)
    }

    func perform(_ command: DeviceCommand) {
        switch command {
        case .physicalSize: selectScalingMode(.physicalSize); return
        case .pointAccurate: selectScalingMode(.pointAccurate); return
        case .pixelAccurate: selectScalingMode(.pixelAccurate); return
        case .fit: selectScalingMode(.fitScreen); return
        case .showBezels: toggleBezels(); return
        case .coverScreen: selectDisplayMode(.cover); return
        case .innerPartiallyOpen: selectDisplayMode(.innerPartiallyOpen); return
        case .innerFullyOpen: selectDisplayMode(.innerFullyOpen); return
        default: break
        }
        if command == .stopRecording { if isRecording { stopRecording() }; return }
        if command == .recording, isRecording { stopRecording(); return }
        guard connected else { return }
        switch command {
        case .home: screen.releaseKeys(); input?.button(usage: 0x40, legacySource: 0)
        case .lock: input?.button(usage: 0x30, legacySource: 1)
        case .volumeUp: input?.button(usage: 0xe9, legacySource: 0)
        case .volumeDown: input?.button(usage: 0xea, legacySource: 0)
        case .siri: input?.button(usage: 0xcf, legacySource: 0x400002)
        case .rotateLeft: rotate(to: (screen.quarterTurns + 3) % 4)
        case .rotateRight: rotate(to: (screen.quarterTurns + 1) % 4)
        case .portrait: rotate(to: 0)
        case .landscapeRight: rotate(to: 1)
        case .portraitUpsideDown: rotate(to: 2)
        case .landscapeLeft: rotate(to: 3)
        case .shake: do { try input?.shake() } catch { report(error) }
        case .slowAnimations:
            do {
                if let input { try input.setSlowAnimationsEnabled(!input.slowAnimationsEnabled()) }
            } catch { report(error) }
        case .screenshot: saveScreenshot()
        case .exportScreenshot: exportScreenshot()
        case .copyScreenshot: copyScreenshot()
        case .paste: paste()
        case .keyboard: screen.keyboardEnabled.toggle(); updateStatus()
        case .hardwareKeyboard:
            do {
                screen.releaseKeys()
                if let input {
                    let enabled = !hardwareKeyboardEnabled
                    try input.setHardwareKeyboardEnabled(enabled)
                    hardwareKeyboardEnabled = enabled
                    UserDefaults.standard.set(enabled, forKey: "hardware-keyboard-\(deviceInfo.id)")
                }
            } catch { report(error) }
        case .fit, .physicalSize, .pointAccurate, .pixelAccurate, .showBezels,
             .coverScreen, .innerPartiallyOpen, .innerFullyOpen: break
        case .appearance:
            dark.toggle()
            run(["ui", deviceInfo.id, "appearance", dark ? "dark" : "light"])
        case .recording: toggleRecording()
        case .stopRecording: break
        }
    }
    private func selectDisplayMode(_ mode: DeviceDisplayMode) {
        guard displayModes.contains(mode) else { return }
        screen.releaseKeys()
        UserDefaults.standard.set(mode.rawValue, forKey: "display-mode-\(deviceInfo.id)")
        UserDefaults.standard.set(mode.hingeAngle, forKey: "hinge-angle-\(deviceInfo.id)")
        animateHinge(to: mode.hingeAngle)
        window?.makeFirstResponder(screen)
    }

    private func handleDuoMagnify(_ event: NSEvent) -> Bool {
        guard !displayModes.isEmpty else { return false }
        if event.phase == .began {
            hingeAnimationTask?.cancel()
            hingeAnimationTask = nil
            hingeAnimationVersion += 1
            screen.releaseKeys()
        }
        let delta = Double(event.magnification) * 180
        let previousAngle = currentHingeAngle
        if abs(delta) > 0.0001 {
            setInteractiveHingeAngle(currentHingeAngle + delta)
        }
        if hingeFeedback.update(from: previousAngle, to: currentHingeAngle, phase: event.phase) {
            // Ask for the current performer each time: AppKit handles hardware
            // support and user preferences. Preset animations never use this path.
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
        }
        if event.phase == .ended || event.phase == .cancelled {
            UserDefaults.standard.set(currentHingeAngle, forKey: "hinge-angle-\(deviceInfo.id)")
            if let displayMode {
                UserDefaults.standard.set(displayMode.rawValue, forKey: "display-mode-\(deviceInfo.id)")
            }
            window?.makeFirstResponder(screen)
        }
        return true
    }

    private func setInteractiveHingeAngle(_ proposedAngle: Double) {
        let angle = min(180, max(0, proposedAngle))
        guard angle != currentHingeAngle else { return }
        currentHingeAngle = angle
        _ = input?.setHingeAngle(angle)

        let nextMode = DeviceDisplayMode.mode(forHingeAngle: angle)
        if nextMode != displayMode {
            screen.releaseKeys()
            displayMode = nextMode
            let chrome = DeviceChrome.load(for: deviceInfo, displayMode: nextMode)
            presentation.canvas.setChrome(chrome)
            presentation.canvas.maximumScale = scalingMode.isAccurate ? logicalScale(for: scalingMode) : nil
            synchronizeDisplay()
        }
        presentation.canvas.setHingeAngle(CGFloat(angle))
        presentation.controls.update(hingeAngle: angle)
        presentation.refreshGeometry()
    }
    private func synchronizeDisplay() {
        displaySwitchTask?.cancel()
        displaySwitchVersion += 1
        // Startup owns the connection until it publishes its immutable panel.
        guard connected, let mode = displayMode else { return }
        let chrome = presentation.canvas.chrome
        screen.releaseKeys()
        if connectedScreenID == chrome.screenID {
            screen.input = input
        } else {
            // Do not send coordinates from the new pose to the old digitizer.
            screen.input = nil
            switchDisplay(to: chrome, mode: mode, version: displaySwitchVersion)
        }
    }
    private func animateHinge(to target: Double) {
        hingeAnimationTask?.cancel()
        hingeAnimationTask = nil
        hingeAnimationVersion += 1
        let version = hingeAnimationVersion
        // Undo the segmented control's immediate target selection. Selection
        // follows the current pose, including clicks on the selected middle item.
        presentation.controls.update(hingeAngle: currentHingeAngle)
        let animation = DuoHingeAnimation(start: currentHingeAngle, target: target)
        guard abs(target - currentHingeAngle) > 0.1,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setInteractiveHingeAngle(target)
            return
        }
        hingeAnimationTask = Task { [weak self] in
            guard let self else { return }
            let started = CACurrentMediaTime()
            while true {
                do { try Task.checkCancellation() }
                catch { return }
                let linear = min(1, max(0, (CACurrentMediaTime() - started) / animation.duration))
                // One clock drives HID, model, active panel and toolbar. A
                // pinch or another preset resumes from this exact visible pose.
                setInteractiveHingeAngle(animation.angle(at: linear))
                if linear >= 1 { break }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
            if hingeAnimationVersion == version { hingeAnimationTask = nil }
        }
    }
    private func switchDisplay(to chrome: DeviceChrome, mode: DeviceDisplayMode, version: Int) {
        displaySwitchTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.displaySwitchVersion == version { self.displaySwitchTask = nil } }
            do {
                var replacement: SIDisplay? = duoDisplays[chrome.screenID]
                var lastError: Error?
                for _ in 0..<60 {
                    if replacement != nil { break }
                    try Task.checkCancellation()
                    do {
                        (_, _, replacement) = try await CoreSimulatorConnection.connect(deviceInfo.id,
                            screenID: chrome.screenID, width: chrome.pixelWidth, height: chrome.pixelHeight)
                        break
                    } catch {
                        lastError = error
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                try Task.checkCancellation()
                guard !closed, displaySwitchVersion == version, displayMode == mode else { return }
                guard let replacement = duoDisplays[chrome.screenID] ?? replacement else {
                    throw lastError ?? SimulatorError(message: "Display unavailable.")
                }
                if duoDisplays[chrome.screenID] == nil {
                    try observeDuoDisplay(replacement, chrome: chrome)
                }
                // Discard host gestures begun while input was disabled; the
                // new digitizer must not receive a move without a touch-down.
                screen.releaseKeys()
                display = replacement
                connectedScreenID = chrome.screenID
                input?.setDigitizerTarget(chrome.digitizerTarget)
                screen.setDisplay(replacement, chrome: chrome)
                screen.input = input
                screen.needsDisplay = true
                window?.makeFirstResponder(screen)
            } catch is CancellationError { }
            catch {
                // A failed panel handoff has already detached input from the
                // previous digitizer. Do not leave a framebuffer that looks
                // usable but can no longer receive clicks. Only the current
                // request may replace the connection state with Retry UI.
                guard !closed, displaySwitchVersion == version, displayMode == mode else { return }
                displaySwitchTask = nil
                disconnect(message: error.localizedDescription)
            }
        }
    }
    private func observeDuoDisplay(_ display: SIDisplay, chrome: DeviceChrome) throws {
        let delivery = DisplayFrameDelivery { [weak self, weak display] in
            guard let self, let display, duoDisplays[chrome.screenID] === display else { return }
            presentation.canvas.updateDuoDisplay(display, chrome: chrome)
            if self.display === display { screen.renderer.requestFrame() }
        }
        // Register before starting; a callback can arrive immediately.
        duoDisplays[chrome.screenID] = display
        do { try display.start(frameHandler: { delivery.requestFrame() }) }
        catch { duoDisplays[chrome.screenID] = nil; throw error }
        delivery.requestFrame()
    }

    private func warmDuoDisplays() {
        displayWarmupTask?.cancel()
        displayWarmupTask = Task { [weak self] in
            guard let self else { return }
            for mode in [DeviceDisplayMode.cover, .innerFullyOpen] {
                let chrome = DeviceChrome.load(for: deviceInfo, displayMode: mode)
                guard duoDisplays[chrome.screenID] == nil else { continue }
                do {
                    let (_, _, panel) = try await CoreSimulatorConnection.connect(deviceInfo.id,
                        screenID: chrome.screenID, width: chrome.pixelWidth, height: chrome.pixelHeight)
                    try Task.checkCancellation()
                    guard !closed, duoDisplays[chrome.screenID] == nil else { continue }
                    try observeDuoDisplay(panel, chrome: chrome)
                } catch is CancellationError {
                    return
                } catch {
                    // The normal switch path retries an unavailable panel.
                }
            }
        }
    }

    private func stopDisplays() {
        displayWarmupTask?.cancel()
        displayWarmupTask = nil
        display?.stop()
        for panel in duoDisplays.values where panel !== display { panel.stop() }
        duoDisplays.removeAll()
    }
    private func rotate(to turns: Int) {
        screen.releaseKeys()
        let orientations: [UInt32] = [1, 3, 2, 4]
        let isFoldable = !displayModes.isEmpty
        Task {
            do {
                if isFoldable {
                    guard input?.setFoldableOrientation(quarterTurns: turns) == true else {
                        throw SimulatorError(message: "The Duo orientation control is unavailable.")
                    }
                    try await Task.sleep(for: .milliseconds(350))
                } else {
                    try await input?.rotate(orientation: orientations[turns], udid: deviceInfo.id)
                }
                guard !closed, connected else { return }
                presentation.layoutSubtreeIfNeeded()
                let previousScale = presentation.canvas.fittedGeometry.scale
                screen.quarterTurns = turns
                presentation.refreshGeometry()
                UserDefaults.standard.set(turns, forKey: "orientation-\(deviceInfo.id)")
                if scalingMode.isAccurate {
                    reapplyScalingMode()
                } else if scalingMode == .custom {
                    // Preserve the current device scale, including a manual resize
                    // made while the guest was processing the rotation request.
                    applyScale(logicalScale: previousScale, exact: canFitLogicalScale(previousScale))
                } else {
                    selectScalingMode(.fitScreen)
                }
            } catch { report(error) }
        }
    }
    private func fitWindowToDevice() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        presentation.layoutSubtreeIfNeeded()
        let fit = presentation.canvas.geometry.fit(in: presentation.canvas.bounds, maximumScale: presentation.canvas.maximumScale)
        resize(scale: fit.scale / presentation.canvas.chrome.displayScale)
    }
    func resize(scale: CGFloat) {
        scalingMode = .custom
        presentation.canvas.pixelAligned = false
        applyScale(logicalScale: scale * presentation.canvas.chrome.displayScale)
    }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 }
    private func logicalScale(for mode: DeviceScalingMode) -> CGFloat? {
        mode.logicalScale(deviceScale: presentation.canvas.chrome.displayScale, backingScale: backingScale,
            deviceDPI: presentation.canvas.chrome.displayDPI, displayPointsPerInch: window?.screen?.physicalPointsPerInch)
    }
    func canSelectScalingMode(_ mode: DeviceScalingMode) -> Bool {
        guard let scale = logicalScale(for: mode) else { return !mode.isAccurate }
        return canFitLogicalScale(scale)
    }
    private func canFitLogicalScale(_ scale: CGFloat) -> Bool {
        guard let window else { return false }
        if presentation.isFullScreen || window.styleMask.contains(.fullScreen) {
            let availableScale = presentation.canvas.geometry.fit(in: presentation.canvas.bounds).scale
            return scale <= availableScale + 0.000001
        }
        guard let available = window.screen?.visibleFrame else { return false }
        let size = presentation.normalSize(scale: scale)
        return ceil(size.width) <= available.width && ceil(size.height) <= available.height
    }
    func isAtAccurateScale(_ mode: DeviceScalingMode) -> Bool {
        guard let desired = logicalScale(for: mode) else { return false }
        let actual = presentation.canvas.geometry.fit(in: presentation.canvas.bounds,
            maximumScale: presentation.canvas.maximumScale).scale
        return abs(actual - desired) < 0.000001
    }
    private func selectScalingMode(_ mode: DeviceScalingMode) {
        guard canSelectScalingMode(mode) else { return }
        screen.releaseKeys()
        scalingMode = mode
        presentation.canvas.pixelAligned = mode == .pixelAccurate
        applyScale(logicalScale: logicalScale(for: mode), exact: mode.isAccurate)
    }
    private func reapplyScalingMode() {
        // Never mark a downscaled device as accurate on a smaller display.
        presentation.refreshGeometry()
        presentation.layoutSubtreeIfNeeded()
        selectScalingMode(canSelectScalingMode(scalingMode) ? scalingMode : .fitScreen)
    }
    private func toggleBezels() {
        (window as? DeviceHostWindow)?.endCornerResize()
        screen.releaseKeys()
        presentation.layoutSubtreeIfNeeded()
        let factor = presentation.canvas.geometry.fit(in: presentation.canvas.bounds,
            maximumScale: presentation.canvas.maximumScale).scale
        presentation.canvas.showsBezels.toggle()
        UserDefaults.standard.set(showsBezels, forKey: "show-bezels-\(deviceInfo.id)")
        presentation.refreshGeometry()
        if scalingMode.isAccurate {
            reapplyScalingMode()
        } else {
            // Keep the touchscreen's scale while adding/removing the hardware frame.
            scalingMode = .custom
            applyScale(logicalScale: factor, exact: canFitLogicalScale(factor))
        }
    }
    private func applyScale(logicalScale desiredScale: CGFloat?, exact: Bool = false) {
        guard let window, let available = window.screen?.visibleFrame else { return }
        if window.styleMask.contains(.fullScreen) {
            presentation.canvas.maximumScale = desiredScale
            presentation.refreshGeometry()
            presentation.layoutSubtreeIfNeeded()
            return
        }
        let maximum = presentation.normalScaleToFit(in: CGSize(width: max(0, available.width - 24), height: max(0, available.height - 30)))
        let factor = exact ? (desiredScale ?? maximum) : min(desiredScale ?? maximum, maximum)
        // Keep the selected device scale when AppKit rounds the window to
        // whole points or enforces its native minimum size.
        presentation.canvas.maximumScale = factor
        var size = presentation.normalSize(scale: factor)
        let minimumFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        size.width = max(minimumFrameSize.width, ceil(size.width))
        size.height = max(minimumFrameSize.height, ceil(size.height))
        var rect = NSRect(x: window.frame.midX - size.width / 2, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        rect.origin.x = max(available.minX, min(rect.origin.x, available.maxX - rect.width))
        rect.origin.y = max(available.minY, min(rect.origin.y, available.maxY - rect.height))
        isApplyingScale = true
        window.setFrame(rect, display: true, animate: false)
        isApplyingScale = false
        presentation.refreshGeometry()
        presentation.layoutSubtreeIfNeeded()
    }
    private func captureScreenshot() async throws -> (CGImage, Data, CGFloat) {
        guard let image = screen.currentImage() else { throw SimulatorError(message: "The simulator has not produced a frame yet.") }
        let context = screen.renderer.engine.images
        // The requested pose may already have changed while its framebuffer is
        // still connecting. Describe the panel that produced these pixels.
        let chrome = screen.displayChrome ?? presentation.canvas.chrome
        let logicalWidth = screen.displayQuarterTurns % 2 == 0 ? chrome.logicalScreenSize.width : chrome.logicalScreenSize.height
        let radius = chrome.cornerRadius * image.extent.width / logicalWidth
        return try await Task.detached(priority: .userInitiated) {
            guard let frame = context.createCGImage(image, from: image.extent) else {
                throw SimulatorError(message: "Could not encode screenshot.")
            }
            return (frame, try ScreenshotImage.png(frame), radius)
        }.value
    }
    private func saveScreenshot() {
        let capturedAt = Date()
        capturePreviews.capture { [self] in
            do {
                let (image, data, radius) = try await self.captureScreenshot()
                let deviceName = self.deviceInfo.name
                let file = try await Task.detached(priority: .userInitiated) {
                    try CaptureFile.stage(data, deviceName: deviceName, date: capturedAt)
                }.value
                let source = self.window?.convertToScreen(self.screen.convert(self.screen.bounds, to: nil))
                self.capturePreviews.show(image, file: file, cornerRadius: radius, beside: self.window, from: source)
            } catch { self.report(error) }
        }
    }
    private func exportScreenshot() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(deviceInfo.name) Screenshot.png"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task {
                do { let (_, data, _) = try await self.captureScreenshot(); try data.write(to: url, options: .atomic) }
                catch { self.report(error) }
            }
        }
    }
    private func copyScreenshot() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (_, data, _) = try await captureScreenshot()
                guard !closed else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            } catch { report(error) }
        }
    }
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), let input else { return }
        Task {
            do {
                _ = try await CommandRunner.simctl(["pbcopy", deviceInfo.id], input: Data(text.utf8))
                guard connected, !closed else { return }
                input.key(0xe3, down: true); input.key(0x19, down: true)
                input.key(0x19, down: false); input.key(0xe3, down: false)
            } catch { report(error) }
        }
    }
    private func run(_ arguments: [String]) {
        Task {
            do { _ = try await CommandRunner.simctl(arguments); await store.refresh() }
            catch { report(error) }
        }
    }
    private func importFiles(_ urls: [URL]) {
        for url in urls {
            if url.pathExtension == "app" { run(["install", deviceInfo.id, url.path]) }
            else if ["png", "jpg", "jpeg", "heic", "mov", "mp4", "gif"].contains(url.pathExtension.lowercased()) {
                run(["addmedia", deviceInfo.id, url.path])
            } else { report(SimulatorError(message: "Drop an iOS Simulator .app bundle, photo, or video.")) }
        }
    }
    private func toggleRecording() {
        if isRecording { stopRecording(); return }
        do {
            let file = try CaptureFile.reserve(deviceName: deviceInfo.name, kind: .recording)
            try startRecording(to: file.temporaryURL)
        } catch { report(error) }
    }
    func startRecording(to url: URL, showPreview: Bool = true) throws {
        guard recording == nil else { return }
        let recordingChrome = screen.displayChrome ?? presentation.canvas.chrome
        let displayID = displayModes.isEmpty ? nil : connectedScreenID
        let session = try VideoRecording(deviceID: deviceInfo.id, displayID: displayID, outputURL: url)
        recording = session
        updateStatus()
        let file = CaptureFile(temporaryURL: url, kind: .recording)
        recordingTask = capturePreviews.capture { [self, session] in
            defer { recording = nil; recordingTask = nil; updateStatus() }
            do {
                try await session.waitUntilFinished()
                guard showPreview else { return }
                if closed {
                    let directory = capturePreviews.saveDirectory
                    _ = try await Task.detached(priority: .userInitiated) { try file.save(in: directory) }.value
                } else {
                    let image: CGImage
                    do {
                        // Keep larger quarter-screen thumbnails sharp on Retina displays.
                        let backing = window?.backingScaleFactor ?? 2
                        let posterSize = CGSize(width: max(1, ceil(screen.bounds.width * backing / 4)),
                            height: max(1, ceil(screen.bounds.height * backing / 4)))
                        image = try await VideoRecording.lastFrame(in: url, maximumSize: posterSize)
                    }
                    catch {
                        // Preserve a finalized movie even if poster decoding fails.
                        let directory = capturePreviews.saveDirectory
                        _ = try await Task.detached(priority: .userInitiated) { try file.save(in: directory) }.value
                        throw error
                    }
                    if closed {
                        let directory = capturePreviews.saveDirectory
                        _ = try await Task.detached(priority: .userInitiated) { try file.save(in: directory) }.value
                        return
                    }
                    let logicalWidth = image.width <= image.height
                        ? recordingChrome.logicalScreenSize.width : recordingChrome.logicalScreenSize.height
                    let radius = recordingChrome.cornerRadius * CGFloat(image.width) / logicalWidth
                    capturePreviews.show(image, file: file, cornerRadius: radius, beside: window)
                }
            } catch { report(error) }
        }
    }
    private func stopRecording() {
        recording?.stop()
        updateStatus()
    }
    func finishRecording() async {
        stopRecording()
        await recordingTask?.value
    }
    private func report(_ error: Error) {
        guard !closed, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Simulator action failed"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closed else { return true }
        guard closeTask == nil else { return false }
        guard settings.shutdownSimulatorOnWindowClose else { return true }
        connectTask?.cancel()
        closeTask = Task {
            defer { closeTask = nil }
            await finishRecording()
            disconnect(message: "Shutting down \(deviceInfo.name)…", canRetry: false)
            spinner.isHidden = false
            spinner.startAnimation(nil)
            do {
                try await store.shutdown(deviceInfo)
                // close() bypasses windowShouldClose; external shutdowns use this
                // same path to release the viewer without issuing another command.
                window?.close()
            } catch {
                disconnect(message: "Could not shut down \(deviceInfo.name). Close the window to try again.")
                report(error)
            }
        }
        return false
    }
    func waitForClose() async { await closeTask?.value }

    func windowWillClose(_ notification: Notification) {
        closed = true
        connectTask?.cancel()
        displaySwitchTask?.cancel()
        hingeAnimationTask?.cancel()
        deviceObservation?.cancel()
        presentation.isFullScreen = false
        stopRecording()
        screen.releaseKeys()
        stopDisplays()
        screen.display = nil; screen.input = nil; display = nil; input = nil
        onClose?()
    }
    func windowDidResignKey(_ notification: Notification) {
        (window as? DeviceHostWindow)?.endCornerResize()
        screen.releaseKeys()
    }
    func windowDidResize(_ notification: Notification) {
        guard presentation != nil, !isApplyingScale, !isEnteringFullScreen else { return }
        if hasEnteredFullScreen || presentation.isFullScreen {
            presentation.refreshGeometry()
            presentation.layoutSubtreeIfNeeded()
            if scalingMode.isAccurate, !canSelectScalingMode(scalingMode) {
                selectScalingMode(.fitScreen)
            }
        } else {
            guard (window as? DeviceHostWindow)?.isCornerResizing != true else { return }
            scalingMode = .custom
            presentation.canvas.pixelAligned = false
            presentation.canvas.maximumScale = nil
        }
    }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard presentation != nil, !isApplyingScale,
              scalingMode == .pixelAccurate || scalingMode == .physicalSize else { return }
        reapplyScalingMode()
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard presentation != nil, !isApplyingScale,
              scalingMode.isAccurate else { return }
        reapplyScalingMode()
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        (window as? DeviceHostWindow)?.endCornerResize()
        isEnteringFullScreen = true
        window?.level = .normal
        (window as? DeviceHostWindow)?.updatePresentationBackground()
        presentation.isFullScreen = true
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        // AppKit reveals the menu bar, status items and original window controls together.
        FullScreenChrome.presentationOptions(from: proposedOptions)
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isEnteringFullScreen = false
        presentation.isFullScreen = false
        restoreNormalChrome()
        updateWindowLevel()
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        isEnteringFullScreen = false
        hasEnteredFullScreen = true
        presentation.isFullScreen = true
        (window as? DeviceHostWindow)?.updatePresentationBackground()
        fullScreenChrome?.refresh()
        if scalingMode.isAccurate { reapplyScalingMode() }
        else { presentation.canvas.maximumScale = nil }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        isEnteringFullScreen = false
        hasEnteredFullScreen = false
        updateWindowLevel()
        presentation.isFullScreen = false
        restoreNormalChrome()
        if scalingMode.isAccurate { reapplyScalingMode() }
        else { presentation.canvas.maximumScale = nil }
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        presentation.isFullScreen = true
        (window as? DeviceHostWindow)?.updatePresentationBackground()
        fullScreenChrome?.refresh()
    }
    private func restoreNormalChrome() {
        fullScreenChrome?.refresh()
        guard let window else { return }
        (window as? DeviceHostWindow)?.updatePresentationBackground()
        presentation.controls.attach(to: window)
        presentation.controls.isHidden = false
        presentation.refreshGeometry()
    }
}
