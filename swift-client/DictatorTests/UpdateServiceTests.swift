import XCTest
@testable import Dictator

@MainActor
final class UpdateServiceTests: XCTestCase {
    private final class Driver: UpdateDriver {
        var automaticallyChecksForUpdates = true
        var canCheckForUpdates = true
        var starts = 0
        var checks = 0
        var fails = false
        func start() throws {
            starts += 1
            if fails { throw NSError(domain: "UpdateServiceTests", code: 1) }
        }
        func checkForUpdates() { checks += 1 }
    }

    func testMissingKeyNeverCreatesUpdaterAndHidesBothControls() {
        for key in [nil, "", " \n\t", "$(DICTATOR_SPARKLE_PUBLIC_KEY)"] as [String?] {
            var creations = 0
            let service = UpdateService(publicKey: key, makeUpdater: {
                creations += 1
                return Driver()
            })
            // Both the menu item and General toggle use this exact gate.
            XCTAssertFalse(service.isActive)
            service.checkForUpdates()
            service.automaticallyChecksForUpdates = true
            XCTAssertEqual(creations, 0)
        }
    }

    func testConfiguredKeyStartsUpdaterAndShowsControls() {
        let driver = Driver()
        let service = UpdateService(publicKey: "fixture-public-key", makeUpdater: { driver })
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(service.automaticallyChecksForUpdates)
        service.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        driver.canCheckForUpdates = false
        service.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
    }

    func testAutomaticChoiceUsesDriverPreferenceAndManualChecksStillWork() {
        let first = Driver(), otherMac = Driver()
        first.automaticallyChecksForUpdates = false
        let service = UpdateService(publicKey: "fixture-public-key", makeUpdater: { first })
        XCTAssertFalse(service.automaticallyChecksForUpdates)
        service.checkForUpdates()
        XCTAssertEqual(first.checks, 1)
        service.automaticallyChecksForUpdates = true
        XCTAssertTrue(first.automaticallyChecksForUpdates)
        service.automaticallyChecksForUpdates = false
        XCTAssertTrue(otherMac.automaticallyChecksForUpdates)
        let reopened = UpdateService(publicKey: "fixture-public-key", makeUpdater: { first })
        XCTAssertFalse(reopened.automaticallyChecksForUpdates)
        XCTAssertTrue(reopened.isActive)
    }

    func testFailedStartHidesControlsAndDoesNotCheck() {
        let driver = Driver()
        driver.fails = true
        let service = UpdateService(publicKey: "fixture-public-key", makeUpdater: { driver })
        XCTAssertFalse(service.isActive)
        service.checkForUpdates()
        XCTAssertEqual(driver.checks, 0)
    }
}
