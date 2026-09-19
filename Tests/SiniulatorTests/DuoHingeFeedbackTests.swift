import AppKit
import XCTest
@testable import Siniulator

final class DuoHingeFeedbackTests: XCTestCase {
    func testClosingAndOpeningPulseAtTheDisplayHandoff() {
        var feedback = DuoHingeFeedback()
        XCTAssertFalse(feedback.update(from: 180, to: 30, phase: .began))
        XCTAssertFalse(feedback.update(from: 30, to: 16, phase: .changed))
        XCTAssertTrue(feedback.update(from: 16, to: 15, phase: .changed))
        XCTAssertFalse(feedback.update(from: 15, to: 0, phase: .changed))
        XCTAssertFalse(feedback.update(from: 0, to: 0, phase: .ended))
        XCTAssertFalse(feedback.update(from: 0, to: 15, phase: .began))
        XCTAssertTrue(feedback.update(from: 15, to: 16, phase: .changed))
        XCTAssertFalse(feedback.update(from: 16, to: 180, phase: .changed))
    }

    func testSlowPinchDoesNotRepeatFeedbackWhenJitteringAcrossThreshold() {
        var feedback = DuoHingeFeedback()
        XCTAssertTrue(feedback.update(from: 16, to: 14.9, phase: .began))
        var previous = 14.9
        for angle in [15.1, 14.8, 15.2, 14.7, 15.3, 15.0] {
            XCTAssertFalse(feedback.update(from: previous, to: angle, phase: .changed))
            previous = angle
        }
        XCTAssertFalse(feedback.update(from: previous, to: 12, phase: .changed))
        XCTAssertTrue(feedback.update(from: 12, to: 16, phase: .changed),
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
            XCTAssertTrue(feedback.update(from: 16, to: 14.9, phase: .began))
            XCTAssertFalse(feedback.update(from: 14.9, to: 16, phase: phase))
            XCTAssertTrue(feedback.update(from: 16, to: 14.9, phase: .began))
        }
    }

    func testNoFeedbackAwayFromHandoffOrForInvalidSamples() {
        var feedback = DuoHingeFeedback()
        for (from, to): (Double, Double) in [(180, 120), (120, 30), (15, 0), (0, 0), (180, 180), (.nan, 0), (180, .infinity)] {
            XCTAssertFalse(feedback.update(from: from, to: to, phase: .changed))
        }
        XCTAssertFalse(feedback.update(from: 180, to: 0, phase: .mayBegin))
        XCTAssertTrue(feedback.update(from: 180, to: 0, phase: []),
            "Magnify events without phase metadata still receive a crossing cue")
    }
}
