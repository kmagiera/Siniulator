#if DEBUG
import AppKit
import AVFoundation

extension Diagnostics {
    static func recordingSmoke(app: AppDelegate) async {
        do {
            let directory = outputDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previousSaves = Set((try? FileManager.default.contentsOfDirectory(at: app.capturePreviews.saveDirectory, includingPropertiesForKeys: nil)) ?? [])
            await app.store.refresh()
            guard let device = app.store.devices.first(where: \.isBooted) else { throw SimulatorError(message: "Recording test needs an already booted device.") }
            app.open(device)
            guard let controller = app.deviceWindows[device.id], let window = controller.window else { throw SimulatorError(message: "Missing device window.") }
            for _ in 0..<150 {
                if controller.isConnected { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard controller.isConnected, let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
                  let recordItem = fileMenu.items.first(where: { $0.tag == DeviceCommand.recording.rawValue }),
                  let stopItem = fileMenu.items.first(where: { $0.tag == DeviceCommand.stopRecording.rawValue }) else {
                throw SimulatorError(message: "Recording menu or device connection is missing.")
            }
            func startFromMenu() throws {
                app.open(device)
                guard app.validateMenuItem(recordItem), recordItem.title == "Record Screen", !app.validateMenuItem(stopItem) else {
                    throw SimulatorError(message: "Idle recording menu should enable Record Screen and disable Stop Recording.")
                }
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
                guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true, controller.isRecording, window.attachedSheet == nil,
                      controller.presentation.controls.actionItems.count == 3,
                      controller.presentation.controls.actionItems[1].label == "Stop Recording",
                      !app.validateMenuItem(recordItem), recordItem.title == "Record Screen",
                      app.validateMenuItem(stopItem), stopItem.title == "Stop Recording" else {
                    throw SimulatorError(message: "Recording should start immediately without a sheet and replace Screenshot with Stop.")
                }
            }
            func finishedPreview() async throws -> CaptureThumbnail {
                await controller.finishRecording()
                guard !controller.isRecording, let preview = app.capturePreviews.previews.last, preview.kind == .recording,
                      preview.fileURL.pathExtension == "mp4", preview.window !== window, !preview.isPresenting,
                      controller.presentation.controls.actionItems[1].label == "Screenshot" else {
                    throw SimulatorError(message: "Finalized recording did not produce a draggable movie preview and restore Screenshot.")
                }
                return preview
            }
            try startFromMenu()
            for _ in 0..<100 {
                if controller.recordingHasStarted { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard controller.recordingHasStarted else { throw SimulatorError(message: "Encoder did not acknowledge its first frame.") }
            try await Task.sleep(for: .seconds(2))
            let bar = controller.presentation.controls
            if let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent("recording-toolbar.png")) }
            }
            fileMenu.update() // Opening File validates Stop Recording after the recording starts.
            fileMenu.performActionForItem(at: fileMenu.index(of: stopItem))
            guard controller.isStoppingRecording, !bar.actionItems[1].isEnabled,
                  !app.validateMenuItem(recordItem), !app.validateMenuItem(stopItem) else {
                throw SimulatorError(message: "Stop Recording menu did not request encoder finalization.")
            }
            let preview = try await finishedPreview()
            let duration = try await AVURLAsset(url: preview.fileURL).load(.duration)
            guard duration.seconds >= 1 else { throw SimulatorError(message: "Movie did not finalize as playable video.") }
            preview.cancelTimer()
            let source = preview.fileURL
            let copy = directory.appendingPathComponent("recording.mp4")
            if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: source, to: copy)
            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent("recording-thumbnail.png")) }
            }
            let destination = app.capturePreviews.saveDirectory.appendingPathComponent(source.lastPathComponent)
            preview.completeDrag(operation: .copy)
            try await Task.sleep(for: .milliseconds(250))
            guard !FileManager.default.fileExists(atPath: destination.path), app.capturePreviews.previews.isEmpty else {
                throw SimulatorError(message: "Successful recording drag callback did not consume the preview.")
            }
            print("PASS: Cmd-R starts without a modal; separate Record Screen and Stop Recording menu items validate independently, Stop Recording finalizes a playable \(duration.seconds)-second MP4, restores Screenshot and presents its poster beside the window; successful-drag callback consumes the movie")

            let originalRecordingFrame = window.frame
            if let host = window.screen {
                window.setFrameOrigin(CGPoint(x: host.visibleFrame.maxX - window.frame.width, y: window.frame.minY))
            }
            controller.toggleStayOnTop()
            try startFromMenu()
            // Exercise Stop before the first-frame acknowledgement reaches AppKit.
            let item = controller.presentation.controls.actionItems[1]
            NSApp.sendAction(item.action!, to: item.target, from: item)
            let quick = try await finishedPreview()
            let quickDuration = try await AVURLAsset(url: quick.fileURL).load(.duration)
            guard quickDuration.seconds > 0 else { throw SimulatorError(message: "Immediate Stop lost the first frame.") }
            guard let quickPanel = quick.window,
                  quickPanel.frame.midX < window.frame.midX,
                  abs(quick.imageRect.width - controller.screen.bounds.width / 4) < 1,
                  abs(quick.imageRect.height - controller.screen.bounds.height / 4) < 1 else {
                throw SimulatorError(message: "Movie preview did not use quarter-screen sizing and the left side at the display edge.")
            }
            let saved = app.capturePreviews.saveDirectory.appendingPathComponent(quick.fileURL.lastPathComponent)
            // Reset the pointer state through the real callback so a stationary
            // pointer near the preview cannot prevent this unattended timer test.
            quick.mouseExited(with: NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: quick.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
            let quickTimer = ContinuousClock.now
            try await Task.sleep(for: .seconds(4.7))
            guard !quick.isFinished else { throw SimulatorError(message: "Movie preview retreated before five seconds.") }
            for _ in 0..<40 {
                if quick.isFinished { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard quick.isFinished, ContinuousClock.now - quickTimer >= .seconds(4.9),
                  let retreat = quick.window, retreat.title == "Capture Preview Dismissal",
                  retreat.level == window.level, retreat.level == .floating,
                  quick.alphaValue == 1, retreat.convertToScreen(quick.frame).midX > quickPanel.frame.midX else {
                throw SimulatorError(message: "Movie preview did not slide right under its Stay On Top window after five seconds.")
            }
            for _ in 0..<70 {
                if FileManager.default.fileExists(atPath: saved.path), app.capturePreviews.previews.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: saved.path), app.capturePreviews.previews.isEmpty,
                  try Data(contentsOf: quick.fileURL) == Data(contentsOf: saved) else {
                throw SimulatorError(message: "Unused movie preview did not autosave the unchanged MP4 after five seconds.")
            }
            controller.toggleStayOnTop()
            window.setFrame(originalRecordingFrame, display: true, animate: false)
            print("PASS: immediate Stop waits for the first frame; quarter-screen movie preview on the left retreats right under its Stay On Top window after five seconds and saves an unchanged MP4 (QA directory)")

            try startFromMenu()
            window.close()
            await app.capturePreviews.savePendingAndDismiss()
            guard !controller.isRecording, app.capturePreviews.previews.isEmpty, !app.capturePreviews.hasPendingSaves,
                  try Set(FileManager.default.contentsOfDirectory(at: app.capturePreviews.saveDirectory, includingPropertiesForKeys: nil)).subtracting(previousSaves).count == 2 else {
                throw SimulatorError(message: "Closing a recording window lost the in-flight movie.")
            }
            print("PASS: closing a recording window and flushing application captures finalizes and saves the movie exactly once")
            try Data("PASS: separate Record Screen and Stop Recording menu states and dispatch, no-modal start, native Stop button, encoder finalization, playable MP4, last-frame preview, drag completion callback, five-second autosave, immediate Stop and window-close/application-flush preservation\nSKIP: actual cross-app pointer drag and drop not exercised\n".utf8).write(to: directory.appendingPathComponent("recording-results.txt"))
        } catch {
            for controller in app.deviceWindows.values where controller.isRecording { await controller.finishRecording() }
            await app.capturePreviews.savePendingAndDismiss()
            fputs("RECORDING FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
