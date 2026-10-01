import AppKit

struct NormalPresentationLayout {
    static let deviceSideMargin: CGFloat = 12
    static let deviceTopMargin: CGFloat = 12
    static let deviceBottomMargin: CGFloat = 24
    let header: CGRect
    let canvas: CGRect

    init(bounds: CGRect, headerHeight: CGFloat, device: ChromeGeometry, maximumScale: CGFloat?,
         showsBezels: Bool = true, topMargin: CGFloat = Self.deviceTopMargin) {
        header = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(headerHeight, bounds.height))
        if !showsBezels {
            canvas = CGRect(x: bounds.minX, y: header.maxY, width: bounds.width, height: max(0, bounds.maxY - header.maxY))
            return
        }
        let width = max(0, bounds.width - Self.deviceSideMargin * 2)
        // Align our glass with the native titlebar instead of relocating its
        // widgets. The device canvas retains its inset and aspect ratio.
        let available = CGRect(x: bounds.minX + Self.deviceSideMargin, y: header.maxY + topMargin, width: width,
            height: max(0, bounds.height - headerHeight - topMargin - Self.deviceBottomMargin))
        // Normal windows keep the bezel just below their detached toolbar.
        // A restored frame can be taller than the device's aspect ratio needs.
        let fitted = device.fit(in: available, maximumScale: maximumScale)
        canvas = CGRect(origin: available.origin, size: CGSize(width: width, height: fitted.rect.height))
    }
}

struct FullScreenPresentationLayout {
    static let headerHeight: CGFloat = 52
    static let deviceMargin: CGFloat = 36
    let header: CGRect
    let canvas: CGRect
    init(bounds: CGRect, safeAreaInsets: NSEdgeInsets) {
        header = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
            height: min(bounds.height, Self.headerHeight + max(0, safeAreaInsets.top)))
        let left = Self.deviceMargin + max(0, safeAreaInsets.left)
        let right = Self.deviceMargin + max(0, safeAreaInsets.right)
        canvas = CGRect(x: bounds.minX + left, y: header.maxY + Self.deviceMargin,
            width: max(0, bounds.width - left - right),
            height: max(0, bounds.height - header.height - Self.deviceMargin * 2 - max(0, safeAreaInsets.bottom)))
    }
}

@MainActor private final class SimulatorBackdropView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class DevicePresentationView: NSView {
    enum PointerRegion: Equatable {
        case passthrough, content, resize(DeviceResizeCorner)

