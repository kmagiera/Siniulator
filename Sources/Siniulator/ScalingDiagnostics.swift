#if DEBUG
import AppKit

extension Diagnostics {
    static func scalingAndBezelSmoke(app: AppDelegate, devices: [SimulatorDevice], directory: URL) async throws {
        guard let menu = NSApp.windowsMenu, let bezels = menu.item(withTitle: "Show Device Bezels") else {
            throw SimulatorError(message: "Window > Show Device Bezels is missing.")
        }
        var results: [String] = []
        for device in devices {
            app.open(device)
            guard let controller = app.deviceWindows[device.id], let window = controller.window else { continue }
            let root = controller.presentation!
            let originalFrame = window.frame
            let originalBezels = controller.showsBezels
            let others = app.deviceWindows.values.filter { $0 !== controller }
            let otherBezels = others.map(\.showsBezels)
            defer {
                if controller.showsBezels != originalBezels { controller.perform(.showBezels) }
                window.setFrame(originalFrame, display: true, animate: false)
                root.canvas.maximumScale = nil
                root.canvas.pixelAligned = false
                root.refreshGeometry()
                root.layoutSubtreeIfNeeded()
            }
            await Task.yield()
            for (mode, title, key) in [(DeviceScalingMode.physicalSize, "Physical Size", "1"),
                                      (.pointAccurate, "Point Accurate", "2"),
                                      (.pixelAccurate, "Pixel Accurate", "3")] {
                menu.update()
                guard let item = menu.item(withTitle: title), item.isEnabled == controller.canSelectScalingMode(mode) else {
                    throw SimulatorError(message: "\(title) menu availability disagrees with the available display space.")
                }
                guard item.isEnabled else {
                    results.append("SKIP: \(device.name) \(title) requires valid density and enough display space")
                    continue
                }
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "1" ? 18 : key == "2" ? 19 : 20)!
                guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true else {
                    throw SimulatorError(message: "\(title) shortcut did not dispatch.")
                }
                root.layoutSubtreeIfNeeded()
                menu.update()
                guard controller.scalingMode == mode, controller.isAtAccurateScale(mode), item.state == .on else {
                    throw SimulatorError(message: "\(device.name) \(title) was clamped or did not check its menu item.")
                }
                let screen = root.canvas.screen
                let frameBefore = screen.frame.size
                if mode == .physicalSize {
                    guard let dpi = root.canvas.chrome.displayDPI, let monitor = window.screen,
                          let pointsPerInch = monitor.physicalPointsPerInch,
                          let image = screen.currentImage(),
                          abs(frameBefore.width / pointsPerInch - image.extent.width / dpi) < 0.001,
                          abs(frameBefore.height / pointsPerInch - image.extent.height / dpi) < 0.001 else {
                        throw SimulatorError(message: "Physical Size does not match the device's screen dimensions in inches.")
                    }
                } else if mode == .pointAccurate {
                    let expected = root.canvas.chrome.geometry(quarterTurns: screen.quarterTurns).screen.size
                    guard abs(frameBefore.width - expected.width) < 0.001, abs(frameBefore.height - expected.height) < 0.001 else {
                        throw SimulatorError(message: "Point Accurate does not match UIKit's logical screen size.")
                    }
                } else {
                    guard let image = screen.currentImage() else { throw SimulatorError(message: "Pixel Accurate needs a framebuffer.") }
                    let pixels = screen.convertToBacking(screen.bounds).size
                    let position = root.canvas.convertToBacking(screen.frame).origin
                    guard abs(pixels.width - image.extent.width) < 0.001, abs(pixels.height - image.extent.height) < 0.001,
                          abs(position.x - position.x.rounded()) < 0.001, abs(position.y - position.y.rounded()) < 0.001 else {
                        throw SimulatorError(message: "Pixel Accurate is not aligned one-to-one with framebuffer pixels.")
                    }
                }
                if !controller.showsBezels { controller.perform(.showBezels) }
                let visibleSize = screen.frame.size
                menu.update()
                menu.performActionForItem(at: menu.index(of: bezels))
                root.layoutSubtreeIfNeeded()
                menu.update()
                guard !controller.showsBezels, bezels.state == .off, root.canvas.geometry.body == root.canvas.geometry.screen,
                      abs(screen.frame.width - visibleSize.width) < 0.001, abs(screen.frame.height - visibleSize.height) < 0.001,
                      controller.isAtAccurateScale(mode), others.map(\.showsBezels) == otherBezels else {
                    throw SimulatorError(message: "Hiding the bezel changed the screen scale, retained hardware padding or changed another window.")
                }
                guard window.isOpaque, window.backgroundColor == .black,
                      abs(root.deviceRect.minY - root.controls.frame.maxY) < 0.001,
                      root.canvas.frame.width == root.bounds.width,
                      root.controls.layer?.cornerRadius == 0 else {
                    throw SimulatorError(message: "Bezel-free screen did not join its normal window header.")
                }
                menu.performActionForItem(at: menu.index(of: bezels))
                menu.update()
                guard controller.showsBezels, bezels.state == .on, controller.isAtAccurateScale(mode),
                      abs(screen.frame.width - visibleSize.width) < 0.001, abs(screen.frame.height - visibleSize.height) < 0.001 else {
                    throw SimulatorError(message: "Restoring the bezel changed the accurate screen scale.")
                }
                results.append("PASS: \(device.name) \(title), native shortcut and checkbox, framebuffer dimensions, bezel toggle without screen rescaling, independent windows")
            }
            let normalBounds = root.frame
            root.isFullScreen = true
            root.frame = CGRect(x: 0, y: 0, width: 360, height: 600)
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            menu.update()
            guard menu.item(withTitle: "Point Accurate")?.isEnabled == false,
                  menu.item(withTitle: "Pixel Accurate")?.isEnabled == false else {
                throw SimulatorError(message: "Accurate scaling must not silently shrink to fit a small Split View viewport.")
            }
            root.isFullScreen = false
            root.frame = normalBounds
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
        }
        try Data((results.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("scaling-and-bezels.txt"))
        for result in results { print(result) }
    }
}
#endif
