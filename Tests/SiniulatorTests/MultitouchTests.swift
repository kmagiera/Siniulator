import AppKit
import XCTest
@testable import Siniulator

final class MultitouchTests: XCTestCase {
    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, file: file, line: line)
    }

    func testPinchKeepsItsCenterAndMirrorsThePointer() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
        assertPoint(gesture.first, CGPoint(x: 0.3, y: 0.4))
        assertPoint(gesture.second, CGPoint(x: 0.7, y: 0.6))
        gesture.update(pointer: CGPoint(x: 0.2, y: 0.6), translating: false)
        assertPoint(gesture.first, CGPoint(x: 0.2, y: 0.6))
        assertPoint(gesture.second, CGPoint(x: 0.8, y: 0.4))
        assertPoint(gesture.center, CGPoint(x: 0.5, y: 0.5))
    }

    func testEnteringTranslationReanchorsAtTheCurrentPointerWithoutMovingContacts() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
        let first = gesture.first, second = gesture.second, center = gesture.center
        // The cursor may have moved since the last delivered mouse event.
        gesture.update(pointer: CGPoint(x: 0.9, y: 0.8), translating: true)
        assertPoint(gesture.first, first)
        assertPoint(gesture.second, second)
        assertPoint(gesture.center, center)
        gesture.update(pointer: CGPoint(x: 0.95, y: 0.75), translating: true)
        assertPoint(gesture.first, CGPoint(x: 0.35, y: 0.35))
        assertPoint(gesture.second, CGPoint(x: 0.75, y: 0.55))
        assertPoint(gesture.center, CGPoint(x: 0.55, y: 0.45))
    }

    func testLeavingTranslationAtTheBoundaryDoesNotSwapFingers() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: true)
        gesture.update(pointer: CGPoint(x: 1, y: 1), translating: true)
        assertPoint(gesture.first, CGPoint(x: 0.6, y: 0.8))
        assertPoint(gesture.second, CGPoint(x: 1, y: 1))
        gesture.update(pointer: CGPoint(x: 1, y: 1), translating: false)
        assertPoint(gesture.first, CGPoint(x: 0.6, y: 0.8))
        assertPoint(gesture.second, CGPoint(x: 1, y: 1))
        // Dragging outside the view can still pinch inward from this anchor.
        gesture.update(pointer: CGPoint(x: 1.1, y: 1.05), translating: false)
        assertPoint(gesture.first, CGPoint(x: 0.7, y: 0.85))
        assertPoint(gesture.second, CGPoint(x: 0.9, y: 0.95))
        assertPoint(gesture.center, CGPoint(x: 0.8, y: 0.9))
    }

    func testRepeatedShiftTogglesWithoutMouseMovementKeepBothMarkersInPlace() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.2, y: 0.3), translating: false)
        gesture.update(pointer: CGPoint(x: 0.2, y: 0.3), translating: true)
        gesture.update(pointer: CGPoint(x: 0.7, y: 0.7), translating: true)
        let first = gesture.first, second = gesture.second, center = gesture.center
        for _ in 0..<20 {
            gesture.update(pointer: CGPoint(x: 0.7, y: 0.7), translating: false)
            gesture.update(pointer: CGPoint(x: 0.7, y: 0.7), translating: true)
            assertPoint(gesture.first, first)
            assertPoint(gesture.second, second)
            assertPoint(gesture.center, center)
        }
    }

    func testTranslationClampsTheWholePairAndReversesImmediately() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.2, y: 0.3), translating: false)
        gesture.update(pointer: CGPoint(x: 0.2, y: 0.3), translating: true)
        gesture.update(pointer: CGPoint(x: -2, y: 3), translating: true)
        assertPoint(gesture.first, CGPoint(x: 0, y: 0.6))
        assertPoint(gesture.second, CGPoint(x: 0.6, y: 1))
        gesture.update(pointer: CGPoint(x: -1.9, y: 2.9), translating: true)
        assertPoint(gesture.first, CGPoint(x: 0.1, y: 0.5))
        assertPoint(gesture.second, CGPoint(x: 0.7, y: 0.9))
    }

    func testRepeatedPointerEventsDoNotMoveTheContactsAgain() {
        var gesture = MultitouchState()
        let steps: [(CGPoint, Bool)] = [(CGPoint(x: 0.3, y: 0.4), false),
            (CGPoint(x: 0.3, y: 0.4), true), (CGPoint(x: 1, y: 1), true),
            (CGPoint(x: 1, y: 1), false), (CGPoint(x: 1.1, y: 1.05), false)]
        for (pointer, translating) in steps {
            gesture.update(pointer: pointer, translating: translating)
            let first = gesture.first, second = gesture.second, center = gesture.center
            for _ in 0..<5 {
                gesture.update(pointer: pointer, translating: translating)
                assertPoint(gesture.first, first)
                assertPoint(gesture.second, second)
                assertPoint(gesture.center, center)
            }
        }
    }

    func testPinchAroundAnOffCenterOriginKeepsBothContactsInsideTheScreen() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: true)
        gesture.update(pointer: CGPoint(x: 1, y: 1), translating: true)
        gesture.update(pointer: CGPoint(x: 1, y: 1), translating: false)
        gesture.update(pointer: CGPoint(x: 10, y: 10), translating: false)
        assertPoint(gesture.first, CGPoint(x: 1, y: 1))
        assertPoint(gesture.second, CGPoint(x: 0.6, y: 0.8))
        gesture.update(pointer: CGPoint(x: -10, y: -10), translating: false)
        assertPoint(gesture.first, CGPoint(x: 0.6, y: 0.8))
        assertPoint(gesture.second, CGPoint(x: 1, y: 1))
        assertPoint(gesture.center, CGPoint(x: 0.8, y: 0.9))
    }

    func testLongGestureWithModeChangesPreservesSymmetryBoundsAndPanSeparation() {
        var gesture = MultitouchState()
        var seed: UInt64 = 0x51_11_1A_70
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1
            return CGFloat(seed >> 32) / CGFloat(UInt32.max) * 2 - 0.5
        }
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
        var translating = false
        for index in 0..<1000 {
            let first = gesture.first, second = gesture.second, center = gesture.center
            let mode = index % 7 < 3
            gesture.update(pointer: CGPoint(x: next(), y: next()), translating: mode)
            if mode != translating {
                assertPoint(gesture.first, first)
                assertPoint(gesture.second, second)
                assertPoint(gesture.center, center)
            } else if mode {
                assertPoint(CGPoint(x: gesture.second.x - gesture.first.x, y: gesture.second.y - gesture.first.y),
                    CGPoint(x: second.x - first.x, y: second.y - first.y))
            } else { assertPoint(gesture.center, center) }
            for contact in [gesture.first, gesture.second] {
                XCTAssertTrue((-0.000001...1.000001).contains(contact.x))
                XCTAssertTrue((-0.000001...1.000001).contains(contact.y))
            }
            assertPoint(CGPoint(x: (gesture.first.x + gesture.second.x) / 2, y: (gesture.first.y + gesture.second.y) / 2), gesture.center)
            translating = mode
        }
    }

    func testNewPointerSequenceKeepsTheCenterAndDiscardsTheOldTranslationAnchor() {
        var gesture = MultitouchState()
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
        gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: true)
        gesture.update(pointer: CGPoint(x: 0.4, y: 0.5), translating: true)
        let center = gesture.center
        gesture.resetTracking()
        gesture.update(pointer: CGPoint(x: 0.5, y: 0.5), translating: true)
        assertPoint(gesture.center, center)
        assertPoint(gesture.first, CGPoint(x: 0.5, y: 0.5))
        gesture.update(pointer: CGPoint(x: 0.55, y: 0.6), translating: true)
        assertPoint(gesture.center, CGPoint(x: 0.65, y: 0.7))
    }

    func testTranslationPreservesFingerIdentityInEveryDeviceOrientation() {
        for turns in 0..<4 {
            var gesture = MultitouchState()
            gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: false)
            gesture.update(pointer: CGPoint(x: 0.3, y: 0.4), translating: true)
            let first = ScreenGeometry.originalPoint(gesture.first, quarterTurns: turns)
            let second = ScreenGeometry.originalPoint(gesture.second, quarterTurns: turns)
            gesture.update(pointer: CGPoint(x: 0.4, y: 0.45), translating: true)
            let movedFirst = ScreenGeometry.originalPoint(gesture.first, quarterTurns: turns)
            let movedSecond = ScreenGeometry.originalPoint(gesture.second, quarterTurns: turns)
            assertPoint(CGPoint(x: movedFirst.x - first.x, y: movedFirst.y - first.y),
                CGPoint(x: movedSecond.x - second.x, y: movedSecond.y - second.y))
            assertPoint(CGPoint(x: movedSecond.x - movedFirst.x, y: movedSecond.y - movedFirst.y),
                CGPoint(x: second.x - first.x, y: second.y - first.y))
        }
    }

    @MainActor func testModifierEventsIgnoreTheirKeyboardLocationAndMouseEventsKeepQueuedCoordinates() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 400, y: 300, width: 400, height: 800),
            styleMask: .borderless, backing: .buffered, defer: true)
        let view = NSView(frame: CGRect(x: 20, y: 30, width: 300, height: 600))
        window.contentView!.addSubview(view)
        for location in [CGPoint.zero, CGPoint(x: -900, y: 1300), CGPoint(x: 200, y: 300)] {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: location, modifierFlags: [.option, .shift],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
            assertPoint(ScreenGeometry.pointerLocation(for: event, in: view),
                view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        let mouse = NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 80, y: 90), modifierFlags: [.option],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        assertPoint(ScreenGeometry.pointerLocation(for: mouse, in: view), CGPoint(x: 60, y: 60))
    }
}
