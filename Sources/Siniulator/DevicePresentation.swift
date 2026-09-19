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
    let canvas: DeviceCanvasView
    let controls: SimulatorControlBar
    let backdrop: NSVisualEffectView = SimulatorBackdropView()
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
        canvas.onDuoProjectionWidthChange = { [weak self] _ in
            self?.needsLayout = true
        }
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
        controls.isAttachedToScreen = usesAttachedChrome
        canvas.alignsScreenToTop = usesAttachedChrome
        layer?.backgroundColor = usesAttachedChrome ? NSColor.black.cgColor : nil
        (window as? DeviceHostWindow)?.updatePresentationBackground()
        backdrop.frame = bounds
        if isFullScreen {
            let layout = FullScreenPresentationLayout(bounds: bounds, safeAreaInsets: fullScreenSafeAreaInsets)
            controls.topInset = max(0, fullScreenSafeAreaInsets.top)
            controls.frame = layout.header
            canvas.frame = layout.canvas
        } else {
            controls.topInset = 0
            let controlWidth = foldableControlWidth
            let layout = NormalPresentationLayout(bounds: bounds, headerHeight: controls.height(for: controlWidth),
                device: canvas.geometry, maximumScale: canvas.maximumScale, showsBezels: canvas.showsBezels,
                topMargin: normalTopMargin)
            controls.frame = CGRect(x: bounds.midX - controlWidth / 2, y: layout.header.minY,
                width: controlWidth, height: layout.header.height)
            canvas.frame = layout.canvas
        }
        controls.needsLayout = true
        canvas.needsLayout = true
        window?.invalidateCursorRects(for: self)
        window?.invalidateShadow()
        (window as? DeviceHostWindow)?.updateMousePassthrough()
    }
    var deviceRect: CGRect {
        let fit = canvas.fittedGeometry
        return convert(ChromeGeometry.placed(canvas.geometry.rotated(canvas.geometry.body), in: fit.rect, scale: fit.scale), from: canvas)
    }
    var visualDeviceRect: CGRect {
        if let corners = canvas.duoResizeCornerPoints, !corners.isEmpty {
            let points = corners.values.map { convert($0, from: canvas) }
            return CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                width: points.map(\.x).max()! - points.map(\.x).min()!,
                height: points.map(\.y).max()! - points.map(\.y).min()!)
        }
        let rect = deviceRect
        return rect
    }
    var deviceCornerRadius: CGFloat {
        (canvas.showsBezels ? canvas.chrome.outerRadius : canvas.chrome.cornerRadius)
            * canvas.geometry.fit(in: canvas.bounds, maximumScale: canvas.maximumScale).scale
    }
    func resizeCorner(at point: CGPoint) -> DeviceResizeCorner? {
        guard !isFullScreen, canvas.showsBezels, !controls.frame.contains(point) else { return nil }
        return DeviceResizeCorner.allCases.first { resizeTarget(for: $0).contains(point) }
    }
    var hasTransparentDuoMargins: Bool { !isFullScreen && canvas.usesDuoModel }

    func acceptsMouse(at point: CGPoint) -> Bool {
        guard hasTransparentDuoMargins else { return true }
        // Resize handles deliberately extend a few points outside the mesh.
        // They must stay interactive even where the rendered pixel is clear.
        if resizeCorner(at: point) != nil { return true }
        let bar = controls.frame
        if NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).contains(point) { return true }
        return canvas.containsDuoHardware(at: canvas.convert(point, from: self))
    }
    func resizeTarget(for corner: DeviceResizeCorner) -> CGRect {
        if let points = canvas.duoResizeCornerPoints {
            guard let point = points[corner] else { return .zero }
            let center = convert(point, from: canvas)
            return CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
        }
        return corner.hitRect(in: deviceRect, radius: deviceCornerRadius)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isFullScreen, canvas.showsBezels else { return }
        addCursorRect(bounds, cursor: .arrow)
        for corner in DeviceResizeCorner.allCases {
            addCursorRect(resizeTarget(for: corner).intersection(bounds), cursor: corner.cursor)
        }
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

    private var normalTopMargin: CGFloat {
        canvas.chrome.displayMode == nil ? NormalPresentationLayout.deviceTopMargin : 0
    }
    private var foldableControlWidth: CGFloat {
        guard canvas.showsBezels, canvas.chrome.displayMode != nil else { return bounds.width }
        let expanded = max(0, bounds.width - NormalPresentationLayout.deviceSideMargin * 2)
        return controls.metrics.pillWidth(availableWidth: bounds.width, deviceWidth: expanded,
            projectedFraction: canvas.duoProjectionWidthFraction, closedFraction: canvas.duoClosedProjectionWidthFraction)
    }
}
