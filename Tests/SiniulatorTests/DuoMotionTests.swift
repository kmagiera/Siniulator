import XCTest
@testable import Siniulator

final class DuoMotionTests: XCTestCase {
    func testRestingTargetsStayOutsideTheAutomaticPanelTurn() {
        for step in 0...1000 {
            let angle = DuoPose.angle(at: DuoPose.pinchPhase(Double(step) / 1000))
            XCTAssertTrue(angle <= DuoPose.coverRestAngle || angle >= DuoPose.innerRestAngle)
        }
        XCTAssertEqual(DuoPose.restingAngle(55), DuoPose.coverRestAngle)
        XCTAssertEqual(DuoPose.restingAngle(80), DuoPose.innerRestAngle)
        for angle in [0.0, 20, 40, 110, 120, 150, 180] { XCTAssertEqual(DuoPose.restingAngle(angle), angle) }
    }

    func testHingeSpeedIsContinuousAtBothEndsOfTheCameraTurn() {
        let epsilon = 0.000001
        for phase in [DuoPose.coverEnd, DuoPose.innerStart] {
            let left = (DuoPose.angle(at: phase) - DuoPose.angle(at: phase - epsilon)) / epsilon
            let right = (DuoPose.angle(at: phase + epsilon) - DuoPose.angle(at: phase)) / epsilon
            XCTAssertEqual(left, right, accuracy: 0.01)
        }
    }
    func testPinchTargetsSkipTheTurnButTheFollowerTraversesIt() {
        for step in 0...1000 {
            let phase = DuoPose.pinchPhase(Double(step) / 1000)
            XCTAssertTrue(phase <= DuoPose.coverEnd || phase >= DuoPose.innerStart)
            XCTAssertEqual(DuoPose.phase(for: DuoPose.angle(at: phase)), phase, accuracy: 1e-10)
        }
        var motion = DuoMotion(angle: 0, quarterTurns: 0)
        motion.fold.target = 1
        var turnFrames = 0
        for _ in 0..<180 {
            let previous = motion.fold.value
            motion.advance(seconds: 1 / 60)
            XCTAssertGreaterThanOrEqual(motion.fold.value, previous)
            XCTAssertLessThanOrEqual(motion.fold.value - previous, 1 / 60 + 1e-10)
            if (DuoPose.coverEnd...DuoPose.innerStart).contains(motion.fold.value) { turnFrames += 1 }
        }
        XCTAssertTrue(motion.isSettled)
        XCTAssertGreaterThanOrEqual(turnFrames, 18)
        XCTAssertLessThan(turnFrames, 35)
    }

    func testRetargetingKeepsPositionAndVelocityAndHandlesDroppedFrames() {
        var motion = DuoMotion(angle: 180, quarterTurns: 0)
        motion.fold.target = 0
        for _ in 0..<30 { motion.advance(seconds: 1 / 60) }
        let position = motion.fold.value, velocity = motion.fold.velocity
        motion.fold.target = 1
        XCTAssertEqual(motion.fold.value, position)
        XCTAssertEqual(motion.fold.velocity, velocity)
        motion.advance(seconds: 0.2)
        XCTAssertLessThanOrEqual(abs(motion.fold.value - position), 1 / 30 + 1e-10)
        for _ in 0..<180 { motion.advance(seconds: 1 / 60) }
        XCTAssertTrue(motion.isSettled)
    }

    func testOrientationUsesTheShortestContinuousArc() {
        var motion = DuoMotion(angle: 180, quarterTurns: 3)
        motion.rotate(to: 0)
        XCTAssertEqual(motion.roll.target, 4)
        motion.rotate(to: 2)
        XCTAssertEqual(motion.roll.value, 3)
        XCTAssertEqual(motion.roll.target, 2)
        for _ in 0..<180 { motion.advance(seconds: 1 / 60) }
        XCTAssertTrue(motion.isSettled)
    }
}
