import XCTest
@testable import Dictator

@MainActor
final class BrandVoiceTests: XCTestCase {
    private var savedFirstDictation = false

    override func setUp() async throws {
        try await super.setUp()
        savedFirstDictation = AppSettings.shared.didPassFirstDictation
    }

    override func tearDown() async throws {
        AppSettings.shared.didPassFirstDictation = savedFirstDictation
        try await super.tearDown()
    }

    func testVoiceUsesNoParodyOrInternalRoles() {
        let banned = ["republic", "first order", "senate", "resistance", "galaxy", "galactic", "starkiller",
                      "core", "edge", "brain", "purge", "citizen", "enemy", "traitor",
                      "regime", "decree", "ranks", "fleet", "orders", "gone dark", "deserted",
                      "rehearsal", "in force", "the act", "magic", "seamless", "effortless",
                      "unleash", "supercharge", "ai-powered"]
        for line in BrandVoice.allLines {
            let words = line.lowercased()
            for word in banned {
                XCTAssertNil(words.range(of: "\\b\(word)", options: .regularExpression), "\(word) in “\(line)”")
            }
            XCTAssertFalse(line.contains("!"), "Exclamation mark in “\(line)”")
            XCTAssertFalse(line.contains("—"), "Em dash in “\(line)”")
        }
    }

    func testProcessingSaysWhatIsHappening() {
        XCTAssertEqual(BrandVoice.processing, "Turning speech into text…")
    }

    func testAlertInstructionsAndPlainFailureTitlesStayTheSame() {
        let alerts = [DictationAlert.cancelled(.noAudio), DictationAlert.cancelled(.micLost), EdgeRuntime.cantReachMainMacAlert,
                      EdgeRuntime.cantReachMainMacMissedAlert]
        let titles = ["Nothing was heard", "The microphone stopped while you were talking",
                      "Can’t reach your main Mac", "Can’t reach your main Mac"]
        let details = ["The microphone didn’t pick anything up. Check that the right one is chosen in Settings › General.",
                       "Check the microphone, then retry in History & Privacy. What was recorded is kept there.",
                       "Recording on this Mac so nothing is lost.",
                       "That dictation wasn’t recorded. Try again; it will record on this Mac."]
        let actions: [DictationAlert.Action?] = [.general, .history, nil, nil]
        for index in alerts.indices {
            XCTAssertEqual(alerts[index]?.title, titles[index])
            XCTAssertEqual(alerts[index]?.detail, details[index])
            XCTAssertEqual(alerts[index]?.action, actions[index])
        }
    }

    func testCountdownStaysPlain() {
        XCTAssertEqual(BrandVoice.countdown(3), "Sending in 3 s. Esc to cancel.")
    }

    func testInstructionsStayPlainAndTheVoiceStaysBrief() {
        let instructions: [(String, String)] = [
            (BrandVoice.welcomeIntro, "Hold a key, speak and release. Your words go into the focused app when it allows typing."),
            (BrandVoice.speechReady, "Speech is ready. You can change the model later in Your Macs."),
            (BrandVoice.yourMacsSummary, "See your Macs, their AI models and where each step of dictation runs."),
            (BrandVoice.nothingOn, "No commands on yet. Turn one on to run it by voice."),
            (BrandVoice.howToSayIt, "How to say it"),
            (BrandVoice.noVoiceCommandFits, "No command fits these words. Dictator would copy them to the clipboard and tell you."),
            (BrandVoice.windowsSummary, "Arrange windows on the current desktop by voice, with a click or a keyboard shortcut."),
            (BrandVoice.hideIdle, "Hides apps you haven't used for an hour. They stay open."),
        ]
        for (line, expected) in instructions { XCTAssertEqual(line, expected) }
        let titles: [(String, String)] = [
            (BrandVoice.ready, "Ready to dictate"),
            (BrandVoice.recording, "Recording speech…"),
            (BrandVoice.onNow, "Ready to run"),
            (BrandVoice.previewOnly, "Preview only. No window has moved."),
            (BrandVoice.rememberLayout, "Save this window layout"),
        ]
        for (line, expected) in titles {
            XCTAssertEqual(line, expected)
            XCTAssertLessThanOrEqual(line.count, 100)
        }
    }

    func testFirstDictationMomentShowsOnce() {
        AppSettings.shared.didPassFirstDictation = false
        XCTAssertEqual(BrandVoice.takeFirstDictationMoment()?.title, "Your first dictation is done.")
        XCTAssertNil(BrandVoice.takeFirstDictationMoment())
    }
}
