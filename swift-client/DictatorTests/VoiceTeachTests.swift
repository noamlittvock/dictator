import XCTest
@testable import Dictator

/// Teach and one-click aliases. Synthetic only: no microphone, no speech.
@MainActor
final class VoiceTeachTests: XCTestCase {
    // MARK: Fixtures

    private let people = VoiceList(id: "people", name: "People", fields: ["phone"], entries: [
        VoiceListEntry(id: "noam", names: ["Noam"], values: ["phone": "1"]),
        VoiceListEntry(id: "dana", names: ["Dana", "Danny"], values: ["phone": "2"]),
        VoiceListEntry(id: "nora", names: ["Nora"], values: ["phone": "3"]),
        VoiceListEntry(id: "omer", names: ["Omer"], values: ["phone": "4"]),
    ])

    private func whatsapp(_ aliases: [String] = []) -> VoiceCommand {
        VoiceCommand(id: "wa", name: "WhatsApp", pattern: "WhatsApp {person:People} {message}",
                            steps: [VoiceStep(kind: .typeText, text: "{message}")], triggerAliases: aliases)
    }

    private func search(_ aliases: [String] = []) -> VoiceCommand {
        VoiceCommand(id: "yt", name: "YouTube", pattern: "YouTube {query}",
                            steps: [VoiceStep(kind: .typeText, text: "{query}")], triggerAliases: aliases)
    }

    private func config(_ commands: [VoiceCommand]) -> VoiceLaunchConfig {
        VoiceLaunchConfig(lists: [people], commands: commands)
    }

    private func planName(_ result: PlanResult) -> String? {
        if case .plan(let plan) = result { return plan.commandName }
        return nil
    }

    // MARK: Trigger aliases

    func testTriggerAliasMatchesExactlyAndScoresLikeTheTrigger() {
        let cfg = config([search(["you tube", "utube"])])
        XCTAssertEqual(planName(VoiceLaunchEngine.plan(for: "utube cute cats", in: cfg)), "YouTube")
        XCTAssertEqual(planName(VoiceLaunchEngine.plan(for: "You tube, cute cats", in: cfg)), "YouTube")
        XCTAssertEqual(planName(VoiceLaunchEngine.plan(for: "YouTube cute cats", in: cfg)), "YouTube")
        // Never fuzzy: a near spelling that isn't saved does not match.
        if case .plan = VoiceLaunchEngine.plan(for: "utub cute cats", in: cfg) { XCTFail("fuzzy match") }
    }

