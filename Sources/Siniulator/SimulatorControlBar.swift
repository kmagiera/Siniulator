import AppKit

@MainActor private final class ControlBarContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class SimulatorControlBar: NSView {
    static let height = SimulatorControlBarLayout.expandedHeight
    static let minimumWidth = SimulatorControlBarLayout.minimumWidth
    // Match Simulator's native 13-point bold title and 11-point regular subtitle.
    // Use the same fonts for measurement and rendering, including compact titles.
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let runtimeFont = NSFont.systemFont(ofSize: 11)
    private let deviceName: String
    private let runtimeName: String
    let titleWidth: CGFloat
    private let name: NSTextField
    private let runtime: NSTextField
    private let nativeName: NSTextField
    private let nativeRuntime: NSTextField
    private let commandAction: (DeviceCommand) -> Void
    private let displayModes: [DeviceDisplayMode]
    private(set) var displayModeControl: NSSegmentedControl?
    let actions: SimulatorToolbar
    var actionItems: [NSToolbarItem] { actions.items }
    private lazy var nativeHost = NativeToolbarHost(bar: self, actions: actions)
    private var hostWindow: NSWindow? { nativeHost.window }
    private(set) var fullScreenRevealProgress: CGFloat = 0
#if DEBUG
    var presentedTitleFrame: CGRect { name.layer?.presentation()?.frame ?? name.frame }
#endif
    let contentView: NSView = ControlBarContentView()
    let surface: NSView
    var windowButtons: [NSButton] { nativeHost.buttons }
    var metrics: SimulatorToolbarMetrics {
        SimulatorToolbarMetrics(titleWidth: titleWidth, modeSize: displayModeControl?.intrinsicContentSize ?? .zero)
    }
    var barLayout: SimulatorControlBarLayout {
        metrics.layout(width: bounds.width, isFullScreen: isFullScreen, topInset: topInset,
            revealProgress: fullScreenRevealProgress, attached: isAttachedToScreen)
    }
    func height(for width: CGFloat) -> CGFloat { metrics.layout(width: width).height }
    var minimumCompactWidth: CGFloat { metrics.minimumCompactWidth }
    var minimumExpandedWidth: CGFloat { metrics.minimumExpandedWidth }
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
        commandAction = action
        displayModes = DeviceChrome.displayModes(for: device)
        titleWidth = max((device.name as NSString).size(withAttributes: [.font: Self.titleFont]).width,
            (device.runtimeName as NSString).size(withAttributes: [.font: Self.runtimeFont]).width) + 6
        name = NSTextField(labelWithString: device.name)
        runtime = NSTextField(labelWithString: device.runtimeName)
        nativeName = NSTextField(labelWithString: device.name)
        nativeRuntime = NSTextField(labelWithString: device.runtimeName)
        actions = SimulatorToolbar(displayModes: displayModes, action: action)
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
        if !displayModes.isEmpty {
            let control = NSSegmentedControl(labels: Array(repeating: "", count: displayModes.count),
                trackingMode: .selectOne, target: self, action: #selector(changeDisplayMode))
            control.segmentStyle = .rounded
            control.controlSize = .large
            for (index, mode) in displayModes.enumerated() {
                control.setImage(mode.image(), forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
                control.setToolTip(mode.tooltip, forSegment: index)
                control.setWidth(40, forSegment: index)
            }
            control.selectedSegment = displayModes.count - 1
            control.setFrameSize(control.intrinsicContentSize)
            displayModeControl = control
            contentView.addSubview(control)
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { nativeHost.detach() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateStyle() {
        // Glass tint does not make its backdrop opaque. The outer base covers
        // the rounded edge; the content fill stops the native backdrop from
        // transmitting desktop colors in either window activation state.
        layer?.cornerRadius = barLayout.cornerRadius
        surface.isHidden = isFullScreen
        displayModeControl?.isHidden = isFullScreen
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
    func attach(to window: NSWindow) { nativeHost.attach(to: window) }
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
    func update(hingeAngle: Double) {
        guard let index = displayModes.firstIndex(of: .selectedMode(forHingeAngle: hingeAngle)) else { return }
        displayModeControl?.selectedSegment = index
        actions.fullscreenModeControl?.selectedSegment = index
    }
    @objc private func changeDisplayMode(_ sender: NSSegmentedControl) {
        guard displayModes.indices.contains(sender.selectedSegment) else { return }
        switch displayModes[sender.selectedSegment] {
        case .cover: commandAction(.coverScreen)
        case .innerPartiallyOpen: commandAction(.innerPartiallyOpen)
        case .innerFullyOpen: commandAction(.innerFullyOpen)
        }
    }
    override func layout() {
        super.layout()
        let layout = barLayout
        nativeHost.apply(layout)
        layer?.cornerRadius = layout.cornerRadius
        contentView.layer?.cornerRadius = layout.cornerRadius
        surface.frame = bounds
        contentView.frame = bounds
        if let control = displayModeControl, let modeFrame = layout.modes {
            control.frame = modeFrame
        }
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
