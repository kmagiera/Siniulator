import AppKit
import MetalKit
import CoreImage
import IOSurface
import SimulatorBridge

enum ScreenGeometry {
    static func imageRect(image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width.isFinite, image.height.isFinite, image.width > 0, image.height > 0,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func normalizedQuarterTurns(_ turns: Int) -> Int { (turns % 4 + 4) % 4 }
    static func nativeQuarterTurns(degrees: Int) -> Int {
        normalizedQuarterTurns(-(degrees / 90))
    }
    static func displayQuarterTurns(orientation: Int, nativeRotation: Int) -> Int {
        normalizedQuarterTurns(orientation + nativeRotation)
    }

    static func originalPoint(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
        switch normalizedQuarterTurns(quarterTurns) {
        case 1: return CGPoint(x: point.y, y: 1 - point.x)
        case 2: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: return CGPoint(x: 1 - point.y, y: point.x)
        default: return point
        }
    }
    static func edge(_ point: CGPoint) -> UInt64 {
        if point.y >= 0.97 { return 3 }
        if point.y <= 0.03 { return 1 }
        if point.x <= 0.03 { return 2 }
        if point.x >= 0.97 { return 4 }
        return 0
    }
    @MainActor static func pointerLocation(for event: NSEvent, in view: NSView) -> CGPoint {
        // flagsChanged is a keyboard event: its locationInWindow is not the
        // current cursor position. Mouse events retain their queued positions.
        let location = event.type == .flagsChanged
            ? view.window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
            : event.locationInWindow
        return view.convert(location, from: nil)
    }
}

// CoreSimulator can emit several damage/surface callbacks before AppKit runs.
// Coalesce them without waiting for a drawable (the 2D layer is hidden on Duo).
final class DisplayFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private let handler: @MainActor @Sendable () -> Void

    init(handler: @escaping @MainActor @Sendable () -> Void) { self.handler = handler }

    func requestFrame() {
        lock.lock()
        let schedule = !pending
        pending = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock(); pending = false; lock.unlock()
            handler()
        }
    }
}

/// A sibling of the touchscreen, so suspending its Metal layer on Duo does
/// not also hide the host's two-finger gesture feedback.
@MainActor final class SimulatorGestureOverlay: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class SimulatorScreenView: NSView {
    lazy var frameDelivery = DisplayFrameDelivery { [weak self] in
        guard let self else { return }
        onDisplayChange?(display)
    }
    func frameHandler(observesSurfaceChanges: Bool) -> @Sendable () -> Void {
        let renderer = renderer
        let delivery = observesSurfaceChanges ? frameDelivery : nil
        return { [weak renderer] in
            // Preserve off-main rendering for ordinary devices.
            renderer?.requestFrame()
            delivery?.requestFrame()
        }
    }
    var display: SIDisplay? {
        didSet {
            if display == nil { displayChrome = nil }
            renderer.setDisplay(display)
            onDisplayChange?(display)
        }
    }
    // The layout can already show the next pose while its framebuffer is still
    // connecting. Keep the source panel separate from the requested pose.
    private(set) var displayChrome: DeviceChrome?
    func setDisplay(_ display: SIDisplay, chrome: DeviceChrome) {
        displayChrome = chrome
        nativeQuarterTurns = chrome.nativeQuarterTurns
        self.display = display
    }
    var onDisplayChange: ((SIDisplay?) -> Void)?
    var magnifyHandler: ((NSEvent) -> Bool)?
    var coordinateMapper: ((_ point: CGPoint, _ clamped: Bool) -> CGPoint?)? {
        didSet {
            if (oldValue == nil) != (coordinateMapper == nil) {
                endContact()
                multitouch = MultitouchState()
                fingerLayers.forEach { $0.isHidden = true }; gestureCenter.isHidden = true
            }
        }
    }
    var coordinateProjector: ((CGPoint) -> CGPoint?)?
    let gestureOverlay = SimulatorGestureOverlay()
    private var gestureQuarterTurns: Int { coordinateMapper == nil ? displayQuarterTurns : 0 }
    var input: SimulatorInput?
    var keyboardEnabled = true {
        didSet { if !keyboardEnabled { releaseKeys() } }
    }
    var quarterTurns = 0 {
        didSet {
            quarterTurns = ScreenGeometry.normalizedQuarterTurns(quarterTurns)
            configureRenderer()
            needsDisplay = true
        }
    }
    var nativeQuarterTurns = 0 {
        didSet {
            nativeQuarterTurns = ScreenGeometry.normalizedQuarterTurns(nativeQuarterTurns)
            configureRenderer()
            needsDisplay = true
        }
    }
    var displayQuarterTurns: Int {
        ScreenGeometry.displayQuarterTurns(orientation: quarterTurns, nativeRotation: nativeQuarterTurns)
    }
    let renderer: ScreenRenderer
    private var contact: CGPoint?
    private var secondContact: CGPoint?
    private var edge: UInt64 = 0
    private var heldKeys: Set<UInt64> = []
    private var modifiers: Set<UInt64> = []
    private var scrollEnd: DispatchWorkItem?
    private var scrollPoint: CGPoint?
    private var pinchDistance: CGFloat = 0.15
    private var multitouch = MultitouchState()
    private var tracking: NSTrackingArea?
    private let fingerLayers = [CAShapeLayer(), CAShapeLayer()]
    private let gestureCenter = CAShapeLayer()

