#if DEBUG
import AppKit

@MainActor private final class ToolbarSmokeRoot: NSView {
    override var isFlipped: Bool { true }
}

extension Diagnostics {
    /// Test the production toolbar with local command handlers, without a guest.
    static func toolbarSmoke() async {
        let directory = outputDirectory()
        do {
            guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
                throw SimulatorError(message: "Toolbar pointer testing requires an unlocked macOS session.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let device = SimulatorDevice(udid: "toolbar-test", name: "iPhone 18 Pro Max", state: "Shutdown",
                isAvailable: true, deviceTypeIdentifier: nil, runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
            var commands: [DeviceCommand] = []
            let bar = SimulatorControlBar(device: device) { command in
                commands.append(command)
                print("Toolbar command \(command), event=\(String(describing: NSApp.currentEvent))")
            }
            let window = NSWindow(contentRect: CGRect(x: 180, y: 200, width: 620, height: 240),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            // Keep this small fixture above the foreground app while the driver
            // clicks it. It never connects to or changes a simulator.
            window.level = .floating
            let root = ToolbarSmokeRoot()
            window.contentView = root
            root.addSubview(bar)
            bar.attachWindowButtons(window)
            let chrome = FullScreenChrome(window: window, controls: bar) { _ in }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            defer { window.close(); withExtendedLifetime(chrome) {} }

            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            func phase(_ name: String, expected: [DeviceCommand], indices: [Int], optionRotate: Bool = false) async throws {
                window.contentView!.superview!.layoutSubtreeIfNeeded()
                window.toolbar?.validateVisibleItems()
                let buttons = descendants(window.contentView!.superview!).compactMap { $0 as? NSButton }
                let ordered = try bar.actionItems.map { item -> NSButton in
                    guard let button = buttons.first(where: { $0.target === bar.actions && $0.action == item.action }) else {
                        throw SimulatorError(message: "Missing native toolbar control for \(item.label).")
                    }
                    return button
                }
                let top = NSScreen.screens.first!.frame.maxY
                let header = window.convertToScreen(bar.convert(bar.bounds, to: nil))
                let targets = indices.map { index -> [String: Any] in
                    let button = ordered[index]
                    let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                    return ["index": index, "x": rect.midX, "y": top - rect.midY]
                }
                let payload: [String: Any] = ["name": name, "targets": targets, "optionRotate": optionRotate,
                    "region": "\(Int(header.minX)),\(Int(top - header.maxY)),\(Int(header.width)),\(Int(header.height))",
                    "activate": [header.minX + header.width / 2, top - header.maxY + 16],
                    "rest": [header.midX, top - header.minY + 100]]
                commands = []
                try JSONSerialization.data(withJSONObject: payload).write(to: directory.appendingPathComponent("toolbar-phase.json"), options: .atomic)
                var acknowledged = false
                for _ in 0..<1000 {
                    acknowledged = (try? String(contentsOf: directory.appendingPathComponent("toolbar-ack.txt"), encoding: .utf8)) == name
                    if acknowledged { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard acknowledged, commands == expected else {
                    throw SimulatorError(message: "Toolbar phase \(name): received \(commands), expected \(expected), acknowledged=\(acknowledged).")
                }
            }

            for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance)
                for (width, layout) in [(CGFloat(620), "wide"), (324, "compact")] {
                    window.setFrame(CGRect(x: 180, y: 400, width: width, height: 240), display: true, animate: false)
                    bar.frame = CGRect(x: 0, y: 0, width: width, height: bar.height(for: width))
                    bar.needsLayout = true
                    bar.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(250))
                    try await phase("\(label)-\(layout)", expected: [.home, .screenshot, .rotateRight, .rotateLeft], indices: [0, 1, 2], optionRotate: true)
                }
                bar.update(isRecording: true)
                try await phase("\(label)-recording", expected: [.recording], indices: [1])
                bar.update(isRecording: true, isStoppingRecording: true)
                try await phase("\(label)-finishing", expected: [], indices: [1])
                bar.update(isRecording: false)
            }
            try Data("done".utf8).write(to: directory.appendingPathComponent("toolbar-ack.txt"), options: .atomic)
            let result = "PASS: real native toolbar clicks in light/dark and wide/compact layouts; Home, Screenshot, Rotate Right, Option-Rotate Left, Stop Recording and disabled finalization. No guest used.\n"
            try Data(result.utf8).write(to: directory.appendingPathComponent("toolbar-results.txt"))
            print(result)
        } catch {
            try? Data("failed".utf8).write(to: directory.appendingPathComponent("toolbar-ack.txt"), options: .atomic)
            fputs("TOOLBAR FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
