import XCTest
@testable import Dictator

/// Recovery's routing and audio preparation, and the paste check for a
/// destination that rewrites what was pasted.
final class RecoveryRoutingTests: XCTestCase {
    private let server = SetupRouting.SpeechSource.server("http://s.example:1")
    private let mine = SetupRouting.SpeechSource.mac("me", model: "whisper")
    private let other = SetupRouting.SpeechSource.mac("main", model: "whisper")

    func testSingleOrMainMacTriesEverySource() {
        for role in [CoreRole.standalone, .core] {
            XCTAssertEqual(
                RecoverySpeechPlan.steps(role: role, sources: [server, mine, other], localEdgeId: "me", connectedToMainMac: false),
                [.sources([server, mine, other])])
        }
    }

    func testConnectedMacKeepsTheConfiguredOrder() {
        XCTAssertEqual(
            RecoverySpeechPlan.steps(role: .edge, sources: [other, mine, server], localEdgeId: "me", connectedToMainMac: true),
            [.mainMac, .sources([mine, server])])
        XCTAssertEqual(
            RecoverySpeechPlan.steps(role: .edge, sources: [server, other, mine], localEdgeId: "me", connectedToMainMac: true),
            [.sources([server]), .mainMac, .sources([mine])])
    }

    /// Whatever the setup, a connected Mac's retry ends with its main Mac, which
    /// may hold a key or reach a server this Mac can't. Never asked twice.
    func testConnectedMacFallsBackToItsMainMacInEverySetup() {
        func steps(_ sources: [SetupRouting.SpeechSource], connected: Bool = true) -> [RecoverySpeechPlan.Step] {
            RecoverySpeechPlan.steps(role: .edge, sources: sources, localEdgeId: "me", connectedToMainMac: connected)
        }
        XCTAssertEqual(steps([server]), [.sources([server]), .mainMac])
        XCTAssertEqual(steps([mine]), [.sources([mine]), .mainMac])
        XCTAssertEqual(steps([server, mine]), [.sources([server, mine]), .mainMac])
        XCTAssertEqual(steps([other]), [.mainMac])
        XCTAssertEqual(steps([other, server]), [.mainMac, .sources([server])])
        XCTAssertEqual(steps([server], connected: false), [.sources([server])])
        XCTAssertEqual(steps([]), [])
    }

    func testMainMacOfflineStillUsesReachableServerAndOwnModel() {
        XCTAssertEqual(
            RecoverySpeechPlan.steps(role: .edge, sources: [other, server, mine], localEdgeId: "me", connectedToMainMac: false),
            [.sources([server, mine])])
        XCTAssertEqual(
            RecoverySpeechPlan.steps(role: .edge, sources: [other], localEdgeId: "me", connectedToMainMac: false), [])
    }

    func testMainMacTextGetsDictionaryAndCleanUp() async {
        let dictionary = [["pattern": "gee pee tee", "replacement": "GPT"]]
        var cleaned: [String] = []
        // Clean-up gets the words as heard and applies the dictionary itself,
        // like `CleanupPrompt.job` does.
        let out = await RecoverySpeechPlan.finish(
            "ask gee pee tee", dictionary: dictionary, refineLevel: .medium,
            cleanUp: {
                cleaned.append($0)
                return CleanupPrompt.job(for: $0, dictionary: dictionary, model: "m").prepared + "."
            })
        XCTAssertEqual(cleaned, ["ask gee pee tee"])
        XCTAssertEqual(out, "ask GPT.")
    }

