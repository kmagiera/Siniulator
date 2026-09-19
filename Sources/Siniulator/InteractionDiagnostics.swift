#if DEBUG
import AppKit
import AVFoundation

extension Diagnostics {
    static func exercise(app: AppDelegate, udid: String) async {
        do {
            await app.store.refresh()
            guard let device = app.store.devices.first(where: { $0.id == udid }) else { throw SimulatorError(message: "Unknown QA device.") }
            _ = try await CommandRunner.run("/usr/bin/xcrun", ["devicectl", "device", "orientation", "set", "--device", udid, "portrait", "--quiet", "--timeout", "5"])
            _ = try await CommandRunner.simctl(["launch", "--terminate-running-process", udid, "dev.siniulator.interaction-qa"])
            app.open(device)
            guard let controller = app.deviceWindows[udid] else { throw SimulatorError(message: "Missing QA window.") }
            for _ in 0..<150 {
                if controller.isConnected { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard controller.isConnected else { throw SimulatorError(message: "QA display did not connect.") }
            let path = String(decoding: try await CommandRunner.simctl(["get_app_container", udid, "dev.siniulator.interaction-qa", "data"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let stateURL = URL(fileURLWithPath: path).appendingPathComponent("Documents/state.json")
            func state() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any] ?? [:] }
            func awaitState(_ description: String, _ predicate: ([String: Any]) -> Bool) async throws {
                for _ in 0..<120 {
                    if let value = try? state(), predicate(value) { print("PASS: \(description)"); return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw SimulatorError(message: "\(description) failed; guest state: \((try? state()) ?? [:])")
            }
            try await awaitState("UIKit fixture ready") { $0["ready"] as? Bool == true }
            try await Task.sleep(for: .milliseconds(500))
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKey()
            try await Task.sleep(for: .milliseconds(300))
            controller.window?.makeFirstResponder(controller.screen)
            let screen = controller.screen
            func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, option: Bool = false, shift: Bool = false) throws -> NSEvent {
                let width = try state()["width"] as? Double ?? 402
                let height = try state()["height"] as? Double ?? 874
                guard let image = screen.currentImage(), let window = controller.window else { throw SimulatorError(message: "Missing image") }
                let rect = ScreenGeometry.imageRect(image: image.extent.size, in: screen.bounds)
                let local = CGPoint(x: rect.minX + x / width * rect.width, y: rect.minY + y / height * rect.height)
                let location = screen.convert(local, to: nil)
                var modifiers: NSEvent.ModifierFlags = option ? .option : []
                if shift { modifiers.insert(.shift) }
                return NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            func tap(x: CGFloat, y: CGFloat) async throws {
                screen.mouseDown(with: try event(.leftMouseDown, x: x, y: y))
                try await Task.sleep(for: .milliseconds(80))
                screen.mouseUp(with: try event(.leftMouseUp, x: x, y: y))
            }
            func shortcut(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags) throws {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
                guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw SimulatorError(message: "Shortcut \(key) was not dispatched.") }
            }
            try await tap(x: 200, y: 228)
            try await awaitState("Native mouse tap reaches UIKit") { $0["taps"] as? Int == 1 }
            try await tap(x: 100, y: 154)
            try await Task.sleep(for: .milliseconds(400))
            for (key, code) in zip(Array("swift123"), [UInt16(1), 13, 34, 3, 17, 18, 19, 20]) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber, context: nil, characters: String(key), charactersIgnoringModifiers: String(key), isARepeat: false, keyCode: code)!
                    if type == .keyDown { screen.keyDown(with: event) } else { screen.keyUp(with: event) }
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            try await awaitState("Physical keyboard events reach UITextField") { $0["text"] as? String == "swift123" }
            try await awaitState("UIKit sees the hardware keyboard attached") { $0["hardwareKeyboardAttached"] as? Bool == true }
            // Observe UIKit's real keyboard frame, not just the host checkbox.
            guard let ioMenu = NSApp.mainMenu?.items.first(where: { $0.title == "I/O" })?.submenu,
                  let keyboardMenu = ioMenu.items.first(where: { $0.title == "Keyboard" })?.submenu,
                  let hardwareItem = keyboardMenu.items.first(where: { $0.tag == DeviceCommand.hardwareKeyboard.rawValue }),
                  app.validateMenuItem(hardwareItem),
                  hardwareItem.state == .on else { throw SimulatorError(message: "Missing native keyboard menu or hardware keyboard connection.") }
            try shortcut("K", code: 40, flags: [.command, .shift])
            guard app.validateMenuItem(hardwareItem), hardwareItem.state == .off else { throw SimulatorError(message: "Hardware keyboard checkbox did not turn off.") }
            try await awaitState("UIKit sees the hardware keyboard detached") { $0["hardwareKeyboardAttached"] as? Bool == false }
            try await awaitState("Disconnecting hardware keyboard shows UIKit software keyboard") { $0["keyboardVisible"] as? Bool == true }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
                if type == .keyDown { screen.keyDown(with: key) } else { screen.keyUp(with: key) }
            }
            try await awaitState("Typing remains available in software keyboard mode") { $0["text"] as? String == "swift123x" }
            keyboardMenu.performActionForItem(at: keyboardMenu.index(of: hardwareItem))
            guard app.validateMenuItem(hardwareItem), hardwareItem.state == .on else { throw SimulatorError(message: "Hardware keyboard checkbox did not turn back on.") }
            try await awaitState("UIKit sees the hardware keyboard reattached") { $0["hardwareKeyboardAttached"] as? Bool == true }
            for (index, type) in [NSEvent.EventType.flagsChanged, .keyDown, .keyUp, .flagsChanged].enumerated() {
                let flags: NSEvent.ModifierFlags = index == 3 ? [] : [.shift]
                let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber, context: nil, characters: "@", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: type == .flagsChanged ? 56 : 19)!
                if type == .flagsChanged { screen.flagsChanged(with: key) }
                else if type == .keyDown { screen.keyDown(with: key) }
                else { screen.keyUp(with: key) }
            }
            try await awaitState("Shift-2 types @ through the hardware keyboard") { $0["text"] as? String == "swift123x@" }
            try await tap(x: 200, y: 228)
            try await Task.sleep(for: .milliseconds(300))
            screen.mouseDown(with: try event(.leftMouseDown, x: 100, y: 340))
            for step in 1...12 {
                screen.mouseDragged(with: try event(.leftMouseDragged, x: 100 + CGFloat(step) * 8, y: 340 + CGFloat(step) * 12))
                try await Task.sleep(for: .milliseconds(20))
            }
            screen.mouseUp(with: try event(.leftMouseUp, x: 196, y: 484))
            try await awaitState("Drag delivers begin, move, and end") { ($0["begins"] as? Int ?? 0) > 0 && ($0["moves"] as? Int ?? 0) > 0 && ($0["ends"] as? Int ?? 0) > 0 }
            screen.mouseDown(with: try event(.leftMouseDown, x: 140, y: 380, option: true))
            try await Task.sleep(for: .milliseconds(100))
            screen.mouseDragged(with: try event(.leftMouseDragged, x: 110, y: 350, option: true))
            try await Task.sleep(for: .milliseconds(100))
            screen.mouseUp(with: try event(.leftMouseUp, x: 110, y: 350, option: true))
            try await awaitState("Option drag produces two UIKit touches") { ($0["maxTouches"] as? Int ?? 0) == 2 }
            screen.mouseDown(with: try event(.leftMouseDown, x: 140, y: 380, option: true))
            func positions(_ value: [String: Any]) -> [[String: Double]] {
                (value["touchPositions"] as? [[String: Double]] ?? []).sorted { $0["x", default: 0] < $1["x", default: 0] }
            }
            try await awaitState("Second two-finger gesture reaches UIKit") { value in
                positions(value).contains {
                    abs($0["x", default: 0] - 140) < 2 && abs($0["y", default: 0] - 380) < 2
                }
            }
            let before = positions(try state())
            // Switch modes at the stationary pointer before dragging; real
            // input delivers a Shift flagsChanged event between these moves.
            screen.mouseDragged(with: try event(.leftMouseDragged, x: 140, y: 380, option: true, shift: true))
            try await Task.sleep(for: .milliseconds(50))
            screen.mouseDragged(with: try event(.leftMouseDragged, x: 180, y: 420, option: true, shift: true))
            try await awaitState("Option-Shift translates both real UIKit touches together") { value in
                let after = positions(value)
                guard before.count == 2, after.count == 2 else { return false }
                return zip(before, after).allSatisfy {
                    abs($1["x", default: 0] - $0["x", default: 0] - 40) < 2 &&
                    abs($1["y", default: 0] - $0["y", default: 0] - 40) < 2
                }
            }
            screen.mouseUp(with: try event(.leftMouseUp, x: 180, y: 420, option: true, shift: true))
            var inputLatency: [Double] = []
            for _ in 0..<20 {
                let down = try event(.leftMouseDown, x: 100, y: 340)
                let sent = CACurrentMediaTime()
                screen.mouseDown(with: down)
                for _ in 0..<200 {
                    let received = (try? state()["touchBeginReceiptUptime"] as? Double) ?? 0
                    if received >= sent { inputLatency.append((received - sent) * 1000); break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                screen.mouseUp(with: try event(.leftMouseUp, x: 100, y: 340))
                try await Task.sleep(for: .milliseconds(30))
            }
            guard inputLatency.count == 20 else { throw SimulatorError(message: "Input latency receipt timestamps missing.") }
            inputLatency.sort()
            let latencyReport = String(format: "NSEvent handler → guest UIWindow receipt, 20 samples: p50 %.3f ms, p95 %.3f ms. Excludes physical mouse, host event delivery and screen presentation.\n", inputLatency[10], inputLatency[19])
            let latencyDirectory = outputDirectory()
            try FileManager.default.createDirectory(at: latencyDirectory, withIntermediateDirectories: true)
            try Data(latencyReport.utf8).write(to: latencyDirectory.appendingPathComponent("input-latency.txt"))
            print(latencyReport)
            try shortcut(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124, flags: .command)
            try await awaitState("Rotate shortcut changes real iOS orientation") { ($0["width"] as? Double ?? 0) > ($0["height"] as? Double ?? 0) }
            try await Task.sleep(for: .milliseconds(500))
            try await tap(x: 200, y: 228)
            try await awaitState("Touch coordinates remain correct in landscape") { $0["taps"] as? Int == 3 }
            guard let orientationMenu = NSApp.mainMenu?.item(withTitle: "Device")?.submenu?.item(withTitle: "Orientation")?.submenu else {
                throw SimulatorError(message: "Missing Orientation submenu.")
            }
            let testPointScaling = controller.canSelectScalingMode(.pointAccurate)
            if testPointScaling { controller.perform(.pointAccurate) }
            var pointAccurateOrientations = 0
            var constrainedOrientations = 0
            for (command, turns) in [(DeviceCommand.portrait, 0), (.portraitUpsideDown, 2), (.landscapeLeft, 3), (.landscapeRight, 1)] {
                guard let item = orientationMenu.items.first(where: { $0.tag == command.rawValue }) else {
                    throw SimulatorError(message: "Missing planar orientation menu action.")
                }
                orientationMenu.update()
                orientationMenu.performActionForItem(at: orientationMenu.index(of: item))
                for _ in 0..<100 {
                    if screen.quarterTurns == turns { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard screen.quarterTurns == turns, try await screen.input?.orientationTurns(udid: udid) == turns,
                      app.validateMenuItem(item), item.state == .on else {
                    throw SimulatorError(message: "Orientation submenu did not change the guest to \(item.title).")
                }
                try await awaitState("Orientation menu selects \(item.title) inside iOS") { value in
                    guard let width = value["width"] as? Double, let height = value["height"] as? Double else { return false }
                    return turns % 2 == 0 ? height > width : width > height
                }
                // UIKit suppresses input during its own rotation transition.
                // Native orientation and layout update before that transition ends.
                try await Task.sleep(for: .milliseconds(650))
                if testPointScaling {
                    if controller.canSelectScalingMode(.pointAccurate) {
                        // A tall phone may not fit point-accurately in portrait
                        // on the current Mac display. If a previous orientation
                        // correctly fell back to Fit, select Point Accurate again
                        // before validating an orientation where it does fit.
                        if controller.scalingMode != .pointAccurate { controller.perform(.pointAccurate) }
                        controller.presentation.layoutSubtreeIfNeeded()
                        guard controller.scalingMode == .pointAccurate,
                              controller.isAtAccurateScale(.pointAccurate) else {
                            throw SimulatorError(message: "Point Accurate was not exact after the guest orientation change.")
                        }
                        pointAccurateOrientations += 1
                    } else {
                        guard controller.scalingMode == .fitScreen,
                              !controller.isAtAccurateScale(.pointAccurate) else {
                            throw SimulatorError(message: "An orientation that cannot fit Point Accurate did not fall back to Fit.")
                        }
                        constrainedOrientations += 1
                    }
                }
            }
            if testPointScaling {
                print("PASS: Point Accurate remained exact in \(pointAccurateOrientations) fitting orientations; Fit handled \(constrainedOrientations) constrained orientations")
            }
            func checkSlowAnimations() async throws {
                guard let input = controller.screen.input,
                      let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Debug" })?.submenu,
                      let item = menu.items.first(where: { $0.tag == DeviceCommand.slowAnimations.rawValue }) else {
                    throw SimulatorError(message: "Missing Slow Animations menu or simulator connection.")
                }
                let original = try input.slowAnimationsEnabled()
                defer { try? input.setSlowAnimationsEnabled(original) }
                try input.setSlowAnimationsEnabled(false)
                guard app.validateMenuItem(item), item.state == .off else {
                    throw SimulatorError(message: "Slow Animations checkbox did not reflect the guest state.")
                }
                func measure() async throws -> Double {
                    // Let UIKit receive the notification before starting a new animation.
                    try await Task.sleep(for: .milliseconds(200))
                    let tapNumber = (try state()["taps"] as? Int ?? 0) + 1
                    try await tap(x: 200, y: 228)
                    try await awaitState("UIKit animation \(tapNumber) completed") { $0["animationTap"] as? Int == tapNumber }
                    guard let duration = try state()["animationDuration"] as? Double else {
                        throw SimulatorError(message: "Guest did not report its animation duration.")
                    }
                    return duration
                }
                let normal = try await measure()
                menu.performActionForItem(at: menu.index(of: item))
                guard try input.slowAnimationsEnabled(), app.validateMenuItem(item), item.state == .on else {
                    throw SimulatorError(message: "Slow Animations menu did not enable the guest setting.")
                }
                let slow = try await measure()
                menu.performActionForItem(at: menu.index(of: item))
                guard try !input.slowAnimationsEnabled(), app.validateMenuItem(item), item.state == .off else {
                    throw SimulatorError(message: "Slow Animations menu did not disable the guest setting.")
                }
                let restored = try await measure()
                guard slow > normal * 3, restored < slow / 3 else {
                    throw SimulatorError(message: "UIKit animations did not change speed: normal=\(normal), slow=\(slow), restored=\(restored).")
                }
                // Changes made by another client must appear without reopening the window.
                try input.setSlowAnimationsEnabled(true)
                guard app.validateMenuItem(item), item.state == .on else {
                    throw SimulatorError(message: "Slow Animations checkbox ignored an external state change.")
                }
                let report = String(format: "PASS: Debug > Slow Animations, native checkbox state and real UIKit duration: normal %.3f s, slow %.3f s, restored %.3f s. Original guest setting restored.\n", normal, slow, restored)
                try FileManager.default.createDirectory(at: outputDirectory(), withIntermediateDirectories: true)
                try Data(report.utf8).write(to: outputDirectory().appendingPathComponent("slow-animations.txt"))
                print(report)
            }
            // Prove that removing the chrome also updates real touch coordinates.
            let originalBezels = controller.showsBezels
            controller.perform(.showBezels)
            controller.presentation.layoutSubtreeIfNeeded()
            let bareTapNumber = (try state()["taps"] as? Int ?? 0) + 1
            try await tap(x: 200, y: 228)
            try await awaitState("tap after bezel toggle") { $0["taps"] as? Int == bareTapNumber }
            controller.perform(.showBezels)
            controller.presentation.layoutSubtreeIfNeeded()
            guard controller.showsBezels == originalBezels else { throw SimulatorError(message: "Bezel toggle did not restore the guest window.") }
            let framedTapNumber = bareTapNumber + 1
            try await tap(x: 200, y: 228)
            try await awaitState("tap after restoring bezels") { $0["taps"] as? Int == framedTapNumber }
            // Let the fixture's ordinary UIKit animation finish before timing it.
            try await Task.sleep(for: .milliseconds(300))
            print("PASS: real UIKit touch coordinates before/after the device bezel toggle")
            guard let deviceMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Device" })?.submenu,
                  let shakeItem = deviceMenu.items.first(where: { $0.tag == DeviceCommand.shake.rawValue }),
                  app.validateMenuItem(shakeItem), shakeItem.keyEquivalent == "z",
                  shakeItem.keyEquivalentModifierMask == [.control, .command] else {
                throw SimulatorError(message: "Device > Shake is missing, disabled, or has the wrong shortcut.")
            }
            let shakeCount = try state()["shakes"] as? Int ?? 0
            deviceMenu.performActionForItem(at: deviceMenu.index(of: shakeItem))
            try await awaitState("Device > Shake delivers UIKit motionShake") { $0["shakes"] as? Int == shakeCount + 1 }
            try shortcut("z", code: 6, flags: [.control, .command])
            try await awaitState("Control-Command-Z delivers a second UIKit motionShake") { $0["shakes"] as? Int == shakeCount + 2 }
            try await checkSlowAnimations()
            let directory = outputDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let recordingURL = directory.appendingPathComponent("interaction.mp4")
            try controller.startRecording(to: recordingURL, showPreview: false)
            try await Task.sleep(for: .seconds(2))
            try await tap(x: 200, y: 228)
            await controller.finishRecording()
            let duration = try await AVURLAsset(url: recordingURL).load(.duration)
            guard duration.seconds > 0 else { throw SimulatorError(message: "Recording has no video duration.") }
            print("PASS: H.264 recording finalizes with \(duration.seconds) seconds of video")
            try await Task.sleep(for: .milliseconds(500))
            if let image = screen.screenshot(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("interaction-landscape.png")) }
            try shortcut("H", code: 4, flags: [.command, .shift])
            try await awaitState("Home shortcut sends fixture to background") { $0["foreground"] as? Bool == false }
            // Shut down only the fixture created by the integration script.
            // The independent window must close even if HID disconnects first.
            _ = try await CommandRunner.simctl(["shutdown", udid])
            for _ in 0..<60 {
                if app.deviceWindows[udid] == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard app.deviceWindows[udid] == nil, controller.window?.isVisible != true else {
                throw SimulatorError(message: "Shutdown left the simulator window open.")
            }
            print("PASS: external simulator shutdown closes its window")
            try Data("PASS\n".utf8).write(to: directory.appendingPathComponent("exercise-success.txt"))
            print("PASS: real-device input exercise complete")
        } catch {
            if let image = app.deviceWindows[udid]?.screen.screenshot(),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: outputDirectory().appendingPathComponent("exercise-failure.png"))
            }
            fputs("EXERCISE FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
