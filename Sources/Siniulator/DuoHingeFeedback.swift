import AppKit

/// One tactile cue at the display handoff, with a small rearming distance so
/// jitter around the hinge threshold cannot produce a train of pulses.
struct DuoHingeFeedback {
    private var isArmed = true
    private static let rearmDistance = 3.0

    mutating func update(from previous: Double, to angle: Double, phase: NSEvent.Phase) -> Bool {
        if phase.contains(.began) { isArmed = true }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            isArmed = true
            return false
        }
        guard phase.isEmpty || phase.contains(.began) || phase.contains(.changed),
              previous.isFinite, angle.isFinite else { return false }
        let threshold = DeviceDisplayMode.coverHandoffAngle
        let awayFromHandoff = abs(angle - threshold) >= Self.rearmDistance
        guard isArmed else {
            if awayFromHandoff { isArmed = true }
            return false
        }
        guard (previous <= threshold) != (angle <= threshold) else { return false }
        isArmed = awayFromHandoff
        return true
    }
}
