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
        bar.attachWindowButtons(window)
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
        for compact in [false, true, false] {
            bar.actions.layout(in: window, compact: compact)
            XCTAssertEqual(window.toolbarStyle, compact ? .expanded : .unified)
            XCTAssertEqual(bar.actions.toolbar.centeredItemIdentifiers, compact ? Set(originalItems.map(\.itemIdentifier)) : [])
            XCTAssertTrue(zip(originalItems, bar.actionItems).allSatisfy { $0 === $1 })
            XCTAssertTrue(zip(bar.actions.toolbar.items.dropFirst(), originalItems).allSatisfy { $0 === $1 })
        }
        XCTAssertTrue(bar.trackingAreas.isEmpty)
        withExtendedLifetime(chrome) {}
    }
}
