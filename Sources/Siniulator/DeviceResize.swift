import AppKit

enum DeviceResizeCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }

    // The presentation view uses top-left coordinates, unlike screen coordinates.
    func hitRect(in device: CGRect, radius: CGFloat) -> CGRect {
        let vertex = CGPoint(x: isLeft ? device.minX : device.maxX, y: isTop ? device.minY : device.maxY)
        let offset = min(radius, device.width / 2, device.height / 2) * (1 - 1 / sqrt(2))
        let curve = CGPoint(x: vertex.x + (isLeft ? offset : -offset), y: vertex.y + (isTop ? offset : -offset))
        // The rectangular vertex is transparent for a rounded device. Keeping
        // it in the resize target made the cursor appear beyond the visible
        // hardware, especially while a foldable was projected into depth.
        return CGRect(x: curve.x - 14, y: curve.y - 14, width: 28, height: 28)
    }
    @MainActor var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return .frameResize(position: position, directions: [.inward, .outward])
        }
        let symbol = isLeft == isTop ? "arrow.up.left.and.arrow.down.right" : "arrow.up.right.and.arrow.down.left"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Resize simulator")!
        image.size = CGSize(width: 20, height: 20)
        return NSCursor(image: image, hotSpot: CGPoint(x: 10, y: 10))
    }
}

struct DeviceResizeSession {
    let corner: DeviceResizeCorner
    let initialFrame: CGRect
    let initialPointer: CGPoint
    let deviceSize: CGSize
    let initialScale: CGFloat
    let visibleFrame: CGRect
    let minimumSize: CGSize
    var toolbarMetrics: SimulatorToolbarMetrics? = nil

    func frame(at pointer: CGPoint) -> CGRect { geometry(at: pointer).frame }
    func geometry(at pointer: CGPoint) -> (frame: CGRect, scale: CGFloat) {
        // A foldable keeps its window frame while switching between displays,
        // so the current pose can start with real horizontal slack around its
        // canvas. Preserve that slack at pointer zero to avoid a jump. Do not
        // mistake space caused only by the toolbar minimum for permanent bezel
        // padding; it must disappear again as a small phone is enlarged.
        let normalExtraWidth = NormalPresentationLayout.deviceSideMargin * 2
        let ordinaryInitialWidth = max(minimumSize.width, deviceSize.width * initialScale + normalExtraWidth)
        let extraWidth = abs(initialFrame.width - ordinaryInitialWidth) <= 1
            ? normalExtraWidth
            : max(normalExtraWidth, initialFrame.width - deviceSize.width * initialScale)
        func barHeight(for width: CGFloat) -> CGFloat {
            toolbarMetrics?.layout(width: width).height ?? SimulatorControlBarLayout.expandedHeight
        }
        let extraHeight = initialFrame.height - deviceSize.height * initialScale - barHeight(for: initialFrame.width)
        let dx = (pointer.x - initialPointer.x) * (corner.isLeft ? -1 : 1)
        let dy = (pointer.y - initialPointer.y) * (corner.isTop ? 1 : -1)
        // Project pointer movement onto the device diagonal to preserve shape.
        let delta = (dx * deviceSize.width + dy * deviceSize.height) /
            (deviceSize.width * deviceSize.width + deviceSize.height * deviceSize.height)
        let anchor = CGPoint(x: corner.isLeft ? initialFrame.maxX : initialFrame.minX,
            y: corner.isTop ? initialFrame.minY : initialFrame.maxY)
        let availableWidth = corner.isLeft ? anchor.x - visibleFrame.minX : visibleFrame.maxX - anchor.x
        let availableHeight = corner.isTop ? visibleFrame.maxY - anchor.y : anchor.y - visibleFrame.minY
        // A minimum toolbar width must not prevent shrinking the phone: below
        // that width, its canvas gains horizontal space around the smaller bezel.
        func scaleForHeight(_ height: CGFloat, cappedAt cap: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
            let candidate = min(cap, max(0.01, (height - extraHeight - SimulatorControlBarLayout.expandedHeight) / deviceSize.height))
            let width = max(minimumSize.width, deviceSize.width * candidate + extraWidth)
            return max(0.01, min(cap, (height - extraHeight - barHeight(for: width)) / deviceSize.height))
        }
        let minimum = scaleForHeight(minimumSize.height)
        let maximum = scaleForHeight(availableHeight, cappedAt: max(0.01, (availableWidth - extraWidth) / deviceSize.width))
        let scale = min(maximum, max(minimum, initialScale + delta))
        let width = max(minimumSize.width, deviceSize.width * scale + extraWidth)
        let size = CGSize(width: width, height: deviceSize.height * scale + extraHeight + barHeight(for: width))
        return (CGRect(x: corner.isLeft ? anchor.x - size.width : anchor.x,
            y: corner.isTop ? anchor.y : anchor.y - size.height, width: size.width, height: size.height), scale)
    }
}

@MainActor final class DeviceHostWindow: NSWindow {
    private var resizeSession: DeviceResizeSession?
    var isCornerResizing: Bool { resizeSession != nil }
    var onManualResize: (() -> Void)?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var trackingMagnification = false

