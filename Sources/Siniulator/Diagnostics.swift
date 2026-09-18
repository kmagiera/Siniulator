#if DEBUG
import AppKit

@MainActor enum Diagnostics {
    static func startupSmoke(app: AppDelegate) async {
        do {
            let expected = Set(app.store.devices.filter(\.isBooted).map(\.id))
            guard !expected.isEmpty else { throw SimulatorError(message: "Startup test requires running simulators.") }
            let directory = outputDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for controller in app.deviceWindows.values where !controller.isConnected {
                controller.presentation.layoutSubtreeIfNeeded()
                guard let overlay = controller.presentation.canvas.subviews.compactMap({ $0 as? NSStackView }).first,
                      let spinner = overlay.arrangedSubviews.compactMap({ $0 as? NSProgressIndicator }).first,
                      !overlay.isHidden, !spinner.isHidden, spinner.isIndeterminate,
                      spinner.bounds.width >= 24, spinner.bounds.height >= 24,
                      controller.screen.bounds.contains(controller.screen.convert(spinner.bounds, from: spinner)),
                      overlay.arrangedSubviews.compactMap({ $0 as? NSButton }).allSatisfy(\.isHidden) else {
                    throw SimulatorError(message: "Startup must show a visible spinner inside the device screen without a retry button.")
                }
                let canvas = controller.presentation.canvas
                if let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        directory.appendingPathComponent("\(controller.deviceInfo.name)-starting.png"))
                }
            }
            for _ in 0..<150 {
                if app.deviceWindows.values.allSatisfy(\.isConnected) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard Set(app.deviceWindows.keys) == expected, app.deviceWindows.values.allSatisfy(\.isConnected) else {
                throw SimulatorError(message: "Default launch did not open all running simulators.")
            }
            try await Task.sleep(for: .milliseconds(500))
            for controller in app.deviceWindows.values {
                controller.presentation.layoutSubtreeIfNeeded()
                if CGPreflightScreenCaptureAccess() {
                    _ = try await CommandRunner.run("/usr/sbin/screencapture", ["-x", "-l", String(controller.window!.windowNumber), directory.appendingPathComponent("\(controller.deviceInfo.name).png").path])
                } else {
                    print("SKIP: composed window screenshot requires Screen Recording access for the diagnostic app")
                }
            }
            print("PASS: default startup opened all \(expected.count) running simulators, without --open-booted or a saved window list")
        } catch { fputs("STARTUP FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func outputDirectory() -> URL {
        if let index = CommandLine.arguments.firstIndex(of: "--output-dir"), CommandLine.arguments.count > index + 1 {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        return URL(fileURLWithPath: "/private/tmp/siniulator-smoke")
    }
    static func probe() async {
        do {
            let data = try await CommandRunner.simctl(["list", "devices", "--json"])
            let devices = try JSONDecoder().decode(DeviceList.self, from: data).available
            print("Available devices: \(devices.count)")
            for device in devices.filter(\.isBooted) {
                let (core, reference, display) = try await CoreSimulatorConnection.connect(device.id)
                let input = try SimulatorInput(core: core, device: reference)
                let screen = try SimulatorScreenView(renderer: ScreenRenderer())
                screen.display = display
                try display.start { }
                try await Task.sleep(for: .milliseconds(300))
                guard let image = screen.screenshot() else { throw SimulatorError(message: "No IOSurface for \(device.name)") }
                print("\(device.name): \(image.width)×\(image.height), \(input.transportName)")
                display.stop()
            }
        } catch { fputs("PROBE FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func smoke(app: AppDelegate) async {
        do {
            await app.store.refresh()
            let devices = Array(app.store.devices.filter(\.isBooted).prefix(2))
            guard devices.count == 2 else { throw SimulatorError(message: "Smoke test requires two booted simulators.") }
            for device in devices { app.open(device) }
            for _ in 0..<100 {
                if app.deviceWindows.values.allSatisfy(\.isConnected) { break }
                try await Task.sleep(for: .milliseconds(300))
            }
            guard app.deviceWindows.count == 2, app.deviceWindows.values.allSatisfy(\.isConnected) else { throw SimulatorError(message: "Two independent windows did not connect.") }
            let directory = outputDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            app.menuNeedsUpdate(app.openSimulatorMenu)
            let menuLines = NSApp.mainMenu.map { describeMenu($0) } ?? []
            try Data((menuLines.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("menu-structure.txt"))
            // macOS inserts contextual Window entries when tracking begins,
            // rather than during a plain NSMenu.update(). Inspect the real menu.
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            if session?["CGSSessionScreenIsLocked"] as? Bool != true,
               let menu = NSApp.windowsMenu, let controller = app.deviceWindows[devices[0].id] {
                app.open(devices[0])
                let inspection = Timer(timeInterval: 0.25, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let menuLines = NSApp.mainMenu.map { describeMenu($0) } ?? []
                        try? Data((menuLines.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("menu-structure-tracking.txt"))
                        NSApp.windowsMenu?.cancelTrackingWithoutAnimation()
                    }
                }
                RunLoop.main.add(inspection, forMode: .eventTracking)
                menu.popUp(positioning: nil, at: CGPoint(x: 20, y: 20), in: controller.presentation.controls)
                inspection.invalidate()
            }
            for device in devices {
                guard let controller = app.deviceWindows[device.id], let image = controller.screen.screenshot(),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw SimulatorError(message: "Missing simulator framebuffer.") }
                try data.write(to: directory.appendingPathComponent("\(device.name).png"))
                app.open(device)
                // Exercise AppKit's actual menu dispatch for the active device's keyboard shortcut.
                guard NSApp.mainMenu?.items.first(where: { $0.title == "I/O" })?.submenu?.item(withTitle: "Input")?.submenu?.items.contains(where: { $0.tag == DeviceCommand.keyboard.rawValue }) == true else { throw SimulatorError(message: "Missing keyboard input menu action.") }
                let wasEnabled = controller.screen.keyboardEnabled
                let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
                guard NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true else { throw SimulatorError(message: "Keyboard shortcut did not dispatch.") }
                guard controller.screen.keyboardEnabled != wasEnabled else { throw SimulatorError(message: "Menu action did not target the active window.") }
                NSApp.mainMenu?.performKeyEquivalent(with: shortcut)
                print("PASS: \(device.name), \(image.width)×\(image.height), independent window and menu dispatch")
                func checkSlowAnimationsTarget() throws {
                    guard let input = controller.screen.input,
                          let debug = NSApp.mainMenu?.items.first(where: { $0.title == "Debug" })?.submenu,
                          let item = debug.items.first(where: { $0.tag == DeviceCommand.slowAnimations.rawValue }) else {
                        throw SimulatorError(message: "Missing Slow Animations menu.")
                    }
                    let original = try input.slowAnimationsEnabled()
                    defer { try? input.setSlowAnimationsEnabled(original) }
                    let other = app.deviceWindows.values.first { $0 !== controller }!
                    let otherState = other.slowAnimationsEnabled
                    guard app.validateMenuItem(item), item.state == (original ? .on : .off) else {
                        throw SimulatorError(message: "Slow Animations checkbox did not match the active device.")
                    }
                    debug.performActionForItem(at: debug.index(of: item))
                    guard controller.slowAnimationsEnabled == !original,
                          other.slowAnimationsEnabled == otherState,
                          app.validateMenuItem(item), item.state == (original ? .off : .on) else {
                        throw SimulatorError(message: "Slow Animations did not target only the active device.")
                    }
                    print("PASS: Slow Animations targets only \(device.name), preserving the other guest's setting")
                }
                try checkSlowAnimationsTarget()
            }
            let first = devices[0], second = devices[1]
            let closing = app.deviceWindows[first.id]
            closing?.window?.performClose(nil)
            await closing?.waitForClose()
            guard app.deviceWindows[first.id] == nil, app.deviceWindows[second.id]?.isConnected == true else { throw SimulatorError(message: "Closing one window affected the other.") }
            let data = try await CommandRunner.simctl(["list", "devices", "--json"])
            let current = try JSONDecoder().decode(DeviceList.self, from: data).available
            let expectedState = AppSettings.shared.shutdownSimulatorOnWindowClose ? "Shutdown" : "Booted"
            guard current.first(where: { $0.id == first.id })?.state == expectedState,
                  current.first(where: { $0.id == second.id })?.isBooted == true else {
                throw SimulatorError(message: "Closing a window did not respect the shutdown setting or affected another device.")
            }
            print("PASS: Closing a window respects the shutdown setting and preserves the other running device")
        } catch { fputs("SMOKE FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    private static func describeMenu(_ menu: NSMenu, indent: String = "") -> [String] {
        var menuLines: [String] = []
        menu.update()
        for item in menu.items {
            if item.isSeparatorItem { menuLines.append(indent + "—"); continue }
            let flags = item.keyEquivalentModifierMask
            let modifiers = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            let shortcut = item.keyEquivalent.isEmpty ? "" : " [\(modifiers)\(item.keyEquivalent)]"
            menuLines.append(indent + item.title + shortcut + (item.isAlternate ? " (Option alternate)" : ""))
            if let child = item.submenu { menuLines += describeMenu(child, indent: indent + "  ") }
        }
        return menuLines
    }
}
#endif
