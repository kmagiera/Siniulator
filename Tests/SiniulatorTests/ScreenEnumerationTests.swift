import Foundation
import SimulatorBridge
import XCTest

private final class ScreenAdapterStub: NSObject {
    enum Completion { case immediate, background, held }
    let completion: Completion
    let finished = DispatchSemaphore(value: 0)
    var held: (@Sendable (NSArray) -> Void)?
    init(_ completion: Completion) { self.completion = completion }

    @objc(enumerateScreensWithCompletionQueue:completionHandler:)
    func enumerate(queue: DispatchQueue, handler: @escaping @Sendable (NSArray) -> Void) {
        switch completion {
        case .immediate: handler(["screen"])
        case .background: queue.async { [finished] in handler(["screen"]); finished.signal() }
        case .held: held = handler
        }
    }
}

final class ScreenEnumerationTests: XCTestCase {
    func testCallbackRacingTheDeadlineIsPublishedOrDiscarded() {
        for _ in 0..<1000 {
            let adapter = ScreenAdapterStub(.background)
            let result = SIEnumerateScreens(adapter, 0)
            XCTAssertTrue(result.isEmpty || result as? [String] == ["screen"])
            XCTAssertEqual(adapter.finished.wait(timeout: .now() + 1), .success)
        }
    }

    func testImmediateAndBackgroundCompletionPublishTheResult() {
        for completion in [ScreenAdapterStub.Completion.immediate, .background] {
            XCTAssertEqual(SIEnumerateScreens(ScreenAdapterStub(completion), 1) as? [String], ["screen"])
        }
    }

    func testTimeoutDoesNotConsumeALateCompletionOrPoisonTheNextAttempt() {
        for _ in 0..<100 {
            let adapter = ScreenAdapterStub(.held)
            let result = SIEnumerateScreens(adapter, 0)
            XCTAssertTrue(result.isEmpty)
            // The callback outlives the synchronous wait. Completing it must be
            // safe, must not change the returned result, and must not satisfy a
            // later enumeration's semaphore.
            adapter.held?(["late screen"])
            adapter.held = nil
            XCTAssertTrue(result.isEmpty)
            XCTAssertEqual(SIEnumerateScreens(ScreenAdapterStub(.background), 1) as? [String], ["screen"])
        }
    }
}
