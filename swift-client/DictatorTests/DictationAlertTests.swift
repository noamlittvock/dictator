import XCTest
@testable import Dictator

/// What the user is told when a dictation doesn't produce text.
final class DictationAlertTests: XCTestCase {
    func testFailureTravelsThroughTheOutcomeAndBack() {
        let alert = DictationAlert(title: "Can’t reach Mac mini", detail: "Check that it’s on.", action: .macs)
        XCTAssertEqual(DictationAlert.decode(failure: DictationFailure(alert).localizedDescription), alert)
    }

    func testAPlainMessageFromAnOlderMacStillReads() {
        let alert = DictationAlert.decode(failure: "Server error 500: boom")
        XCTAssertEqual(alert.title, "Dictation didn’t work")
        XCTAssertEqual(alert.detail, "Server error 500: boom")
        XCTAssertNil(alert.action)
    }

    func testCancellationsExplainThemselves() {
        XCTAssertNil(DictationAlert.cancelled(.user), "pressing Esc isn't an error")
        XCTAssertEqual(DictationAlert.cancelled(.noAudio)?.title, BrandVoice.nothingHeard)
        XCTAssertEqual(DictationAlert.cancelled(.micLost)?.action, .history)
        XCTAssertEqual(DictationAlert.cancelled(.initiatorLost)?.title, "Lost the connection to your other Mac")
    }

    func testClipboardFallbackSaysWhereTheTextIs() {
        XCTAssertEqual(DictationAlert.clipboardOnly(reason: "x", needsAccessibility: true).action, .accessibilityPrivacy)
        XCTAssertTrue(DictationAlert.clipboardOnly(reason: "x", needsAccessibility: false).detail.contains("⌘V"))
    }
}


extension DictationAlertTests {
    @MainActor
    func testVoiceCommandTieNamesChoicesAndOpensVoiceLaunch() {
        let alert = DictationAlert.voiceCommandTie(heard: "Open Safari", names: ["Work", "Browse"])
        XCTAssertEqual(alert.title, "More than one command fits “Open Safari”")
        XCTAssertTrue(alert.detail.contains("“Work”, “Browse”"))
        XCTAssertTrue(alert.detail.contains("Turn one off or change what you say"))
        XCTAssertTrue(alert.detail.contains("Your words are on the clipboard."))
        XCTAssertEqual(alert.action?.title, "Open Commands")
        XCTAssertEqual(DictationAlert.decode(failure: alert.encoded).action, .voiceLaunch)
        let navigation = AppNavigation.shared
        let savedSelection = navigation.mainSelection
        let savedRequests = navigation.mainWindowRequests
        defer { navigation.mainSelection = savedSelection; navigation.mainWindowRequests = savedRequests }
        alert.perform()
        XCTAssertEqual(navigation.mainSelection, .voiceLaunch)
        XCTAssertEqual(navigation.mainWindowRequests, savedRequests + 1)
        XCTAssertEqual(SidebarItem.workspaceLaunch.title, "Workspaces")
    }
}

extension DictationAlertTests {
    func testRemoteLiveSpeechKeyAlertNamesMainMacWithoutOpeningLocalSettings() throws {
        for name in [String?.none, "Mac mini"] {
            let alert = try XCTUnwrap(DictationAlert.speechConfigurationFailure(
                TranscriptionError.authenticationRequired, requestFromOtherMac: true, mainMacName: name))
            XCTAssertNil(alert.action)
            XCTAssertTrue(alert.detail.contains("Settings › Advanced on the main Mac"))
            if let name { XCTAssertTrue(alert.detail.contains(name)) }
            XCTAssertEqual(DictationAlert.decode(failure: alert.encoded), alert)
        }
    }

    func testKeyAlertSaysWhereTheKeyComesFromInAnySetup() throws {
        let auth = TranscriptionError.authenticationRequired
        let named = try XCTUnwrap(DictationAlert.speechConfigurationFailure(auth, serverMacName: "Studio"))
        XCTAssertTrue(named.detail.contains("Settings › Advanced on Studio"), named.detail)
        let unknown = try XCTUnwrap(DictationAlert.speechConfigurationFailure(auth))
        XCTAssertTrue(unknown.detail.contains("the Mac that runs the speech server"), unknown.detail)
        let cutOff = try XCTUnwrap(DictationAlert.speechConfigurationFailure(auth, serverMacName: "Studio", canReconnect: true))
        XCTAssertTrue(cutOff.detail.hasPrefix("Reconnect this Mac to your main Mac"), cutOff.detail)
        let relayed = try XCTUnwrap(DictationAlert.speechConfigurationFailure(
            auth, requestFromOtherMac: true, mainMacName: "Tower", serverMacName: "Studio"))
        XCTAssertTrue(relayed.detail.contains("on Studio"), relayed.detail)
        XCTAssertTrue(relayed.detail.contains("the main Mac (Tower)"), relayed.detail)
    }

    func testLocalStandaloneAndDirectRecoveryKeepKeySettingsButton() throws {
        let alert = try XCTUnwrap(DictationAlert.speechConfigurationFailure(TranscriptionError.authenticationRequired))
        XCTAssertEqual(alert.action, .advanced)
        XCTAssertFalse(alert.detail.contains("on the main Mac"))
        let delegatedRecovery = try XCTUnwrap(DictationAlert.speechConfigurationFailure(RepositoryError.unavailable(alert.encoded)))
        XCTAssertEqual(delegatedRecovery.action, .advanced)
    }
}
