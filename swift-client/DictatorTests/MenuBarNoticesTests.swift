import XCTest
@testable import Dictator

/// The menu stays quiet when all is well, and every problem it shows has a fix.
final class MenuBarNoticesTests: XCTestCase {
    func testAHealthyMacShowsNothing() {
        XCTAssertEqual(MenuBarNotices.make(.init()), [])
    }

    func testAConnectionThatIsFineIsNotMentioned() {
        XCTAssertEqual(MenuBarNotices.make(.init(connection: ("This Mac works on its own.", true))), [])
        XCTAssertEqual(MenuBarNotices.make(.init(connection: ("Connected to Mac mini.", true))), [])
    }

    func testEachPermissionOpensItsOwnPane() {
        func fix(_ message: String) -> MenuBarNotice.Fix? { MenuBarNotices.make(.init(permission: message)).first?.fix }
        XCTAssertEqual(fix("Dictator needs Microphone access."), .privacyPane("Privacy_Microphone"))
        XCTAssertEqual(fix("Dictator needs Input Monitoring."), .privacyPane("Privacy_ListenEvent"))
        XCTAssertEqual(fix("Dictator needs Accessibility."), .privacyPane("Privacy_Accessibility"))
    }

    func testAccessibilityHintKnowsWhetherPermissionArrived() {
        let waiting = MenuBarNotices.make(.init(permission: "Dictator needs Accessibility.", accessibilityGranted: false))
        let granted = MenuBarNotices.make(.init(permission: "Dictator needs Accessibility.", accessibilityGranted: true))
        XCTAssertEqual(waiting.first?.hint, "If Dictator is already listed, remove it and add it again.")
        XCTAssertEqual(granted.first?.hint, "Dictator has permission now. Try again or relaunch.")
    }

    func testMicrophonePermissionHasNoHotkeyHint() {
        XCTAssertNil(MenuBarNotices.make(.init(permission: "Dictator needs Microphone access.")).first?.hint)
    }

    func testProblemsLeadToWhereTheyAreFixed() {
        let notices = MenuBarNotices.make(.init(
            microphone: "No microphone", storage: "Can't save",
            connection: ("Can’t reach Mac mini.", false),
            syncProblem: "Couldn’t update history", cleanupNotSetUp: true, unsavedPlaces: 2
        ))
        XCTAssertEqual(notices.map(\.fix), [.retry, .settings(.history), .settings(.macs), .settings(.macs), .settings(.macs), .settings(.typedApps)])
        XCTAssertEqual(notices.last?.text, "2 places you typed in aren’t kept")
    }

    func testPlacesReadAsOne() {
        XCTAssertEqual(MenuBarNotices.make(.init(unsavedPlaces: 1)).first?.text, "1 place you typed in isn’t kept")
    }

    func testSyncProblemCanBeRetriedOnlyWhenConnected() {
        XCTAssertEqual(MenuBarNotices.make(.init(syncProblem: "Late", syncCanRunNow: true)).first?.fix, .syncNow)
        XCTAssertEqual(MenuBarNotices.make(.init(syncProblem: "Late", syncCanRunNow: false)).first?.fix, .settings(.macs))
    }

    func testInsertionProblemOpensAccessibilityOnlyWhenThatIsTheCause() {
        XCTAssertEqual(MenuBarNotices.make(.init(needsAccessibility: true, insertion: "On the clipboard")).first?.fix, .privacyPane("Privacy_Accessibility"))
        XCTAssertEqual(MenuBarNotices.make(.init(needsAccessibility: false, insertion: "On the clipboard")).first?.fix, .openDictator)
    }

    func testWhatStopsDictationComesFirst() {
        let notices = MenuBarNotices.make(.init(permission: "Dictator needs Accessibility.", connection: ("Can’t reach Mac mini.", false), unsavedPlaces: 1))
        XCTAssertEqual(notices.first?.symbol, "lock")
        XCTAssertEqual(notices.last?.symbol, "keyboard")
    }

    func testMenuOffersTheLevelsInDialOrder() {
        XCTAssertEqual(RefineLevel.allCases.map(\.title), ["Skip AI clean-up", "Clean up the text", "Polish the text"])
    }

    func testSidebarFollowsTheChosenOrder() {
        XCTAssertEqual(SidebarItem.allCases.map(\.title), ["Home", "Commands", "Workspaces", "Dictionary", "Datasets", "Settings", "Help"])
    }
}
