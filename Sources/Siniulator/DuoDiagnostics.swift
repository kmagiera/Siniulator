#if DEBUG
import AppKit

extension Diagnostics {
    @MainActor static func duoSmoke(app: AppDelegate) async {
        let directory = outputDirectory()
        var controller: DeviceWindowController?
        var savedFrame: CGRect?
        var savedTurns = 0
        var savedAngle = 180.0

        func restore() async {
            guard let target = controller, let window = target.window, let frame = savedFrame else { return }
            target.diagnosticSetHingeAngle(savedAngle)
            for _ in 0..<500 {
                if !target.diagnosticDisplaySwitchInProgress { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if target.screen.quarterTurns != savedTurns {
                target.perform(orientationCommand(for: savedTurns))
                for _ in 0..<100 {
                    if target.screen.quarterTurns == savedTurns { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            // Rotation reapplies the logical scale asynchronously. Put the saved
            // frame back only after it has settled, then persist exactly that
            // frame instead of letting the diagnostic shrink future launches.
            try? await Task.sleep(for: .milliseconds(150))
            window.setFrame(frame, display: false, animate: false)
            window.saveFrame(usingName: "framed-device-\(target.deviceInfo.id)")
            let mode = DeviceDisplayMode.mode(forHingeAngle: savedAngle)
            UserDefaults.standard.set(mode.rawValue, forKey: "display-mode-\(target.deviceInfo.id)")
            UserDefaults.standard.set(savedAngle, forKey: "hinge-angle-\(target.deviceInfo.id)")
            UserDefaults.standard.set(savedTurns, forKey: "orientation-\(target.deviceInfo.id)")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await app.store.refresh()
            guard let device = app.store.devices.first(where: {
                $0.isBooted && DeviceChrome.displayModes(for: $0) == DeviceDisplayMode.allCases
            }) else {
                throw SimulatorError(message: "Duo test requires a booted foldable simulator.")
            }
            app.open(device)
            guard let target = app.deviceWindows[device.id], let window = target.window else {
                throw SimulatorError(message: "Duo test could not open the device window.")
            }
            for _ in 0..<600 {
                if target.isConnected || !target.isConnecting { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard target.isConnected else {
                throw SimulatorError(message: "Duo connection failed: \(target.diagnosticConnectionMessage)")
            }

            controller = target
            savedFrame = window.frame
            savedTurns = target.screen.quarterTurns
            savedAngle = target.diagnosticHingeAngle

            func assertStableWindow(_ expected: CGRect, context: String) throws {
                let actual = window.frame
                guard abs(actual.minX - expected.minX) <= 0.5,
                      abs(actual.minY - expected.minY) <= 0.5,
                      abs(actual.width - expected.width) <= 0.5,
                      abs(actual.height - expected.height) <= 0.5 else {
                    throw SimulatorError(message: "Duo changed its window during \(context): \(expected) -> \(actual).")
                }
            }

            func assertChrome(context: String) throws {
                // Check the settled native widgets BEFORE forcing content layout;
                // otherwise that layout can hide an AppKit titlebar reset.
                let controls = target.presentation.controls
                for button in controls.windowButtons {
                    let frame = controls.convert(button.bounds, from: button)
                    guard frame.minX >= 0, frame.maxX <= controls.bounds.maxX else {
                        throw SimulatorError(message: "Duo traffic light escaped the toolbar during \(context): \(frame), bar=\(controls.bounds).")
                    }
                }
                target.presentation.layoutSubtreeIfNeeded()
                target.presentation.controls.layoutSubtreeIfNeeded()
                let canvas = target.presentation.canvas
                guard !target.diagnosticShowsConnectionOverlay else {
                    throw SimulatorError(message: "Duo showed the Starting overlay during \(context).")
                }
                guard abs(canvas.frame.minY - controls.frame.maxY) <= 0.5 else {
                    throw SimulatorError(message: "Duo toolbar gap is \(canvas.frame.minY - controls.frame.maxY) points during \(context).")
                }
                guard let selector = controls.displayModeControl,
                      abs(controls.convert(selector.bounds, from: selector).midX - controls.bounds.midX) <= 1 else {
                    throw SimulatorError(message: "Duo mode controls are not centered during \(context).")
                }
                guard selector.selectedSegment == DeviceDisplayMode.selectedMode(
                    forHingeAngle: target.diagnosticHingeAngle).rawValue else {
                    throw SimulatorError(message: "Duo lost its pose selection during \(context).")
                }
                let selectorFrame = controls.convert(selector.bounds, from: selector)
                guard !controls.barLayout.name.intersects(selectorFrame),
                      !controls.barLayout.runtime.intersects(selectorFrame) else {
                    throw SimulatorError(message: "Duo title overlaps the centered selector during \(context).")
                }
            }

            func waitForMode(_ mode: DeviceDisplayMode, preserving frame: CGRect,
                             context: String, invoke: Bool = true) async throws {
                let chrome = DeviceChrome.load(for: device, displayMode: mode)
                if invoke { target.perform(command(for: mode)) }
                for _ in 0..<500 {
                    try assertStableWindow(frame, context: context)
                    try assertChrome(context: context)
                    guard !target.diagnosticShowsConnectionOverlay else {
                        throw SimulatorError(message: "Duo showed the Starting overlay during \(context).")
                    }
                    if target.displayMode == mode,
                       target.diagnosticConnectedScreenID == chrome.screenID,
                       !target.diagnosticDisplaySwitchInProgress,
                       !target.diagnosticHingeAnimationInProgress,
                       target.diagnosticHingeAngle == mode.hingeAngle,
                       target.screen.framebufferSize != .zero { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard target.displayMode == mode,
                      target.diagnosticConnectedScreenID == chrome.screenID,
                      !target.diagnosticDisplaySwitchInProgress,
                      !target.diagnosticHingeAnimationInProgress,
                      target.diagnosticHingeAngle == mode.hingeAngle,
                      target.screen.framebufferSize != .zero else {
                    throw SimulatorError(message: "Duo did not finish switching to \(mode.label) during \(context).")
                }
                try await Task.sleep(for: .milliseconds(950))
                try assertStableWindow(frame, context: context)
                try assertChrome(context: context)
            }

            func rotate(to turns: Int) async throws {
                if target.screen.quarterTurns != turns {
                    target.perform(orientationCommand(for: turns))
                }
                for _ in 0..<100 {
                    if target.screen.quarterTurns == turns { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard target.screen.quarterTurns == turns else {
                    throw SimulatorError(message: "Duo did not rotate to quarter turn \(turns).")
                }
                try await Task.sleep(for: .milliseconds(100))
                target.presentation.layoutSubtreeIfNeeded()
            }

            func saveSnapshot(mode: DeviceDisplayMode, turns: Int) throws {
                guard let image = target.presentation.canvas.duoSnapshot(),
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]),
                      !png.isEmpty else {
                    throw SimulatorError(message: "Could not render Duo snapshot for \(mode.label), turn \(turns).")
                }
                try png.write(to: directory.appendingPathComponent("duo-\(mode.fileName)-turn-\(turns).png"))
            }

            func stableFramebufferPNG(filename: String) async throws -> (data: Data, size: CGSize) {
                var previous: Data?
                var matchingFrames = 0
                for _ in 0..<50 {
                    guard let image = target.screen.screenshot(),
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                          !data.isEmpty else {
                        throw SimulatorError(message: "Could not capture the live Duo framebuffer.")
                    }
                    if data == previous { matchingFrames += 1 } else { matchingFrames = 0 }
                    if matchingFrames >= 2 {
                        try data.write(to: directory.appendingPathComponent(filename))
                        return (data, CGSize(width: image.width, height: image.height))
                    }
                    previous = data
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw SimulatorError(message: "The Duo framebuffer did not settle before screenshot verification.")
            }

            func decodedSize(_ data: Data, context: String) throws -> CGSize {
                guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
                    throw SimulatorError(message: "\(context) is not a decodable PNG.")
                }
                return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            }

            var widths: [DeviceDisplayMode: CGFloat] = [:]
            for turns in 0..<4 {
                try await rotate(to: turns)
                let frame = window.frame
                for mode in DeviceDisplayMode.allCases {
                    let context = "\(mode.label), quarter turn \(turns)"
                    try await waitForMode(mode, preserving: frame, context: context)
                    guard target.presentation.controls.displayModeControl?.selectedSegment == mode.rawValue else {
                        throw SimulatorError(message: "Duo toolbar selected the wrong mode during \(context).")
                    }
                    if turns == 0 { widths[mode] = target.presentation.controls.frame.width }
                    try saveSnapshot(mode: mode, turns: turns)
                    try queuedCornerResizeSmoke(controller: target)
                    try assertStableWindow(frame, context: "corner resize rollback during \(context)")
                }
            }
            guard let coverWidth = widths[.cover], let partialWidth = widths[.innerPartiallyOpen],
                  let openWidth = widths[.innerFullyOpen] else {
                throw SimulatorError(message: "Duo toolbar geometry was not measured in every mode.")
            }

            try await rotate(to: 0)
            try await waitForMode(.innerFullyOpen, preserving: window.frame, context: "slow close setup")
            let viewport = target.screen.bounds.size
            var transitionLog: [String] = []
            for angle in stride(from: 40.0, through: 0.0, by: -1.0) {
                target.diagnosticSetHingeAngle(angle)
                try await Task.sleep(for: .milliseconds(100))
                target.presentation.layoutSubtreeIfNeeded()
                guard target.screen.bounds.size == viewport,
                      target.screen.renderer.layer.opacity == 0 else {
                    throw SimulatorError(message: "Duo changed its viewport or exposed the 2D framebuffer at \(angle)°")
                }
                transitionLog.append("angle=\(angle) readyPanels=\(target.diagnosticReadyPanelIDs)")
                if Int(angle).isMultiple(of: 2), let image = target.presentation.canvas.duoSnapshot(),
                   let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("slow-close-\(Int(angle)).png"))
                }
            }
            try Data(transitionLog.joined(separator: "\n").utf8)
                .write(to: directory.appendingPathComponent("slow-close.txt"))
            let gestureFrame = window.frame
            var previousToolbarWidth: CGFloat = .greatestFiniteMagnitude
            for angle in stride(from: 180.0, through: 0.0, by: -5.0) {
                target.diagnosticSetHingeAngle(angle)
                try assertStableWindow(gestureFrame, context: "continuous close at \(angle)°")
                try assertChrome(context: "continuous close at \(angle)°")
                let width = target.presentation.controls.frame.width
                guard width <= previousToolbarWidth + 0.5 else {
                    throw SimulatorError(message: "Duo toolbar grew again while closing at \(angle)°: \(previousToolbarWidth) -> \(width).")
                }
                previousToolbarWidth = width
                try await Task.sleep(for: .milliseconds(16))
            }
            try await waitForMode(.cover, preserving: gestureFrame, context: "continuous close")
            for angle in stride(from: 0.0, through: 180.0, by: 5.0) {
                target.diagnosticSetHingeAngle(angle)
                try assertStableWindow(gestureFrame, context: "continuous open at \(angle)°")
                try assertChrome(context: "continuous open at \(angle)°")
                try await Task.sleep(for: .milliseconds(16))
            }
            try await waitForMode(.innerFullyOpen, preserving: gestureFrame, context: "continuous open")

            target.diagnosticSetHingeAngle(60)
            guard let selector = target.presentation.controls.displayModeControl,
                  selector.selectedSegment == 1, let action = selector.action,
                  NSApp.sendAction(action, to: selector.target, from: selector) else {
                throw SimulatorError(message: "The selected middle Duo button did not dispatch its preset.")
            }
            try await waitForMode(.innerPartiallyOpen, preserving: gestureFrame,
                context: "selected middle button from 60°", invoke: false)
            target.perform(.coverScreen)
            try await Task.sleep(for: .milliseconds(150))
            let interruptedAngle = target.diagnosticHingeAngle
            target.perform(.innerPartiallyOpen)
            guard target.diagnosticHingeAngle == interruptedAngle else {
                throw SimulatorError(message: "Retargeting the Duo animation jumped to a preset.")
            }
            try await waitForMode(.innerPartiallyOpen, preserving: gestureFrame,
                context: "retargeted preset", invoke: false)

            // Exercise the commands behind both screenshot menu items and the
            // toolbar button on a projected (non-flat) Duo. A window resize must
            // not crop, rotate or rescale the simulator framebuffer capture.
            try await waitForMode(.innerPartiallyOpen, preserving: gestureFrame, context: "screenshot and resize verification")
            let beforeResize = try await stableFramebufferPNG(filename: "duo-framebuffer-before-resize.png")
            try queuedCornerResizeSmoke(controller: target)
            try assertStableWindow(gestureFrame, context: "screenshot resize rollback")
            let afterResize = try await stableFramebufferPNG(filename: "duo-framebuffer-after-resize.png")
            guard beforeResize.size == afterResize.size,
                  beforeResize.size == target.screen.framebufferSize,
                  beforeResize.data == afterResize.data else {
                throw SimulatorError(message: "Corner resizing changed the settled screenshot: \(beforeResize.size) -> \(afterResize.size), framebuffer \(target.screen.framebufferSize).")
            }

            let pasteboard = NSPasteboard.general
            let oldChangeCount = pasteboard.changeCount
            target.perform(.copyScreenshot)
            for _ in 0..<100 {
                if pasteboard.changeCount != oldChangeCount, pasteboard.data(forType: .png) != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard pasteboard.changeCount != oldChangeCount,
                  let copiedPNG = pasteboard.data(forType: .png),
                  try decodedSize(copiedPNG, context: "Copied Duo screenshot") == beforeResize.size else {
                throw SimulatorError(message: "Copy Screen did not put a full-size Duo PNG on the pasteboard.")
            }
            try copiedPNG.write(to: directory.appendingPathComponent("duo-copied-screenshot.png"))

            try FileManager.default.createDirectory(at: app.capturePreviews.saveDirectory, withIntermediateDirectories: true)
            target.perform(.screenshot)
            for _ in 0..<100 {
                if app.capturePreviews.previews.last?.kind == .screenshot { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let preview = app.capturePreviews.previews.last, preview.kind == .screenshot else {
                throw SimulatorError(message: "Save Screen did not create its screenshot preview.")
            }
            let savedURL = app.capturePreviews.saveDirectory.appendingPathComponent(preview.fileURL.lastPathComponent)
            await app.capturePreviews.savePendingAndDismiss()
            guard let savedPNG = try? Data(contentsOf: savedURL),
                  try decodedSize(savedPNG, context: "Saved Duo screenshot") == beforeResize.size,
                  app.capturePreviews.previews.isEmpty, !app.capturePreviews.hasPendingSaves else {
                throw SimulatorError(message: "Save Screen did not persist exactly one full-size Duo PNG.")
            }

            let movieURL = directory.appendingPathComponent("duo-active-panel.mp4")
            if FileManager.default.fileExists(atPath: movieURL.path) {
                try FileManager.default.removeItem(at: movieURL)
            }
            try target.startRecording(to: movieURL, showPreview: false)
            for _ in 0..<100 {
                if target.recordingHasStarted { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard target.recordingHasStarted else {
                throw SimulatorError(message: "Duo recording did not start on the active inner display.")
            }
            try await Task.sleep(for: .milliseconds(500))
            await target.finishRecording()
            let movieFrame = try await VideoRecording.lastFrame(in: movieURL, maximumSize: .zero)
            let movieSize = CGSize(width: movieFrame.width, height: movieFrame.height)
            let framebufferSize = target.screen.framebufferSize
            // H.264 requires even dimensions, so simctl trims one pixel from
            // each odd edge of Duo's 2007×2853 inner framebuffer.
            guard abs(movieSize.width - framebufferSize.width) <= 1,
                  abs(movieSize.height - framebufferSize.height) <= 1 else {
                throw SimulatorError(message: "Duo recording used the wrong display: movie \(movieSize), active framebuffer \(target.screen.framebufferSize).")
            }

            let result = "PASS: Duo switched three modes without a Starting overlay or window resize; "
                + "all modes rendered in four orientations; continuous 5° hinge steps stayed stable; "
                + "all four visible resize corners worked in every mode and orientation; "
                + "Save Screen and Copy Screen produced full-size PNGs before and after resizing; "
                + "recording captured the active inner panel; "
                + "toolbar widths cover=\(coverWidth), partial=\(partialWidth), open=\(openWidth).\n"
            try Data(result.utf8).write(to: directory.appendingPathComponent("duo-results.txt"))
            await restore()
            print(result, terminator: "")
        } catch {
            if let controller, controller.isRecording { await controller.finishRecording() }
            await restore()
            fputs("DUO FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func command(for mode: DeviceDisplayMode) -> DeviceCommand {
        switch mode {
        case .cover: .coverScreen
        case .innerPartiallyOpen: .innerPartiallyOpen
        case .innerFullyOpen: .innerFullyOpen
        }
    }

    private static func orientationCommand(for turns: Int) -> DeviceCommand {
        [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft][ScreenGeometry.normalizedQuarterTurns(turns)]
    }
}

private extension DeviceDisplayMode {
    var fileName: String {
        switch self {
        case .cover: "cover"
        case .innerPartiallyOpen: "partial"
        case .innerFullyOpen: "open"
        }
    }
}
#endif