    init(renderer: ScreenRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        gestureOverlay.wantsLayer = true
        for finger in fingerLayers {
            finger.fillColor = NSColor.white.withAlphaComponent(0.25).cgColor
            finger.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            finger.lineWidth = 2
            finger.isHidden = true
            gestureOverlay.layer?.addSublayer(finger)
        }
        gestureCenter.fillColor = NSColor.clear.cgColor
        gestureCenter.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
        gestureCenter.lineWidth = 1
        gestureCenter.isHidden = true
        gestureOverlay.layer?.addSublayer(gestureCenter)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("Simulator touchscreen")
        setAccessibilityRole(.image)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func currentImage() -> CIImage? {
        guard let surface = display?.surface as? IOSurface else { return nil }
        let image = CIImage(ioSurface: surface)
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        return image.oriented(orientations[displayQuarterTurns])
    }
#if DEBUG
    var diagnosticContacts: [CGPoint] { [contact, secondContact].compactMap { $0 } }
    func screenshot() -> CGImage? {
        guard let image = currentImage() else { return nil }
        return renderer.engine.images.createCGImage(image, from: image.extent)
    }
#endif

    override func makeBackingLayer() -> CALayer { renderer.layer }
    override func layout() { super.layout(); configureRenderer() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); configureRenderer() }
    override func updateLayer() { renderer.requestFrame() }
    private func configureRenderer() {
        renderer.configure(size: bounds.size, scale: window?.backingScaleFactor ?? 2,
                           turns: displayQuarterTurns)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fingerLayers.forEach { $0.frame = bounds }; gestureCenter.frame = bounds
        CATransaction.commit()
    }
    var framebufferSize: CGSize {
        guard let surface = display?.surface as? IOSurface else { return .zero }
        return displayQuarterTurns % 2 == 0
            ? CGSize(width: surface.width, height: surface.height)
            : CGSize(width: surface.height, height: surface.width)
    }

