import AppKit

struct SimulatorControlBarLayout {
    static let expandedHeight: CGFloat = 52
    static let compactHeight: CGFloat = 76
    static let minimumWidth: CGFloat = 300
    static let controlSize = CGSize(width: 112, height: 36)
    let isCompact: Bool
    let height: CGFloat
    let cornerRadius: CGFloat
    let buttons: CGRect
    let name: CGRect
    let runtime: CGRect

    init(width: CGFloat, titleWidth: CGFloat, isFullScreen: Bool, topInset: CGFloat = 0, fullScreenRevealProgress: CGFloat = 0,
         isAttachedToScreen: Bool = false) {
        isCompact = !isFullScreen && width < 102 + titleWidth + 20 + Self.controlSize.width + 8
        height = isCompact ? Self.compactHeight : Self.expandedHeight
        cornerRadius = isFullScreen || isAttachedToScreen ? 0 : isCompact ? 16 : height / 2
        if isCompact {
            name = CGRect(x: 84, y: 7, width: max(0, width - 96), height: 20)
            runtime = .zero
            buttons = CGRect(x: (width - Self.controlSize.width) / 2, y: 32, width: Self.controlSize.width, height: Self.controlSize.height)
        } else {
            let left: CGFloat = isFullScreen ? 20 + 88 * min(1, max(0, fullScreenRevealProgress)) : 102
            buttons = CGRect(x: width - Self.controlSize.width - 8, y: topInset + 8, width: Self.controlSize.width, height: Self.controlSize.height)
            name = CGRect(x: left, y: topInset + 10, width: max(0, buttons.minX - left - 10), height: 16)
            runtime = CGRect(x: left, y: topInset + 26, width: name.width, height: 16)
        }
    }
}

