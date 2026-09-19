import AppKit

/// Standard toolbar items let AppKit provide Finder's shared action group,
/// including its layout, glass, hover, pressed state and appearance adaptation.
@MainActor final class SimulatorToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    let toolbar: NSToolbar
    private let action: (DeviceCommand) -> Void
    private enum CaptureState { case idle, recording, finishing }
    private var captureState = CaptureState.idle
    private(set) var items: [NSToolbarItem] = []
    static let modeIdentifier = NSToolbarItem.Identifier("Siniulator.DisplayModes")
    private var modeItem: NSToolbarItem?
    private(set) var fullscreenModeControl: NSSegmentedControl?

    /// Fullscreen chrome lives in AppKit's auxiliary toolbar window. Keep its
    /// control separate: hosting the content control in NSToolbar changes its
    /// contextual rendering even after it is moved back to the window.
    func setFullscreenModes(_ source: NSSegmentedControl?) {
        if let source {
            if let fullscreenModeControl {
                fullscreenModeControl.selectedSegment = source.selectedSegment
                return
            }
            let control = NSSegmentedControl(labels: Array(repeating: "", count: source.segmentCount),
                trackingMode: .selectOne, target: source.target, action: source.action)
            for index in 0..<source.segmentCount {
                control.setImage(source.image(forSegment: index), forSegment: index)
                control.setImageScaling(source.imageScaling(forSegment: index), forSegment: index)
                control.setToolTip(source.toolTip(forSegment: index), forSegment: index)
                control.setWidth(source.width(forSegment: index), forSegment: index)
            }
            control.selectedSegment = source.selectedSegment
            control.setFrameSize(control.intrinsicContentSize)
            let item = NSToolbarItem(itemIdentifier: Self.modeIdentifier)
            item.label = "Display Mode"
            item.paletteLabel = item.label
            item.visibilityPriority = .high
            // Direct hosting intentionally lets AppKit choose the toolbar-native
            // size and appearance. This is a separate control, so those changes
            // can never leak back into the normal-window selector.
            item.view = control
            fullscreenModeControl = control
            modeItem = item
            toolbar.insertItem(withItemIdentifier: Self.modeIdentifier, at: 0)
        } else if modeItem != nil {
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.modeIdentifier }) {
                toolbar.removeItem(at: index)
            }
            modeItem?.view = nil
            modeItem = nil
            fullscreenModeControl = nil
        }
    }

    init(displayModes: [DeviceDisplayMode] = [], action: @escaping (DeviceCommand) -> Void) {
        self.action = action
        toolbar = NSToolbar(identifier: displayModes.isEmpty
            ? "Siniulator.DeviceActions" : "Siniulator.FoldableDeviceActions")
        super.init()
        items = [
            makeItem("Home", symbol: "house", action: #selector(home), tooltip: "Home (⇧⌘H)"),
            makeItem("Screenshot", symbol: "camera.on.rectangle", action: #selector(capture), tooltip: "Screenshot (⌘S)"),
            makeItem("Rotate", symbol: "rotate.right", action: #selector(rotate), tooltip: "Rotate Right (⌘→; ⌥: left)")
        ]
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if #available(macOS 15, *) { toolbar.allowsDisplayModeCustomization = false }
        if #available(macOS 15, *) {
            toolbar.itemIdentifiers = toolbarDefaultItemIdentifiers(toolbar)
        }
    }

    private func makeItem(_ name: String, symbol: String, action: Selector, tooltip: String) -> NSToolbarItem {
        makeItem(name, image: NSImage(systemSymbolName: symbol, accessibilityDescription: name),
                 action: action, tooltip: tooltip)
    }

    private func makeItem(_ name: String, image: NSImage?, action: Selector, tooltip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init("Siniulator.\(name)"))
        item.label = name
        item.paletteLabel = name
        item.image = image
        item.toolTip = tooltip
        item.target = self
        item.action = action
        item.visibilityPriority = .high
        return item
    }

    func update(isRecording: Bool, isStoppingRecording: Bool) {
        captureState = isStoppingRecording ? .finishing : isRecording ? .recording : .idle
        let item = items[1]
        let name = captureState == .idle ? "Screenshot" : "Stop Recording"
        item.label = name
        item.paletteLabel = name
        item.image = NSImage(systemSymbolName: captureState == .idle ? "camera.on.rectangle" : "stop.circle", accessibilityDescription: name)
        item.toolTip = captureState == .finishing ? "Finishing recording…" : captureState == .recording ? "Stop Recording (⌘R)" : "Screenshot (⌘S)"
        item.isEnabled = captureState != .finishing
    }

    @objc private func home() { action(.home) }
    @objc private func capture() {
        guard captureState != .finishing else { return }
        action(captureState == .recording ? .recording : .screenshot)
    }
    @objc private func rotate() {
        action(NSApp.currentEvent?.modifierFlags.contains(.option) == true ? .rotateLeft : .rotateRight)
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item !== items[1] || captureState != .finishing
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let standard = items.map(\.itemIdentifier)
        return [.flexibleSpace] + standard
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.modeIdentifier]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.modeIdentifier { return modeItem }
        return items.first { $0.itemIdentifier == identifier }
    }
}
