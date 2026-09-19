#if DEBUG
import AppKit

extension Diagnostics {
    static func rotationSmoke(app: AppDelegate) async {
        var controller: DeviceWindowController?
        var originalFrame: CGRect?
        var originalOrientation = 0
        var originalBezels = true
        var originalScale: CGFloat?
        let directory = outputDirectory()
        func rotate(_ target: DeviceWindowController, to turns: Int, command: DeviceCommand) async throws {
            if target.screen.quarterTurns != turns { target.perform(command) }
            for _ in 0..<100 {
                if target.screen.quarterTurns == turns { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let isFoldable = target.presentation.canvas.chrome.displayMode != nil
            let guestTurns = isFoldable ? turns
                : try await target.screen.input?.orientationTurns(udid: target.deviceInfo.id)
            guard target.screen.quarterTurns == turns, guestTurns == turns else {
                throw SimulatorError(message: "Guest orientation did not reach \(turns).")
            }
            // quarterTurns changes before the window finishes applying the
            // preserved scale. Wait for that MainActor task to settle.
            try await Task.sleep(for: .milliseconds(100))
            target.presentation.layoutSubtreeIfNeeded()
        }
        func restore() async throws {
            guard let controller, let originalFrame else { return }
            let commands: [DeviceCommand] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
            if controller.screen.quarterTurns != originalOrientation {
                try await rotate(controller, to: originalOrientation, command: commands[originalOrientation])
            }
            if controller.showsBezels != originalBezels { controller.perform(.showBezels) }
            controller.window?.setFrame(originalFrame, display: true, animate: false)
            controller.presentation.canvas.maximumScale = originalScale
            controller.presentation.refreshGeometry()
            controller.presentation.layoutSubtreeIfNeeded()
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await app.store.refresh()
            guard let device = app.store.devices.first(where: \.isBooted) else {
                throw SimulatorError(message: "Rotation test requires an already booted simulator.")
            }
            app.open(device)
            guard let target = app.deviceWindows[device.id], let window = target.window else {
                throw SimulatorError(message: "Rotation test could not open the device window.")
            }
            for _ in 0..<100 {
                if target.isConnected { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard target.isConnected else { throw SimulatorError(message: "Simulator connection timed out.") }
            controller = target
            originalFrame = window.frame
            originalOrientation = target.screen.quarterTurns
            originalBezels = target.showsBezels
            originalScale = target.presentation.canvas.maximumScale
            try await rotate(target, to: 0, command: .portrait)
            let root = target.presentation!
            var results: [String] = []
            for bezels in [true, false] {
                if target.showsBezels != bezels { target.perform(.showBezels) }
                for manuallyResized in [false, true] {
                    target.resize(scale: 0.15)
                    if manuallyResized {
                        var frame = window.frame
                        frame.size = CGSize(width: 380, height: 560)
                        window.setFrame(frame, display: true, animate: false)
                        // The delegate notification exercises the same custom
                        // sizing state entered by AppKit's manual resizer.
                        target.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
                    }
                    root.layoutSubtreeIfNeeded()
                    let initialScale = root.canvas.fittedGeometry.scale
                    let initialScreen = root.canvas.screen.frame.size
                    for (turns, command) in [(1, DeviceCommand.rotateRight), (0, .rotateLeft),
                                             (2, .portraitUpsideDown), (3, .landscapeLeft), (0, .portrait)] {
                        try await rotate(target, to: turns, command: command)
                        let scale = root.canvas.fittedGeometry.scale
                        let screenSize = root.canvas.screen.frame.size
                        let expected = turns % 2 == 0 ? initialScreen : CGSize(width: initialScreen.height, height: initialScreen.width)
                        guard target.scalingMode == .custom,
                              abs(scale - initialScale) < 0.000001,
                              abs(screenSize.width - expected.width) < 0.01,
                              abs(screenSize.height - expected.height) < 0.01 else {
                            throw SimulatorError(message: "Rotation reset custom size: bezels=\(bezels), manual=\(manuallyResized), turns=\(turns), mode=\(target.scalingMode), scale=\(scale), expected=\(initialScale), screen=\(screenSize), expectedScreen=\(expected).")
                        }
                        let expectedWindow = root.normalSize(scale: initialScale)
                        let minimumFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
                        let expectedSize = CGSize(width: max(minimumFrameSize.width, ceil(expectedWindow.width)),
                            height: max(minimumFrameSize.height, ceil(expectedWindow.height)))
                        let nativeChromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
                        guard abs(window.frame.width - expectedSize.width) < 0.01,
                              window.frame.height >= expectedSize.height - 0.01,
                              window.frame.height <= expectedSize.height + nativeChromeHeight + 0.01 else {
                            throw SimulatorError(message: "Rotation window size \(window.frame.size) does not match the preserved scale size \(expectedWindow) or AppKit minimum \(minimumFrameSize).")
                        }
                    }
                    results.append("PASS: custom rotation scale, bezels=\(bezels), manual resize=\(manuallyResized); left/right and all four orientations; scale=\(initialScale).")
                }
            }
            try await restore()
            let result = results.joined(separator: "\n") + "\n"
            try Data(result.utf8).write(to: directory.appendingPathComponent("rotation-results.txt"))
            print(result)
        } catch {
            try? await restore()
            fputs("ROTATION FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