@MainActor private final class ControlBarContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class SimulatorControlBar: NSView {
    static let height = SimulatorControlBarLayout.expandedHeight
    static let minimumWidth = SimulatorControlBarLayout.minimumWidth
    // Keep title measurement and rendering consistent, including compact titles.
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let runtimeFont = NSFont.systemFont(ofSize: 11)
    private let deviceName: String
    private let runtimeName: String
    let titleWidth: CGFloat
    private let name: NSTextField
    private let runtime: NSTextField
    private let nativeName: NSTextField
    private let nativeRuntime: NSTextField
    let actions: SimulatorToolbar
    var actionItems: [NSToolbarItem] { actions.items }
    private weak var hostWindow: NSWindow?
    private(set) var fullScreenRevealProgress: CGFloat = 0
#if DEBUG
    var presentedTitleFrame: CGRect { name.layer?.presentation()?.frame ?? name.frame }
#endif
    let contentView: NSView = ControlBarContentView()
    let surface: NSView
    var windowButtons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { hostWindow?.standardWindowButton($0) }
    }
    var barLayout: SimulatorControlBarLayout {
        SimulatorControlBarLayout(width: bounds.width, titleWidth: titleWidth, isFullScreen: isFullScreen, topInset: topInset,
            fullScreenRevealProgress: fullScreenRevealProgress, isAttachedToScreen: isAttachedToScreen)
    }
    func height(for width: CGFloat) -> CGFloat {
        SimulatorControlBarLayout(width: width, titleWidth: titleWidth, isFullScreen: false).height
    }
    var topInset: CGFloat = 0 { didSet { needsLayout = true } }
    var isAttachedToScreen = false {
        didSet {
            guard oldValue != isAttachedToScreen else { return }
            updateStyle(); needsLayout = true
        }
    }
    var isFullScreen = false {
        didSet {
            fullScreenRevealProgress = 0
            updateStyle(); needsLayout = true
        }
    }
    override var isFlipped: Bool { true }
    init(device: SimulatorDevice, action: @escaping (DeviceCommand) -> Void) {
        deviceName = device.name
        runtimeName = device.runtimeName
        titleWidth = max((device.name as NSString).size(withAttributes: [.font: Self.titleFont]).width,
            (device.runtimeName as NSString).size(withAttributes: [.font: Self.runtimeFont]).width) + 6
        name = NSTextField(labelWithString: device.name)
        runtime = NSTextField(labelWithString: device.runtimeName)
        nativeName = NSTextField(labelWithString: device.name)
        nativeRuntime = NSTextField(labelWithString: device.runtimeName)
        actions = SimulatorToolbar(action: action)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            surface = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .titlebar
            material.blendingMode = .withinWindow
            material.state = .followsWindowActiveState
            material.wantsLayer = true
            material.layer?.masksToBounds = true
            material.layer?.cornerCurve = .continuous
            surface = material
        }
        super.init(frame: .zero)
        wantsLayer = true
        contentView.wantsLayer = true
        addSubview(surface)
        updateStyle()
        for label in [name, nativeName] {
            label.font = Self.titleFont
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for label in [runtime, nativeRuntime] {
            label.font = Self.runtimeFont
            label.textColor = .secondaryLabelColor
        }
        contentView.addSubview(name); contentView.addSubview(runtime)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func updateStyle() {
        // Glass tint does not make its backdrop opaque. The outer base covers
        // the rounded edge; the content fill stops the native backdrop from
        // transmitting desktop colors in either window activation state.
        layer?.cornerRadius = barLayout.cornerRadius
        surface.isHidden = isFullScreen
        if #available(macOS 26, *), let glass = surface as? NSGlassEffectView {
            if isFullScreen {
                glass.contentView = nil
                if contentView.superview !== self { addSubview(contentView) }
            } else if glass.contentView !== contentView {
                contentView.removeFromSuperview()
                glass.contentView = contentView
            }
        } else {
            let parent = isFullScreen ? self : surface
            if contentView.superview !== parent { parent.addSubview(contentView) }
        }
        updateColors()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = NSColor.windowBackgroundColor
            layer?.backgroundColor = background.cgColor
            contentView.layer?.backgroundColor = isFullScreen ? nil : background.cgColor
            if #available(macOS 26, *), let glass = surface as? NSGlassEffectView {
                glass.tintColor = background
            }
        }
    }
    func attachWindowButtons(_ window: NSWindow) {
        // The window owns their parent, frames, targets and grouped hover. Never
        // extract individual theme widgets or manufacture replacement controls.
        hostWindow = window
    }
    func installNativeTitle(in container: NSView) {
        container.addSubview(nativeName); container.addSubview(nativeRuntime)
    }
    func layoutNativeTitle() {
        guard let container = nativeName.superview, let nativeWindow = container.window, let hostWindow else { return }
        // AppKit owns a persistent fullscreen toolbar. Its accessory provides
        // the title above the toolbar material, using our header coordinates.
        nativeName.isHidden = !isFullScreen || nativeWindow === hostWindow
        nativeRuntime.isHidden = nativeName.isHidden
        nativeName.frame = nativeTitleFrame(barLayout.name)
        nativeRuntime.frame = nativeTitleFrame(barLayout.runtime)
    }
    private func nativeTitleFrame(_ rect: CGRect) -> CGRect {
        guard let parent = nativeName.superview,
              let nativeWindow = parent.window, let hostWindow else { return rect }
        return parent.convert(nativeWindow.convertFromScreen(hostWindow.convertToScreen(convert(rect, to: nil))), from: nil)
    }
    func setFullScreenRevealProgress(_ progress: CGFloat) {
        let progress = isFullScreen ? min(1, max(0, progress)) : 0
        guard fullScreenRevealProgress != progress else { return }
        let old = fullScreenRevealProgress
        fullScreenRevealProgress = progress
        if abs(progress - old) == 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Geometry can jump to the endpoint when AppKit animates its window
            // in WindowServer. Animate only our title, never native controls.
            let layout = barLayout
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                name.animator().frame = layout.name
                runtime.animator().frame = layout.runtime
                nativeName.animator().frame = nativeTitleFrame(layout.name)
                nativeRuntime.animator().frame = nativeTitleFrame(layout.runtime)
            }
        } else {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }
    func update(isRecording: Bool, isStoppingRecording: Bool = false) {
        actions.update(isRecording: isRecording, isStoppingRecording: isStoppingRecording)
    }
    override func layout() {
        super.layout()
        let layout = barLayout
        if let hostWindow { actions.layout(in: hostWindow, compact: layout.isCompact) }
        layer?.cornerRadius = layout.cornerRadius
        contentView.layer?.cornerRadius = layout.cornerRadius
        surface.frame = bounds
        contentView.frame = bounds
        if #available(macOS 26, *), let glass = surface as? NSGlassEffectView {
            glass.cornerRadius = layout.cornerRadius
        } else {
            surface.layer?.cornerRadius = layout.cornerRadius
        }
        name.stringValue = layout.isCompact ? "\(deviceName) – \(runtimeName)" : deviceName
        name.textColor = layout.isCompact ? .secondaryLabelColor : .labelColor
        name.frame = layout.name
        runtime.isHidden = layout.isCompact
        runtime.frame = layout.runtime
        layoutNativeTitle()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else if window?.styleMask.contains(.fullScreen) != true { window?.performDrag(with: event) }
    }
}

struct NormalPresentationLayout {
    static let deviceSideMargin: CGFloat = 12
    static let deviceTopMargin: CGFloat = 12
    static let deviceBottomMargin: CGFloat = 24
    let header: CGRect
    let canvas: CGRect