        var resizeCorner: DeviceResizeCorner? {
            if case let .resize(corner) = self { return corner }
            return nil
        }
    }
    let canvas: DeviceCanvasView
    let controls: SimulatorControlBar
    let backdrop: NSVisualEffectView = SimulatorBackdropView()
    // The square projection is independent of this view/window's bounds.
    // Only a user's resize changes its scale; posing crops the window and
    // translates the camera projection in the skeleton's own transaction.
    var duoViewportSide: CGFloat = DuoStage.viewport {
        didSet { if oldValue != duoViewportSide { needsLayout = true } }
    }
    var isDuoAnimating = false
    private var pointerTrackingArea: NSTrackingArea?
    var usesAttachedChrome: Bool { !isFullScreen && !canvas.showsBezels }
    private var fullScreenMenuInset: CGFloat = 0
    var isFullScreen = false {
        didSet {
            guard oldValue != isFullScreen else { return }
            if let screen = window?.screen, isFullScreen {
                // Keep the device stationary while AppKit reveals menu chrome;
                // visibleFrame can change slightly during that transition.
                fullScreenMenuInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            } else { fullScreenMenuInset = 0 }
            controls.isFullScreen = isFullScreen
            backdrop.isHidden = !isFullScreen
            needsLayout = true; needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    init(screen: SimulatorScreenView, chrome: DeviceChrome, device: SimulatorDevice, action: @escaping (DeviceCommand) -> Void) {
        canvas = DeviceCanvasView(screen: screen, chrome: chrome,
            modelChrome: DeviceChrome.load(for: device, displayMode: .innerFullyOpen))
        controls = SimulatorControlBar(device: device, action: action)
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.material = .underWindowBackground
        // Let WindowServer composite the desktop/full-screen Space. Reading the
        // configured wallpaper URL would require file access when the user chose
        // an image outside the system wallpaper directories.
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.isHidden = true
        needsLayout = true
        addSubview(backdrop); addSubview(canvas); addSubview(controls)
        canvas.onButton = action
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
    var fullScreenSafeAreaInsets: NSEdgeInsets {
        guard let screen = window?.screen else { return safeAreaInsets }
        // Full-size content extends behind the menu bar. Reserve its strip so the
        // persistent header and revealed buttons remain below it. Do not count the
        // native, hidden titlebar itself.
        let display = screen.safeAreaInsets
        let windowTopInset = window?.styleMask.contains(.fullScreen) == true
            ? max(0, screen.frame.maxY - (window?.frame.maxY ?? screen.frame.maxY)) : 0
        let menuInset = window?.styleMask.contains(.fullScreen) == true ? max(0, fullScreenMenuInset - windowTopInset) : 0
        // On notched displays AppKit may already place the entire window below
        // the menu/notch strip. Reserve only the portion inside our content.
        let physicalInset = max(0, display.top - windowTopInset)
        return NSEdgeInsets(top: max(menuInset, min(safeAreaInsets.top, physicalInset)), left: min(safeAreaInsets.left, display.left),
            bottom: min(safeAreaInsets.bottom, display.bottom), right: min(safeAreaInsets.right, display.right))
    }
    override func layout() {
        super.layout()
        let previousControlsFrame = controls.frame
        controls.isAttachedToScreen = usesAttachedChrome
        canvas.alignsScreenToTop = usesAttachedChrome
        canvas.anchorsDuoToTop = !isFullScreen && canvas.usesDuoModel
        layer?.backgroundColor = usesAttachedChrome ? NSColor.black.cgColor : nil
        (window as? DeviceHostWindow)?.updatePresentationBackground()
        backdrop.frame = bounds
        if isFullScreen {
            let layout = FullScreenPresentationLayout(bounds: bounds, safeAreaInsets: fullScreenSafeAreaInsets)
            controls.topInset = max(0, fullScreenSafeAreaInsets.top)
            controls.frame = layout.header
            if canvas.usesDuoModel {
                let side = min(layout.canvas.width, layout.canvas.height)
                canvas.frame = CGRect(x: layout.canvas.midX - side / 2, y: layout.canvas.midY - side / 2,
                    width: side, height: side)
            } else {
                canvas.frame = layout.canvas
            }
        } else if canvas.usesDuoModel {
            controls.topInset = 0
            let width = min(duoToolbarWidth, bounds.width - 2 * DuoStage.outerMargin)
            let height = controls.height(for: width)
            // Native titlebar items are anchored at the window top.
            controls.frame = CGRect(x: bounds.midX - width / 2, y: 0, width: width, height: height)
            let size = CGSize(width: duoViewportSide, height: duoViewportSide)
            if canvas.bounds.size != size {
                canvas.setFrameSize(size)
                canvas.needsLayout = true
                canvas.layoutSubtreeIfNeeded()
            }
            canvas.setFrameOrigin(CGPoint(x: bounds.midX - duoViewportSide / 2,
                y: controls.frame.maxY + DuoStage.toolbarGap - DuoStage.projectionTopInset))
        } else {
            controls.topInset = 0
            let controlWidth = bounds.width
            let layout = NormalPresentationLayout(bounds: bounds, headerHeight: controls.height(for: controlWidth),
                device: canvas.geometry, maximumScale: canvas.maximumScale, showsBezels: canvas.showsBezels,
                topMargin: normalTopMargin)
            controls.frame = CGRect(x: bounds.midX - controlWidth / 2, y: layout.header.minY,
                width: controlWidth, height: layout.header.height)
            canvas.frame = layout.canvas
        }
        if controls.frame != previousControlsFrame { controls.needsLayout = true }
        window?.invalidateCursorRects(for: self)
        window?.invalidateShadow()
        (window as? DeviceHostWindow)?.updateMousePassthrough()
    }
    var deviceRect: CGRect {
        let fit = canvas.fittedGeometry
        return convert(ChromeGeometry.placed(canvas.geometry.rotated(canvas.geometry.body), in: fit.rect, scale: fit.scale), from: canvas)
    }
    var visualDeviceRect: CGRect {
        if let hardware = canvas.duoHardwareBounds { return convert(hardware, from: canvas) }
        return deviceRect
    }
    var deviceCornerRadius: CGFloat {
        (canvas.showsBezels ? canvas.chrome.outerRadius : canvas.chrome.cornerRadius)
            * canvas.geometry.fit(in: canvas.bounds, maximumScale: canvas.maximumScale).scale
    }
    func resizeCorner(at point: CGPoint) -> DeviceResizeCorner? {
        guard !isFullScreen, !isDuoAnimating, canvas.showsBezels, !controls.frame.contains(point) else { return nil }
        guard let corner = DeviceResizeCorner.allCases.first(where: { resizeTarget(for: $0).contains(point) }) else { return nil }
        if canvas.usesDuoModel, !canvas.containsDuoResizeFrame(at: canvas.convert(point, from: self)) { return nil }
        return corner
    }
    var hasTransparentDuoMargins: Bool { !isFullScreen && canvas.usesDuoModel }

    func acceptsMouse(at point: CGPoint) -> Bool {
        pointerRegion(at: point) != .passthrough
    }
    func pointerRegion(at point: CGPoint) -> PointerRegion {
        guard hasTransparentDuoMargins else { return .content }
        guard bounds.contains(point) else { return .passthrough }
        // Resize handles deliberately extend a few points outside the mesh.
        // They must stay interactive even where the rendered pixel is clear.
        if let corner = resizeCorner(at: point) { return .resize(corner) }
        let bar = controls.frame
        if NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).contains(point) { return .content }
        return canvas.containsDuoHardware(at: canvas.convert(point, from: self)) ? .content : .passthrough
    }
    func resizeTarget(for corner: DeviceResizeCorner) -> CGRect {
        if let points = canvas.duoResizeCornerPoints {
            guard let point = points[corner] else { return .zero }
            let center = convert(point, from: canvas)
            return CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
        }
        return corner.hitRect(in: deviceRect, radius: deviceCornerRadius)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isFullScreen, !isDuoAnimating, canvas.showsBezels else { return }
        // Rectangular cursor regions cannot express a thin curved frame minus
        // the touchscreen. Duo uses the exact same point predicate as clicks.
        guard !canvas.usesDuoModel else { return }
        addCursorRect(bounds, cursor: .arrow)
        for corner in DeviceResizeCorner.allCases {
            addCursorRect(resizeTarget(for: corner).intersection(bounds), cursor: corner.cursor)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        pointerTrackingArea = nil
        guard canvas.usesDuoModel, !isFullScreen else { return }
        let area = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
    override func cursorUpdate(with event: NSEvent) {
        guard hasTransparentDuoMargins, let window = window as? DeviceHostWindow else {
            super.cursorUpdate(with: event)
            return
        }
        window.updateMousePassthrough()
    }
    override func mouseMoved(with event: NSEvent) {
        if hasTransparentDuoMargins { (window as? DeviceHostWindow)?.updateMousePassthrough() }
        super.mouseMoved(with: event)
    }
    func normalSize(scale: CGFloat) -> CGSize {
        let size = canvas.geometry.size
        let horizontalMargin = NormalPresentationLayout.deviceSideMargin * 2
        let verticalMargin = normalTopMargin + NormalPresentationLayout.deviceBottomMargin
        let width = max(controls.minimumCompactWidth + horizontalMargin, size.width * scale + (canvas.showsBezels ? horizontalMargin : 0))
        return CGSize(width: width, height: size.height * scale + controls.height(for: width) + (canvas.showsBezels ? verticalMargin : 0))
    }
    func normalScaleToFit(in size: CGSize) -> CGFloat {
        let layout = NormalPresentationLayout(bounds: CGRect(origin: .zero, size: size), headerHeight: controls.height(for: size.width),
            device: canvas.geometry, maximumScale: nil, showsBezels: canvas.showsBezels, topMargin: normalTopMargin)
        return canvas.geometry.fit(in: layout.canvas).scale
    }
    func refreshGeometry() { needsLayout = true; canvas.needsLayout = true; canvas.needsDisplay = true }

    var duoWindowSize: CGSize {
        let device = canvas.duoHardwareBounds?.size ?? .zero
        return CGSize(width: max(duoToolbarWidth, device.width) + 2 * DuoStage.outerMargin,
            height: controls.height(for: duoToolbarWidth) + DuoStage.toolbarGap + device.height + DuoStage.outerMargin)
    }
    var duoToolbarSizing: DuoToolbarSizing {
        DuoToolbarSizing(widthFraction: canvas.duoToolbarWidthFraction, minimumWidth: controls.minimumExpandedWidth)
    }
    var duoToolbarWidth: CGFloat { duoToolbarSizing.width(for: duoViewportSide) }

    private var normalTopMargin: CGFloat {
        canvas.chrome.displayMode == nil ? NormalPresentationLayout.deviceTopMargin : 0
    }
}