    /// WindowServer otherwise treats the entire SceneKit backing surface as a
    /// mouse target, including its transparent, unfolded-size margins. A nil
    /// NSView hit test cannot hand the click to a different application.
    func updateMousePassthrough() {
        guard !styleMask.contains(.fullScreen),
              let root = contentView as? DevicePresentationView, root.hasTransparentDuoMargins else {
            stopPointerMonitoring()
            return
        }
        if localPointerMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.updateMousePassthrough()
                return event
            }
            // Necessary to re-enable this window when the pointer returns from
            // another app while ignoresMouseEvents is true. No event replay.
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                self?.updateMousePassthrough()
            }
        }
        updateMousePassthrough(at: NSEvent.mouseLocation, buttonsPressed: NSEvent.pressedMouseButtons != 0)
    }

    func updateMousePassthrough(at screenPoint: CGPoint, buttonsPressed: Bool) {
        guard !styleMask.contains(.fullScreen),
              let root = contentView as? DevicePresentationView, root.hasTransparentDuoMargins else {
            ignoresMouseEvents = false
            return
        }
        // Preserve the owner of an in-flight drag, even beyond the mesh. This
        // applies both to simulator input/resizing and a drag in the app below.
        guard !buttonsPressed, !isCornerResizing, !trackingMagnification else { return }
        let local = root.convert(convertPoint(fromScreen: screenPoint), from: nil)
        ignoresMouseEvents = !root.acceptsMouse(at: local)
    }

    private func stopPointerMonitoring() {
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        localPointerMonitor = nil
        globalPointerMonitor = nil
        ignoresMouseEvents = false
    }

    func updatePresentationBackground() {
        // AppKit rebuilds window chrome during native full-screen transitions.
        // Bezel-free desktop windows are ordinary opaque windows. Native full
        // screen remains clear for the wallpaper and its visual effect.
        let attached = !styleMask.contains(.fullScreen) && (contentView as? DevicePresentationView)?.usesAttachedChrome == true
        if isOpaque != attached { isOpaque = attached }
        let color: NSColor = attached ? .black : .clear
        if backgroundColor != color { backgroundColor = color }
    }

    private func screenPosition(of event: NSEvent) -> CGPoint {
        if let position = event.cgEvent?.location, let primary = NSScreen.screens.first {
            // A queued event's window-relative coordinates belong to the frame
            // at event creation. Bottom/left resize changes that frame's origin.
            // Quartz records an absolute position, independent of those moves.
            return CGPoint(x: position.x, y: primary.frame.maxY - position.y)
        }
        return convertToScreen(CGRect(origin: event.locationInWindow, size: .zero)).origin
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .magnify {
            if event.phase == .began { trackingMagnification = true }
            if event.phase == .ended || event.phase == .cancelled { trackingMagnification = false }
        }
        defer {
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp, .magnify].contains(event.type) {
                updateMousePassthrough()
            }
        }
        if event.type == .leftMouseDown,
           let bar = (contentView as? DevicePresentationView)?.controls, !bar.isFullScreen,
           let control = bar.displayModeControl,
           !control.isHidden, control.bounds.contains(control.convert(event.locationInWindow, from: nil)) {
            // The transparent native titlebar sits above the persistent custom
            // bar. Route clicks in the centered Duo control to the real AppKit
            // segmented control instead of letting the titlebar start a drag.
            control.mouseDown(with: event)
            return
        }
        if let session = resizeSession {
            if event.type == .leftMouseDragged {
                onManualResize?()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let geometry = session.geometry(at: screenPosition(of: event))
                (contentView as? DevicePresentationView)?.canvas.maximumScale = geometry.scale
                setFrame(geometry.frame, display: false, animate: false)
                contentView?.layoutSubtreeIfNeeded()
                displayIfNeeded()
                CATransaction.commit()
                return
            }
            if event.type == .leftMouseUp { endCornerResize(); return }
        }
        if event.type == .leftMouseDown, !styleMask.contains(.fullScreen),
           let root = contentView as? DevicePresentationView, !root.isFullScreen, root.canvas.showsBezels {
            let pointer = screenPosition(of: event)
            let point = root.convert(convertFromScreen(CGRect(origin: pointer, size: .zero)).origin, from: nil)
            if let corner = root.resizeCorner(at: point), let visible = screen?.visibleFrame {
                root.canvas.screen.releaseKeys()
                resizeSession = DeviceResizeSession(corner: corner, initialFrame: frame,
                    initialPointer: pointer,
                    deviceSize: root.canvas.geometry.size, initialScale: root.canvas.geometry.fit(in: root.canvas.bounds, maximumScale: root.canvas.maximumScale).scale,
                    visibleFrame: visible, minimumSize: minSize, toolbarMetrics: root.controls.metrics)
                makeKey()
                disableCursorRects()
                corner.cursor.push()
                return
            }
            // Retain .resizable for native full screen / Split View, but do not
            // forward normal-window edge gestures to AppKit's frame resizer.
            if point.x < 7 || point.y < 7 || point.x > root.bounds.maxX - 7 || point.y > root.bounds.maxY - 7 { return }
        }
        super.sendEvent(event)
    }
    func endCornerResize() {
        guard resizeSession != nil else { return }
        resizeSession = nil
        NSCursor.pop()
        enableCursorRects()
        if let contentView { invalidateCursorRects(for: contentView) }
    }
    override func close() { endCornerResize(); stopPointerMonitoring(); super.close() }
}
