import AppKit
import Combine

enum CapturePreviewLayout {
    static let shadowInset: CGFloat = 12
    static let bezelWidth: CGFloat = 3
    static let gap: CGFloat = 16
    static let dismissalDuration: TimeInterval = 0.35

    static func cardSize(imageSize: CGSize, displayedScreenSize: CGSize) -> CGSize {
        let scale = min(displayedScreenSize.width / imageSize.width, displayedScreenSize.height / imageSize.height) * 0.25
        return CGSize(width: imageSize.width * scale + bezelWidth * 2, height: imageSize.height * scale + bezelWidth * 2)
    }

    static func bottom(device: CGRect, screen: CGRect) -> CGFloat {
        // Align the card near the bottom of the device's lower bezel. At both
        // reference scales its captured pixels sit 5 points above this midpoint.
        (device.minY + screen.minY) / 2 + 2 - shadowInset
    }

    static func dismissalFrame(card: CGRect, under device: CGRect, cornerRadius: CGFloat) -> CGRect {
        let inset = min(cornerRadius + 4, max(0, (device.width - card.width) / 2))
        let x = card.midX >= device.midX ? device.maxX - inset - card.width : device.minX + inset
        return CGRect(origin: CGPoint(x: x, y: card.minY), size: card.size)
    }

    static func frame(size: CGSize, beside anchor: CGRect, visibleFrame: CGRect, bottom: CGFloat? = nil) -> CGRect {
        // Measure the gap to the captured pixels, inside the black phone frame.
        let right = anchor.maxX + gap - shadowInset - bezelWidth
        let left = anchor.minX - gap - size.width + shadowInset + bezelWidth
        let x: CGFloat
        if right + size.width - shadowInset <= visibleFrame.maxX { x = right }
        else if left + shadowInset >= visibleFrame.minX { x = left }
        else { x = visibleFrame.maxX - size.width - gap }
        let y = min(max(bottom ?? anchor.minY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        let clampedX = min(max(visibleFrame.minX, x), max(visibleFrame.minX, visibleFrame.maxX - size.width))
        return CGRect(x: clampedX, y: y, width: size.width, height: size.height)
    }
}

@MainActor final class CapturePreviewPresenter {
    @MainActor private final class Entry {
        let preview: CaptureThumbnail
        let panel: NSPanel
        let file: CaptureFile
        weak var sourceWindow: NSWindow?
        var anchor: CGRect
        var deviceFrame: CGRect
        var deviceCornerRadius: CGFloat = 0
        var displayID: UInt32
        var consumed = false
        var introPanel: NSPanel?
        var introTask: Task<Void, Never>?
        var flash: NSView?
        var dismissalPanel: NSPanel?
        var dismissalTask: Task<Void, Never>?
        private var saveTask: Task<URL, Error>?
        init(preview: CaptureThumbnail, panel: NSPanel, file: CaptureFile, sourceWindow: NSWindow?, anchor: CGRect, displayID: UInt32) {
            self.preview = preview; self.panel = panel; self.file = file
            self.sourceWindow = sourceWindow; self.anchor = anchor; self.deviceFrame = anchor; self.displayID = displayID
        }
        func save(in directory: URL) async throws -> URL {
            if let saveTask { return try await saveTask.value }
            let file = file
            let task = Task.detached(priority: .userInitiated) { try file.save(in: directory) }
            saveTask = task
            do { return try await task.value }
            catch { saveTask = nil; throw error }
        }
    }
    private var entries: [Entry] = []
    private var captures: [UUID: Task<Void, Never>] = [:]
    private var observers: Set<AnyCancellable> = []
    let saveDirectory: URL
    var previews: [CaptureThumbnail] { entries.map(\.preview) }
    var hasPendingSaves: Bool { !captures.isEmpty || entries.contains { !$0.consumed } }

    @discardableResult func capture(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.captures.removeValue(forKey: id) }
            await operation()
        }
        captures[id] = task
        return task
    }