    private func normalized(_ event: NSEvent, clamped: Bool = false) -> CGPoint? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let coordinateMapper { return coordinateMapper(viewPoint, clamped) }
        let size = framebufferSize
        guard size.width > 0, size.height > 0 else { return nil }
        let rect = ScreenGeometry.imageRect(image: size, in: bounds)
        guard !rect.isEmpty else { return nil }
        let point = viewPoint
        guard clamped || rect.contains(point) else { return nil }
        let normalized = CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                                 y: min(1, max(0, (point.y - rect.minY) / rect.height)))
        return ScreenGeometry.originalPoint(normalized, quarterTurns: displayQuarterTurns)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endContact()
        guard let point = normalized(event) else { return }
        contact = point
        edge = ScreenGeometry.edge(point)
        if event.modifierFlags.contains(.option) {
            guard updateFingers(event) else { contact = nil; return }
            contact = ScreenGeometry.originalPoint(multitouch.first, quarterTurns: gestureQuarterTurns)
            secondContact = ScreenGeometry.originalPoint(multitouch.second, quarterTurns: gestureQuarterTurns)
            edge = 0
            // The host gesture modifiers must not stick on the guest keyboard.
            for usage in modifiers.intersection([0xe1, 0xe2]) { input?.key(usage, down: false); modifiers.remove(usage) }
        }
        input?.touch(contact!, phase: .start, edge: edge, second: secondContact)
    }
    override func mouseDragged(with event: NSEvent) {
        guard contact != nil, let point = normalized(event, clamped: true) else { return }
        contact = point
        if secondContact != nil {
            guard updateFingers(event) else { return }
            contact = ScreenGeometry.originalPoint(multitouch.first, quarterTurns: gestureQuarterTurns)
            secondContact = ScreenGeometry.originalPoint(multitouch.second, quarterTurns: gestureQuarterTurns)
        }
        input?.touch(contact!, phase: .move, edge: edge, second: secondContact)
    }
    override func mouseUp(with event: NSEvent) {
        if contact != nil {
            if secondContact != nil {
                updateFingers(event)
                contact = ScreenGeometry.originalPoint(multitouch.first, quarterTurns: gestureQuarterTurns)
                secondContact = ScreenGeometry.originalPoint(multitouch.second, quarterTurns: gestureQuarterTurns)
            } else { contact = normalized(event, clamped: true) ?? contact }
        }
        endContact()
    }
    func endContact() {
        if let contact { input?.touch(contact, phase: .end, edge: edge, second: secondContact) }
        contact = nil; secondContact = nil; edge = 0
        if let scrollPoint { input?.touch(scrollPoint, phase: .end) }
        scrollPoint = nil
        scrollEnd?.cancel()
    }
    override func scrollWheel(with event: NSEvent) {
        guard let start = normalized(event) else { return }
        if scrollPoint == nil {
            endContact()
            scrollPoint = start
            input?.touch(start, phase: .start)
        }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let rect = ScreenGeometry.imageRect(image: framebufferSize, in: bounds)
        guard rect.width > 0, rect.height > 0, let current = scrollPoint else { return }
        let delta = ScreenGeometry.originalPoint(CGPoint(x: 0.5 + event.scrollingDeltaX * factor / rect.width,
                                                         y: 0.5 + event.scrollingDeltaY * factor / rect.height), quarterTurns: displayQuarterTurns)
        let point = CGPoint(x: min(0.98, max(0.02, current.x + delta.x - 0.5)),
                            y: min(0.98, max(0.02, current.y + delta.y - 0.5)))
        scrollPoint = point
        input?.touch(point, phase: .move)
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.endContact() }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: end)
    }
    override func magnify(with event: NSEvent) {
        if magnifyHandler?(event) == true { return }
        if event.phase == .began || secondContact == nil {
            endContact()
            pinchDistance = 0.15
            contact = ScreenGeometry.originalPoint(CGPoint(x: 0.5 - pinchDistance, y: 0.5), quarterTurns: displayQuarterTurns)
            secondContact = ScreenGeometry.originalPoint(CGPoint(x: 0.5 + pinchDistance, y: 0.5), quarterTurns: displayQuarterTurns)
            input?.touch(contact!, phase: .start, second: secondContact)
        }
        pinchDistance = min(0.45, max(0.02, pinchDistance + event.magnification * 0.3))
        contact = ScreenGeometry.originalPoint(CGPoint(x: 0.5 - pinchDistance, y: 0.5), quarterTurns: displayQuarterTurns)
        secondContact = ScreenGeometry.originalPoint(CGPoint(x: 0.5 + pinchDistance, y: 0.5), quarterTurns: displayQuarterTurns)
        input?.touch(contact!, phase: .move, second: secondContact)
        if event.phase == .ended || event.phase == .cancelled { endContact() }
    }
    override func keyDown(with event: NSEvent) {
        guard keyboardEnabled, !event.modifierFlags.contains(.command), let usage = KeyboardMap.usages[event.keyCode] else { super.keyDown(with: event); return }
        heldKeys.insert(usage)
        input?.key(usage, down: true)
    }
    override func keyUp(with event: NSEvent) {
        guard let usage = KeyboardMap.usages[event.keyCode], heldKeys.remove(usage) != nil else { return }
        input?.key(usage, down: false)
    }
    override func flagsChanged(with event: NSEvent) {
        let showFingers = event.modifierFlags.contains(.option)
        if showFingers { updateFingers(event) }
        else {
            if secondContact != nil { endContact() }
            multitouch.resetTracking()
            fingerLayers.forEach { $0.isHidden = true }; gestureCenter.isHidden = true
        }
        guard keyboardEnabled else { return }
        var next: Set<UInt64> = []
        if event.modifierFlags.contains(.shift), !showFingers { next.insert(0xe1) }
        if event.modifierFlags.contains(.control) { next.insert(0xe0) }
        // Option is reserved for the host two-finger gesture.
        if event.modifierFlags.contains(.capsLock) { next.insert(0x39) }
        for usage in modifiers.subtracting(next) { input?.key(usage, down: false) }
        for usage in next.subtracting(modifiers) { input?.key(usage, down: true) }
        modifiers = next
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { if event.modifierFlags.contains(.option) { updateFingers(event) } }
    override func mouseEntered(with event: NSEvent) { if event.modifierFlags.contains(.option) { updateFingers(event) } }
    override func mouseExited(with event: NSEvent) {
        if contact == nil {
            multitouch.resetTracking()
            fingerLayers.forEach { $0.isHidden = true }; gestureCenter.isHidden = true
        }
    }
    @discardableResult private func updateFingers(_ event: NSEvent) -> Bool {
        let rect = ScreenGeometry.imageRect(image: framebufferSize, in: bounds)
        guard rect.width > 0, rect.height > 0 else { return false }
        let p = ScreenGeometry.pointerLocation(for: event, in: self)
        // Clamp the contacts in MultitouchState, not the cursor. A drag beyond
        // the view must still be able to move relative to its Shift anchor.
        let pointer: CGPoint
        if let coordinateMapper {
            guard let mapped = coordinateMapper(p, true) else { return false }
            pointer = mapped
        } else {
            pointer = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        }
        multitouch.update(pointer: pointer, translating: event.modifierFlags.contains(.shift))
        func project(_ point: CGPoint) -> CGPoint? {
            if let coordinateProjector { return coordinateProjector(point) }
            return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (finger, point) in zip(fingerLayers, [multitouch.first, multitouch.second]) {
            guard let local = project(point) else { finger.isHidden = true; continue }
            finger.path = CGPath(ellipseIn: CGRect(x: local.x - 13, y: local.y - 13, width: 26, height: 26), transform: nil)
            finger.isHidden = false
        }
        if let center = project(multitouch.center) {
            gestureCenter.path = CGPath(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6), transform: nil)
            gestureCenter.isHidden = false
        } else { gestureCenter.isHidden = true }
        CATransaction.commit()
        return true
    }
    func releaseKeys() {
        for usage in heldKeys.union(modifiers) { input?.key(usage, down: false) }
        heldKeys = []; modifiers = []
        multitouch.resetTracking()
        fingerLayers.forEach { $0.isHidden = true }; gestureCenter.isHidden = true
        endContact()
    }
    override func resignFirstResponder() -> Bool { releaseKeys(); return super.resignFirstResponder() }
    var onDrop: (([URL]) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        onDrop?(urls)
        return true
    }
}