    func testConnectedMacAsksItsMainMacToCleanUp() async {
        var asked: [(String, Bool)] = []
        var localCalled = false
        let out = await RecoverySpeechPlan.finishDelegated(
            "hello there", role: .edge, dictionary: [], refineLevel: .medium,
            askMainMac: { asked.append(($0, $1)); return "Hello there." },
            cleanUp: { _ in localCalled = true; return "local" })
        XCTAssertEqual(out, "Hello there.")
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].1)
        XCTAssertFalse(localCalled, "a connected Mac must not use its detached local host")
    }

    func testConnectedMacExactLevelAsksWithoutAI() async {
        var useAI: Bool?
        _ = await RecoverySpeechPlan.finishDelegated(
            "x", role: .edge, dictionary: [], refineLevel: .exact,
            askMainMac: { useAI = $1; return $0 }, cleanUp: nil)
        XCTAssertEqual(useAI, false)
    }

    func testConnectedMacFallsBackToDictionaryWhenTheMainMacFails() async {
        struct Down: Error {}
        let out = await RecoverySpeechPlan.finishDelegated(
            "gee pee tee", role: .edge, dictionary: [["pattern": "gee pee tee", "replacement": "GPT"]], refineLevel: .medium,
            askMainMac: { _, _ in throw Down() }, cleanUp: nil)
        XCTAssertEqual(out, "GPT")
    }

    func testNonIdempotentReplacementIsAppliedExactlyOnce() async {
        struct Down: Error {}
        let dictionary = [["pattern": "GPT", "replacement": "Chat GPT"]]
        let viaFallback = await RecoverySpeechPlan.finishDelegated(
            "I use GPT daily", role: .edge, dictionary: dictionary, refineLevel: .exact,
            askMainMac: { _, _ in throw Down() }, cleanUp: nil)
        XCTAssertEqual(viaFallback, "I use Chat GPT daily")
        let local = await RecoverySpeechPlan.finish("I use GPT daily", dictionary: dictionary, refineLevel: .exact, cleanUp: nil)
        XCTAssertEqual(local, "I use Chat GPT daily")
        XCTAssertFalse(viaFallback.contains("Chat Chat GPT"))
    }

    func testOnlyAConnectedMacLeavesFinishingToTheMainMac() {
        XCTAssertFalse(RecoverySpeechPlan.sourcesPostProcess(role: .edge))
        XCTAssertTrue(RecoverySpeechPlan.sourcesPostProcess(role: .core))
        XCTAssertTrue(RecoverySpeechPlan.sourcesPostProcess(role: .standalone))
    }

    func testMainMacItselfCleansUpLocally() async {
        var asked = false
        let out = await RecoverySpeechPlan.finishDelegated(
            "hi", role: .core, dictionary: [], refineLevel: .medium,
            askMainMac: { _, _ in asked = true; return "no" }, cleanUp: { $0 + "!" })
        XCTAssertEqual(out, "hi!")
        XCTAssertFalse(asked)
    }

    func testExactLevelOrNoCleanupModelSkipsCleanUp() async {
        var called = false
        let exact = await RecoverySpeechPlan.finish("hello", dictionary: [], refineLevel: .exact, cleanUp: { _ in called = true; return "x" })
        XCTAssertEqual(exact, "hello")
        XCTAssertFalse(called)
        let none = await RecoverySpeechPlan.finish("hello", dictionary: [], refineLevel: .medium, cleanUp: nil)
        XCTAssertEqual(none, "hello")
    }

    func testOwnModelRunsDirectlyOthersGoThroughTheBroker() {
        XCTAssertTrue(RecoverySpeechPlan.runsOnThisMac(machine: "me", localEdgeId: "me"))
        XCTAssertFalse(RecoverySpeechPlan.runsOnThisMac(machine: "main", localEdgeId: "me"))
    }

    func testDeviceRateAudioIsResampledTo16k() {
        let rate = 48_000
        let samples = (0..<rate).map { Float(sin(2 * Double.pi * 440 * Double($0) / Double(rate))) * 0.5 }
        let audio = CapturedAudio(
            data: samples.withUnsafeBufferPointer { Data(buffer: $0) },
            durationSeconds: 1, sampleRate: rate, frameCount: samples.count)
        let ready = RecoverySpeechPlan.speechReady(audio)
        XCTAssertEqual(ready.sampleRate, 16_000)
        XCTAssertEqual(Double(ready.frameCount), 16_000, accuracy: 200)
        XCTAssertEqual(ready.data.count, ready.frameCount * 4)
        XCTAssertEqual(ready.durationSeconds, 1, accuracy: 0.02)
    }

    func testSixteenKAudioPassesThroughUntouched() {
        let data = [Float](repeating: 0.2, count: 1_600).withUnsafeBufferPointer { Data(buffer: $0) }
        let audio = CapturedAudio(data: data, durationSeconds: 0.1, sampleRate: 16_000, frameCount: 1_600)
        XCTAssertEqual(RecoverySpeechPlan.speechReady(audio).data, data)
    }

    func testDestinationThatRewritesThePasteCountsAsInserted() {
        // Uppercased: not what we expected, but different from before.
        XCTAssertEqual(PasteDecision.insertionState(matchesExpected: false, snapshotValue: "hi ", currentValue: "hi HELLO"), true)
    }

    func testUnchangedFieldReadsFalseAndUnreadableIsUnknown() {
        XCTAssertEqual(PasteDecision.insertionState(matchesExpected: false, snapshotValue: "hi ", currentValue: "hi "), false)
        XCTAssertNil(PasteDecision.insertionState(matchesExpected: false, snapshotValue: "hi ", currentValue: nil))
        XCTAssertEqual(PasteDecision.insertionState(matchesExpected: true, snapshotValue: "a", currentValue: nil), true)
    }
}
