#if DEBUG
import AppKit

extension Diagnostics {
    /// A native Space test driven by scripts/fixtures/FullscreenPointer.swift.
    /// The external helper posts real pointer events and captures WindowServer.
    static func fullScreenChromeSmoke(app: AppDelegate) async {
        let directory = outputDirectory()
        do {
            if let index = CommandLine.arguments.firstIndex(of: "--test-appearance"), index + 1 < CommandLine.arguments.count {
                switch CommandLine.arguments[index + 1] {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "system": NSApp.appearance = nil
                default: throw SimulatorError(message: "Test appearance must be light, dark or system.")
                }
            }
            guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
                throw SimulatorError(message: "Native pointer/full-screen testing requires an unlocked macOS session.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await app.store.refresh()
            guard let device = app.store.devices.first(where: \.isBooted) else {
                throw SimulatorError(message: "Full-screen chrome test requires a booted simulator.")
            }
            app.open(device)
            guard let controller = app.deviceWindows[device.id], let window = controller.window else {
                throw SimulatorError(message: "No device window for full-screen chrome test.")
            }
            window.appearance = NSApp.appearance
            for _ in 0..<100 {
                if controller.isConnected { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard controller.isConnected else { throw SimulatorError(message: "Simulator connection timed out.") }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            let savedFrame = window.frame
            if let index = CommandLine.arguments.firstIndex(of: "--screen-index"), index + 1 < CommandLine.arguments.count,
               let screenIndex = Int(CommandLine.arguments[index + 1]) {
                guard NSScreen.screens.indices.contains(screenIndex) else { throw SimulatorError(message: "Requested display is unavailable.") }
                let available = NSScreen.screens[screenIndex].visibleFrame
                let size = CGSize(width: min(window.frame.width, available.width - 40), height: min(window.frame.height, available.height - 40))
                window.setFrame(CGRect(x: available.midX - size.width / 2, y: available.maxY - size.height - 20,
                    width: size.width, height: size.height), display: true, animate: false)
                try await Task.sleep(for: .milliseconds(300))
            }
            let original = window.frame
            window.toggleFullScreen(nil)
            for _ in 0..<100 {
                if controller.hasEnteredFullScreen { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard controller.hasEnteredFullScreen else { throw SimulatorError(message: "Native full-screen entry timed out.") }
            try await Task.sleep(for: .milliseconds(500))
            let root = controller.presentation!
            let bar = root.controls
            let display = window.screen!.frame
            let header = window.convertToScreen(bar.convert(bar.bounds, to: nil))
            let appearance: [String: Any] = [
                "header": [0.65, (display.maxY - header.minY - 28) / display.height, 64 / display.width, 16 / display.height],
                "body": [0.04, 0.25, 0.12, 0.6],
                "header-brightness": window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? [0.0, 0.3] : [0.7, 1.0],
                "appearance-toggle-brightness": window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? [0.7, 1.0] : [0.0, 0.3]
            ]
            try JSONSerialization.data(withJSONObject: appearance).write(to: directory.appendingPathComponent("appearance-regions.json"))
            let canvas = window.convertToScreen(root.canvas.convert(root.canvas.bounds, to: nil))
            let buttons = bar.windowButtons
            var sawIntermediateReveal = false, sawIntermediateHide = false
            func phase(_ name: String, progress: CGFloat, hoverX: CGFloat? = nil, overHeader: Bool = false) async throws {
                let display = window.screen!.frame
                let canvasScreenFrame = window.convertToScreen(root.canvas.convert(root.canvas.bounds, to: nil))
                let maxY = NSScreen.screens.first!.frame.maxY
                let header = window.convertToScreen(bar.convert(bar.bounds, to: nil))
                // Only the physical system menu-bar edge initiates reveal.
                // Hovering our lower device header must leave it hidden.
                let top = overHeader ? maxY - header.midY : maxY - display.maxY + 1
                let payload = "\(name) \(window.windowNumber) \(header.minX + (hoverX ?? header.width / 2)) \(top) \(canvasScreenFrame.midX) \(maxY - canvasScreenFrame.midY)"
                try Data(payload.utf8).write(to: directory.appendingPathComponent("phase.txt"), options: .atomic)
                var acknowledged = false
                for _ in 0..<600 {
                    let current = bar.fullScreenRevealProgress
                    let titleX = bar.presentedTitleFrame.minX
                    if titleX > 20.1 && titleX < 107.9 {
                        if progress == 1 { sawIntermediateReveal = true }
                        if progress == 0 { sawIntermediateHide = true }
                    }
                    acknowledged = (try? String(contentsOf: directory.appendingPathComponent("ack.txt"), encoding: .utf8)) == name
                    if acknowledged && abs(current - progress) < 0.001 && abs(titleX - (20 + 88 * progress)) < 0.1 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard acknowledged, abs(bar.fullScreenRevealProgress - progress) < 0.001 else {
                    let accessory = window.titlebarAccessoryViewControllers.first(where: { $0 is FullScreenChrome })!.view
                    let native = window.standardWindowButton(.closeButton)!
                    throw SimulatorError(message: "Native chrome did not reach \(name): \(bar.fullScreenRevealProgress); window=\(window.frame) header=\(header) inset=\(bar.topInset) pointer=\(NSEvent.mouseLocation) active=\(NSApp.isActive) key=\(window.isKeyWindow) tracking=\(bar.trackingAreas.map { $0.rect }); accessory=\(accessory.frame) visible=\(accessory.visibleRect) owner=\(accessory.window?.frame ?? .zero) originalButton=\(native.frame) visible=\(native.visibleRect) owner=\(native.window?.frame ?? .zero).")
                }
                try await Task.sleep(for: .milliseconds(350))
                root.layoutSubtreeIfNeeded()
                let settledCanvas = window.convertToScreen(root.canvas.convert(root.canvas.bounds, to: nil))
                guard !window.isOpaque, window.backgroundColor == .clear,
                      root.layer?.backgroundColor == nil || root.layer?.backgroundColor?.alpha == 0,
                      bar.layer?.backgroundColor?.alpha == 1,
                      !root.backdrop.isHidden, root.backdrop.blendingMode == .behindWindow else {
                    throw SimulatorError(message: "Full-screen window lost desktop transparency or its header became translucent: \(name).")
                }
                guard buttons.count == 3,
                      !bar.isHidden, buttons.allSatisfy({ !$0.isDescendant(of: bar) }),
                      zip(buttons, bar.windowButtons).allSatisfy({ $0 === $1 }),
                      bar.barLayout.name.minX == 20 + 88 * progress,
                      settledCanvas == canvas else {
                    throw SimulatorError(message: "Chrome reveal changed the device layout or lost its native window-owned buttons: \(name), canvas=\(settledCanvas) expected=\(canvas), title=\(bar.barLayout.name.minX), progress=\(bar.fullScreenRevealProgress).")
                }
                guard let chrome = window.titlebarAccessoryViewControllers.first(where: { $0 is FullScreenChrome })?.view.window,
                      chrome !== window, chrome.titlebarAppearsTransparent, !chrome.isOpaque,
                      chrome.backgroundColor == .clear, !chrome.ignoresMouseEvents else {
                    throw SimulatorError(message: "Native titlebar is not transparent or cannot receive system hover events.")
                }
                let close = buttons[0]
                let group = chrome.contentView!.superview!
                if name == "idle" {
                    print("Toolbar appearance: host=\(window.effectiveAppearance.name), bar=\(bar.effectiveAppearance.name), native=\(chrome.effectiveAppearance.name), background=\(String(describing: NSColor(cgColor: bar.layer!.backgroundColor!)))")
                }
                func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let nativeActions = descendants(group).compactMap { $0 as? NSButton }.filter { $0.target === bar.actions }
                guard window.toolbar === bar.actions.toolbar, window.toolbar?.isVisible == true,
                      nativeActions.count == 3, nativeActions.allSatisfy({ button in
                          let point = group.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                          let hit = group.hitTest(point)
                          return !button.isHiddenOrHasHiddenAncestor && button.alphaValue == 1 &&
                              (hit === button || hit === button.superview || hit?.isDescendant(of: button) == true)
                      }) else {
                    throw SimulatorError(message: "Persistent native toolbar actions were hidden or covered in \(name).")
                }
                var parents: [String] = []
                var ancestor: NSView? = close.superview
                while let view = ancestor {
                    parents.append("\(type(of: view)):\(view.trackingAreas.map { $0.rect })")
                    ancestor = view.superview
                }
                let details = "\(name) active=\(NSApp.isActive) key=\(window.isKeyWindow) nativeKey=\(chrome.isKeyWindow) pointer=\(NSEvent.mouseLocation) close=\(chrome.convertToScreen(close.convert(close.bounds, to: nil))) tracking=\(group.trackingAreas.map { $0.rect }) hostTracking=\(window.contentView!.superview!.trackingAreas.map { $0.rect }) parents=\(parents)\n"
                let detailFile = directory.appendingPathComponent("native-hover.txt")
                let previous = (try? Data(contentsOf: detailFile)) ?? Data()
                try (previous + Data(details.utf8)).write(to: detailFile)
                guard NSApp.presentationOptions.contains(.autoHideMenuBar),
                      !NSApp.presentationOptions.contains(.autoHideToolbar),
                      !NSApp.presentationOptions.contains(.hideMenuBar),
                      progress == 0 || NSMenu.menuBarVisible() else {
                    throw SimulatorError(message: "System menu/status bar was disabled in full screen: phase=\(name) active=\(NSApp.isActive) systemOptions=\(NSApp.currentSystemPresentationOptions.rawValue) appOptions=\(NSApp.presentationOptions.rawValue) menuVisible=\(NSMenu.menuBarVisible()).")
                }
                if progress == 0 {
                    // This is application-wide: a second display can keep its
                    // menu visible while the tested fullscreen display hides it.
                    guard NSScreen.screens.count > 1 || !NSMenu.menuBarVisible() else {
                        throw SimulatorError(message: "System menu bar did not retreat with its titlebar.")
                    }
                    guard buttons.allSatisfy({ button in
                        button.alphaValue == 0 || button.isHiddenOrHasHiddenAncestor || chrome.alphaValue == 0 ||
                            chrome.convertToScreen(button.convert(button.bounds, to: nil)).intersection(header).isEmpty
                    }) else {
                        throw SimulatorError(message: "Idle full-screen controls did not hide.")
                    }
                } else {
                    guard buttons.allSatisfy({ !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue == 1 }),
                          buttons[0].isEnabled, buttons[2].isEnabled else {
                        let state = buttons.map { "enabled=\($0.isEnabled) cell=\($0.cell?.isEnabled ?? false) hidden=\($0.isHiddenOrHasHiddenAncestor) alpha=\($0.alphaValue) frame=\($0.frame) mask=\($0.window?.styleMask.rawValue ?? 0)" }.joined(separator: "; ")
                        throw SimulatorError(message: "Revealed traffic lights are missing or have incorrect availability: \(state).")
                    }

                }
                try Data(name.utf8).write(to: directory.appendingPathComponent("capture.txt"), options: .atomic)
                for _ in 0..<300 {
                    if (try? String(contentsOf: directory.appendingPathComponent("captured.txt"), encoding: .utf8)) == name { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw SimulatorError(message: "External pointer/capture helper did not acknowledge \(name).")
            }
            try await phase("idle", progress: 0)
            try await phase("header-title", progress: 0, hoverX: 250, overHeader: true)
            try await phase("header-right", progress: 0, hoverX: bar.bounds.width - 60, overHeader: true)
            try await phase("reveal-system-menu", progress: 1, hoverX: 250)
            try await phase("reveal-system-status", progress: 1, hoverX: bar.bounds.width - 90)
            try await phase("header-native-hover", progress: 1, hoverX: 26, overHeader: true)
            try await phase("hide", progress: 0)
            guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || (sawIntermediateReveal && sawIntermediateHide) else {
                throw SimulatorError(message: "Title reveal/hide did not include intermediate positions.")
            }
            let originalAppearance = window.appearance
            let originalAppAppearance = NSApp.appearance
            let toggled: NSAppearance.Name = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .aqua : .darkAqua
            NSApp.appearance = NSAppearance(named: toggled)
            window.appearance = NSApp.appearance
            try await Task.sleep(for: .milliseconds(300))
            guard window.titlebarAccessoryViewControllers.first(where: { $0 is FullScreenChrome })?.view.window?
                .effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == toggled else {
                throw SimulatorError(message: "Native fullscreen toolbar did not follow a live appearance change.")
            }
            try await phase("appearance-toggle", progress: 0)
            NSApp.appearance = originalAppAppearance
            window.appearance = originalAppearance
            try await Task.sleep(for: .milliseconds(300))
            // Click the real green standard button, not a menu shortcut.
            try await phase("exit-reveal", progress: 1)
            let green = buttons[2]
            let center = green.window!.convertPoint(toScreen: green.convert(CGPoint(x: green.bounds.midX, y: green.bounds.midY), to: nil))
            let maxY = NSScreen.screens.first!.frame.maxY
            try Data("exit \(center.x) \(maxY - center.y)".utf8).write(to: directory.appendingPathComponent("phase.txt"), options: .atomic)
            for _ in 0..<100 {
                if !controller.hasEnteredFullScreen { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !controller.hasEnteredFullScreen, !root.isFullScreen,
                  bar.windowButtons.allSatisfy({ !$0.isHidden && $0.alphaValue == 1 && !$0.isDescendant(of: bar) && $0.window === window }),
                  abs(window.frame.width - original.width) < 1, abs(window.frame.height - original.height) < 1 else {
                throw SimulatorError(message: "Green button did not restore the normal device window.")
            }
            window.setFrame(savedFrame, display: true, animate: false)
            try Data("done".utf8).write(to: directory.appendingPathComponent("phase.txt"), options: .atomic)
            let result = "PASS: native full-screen Space; device-header hover does not reveal chrome; system menu-bar edge reveals menu, status bar and original window controls; native reveal/retreat with animated title inset; persistent native toolbar actions remain clickable; live appearance changes reach the auxiliary toolbar window; stable device canvas; permission-free native behind-window composition; exit by clicking native green; normal-window controls and dimensions restored.\n"
            try Data(result.utf8).write(to: directory.appendingPathComponent("fullscreen-chrome-results.txt"))
            print(result)
        } catch {
            try? Data("failed".utf8).write(to: directory.appendingPathComponent("phase.txt"), options: .atomic)
            fputs("FULLSCREEN CHROME FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
