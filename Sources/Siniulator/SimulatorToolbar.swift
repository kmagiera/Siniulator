import AppKit

/// Standard toolbar items let AppKit provide Finder's shared action group,
/// including its layout, glass, hover, pressed state and appearance adaptation.
@MainActor final class SimulatorToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    let toolbar = NSToolbar(identifier: "Siniulator.DeviceActions")
    private let action: (DeviceCommand) -> Void
    private var isRecording = false
    private var isStoppingRecording = false
    private(set) var items: [NSToolbarItem] = []

    init(action: @escaping (DeviceCommand) -> Void) {
        self.action = action
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
    }

    private func makeItem(_ name: String, symbol: String, action: Selector, tooltip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init("Siniulator.\(name)"))
        item.label = name
        item.paletteLabel = name
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        item.toolTip = tooltip
        item.target = self
        item.action = action
        item.visibilityPriority = .high
        return item
    }

    func layout(in window: NSWindow, compact: Bool) {
        let style: NSWindow.ToolbarStyle = compact ? .expanded : .unified
        if window.toolbarStyle != style { window.toolbarStyle = style }
        let centered = compact ? Set(items.map(\.itemIdentifier)) : []
        if toolbar.centeredItemIdentifiers != centered { toolbar.centeredItemIdentifiers = centered }
    }

    func update(isRecording: Bool, isStoppingRecording: Bool) {
        self.isRecording = isRecording
        self.isStoppingRecording = isStoppingRecording
        let item = items[1]
        let name = isRecording ? "Stop Recording" : "Screenshot"
        item.label = name
        item.paletteLabel = name
        item.image = NSImage(systemSymbolName: isRecording ? "stop.circle" : "camera.on.rectangle", accessibilityDescription: name)
        item.toolTip = isStoppingRecording ? "Finishing recording…" : isRecording ? "Stop Recording (⌘R)" : "Screenshot (⌘S)"
        item.isEnabled = !isStoppingRecording
    }

    @objc private func home() { action(.home) }
    @objc private func capture() {
        guard !isStoppingRecording else { return }
        action(isRecording ? .recording : .screenshot)
    }
    @objc private func rotate() {
        action(NSApp.currentEvent?.modifierFlags.contains(.option) == true ? .rotateLeft : .rotateRight)
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item !== items[1] || !isStoppingRecording
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Adjacent standard action items share one native glass group on macOS 26.
        [.flexibleSpace] + items.map(\.itemIdentifier)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        items.first { $0.itemIdentifier == identifier }
    }
}