    func testTriggerAliasTextFillsTheRestOfThePattern() throws {
        let cfg = config([whatsapp(["what's up"])])
        // "what's up" normalizes to two words, "whats up".
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "What's up Nora running late", in: cfg) else {
            return XCTFail("the alias should match")
        }
        XCTAssertEqual(plan.mainText, "running late")
        XCTAssertEqual(plan.slots.first?.value, "Nora")
        // The same letters joined still match; a different spelling does not.
        if case .plan = VoiceLaunchEngine.plan(for: "whatsup Nora running late", in: cfg) {} else { XCTFail("joined alias should match") }
        if case .plan = VoiceLaunchEngine.plan(for: "wassup Nora running late", in: cfg) { XCTFail("a different spelling is not the alias") }
    }

    func testTriggerAliasesAreHintedToTheRecognizer() {
        XCTAssertTrue(VoiceLaunchEngine.hintWords(config([search(["utube"])])).contains("utube"))
    }

    func testOldJSONWithoutTriggerAliasesDecodesAndStaysCompact() throws {
        let old = """
        {"version":2,"lists":[],"shortcuts":[{"id":"s","name":"YouTube","pattern":"YouTube {query}","enabled":true,\
        "steps":[{"id":"a","kind":"typeText","text":"{query}"}]}]}
        """
        let decoded = try XCTUnwrap(VoiceLaunchConfig.decode(old))
        XCTAssertEqual(decoded.commands[0].triggerAliases, [])
        XCTAssertFalse(decoded.encoded().contains("triggerAliases"))
        var withAlias = decoded
        withAlias.commands[0].triggerAliases = ["utube"]
        XCTAssertEqual(VoiceLaunchConfig.decode(withAlias.encoded()), withAlias)
    }

    // MARK: Alias conflicts

    func testTriggerAliasMayNotBeAnotherVoiceCommandsTriggerOrAlias() {
        var cfg = config([whatsapp(), search(["utube"])])
        XCTAssertNil(cfg.validate(allowedSchemes: ["https"]))
        cfg.commands[0].triggerAliases = ["YouTube"]
        XCTAssertNotNil(cfg.validate(allowedSchemes: ["https"]))
        cfg.commands[0].triggerAliases = ["U tube", "utube"]
        XCTAssertNotNil(cfg.validate(allowedSchemes: ["https"]))
        cfg.commands[0].triggerAliases = ["whats app"]
        XCTAssertNil(cfg.validate(allowedSchemes: ["https"]))
        cfg.commands[0].triggerAliases = ["  "]
        XCTAssertNotNil(cfg.validate(allowedSchemes: ["https"]))
    }

    func testAddTriggerAliasRefusesConflictsAndRepeats() {
        var cfg = config([whatsapp(), search()])
        XCTAssertEqual(cfg.addTriggerAlias("youtube", toVoiceCommand: "wa"), .takenByVoiceCommand("YouTube"))
        XCTAssertNil(cfg.addTriggerAlias("whats app", toVoiceCommand: "wa"))
        XCTAssertEqual(cfg.addTriggerAlias("Whats App", toVoiceCommand: "wa"), .alreadyKnown)
        XCTAssertEqual(cfg.addTriggerAlias("whatsapp", toVoiceCommand: "wa"), .alreadyKnown)
        XCTAssertEqual(cfg.commands[0].triggerAliases, ["whats app"])
    }

    func testEntryAliasConflictsAreOnlyWithinTheSameList() {
        var cfg = config([whatsapp()])
        XCTAssertEqual(cfg.addEntryAlias("nora", listId: "people", entryId: "noam"), .takenByEntry("Nora"))
        XCTAssertEqual(cfg.addEntryAlias("Danny", listId: "people", entryId: "noam"), .takenByEntry("Dana"))
        XCTAssertEqual(cfg.addEntryAlias("noam", listId: "people", entryId: "noam"), .alreadyKnown)
        XCTAssertNil(cfg.addEntryAlias("norm", listId: "people", entryId: "noam"))
        XCTAssertEqual(cfg.lists[0].entries[0].names, ["Noam", "norm"])
        XCTAssertEqual(cfg.addEntryAlias("norm", listId: "people", entryId: "dana"), .takenByEntry("Noam"))
    }

    // MARK: Near miss

    func testEntryNearMissReportsVoiceCommandSlotHeardWordsAndCandidates() throws {
        let cfg = config([whatsapp()])
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "WhatsApp norm I'll be late", in: cfg) else {
            return XCTFail("expected a near miss")
        }
        XCTAssertEqual(miss.kind, .entry)
        XCTAssertEqual(miss.commandId, "wa")
        XCTAssertEqual(miss.slotName, "person")
        XCTAssertEqual(miss.listId, "people")
        // A text slot follows the name, so the name may be one or two words.
        XCTAssertEqual(miss.heardSpans, ["norm", "norm I'll"])
        XCTAssertEqual(miss.candidates.map(\.name), ["Noam", "Nora", "Dana"])
        XCTAssertEqual(miss.transcript, "WhatsApp norm I'll be late")
    }

    func testNearMissSpanIsOneWordWhenNothingFollowsAndUpToTheNextFixedWord() {
        let tail = VoiceCommand(id: "call", name: "Call", pattern: "Call {person:People}", steps: [VoiceStep(kind: .typeText, text: "x")])
        guard case .nearMiss(let end) = VoiceLaunchEngine.plan(for: "Call norm", in: config([tail])) else { return XCTFail() }
        XCTAssertEqual(end.heardSpans, ["norm"])
        let marked = VoiceCommand(id: "tell", name: "Tell", pattern: "Tell {person:People} that {message}", steps: [VoiceStep(kind: .typeText, text: "x")])
        guard case .nearMiss(let mid) = VoiceLaunchEngine.plan(for: "Tell no arm that hi", in: config([marked])) else { return XCTFail() }
        XCTAssertEqual(mid.heardSpans, ["no arm"])
    }

    func testTriggerNearMissWhenNoVoiceCommandStartsTheWords() {
        let cfg = config([whatsapp(), search()])
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "Whatsap Noam hi", in: cfg) else { return XCTFail() }
        XCTAssertEqual(miss.kind, .trigger)
        XCTAssertEqual(miss.heardTrigger, "Whatsap")
        let wa = whatsapp()
        XCTAssertEqual(VoiceLaunchEngine.triggerAliasCandidate(miss, for: wa), "whatsap")
        // A two-word trigger takes two words.
        let long = VoiceCommand(id: "open", name: "Open notes", pattern: "open my notes", steps: [VoiceStep(kind: .typeText, text: "x")])
        guard case .nearMiss(let two) = VoiceLaunchEngine.plan(for: "Oh pen my notes", in: config([long])) else { return XCTFail() }
        XCTAssertEqual(two.heardTrigger, "Oh pen")
        XCTAssertEqual(VoiceLaunchEngine.triggerAliasCandidate(two, for: long), "oh pen my")
    }

    func testNoNearMissWhenNothingSaidOrNoVoiceCommandsOrAMatch() {
        XCTAssertEqual(VoiceLaunchEngine.plan(for: "", in: config([whatsapp()])), .noMatch(.nothingSaid))
        XCTAssertEqual(VoiceLaunchEngine.plan(for: "hello", in: config([])), .noMatch(.noCommands))
        XCTAssertNotNil(planName(VoiceLaunchEngine.plan(for: "WhatsApp Noam hi", in: config([whatsapp()]))))
        // A list with no entries has nobody to suggest.
        let empty = VoiceLaunchConfig(lists: [VoiceList(id: "people", name: "People")], commands: [whatsapp()])
        if case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "WhatsApp norm hi", in: empty) { XCTAssertEqual(miss.kind, .trigger) }
    }

    func testCandidatesAreOrderedByEditDistanceThenListOrder() {
        let ranked = VoiceLaunchEngine.rankedEntries(heard: "norm", in: people)
        XCTAssertEqual(ranked.map(\.name), ["Noam", "Nora", "Dana", "Omer"])
        XCTAssertEqual(VoiceLaunchEngine.rankedEntries(heard: "Danni", in: people, limit: 1).map(\.name), ["Dana"])
        XCTAssertEqual(VoiceLaunchText.editDistance("norm", "noam"), 1)
        XCTAssertEqual(VoiceLaunchText.editDistance("", "abc"), 3)
    }

    func testChoosingAnEntryAddsTheAliasAndPlansTheSameWordsAgain() throws {
        let cfg = config([whatsapp()])
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "WhatsApp norm I'll be late", in: cfg) else { return XCTFail() }
        let fix = try XCTUnwrap(try? VoiceNearMissFix.fixEntry(miss, span: 0, entryId: "noam", in: cfg).get())
        XCTAssertEqual(fix.config.lists[0].entries[0].names, ["Noam", "norm"])
        guard case .plan(let plan) = fix.result else { return XCTFail("should run now") }
        XCTAssertEqual(plan.commandName, "WhatsApp")
        XCTAssertEqual(plan.slots.first?.value, "Noam")
        XCTAssertEqual(plan.mainText, "I'll be late")
    }

    func testTwoWordSpanSavesTwoWordsAndConflictsAreRefused() throws {
        let cfg = config([whatsapp()])
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "WhatsApp know am I'll be late", in: cfg) else { return XCTFail() }
        XCTAssertEqual(miss.heardSpans, ["know", "know am"])
        let fix = try VoiceNearMissFix.fixEntry(miss, span: 1, entryId: "noam", in: cfg).get()
        XCTAssertEqual(fix.config.lists[0].entries[0].names, ["Noam", "know am"])
        guard case .plan(let plan) = fix.result else { return XCTFail() }
        XCTAssertEqual(plan.mainText, "I'll be late")

        var taken = cfg
        taken.addEntryAlias("know", listId: "people", entryId: "omer")
        if case .success = VoiceNearMissFix.fixEntry(miss, span: 0, entryId: "noam", in: taken) { XCTFail("conflict must be refused") }
    }

    func testChoosingAVoiceCommandAddsATriggerAliasWithoutRunning() throws {
        let cfg = config([whatsapp(), search()])
        guard case .nearMiss(let miss) = VoiceLaunchEngine.plan(for: "Whatsap Noam hi", in: cfg) else { return XCTFail() }
        let updated = try VoiceNearMissFix.fixTrigger(miss, commandId: "wa", in: cfg).get()
        XCTAssertEqual(updated.commands[0].triggerAliases, ["whatsap"])
        XCTAssertNotNil(planName(VoiceLaunchEngine.plan(for: "Whatsap Noam hi", in: updated)))
        // Can't take another shortcut's own trigger.
        let clash = VoiceNearMiss(kind: .trigger, transcript: "YouTube hi", heardTrigger: "YouTube")
        if case .success = VoiceNearMissFix.fixTrigger(clash, commandId: "wa", in: cfg) { XCTFail("conflict must be refused") }
    }

    func testTryItShowsTheNearMiss() {
        if case .nearMiss(let miss) = VoiceTryItResult.result(for: "WhatsApp norm hi", in: config([whatsapp()])) {
            XCTAssertEqual(miss.kind, .entry)
        } else { XCTFail() }
    }

    // MARK: Teach extraction

    func testPhraseUsesARealVoiceCommandPhraseOrJustTheName() {
        let cfg = config([search(), whatsapp()])
        let noam = people.entries[0]
        let phrase = VoiceTeach.phrase(for: noam, in: people, config: cfg)
        XCTAssertEqual(phrase.text, "WhatsApp Noam")
        XCTAssertEqual(phrase.leadingWords, ["WhatsApp"])
        XCTAssertEqual(VoiceTeach.phrase(for: noam, in: people, config: config([search()])), VoiceTeachPhrase(text: "Noam", leadingWords: []))
        XCTAssertEqual(VoiceTeach.phrase(forTrigger: search()), VoiceTeachPhrase(text: "YouTube", leadingWords: ["YouTube"]))
    }

    func testExtractionWhenTheFixedWordsWereHeardIsTheWordsAtTheNamesPlace() {
        let phrase = VoiceTeachPhrase(text: "WhatsApp Noam", leadingWords: ["WhatsApp"])
        XCTAssertEqual(VoiceTeach.heardForEntry("WhatsApp norm.", phrase: phrase), .alias("norm"))
        XCTAssertEqual(VoiceTeach.heardForEntry("whatsapp no arm", phrase: phrase), .alias("no arm"))
        XCTAssertEqual(VoiceTeach.heardForEntry("", phrase: phrase), .nothing)
        XCTAssertEqual(VoiceTeach.heardForEntry("Norm", phrase: VoiceTeachPhrase(text: "Noam", leadingWords: [])), .alias("norm"))
    }

    func testExtractionWhenTheFixedWordsWereMisheardAsksWhichWordsAreTheName() {
        let phrase = VoiceTeachPhrase(text: "WhatsApp Noam", leadingWords: ["WhatsApp"])
        XCTAssertEqual(VoiceTeach.heardForEntry("What's up norm", phrase: phrase), .chooseWords(["what's", "up", "norm"]))
        XCTAssertEqual(VoiceTeach.heardForEntry("WhatsApp", phrase: phrase), .chooseWords(["whatsapp"]))
        XCTAssertEqual(VoiceTeach.alias(from: ["what's", "up", "norm"], selected: [2]), "norm")
        XCTAssertEqual(VoiceTeach.alias(from: ["a", "b", "c"], selected: [2, 0]), "a c")
    }

    func testTriggerExtractionIsTheWholeHeardText() {
        XCTAssertEqual(VoiceTeach.heardForTrigger("You tube."), .alias("you tube"))
        XCTAssertEqual(VoiceTeach.heardForTrigger("  "), .nothing)
    }

    func testCandidatesMergeRepeatsAndMarkNamesAndConflicts() {
        let target = VoiceTeachTarget.entry(list: people, entryId: "noam")
        let found = VoiceTeach.candidates(from: ["norm", "Norm", "noam", "nora", "no arm"], target: target)
        XCTAssertEqual(found.map(\.alias), ["norm", "noam", "nora", "no arm"])
        XCTAssertEqual(found.map(\.status), [.fresh, .sameAsName, .conflict(.takenByEntry("Nora")), .fresh])

        let triggerTarget = VoiceTeachTarget.trigger(commandId: "wa", commands: [whatsapp(), search(["utube"])])
        let triggers = VoiceTeach.candidates(from: ["whats app", "utube", "WhatsApp"], target: triggerTarget)
        XCTAssertEqual(triggers.map(\.status), [.fresh, .conflict(.takenByVoiceCommand("YouTube")), .sameAsName])
    }

    // MARK: Recording

    func testEndpointerStopsAfterTwoSecondsOfQuietOrSixSeconds() {
        var quietAfter = VoiceTeachEndpointer()
        XCTAssertEqual(quietAfter.silenceSeconds, 2.0)
        XCTAssertEqual(quietAfter.maxSeconds, 6.0)
        XCTAssertFalse(quietAfter.feed(level: 0.0, at: 0))      // waiting for speech
        XCTAssertFalse(quietAfter.feed(level: 0.3, at: 0.5))
        XCTAssertFalse(quietAfter.feed(level: 0.01, at: 1.6))   // 1.1 s of quiet: not yet
        XCTAssertFalse(quietAfter.feed(level: 0.01, at: 2.4))
        XCTAssertTrue(quietAfter.feed(level: 0.01, at: 2.5))    // 2.0 s since the last voice
        var cap = VoiceTeachEndpointer()
        for t in stride(from: 0.0, to: 6.0, by: 0.5) { XCTAssertFalse(cap.feed(level: 0.3, at: t)) }
        XCTAssertTrue(cap.feed(level: 0.3, at: 6.0))
        var silent = VoiceTeachEndpointer()
        XCTAssertFalse(silent.feed(level: 0, at: 0))
        XCTAssertFalse(silent.feed(level: 0, at: 5.9))
        XCTAssertTrue(silent.feed(level: 0, at: 6.1))
    }

    func testEndpointerSilenceProgressRunsAndResetsWhenSpeechResumes() {
        var e = VoiceTeachEndpointer()
        XCTAssertNil(e.silenceProgress)
        _ = e.feed(level: 0, at: 0)
        XCTAssertNil(e.silenceProgress)                          // nobody has spoken yet
        _ = e.feed(level: 0.3, at: 1.0)
        XCTAssertNil(e.silenceProgress)                          // speaking
        _ = e.feed(level: 0.01, at: 1.3)
        XCTAssertNil(e.silenceProgress)                          // a short pause: no countdown
        _ = e.feed(level: 0.01, at: 2.0)
        XCTAssertEqual(try XCTUnwrap(e.silenceProgress), 0.5, accuracy: 0.001)
        _ = e.feed(level: 0.01, at: 2.5)
        XCTAssertEqual(try XCTUnwrap(e.silenceProgress), 0.75, accuracy: 0.001)
        _ = e.feed(level: 0.3, at: 2.6)                          // speech resumes
        XCTAssertNil(e.silenceProgress)
        _ = e.feed(level: 0.01, at: 3.6)
        XCTAssertEqual(try XCTUnwrap(e.silenceProgress), 0.5, accuracy: 0.001) // counting again from 0
        XCTAssertTrue(e.feed(level: 0.01, at: 4.7))
        XCTAssertEqual(try XCTUnwrap(e.silenceProgress), 1.0, accuracy: 0.001)
    }

    func testEndpointerReportsWhatIsLeftOfTheSixSecondCap() {
        var e = VoiceTeachEndpointer()
        XCTAssertEqual(e.secondsLeft, 6.0)
        _ = e.feed(level: 0.3, at: 10)
        XCTAssertEqual(e.secondsLeft, 6.0, accuracy: 0.001)
        _ = e.feed(level: 0.3, at: 14.5)
        XCTAssertEqual(e.secondsLeft, 1.5, accuracy: 0.001)
        XCTAssertTrue(e.feed(level: 0.3, at: 16))
        XCTAssertEqual(e.secondsLeft, 0, accuracy: 0.001)
    }

    @MainActor private final class FakeRecorder: VoiceTeachRecording {
        var teachLevelObserver: ((Float) -> Void)?
        var began = 0
        var ended = 0
        var busy = false
        func beginTeachRecording() -> Bool { began += 1; return !busy }
        func endTeachRecording() -> CapturedAudio? {
            ended += 1
            return CapturedAudio(data: Data(count: 16_000 * 4), durationSeconds: 1, sampleRate: 16_000, frameCount: 16_000)
        }
        func cancelTeachRecording() {}
    }

    func testSessionRecordsFourTakesThroughTheSpeechPathAndDiscardsAudio() async throws {
        let service = VoiceTeachService()
        let recorder = FakeRecorder()
        service.recorder = recorder
        var heard = ["WhatsApp norm", "WhatsApp norm.", "WhatsApp Noam", "What's up norm"]
        var audioSizes: [Int] = []
        service.transcribe = { audio in audioSizes.append(audio.data.count); return heard.removeFirst() }
        let session = VoiceTeachSession(service: service)
        var now: TimeInterval = 0
        session.clock = { now += 2; return now }   // every level is "two seconds later"

        for _ in 0..<VoiceTeach.takeCount {
            let take = Task { await session.record() }
            for _ in 0..<50 where recorder.teachLevelObserver == nil { await Task.yield() }
            recorder.teachLevelObserver?(0.3)
            recorder.teachLevelObserver?(0.0)           // >= 2 s of quiet after speech ends the take
            await take.value
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.transcripts, ["WhatsApp norm", "WhatsApp norm.", "WhatsApp Noam", "What's up norm"])
        XCTAssertEqual(recorder.began, 4)
        XCTAssertEqual(recorder.ended, 4)
        XCTAssertEqual(audioSizes, [64_000, 64_000, 64_000, 64_000])
        XCTAssertNil(recorder.teachLevelObserver)
        // A fifth take is ignored.
        await session.record()
        XCTAssertEqual(recorder.began, 4)
    }

    func testSessionExplainsWhenDictationIsBusy() async {
        let service = VoiceTeachService()
        let recorder = FakeRecorder()
        recorder.busy = true
        service.recorder = recorder
        service.transcribe = { _ in "" }
        let session = VoiceTeachSession(service: service)
        await session.record()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNotNil(session.message)
        XCTAssertTrue(session.transcripts.isEmpty)
    }

    // MARK: Protocol

    func testTranscribeMessagesRoundTripAndOlderPeersIgnoreThem() throws {
        let header = AudioTakeHeader(sessionId: "teach", sampleRate: 16_000, frameCount: 8_000, durationSeconds: 0.5, byteCount: 32_000)
        let request = EdgeMessage.transcribeRequest(requestId: "r1", header: header)
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(try EdgeProtocolCodec.encode(request)), request)
        for result in [CoreMessage.transcribeResult(requestId: "r1", text: "norm", error: nil),
                       CoreMessage.transcribeResult(requestId: "r1", text: nil, error: "no speech")] {
            XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(try EdgeProtocolCodec.encode(result)), result)
        }
        XCTAssertEqual(EdgeProtocol.version, 2, "new optional messages must not bump the version")
        // An older peer's decoder answers unknown types with `unknownType`, which it skips.
        let unknown = Data(#"{"v":2,"t":"transcribe.future","id":"x"}"#.utf8)
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeCoreMessage(unknown)) {
            XCTAssertEqual($0 as? EdgeProtocolError, .unknownType("transcribe.future"))
        }
    }

    func testVoiceCommandDeliveryCarriesTheNearMissAndDecodesWithoutIt() throws {
        let miss = VoiceNearMiss(kind: .entry, transcript: "WhatsApp norm hi", commandId: "wa", commandName: "WhatsApp", slotName: "person",
                                 listId: "people", listName: "People", heardSpans: ["norm", "norm hi"],
                                 candidates: [.init(entryId: "noam", name: "Noam")])
        let with = CoreMessage.voiceCommandInsert(sessionId: "s", delivery: VoiceCommandDelivery(text: "WhatsApp norm hi", notice: "n", nearMiss: miss))
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(try EdgeProtocolCodec.encode(with)), with)
        let without = CoreMessage.voiceCommandInsert(sessionId: "s", delivery: VoiceCommandDelivery(text: "hi"))
        let decoded = try EdgeProtocolCodec.decodeCoreMessage(try EdgeProtocolCodec.encode(without))
        XCTAssertEqual(decoded, without)
        if case .voiceCommandInsert(_, let delivery) = decoded { XCTAssertNil(delivery.nearMiss) }
    }
}
