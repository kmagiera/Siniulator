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
        let originalViewport = root.duoViewportSide
        defer {
            window.endCornerResize()
            root.duoViewportSide = originalViewport
            window.setFrame(original, display: true, animate: false)
            root.canvas.maximumScale = originalMaximum
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            if root.canvas.usesDuoModel {
                UserDefaults.standard.set(originalViewport, forKey: "duo-viewport-\(controller.deviceInfo.id)")
            }
        }
        guard !window.isMovableByWindowBackground else {
            throw SimulatorError(message: "Automatic background movement competes with corner resizing.")
        }
        for corner in DeviceResizeCorner.allCases {
            root.duoViewportSide = originalViewport
            window.setFrame(original, display: true, animate: false)
            root.canvas.maximumScale = originalMaximum
            root.refreshGeometry()
            root.layoutSubtreeIfNeeded()
            let target = root.resizeTarget(for: corner)
            let local = CGPoint(x: target.midX, y: target.midY)
            guard root.resizeCorner(at: local) == corner else {
                throw SimulatorError(message: "Visible \(corner) did not expose its resize target: \(target), toolbar \(root.controls.frame), device \(root.deviceRect), mode \(String(describing: controller.displayMode)), turns \(controller.screen.quarterTurns).")
            }
            let pointer = window.convertToScreen(CGRect(origin: root.convert(local, to: nil), size: .zero)).origin
            let duoSession = root.canvas.usesDuoModel ? DuoResizeSession(corner: corner, initialFrame: original,
                initialDevice: window.convertToScreen(root.convert(root.visualDeviceRect, to: nil)),
                initialPointer: pointer, initialViewport: originalViewport,
                headerHeight: root.controls.frame.height, visibleFrame: window.screen!.visibleFrame,
                toolbarSizing: root.duoToolbarSizing, maximumSpan: root.canvas.duoMaximumProjectedSpan) : nil
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
                if let duoSession {
                    let location = event.cgEvent!.location
                    let geometry = duoSession.geometry(at: CGPoint(x: location.x, y: NSScreen.screens.first!.frame.maxY - location.y))
                    guard abs(frame.minX - geometry.frame.minX) <= 1, abs(frame.minY - geometry.frame.minY) <= 1,
                          abs(frame.width - geometry.frame.width) <= 1, abs(frame.height - geometry.frame.height) <= 1,
                          root.duoViewportSide == geometry.viewport,
                          abs(root.visualDeviceRect.minY - root.controls.frame.maxY - DuoStage.toolbarGap) < 0.001 else {
                        throw SimulatorError(message: "Queued \(corner) Duo resize changed its projection scale or frame geometry.")
                    }
                } else {
                    guard abs((corner.isLeft ? frame.maxX : frame.minX) - (corner.isLeft ? original.maxX : original.minX)) < 1,
                          abs((corner.isTop ? frame.minY : frame.maxY) - (corner.isTop ? original.minY : original.maxY)) < 1,
                          let maximum = root.canvas.maximumScale,
                          abs(root.canvas.geometry.fit(in: root.canvas.bounds, maximumScale: maximum).scale - maximum) < 0.000001 else {
                        throw SimulatorError(message: "Queued \(corner) resize moved its anchor or reset the dragged screen scale.")
                    }
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
