import Cocoa
import XCTest
@testable import Dictator

/// Covers `FocusClaimDetector`'s debounce/throttle scheduling with a fake AX
/// probe and a wall-clock-based `clock` scoped to each test (so assertions
/// about "within the first second" mean something), plus `PasteService`'s
/// synthetic-event tagging that the detector's tap-side hook depends on to
/// never claim focus for our own ⌘V paste. Never installs a live CGEvent tap.
final class FocusClaimDetectorTests: XCTestCase {
    /// A `clock` closure the test fully owns: elapsed real seconds since the
    /// test created it. Real time so `queue.asyncAfter` deadlines (computed
    /// from clock deltas inside `FocusClaimDetector`) line up with actual
    /// waits, but injected so each test gets its own zeroed timeline.
    private func makeClock() -> () -> TimeInterval {
        let start = Date()
        return { Date().timeIntervalSince(start) }
    }

    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "focus-claim-test-\(UUID().uuidString)", qos: .utility)
    }

    func testSingleActivityProducesOneProbeAndOneClaim() {
        var probeCallCount = 0
        let detector = FocusClaimDetector(
            probe: { probeCallCount += 1; return .some("com.example.editor") },
            queue: makeQueue(), clock: makeClock(), debounce: 0.02, maxClaimsPerSecond: 4
        )

        let claimed = expectation(description: "claim emitted")
        var claimedBundleId: String?
        detector.onClaim = { bundleId in
            claimedBundleId = bundleId
            claimed.fulfill()
        }

        detector.noteActivity(.click)
        wait(for: [claimed], timeout: 1.0)

        XCTAssertEqual(probeCallCount, 1)
        XCTAssertEqual(claimedBundleId, "com.example.editor")
    }

    func testBurstWithinDebounceCollapsesToOneProbe() {
        var probeCallCount = 0
        let detector = FocusClaimDetector(
            probe: { probeCallCount += 1; return .some("com.example.editor") },
            queue: makeQueue(), clock: makeClock(), debounce: 0.15, maxClaimsPerSecond: 4
        )

        let claimed = expectation(description: "one claim after the burst")
        detector.onClaim = { _ in claimed.fulfill() }

        // 5 activities inside a 50 ms burst, well under the 150 ms debounce,
        // so only the last one's probe should ever fire.
        for _ in 0..<5 {
            detector.noteActivity(.keystroke)
            usleep(10_000) // 10 ms
        }

        wait(for: [claimed], timeout: 1.0)
        XCTAssertEqual(probeCallCount, 1)
    }

    func testNonEditableProbeProducesNoClaim() {
        var probeCallCount = 0
        let detector = FocusClaimDetector(
            probe: { probeCallCount += 1; return nil }, // nothing editable focused
            queue: makeQueue(), clock: makeClock(), debounce: 0.02, maxClaimsPerSecond: 4
        )

        let noClaim = expectation(description: "no claim for a non-editable focus")
        noClaim.isInverted = true
        detector.onClaim = { _ in noClaim.fulfill() }

        detector.noteActivity(.click)
        wait(for: [noClaim], timeout: 0.3)
        XCTAssertEqual(probeCallCount, 1)
    }

    func testThrottleCapsClaimsPerSecondButFinalActivityStillWinsAfterTheWindow() {
        let clock = makeClock()
        let detector = FocusClaimDetector(
            probe: { .some("com.example.editor") },
            queue: makeQueue(), clock: clock, debounce: 0.01, maxClaimsPerSecond: 4
        )

        let lock = NSLock()
        var claimTimes: [TimeInterval] = []
        let finalClaim = expectation(description: "a claim lands after the 1s throttle window")

        detector.onClaim = { _ in
            lock.lock()
            claimTimes.append(clock())
            let count = claimTimes.count
            lock.unlock()
            // 4 immediate claims (spaced by the 20 ms activities below, all
            // inside the first second) plus exactly one delayed claim once
            // the rolling window frees a slot again.
            if count == 5 { finalClaim.fulfill() }
        }

        // 10 activities, spaced 20 ms apart — comfortably longer than the
        // 10 ms debounce, so each schedules its own probe rather than
        // collapsing into the previous one; the throttle is what actually
        // limits how many of them turn into claims within the first second.
        for i in 0..<10 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.02) {
                detector.noteActivity(.keystroke)
            }
        }

        wait(for: [finalClaim], timeout: 2.0)

        lock.lock()
        let times = claimTimes
        lock.unlock()

        let withinFirstSecond = times.filter { $0 < 1.0 }
        XCTAssertLessThanOrEqual(withinFirstSecond.count, 4)
        XCTAssertEqual(times.count, 5)
        XCTAssertGreaterThanOrEqual(times.last ?? 0, 1.0)
    }

    func testResetCancelsAPendingProbe() {
        var probeCallCount = 0
        let detector = FocusClaimDetector(
            probe: { probeCallCount += 1; return .some("com.example.editor") },
            queue: makeQueue(), clock: makeClock(), debounce: 0.3, maxClaimsPerSecond: 4
        )

        let noClaim = expectation(description: "reset cancels the pending probe")
        noClaim.isInverted = true
        detector.onClaim = { _ in noClaim.fulfill() }

        detector.noteActivity(.click)
        // Well before the 300 ms debounce fires.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            detector.reset()
        }

        wait(for: [noClaim], timeout: 0.6)
        XCTAssertEqual(probeCallCount, 0)
    }

    func testSyntheticEventTaggingIsRecognized() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) else {
            XCTFail("could not create test CGEvent")
            return
        }

        XCTAssertFalse(PasteService.isSyntheticEvent(event), "untagged event must not read as synthetic")

        event.setIntegerValueField(.eventSourceUserData, value: PasteService.syntheticEventTag)
        XCTAssertTrue(PasteService.isSyntheticEvent(event), "tagged event must be recognized as our own synthetic paste")
    }
}
