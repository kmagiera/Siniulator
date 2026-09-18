import Foundation

struct MultitouchState {
    private(set) var center = CGPoint(x: 0.5, y: 0.5)
    private(set) var first = CGPoint(x: 0.35, y: 0.5)
    private var previous: CGPoint?
    private var translating = false
    private var pinchOffset = CGPoint.zero
    var second: CGPoint { CGPoint(x: 2 * center.x - first.x, y: 2 * center.y - first.y) }

    mutating func resetTracking() {
        // Hiding the markers or leaving the view ends this pointer sequence,
        // but preserves the center chosen by the user.
        previous = nil
        translating = false
        pinchOffset = .zero
    }

    mutating func update(pointer: CGPoint, translating: Bool) {
        if previous != nil, self.translating != translating {
            // A modifier change chooses a new anchor, not a touch movement.
            // Preserve the cursor-to-finger offset when returning to pinch:
            // clamping a pan at an edge may have separated those positions.
            pinchOffset = CGPoint(x: first.x - pointer.x, y: first.y - pointer.y)
        } else if translating, let previous {
            // Move both fingers equally without changing their separation.
            let other = second
            let dx = min(1 - max(first.x, other.x), max(-min(first.x, other.x), pointer.x - previous.x))
            let dy = min(1 - max(first.y, other.y), max(-min(first.y, other.y), pointer.y - previous.y))
            center.x += dx; center.y += dy; first.x += dx; first.y += dy
        } else {
            first = CGPoint(x: min(min(1, 2 * center.x), max(max(0, 2 * center.x - 1), pointer.x + pinchOffset.x)),
                            y: min(min(1, 2 * center.y), max(max(0, 2 * center.y - 1), pointer.y + pinchOffset.y)))
        }
        previous = pointer
        self.translating = translating
    }
}
