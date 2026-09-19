import AppKit
import Combine

/// Follow AppKit's menu-bar/titlebar reveal; only the title layout is ours.
@MainActor final class FullScreenChrome: NSTitlebarAccessoryViewController {
    private let revealView: FullScreenRevealView
    init(window: NSWindow, controls: SimulatorControlBar, onReveal: @escaping (CGFloat) -> Void) {
        revealView = FullScreenRevealView(window: window, controls: controls, onReveal: onReveal)
        super.init(nibName: nil, bundle: nil)
        view = revealView
        layoutAttribute = .leading
        prepareLayout(controls.barLayout)
        controls.attach(to: window)
        window.addTitlebarAccessoryViewController(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func refresh() { revealView.refresh() }
    func prepareLayout(_ layout: SimulatorControlBarLayout) { revealView.prepareLayout(layout) }
    nonisolated static func presentationOptions(from proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposed.subtracting([.hideMenuBar, .autoHideToolbar]).union(.autoHideMenuBar)
    }
    nonisolated static func revealProgress(titlebar: CGRect, header: CGRect) -> CGFloat {
        guard titlebar.height > 0 else { return 0 }
        let shown = titlebar.intersection(header)
        return shown.isEmpty ? 0 : min(1, max(0, shown.height / titlebar.height))
    }
}

@MainActor private final class FullScreenRevealView: NSView {
    private let background = FullScreenTitlebarBackground(frame: .zero)
    private weak var hostWindow: NSWindow?
    private weak var controls: SimulatorControlBar?
    private let onReveal: (CGFloat) -> Void
    private var observations: Set<AnyCancellable> = []
    private var windowFrameObservation: NSKeyValueObservation?
    private var windowAlphaObservation: NSKeyValueObservation?
    private var buttonAlphaObservation: NSKeyValueObservation?
    private var hostAppearanceObservation: NSKeyValueObservation?
    init(window: NSWindow, controls: SimulatorControlBar, onReveal: @escaping (CGFloat) -> Void) {
        hostWindow = window
        self.controls = controls
        self.onReveal = onReveal
        super.init(frame: CGRect(x: 0, y: 0, width: controls.titleWidth + 20, height: SimulatorControlBar.height))
        controls.installNativeTitle(in: self)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    // This accessory only draws labels; it must not intercept AppKit's toolbar
    // buttons, window widgets or native window dragging beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); refresh() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeGeometry(); refresh() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeGeometry(); refresh() }
    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }
    private func observeGeometry() {
        observations.removeAll()
        windowFrameObservation = nil; windowAlphaObservation = nil; buttonAlphaObservation = nil; hostAppearanceObservation = nil
        guard window != nil else { return }
        // Use public geometry notifications, without private titlebar classes.
        var ancestor: NSView? = self
        while let view = ancestor {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                NotificationCenter.default.publisher(for: name, object: view)
                    .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
                    .store(in: &observations)
            }
            ancestor = view.superview
        }
        windowFrameObservation = window?.observe(\.frame) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        buttonAlphaObservation = hostWindow?.standardWindowButton(.closeButton)?.observe(\.alphaValue) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        hostAppearanceObservation = hostWindow?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        windowAlphaObservation = window?.observe(\.alphaValue) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func prepareLayout(_ layout: SimulatorControlBarLayout) {
        guard let controls else { return }
        // On macOS 26 an expanded toolbar fills leading accessories to both
        // rows. Collapse our title slot in compact mode so the accessory's
        // system clip view cannot cover the centered native action controls.
        let width = layout.isCompact ? 0 : controls.titleWidth + 20
        let size = CGSize(width: width, height: layout.isCompact ? 0 : SimulatorControlBar.height)
        if frame.size != size { setFrameSize(size) }
    }
    func refresh() {
        guard let hostWindow else { onReveal(0); return }
        guard let controls else { onReveal(0); return }
        guard let chromeWindow = window,
              chromeWindow !== hostWindow else { background.removeFromSuperview(); onReveal(0); return }
        // The system moves and tracks its own titlebar. A transparent window
        // avoids a second background over our persistent header.
        chromeWindow.titlebarAppearsTransparent = true
        chromeWindow.backgroundColor = .clear
        chromeWindow.isOpaque = false
        chromeWindow.hasShadow = false
        // AppKit's auxiliary fullscreen window does not always inherit an app
        // appearance override. Keep all native chrome in the host's appearance,
        // including subsequent system light/dark changes.
        if chromeWindow.appearance != hostWindow.effectiveAppearance {
            chromeWindow.appearance = hostWindow.effectiveAppearance
        }
        // Preserve our opaque header behind the genuine toolbar. AppKit paints
        // a dark fullscreen titlebar even in Aqua. Place the matching fill below
        // the toolbar's whole container, so its native glass and controls remain
        // untouched and above the fill. No private view classes are referenced.
        if let titlebar = hostWindow.standardWindowButton(.closeButton)?.superview {
            if background.superview !== titlebar,
               let toolbar = titlebar.subviews.first(where: { containsActions(in: $0, target: controls.actions) }) {
                titlebar.addSubview(background, positioned: .below, relativeTo: toolbar)
            }
            background.frame = titlebar.bounds
        }
        controls.layoutNativeTitle()
        guard hostWindow.styleMask.contains(.fullScreen), bounds.height > 0,
              !isHiddenOrHasHiddenAncestor else { onReveal(0); return }
        let visible = visibleRect.intersection(bounds)
        guard !visible.isEmpty else { onReveal(0); return }
        let placed = chromeWindow.convertToScreen(convert(visible, to: nil))
        let header = hostWindow.convertToScreen(controls.convert(CGRect(x: 0, y: controls.topInset,
            width: controls.bounds.width, height: max(0, controls.bounds.height - controls.topInset)), to: nil))
        onReveal(FullScreenChrome.revealProgress(titlebar: placed, header: header) * chromeWindow.alphaValue * (hostWindow.standardWindowButton(.closeButton)?.alphaValue ?? 0))
    }
    private func containsActions(in view: NSView, target: SimulatorToolbar) -> Bool {
        if let button = view as? NSButton, button.target === target { return true }
        return view.subviews.contains { containsActions(in: $0, target: target) }
    }
}

@MainActor private final class FullScreenTitlebarBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
