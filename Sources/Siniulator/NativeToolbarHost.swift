import AppKit
import Combine

/// The only boundary allowed to adapt AppKit's titlebar to an inset pill.
/// Never reparents or replaces window buttons, or creates custom action buttons.
@MainActor final class NativeToolbarHost {
    private weak var bar: SimulatorControlBar?
    private(set) weak var window: NSWindow?
    private let actions: SimulatorToolbar
    private let trailingInset = NSTitlebarAccessoryViewController()
    private var observations: Set<AnyCancellable> = []
    private var nativeButtonOffsets: [CGFloat] = []
    private var reconciling = false
    private var scheduled = false
    private weak var trackingView: NSView?
    private var originalTracking: NSTrackingArea?
    private var translatedTracking: NSTrackingArea?

    init(bar: SimulatorControlBar, actions: SimulatorToolbar) {
        self.bar = bar
        self.actions = actions
        trailingInset.layoutAttribute = .right
        trailingInset.view = NSView(frame: CGRect(x: 0, y: 0, width: 0, height: 1))
    }
    var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar = actions.toolbar
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        nativeButtonOffsets = buttons.map { $0.convert($0.bounds, to: nil).minX }
        observe(NSWindow.willCloseNotification, object: window) { $0.detach() }
        guard bar?.metrics.hasModes == true else { return }
        window.addTitlebarAccessoryViewController(trailingInset)
        for button in buttons {
            button.postsFrameChangedNotifications = true
            observe(NSView.frameDidChangeNotification, object: button) { $0.scheduleReconcile() }
        }
        // Native tracking can be rebuilt independently of the button frames.
        observe(NSWindow.didUpdateNotification, object: window) { $0.scheduleReconcile() }
    }

    private func observe(_ name: Notification.Name, object: AnyObject,
                         action: @escaping @MainActor (NativeToolbarHost) -> Void) {
        NotificationCenter.default.publisher(for: name, object: object).sink { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }.store(in: &observations)
    }
    func detach() {
        observations.removeAll()
        restoreModesToContent()
        restoreButtonPositions()
        restoreTracking()
        if let window, let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === trailingInset }) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        window = nil
        nativeButtonOffsets = []
    }

    func apply(_ layout: SimulatorControlBarLayout) {
        guard let window, let bar else { return }
        if bar.isFullScreen { actions.setFullscreenModes(bar.displayModeControl) }
        else { restoreModesToContent() }
        func prepareTitleSlot() {
            for accessory in window.titlebarAccessoryViewControllers {
                (accessory as? FullScreenChrome)?.prepareLayout(layout)
            }
        }
        // Collapse before entering two rows, expand only after leaving them.
        // Otherwise AppKit briefly solves a tall leading accessory against the
        // expanded toolbar's row constraints and breaks its own constraints.
        if layout.isCompact { prepareTitleSlot() }
        if bar.metrics.hasModes {
            let frame = bar.convert(bar.bounds, to: window.contentView)
            let inset = max(0, (window.contentView?.bounds.maxX ?? frame.maxX) - frame.maxX)
            if abs(trailingInset.view.frame.width - inset) > 0.5 {
                trailingInset.view.setFrameSize(CGSize(width: inset, height: 1))
            }
        }
        let style: NSWindow.ToolbarStyle = layout.isCompact ? .expanded : .unified
        if window.toolbarStyle != style {
            // AppKit retains row-specific accessory constraints across a style
            // change. Reinstall only our accessories around that transition,
            // letting the new native titlebar build its own constraints.
            let managed = window.titlebarAccessoryViewControllers.enumerated().filter {
                $0.element === trailingInset || $0.element is FullScreenChrome
            }
            for entry in managed.reversed() { window.removeTitlebarAccessoryViewController(at: entry.offset) }
            window.toolbarStyle = style
            for entry in managed { window.insertTitlebarAccessoryViewController(entry.element, at: entry.offset) }
        }
        if !layout.isCompact { prepareTitleSlot() }
        let centered: Set<NSToolbarItem.Identifier>
        if bar.isFullScreen && bar.metrics.hasModes { centered = [SimulatorToolbar.modeIdentifier] }
        else { centered = layout.isCompact && !bar.metrics.hasModes ? Set(actions.items.map(\.itemIdentifier)) : [] }
        if actions.toolbar.centeredItemIdentifiers != centered { actions.toolbar.centeredItemIdentifiers = centered }
        reconcile()
    }
    private func restoreModesToContent() {
        actions.setFullscreenModes(nil)
    }
    private func scheduleReconcile() {
        guard !reconciling, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.reconcile()
        }
    }
    private func reconcile() {
        guard !reconciling, let window, let bar else { return }
        reconciling = true
        defer { reconciling = false }
        guard bar.metrics.hasModes, !bar.isFullScreen, !window.styleMask.contains(.fullScreen) else {
            restoreButtonPositions()
            restoreTracking()
            return
        }
        let buttons = buttons
        guard buttons.count == nativeButtonOffsets.count, buttons.allSatisfy({ $0.window === window }) else { return }
        for (button, nativeX) in zip(buttons, nativeButtonOffsets) {
            guard let parent = button.superview else { continue }
            let x = parent.convert(bar.convert(CGPoint(x: nativeX, y: 0), to: nil), from: nil).x
            if abs(button.frame.minX - x) > 0.5 {
                button.setFrameOrigin(CGPoint(x: x, y: button.frame.minY))
            }
        }
        reconcileTracking(buttons)
    }
    private func restoreButtonPositions() {
        guard bar?.metrics.hasModes == true, let window else { return }
        for (button, nativeX) in zip(buttons, nativeButtonOffsets) {
            guard button.window === window, let parent = button.superview else { continue }
            let x = parent.convert(CGPoint(x: nativeX, y: 0), from: nil).x
            if abs(button.frame.minX - x) > 0.5 {
                button.setFrameOrigin(CGPoint(x: x, y: button.frame.minY))
            }
        }
    }

    /// A native frame's group-hover region is cached separately from its button
    /// frames. Translate that region with the widgets, preserving AppKit's owner,
    /// options and userInfo. Restore the original on detach/fullscreen. No custom
    /// hover drawing, synthetic events or private selectors are involved.
    private func reconcileTracking(_ buttons: [NSButton]) {
        guard let frame = window?.contentView?.superview, !buttons.isEmpty else { return }
        let span = buttons.map { frame.convert($0.bounds, from: $0) }.reduce(CGRect.null) { $0.union($1) }
        if trackingView !== frame { restoreTracking(); trackingView = frame }
        frame.updateTrackingAreas()
        let systemArea = frame.trackingAreas.first {
            $0 !== translatedTracking && $0.options.contains(.mouseEnteredAndExited)
                && $0.rect.size == span.size && $0.owner as AnyObject? === frame
        }
        if let systemArea {
            if let translatedTracking, frame.trackingAreas.contains(where: { $0 === translatedTracking }) {
                frame.removeTrackingArea(translatedTracking)
            }
            translatedTracking = nil
            originalTracking = systemArea
        }
        guard let originalTracking else { return }
        if span == originalTracking.rect { restoreTracking(); return }
        if let translatedTracking, translatedTracking.rect == span,
           frame.trackingAreas.contains(where: { $0 === translatedTracking }) { return }
        if frame.trackingAreas.contains(where: { $0 === originalTracking }) { frame.removeTrackingArea(originalTracking) }
        if let translatedTracking, frame.trackingAreas.contains(where: { $0 === translatedTracking }) {
            frame.removeTrackingArea(translatedTracking)
        }
        let replacement = NSTrackingArea(rect: span, options: originalTracking.options,
            owner: originalTracking.owner, userInfo: originalTracking.userInfo)
        frame.addTrackingArea(replacement)
        translatedTracking = replacement
    }
    private func restoreTracking() {
        if let frame = trackingView {
            if let translatedTracking, frame.trackingAreas.contains(where: { $0 === translatedTracking }) {
                frame.removeTrackingArea(translatedTracking)
            }
            if let originalTracking, !frame.trackingAreas.contains(where: { $0 === originalTracking }) {
                frame.addTrackingArea(originalTracking)
            }
        }
        trackingView = nil
        translatedTracking = nil
        originalTracking = nil
    }
}
