import AppKit
import XCTest
@testable import Siniulator

@MainActor private final class NativeChromeTestRoot: NSView {
    override var isFlipped: Bool { true }
}

final class NativeWindowChromeTests: XCTestCase {
    func testFullScreenKeepsNativeToolbarVisibleAndAutoHidesSystemMenuAndWindowControls() {
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideDock, .hideMenuBar, .autoHideToolbar]
        let actual = FullScreenChrome.presentationOptions(from: proposed)
        XCTAssertTrue(actual.contains(.autoHideMenuBar))
        XCTAssertFalse(actual.contains(.autoHideToolbar))
        XCTAssertTrue(actual.contains(.fullScreen))
        XCTAssertTrue(actual.contains(.autoHideDock))
        XCTAssertFalse(actual.contains(.hideMenuBar))
    }

    func testTitleInsetFollowsNativeTitlebarVisibilityInsteadOfPointerLocation() {
        let header = CGRect(x: 0, y: 1358, width: 2560, height: 52)
        XCTAssertEqual(FullScreenChrome.revealProgress(titlebar: CGRect(x: 0, y: 1440, width: 2560, height: 52), header: header), 0)
        XCTAssertEqual(FullScreenChrome.revealProgress(titlebar: CGRect(x: 0, y: 1384, width: 2560, height: 52), header: header), 0.5)
        XCTAssertEqual(FullScreenChrome.revealProgress(titlebar: header, header: header), 1)
        XCTAssertEqual(FullScreenChrome.revealProgress(titlebar: .zero, header: header), 0)
        let tile = CGRect(x: 700, y: 100, width: 600, height: 52)
        XCTAssertEqual(FullScreenChrome.revealProgress(titlebar: tile, header: tile), 1)
        XCTAssertEqual(FullScreenChrome.revealProgress(titlebar: tile.offsetBy(dx: 700, dy: 0), header: tile), 0)
    }

    @MainActor func testOriginalWidgetsKeepTheirNativeParentsActionsAndGroupedTracking() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NativeChromeTestRoot()
        let device = SimulatorDevice(udid: "test", name: "iPhone", state: "Booted", isAvailable: true, deviceTypeIdentifier: nil, runtime: "iOS")
        let bar = SimulatorControlBar(device: device) { _ in }
        let chrome = FullScreenChrome(window: window, controls: bar) { _ in }
        window.contentView!.addSubview(bar)
        bar.attach(to: window)
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let originals = types.map { window.standardWindowButton($0)! }
        let parents = originals.map { $0.superview! }
        let actions = originals.map { $0.action }
        let targets = originals.map { $0.target as AnyObject? }
        for (width, fullScreen) in [(CGFloat(620), false), (324, false), (620, true), (620, false)] {
            window.setContentSize(CGSize(width: width, height: 800))
            bar.isFullScreen = fullScreen
            bar.frame = CGRect(x: 0, y: 0, width: width, height: fullScreen ? 52 : bar.height(for: width))
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            window.contentView!.superview!.layoutSubtreeIfNeeded()
            for index in types.indices {
                let button = bar.windowButtons[index]
                XCTAssertTrue(button === originals[index])
                XCTAssertTrue(button === window.standardWindowButton(types[index]))
                XCTAssertTrue(button.superview === parents[index])
                XCTAssertFalse(button.isDescendant(of: bar))
                XCTAssertEqual(button.action, actions[index])
                XCTAssertTrue((button.target as AnyObject?) === targets[index])
                XCTAssertTrue(bar.bounds.contains(bar.convert(button.bounds, from: button)))
            }
            XCTAssertTrue(bar.trackingAreas.isEmpty, "AppKit owns traffic-light hover and reveal tracking")
            let frame = window.contentView!.superview!
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let buttons = descendants(frame).compactMap { $0 as? NSButton }.filter { $0.target === bar.actions }
            XCTAssertEqual(buttons.count, 3)
            for button in buttons {
                let center = frame.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                let hit = frame.hitTest(center)
                XCTAssertTrue(hit === button || hit === button.superview || hit?.isDescendant(of: button) == true,
                    "AppKit's toolbar control must remain clickable: \(String(describing: hit))")
                XCTAssertFalse(button.isDescendant(of: bar), "AppKit owns the toolbar controls")
            }
        }
        let frame = window.contentView!.superview!
        frame.updateTrackingAreas()
        let span = originals.map { frame.convert($0.bounds, from: $0) }.reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(frame.trackingAreas.contains { $0.rect == span && $0.options.contains(.mouseEnteredAndExited) },
            "The native group hover area must coincide with the real buttons")
        withExtendedLifetime(chrome) {}
    }

    @MainActor func testNativeToolbarActionsAndRecordingValidation() async {
        _ = NSApplication.shared
        let device = SimulatorDevice(udid: "test", name: "iPhone", state: "Booted", isAvailable: true, deviceTypeIdentifier: nil)
        var commands: [DeviceCommand] = []
        let bar = SimulatorControlBar(device: device) { commands.append($0) }
        func click(_ index: Int) {
            let item = bar.actionItems[index]
            XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        for index in 0..<3 { click(index) }
        XCTAssertEqual(commands, [.home, .screenshot, .rotateRight])
        bar.update(isRecording: true)
        XCTAssertEqual(bar.actionItems[1].label, "Stop Recording")
        click(1)
        XCTAssertEqual(commands.last, .recording)
        bar.update(isRecording: true, isStoppingRecording: true)
        bar.actions.toolbar.validateVisibleItems()
        XCTAssertFalse(bar.actionItems[1].isEnabled)
        XCTAssertFalse(bar.actions.validateToolbarItem(bar.actionItems[1]))
        XCTAssertTrue(bar.actions.validateToolbarItem(bar.actionItems[0]))
        XCTAssertTrue(bar.actions.validateToolbarItem(bar.actionItems[2]))
        let count = commands.count
        click(1)
        XCTAssertEqual(commands.count, count, "A stale click during finalization must be ignored")
        bar.update(isRecording: false)
        XCTAssertEqual(bar.actionItems[1].label, "Screenshot")
        XCTAssertTrue(bar.actionItems[1].isEnabled)
        click(1)
        XCTAssertEqual(commands.last, .screenshot)
    }

    @MainActor func testFoldableToolbarOffersAllThreeDisplayModes() async throws {
        _ = NSApplication.shared
        var commands: [DeviceCommand] = []
        let toolbar = SimulatorToolbar(displayModes: DeviceDisplayMode.allCases) { commands.append($0) }
        XCTAssertEqual(toolbar.items.map(\.label), ["Home", "Screenshot", "Rotate"])
        XCTAssertEqual(DeviceDisplayMode.allCases.map(\.deviceKitAssetName), ["v68.closed", "v68.bent", "v68.flat"])
        XCTAssertEqual(toolbar.toolbarDefaultItemIdentifiers(toolbar.toolbar), [
            .flexibleSpace,
            toolbar.items[0].itemIdentifier, toolbar.items[1].itemIdentifier, toolbar.items[2].itemIdentifier
        ])
        if #available(macOS 15, *) {
            XCTAssertEqual(toolbar.toolbar.itemIdentifiers, toolbar.toolbarDefaultItemIdentifiers(toolbar.toolbar))
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.toolbar = toolbar.toolbar
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier),
            toolbar.toolbarDefaultItemIdentifiers(toolbar.toolbar))
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let nativeButtons = descendants(window.contentView!.superview!).compactMap { $0 as? NSButton }
            .filter { $0.target === toolbar }
        XCTAssertEqual(nativeButtons.count, 3)
        let duo = SimulatorDevice(udid: "duo-layout", name: "iPhone Duo", state: "Booted", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        guard DeviceChrome.displayModes(for: duo) == DeviceDisplayMode.allCases else {
            throw XCTSkip("The selected Xcode does not include the Duo device profile")
        }
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        let root = NativeChromeTestRoot(frame: host.contentLayoutRect)
        host.contentView = root
        let bar = SimulatorControlBar(device: duo) { commands.append($0) }
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: bar.height(for: 800))
        root.addSubview(bar)
        let chrome = FullScreenChrome(window: host, controls: bar) { _ in }
        bar.attach(to: host)
        let originalButtons = bar.windowButtons
        let originalParents = originalButtons.map { $0.superview }
        let nativeOffsets = originalButtons.map { $0.convert($0.bounds, to: nil).minX }
        host.orderFront(nil)
        host.contentView!.superview!.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.actions.toolbar.centeredItemIdentifiers.isEmpty)
        let productionButtons = descendants(host.contentView!.superview!).compactMap { $0 as? NSButton }
            .filter { $0.target === bar.actions }
        XCTAssertEqual(productionButtons.count, 3)
        func actionFrames() -> [CGRect] {
            bar.actionItems.map { item in
                productionButtons.first { $0.action == item.action }.map { button in
                    guard let window = button.window else { return CGRect.zero }
                    let screenFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
                    let hostFrame = host.convertFromScreen(screenFrame)
                    return bar.convert(hostFrame, from: nil)
                } ?? .zero
            }
        }
        let frames = actionFrames()
        let nativeTrailingInset = bar.bounds.maxX - frames.map(\.maxX).max()!
        XCTAssertGreaterThan(nativeTrailingInset, 0)
        XCTAssertEqual(bar.convert(bar.windowButtons[0].bounds, from: bar.windowButtons[0]).minX, 20, accuracy: 1)
        XCTAssertTrue(frames.allSatisfy { !$0.isEmpty && $0.minX >= 0 && $0.maxX <= bar.bounds.maxX },
            "Toolbar frames must fit the window horizontally: \(frames)")
        let modeControl = try XCTUnwrap(bar.displayModeControl)
        XCTAssertEqual(modeControl.segmentCount, 3)
        XCTAssertTrue((0..<modeControl.segmentCount).allSatisfy { modeControl.image(forSegment: $0) != nil })
        for index in 0..<modeControl.segmentCount {
            modeControl.selectedSegment = index
            XCTAssertTrue(NSApp.sendAction(modeControl.action!, to: modeControl.target, from: modeControl))
        }
        XCTAssertEqual(commands, [.coverScreen, .innerPartiallyOpen, .innerFullyOpen])
        for angle in [0.0, 0.0001, 1, 14, 15, 16, 60, 119.9, 120, 120.1, 179.9, 179.9999, 180] {
            bar.update(hingeAngle: angle)
            let expected = angle == 0 ? 0 : angle == 180 ? 2 : 1
            XCTAssertEqual(modeControl.selectedSegment, expected, "angle=\(angle)")
        }
        bar.update(hingeAngle: 60)
        XCTAssertEqual(modeControl.selectedSegment, 1)
        XCTAssertTrue(NSApp.sendAction(modeControl.action!, to: modeControl.target, from: modeControl))
        XCTAssertEqual(commands.last, .innerPartiallyOpen,
            "Clicking the already-selected middle segment must still request the 120° preset")
        let modeFrame = bar.convert(modeControl.bounds, from: modeControl)
        XCTAssertEqual(modeFrame.midX, bar.bounds.midX, accuracy: 1,
            "The Duo mode group must remain at the exact center of the visible bar")
        XCTAssertGreaterThan(modeFrame.minX, 102 + bar.titleWidth)
        XCTAssertLessThan(modeFrame.maxX, frames.map(\.minX).min()!)

        bar.frame = CGRect(x: 100, y: 0, width: 600, height: bar.height(for: 600))
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        host.contentView!.superview!.layoutSubtreeIfNeeded()
        let narrowed = actionFrames()
        XCTAssertEqual(bar.bounds.maxX - narrowed.map(\.maxX).max()!, nativeTrailingInset, accuracy: 1)
        XCTAssertEqual(bar.convert(bar.windowButtons[0].bounds, from: bar.windowButtons[0]).minX, 20, accuracy: 1)
        XCTAssertTrue(narrowed.allSatisfy { !$0.isEmpty && $0.minX >= 0 && $0.maxX <= bar.bounds.maxX },
            "Standard controls must follow the shrinking bar's right edge: \(narrowed)")
        XCTAssertLessThan(narrowed.map(\.maxX).max()!, frames.map(\.maxX).max()! - 150)
        XCTAssertEqual(bar.convert(modeControl.bounds, from: modeControl).midX, bar.bounds.midX, accuracy: 1)
        // AppKit also lays out the titlebar after our content's layout pass.
        // Do not call bar.layout() before checking the settled native widgets.
        for width: CGFloat in [600, bar.minimumCompactWidth + 24, 480, 760, 600] {
            bar.frame = CGRect(x: (800 - width) / 2, y: 0, width: width, height: bar.height(for: width))
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            for _ in 0..<3 {
                let frameView = host.contentView!.superview!
                frameView.needsLayout = true
                frameView.layoutSubtreeIfNeeded()
                host.update()
                try await Task.sleep(for: .milliseconds(30))
                let selector = bar.convert(modeControl.bounds, from: modeControl)
                XCTAssertFalse(bar.barLayout.name.intersects(selector))
                XCTAssertTrue(actionFrames().allSatisfy { !$0.intersects(selector) },
                    "Native actions must not overlap the centered Duo selector in either row layout")
                for index in originalButtons.indices {
                    let button = bar.windowButtons[index]
                    XCTAssertTrue(button === originalButtons[index])
                    XCTAssertTrue(button.superview === originalParents[index])
                    XCTAssertEqual(bar.convert(button.bounds, from: button).minX,
                        nativeOffsets[index], accuracy: 0.5,
                        "Traffic lights must follow the pill after AppKit's deferred layout (width=\(width))")
                    let center = frameView.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    let hit = frameView.hitTest(center)
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                        "The visible native window button must remain clickable")
                }
                let span = originalButtons.map { frameView.convert($0.bounds, from: $0) }
                    .reduce(CGRect.null) { $0.union($1) }
                let hoverAreas = frameView.trackingAreas.filter {
                    $0.options.contains(.mouseEnteredAndExited) && $0.rect.size == span.size
                        && $0.owner as AnyObject? === frameView
                }
                XCTAssertEqual(hoverAreas.count, 1, "Keep exactly one native group-hover region")
                XCTAssertEqual(hoverAreas.first?.rect, span,
                    "The native hover region must follow the visible traffic lights after deferred layout")
            }
        }
        bar.isFullScreen = true
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: 52)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        let frameView = host.contentView!.superview!
        frameView.needsLayout = true
        frameView.layoutSubtreeIfNeeded()
        host.update()
        try await Task.sleep(for: .milliseconds(50))
        let nativeSpan = originalButtons.map { frameView.convert($0.bounds, from: $0) }
            .reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(frameView.trackingAreas.contains { $0.rect == nativeSpan && $0.options.contains(.mouseEnteredAndExited) },
            "Fullscreen relinquishes traffic-light placement and tracking to AppKit")
        bar.isFullScreen = false
        bar.frame = CGRect(x: 100, y: 0, width: 600, height: 52)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        host.update()
        try await Task.sleep(for: .milliseconds(50))
        let restoredSpan = originalButtons.map { frameView.convert($0.bounds, from: $0) }
            .reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(frameView.trackingAreas.contains { $0.rect == restoredSpan && $0.options.contains(.mouseEnteredAndExited) })
        bar.removeFromSuperview()
        for (button, nativeX) in zip(originalButtons, nativeOffsets) {
            XCTAssertEqual(button.convert(button.bounds, to: nil).minX, nativeX, accuracy: 0.5,
                "Detaching the bar restores the system buttons")
        }
        let detachedSpan = originalButtons.map { frameView.convert($0.bounds, from: $0) }
            .reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(frameView.trackingAreas.contains { $0.rect == detachedSpan && $0.options.contains(.mouseEnteredAndExited) })
        root.addSubview(bar)
        for _ in 0..<5 { bar.attach(to: host) }
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        host.update()
        try await Task.sleep(for: .milliseconds(50))
        for (button, nativeX) in zip(originalButtons, nativeOffsets) {
            XCTAssertEqual(bar.convert(button.bounds, from: button).minX, nativeX, accuracy: 0.5,
                "Reattachment must not accumulate translations or duplicate observers")
        }
        withExtendedLifetime(chrome) {}
    }

    @MainActor func testFullscreenDuoSelectorUsesAnIndependentNativeToolbarControl() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NativeChromeTestRoot()
        let device = SimulatorDevice(udid: "test", name: "iPhone Duo", state: "Booted", isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")
        guard DeviceChrome.displayModes(for: device) == DeviceDisplayMode.allCases else {
            throw XCTSkip("The selected Xcode does not include the Duo device profile")
        }
        var commands: [DeviceCommand] = []
        let bar = SimulatorControlBar(device: device) { commands.append($0) }
        window.contentView!.addSubview(bar)
        let chrome = FullScreenChrome(window: window, controls: bar) { _ in }
        let selector = try XCTUnwrap(bar.displayModeControl)
        let originalStyle = selector.segmentStyle
        let originalBorder = selector.cell?.isBordered
        let originalSize = selector.controlSize
        let originalActions = bar.actionItems
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for fullScreen in [true, false, true, false] {
            bar.isFullScreen = fullScreen
            bar.frame = CGRect(x: 0, y: 0, width: 1000, height: 52)
            bar.update(hingeAngle: 60)
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            let frame = window.contentView!.superview!
            frame.layoutSubtreeIfNeeded()
            window.update()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(bar.displayModeControl === selector)
            XCTAssertEqual(selector.selectedSegment, 1)
            XCTAssertTrue(zip(originalActions, bar.actionItems).allSatisfy { $0 === $1 })
            let fullscreenSelector = bar.actions.fullscreenModeControl
            let nativeSelectors = fullscreenSelector.map { control in
                bar.actions.toolbar.items.filter { $0.view === control }
            } ?? []
            XCTAssertEqual(nativeSelectors.count, fullScreen ? 1 : 0)
            XCTAssertTrue(selector.superview === bar.contentView,
                "NSToolbar must never mutate the content selector's rendering context")
            if fullScreen {
                let fullscreenSelector = try XCTUnwrap(fullscreenSelector)
                XCTAssertFalse(fullscreenSelector === selector)
                XCTAssertTrue(selector.isHidden)
                XCTAssertFalse(fullscreenSelector.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(fullscreenSelector.visibleRect.contains(fullscreenSelector.bounds))
                XCTAssertEqual(fullscreenSelector.selectedSegment, selector.selectedSegment)
                let placed = fullscreenSelector.convert(fullscreenSelector.bounds, to: nil)
                XCTAssertEqual(placed.midX, window.contentView!.bounds.midX, accuracy: 1)
                for index in 0..<3 {
                    let center = frame.convert(CGPoint(x: fullscreenSelector.bounds.width * (CGFloat(index) + 0.5) / 3,
                        y: fullscreenSelector.bounds.midY), from: fullscreenSelector)
                    let hit = frame.hitTest(center)
                    XCTAssertTrue(hit === fullscreenSelector || hit?.isDescendant(of: fullscreenSelector) == true,
                        "Each visible segment must receive the click above native chrome: \(String(describing: hit))")
                    fullscreenSelector.selectedSegment = index
                    XCTAssertTrue(NSApp.sendAction(fullscreenSelector.action!, to: fullscreenSelector.target, from: fullscreenSelector))
                }
            } else {
                XCTAssertNil(fullscreenSelector)
                XCTAssertFalse(selector.isHidden)
                XCTAssertEqual(selector.segmentStyle, originalStyle)
                XCTAssertEqual(selector.cell?.isBordered, originalBorder)
                XCTAssertEqual(selector.controlSize, originalSize)
                XCTAssertEqual(bar.convert(selector.bounds, from: selector).midX, bar.bounds.midX, accuracy: 1)
            }
        }
        XCTAssertEqual(commands, [.coverScreen, .innerPartiallyOpen, .innerFullyOpen,
                                  .coverScreen, .innerPartiallyOpen, .innerFullyOpen])
        withExtendedLifetime(chrome) {}
    }

    @MainActor func testAppKitOwnsActionViewsAndResponsiveGrouping() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let device = SimulatorDevice(udid: "test", name: "iPhone", state: "Booted", isAvailable: true, deviceTypeIdentifier: nil)
        let bar = SimulatorControlBar(device: device) { _ in }
        let chrome = FullScreenChrome(window: window, controls: bar) { _ in }
        XCTAssertTrue(window.toolbar === bar.actions.toolbar)
        XCTAssertEqual(bar.actionItems.count, 3)
        XCTAssertTrue(bar.actionItems.allSatisfy { $0.view == nil }, "No custom NSButtons, glass wrapper, background or style")
        XCTAssertEqual(bar.actions.toolbarDefaultItemIdentifiers(bar.actions.toolbar), [.flexibleSpace] + bar.actionItems.map(\.itemIdentifier))
        let originalItems = bar.actionItems
        window.contentView!.addSubview(bar)
        for compact in [false, true, false] {
            bar.frame = CGRect(x: 0, y: 0, width: compact ? bar.minimumExpandedWidth - 1 : 620, height: compact ? 76 : 52)
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.toolbarStyle, compact ? .expanded : .unified)
            XCTAssertEqual(bar.actions.toolbar.centeredItemIdentifiers, compact ? Set(originalItems.map(\.itemIdentifier)) : [])
            XCTAssertTrue(zip(originalItems, bar.actionItems).allSatisfy { $0 === $1 })
            XCTAssertTrue(zip(bar.actions.toolbar.items.dropFirst(), originalItems).allSatisfy { $0 === $1 })
        }
        XCTAssertTrue(bar.trackingAreas.isEmpty)
        withExtendedLifetime(chrome) {}
    }
}
