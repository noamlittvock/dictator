import XCTest
@testable import Dictator

/// Dictionary replacements happen in exactly one place on every text path.
/// GPT -> Chat GPT is not idempotent, so a second pass shows as Chat Chat GPT.
final class ReplacementOwnerTests: XCTestCase {
    private let dictionary = [["pattern": "GPT", "replacement": "Chat GPT"]]

    /// What the real clean-up does: `CleanupPrompt.job` applies the dictionary
    /// to the words it is given.
    private func aiCleanUp(_ text: String) async -> String {
        CleanupPrompt.job(for: text, dictionary: dictionary, model: "m").prepared
    }

    private func assertOnce(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(text, "I use Chat GPT daily", file: file, line: line)
    }

    func testFinisherWithAICleanUpReplacesOnce() async {
        assertOnce(await TextFinisher.finish("I use GPT daily", dictionary: dictionary, cleanUp: aiCleanUp))
    }

    func testFinisherWithoutAICleanUpReplacesOnce() async {
        assertOnce(await TextFinisher.finish("I use GPT daily", dictionary: dictionary, cleanUp: nil))
    }

    func testLiveRelayedCleanUpAndVoiceCommandSlotsReplaceOnce() async {
        // dictation with relayed clean-up, a shortcut's clean-up slot, and Clean up text all use the finisher
        assertOnce(await TextFinisher.finish("I use GPT daily", dictionary: dictionary, cleanUp: aiCleanUp))
        assertOnce(CleanupPrompt.applyReplacements("I use GPT daily", dictionary: dictionary)) // a plain shortcut slot
    }

    func testRecoveryDirectOnAConnectedMacReplacesOnce() async {
        // raw words -> finishDelegated -> main Mac (which finishes with the finisher)
        let out = await RecoverySpeechPlan.finishDelegated(
            "I use GPT daily", role: .edge, dictionary: dictionary, refineLevel: .medium,
            askMainMac: { text, useAI in
                await TextFinisher.finish(text, dictionary: self.dictionary, cleanUp: useAI ? self.aiCleanUp : nil)
            },
            cleanUp: nil)
        assertOnce(out)
    }

    func testRecoveryOnAMainMacReplacesOnceWithAndWithoutAI() async {
        for level in [RefineLevel.exact, .medium] {
            let out = await RecoverySpeechPlan.finish("I use GPT daily", dictionary: dictionary, refineLevel: level, cleanUp: aiCleanUp)
            assertOnce(out)
        }
    }

    func testMainMacFailureFallbackReplacesOnce() async {
        struct Down: Error {}
        let out = await RecoverySpeechPlan.finishDelegated(
            "I use GPT daily", role: .edge, dictionary: dictionary, refineLevel: .medium,
            askMainMac: { _, _ in throw Down() }, cleanUp: nil)
        assertOnce(out)
    }

    func testEmptyWordsStayEmpty() async {
        let out = await TextFinisher.finish("  ", dictionary: dictionary, cleanUp: aiCleanUp)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespaces), "")
    }
}
