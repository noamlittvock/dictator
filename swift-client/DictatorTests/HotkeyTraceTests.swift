import Cocoa
import XCTest
@testable import Dictator

/// Covers the `DICTATOR_HOTKEY_TRACE` rate limiter and line formatter in
/// isolation, without a live CGEvent tap.
final class HotkeyTraceTests: XCTestCase {
    func testLimiterAllowsUpToFiftyPerSecondThenDrops() {
        var now: TimeInterval = 0
        let limiter = HotkeyTraceLimiter(limit: 50, windowSeconds: 1.0, clock: { now })

        for _ in 0..<50 {
            XCTAssertEqual(limiter.allow(), .allowed)
        }
        XCTAssertEqual(limiter.allow(), .dropped)
        XCTAssertEqual(limiter.allow(), .dropped)
    }

    func testLimiterReportsDroppedCountOnceWhenWindowResets() {
        var now: TimeInterval = 0
        let limiter = HotkeyTraceLimiter(limit: 50, windowSeconds: 1.0, clock: { now })

        for _ in 0..<50 { _ = limiter.allow() }
        for _ in 0..<7 { XCTAssertEqual(limiter.allow(), .dropped) }

        now = 1.0 // window rolls over
        XCTAssertEqual(limiter.allow(), .allowedWithDroppedReport(7))

        // The report fires exactly once; the next call in the same window is
        // a plain allow.
        XCTAssertEqual(limiter.allow(), .allowed)
    }

    func testLimiterWindowResetWithoutDropsIsAPlainAllow() {
        var now: TimeInterval = 0
        let limiter = HotkeyTraceLimiter(limit: 50, windowSeconds: 1.0, clock: { now })

        XCTAssertEqual(limiter.allow(), .allowed)
        now = 2.0
        XCTAssertEqual(limiter.allow(), .allowed)
    }

    func testOrdinaryKeyDownEventsAreNotTraced() {
        XCTAssertFalse(HotkeyService.shouldTrace(type: "keyDown", keyCode: 0))
        XCTAssertFalse(HotkeyService.shouldTrace(type: "keyDown", keyCode: 12))
        XCTAssertTrue(HotkeyService.shouldTrace(type: "keyDown", keyCode: 53)) // Esc
        XCTAssertTrue(HotkeyService.shouldTrace(type: "keyDown", keyCode: 48)) // Tab
        XCTAssertTrue(HotkeyService.shouldTrace(type: "flagsChanged", keyCode: 0))
    }

    func testTestRunsDoNotWriteToTheRealLog() {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dictator").path
        XCTAssertFalse(HotkeyService.diagnosticsPath.path.hasPrefix(real))
    }

    func testDiagnosticsPathCanBeOverriddenAndRotatesAroundOneMegabyte() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotkeyTraceTests-\(UUID().uuidString)")
        let logURL = directory.appendingPathComponent("hotkey.log")
        let rotatedURL = logURL.appendingPathExtension("1")
        let originalPath = HotkeyService.diagnosticsPath
        defer {
            HotkeyService.diagnosticsPath = originalPath
            try? FileManager.default.removeItem(at: directory)
        }

        HotkeyService.diagnosticsPath = logURL
        HotkeyService.recordDiagnostics(String(repeating: "x", count: 999_900))
        HotkeyService.recordDiagnostics(String(repeating: "y", count: 200))

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        let rotated = try String(contentsOf: rotatedURL, encoding: .utf8)
        let current = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(rotated.contains(String(repeating: "x", count: 100)))
        XCTAssertFalse(rotated.contains(String(repeating: "y", count: 100)))
        XCTAssertTrue(current.contains(String(repeating: "y", count: 100)))
    }

    func testTraceLineFormatsFlagsChangedWithRightOptionHeld() {
        let line = HotkeyService.traceLine(
            type: "flagsChanged", keyCode: 61, flags: CGEventFlags(rawValue: 0x40),
            pressed: true, hidDevAlt: true, hidAlt: false, src: 1234
        )
        XCTAssertEqual(
            line,
            "trace type=flagsChanged keyCode=61 flags=0x40 rightOption=1 pressed=1 "
            + "hidRightOption=1 hidDevAlt=1 hidAlt=0 src=1234"
        )
    }

    func testTraceLineFormatsKeyDownWithNoRightOptionAndZeroSrc() {
        let line = HotkeyService.traceLine(
            type: "keyDown", keyCode: 53, flags: [], pressed: false,
            hidDevAlt: false, hidAlt: false, src: 0
        )
        XCTAssertEqual(
            line,
            "trace type=keyDown keyCode=53 flags=0x0 rightOption=0 pressed=0 "
            + "hidRightOption=0 hidDevAlt=0 hidAlt=0 src=0"
        )
    }

    func testTraceLineFallsBackToGenericAlternateMaskOnRightOptionKeyCode() {
        // Keyboards that don't report the 0x40 device bit still register on
        // the right-Option keycode via the generic Alternate mask.
        let line = HotkeyService.traceLine(
            type: "flagsChanged", keyCode: 61, flags: .maskAlternate,
            pressed: true, hidDevAlt: false, hidAlt: true, src: 42
        )
        XCTAssertTrue(line.contains("rightOption=1"))
        XCTAssertTrue(line.contains("hidRightOption=1"))
        XCTAssertTrue(line.contains("hidDevAlt=0"))
        XCTAssertTrue(line.contains("hidAlt=1"))
        XCTAssertTrue(line.contains("src=42"))
    }
}

/// Covers `PointerPresenceThrottle` (the Universal Control initiator/target
/// fix's `mouseMoved` heartbeat gate) in isolation, with an injected clock so
/// nothing here sleeps or touches a live CGEvent tap.
final class PointerPresenceThrottleTests: XCTestCase {
    func testFirstCallAlwaysAllows() {
        var now: TimeInterval = 0
        let throttle = PointerPresenceThrottle(interval: 0.5, clock: { now })
        XCTAssertTrue(throttle.allow())
    }

    func testCallsWithinTheIntervalAreSuppressed() {
        var now: TimeInterval = 0
        let throttle = PointerPresenceThrottle(interval: 0.5, clock: { now })
        XCTAssertTrue(throttle.allow())

        now = 0.1
        XCTAssertFalse(throttle.allow())
        now = 0.49
        XCTAssertFalse(throttle.allow())
    }

    func testCallAtOrAfterTheIntervalAllowsAndResetsTheWindow() {
        var now: TimeInterval = 0
        let throttle = PointerPresenceThrottle(interval: 0.5, clock: { now })
        XCTAssertTrue(throttle.allow())

        now = 0.5
        XCTAssertTrue(throttle.allow())
        // Immediately after, back inside the new window.
        XCTAssertFalse(throttle.allow())

        now = 1.2
        XCTAssertTrue(throttle.allow())
    }

    /// A burst of `mouseMoved` firing hundreds of times a second — as it
    /// does while the pointer is actually being dragged — must still only
    /// let a few heartbeats through per second.
    func testDenseBurstIsCollapsedToAFewHeartbeatsPerSecond() {
        var now: TimeInterval = 0
        let throttle = PointerPresenceThrottle(interval: 0.1, clock: { now })

        var allowedCount = 0
        for i in 0..<1000 {
            now = Double(i) * 0.001 // 1000 calls across 1 simulated second
            if throttle.allow() { allowedCount += 1 }
        }
        // interval 0.1s over ~1s of simulated time: at most ~11 heartbeats.
        XCTAssertLessThanOrEqual(allowedCount, 11)
        XCTAssertGreaterThanOrEqual(allowedCount, 9)
    }
}
