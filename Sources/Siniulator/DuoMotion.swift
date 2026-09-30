import Foundation

/// One render-time state for both presets and gestures. Retargeting retains
/// velocity; a late display callback cannot skip a large part of the motion.
struct DuoSpring {
    var value: Double
    var target: Double
    private(set) var velocity = 0.0
    let maximumSpeed: Double

    init(_ value: Double, maximumSpeed: Double) {
        self.value = value
        target = value
        self.maximumSpeed = maximumSpeed
    }

    var isSettled: Bool { abs(target - value) < 0.00001 && abs(velocity) < 0.0001 }

    mutating func snap(to value: Double) {
        self.value = value
        target = value
        velocity = 0
    }

    mutating func advance(seconds: Double) {
        let dt = min(1.0 / 30, max(0, seconds))
        guard dt > 0 else { return }
        let frequency = 12.0
        let error = value - target
        let tangent = velocity + frequency * error
        let decay = exp(-frequency * dt)
        let proposed = target + (error + tangent * dt) * decay
        let step = proposed - value
        if abs(step) > maximumSpeed * dt {
            velocity = step.sign == .minus ? -maximumSpeed : maximumSpeed
            value += velocity * dt
        } else {
            value = proposed
            velocity = (velocity - frequency * tangent * dt) * decay
        }
        if isSettled { snap(to: target) }
    }
}

enum DuoPose {
    // A single path reserves time for turning the closed device over. A pinch
    // may target either side, but cannot park the model halfway through a turn.
    static let coverEnd = 0.20
    static let innerStart = 0.50
    // Keep the native panel swap inside the automatic camera turn. In
    // particular, the inner-facing endpoint must not be a nearly closed pose
    // at which iOS can extinguish its inner display after the gesture stops.
    static let coverRestAngle = 40.0
    // Held/reversed native transitions failed at 105° and passed at 108° on
    // iOS 27.1. Keep a small margin without turning as early as the 120° preset.
    static let innerRestAngle = 110.0

    static func restingAngle(_ angle: Double) -> Double {
        let angle = min(180, max(0, angle))
        guard angle > coverRestAngle, angle < innerRestAngle else { return angle }
        return angle < (coverRestAngle + innerRestAngle) / 2 ? coverRestAngle : innerRestAngle
    }

    static func phase(for angle: Double) -> Double {
        let angle = min(180, max(0, angle))
        if angle == 0 { return 0 }
        if angle == 180 { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if Self.angle(at: middle) < angle { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    static func angle(at phase: Double) -> Double {
        let phase = min(1, max(0, phase))
        // Monotone cubic segments share their tangents. A linear remapping
        // would abruptly change hinge speed on entering/leaving the turn.
        let firstSlope = coverRestAngle / coverEnd
        let turnSlope = (innerRestAngle - coverRestAngle) / (innerStart - coverEnd)
        let lastSlope = (180 - innerRestAngle) / (1 - innerStart)
        let firstTangent = 1.5 / (0.8 / firstSlope + 0.7 / turnSlope)
        let secondTangent = 2.4 / (1.3 / turnSlope + 1.1 / lastSlope)
        if phase <= coverEnd {
            return segment(phase / coverEnd, start: 0, end: coverRestAngle, slope0: firstSlope * coverEnd, slope1: firstTangent * coverEnd)
        }
        if phase < innerStart {
            let span = innerStart - coverEnd
            return segment((phase - coverEnd) / span, start: coverRestAngle, end: innerRestAngle,
                slope0: firstTangent * span, slope1: secondTangent * span)
        }
        let span = 1 - innerStart
        return segment((phase - innerStart) / span, start: innerRestAngle, end: 180,
            slope0: secondTangent * span, slope1: lastSlope * span)
    }

    private static func segment(_ t: Double, start: Double, end: Double, slope0: Double, slope1: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * start + (t3 - 2 * t2 + t) * slope0
            + (-2 * t3 + 3 * t2) * end + (t3 - t2) * slope1
    }

    static func orbit(at phase: Double) -> Double {
        let t = min(1, max(0, (phase - coverEnd) / (innerStart - coverEnd)))
        return -.pi / 2 * (1 - t * t * (3 - 2 * t))
    }

    static func pinchPhase(_ progress: Double) -> Double {
        let progress = min(1, max(0, progress))
        return progress < 0.25 ? progress / 0.25 * coverEnd
            : innerStart + (progress - 0.25) / 0.75 * (1 - innerStart)
    }

    static func pinchProgress(_ phase: Double) -> Double {
        if phase <= coverEnd { return phase / coverEnd * 0.25 }
        if phase < innerStart { return phase < (coverEnd + innerStart) / 2 ? 0.249999 : 0.25 }
        return 0.25 + (phase - innerStart) / (1 - innerStart) * 0.75
    }
}

/// A display-link sample shared by the renderer, projection and native HID.
/// Only external angle inputs need the inverse phase lookup.
struct DuoRenderPose: Equatable {
    let phase: Double
    let quarterTurns: CGFloat
    let angle: CGFloat
    let cameraOrbit: CGFloat

    init(phase: Double, quarterTurns: CGFloat) {
        self.phase = min(1, max(0, phase))
        self.quarterTurns = quarterTurns
        angle = CGFloat(DuoPose.angle(at: self.phase))
        cameraOrbit = CGFloat(DuoPose.orbit(at: self.phase))
    }

    init(angle: CGFloat, quarterTurns: CGFloat) {
        self.init(phase: DuoPose.phase(for: Double(angle)), quarterTurns: quarterTurns)
    }
}

struct DuoMotion {
    var fold: DuoSpring
    var roll: DuoSpring

    init(angle: Double, quarterTurns: Int) {
        fold = DuoSpring(DuoPose.phase(for: angle), maximumSpeed: 1)
        roll = DuoSpring(Double(quarterTurns), maximumSpeed: 3)
    }

    var angle: Double { DuoPose.angle(at: fold.value) }
    var renderedPose: DuoRenderPose { DuoRenderPose(phase: fold.value, quarterTurns: CGFloat(roll.value)) }
    var isSettled: Bool { fold.isSettled && roll.isSettled }

    mutating func rotate(to turns: Int) {
        let target = Double(turns)
        roll.target = target + ((roll.value - target) / 4).rounded() * 4
    }

    mutating func advance(seconds: Double) {
        fold.advance(seconds: seconds)
        roll.advance(seconds: seconds)
    }
}

/// Reference projection for Duo. The camera fits the
/// entire swept model once; only a manual resize changes projection scale.
enum DuoStage {
    static let viewport: CGFloat = 700
    static let toolbarGap: CGFloat = 20
    static let outerMargin: CGFloat = 16
    static let modelInset: CGFloat = 36
    // Keep the hardware safely inside the backing surface, including resize
    // targets/antialiasing. The window crop removes this internal padding.
    static let projectionTopInset: CGFloat = 16
    static let fieldOfView: CGFloat = 31
    static let nearPlane: Float = 0.01
    static let farPlane: Float = 200
    static var halfFieldOfView: CGFloat { fieldOfView * .pi / 360 }
    static var cameraFitFraction: CGFloat { 1 - 2 * modelInset / viewport }
}

/// The toolbar follows device scale, never its current hinge or roll. Keep a
/// single row at small scales rather than changing the header height mid-drag.
struct DuoToolbarSizing: Equatable {
    let widthFraction: CGFloat
    let minimumWidth: CGFloat

    func width(for viewport: CGFloat) -> CGFloat {
        max(minimumWidth, viewport * widthFraction)
    }
}