    init(saveDirectory: URL? = nil) {
        self.saveDirectory = saveDirectory ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.layoutPreviews() }.store(in: &observers)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow,
                      self.entries.contains(where: { $0.sourceWindow === window }) else { return }
                self.layoutPreviews()
            }.store(in: &observers)
        }
    }
    private func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    func show(_ image: CGImage, file: CaptureFile, cornerRadius: CGFloat, beside window: NSWindow?, from screenRect: CGRect? = nil) {
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            let directory = saveDirectory
            capture { do { _ = try await Task.detached { try file.save(in: directory) }.value }
                catch { self.report(error, file: file) } }
            return
        }
        let siblings = entries.filter { $0.sourceWindow === window && !$0.preview.isFinished }
        if siblings.count >= 3 { siblings.first?.preview.dismiss() }
        let preview = CaptureThumbnail(image: image, fileURL: file.temporaryURL, kind: file.kind, cornerRadius: cornerRadius)
        let inset = CapturePreviewLayout.shadowInset
        let size = CGSize(width: preview.preferredSize.width + inset * 2, height: preview.preferredSize.height + inset * 2)
        let panel = makePanel(frame: CGRect(origin: .zero, size: size))
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        preview.frame = CGRect(origin: CGPoint(x: inset, y: inset), size: preview.preferredSize)
        content.addSubview(preview)
        panel.contentView = content
        let entry = Entry(preview: preview, panel: panel, file: file, sourceWindow: window,
            anchor: window?.frame ?? screen.visibleFrame, displayID: displayID(screen))
        preview.onComplete = { [weak self, weak entry] save in
            guard let self, let entry else { return }
            entry.consumed = !save
            guard save else { self.remove(entry); return }
            let dismissal = self.animateDismissal(entry)
            Task {
                do { _ = try await entry.save(in: self.saveDirectory) }
                catch { self.report(error, file: entry.file) }
                await dismissal?.value
                self.remove(entry)
            }
        }
        entries.append(entry)
        layoutPreviews()
        if let screenRect, !screenRect.isEmpty {
            animateCapture(entry, from: screenRect)
        } else {
            panel.orderFrontRegardless()
            preview.completePresentation()
        }
    }
    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = CapturePreviewPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Capture Preview"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.tabbingMode = .disallowed
        return panel
    }
    private func animateCapture(_ entry: Entry, from screenRect: CGRect) {
        let preview = entry.preview
        let bezel = CapturePreviewLayout.bezelWidth * screenRect.width / (preview.preferredSize.width - CapturePreviewLayout.bezelWidth * 2)
        let origin = screenRect.insetBy(dx: -bezel, dy: -bezel)
        let destination = entry.panel.convertToScreen(preview.frame)
        // One stationary, transparent panel lets the snapshot cross the source
        // window boundary. Animate its view, avoiding a second screen capture.
        let envelope = origin.union(destination).insetBy(dx: -16, dy: -16)
        let intro = makePanel(frame: envelope)
        intro.ignoresMouseEvents = true
        let content = NSView(frame: CGRect(origin: .zero, size: envelope.size))
        content.wantsLayer = true
        intro.contentView = content
        preview.removeFromSuperview()
        preview.frame = origin.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
        content.addSubview(preview)
        entry.introPanel = intro
        let flash = NSView(frame: preview.bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.cgColor
        flash.layer?.cornerRadius = preview.imageRadius + preview.bezelWidth
        flash.autoresizingMask = [.width, .height]
        preview.addSubview(flash)
        entry.flash = flash
        intro.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            flash.animator().alphaValue = 0
        }
        // AppKit can suspend animation completion for occluded/locked windows.
        // Keep the preview and autosave lifecycle moving on elapsed time.
        entry.introTask = Task { [weak self, weak entry] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, let entry else { return }
            flash.removeFromSuperview()
            entry.flash = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                preview.animator().frame = destination.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
            }, completionHandler: nil)
            do { try await Task.sleep(for: .milliseconds(440)) } catch { return }
            self.finishPresentation(entry)
        }
    }
    private func finishPresentation(_ entry: Entry) {
        guard let intro = entry.introPanel else { return }
        entry.introTask?.cancel(); entry.introTask = nil
        entry.flash?.removeFromSuperview(); entry.flash = nil
        entry.introPanel = nil
        guard entries.contains(where: { $0 === entry }), !entry.preview.isFinished else { intro.close(); return }
        entry.preview.removeFromSuperview()
        entry.preview.frame = CGRect(origin: CGPoint(x: CapturePreviewLayout.shadowInset, y: CapturePreviewLayout.shadowInset), size: entry.preview.preferredSize)
        entry.panel.contentView?.addSubview(entry.preview)
        entry.panel.orderFrontRegardless()
        intro.close()
        entry.preview.completePresentation()
    }
    private func layoutPreviews() {
        var bottoms: [ObjectIdentifier: CGFloat] = [:]
        for entry in entries.reversed() where !entry.preview.isFinished {
            if entry.introPanel != nil { finishPresentation(entry) }
            var bottom: CGFloat?
            if let window = entry.sourceWindow {
                entry.anchor = window.frame
                entry.deviceFrame = window.frame
                if let root = window.contentView as? DevicePresentationView {
                    root.layoutSubtreeIfNeeded()
                    let device = window.convertToScreen(root.convert(root.deviceRect, to: nil))
                    let screen = root.canvas.screen
                    let display = window.convertToScreen(screen.convert(screen.bounds, to: nil))
                    let header = window.convertToScreen(root.controls.convert(root.controls.bounds, to: nil))
                    entry.anchor = root.isFullScreen ? device : device.union(header)
                    entry.deviceFrame = device
                    entry.deviceCornerRadius = root.deviceCornerRadius
                    if !display.isEmpty { entry.preview.displayedScreenSize = display.size }
                    bottom = CapturePreviewLayout.bottom(device: device, screen: display)
                }
                if let screen = window.screen { entry.displayID = displayID(screen) }
            }
            guard let screen = NSScreen.screens.first(where: { displayID($0) == entry.displayID }) ?? NSScreen.main else { continue }
            let key = entry.sourceWindow.map(ObjectIdentifier.init) ?? ObjectIdentifier(entry.panel)
            let cardSize = entry.preview.preferredSize
            let inset = CapturePreviewLayout.shadowInset
            let size = CGSize(width: cardSize.width + inset * 2, height: cardSize.height + inset * 2)
            let frame = CapturePreviewLayout.frame(size: size, beside: entry.anchor,
                visibleFrame: screen.visibleFrame, bottom: bottoms[key] ?? bottom)
            entry.panel.setFrame(frame, display: true, animate: false)
            entry.panel.contentView?.frame.size = size
            entry.preview.frame = CGRect(origin: CGPoint(x: inset, y: inset), size: cardSize)
            bottoms[key] = frame.maxY + 8
        }
    }
    private func animateDismissal(_ entry: Entry) -> Task<Void, Never>? {
        guard let source = entry.sourceWindow, source.isVisible else {
            entry.introTask?.cancel(); entry.introPanel?.close(); entry.panel.orderOut(nil)
            return nil
        }
        let card = entry.panel.convertToScreen(CGRect(origin: CGPoint(x: CapturePreviewLayout.shadowInset, y: CapturePreviewLayout.shadowInset),
            size: entry.preview.preferredSize))
        let destination = CapturePreviewLayout.dismissalFrame(card: card, under: entry.deviceFrame, cornerRadius: entry.deviceCornerRadius)
        let envelope = card.union(destination).insetBy(dx: -CapturePreviewLayout.shadowInset, dy: -CapturePreviewLayout.shadowInset)
        let overlay = makePanel(frame: envelope)
        overlay.title = "Capture Preview Dismissal"
        overlay.ignoresMouseEvents = true
        let content = NSView(frame: CGRect(origin: .zero, size: envelope.size))
        content.wantsLayer = true
        overlay.contentView = content
        entry.introTask?.cancel(); entry.introTask = nil
        entry.flash?.removeFromSuperview(); entry.flash = nil
        entry.preview.removeFromSuperview()
        entry.preview.layer?.removeAllAnimations()
        entry.preview.frame = card.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
        content.addSubview(entry.preview)
        entry.dismissalPanel = overlay
        // Normal foreground windows provide real AppKit occlusion. Full-screen
        // backdrops cover the display; lowering an inactive window's preview also
        // hides it behind the active app too early. Keep these overlays floating
        // and clip against the device silhouette throughout the horizontal slide.
        if source.styleMask.contains(.fullScreen) || (!NSApp.isActive && source.level == .normal) {
            let mask = CAShapeLayer()
            mask.frame = content.bounds
            let path = CGMutablePath()
            path.addRect(content.bounds)
            path.addRoundedRect(in: entry.deviceFrame.offsetBy(dx: -envelope.minX, dy: -envelope.minY),
                cornerWidth: entry.deviceCornerRadius, cornerHeight: entry.deviceCornerRadius)
            mask.path = path; mask.fillRule = .evenOdd
            content.layer?.mask = mask
            overlay.orderFrontRegardless()
        } else {
            overlay.level = source.level
            overlay.order(.below, relativeTo: source.windowNumber)
        }
        entry.introPanel?.close(); entry.introPanel = nil
        entry.panel.orderOut(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CapturePreviewLayout.dismissalDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            entry.preview.animator().frame = destination.offsetBy(dx: -envelope.minX, dy: -envelope.minY)
        }
        let task = Task { [weak entry] in
            do { try await Task.sleep(for: .seconds(CapturePreviewLayout.dismissalDuration)) } catch { return }
            entry?.dismissalPanel?.orderOut(nil)
        }
        entry.dismissalTask = task
        return task
    }
    private func report(_ error: Error, file: CaptureFile) {
        let alert = NSAlert(error: error)
        alert.informativeText += "\nThe temporary \(file.kind.title.lowercased()) is still available at \(file.temporaryURL.path)."
        alert.runModal()
    }
    private func remove(_ entry: Entry) {
        entries.removeAll { $0 === entry }
        entry.introTask?.cancel(); entry.introPanel?.close()
        entry.dismissalTask?.cancel(); entry.dismissalPanel?.close()
        entry.panel.close()
        layoutPreviews()
    }
    func savePendingAndDismiss() async {
        while !captures.isEmpty {
            for task in Array(captures.values) { await task.value }
        }
        for entry in entries where !entry.consumed {
            do { _ = try await entry.save(in: saveDirectory) }
            catch { report(error, file: entry.file) }
        }
        dismissAll()
    }
    func dismissAll() {
        let old = entries
        entries.removeAll()
        for entry in old {
            entry.introTask?.cancel(); entry.introPanel?.close()
            entry.dismissalTask?.cancel(); entry.dismissalPanel?.close()
            entry.preview.cancelTimer(); entry.panel.close()
        }
    }
}

private final class CapturePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