    init(bounds: CGRect, headerHeight: CGFloat, device: ChromeGeometry, maximumScale: CGFloat?, showsBezels: Bool = true) {
        header = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(headerHeight, bounds.height))
        if !showsBezels {
            canvas = CGRect(x: bounds.minX, y: header.maxY, width: bounds.width, height: max(0, bounds.maxY - header.maxY))
            return
        }
        let width = max(0, bounds.width - Self.deviceSideMargin * 2)
        // Align our glass with the native titlebar instead of relocating its
        // widgets. The device canvas retains its inset and aspect ratio.
        let available = CGRect(x: bounds.minX + Self.deviceSideMargin, y: header.maxY + Self.deviceTopMargin, width: width,
            height: max(0, bounds.height - headerHeight - Self.deviceTopMargin - Self.deviceBottomMargin))
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
    let wallpaper = DesktopWallpaperView(frame: .zero)
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
            wallpaper.isHidden = !isFullScreen
            if !isFullScreen { wallpaper.reset() }
            backdrop.isHidden = !isFullScreen
            needsLayout = true; needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    init(screen: SimulatorScreenView, chrome: DeviceChrome, device: SimulatorDevice, action: @escaping (DeviceCommand) -> Void) {
        canvas = DeviceCanvasView(screen: screen, chrome: chrome)
        controls = SimulatorControlBar(device: device, action: action)
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.isHidden = true
        wallpaper.isHidden = true
        needsLayout = true
        addSubview(wallpaper); addSubview(backdrop); addSubview(canvas); addSubview(controls)
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
        controls.isAttachedToScreen = usesAttachedChrome
        canvas.alignsScreenToTop = usesAttachedChrome
        layer?.backgroundColor = usesAttachedChrome ? NSColor.black.cgColor : nil
        (window as? DeviceHostWindow)?.updatePresentationBackground()
        backdrop.frame = bounds
        wallpaper.frame = bounds
        if isFullScreen {
            wallpaper.refresh()
            let layout = FullScreenPresentationLayout(bounds: bounds, safeAreaInsets: fullScreenSafeAreaInsets)
            controls.topInset = max(0, fullScreenSafeAreaInsets.top)
            controls.frame = layout.header
            canvas.frame = layout.canvas
        } else {
            controls.topInset = 0
            let width = bounds.width
            let layout = NormalPresentationLayout(bounds: bounds, headerHeight: controls.height(for: width),
                device: canvas.geometry, maximumScale: canvas.maximumScale, showsBezels: canvas.showsBezels)
            controls.frame = layout.header
            canvas.frame = layout.canvas
        }
        controls.needsLayout = true
        canvas.needsLayout = true
        window?.invalidateCursorRects(for: self)
        window?.invalidateShadow()
    }
    var deviceRect: CGRect {
        let fit = canvas.fittedGeometry
        return convert(ChromeGeometry.placed(canvas.geometry.rotated(canvas.geometry.body), in: fit.rect, scale: fit.scale), from: canvas)
    }
    var deviceCornerRadius: CGFloat {
        (canvas.showsBezels ? canvas.chrome.outerRadius : canvas.chrome.cornerRadius)
            * canvas.geometry.fit(in: canvas.bounds, maximumScale: canvas.maximumScale).scale
    }
    func resizeCorner(at point: CGPoint) -> DeviceResizeCorner? {
        guard !isFullScreen, canvas.showsBezels, !controls.frame.contains(point) else { return nil }
        return DeviceResizeCorner.allCases.first { $0.hitRect(in: deviceRect, radius: deviceCornerRadius).contains(point) }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isFullScreen, canvas.showsBezels else { return }
        addCursorRect(bounds, cursor: .arrow)
        for corner in DeviceResizeCorner.allCases {
            addCursorRect(corner.hitRect(in: deviceRect, radius: deviceCornerRadius).intersection(bounds), cursor: corner.cursor)
        }
    }
    func normalSize(scale: CGFloat) -> CGSize {
        let size = canvas.geometry.size
        let horizontalMargin = NormalPresentationLayout.deviceSideMargin * 2
        let verticalMargin = NormalPresentationLayout.deviceTopMargin + NormalPresentationLayout.deviceBottomMargin
        let width = max(SimulatorControlBar.minimumWidth + horizontalMargin, size.width * scale + (canvas.showsBezels ? horizontalMargin : 0))
        return CGSize(width: width, height: size.height * scale + controls.height(for: width) + (canvas.showsBezels ? verticalMargin : 0))
    }
    func normalScaleToFit(in size: CGSize) -> CGFloat {
        let layout = NormalPresentationLayout(bounds: CGRect(origin: .zero, size: size), headerHeight: controls.height(for: size.width),
            device: canvas.geometry, maximumScale: nil, showsBezels: canvas.showsBezels)
        return canvas.geometry.fit(in: layout.canvas).scale
    }
    func refreshGeometry() { needsLayout = true; canvas.needsLayout = true; canvas.needsDisplay = true }
}
