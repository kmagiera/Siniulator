#if DEBUG
import AppKit

extension Diagnostics {
    static func presentationSmoke(app: AppDelegate) async {
        do {
            let directory = outputDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let scalingReport = directory.appendingPathComponent("scaling-and-bezels.txt")
            if FileManager.default.fileExists(atPath: scalingReport.path) { try FileManager.default.removeItem(at: scalingReport) }
            for name in ["presentation-results.txt", "control-bar.png", "control-bar-compact.png", "control-bar-wide.png", "control-bar-pressed.png", "control-bar-home-highlight.png", "control-bar-rotate-highlight.png", "control-bar-stop-highlight.png", "full-screen-header.png", "framed-device.png", "framed-ipad.png", "screenshot-preview.png", "screenshot-preview-large.png", "screenshot-preview-small.png", "screenshot-thumbnail.png", "full-screen.png", "full-screen-preview.png"] {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            await app.store.refresh()
            let devices = Array(app.store.devices.filter(\.isBooted).prefix(2))
            guard !devices.isEmpty else { throw SimulatorError(message: "Presentation test needs a booted device.") }
            for device in devices { app.open(device) }
            for _ in 0..<150 {
                // Wait for the initial connection before exercising window modes.
                if app.deviceWindows.values.allSatisfy(\.isConnected) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard app.deviceWindows.values.allSatisfy(\.isConnected), NSApp.windows.filter(\.isVisible).count == devices.count else {
                throw SimulatorError(message: "Expected only the running device windows, without a device browser.")
            }
            let originalBezelStates = devices.compactMap { device -> (DeviceWindowController, Bool)? in
                guard let controller = app.deviceWindows[device.id] else { return nil }
                return (controller, controller.showsBezels)
            }
            defer {
                for (controller, bezels) in originalBezelStates where controller.showsBezels != bezels {
                    controller.perform(.showBezels)
                }
            }
            // Start detached checks framed; scalingAndBezelSmoke also exercises
            // the joined window. Restore the user's original preference above.
            for (controller, bezels) in originalBezelStates where !bezels { controller.perform(.showBezels) }
            app.menuNeedsUpdate(app.openSimulatorMenu)
            let entries = app.openSimulatorMenu.items.flatMap { $0.submenu?.items ?? [] }
            guard devices.allSatisfy({ device in entries.contains { $0.representedObject as? String == device.id } }) else {
                throw SimulatorError(message: "Open Simulator menu is missing running devices.")
            }
            print("PASS: devices are selectable from runtime submenus; no browser window")
            let device = devices.first(where: { $0.name.hasPrefix("iPhone") }) ?? devices[0]
            app.open(device)
            guard let controller = app.deviceWindows[device.id], let window = controller.window else { throw SimulatorError(message: "Missing window.") }
            guard let windowMenu = NSApp.windowsMenu, let stayOnTop = windowMenu.item(withTitle: "Stay On Top"),
                  let stayAction = stayOnTop.action else { throw SimulatorError(message: "Stay On Top menu item is missing.") }
            windowMenu.update()
            guard stayOnTop.isEnabled, stayOnTop.state == .off,
                  NSApp.sendAction(stayAction, to: stayOnTop.target, from: stayOnTop) else {
                throw SimulatorError(message: "Stay On Top menu action did not dispatch.")
            }
            windowMenu.update()
            guard controller.staysOnTop, window.level == .floating, !window.hidesOnDeactivate, stayOnTop.state == .on,
                  app.deviceWindows.values.filter({ $0 !== controller }).allSatisfy({ !$0.staysOnTop && $0.window?.level == .normal }) else {
                throw SimulatorError(message: "Stay On Top checkbox or independent floating window level failed.")
            }
            NSApp.sendAction(stayAction, to: stayOnTop.target, from: stayOnTop)
            windowMenu.update()
            guard !controller.staysOnTop, window.level == .normal, stayOnTop.state == .off else {
                throw SimulatorError(message: "Disabling Stay On Top did not restore the normal window level.")
            }
            print("PASS: Window > Stay On Top dispatches through the native menu, updates its checkbox and toggles the selected window's floating level without hiding on app deactivation")
            func captureWindow(_ target: NSWindow, filename: String) async throws {
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                guard session?["CGSSessionScreenIsLocked"] as? Bool != true else {
                    print("SKIP: window screenshot \(filename) requires an unlocked session")
                    return
                }
                guard CGPreflightScreenCaptureAccess() else {
                    print("SKIP: window screenshot \(filename) requires Screen Recording access for the diagnostic app")
                    return
                }
                _ = try await CommandRunner.run("/usr/sbin/screencapture", ["-x", "-l", String(target.windowNumber), directory.appendingPathComponent(filename).path])
            }
            for device in devices {
                guard let candidate = app.deviceWindows[device.id], let target = candidate.window else { continue }
                let presentation = candidate.presentation!
                presentation.layoutSubtreeIfNeeded()
                guard target.hasShadow, !target.isOpaque, target.backgroundColor == .clear else {
                    throw SimulatorError(message: "Device window must use a native shadow around its transparent content.")
                }
                let original = target.frame
                let scale = presentation.canvas.geometry.fit(in: presentation.canvas.bounds).scale
                let expectedHeight = max(target.minSize.height, presentation.normalSize(scale: scale).height)
                guard abs(original.height - expectedHeight) < 1 else {
                    throw SimulatorError(message: "\(device.name) opened with unused vertical window space.")
                }
                for size in [CGSize(width: 560, height: 900), CGSize(width: 560, height: 1400),
                             CGSize(width: 900, height: 560), CGSize(width: 324, height: 900)] {
                    target.setFrame(CGRect(origin: original.origin, size: size), display: true, animate: false)
                    presentation.refreshGeometry()
                    presentation.layoutSubtreeIfNeeded()
                    let geometry = presentation.canvas.geometry
                    let fitted = geometry.fit(in: presentation.canvas.bounds, maximumScale: presentation.canvas.maximumScale)
                    let expectedGap = 12 + geometry.rotated(geometry.body).minY * fitted.scale
                    let gap = presentation.deviceRect.minY - presentation.controls.frame.maxY
                    guard abs(gap - expectedGap) < 0.001 else {
                        throw SimulatorError(message: "\(device.name) has \(gap) points between its toolbar and bezel; expected \(expectedGap).")
                    }
                }
                target.setFrame(original, display: true, animate: false)
                presentation.refreshGeometry()
                presentation.layoutSubtreeIfNeeded()
                if device.name.contains("iPad") {
                    try await captureWindow(target, filename: "framed-ipad.png")
                }
            }
            print("PASS: phone/tablet startup windows fit the bezel; tall, narrow and wide restored frames keep the device directly below its toolbar")
            try await scalingAndBezelSmoke(app: app, devices: devices, directory: directory)
            app.open(device)
            try await Task.sleep(for: .milliseconds(500))
            guard controller.presentation.canvas.chrome.resourceURL != nil else { throw SimulatorError(message: "System device bezel did not load.") }
            try await captureWindow(window, filename: "framed-device.png")
            print("PASS: installed device bezel and detached control bar")
            guard !controller.presentation.controls.isHidden, controller.presentation.controls.frame.height == controller.presentation.controls.barLayout.height,
                  window.collectionBehavior.contains(.fullScreenAllowsTiling), window.collectionBehavior.contains(.fullScreenPrimary) else {
                throw SimulatorError(message: "Device controls or native full-screen tiling policy are missing.")
            }
            guard let hostWindow = window as? DeviceHostWindow else { throw SimulatorError(message: "Missing corner resize support.") }
            let originalFrame = window.frame
            let root = controller.presentation!
            root.layoutSubtreeIfNeeded()
            let cornerPoint = CGPoint(x: root.deviceRect.maxX - root.deviceCornerRadius * (1 - 1 / sqrt(2)),
                y: root.deviceRect.maxY - root.deviceCornerRadius * (1 - 1 / sqrt(2)))
            let pointer = window.convertToScreen(CGRect(origin: root.convert(cornerPoint, to: nil), size: .zero)).origin
            func mouseEvent(_ type: NSEvent.EventType, at screenPoint: CGPoint) -> NSEvent {
                cornerResizeEvent(type, at: screenPoint)
            }
            hostWindow.sendEvent(mouseEvent(.leftMouseDown, at: pointer))
            guard hostWindow.isCornerResizing else { throw SimulatorError(message: "Corner mouse down did not begin resizing.") }
            hostWindow.sendEvent(mouseEvent(.leftMouseDragged, at: CGPoint(x: pointer.x + 32, y: pointer.y - 64)))
            guard window.frame != originalFrame, abs(window.frame.minX - originalFrame.minX) < 1,
                  abs(window.frame.maxY - originalFrame.maxY) < 1,
                  root.controls.frame.height == root.controls.barLayout.height else {
                throw SimulatorError(message: "Corner drag did not resize immediately with fixed opposite corner and toolbar height.")
            }
            hostWindow.sendEvent(mouseEvent(.leftMouseUp, at: pointer))
            guard !hostWindow.isCornerResizing,
                  root.resizeCorner(at: CGPoint(x: root.deviceRect.minX, y: root.deviceRect.midY)) == nil else {
                throw SimulatorError(message: "Corner resize did not finish or accepts straight device edges.")
            }
            window.setFrame(originalFrame, display: true, animate: false)
            root.canvas.maximumScale = nil
            root.layoutSubtreeIfNeeded()
            hostWindow.sendEvent(mouseEvent(.leftMouseDown, at: pointer))
            hostWindow.sendEvent(mouseEvent(.leftMouseDragged, at: CGPoint(x: pointer.x - 32, y: pointer.y + 64)))
            guard window.frame.height < originalFrame.height,
                  window.frame.width >= window.minSize.width, root.controls.frame.height == root.controls.barLayout.height else {
                throw SimulatorError(message: "Minimum toolbar width prevents shrinking the device.")
            }
            hostWindow.sendEvent(mouseEvent(.leftMouseUp, at: pointer))
            let edge = window.convertToScreen(CGRect(origin: root.convert(CGPoint(x: 1, y: root.bounds.midY), to: nil), size: .zero)).origin
            hostWindow.sendEvent(mouseEvent(.leftMouseDown, at: edge))
            guard !hostWindow.isCornerResizing else { throw SimulatorError(message: "Window edge started a resize.") }
            window.setFrame(originalFrame, display: true, animate: false)
            root.canvas.maximumScale = nil
            root.layoutSubtreeIfNeeded()
            print("PASS: synthetic AppKit corner drag resizes immediately, fixes the opposite corner, accounts for toolbar rows and rejects edge resizing")
            for candidate in app.deviceWindows.values {
                try queuedCornerResizeSmoke(controller: candidate)
            }
            // Glass is composited by WindowServer, not by cacheDisplay. Snapshot
            // its AppKit content separately; captureWindow checks the full effect
            // when the session is unlocked.
            let bar = controller.presentation.controls
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bar.bounds.width * 2),
                pixelsHigh: Int(bar.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw SimulatorError(message: "Could not allocate control bar snapshot.")
            }
            guard let snapshot = bitmap.retagging(with: .sRGB) else { throw SimulatorError(message: "Could not configure snapshot color space.") }
            snapshot.size = bar.bounds.size
            bar.contentView.cacheDisplay(in: bar.contentView.bounds, to: snapshot)
            guard let png = snapshot.representation(using: .png, properties: [:]) else { throw SimulatorError(message: "Could not encode control bar snapshot.") }
            try png.write(to: directory.appendingPathComponent("control-bar.png"))
            func barSnapshot() throws -> Data {
                guard let bitmap = bar.contentView.bitmapImageRepForCachingDisplay(in: bar.contentView.bounds) else { throw SimulatorError(message: "Could not allocate adaptive bar snapshot.") }
                bar.contentView.cacheDisplay(in: bar.contentView.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SimulatorError(message: "Could not encode adaptive bar snapshot.") }
                return data
            }
            let originalBarFrame = bar.frame
            var compactWidth = CGFloat(351)
            while bar.height(for: compactWidth) == SimulatorControlBarLayout.expandedHeight { compactWidth -= 1 }
            for (width, compact, filename) in [(compactWidth, true, "control-bar-compact.png"), (760, false, "control-bar-wide.png")] {
                bar.frame = CGRect(origin: originalBarFrame.origin, size: CGSize(width: width, height: bar.height(for: width)))
                bar.needsLayout = true
                bar.layoutSubtreeIfNeeded()
                let labels = bar.contentView.subviews.compactMap { $0 as? NSTextField }
                guard bar.barLayout.isCompact == compact,
                      bar.layer?.cornerRadius == (compact ? 16 : 26),
                      labels.contains(where: { !$0.isHidden && $0.stringValue == (compact ? "\(device.name) – \(device.runtimeName)" : device.name) }),
                      bar.actionItems.count == 3,
                      bar.actionItems.allSatisfy({ $0.view == nil && $0.target === bar.actions }),
                      window.toolbar === bar.actions.toolbar,
                      window.toolbarStyle == (compact ? .expanded : .unified),
                      bar.actions.toolbar.centeredItemIdentifiers == (compact ? Set(bar.actionItems.map(\.itemIdentifier)) : []) else {
                    throw SimulatorError(message: "Adaptive toolbar title, corner radius or native hover button style is missing.")
                }
                if #available(macOS 26, *) {
                    guard let glass = bar.surface as? NSGlassEffectView,
                          glass.contentView === bar.contentView, !glass.isHidden,
                          glass.style == .regular, glass.cornerRadius == bar.barLayout.cornerRadius,
                          glass.frame == bar.bounds, bar.contentView.frame == glass.bounds,
                          bar.layer?.backgroundColor?.alpha == 1, bar.contentView.layer?.backgroundColor?.alpha == 1,
                          bar.contentView.layer?.cornerRadius == bar.barLayout.cornerRadius, bar.layer?.borderWidth == 0,
                          labels.filter({ !$0.isHidden }).allSatisfy({ bar.contentView.bounds.contains($0.frame) }),
                          bar.actionItems.allSatisfy({ $0.view == nil }) else {
                        throw SimulatorError(message: "Toolbar content or rounded adaptive shape is outside its native glass surface.")
                    }
                }
                try barSnapshot().write(to: directory.appendingPathComponent(filename))
            }
            bar.frame = originalBarFrame
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            print("PASS: opaque base beneath native glass in compact/wide toolbar; WindowServer shadow enabled (desktop appearance requires an unlocked session)")
            print("PASS: compact/wide title layouts and a genuine NSToolbar with centered compact standard action items (WindowServer hover/press appearance requires external pointer verification)")
            if CommandLine.arguments.contains("--window-controls-smoke") {
                root.isFullScreen = true
                root.refreshGeometry()
                root.layoutSubtreeIfNeeded()
                guard bar.surface.isHidden, bar.contentView.superview === bar,
                      bar.contentView.layer?.backgroundColor == nil else {
                    throw SimulatorError(message: "Full-screen toolbar retained its normal-window fill or glass surface.")
                }
                root.isFullScreen = false
                root.refreshGeometry()
                root.layoutSubtreeIfNeeded()
                guard !bar.surface.isHidden, bar.contentView.layer?.backgroundColor?.alpha == 1,
                      bar.contentView.layer?.cornerRadius == bar.barLayout.cornerRadius else {
                    throw SimulatorError(message: "Opaque toolbar was not restored after full-screen layout.")
                }
                let result = "PASS: Physical Size/Point/Pixel Accurate menu availability, shortcuts, checkboxes and framebuffer dimensions (see scaling-and-bezels.txt); queued corner drags and reversal; opaque compact/wide native glass; native window shadow configuration; normal/full-screen fill restoration.\nSKIP: actual pointer drag smoothness and glass appearance require manual/external WindowServer verification.\n"
                try Data(result.utf8).write(to: directory.appendingPathComponent("window-controls-results.txt"))
                print("PASS: isolated window controls and corner resize smoke test")
                return
            }
            let captureEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
            guard NSApp.mainMenu?.performKeyEquivalent(with: captureEvent) == true else { throw SimulatorError(message: "Screenshot shortcut did not dispatch.") }
            for _ in 0..<100 {
                if !app.capturePreviews.previews.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let preview = app.capturePreviews.previews.last,
                  FileManager.default.fileExists(atPath: preview.fileURL.path),
                  NSImage(contentsOf: preview.fileURL) != nil,
                  (preview.fileURL as NSURL).writableTypes(for: NSPasteboard(name: .init("Siniulator Screenshot QA"))).contains(.fileURL) else {
                throw SimulatorError(message: "Screenshot preview is missing its draggable PNG file.")
            }
            guard preview.isPresenting, let intro = preview.window else { throw SimulatorError(message: "Screenshot did not start over the device screen.") }
            let sourceScreen = window.convertToScreen(controller.screen.convert(controller.screen.bounds, to: nil))
            guard intro.frame.contains(sourceScreen), intro.ignoresMouseEvents else { throw SimulatorError(message: "Screenshot animation does not span the device screen.") }
            for _ in 0..<100 {
                if !preview.isPresenting { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            func expectedPreviewFrame(_ panel: NSWindow) -> CGRect {
                let device = window.convertToScreen(root.convert(root.deviceRect, to: nil))
                let display = window.convertToScreen(controller.screen.convert(controller.screen.bounds, to: nil))
                let header = window.convertToScreen(root.controls.convert(root.controls.bounds, to: nil))
                return CapturePreviewLayout.frame(size: panel.frame.size, beside: root.isFullScreen ? device : device.union(header),
                    visibleFrame: window.screen!.visibleFrame, bottom: CapturePreviewLayout.bottom(device: device, screen: display))
            }
            func isPositionedCorrectly(_ panel: NSWindow) -> Bool {
                let expected = expectedPreviewFrame(panel)
                // AppKit rounds borderless panel origins to whole screen points.
                let tolerance = 1.001
                return abs(panel.frame.minX - expected.minX) <= tolerance && abs(panel.frame.minY - expected.minY) <= tolerance
            }
            guard let panel = preview.window, panel !== window, window.screen != nil,
                  isPositionedCorrectly(panel),
                  preview.superview !== controller.presentation,
                  panel.collectionBehavior.contains(.fullScreenAuxiliary), !preview.isPresenting else {
                throw SimulatorError(message: "Screenshot preview is not positioned beside the device window: presenting=\(preview.isPresenting), frame=\(String(describing: preview.window?.frame)), expected=\(String(describing: preview.window.map(expectedPreviewFrame))).")
            }
            guard abs(preview.imageRect.width - controller.screen.bounds.width / 4) <= 0.5,
                  abs(preview.imageRect.height - controller.screen.bounds.height / 4) <= 0.5 else {
                throw SimulatorError(message: "Screenshot preview is not a quarter of the displayed device screen.")
            }
            guard let png = NSBitmapImageRep(data: try Data(contentsOf: preview.fileURL)),
                  png.pixelsWide == Int(controller.screen.framebufferSize.width),
                  png.pixelsHigh == Int(controller.screen.framebufferSize.height),
                  png.colorAt(x: 0, y: 0)?.alphaComponent == 1,
                  png.colorAt(x: png.pixelsWide - 1, y: 0)?.alphaComponent == 1,
                  png.colorAt(x: 0, y: png.pixelsHigh - 1)?.alphaComponent == 1,
                  png.colorAt(x: png.pixelsWide - 1, y: png.pixelsHigh - 1)?.alphaComponent == 1,
                  png.colorAt(x: png.pixelsWide / 2, y: png.pixelsHigh / 2)?.alphaComponent == 1,
                  abs(preview.bezelWidth - 3) < 0.01 else {
                throw SimulatorError(message: "Screenshot must preserve rectangular framebuffer pixels; only its preview gets a phone frame.")
            }
            guard let thumbnail = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { throw SimulatorError(message: "Could not allocate thumbnail snapshot.") }
            preview.cacheDisplay(in: preview.bounds, to: thumbnail)
            let top = thumbnail.colorAt(x: thumbnail.pixelsWide / 2, y: 1)?.usingColorSpace(.deviceRGB)
            guard thumbnail.colorAt(x: 0, y: 0)?.alphaComponent == 0,
                  top?.alphaComponent == 1, (top?.redComponent ?? 1) < 0.01,
                  (top?.greenComponent ?? 1) < 0.01, (top?.blueComponent ?? 1) < 0.01,
                  let thumbnailPNG = thumbnail.representation(using: .png, properties: [:]) else {
                throw SimulatorError(message: "Thumbnail does not have rounded, clipped corners and an opaque black phone frame.")
            }
            try thumbnailPNG.write(to: directory.appendingPathComponent("screenshot-thumbnail.png"))
            try await captureWindow(panel, filename: "screenshot-preview.png")
            preview.cancelTimer()
            let deviceFrame = window.frame
            func capturePreviewScene(filename: String) async throws {
                guard CGPreflightScreenCaptureAccess() else {
                    print("SKIP: preview scene \(filename) requires Screen Recording access for the diagnostic app")
                    return
                }
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                guard session?["CGSSessionScreenIsLocked"] as? Bool != true else { return }
                let scene = window.frame.union(panel.frame).insetBy(dx: -8, dy: -8).integral
                // Capture only our two windows, even if another app covers them.
                let captures = [(window, directory.appendingPathComponent("scene-device.png")),
                    (panel, directory.appendingPathComponent("scene-preview.png"))]
                defer { for (_, url) in captures { try? FileManager.default.removeItem(at: url) } }
                for (target, url) in captures {
                    _ = try await CommandRunner.run("/usr/sbin/screencapture", ["-x", "-l", String(target.windowNumber), url.path])
                    let currentSession = CGSessionCopyCurrentDictionary() as? [String: Any]
                    if currentSession?["CGSSessionScreenIsLocked"] as? Bool == true { return }
                }
                let backing = window.backingScaleFactor
                guard let context = CGContext(data: nil, width: Int(scene.width * backing), height: Int(scene.height * backing), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw SimulatorError(message: "Could not allocate preview scene.")
                }
                context.scaleBy(x: backing, y: backing)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(origin: .zero, size: scene.size))
                for (target, url) in captures {
                    guard let image = NSBitmapImageRep(data: try Data(contentsOf: url))?.cgImage else { throw SimulatorError(message: "Could not decode preview scene capture.") }
                    context.draw(image, in: target.frame.offsetBy(dx: -scene.minX, dy: -scene.minY))
                }
                guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw SimulatorError(message: "Could not encode preview scene.")
                }
                try png.write(to: directory.appendingPathComponent(filename))
            }
            try await capturePreviewScene(filename: "screenshot-preview-large.png")
            let fitScale = root.canvas.geometry.fit(in: root.canvas.bounds, maximumScale: root.canvas.maximumScale).scale
            let smaller = root.normalSize(scale: fitScale * 0.65)
            window.setFrame(CGRect(x: deviceFrame.minX, y: deviceFrame.maxY - smaller.height, width: smaller.width, height: smaller.height), display: true, animate: false)
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            guard isPositionedCorrectly(panel),
                  abs(preview.imageRect.width - controller.screen.bounds.width / 4) <= 0.5,
                  abs(preview.imageRect.height - controller.screen.bounds.height / 4) <= 0.5 else {
                throw SimulatorError(message: "Screenshot preview did not follow the displayed screen's size after resizing its window.")
            }
            try await capturePreviewScene(filename: "screenshot-preview-small.png")
            window.setFrame(deviceFrame, display: true, animate: false)
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            window.setFrameOrigin(deviceFrame.origin.applying(CGAffineTransform(translationX: 20, y: 10)))
            try await Task.sleep(for: .milliseconds(150))
            guard isPositionedCorrectly(panel) else {
                throw SimulatorError(message: "Screenshot preview did not follow its device window.")
            }
            window.setFrameOrigin(deviceFrame.origin)
            let savedURL = app.capturePreviews.saveDirectory.appendingPathComponent(preview.fileURL.lastPathComponent)
            let trackingEvent = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil)!
            preview.mouseEntered(with: trackingEvent)
            try await Task.sleep(for: .seconds(5.3))
            guard !preview.isFinished, !FileManager.default.fileExists(atPath: savedURL.path) else {
                throw SimulatorError(message: "Hover callback failed to pause screenshot autosave.")
            }
            preview.mouseExited(with: trackingEvent)
            // Exercise the callback for an aborted native drag, then let the real five-second timer finish.
            let saveStarted = ContinuousClock.now
            preview.completeDrag(operation: [])
            guard !FileManager.default.fileExists(atPath: savedURL.path) else { throw SimulatorError(message: "Screenshot was saved before the preview timeout.") }
            // Leave room for scheduling delays under active WindowServer load,
            // then observe the dismissal rather than waking just before it.
            try await Task.sleep(for: .seconds(3))
            guard !preview.isFinished, preview.window === panel else { throw SimulatorError(message: "Preview retreated before its five-second timeout.") }
            for _ in 0..<250 {
                if preview.isFinished { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let deviceOnScreen = window.convertToScreen(root.convert(root.deviceRect, to: nil))
            let deviceMask = (preview.superview?.layer?.mask as? CAShapeLayer)?.fillRule == .evenOdd
            guard preview.isFinished, ContinuousClock.now - saveStarted >= .seconds(4.9), let retreat = preview.window,
                  retreat.title == "Capture Preview Dismissal", retreat.level == window.level || deviceMask,
                  retreat.ignoresMouseEvents, preview.alphaValue == 1,
                  retreat.convertToScreen(preview.frame).midX < panel.frame.midX,
                  deviceOnScreen.contains(retreat.convertToScreen(preview.frame)) else {
                throw SimulatorError(message: "Expired screenshot did not slide horizontally under its source window without fading.")
            }
            for _ in 0..<150 {
                if app.capturePreviews.previews.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard app.capturePreviews.previews.isEmpty,
                  ContinuousClock.now - saveStarted >= .seconds(4.9),
                  try Data(contentsOf: savedURL) == Data(contentsOf: preview.fileURL) else {
                throw SimulatorError(message: "Screenshot timeout did not save the PNG and dismiss the preview.")
            }
            print("PASS: shortcut, rectangular PNG, quarter-screen thumbnail, screenshot-to-thumbnail transition, rounded black preview frame, window-relative movement, hover pause and aborted-drag callbacks, five-second autosave and horizontal retreat under the source window without fading (QA directory)")
            guard NSApp.mainMenu?.performKeyEquivalent(with: captureEvent) == true else { throw SimulatorError(message: "Second screenshot shortcut did not dispatch.") }
            for _ in 0..<100 {
                if !app.capturePreviews.previews.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let consumed = app.capturePreviews.previews.last else { throw SimulatorError(message: "Missing second preview.") }
            try await Task.sleep(for: .milliseconds(650))
            let consumedURL = app.capturePreviews.saveDirectory.appendingPathComponent(consumed.fileURL.lastPathComponent)
            consumed.completeDrag(operation: .copy)
            try await Task.sleep(for: .milliseconds(250))
            guard app.capturePreviews.previews.isEmpty, !app.capturePreviews.hasPendingSaves else {
                throw SimulatorError(message: "Successful-drag callback did not consume the pending save.")
            }
            let presentation = controller.presentation!
            let normalBounds = presentation.frame
            presentation.isFullScreen = true
            for size in [CGSize(width: 3008, height: 1692), CGSize(width: 1504, height: 1692),
                         CGSize(width: 756, height: 982), CGSize(width: 360, height: 600)] {
                presentation.frame = CGRect(origin: normalBounds.origin, size: size)
                presentation.needsLayout = true
                presentation.layoutSubtreeIfNeeded()
                let layout = FullScreenPresentationLayout(bounds: presentation.bounds, safeAreaInsets: presentation.fullScreenSafeAreaInsets)
                guard !presentation.controls.isHidden, presentation.controls.frame == layout.header,
                      presentation.controls.layer?.cornerRadius == 0, presentation.controls.layer?.borderWidth == 0,
                      presentation.controls.surface.isHidden, presentation.controls.contentView.superview === presentation.controls,
                      presentation.controls.contentView.layer?.backgroundColor == nil,
                      presentation.controls.windowButtons.count == 3,
                      presentation.controls.windowButtons.allSatisfy({ !$0.isDescendant(of: presentation.controls) }),
                      presentation.canvas.frame == layout.canvas,
                      !presentation.backdrop.isHidden, presentation.backdrop.frame == presentation.bounds,
                      presentation.backdrop.material == .underWindowBackground, presentation.backdrop.blendingMode == .behindWindow else {
                    throw SimulatorError(message: "Full screen header, backdrop or responsive device layout failed at \(size).")
                }
                let device = presentation.canvas.geometry.fit(in: presentation.canvas.bounds).rect
                guard presentation.canvas.bounds.contains(device),
                      abs(device.midX - presentation.canvas.bounds.midX) < 1,
                      abs(device.midY - presentation.canvas.bounds.midY) < 1 else {
                    throw SimulatorError(message: "Device did not fit below the header at \(size).")
                }
                if size.width == 3008 {
                    guard let bitmap = presentation.controls.bitmapImageRepForCachingDisplay(in: presentation.controls.bounds) else {
                        throw SimulatorError(message: "Could not allocate full screen header snapshot.")
                    }
                    presentation.controls.cacheDisplay(in: presentation.controls.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw SimulatorError(message: "Could not encode full screen header snapshot.")
                    }
                    try png.write(to: directory.appendingPathComponent("full-screen-header.png"))
                }
            }
            presentation.isFullScreen = false
            presentation.frame = normalBounds
            presentation.needsLayout = true
            presentation.layoutSubtreeIfNeeded()
            guard presentation.backdrop.isHidden, !presentation.controls.isHidden,
                  presentation.controls.layer?.cornerRadius == presentation.controls.barLayout.cornerRadius,
                  presentation.controls.windowButtons.count == 3, presentation.controls.windowButtons.allSatisfy({ !$0.isHidden }) else {
                throw SimulatorError(message: "Normal window chrome was not restored after full screen layout.")
            }
            if #available(macOS 26, *) {
                guard let glass = presentation.controls.surface as? NSGlassEffectView,
                      !glass.isHidden, glass.contentView === presentation.controls.contentView,
                      presentation.controls.contentView.layer?.backgroundColor?.alpha == 1 else {
                    throw SimulatorError(message: "Toolbar content did not return to its native glass surface after full screen.")
                }
            }
            print("PASS: persistent full-width header, native window-owned traffic lights, native backdrop, centered device at full-screen and Split View dimensions, normal chrome restoration; AppKit layout check, not native Spaces")
            try await Task.sleep(for: .seconds(5.3))
            guard !FileManager.default.fileExists(atPath: consumedURL.path) else { throw SimulatorError(message: "Consumed screenshot was also autosaved.") }
            print("PASS: successful-drag callback cancels autosave; actual cross-app drop not exercised")
            let savedBefore = Set(try FileManager.default.contentsOfDirectory(at: app.capturePreviews.saveDirectory, includingPropertiesForKeys: nil))
            guard NSApp.mainMenu?.performKeyEquivalent(with: captureEvent) == true else { throw SimulatorError(message: "Pending screenshot shortcut did not dispatch.") }
            guard app.capturePreviews.hasPendingSaves else { throw SimulatorError(message: "In-flight screenshot capture was not registered.") }
            // Quit while PNG encoding is still queued, before the thumbnail has appeared.
            await app.capturePreviews.savePendingAndDismiss()
            let savedAfter = Set(try FileManager.default.contentsOfDirectory(at: app.capturePreviews.saveDirectory, includingPropertiesForKeys: nil))
            guard savedAfter.subtracting(savedBefore).count == 1,
                  app.capturePreviews.previews.isEmpty, !app.capturePreviews.hasPendingSaves else {
                throw SimulatorError(message: "Application shutdown would lose a pending screenshot.")
            }
            print("PASS: in-flight screenshot capture finishes and saves exactly once before application termination")
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            if session?["CGSSessionScreenIsLocked"] as? Bool == true {
                let result = "PASS: runtime submenus, independent device windows, system bezel, adaptive 52/76-point toolbar, compact/wide AppKit snapshots, native hover bezel configuration and pressed rendering, synthetic AppKit corner drags, rectangular PNGs, screenshot animation endpoints, rounded black thumbnails, autosave (QA directory), drag completion callbacks, pending-save flush, full-width header, original AppKit window-owned traffic lights, native backdrop configuration, centered device at full-screen and Split View dimensions, normal chrome restoration\nSKIP: actual pointer hover, mouse/cursor interaction, cross-app drop, animation appearance, native Space transition, desktop blur appearance and native Split View require an unlocked macOS session\n"
                try Data(result.utf8).write(to: directory.appendingPathComponent("presentation-results.txt"))
                print("SKIP: native full screen requires an unlocked macOS session")
                return
            }
            let original = window.frame
            NSApp.sendAction(stayAction, to: stayOnTop.target, from: stayOnTop)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(500))
            func fullScreenShortcut() throws {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
                guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw SimulatorError(message: "Full screen shortcut did not dispatch.") }
            }
            try fullScreenShortcut()
            for _ in 0..<100 {
                if controller.hasEnteredFullScreen { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard controller.hasEnteredFullScreen else { throw SimulatorError(message: "Native full screen did not finish entering.") }
            try await Task.sleep(for: .milliseconds(500))
            let nativeLayout = FullScreenPresentationLayout(bounds: root.bounds, safeAreaInsets: root.fullScreenSafeAreaInsets)
            guard !root.controls.isHidden, root.controls.frame == nativeLayout.header, !root.backdrop.isHidden else {
                throw SimulatorError(message: "Native full screen is missing the full-width header or backdrop.")
            }
            let center = root.canvas.convert(CGPoint(x: root.canvas.bounds.midX, y: root.canvas.bounds.midY), to: root)
            guard abs(center.x - nativeLayout.canvas.midX) < 1, abs(center.y - nativeLayout.canvas.midY) < 1 else {
                throw SimulatorError(message: "Full screen device canvas is not centered below the header.")
            }
            let expected = root.canvas.geometry.screen.size
            guard abs(controller.screen.bounds.width / controller.screen.bounds.height - expected.width / expected.height) < 0.001 else {
                throw SimulatorError(message: "Full screen stretched the device screen.")
            }
            try await captureWindow(window, filename: "full-screen.png")
            print("PASS: native full screen, full-width header, desktop backdrop, centered bezel below header and correct aspect ratio")
            let fullScreenCapture = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
            guard NSApp.mainMenu?.performKeyEquivalent(with: fullScreenCapture) == true else { throw SimulatorError(message: "Full screen screenshot shortcut did not dispatch.") }
            for _ in 0..<100 {
                if !app.capturePreviews.previews.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(650))
            guard let fullScreenPreview = app.capturePreviews.previews.last, let previewPanel = fullScreenPreview.window,
                  let host = window.screen else { throw SimulatorError(message: "Full screen screenshot preview is missing.") }
            guard NSApp.keyWindow === window, isPositionedCorrectly(previewPanel) else {
                throw SimulatorError(message: "Full screen screenshot focus=\(NSApp.keyWindow === window), panel=\(previewPanel.frame), expected=\(expectedPreviewFrame(previewPanel)).")
            }
            let displayID = (host.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            let displayRect = CGDisplayBounds(displayID)
            let region = "\(Int(displayRect.minX)),\(Int(displayRect.minY)),\(Int(displayRect.width)),\(Int(displayRect.height))"
            if CGPreflightScreenCaptureAccess() {
                _ = try await CommandRunner.run("/usr/sbin/screencapture", ["-x", "-R", region, directory.appendingPathComponent("full-screen-preview.png").path])
            } else {
                print("SKIP: full-screen preview screenshot requires Screen Recording access for the diagnostic app")
            }
            fullScreenPreview.dismiss()
            guard let retreat = fullScreenPreview.window,
                  retreat.title == "Capture Preview Dismissal",
                  (fullScreenPreview.superview?.layer?.mask as? CAShapeLayer)?.fillRule == .evenOdd,
                  fullScreenPreview.alphaValue == 1 else {
                throw SimulatorError(message: "Full screen preview did not retreat behind the device silhouette.")
            }
            try await Task.sleep(for: .milliseconds(400))
            print("PASS: full screen screenshot preview stays beside the device without taking keyboard focus")
            try fullScreenShortcut()
            for _ in 0..<100 {
                if !controller.hasEnteredFullScreen { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !controller.hasEnteredFullScreen, !root.controls.isHidden,
                  controller.staysOnTop, window.level == .floating,
                  abs(window.frame.width - original.width) < 1, abs(window.frame.height - original.height) < 1 else {
                throw SimulatorError(message: "Exiting full screen did not restore the device window.")
            }
            NSApp.sendAction(stayAction, to: stayOnTop.target, from: stayOnTop)
            print("PASS: native full screen restores the per-window Stay On Top preference on exit")
            print("PASS: exiting full screen restores the floating controls and original window size")
            try Data("PASS: menus, bezel, adaptive 52/76-point toolbar, compact/wide AppKit snapshots, native hover bezel configuration and pressed rendering, synthetic corner drags, rectangular PNGs, screenshot animation endpoints, rounded black thumbnails, window-relative preview, autosave (QA directory), drag completion callbacks, pending-save flush, native full screen with full-width header, centered bezel below header, backdrop configuration and restoration\nSKIP: actual pointer hover, mouse/cursor interaction, cross-app drop, animation appearance, visual blur comparison and native Split View not exercised by this smoke test\n".utf8).write(to: directory.appendingPathComponent("presentation-results.txt"))
        } catch { fputs("PRESENTATION FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
#endif
