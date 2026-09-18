#if DEBUG
import AppKit

extension Diagnostics {
    static func cornerResizeEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        let cgType: CGEventType = type == .leftMouseDown ? .leftMouseDown : type == .leftMouseUp ? .leftMouseUp : .leftMouseDragged
        let quartz = CGPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y)
        return NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: quartz, mouseButton: .left)!)!
    }

    static func queuedCornerResizeSmoke(controller: DeviceWindowController) throws {
        guard let window = controller.window as? DeviceHostWindow, let root = controller.presentation else { return }
        let original = window.frame
        let originalMaximum = root.canvas.maximumScale
        defer {
            window.endCornerResize()
            window.setFrame(original, display: true, animate: false)
            root.canvas.maximumScale = originalMaximum
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
        }
        guard !window.isMovableByWindowBackground else {
            throw SimulatorError(message: "Automatic background movement competes with corner resizing.")
        }
        for corner in DeviceResizeCorner.allCases {
            window.setFrame(original, display: true, animate: false)
            root.canvas.maximumScale = originalMaximum
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            let curve = root.deviceCornerRadius * (1 - 1 / sqrt(2))
            let local = CGPoint(x: corner.isLeft ? root.deviceRect.minX + curve : root.deviceRect.maxX - curve,
                y: corner.isTop ? root.deviceRect.minY + curve : root.deviceRect.maxY - curve)
            let pointer = window.convertToScreen(CGRect(origin: root.convert(local, to: nil), size: .zero)).origin
            // Build the entire queue before moving the window. Real mouse events
            // can be queued while AppKit is laying out/compositing the last frame.
            let steps: [CGFloat] = [0, 8, 16, 24, 32, 32, 16, 0]
            let events = steps.map { step in
                cornerResizeEvent(.leftMouseDragged, at: CGPoint(x: pointer.x + (corner.isLeft ? -step : step),
                    y: pointer.y + (corner.isTop ? step * 2 : -step * 2)))
            }
            window.sendEvent(cornerResizeEvent(.leftMouseDown, at: pointer))
            guard window.isCornerResizing else { throw SimulatorError(message: "Queued \(corner) resize did not start.") }
            var frames: [CGRect] = []
            for event in events {
                window.sendEvent(event)
                let frame = window.frame
                frames.append(frame)
                guard abs((corner.isLeft ? frame.maxX : frame.minX) - (corner.isLeft ? original.maxX : original.minX)) < 1,
                      abs((corner.isTop ? frame.minY : frame.maxY) - (corner.isTop ? original.minY : original.maxY)) < 1,
                      let maximum = root.canvas.maximumScale,
                      abs(root.canvas.geometry.fit(in: root.canvas.bounds, maximumScale: maximum).scale - maximum) < 0.000001 else {
                    throw SimulatorError(message: "Queued \(corner) resize moved its anchor or reset the dragged screen scale.")
                }
            }
            window.sendEvent(cornerResizeEvent(.leftMouseUp, at: pointer))
            guard !window.isCornerResizing, frames[4] == frames[5], frames[2] == frames[6], frames[0] == frames[7],
                  (0..<4).allSatisfy({ frames[$0 + 1].height >= frames[$0].height }),
                  abs(window.frame.width - original.width) < 1, abs(window.frame.height - original.height) < 1 else {
                throw SimulatorError(message: "Queued \(corner) resize jumps, oscillates or does not return to its starting frame.")
            }
        }
        print("PASS: \(controller.deviceInfo.name) queued drags at all four corners preserve the anchor and screen scale; repeated pointer positions produce identical frames, reversing returns to the original size")
    }
}
#endif
