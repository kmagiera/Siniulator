import AppKit
import UniformTypeIdentifiers

@MainActor class CaptureCardView: NSView {
    let image: NSImage
    let cornerRadius: CGFloat
    var displayedScreenSize: CGSize? { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }
    init(image: CGImage, cornerRadius: CGFloat) {
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    var preferredSize: CGSize {
        if let displayedScreenSize {
            return CapturePreviewLayout.cardSize(imageSize: image.size, displayedScreenSize: displayedScreenSize)
        }
        let scale = min(110 / image.size.width, 170 / image.size.height)
        return CGSize(width: image.size.width * scale + 6, height: image.size.height * scale + 6)
    }
    var bezelWidth: CGFloat { CapturePreviewLayout.bezelWidth * bounds.width / preferredSize.width }
    var imageRect: CGRect { bounds.insetBy(dx: bezelWidth, dy: bezelWidth) }
    var imageRadius: CGFloat { cornerRadius * imageRect.width / image.size.width }
    override func layout() {
        super.layout()
        let radius = imageRadius + bezelWidth
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let radius = imageRadius + bezelWidth
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: imageRadius, yRadius: imageRadius).addClip()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    func draggingImage() -> NSImage {
        // Only the drag ghost has the phone frame; the file is the original capture.
        let result = NSImage(size: bounds.size)
        result.lockFocusFlipped(true)
        draw(bounds)
        result.unlockFocus()
        return result
    }
}

@MainActor final class CaptureThumbnail: CaptureCardView, NSDraggingSource {
    let fileURL: URL
    let kind: CaptureKind
    private var dismissTask: Task<Void, Never>?
    private var pointerTracking: NSTrackingArea?
    private var mouseOrigin = CGPoint.zero
    private var pointerInside = false
    private var dragging = false
    private(set) var isPresenting = true
    private(set) var isFinished = false
    var onComplete: ((Bool) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(image: CGImage, fileURL: URL, kind: CaptureKind, cornerRadius: CGFloat) {
        self.fileURL = fileURL
        self.kind = kind
        super.init(image: image, cornerRadius: cornerRadius)
        toolTip = "Drag \(kind == .recording ? "recording" : "screenshot") into another app. Click to open; right-click for more options."
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(kind.title) preview")
        let menu = NSMenu()
        for (title, selector) in [("Open", #selector(openFile)), ("Save As…", #selector(saveAs)), ("Copy", #selector(copyFile)), ("Reveal in Finder", #selector(reveal)), ("Save to Desktop", #selector(dismiss))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func completePresentation() {
        isPresenting = false
        resetDismissTimer()
    }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); pointerTracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; cancelTimer() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; if !dragging { resetDismissTimer() } }
    override func mouseDown(with event: NSEvent) {
        guard !isFinished else { return }
        cancelTimer()
        mouseOrigin = event.locationInWindow; dragging = false
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !isFinished else { return }
        cancelTimer()
        super.rightMouseDown(with: event)
        resetDismissTimer()
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isFinished, !dragging, hypot(event.locationInWindow.x - mouseOrigin.x, event.locationInWindow.y - mouseOrigin.y) > 3 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: draggingImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        guard !isFinished else { return }
        if !dragging, !event.modifierFlags.contains(.control) { openFile() }
        resetDismissTimer()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        completeDrag(operation: operation)
    }
    func completeDrag(operation: NSDragOperation) {
        dragging = false
        if operation != [] { finish(save: false) } else { resetDismissTimer() }
    }
    func cancelTimer() { dismissTask?.cancel(); dismissTask = nil }
    private func resetDismissTimer() {
        cancelTimer()
        guard !isFinished, !isPresenting, !pointerInside, !dragging else { return }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.dismiss()
        }
    }
    @objc private func openFile() { NSWorkspace.shared.open(fileURL) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    @objc private func copyFile() {
        NSPasteboard.general.clearContents()
        if kind == .screenshot { NSPasteboard.general.writeObjects([fileURL as NSURL, image]) }
        else { NSPasteboard.general.writeObjects([fileURL as NSURL]) }
        resetDismissTimer()
    }
    @objc private func saveAs() {
        cancelTimer()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind.contentType]
        panel.nameFieldStringValue = fileURL.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in
            guard let self else { return }
            if result == .OK, let url = panel.url {
                // A movie can be large; copying it must not block AppKit input.
                let file = CaptureFile(temporaryURL: self.fileURL, kind: self.kind)
                Task {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try file.save(to: url)
                        }.value
                    } catch { NSAlert(error: error).runModal() }
                    self.resetDismissTimer()
                }
                return
            }
            self.resetDismissTimer()
        }
    }
    @objc func dismiss() {
        finish(save: true)
    }
    private func finish(save: Bool) {
        guard !isFinished else { return }
        isFinished = true
        cancelTimer()
        onComplete?(save)
    }
}
