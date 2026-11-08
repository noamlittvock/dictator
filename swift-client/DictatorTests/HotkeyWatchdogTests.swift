import Cocoa
import XCTest
@testable import Dictator

/// Covers `HotkeyService`'s modifier watchdog — the local defence against
/// Universal Control delivering a Right Option key-up to the other Mac (or
/// dropping it entirely) when the pointer crosses machines mid-hold. Driven
/// entirely through the internal start/stop methods, `simulatePressForTesting()`,
/// and a fake `modifierStateProbe`; never creates a live CGEvent tap.
final class HotkeyWatchdogTests: XCTestCase {
    private func makeService() -> HotkeyService {
        let service = HotkeyService()
        service.watchdogInterval = 0.02
        return service
    }

    func testFiresOnceAfterTwoConsecutiveNotHeldReads() {
        let service = makeService()
        service.simulatePressForTesting()

        var pollCount = 0
        service.modifierStateProbe = {
            pollCount += 1
            // First poll still reads held (the grace period); every poll
            // after that reads released.
            return pollCount == 1 ? CGEventFlags(rawValue: 0x40) : []
        }

        var receivedReasons: [HotkeyUpReason] = []
        let fired = expectation(description: "watchdog fires")
        service.onStop = { reason in
            receivedReasons.append(reason)
            fired.fulfill()
        }

        service.startModifierWatchdog()
        wait(for: [fired], timeout: 1.0)

        // Give the timer more ticks to prove it fired exactly once, not
        // repeatedly.
        let noExtraCallback = expectation(description: "no extra callback")
        noExtraCallback.isInverted = true
        service.onStop = { _ in noExtraCallback.fulfill() }
        wait(for: [noExtraCallback], timeout: 0.3)

        XCTAssertEqual(receivedReasons, [.modifierWatchdog])
        XCTAssertFalse(service.isPressed)
    }

    func testDoesNotFireWhileProbeReportsHeld() {
        let service = makeService()
        service.simulatePressForTesting()
        service.modifierStateProbe = { CGEventFlags(rawValue: 0x40) }

        let noCallback = expectation(description: "no callback while held")
        noCallback.isInverted = true
        service.onStop = { _ in noCallback.fulfill() }

        service.startModifierWatchdog()
        wait(for: [noCallback], timeout: 0.3)

        XCTAssertTrue(service.isPressed)
        service.stopModifierWatchdog()
    }

    func testStoppingBeforeItFiresProducesNoCallback() {
        let service = makeService()
        service.simulatePressForTesting()
        service.modifierStateProbe = { [] } // always reads "not held"

        let noCallback = expectation(description: "no callback after stop")
        noCallback.isInverted = true
        service.onStop = { _ in noCallback.fulfill() }

        service.startModifierWatchdog()
        service.stopModifierWatchdog()

        wait(for: [noCallback], timeout: 0.3)
    }

    func testSingleNotHeldReadFollowedByHeldDoesNotFire() {
        let service = makeService()
        service.simulatePressForTesting()

        // Alternates not-held, held, not-held, held, ... — never two
        // consecutive not-held reads, so the miss count keeps resetting
        // before it can reach the fire threshold.
        var reportNotHeld = true
        service.modifierStateProbe = {
            defer { reportNotHeld.toggle() }
            return reportNotHeld ? [] : CGEventFlags(rawValue: 0x40)
        }

        let noCallback = expectation(description: "alternating reads never fire")
        noCallback.isInverted = true
        service.onStop = { _ in noCallback.fulfill() }

        service.startModifierWatchdog()
        wait(for: [noCallback], timeout: 0.5)

        XCTAssertTrue(service.isPressed)
        service.stopModifierWatchdog()
    }

    // MARK: Permissions are asked for once, never by the health monitor

    private final class Asked { var input = 0; var accessibility = 0 }

    private func denied(_ asked: Asked, accessibility: Bool = false, input: Bool = false) -> HotkeyService.PermissionAccess {
        HotkeyService.PermissionAccess(
            accessibilityGranted: { accessibility }, inputMonitoringGranted: { input },
            requestAccessibility: { asked.accessibility += 1 }, requestInputMonitoring: { asked.input += 1 })
    }

    private func setFirstStartFlags(prompts: Bool) {
        let saved = (HotkeyService.promptsForMissingPermissionsOnFirstStart, HotkeyService.firstStartRequestUsed)
        HotkeyService.promptsForMissingPermissionsOnFirstStart = prompts
        HotkeyService.firstStartRequestUsed = false
        addTeardownBlock {
            HotkeyService.promptsForMissingPermissionsOnFirstStart = saved.0
            HotkeyService.firstStartRequestUsed = saved.1
        }
    }

    func testHealthTicksNeverAskForPermissionsAgain() {
        setFirstStartFlags(prompts: true)
        do {
            let asked = Asked()
            let service = HotkeyService()
            service.permissions = denied(asked)
            XCTAssertThrowsError(try service.start())
            XCTAssertEqual(asked.input, 1)
            XCTAssertEqual(asked.accessibility, 1)
            for _ in 0..<10 { XCTAssertThrowsError(try service.ensureHealthy()) }
            XCTAssertThrowsError(try service.start(), "a later start doesn't ask either")
            XCTAssertEqual(asked.input, 1)
            XCTAssertEqual(asked.accessibility, 1)
            XCTAssertEqual(service.consecutiveStartFailures, 12)
            XCTAssertEqual(service.mode, .none)
        }
    }

    func testWithTheFirstStartRequestOffOnlyTheExplicitRequestAsks() {
        setFirstStartFlags(prompts: false)
        do {
            let asked = Asked()
            let service = HotkeyService()
            service.permissions = denied(asked)
            XCTAssertThrowsError(try service.start())
            XCTAssertThrowsError(try service.ensureHealthy())
            XCTAssertEqual(asked.input + asked.accessibility, 0)
            let result = HotkeyService.requestMissingPermissions(denied(asked, accessibility: true))
            XCTAssertTrue(result.inputMonitoring)
            XCTAssertFalse(result.accessibility, "only what is missing")
            XCTAssertEqual(asked.input, 1)
            XCTAssertEqual(asked.accessibility, 0)
        }
    }

    func testRepeatedStartFailuresAreLoggedOnAWideningSchedule() {
        XCTAssertEqual((0...20).filter(HotkeyService.shouldLogStartFailure), [1, 2, 4, 8, 16])
    }
}
