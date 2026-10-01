import AppKit
import XCTest
@testable import Siniulator

final class DuoHingeFeedbackTests: XCTestCase {
    private let threshold = DeviceDisplayMode.coverHandoffAngle
    func testClosingAndOpeningPulseAtTheDisplayHandoff() {
        var feedback = DuoHingeFeedback()
        XCTAssertFalse(feedback.update(from: 180, to: 90, phase: .began))
        XCTAssertFalse(feedback.update(from: 90, to: threshold + 1, phase: .changed))
        XCTAssertTrue(feedback.update(from: threshold + 1, to: threshold, phase: .changed))
        XCTAssertFalse(feedback.update(from: threshold, to: 0, phase: .changed))
        XCTAssertFalse(feedback.update(from: 0, to: 0, phase: .ended))
        XCTAssertFalse(feedback.update(from: 0, to: threshold, phase: .began))
        XCTAssertTrue(feedback.update(from: threshold, to: threshold + 1, phase: .changed))
        XCTAssertFalse(feedback.update(from: threshold + 1, to: 180, phase: .changed))
    }

    func testSlowPinchDoesNotRepeatFeedbackWhenJitteringAcrossThreshold() {
        var feedback = DuoHingeFeedback()
        XCTAssertTrue(feedback.update(from: threshold + 1, to: threshold - 0.1, phase: .began))
        var previous = threshold - 0.1
        for offset in [0.1, -0.2, 0.2, -0.3, 0.3, 0.0] {
            let angle = threshold + offset
            XCTAssertFalse(feedback.update(from: previous, to: angle, phase: .changed))
            previous = angle
        }
        XCTAssertFalse(feedback.update(from: previous, to: threshold - 3, phase: .changed))
        XCTAssertTrue(feedback.update(from: threshold - 3, to: threshold + 1, phase: .changed),
            "Moving away from the threshold rearms feedback for a deliberate reversal")
    }

    func testLargeStepsCanCrossInBothDirectionsWithinOneGesture() {
        var feedback = DuoHingeFeedback()
        XCTAssertTrue(feedback.update(from: 180, to: 0, phase: .began))
        XCTAssertTrue(feedback.update(from: 0, to: 180, phase: .changed))
        XCTAssertFalse(feedback.update(from: 180, to: 180, phase: .changed))
    }

    func testEndingOrCancellingNeverPulsesAndNextGestureIsRearmed() {
        for phase: NSEvent.Phase in [.ended, .cancelled] {
            var feedback = DuoHingeFeedback()
            XCTAssertTrue(feedback.update(from: threshold + 1, to: threshold - 0.1, phase: .began))
            XCTAssertFalse(feedback.update(from: threshold - 0.1, to: threshold + 1, phase: phase))
            XCTAssertTrue(feedback.update(from: threshold + 1, to: threshold - 0.1, phase: .began))
        }
    }

    func testNoFeedbackAwayFromHandoffOrForInvalidSamples() {
        var feedback = DuoHingeFeedback()
        for (from, to): (Double, Double) in [(180, 120), (120, 90), (threshold, 0), (0, 0), (180, 180), (.nan, 0), (180, .infinity)] {
            XCTAssertFalse(feedback.update(from: from, to: to, phase: .changed))
        }
        XCTAssertFalse(feedback.update(from: 180, to: 0, phase: .mayBegin))
        XCTAssertTrue(feedback.update(from: 180, to: 0, phase: []),
            "Magnify events without phase metadata still receive a crossing cue")
    }
}
