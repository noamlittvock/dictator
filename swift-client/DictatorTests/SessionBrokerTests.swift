import XCTest
@testable import Dictator

/// Covers every state-machine row plus the worked cross-machine examples,
/// using fake edges and a manual clock so nothing here touches real time,
/// networking or audio.
final class SessionBrokerTests: XCTestCase {
    private var now: TimeInterval = 0
    private var broker: SessionBroker!

    private let miniCaps = EdgeCapabilities(hasMic: false, inputDeviceUID: "", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
    private let macbookCaps = EdgeCapabilities(hasMic: true, inputDeviceUID: "uid-1", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
    private let noMicCaps = EdgeCapabilities(hasMic: false, inputDeviceUID: "", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")

    override func setUp() {
        super.setUp()
        now = 0
        broker = SessionBroker(coreId: "core-1", clock: { self.now }, makeSessionID: { "s1" })
    }

    // MARK: - Helpers

    @discardableResult
    private func connect(_ id: EdgeID, caps: EdgeCapabilities) -> [BrokerEffect] {
        broker.apply(.edgeConnected(BrokerEdgeInfo(id: id, name: id, caps: caps)))
    }

    private func connectMini(chooseRemoteMic: Bool = true) {
        _ = connect("mini", caps: miniCaps)
        // These cross-Mac fixtures deliberately record on the other Mac.
        // Using another Mac's mic requires the user to have chosen it explicitly.
        if chooseRemoteMic { _ = broker.apply(.micOwnerChanged("macbook")) }
    }
    private func connectMacbook() { _ = connect("macbook", caps: macbookCaps) }

    @discardableResult
    private func msg(_ m: EdgeMessage, from: EdgeID) -> [BrokerEffect] {
        broker.apply(.message(m, from: from))
    }

    private func recordingState(target: EdgeID? = "mini", outcome: SessionOutcome? = nil) -> SessionStateUpdate {
        SessionStateUpdate(sessionId: "s1", state: .recording, initiator: "mini", micOwner: "macbook", target: target, outcome: outcome)
    }

    private func processingState(target: EdgeID? = "mini", outcome: SessionOutcome? = nil, recordingLimitReached: Bool? = nil) -> SessionStateUpdate {
        SessionStateUpdate(sessionId: "s1", state: .processing, initiator: "mini", micOwner: "macbook", target: target, outcome: outcome, recordingLimitReached: recordingLimitReached)
    }

    private func insertingState(target: EdgeID?, outcome: SessionOutcome? = nil) -> SessionStateUpdate {
        SessionStateUpdate(sessionId: "s1", state: .inserting, initiator: "mini", micOwner: "macbook", target: target, outcome: outcome)
    }

    private func idleState(target: EdgeID? = "mini", outcome: SessionOutcome) -> SessionStateUpdate {
        SessionStateUpdate(sessionId: "s1", state: .idle, initiator: "mini", micOwner: "macbook", target: target, outcome: outcome)
    }

    /// Drives mini→macbook through hotkeyDown/hotkeyUp (and the resulting
    /// release grace) so tests that only care about the processing/inserting
    /// phases don't repeat the setup. Mini is the sole holder throughout, so
    /// its `hotkeyUp` empties the held set immediately and only the grace
    /// firing actually stops capture — same as production, just driven
    /// synchronously instead of through `CoreHost`'s real timer.
    @discardableResult
    private func startAndStopRecording() -> [BrokerEffect] {
        _ = msg(.hotkeyDown, from: "mini")
        _ = msg(.hotkeyUp(reason: .key), from: "mini")
        return broker.apply(.releaseGraceFired("s1"))
    }

    private func deliverAudio(frameCount: Int = 1600, byteCount: Int = 6400, durationSeconds: Double = 0.01, from: EdgeID = "macbook") {
        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: frameCount, durationSeconds: durationSeconds, byteCount: byteCount)
        _ = msg(.audioTake(header), from: from)
        _ = broker.apply(.audio(Data(repeating: 0, count: byteCount), from: from))
    }

    // MARK: - Worked example (a): press on mini, capture on macbook, insert on mini

    func testCaptureFailureOnlyEndsTheMatchingMicOwnersRecording() {
        connectMini(); connectMacbook()
        _ = msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(msg(.captureFailed(sessionId: "s1", message: "busy"), from: "mini"), [])
        XCTAssertEqual(msg(.captureFailed(sessionId: "stale", message: "busy"), from: "macbook"), [])
        XCTAssertNotNil(broker.session)

        let effects = msg(.captureFailed(sessionId: "s1", message: "Another recording is using the microphone."), from: "macbook")

        XCTAssertNil(broker.session)
        XCTAssertTrue(effects.contains(.send("mini", .sessionState(idleState(outcome: .failed(message: "Another recording is using the microphone."))))))
    }

    func testCaptureFailureEndsProcessingOnlyWhileAudioIsStillAwaited() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        _ = msg(.captureFailed(sessionId: "s1", message: "Recording was not available."), from: "macbook")
        XCTAssertNil(broker.session)

        startAndStopRecording()
        deliverAudio()
        XCTAssertEqual(msg(.captureFailed(sessionId: "s1", message: "late failure"), from: "macbook"), [])
        XCTAssertEqual(broker.session?.phase, .processing, "a late capture failure cannot cancel audio already being transcribed")
    }

    func testWorkedExampleA_PressOnMiniCaptureOnMacbookInsertOnMini() {
        connectMini(); connectMacbook()

        let downEffects = msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(downEffects, [
            // sessionState(recording) goes out before captureStart so every
            // edge knows its role before M is told to start capturing.
            .send("macbook", .sessionState(recordingState())),
            .send("mini", .sessionState(recordingState())),
            .send("macbook", .captureStart(sessionId: "s1")),
            .scheduleWatchdog("s1", EdgeProtocol.maxSessionDuration),
            .scheduleCountdown("s1", EdgeProtocol.maxSessionDuration - EdgeProtocol.countdownLead)
        ])
        XCTAssertEqual(broker.session, SessionSnapshot(id: "s1", phase: .recording, initiator: "mini", micOwner: "macbook", target: "mini"))

        // mini is the sole holder, so its release empties the held set and
        // schedules the grace rather than stopping capture outright.
        let upEffects = msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertEqual(upEffects, [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])
        XCTAssertEqual(broker.session?.phase, .recording)

        let graceEffects = broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(graceEffects, [
            .send("macbook", .captureStop(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(processingState())),
            .send("mini", .sessionState(processingState())),
            .scheduleWatchdog("s1", SessionBroker.audioUploadTimeout),
            .log("release grace fired for session s1: stopping capture")
        ])

        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 1600, durationSeconds: 0.1, byteCount: 6400)
        XCTAssertEqual(msg(.audioTake(header), from: "macbook"), [])

        let audioData = Data(repeating: 7, count: 6400)
        XCTAssertEqual(broker.apply(.audio(audioData, from: "macbook")), [.cancelWatchdog("s1"), .transcribe("s1", header, audioData)])

        let finishEffects = broker.apply(.transcriptionFinished("s1", text: "hello world", inferenceMs: 42, error: nil))
        XCTAssertEqual(finishEffects, [
            // sessionState(inserting, target) goes out before insert, same
            // reasoning as above.
            .send("macbook", .sessionState(insertingState(target: "mini"))),
            .send("mini", .sessionState(insertingState(target: "mini"))),
            .send("mini", .insert(sessionId: "s1", text: "hello world")),
            .scheduleWatchdog("s1", SessionBroker.insertTimeout)
        ])
        XCTAssertEqual(broker.session?.target, "mini")

        let insertEffects = msg(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "mini")
        XCTAssertEqual(insertEffects, [
            .recordHistory(sessionId: "s1", text: "hello world", durationSeconds: 0.1, inferenceMs: 42, destination: nil, initiator: "mini"),
            .cancelWatchdog("s1"), // the insertion watchdog scheduled above
            .send("macbook", .sessionState(idleState(target: "mini", outcome: .pasted))),
            .send("mini", .sessionState(idleState(target: "mini", outcome: .pasted)))
        ])
        XCTAssertNil(broker.session)
    }

    // MARK: - Worked example (b): a focus claim during processing redirects insertion

    func testWorkedExampleB_FocusClaimDuringProcessingRedirectsInsert() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        now = 5
        // The live target follows the claim immediately, so the indicator
        // moves to the macbook while still processing — not only at insert.
        XCTAssertEqual(msg(.pointerPresence, from: "macbook"), [
            .send("macbook", .sessionState(processingState(target: "macbook"))),
            .send("mini", .sessionState(processingState(target: "macbook")))
        ])
        XCTAssertEqual(broker.session?.target, "macbook")

        deliverAudio()

        let finishEffects = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertEqual(finishEffects, [
            .send("macbook", .sessionState(insertingState(target: "macbook"))),
            .send("mini", .sessionState(insertingState(target: "macbook"))),
            .send("macbook", .insert(sessionId: "s1", text: "hi")),
            .scheduleWatchdog("s1", SessionBroker.insertTimeout)
        ])
        XCTAssertEqual(broker.session?.target, "macbook")
    }

    // MARK: - Worked example (c): claims ordered by Core receipt clock, not call order

    func testWorkedExampleC_ClaimsOrderedByCoreReceiptClockNotCallSequence() {
        connectMini(); connectMacbook()

        now = 100
        msg(.focusClaim(appBundleId: "macbook-app"), from: "macbook")
        now = 10 // recorded after macbook's claim, but with an earlier receipt clock
        msg(.focusClaim(appBundleId: "mini-app"), from: "mini")

        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "macbook")
    }

    // MARK: - Worked example (d): freshest claimant disconnects, falls back, then to initiator

    func testWorkedExampleD_FreshestClaimantDisconnectedFallsBackThenToInitiator() {
        connectMini(); connectMacbook()
        connect("imac", caps: noMicCaps)

        startAndStopRecording() // initiator mini, micOwner macbook
        deliverAudio() // transcription already has the audio: mic owner can now go away safely

        now = 10
        msg(.focusClaim(appBundleId: "imac-app"), from: "imac")
        now = 20
        msg(.focusClaim(appBundleId: "macbook-app"), from: "macbook")
        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "macbook")

        let disconnectEffects = broker.apply(.edgeDisconnected("macbook"))
        XCTAssertEqual(disconnectEffects, []) // audio already handed off — session unaffected
        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "imac")

        broker.apply(.edgeDisconnected("imac"))
        XCTAssertNil(broker.focusClaims.freshest(connected: Set(broker.edges.keys)))

        let finish = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertTrue(finish.contains(.send("mini", .insert(sessionId: "s1", text: "hi"))))
        XCTAssertEqual(broker.session?.target, "mini")
    }

    // A shared keyboard can choose a different initiator from the first
    // reporter, but both reports are required before that choice is made.
    func testHotkeyUpFromDifferentEdgeThanInitiatorStopsCaptureAfterGrace() {
        connectMini(); connectMacbook()
        msg(.focusClaim(appBundleId: "com.apple.TextEdit"), from: "mini")
        msg(.hotkeyDown, from: "macbook")
        XCTAssertNil(broker.session)
        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(broker.session?.initiator, "mini")
        msg(.hotkeyUp(reason: .key), from: "mini")

        let upEffects = msg(.hotkeyUp(reason: .key), from: "macbook")
        XCTAssertEqual(upEffects, [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])
        XCTAssertEqual(broker.session?.phase, .recording)
        let fireEffects = broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(fireEffects.first, .send("macbook", .captureStop(sessionId: "s1")))
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testHotkeyUpIgnoredWhenNotRecording() {
        connectMini()
        XCTAssertEqual(msg(.hotkeyUp(reason: .key), from: "mini"), [.log("hotkeyUp from mini ignored: no recording session")])
    }

    // A press that only joined a recording and then turned out to be a typed
    // character lets go of its hold, so the first Mac's release still stops it.
    func testJoinedPressReleasedByChordDoesNotBlockTheOriginalRelease() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        msg(.hotkeyDown, from: "macbook")
        msg(.hotkeyUp(reason: .key), from: "macbook")
        let effects = msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertTrue(effects.contains { if case .scheduleReleaseGrace = $0 { return true } else { return false } },
                      "the recording must stop once the Mac that started it lets go")
    }

    // MARK: - (f) second hotkeyDown while recording joins the hold instead of being ignored

    func testHotkeyDownWhileAlreadyRecordingJoinsTheHold() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")

        let effects = msg(.hotkeyDown, from: "macbook")
        XCTAssertEqual(effects, [.log("hotkeyDown from macbook joined the hold for session s1")])
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertEqual(broker.session?.initiator, "mini") // untouched by the second press

        // Both edges now hold: releasing mini alone must not stop capture.
        let miniUp = msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertEqual(miniUp, [.log("release from mini ignored, still held by macbook")])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testHotkeyDownIgnoredWhileProcessing() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        XCTAssertEqual(msg(.hotkeyDown, from: "mini"), [
            .log("hotkeyDown from mini ignored: session already active"),
            .send("mini", .error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
        ])
    }

    // MARK: - (g) watchdog scheduled on recording start, cancelled on stop

    func testVoiceWorkflowGetsTimeForItsConfiguredSteps() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()
        let plan = VoiceLaunchPlan(commandId: "long", commandName: "Long workflow", slots: [], steps: [
            VoiceStep(kind: .confirm, seconds: 30),
            VoiceStep(kind: .runAppleShortcut, shortcutName: "Test", timeoutSeconds: 120),
            VoiceStep(kind: .waitForTextField, seconds: 60)
        ], mainText: "test words")
        broker.attachLaunch(plan, sessionId: "s1")
        let effects = broker.apply(.transcriptionFinished("s1", text: "test words", inferenceMs: nil, error: nil))
        let timeout = effects.compactMap { effect -> TimeInterval? in
            if case .scheduleWatchdog(_, let seconds) = effect { return seconds }
            return nil
        }.first
        XCTAssertGreaterThan(try! XCTUnwrap(timeout), 210, "The session must outlast the workflow's allowed waits and execution")
    }

    func testWatchdogIsScheduledFor120SecondsAndCancelledOnStop() {
        connectMini(); connectMacbook()

        XCTAssertEqual(EdgeProtocol.maxSessionDuration, 120)
        XCTAssertTrue(msg(.hotkeyDown, from: "mini").contains(.scheduleWatchdog("s1", 120)))
        // mini is the sole holder: its hotkeyUp empties the held set and
        // schedules the release grace rather than cancelling the watchdog
        // directly — the watchdog is only actually cancelled once the grace
        // fires and capture really stops.
        XCTAssertEqual(msg(.hotkeyUp(reason: .key), from: "mini"), [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])
        XCTAssertTrue(broker.apply(.releaseGraceFired("s1")).contains(.cancelWatchdog("s1")))
    }

    func testWatchdogFiredMatchingTransitionsToProcessingLikeHotkeyUpAndLogs() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")

        let effects = broker.apply(.watchdogFired("s1"))
        XCTAssertEqual(effects, [
            .send("macbook", .captureStop(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(processingState(recordingLimitReached: true))),
            .send("mini", .sessionState(processingState(recordingLimitReached: true))),
            .scheduleWatchdog("s1", SessionBroker.audioUploadTimeout),
            .log("watchdog fired for session s1")
        ])
    }

    func testTimeLimitStillTranscribesAndInsertsTheWords() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        _ = broker.apply(.watchdogFired("s1"))
        deliverAudio()
        let effects = broker.apply(.transcriptionFinished("s1", text: "Kept words", inferenceMs: 10, error: nil))
        XCTAssertEqual(broker.session?.phase, .inserting)
        XCTAssertTrue(effects.contains {
            if case .send("mini", .insert(let id, let text)) = $0 {
                return id == "s1" && text == "Kept words"
            }
            return false
        })
        let reconnected = connect("mini", caps: miniCaps)
        XCTAssertTrue(reconnected.contains {
            if case .send("mini", .sessionState(let update)) = $0 { return update.recordingLimitReached == true }
            return false
        })
    }

    func testWatchdogFiredIgnoredWhenNoSessionOrWrongIdOrNotRecording() {
        connectMini(); connectMacbook()
        XCTAssertEqual(broker.apply(.watchdogFired("s1")), []) // idle: no session at all

        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(broker.apply(.watchdogFired("some-other-session")), []) // wrong id

        msg(.hotkeyUp(reason: .key), from: "mini")
        broker.apply(.releaseGraceFired("s1")) // now waiting for audio
        deliverAudio()
        XCTAssertEqual(broker.apply(.watchdogFired("s1")), []) // recognition owns its deadlines
    }

    // MARK: - (h) audio size mismatch / empty audio

    func testAudioSizeMismatchEndsSessionAndKeepsRecordingRecoverable() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        // A semantically valid header (byteCount == frameCount * 4) whose
        // declared byteCount doesn't match the binary frame that actually
        // follows — a different failure mode than an invalid header.
        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 100, durationSeconds: 0.01, byteCount: 400)
        msg(.audioTake(header), from: "macbook")

        let effects = broker.apply(.audio(Data(repeating: 0, count: 5), from: "macbook"))
        XCTAssertEqual(effects.last, .log("audio frame ignored from macbook: size mismatch (header 400 bytes, got 5)"))
        XCTAssertTrue(effects.contains {
            if case .send(_, .sessionState(let update)) = $0, case .failed = update.outcome { return true }
            return false
        })
        XCTAssertNil(broker.session)
    }

    func testAudioIgnoredWithoutAPendingHeader() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let effects = broker.apply(.audio(Data([1, 2, 3]), from: "macbook"))
        XCTAssertEqual(effects, [.log("audio frame ignored from macbook: no pending audio.take header")])
    }

    func testEmptyAudioEndsSessionWithNoAudioOutcome() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 0, durationSeconds: 0, byteCount: 0)
        msg(.audioTake(header), from: "macbook")

        let effects = broker.apply(.audio(Data(), from: "macbook"))
        XCTAssertEqual(effects, [
            .cancelWatchdog("s1"),
            .send("macbook", .sessionState(idleState(outcome: .cancelled(.noAudio)))),
            .send("mini", .sessionState(idleState(outcome: .cancelled(.noAudio))))
        ])
        XCTAssertNil(broker.session)
    }

    func testAudioTakeIgnoredFromWrongEdgeOrWrongSession() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 100, durationSeconds: 0.01, byteCount: 10)
        XCTAssertEqual(msg(.audioTake(header), from: "mini"), [.log("audioTake ignored from mini: no matching processing session")])
        XCTAssertEqual(broker.session?.phase, .processing) // routing mismatch: session untouched

        let wrongSession = AudioTakeHeader(sessionId: "other", sampleRate: 16000, frameCount: 100, durationSeconds: 0.01, byteCount: 10)
        XCTAssertEqual(msg(.audioTake(wrongSession), from: "macbook"), [.log("audioTake ignored from macbook: no matching processing session")])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    // MARK: - (j) audioTake semantic validation

    func testAudioTakeWithExtremeFrameCountFailsWithoutOverflow() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16_000, frameCount: Int.max, durationSeconds: 1, byteCount: 4)
        let effects = msg(.audioTake(header), from: "macbook")
        XCTAssertNil(broker.session)
        XCTAssertTrue(effects.contains {
            if case .send(_, .sessionState(let update)) = $0, case .failed = update.outcome { return true }
            return false
        })
    }

    func testRepeatedAudioHeaderCannotStartTranscriptionTwice() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()
        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16_000, frameCount: 1, durationSeconds: 0.1, byteCount: 4)
        _ = msg(.audioTake(header), from: "macbook")
        let effects = broker.apply(.audio(Data(repeating: 0, count: 4), from: "macbook"))
        XCTAssertFalse(effects.contains { if case .transcribe = $0 { return true }; return false })
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testAudioHeaderWithoutBodyTimesOutAndKeepsRecorderCheckpoint() {
        connectMini(); connectMacbook()
        let stopped = startAndStopRecording()
        XCTAssertTrue(stopped.contains(.scheduleWatchdog("s1", SessionBroker.audioUploadTimeout)))
        _ = msg(.audioTake(AudioTakeHeader(sessionId: "s1", sampleRate: 16_000, frameCount: 1, durationSeconds: 0.1, byteCount: 4)), from: "macbook")
        let effects = broker.apply(.watchdogFired("s1"))
        XCTAssertNil(broker.session)
        XCTAssertTrue(effects.contains {
            if case .send("macbook", .sessionState(let update)) = $0, case .failed = update.outcome { return true }
            return false
        })
    }

    func testAudioTakeOversizedEndsSessionWithRecoverableFailure() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let oversized = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 100, durationSeconds: 0.01, byteCount: EdgeProtocol.maxBinaryFrameBytes + 1)
        let effects = msg(.audioTake(oversized), from: "macbook")
        XCTAssertEqual(effects.last, .log("audioTake ignored from macbook: invalid header"))
        XCTAssertTrue(effects.contains {
            if case .send(_, .sessionState(let update)) = $0, case .failed = update.outcome { return true }
            return false
        })
        XCTAssertNil(broker.session)
    }

    func testAudioTakeByteCountNotMatchingFrameCountTimesFourEndsSessionAsNoAudio() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let mismatched = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 100, durationSeconds: 0.01, byteCount: 401)
        let effects = msg(.audioTake(mismatched), from: "macbook")
        XCTAssertEqual(effects.last, .log("audioTake ignored from macbook: invalid header"))
        XCTAssertNil(broker.session)
    }

    func testAudioTakeWrongSampleRateEndsSessionAsNoAudio() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let wrongRate = AudioTakeHeader(sessionId: "s1", sampleRate: 8000, frameCount: 100, durationSeconds: 0.01, byteCount: 400)
        let effects = msg(.audioTake(wrongRate), from: "macbook")
        XCTAssertEqual(effects.last, .log("audioTake ignored from macbook: invalid header"))
        XCTAssertNil(broker.session)
    }

    func testAudioTakeNegativeFrameCountEndsSessionAsNoAudio() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let negative = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: -1, durationSeconds: 0.01, byteCount: 0)
        let effects = msg(.audioTake(negative), from: "macbook")
        XCTAssertEqual(effects.last, .log("audioTake ignored from macbook: invalid header"))
        XCTAssertNil(broker.session)
    }

    func testAudioTakeOutOfRangeOrNonFiniteDurationEndsSessionAsNoAudio() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        let tooLong = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 100, durationSeconds: EdgeProtocol.maxSessionDuration + 5.1, byteCount: 400)
        XCTAssertEqual(msg(.audioTake(tooLong), from: "macbook").last, .log("audioTake ignored from macbook: invalid header"))
        XCTAssertNil(broker.session)

        // Fresh session for the non-finite case.
        connectMini(); connectMacbook()
        startAndStopRecording()
        let nonFinite = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 100, durationSeconds: .nan, byteCount: 400)
        XCTAssertEqual(msg(.audioTake(nonFinite), from: "macbook").last, .log("audioTake ignored from macbook: invalid header"))
        XCTAssertNil(broker.session)
    }

    // MARK: - (i) mic owner preference: honoured / falls back / noMic error

    func testMicOwnerPreferenceHonouredWhenConnectedAndHasMic() {
        connectMini(); connectMacbook()
        XCTAssertEqual(broker.apply(.micOwnerChanged("macbook")), [])

        XCTAssertTrue(msg(.hotkeyDown, from: "mini").contains(.send("macbook", .captureStart(sessionId: "s1"))))
        XCTAssertEqual(broker.session?.micOwner, "macbook")
    }

    func testMicOwnerPreferenceFallsBackWhenPreferredEdgeNotConnected() {
        connect("mini", caps: macbookCaps); connectMacbook()
        broker.apply(.micOwnerChanged("imac")) // never connects

        XCTAssertTrue(msg(.hotkeyDown, from: "mini").contains(.send("mini", .captureStart(sessionId: "s1"))))
    }

    func testMicOwnerPreferenceFallsBackWhenPreferredEdgeHasNoMic() {
        connect("mini", caps: macbookCaps); connectMacbook()
        connect("imac", caps: noMicCaps)
        broker.apply(.micOwnerChanged("imac")) // connected, but no mic

        XCTAssertTrue(msg(.hotkeyDown, from: "mini").contains(.send("mini", .captureStart(sessionId: "s1"))))
    }

    func testNoPreferenceFallsBackToInitiatorWhenItHasAMic() {
        connectMacbook() // only macbook is connected, and it has a mic
        let effects = msg(.hotkeyDown, from: "macbook")
        XCTAssertTrue(effects.contains(.send("macbook", .captureStart(sessionId: "s1"))))
        XCTAssertEqual(broker.session?.micOwner, "macbook")
    }

    func testNoPreferenceRefusesAnUnrelatedConnectedMicrophone() {
        connectMini(chooseRemoteMic: false)
        connect("zzz-box", caps: macbookCaps)
        connect("aaa-box", caps: macbookCaps)

        XCTAssertEqual(msg(.hotkeyDown, from: "mini"), [.schedulePressSettle(1, SessionBroker.pressSettle)])
        let effects = broker.apply(.pressSettled(1))
        XCTAssertTrue(effects.contains(.send("mini", .error(code: "noMic", message: DictationAlert.microphoneOnAnotherMac().encoded))))
        XCTAssertNil(broker.session)
    }

    func testNoMicAnywhereEmitsErrorAndStaysIdle() {
        connectMini() // no mic anywhere
        let effects = msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(effects, [
            .send("mini", .error(code: "noMic", message: "No connected edge has a microphone.")),
            .log("hotkeyDown from mini: no edge with a microphone is available")
        ])
        XCTAssertNil(broker.session)
    }

    // MARK: - hotkeyCancel

    func testHotkeyCancelWhileRecording() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")

        let effects = msg(.hotkeyCancel, from: "mini")
        XCTAssertEqual(effects, [
            .send("macbook", .captureCancel(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(idleState(outcome: .cancelled(.user)))),
            .send("mini", .sessionState(idleState(outcome: .cancelled(.user))))
        ])
        XCTAssertNil(broker.session)
    }

    func testHotkeyCancelWhileProcessing() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let effects = msg(.hotkeyCancel, from: "macbook") // cancel can come from any edge
        XCTAssertEqual(effects, [
            .cancelTranscription("s1"),
            .cancelWatchdog("s1"),
            .send("macbook", .sessionState(idleState(outcome: .cancelled(.user)))),
            .send("mini", .sessionState(idleState(outcome: .cancelled(.user))))
        ])
    }

    func testHotkeyCancelIgnoredWhenIdle() {
        connectMini()
        XCTAssertEqual(msg(.hotkeyCancel, from: "mini"), [])
    }

    func testHotkeyCancelIgnoredWhileInserting() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()
        broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertEqual(broker.session?.phase, .inserting)

        XCTAssertEqual(msg(.hotkeyCancel, from: "mini"), [])
        XCTAssertEqual(broker.session?.phase, .inserting) // untouched
    }

    // MARK: - level relay

    func testLevelRelayedToInitiatorWhenMicOwnerDiffers() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")

        XCTAssertEqual(msg(.level(rms: 0.5), from: "macbook"), [.send("mini", .level(rms: 0.5))])
    }

    func testLevelNotRelayedWhenInitiatorIsItsOwnMicOwner() {
        connectMacbook()
        msg(.hotkeyDown, from: "macbook") // initiator == micOwner

        XCTAssertEqual(msg(.level(rms: 0.3), from: "macbook"), [])
    }

    func testLevelIgnoredFromNonMicOwnerOrOutsideRecording() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(msg(.level(rms: 0.5), from: "mini"), []) // mini isn't the mic owner

        msg(.hotkeyUp(reason: .key), from: "mini") // held set now empty, grace pending
        broker.apply(.releaseGraceFired("s1")) // now processing
        XCTAssertEqual(msg(.level(rms: 0.5), from: "macbook"), [])
    }

    // MARK: - transcriptionFinished

    func testTranscriptionFinishedIgnoredWhenSessionIdIsStale() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        XCTAssertEqual(broker.apply(.transcriptionFinished("some-other-session", text: "hi", inferenceMs: nil, error: nil)), [])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testTranscriptionFinishedErrorEndsSessionAsFailed() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()

        let effects = broker.apply(.transcriptionFinished("s1", text: nil, inferenceMs: nil, error: "server unreachable"))
        XCTAssertEqual(effects, [
            .send("macbook", .sessionState(idleState(outcome: .failed(message: "server unreachable")))),
            .send("mini", .sessionState(idleState(outcome: .failed(message: "server unreachable"))))
        ])
    }

    /// Whitespace-only text is trimmed and treated as empty, not just an
    /// exactly-empty string, because pasting whitespace is never useful.
    /// See the doc comment on `handleTranscriptionFinished`.
    func testTranscriptionFinishedEmptyOrWhitespaceTextEndsSessionAsEmpty() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()

        let effects = broker.apply(.transcriptionFinished("s1", text: "   \n", inferenceMs: nil, error: nil))
        XCTAssertEqual(effects, [
            .send("macbook", .sessionState(idleState(outcome: .empty))),
            .send("mini", .sessionState(idleState(outcome: .empty)))
        ])
    }

    // MARK: - insertResult

    func testInsertResultIgnoredFromNonTargetOrStaleSession() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()
        broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil)) // target = mini

        XCTAssertEqual(
            msg(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "macbook"),
            [.log("insertResult ignored from macbook: not the current insertion target")]
        )
        XCTAssertEqual(
            msg(.insertResult(sessionId: "stale", outcome: .pasted, destination: nil), from: "mini"),
            [.log("insertResult ignored from mini: not the current insertion target")]
        )
        XCTAssertEqual(broker.session?.phase, .inserting) // both ignored, nothing changed
    }

    func testInsertResultRecordsHistoryWithReportedOutcome() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio(durationSeconds: 2.5)
        broker.apply(.transcriptionFinished("s1", text: "hi there", inferenceMs: 17, error: nil))

        let destination = InsertDestination(bundleId: "com.apple.Notes", appName: "Notes", url: nil, insertionMethod: "paste")
        let effects = msg(.insertResult(sessionId: "s1", outcome: .clipboardOnly(reason: "No editable field", needsAccessibility: true), destination: destination), from: "mini")
        XCTAssertEqual(effects, [
            .recordHistory(sessionId: "s1", text: "hi there", durationSeconds: 2.5, inferenceMs: 17, destination: destination, initiator: "mini"),
            .cancelWatchdog("s1"), // the insertion watchdog
            .send("macbook", .sessionState(idleState(target: "mini", outcome: .clipboardOnly(reason: "No editable field", needsAccessibility: true)))),
            .send("mini", .sessionState(idleState(target: "mini", outcome: .clipboardOnly(reason: "No editable field", needsAccessibility: true))))
        ])
    }

    // MARK: - edgeDisconnected

    func testEdgeDisconnectedMicOwnerDuringRecordingEndsSessionAsMicLost() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")

        let effects = broker.apply(.edgeDisconnected("macbook"))
        XCTAssertEqual(effects, [
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("mini", .sessionState(idleState(outcome: .cancelled(.micLost))))
        ])
        XCTAssertNil(broker.session)
        XCTAssertNil(broker.edges["macbook"])
    }

    func testEdgeDisconnectedInitiatorDuringRecordingEndsSessionAsInitiatorLost() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")

        let effects = broker.apply(.edgeDisconnected("mini"))
        XCTAssertEqual(effects, [
            .send("macbook", .captureCancel(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(idleState(outcome: .cancelled(.initiatorLost))))
        ])
    }

    func testEdgeDisconnectedMicOwnerDuringProcessingBeforeAudioEndsSessionAsMicLost() {
        connectMini(); connectMacbook()
        startAndStopRecording()

        let effects = broker.apply(.edgeDisconnected("macbook"))
        XCTAssertEqual(effects, [.cancelWatchdog("s1"), .send("mini", .sessionState(idleState(outcome: .cancelled(.micLost))))])
    }

    func testEdgeDisconnectedMicOwnerDuringProcessingAfterAudioContinuesUnaffected() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()

        let effects = broker.apply(.edgeDisconnected("macbook"))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testEdgeDisconnectedTargetDuringInsertingEndsSessionAsTargetLost() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()
        broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil)) // target = mini

        let effects = broker.apply(.edgeDisconnected("mini"))
        XCTAssertEqual(effects, [
            .cancelWatchdog("s1"), // the insertion watchdog
            .send("macbook", .sessionState(idleState(target: "mini", outcome: .cancelled(.targetLost))))
        ])
    }

    func testEdgeDisconnectedBystanderDoesNotChangeSession() {
        connectMini(); connectMacbook()
        connect("imac", caps: noMicCaps)
        msg(.hotkeyDown, from: "mini")

        let effects = broker.apply(.edgeDisconnected("imac"))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testEdgeDisconnectedRemovesItsFocusClaim() {
        connectMini()
        now = 5
        msg(.focusClaim(appBundleId: "x"), from: "mini")
        XCTAssertNotNil(broker.focusClaims.claim(for: "mini"))

        broker.apply(.edgeDisconnected("mini"))
        XCTAssertNil(broker.focusClaims.claim(for: "mini"))
    }

    // MARK: - edgeConnected

    func testEdgeConnectedWhileIdleProducesNoEffects() {
        XCTAssertEqual(connect("mini", caps: miniCaps), [])
    }

    func testEdgeConnectedMidSessionSyncsTheJoiningEdge() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")

        let effects = connect("imac", caps: noMicCaps)
        XCTAssertEqual(effects, [.send("imac", .sessionState(recordingState()))])
    }

    // MARK: - focusClaim / micOwnerChanged / ping/hello no-ops

    func testFocusClaimIsRecordedWithTheCoresClock() {
        connectMini()
        now = 42
        XCTAssertEqual(msg(.focusClaim(appBundleId: "com.apple.Notes"), from: "mini"), [])

        let claim = broker.focusClaims.claim(for: "mini")
        XCTAssertEqual(claim?.appBundleId, "com.apple.Notes")
        XCTAssertEqual(claim?.receivedAt, 42)
    }

    // MARK: - Pointer presence dominates keystroke claims (Universal Control)
    //
    // `focus.claim` is keyDown/click-derived, and Universal Control can
    // deliver the same physical keyDown to both Macs' event taps (identical
    // keyDown/flagsChanged trace lines land on both hotkey.log files within
    // the same second). `pointer.presence` never has this problem: only the
    // Mac that owns the on-screen pointer ever receives
    // mouseMoved/leftMouseDown from its own tap.

    func testPointerPresenceClaimIsRecordedWithTheCoresClock() {
        connectMini()
        now = 7
        XCTAssertEqual(msg(.pointerPresence, from: "mini"), [])

        let claim = broker.focusClaims.claim(for: "mini")
        XCTAssertEqual(claim?.appBundleId, nil)
        XCTAssertEqual(claim?.receivedAt, 7)
    }

    /// The exact shape of the bug: mini's pointer claim is older than
    /// macbook's keystroke claim (a stale/duplicated keyDown that arrived at
    /// the Core after the pointer moved away), yet mini must still win —
    /// pointer presence dominates rather than merely tie-breaking on
    /// recency.
    func testPointerClaimDominatesAFresherKeystrokeClaimFromAnotherEdge() {
        connectMini(); connectMacbook()

        now = 1
        msg(.pointerPresence, from: "mini") // the user's pointer really is on mini
        now = 100
        msg(.focusClaim(appBundleId: "macbook-app"), from: "macbook") // later, but ambiguous

        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "mini")
    }

    /// With no pointer claim on record anywhere (e.g. right after launch,
    /// before the first mouseMoved/click), the old keystroke-freshest
    /// behavior is unchanged — this is the backward-compatible fallback.
    func testFreshestFallsBackToKeystrokeClaimsWhenNoPointerClaimExists() {
        connectMini(); connectMacbook()

        now = 1
        msg(.focusClaim(appBundleId: "mini-app"), from: "mini")
        now = 2
        msg(.focusClaim(appBundleId: "macbook-app"), from: "macbook")

        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "macbook")
    }

    /// Among two pointer claims, freshest still wins normally — the
    /// dominance rule only overrides keystroke claims, not other pointer
    /// claims.
    func testFreshestAmongPointerClaimsIsStillOrderedByReceiptTime() {
        connectMini(); connectMacbook()

        now = 50
        msg(.pointerPresence, from: "macbook")
        now = 10
        msg(.pointerPresence, from: "mini") // earlier receipt clock than macbook's

        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "macbook")
    }

    /// End-to-end: the user's pointer is genuinely on the mini, but a
    /// duplicated keyDown (Universal Control forwarding the same physical
    /// keystroke to both taps) makes the macbook emit a keystroke claim
    /// after the mini's pointer claim. Pressing the hotkey must still start
    /// the session on the mini — this is the literal bug report ("mouse on
    /// the mini, dictation doesn't necessarily start there").
    func testInitiatorResolvesToThePointerOwnerDespiteALaterSpuriousKeystrokeClaim() {
        connectMini(); connectMacbook()

        now = 1
        msg(.pointerPresence, from: "mini") // the user's mouse is on the mini
        now = 2
        msg(.focusClaim(appBundleId: "com.apple.Terminal"), from: "macbook") // spurious duplicate keyDown

        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(broker.session?.initiator, "mini")
    }

    /// The common case: the pointer crossed from the macbook to the mini
    /// (both have pointer claims, the mini's fresher), then the user types on
    /// the mini — which yields a keystroke claim from the mini (and possibly
    /// the macbook). The mini's keystroke claim must not erase its pointer
    /// claim, otherwise the macbook's stale pointer claim would be the only
    /// `.pointer` entry left and would win.
    func testKeystrokeClaimDoesNotEraseTheSameEdgesPointerClaim() {
        connectMini(); connectMacbook()

        now = 1
        msg(.pointerPresence, from: "macbook") // pointer was on the macbook…
        now = 2
        msg(.pointerPresence, from: "mini")    // …then crossed to the mini
        now = 3
        msg(.focusClaim(appBundleId: "com.apple.Notes"), from: "mini") // typing on the mini
        now = 4
        msg(.focusClaim(appBundleId: "com.apple.Terminal"), from: "macbook") // duplicated keyDown

        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "mini")
        msg(.hotkeyDown, from: "macbook") // first report alone cannot choose another Mac
        XCTAssertNil(broker.session)
        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(broker.session?.initiator, "mini")
    }

    /// The indicator follows the pointer: a session started on the mini
    /// whose pointer then crosses to the macbook re-broadcasts the new
    /// target while recording (level meter moves) and again if it crosses
    /// back during processing (spinner moves). Nothing goes out when the
    /// pointer stays put.
    func testTargetFollowsThePointerAcrossMachinesDuringRecordingAndProcessing() {
        connectMini(); connectMacbook()
        now = 1
        msg(.pointerPresence, from: "mini")
        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(broker.session?.target, "mini")

        now = 2
        XCTAssertEqual(msg(.pointerPresence, from: "mini"), []) // still here: no re-broadcast
        now = 3
        XCTAssertEqual(msg(.pointerPresence, from: "macbook"), [
            .send("macbook", .sessionState(recordingState(target: "macbook"))),
            .send("mini", .sessionState(recordingState(target: "macbook")))
        ])
        // The mic owner's level meter now goes to the new target — which is
        // the macbook itself, so nothing is relayed.
        XCTAssertEqual(msg(.level(rms: 0.5), from: "macbook"), [])

        msg(.hotkeyUp(reason: .key), from: "mini")
        broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(broker.session?.phase, .processing)
        now = 4
        XCTAssertEqual(msg(.pointerPresence, from: "mini"), [
            .send("macbook", .sessionState(processingState(target: "mini"))),
            .send("mini", .sessionState(processingState(target: "mini")))
        ])
        deliverAudio()
        let finish = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertTrue(finish.contains(.send("mini", .insert(sessionId: "s1", text: "hi"))))
    }

    func testMicOwnerChangedDoesNotTouchAnActiveSession() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini") // micOwner resolves to macbook

        XCTAssertEqual(broker.apply(.micOwnerChanged("mini")), [])
        XCTAssertEqual(broker.session?.micOwner, "macbook") // preference change doesn't retroactively move it
        XCTAssertEqual(broker.micOwnerPreference, "mini")
    }

    func testPingAndHelloAreNoOps() {
        connectMini()
        XCTAssertEqual(msg(.ping, from: "mini"), [])
        XCTAssertEqual(msg(.hello(edgeId: "mini", name: "Mini", token: "t", caps: miniCaps), from: "mini"), [])
    }

    // MARK: - Initiator lost during processing/inserting must never wedge the Core

    func testInitiatorDisconnectedDuringProcessingWithNoClaimantEndsSessionAsInitiatorLostWithNoInsert() {
        connectMini(); connectMacbook()
        startAndStopRecording() // initiator mini, micOwner macbook
        deliverAudio() // audio already handed off — mic owner leaving wouldn't matter either

        // The initiator (mini) drops before transcription comes back, and
        // nobody has claimed focus anywhere else.
        let disconnectEffects = broker.apply(.edgeDisconnected("mini"))
        XCTAssertEqual(disconnectEffects, []) // processing, not the mic owner — no immediate effect
        XCTAssertNotNil(broker.session) // session is still alive, waiting on transcription

        let finish = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertEqual(finish, [.send("macbook", .sessionState(idleState(outcome: .cancelled(.initiatorLost))))])
        XCTAssertNil(broker.session) // ended idle, never entered .inserting — no .send(_, .insert) anywhere
    }

    func testInitiatorDisconnectedDuringProcessingWithConnectedClaimantInsertsToTheClaimant() {
        connectMini(); connectMacbook()
        startAndStopRecording() // initiator mini, micOwner macbook
        now = 5
        msg(.pointerPresence, from: "macbook") // macbook claims focus
        deliverAudio()

        broker.apply(.edgeDisconnected("mini")) // initiator gone mid-processing

        let finish = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertEqual(finish, [
            .send("macbook", .sessionState(insertingState(target: "macbook"))),
            .send("macbook", .insert(sessionId: "s1", text: "hi")),
            .scheduleWatchdog("s1", SessionBroker.insertTimeout)
        ])
        XCTAssertEqual(broker.session?.target, "macbook")
    }

    // MARK: - Insertion watchdog

    func testInsertionWatchdogIsScheduledOnEnteringInsertingAndCancelledOnInsertResult() {
        XCTAssertEqual(SessionBroker.insertTimeout, 20)
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()

        let finish = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertTrue(finish.contains(.scheduleWatchdog("s1", SessionBroker.insertTimeout)))

        let insertEffects = msg(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil), from: "mini")
        XCTAssertTrue(insertEffects.contains(.cancelWatchdog("s1")))
    }

    func testInsertionWatchdogFiredEndsSessionAsFailedInsertionTimedOut() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()
        broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil)) // target = mini, now .inserting

        let effects = broker.apply(.watchdogFired("s1"))
        XCTAssertEqual(effects, [
            .cancelWatchdog("s1"),
            .send("macbook", .sessionState(idleState(target: "mini", outcome: .failed(message: "The Mac you’re using didn’t confirm that it typed your text.")))),
            .send("mini", .sessionState(idleState(target: "mini", outcome: .failed(message: "The Mac you’re using didn’t confirm that it typed your text.")))),
            .log("insertion watchdog fired for session s1")
        ])
        XCTAssertNil(broker.session)
    }

    func testInsertionWatchdogIgnoredWithWrongSessionIdOrOutsideInserting() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio() // recognition owns its deadlines
        XCTAssertEqual(broker.apply(.watchdogFired("s1")), [])
        broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil)) // now inserting
        XCTAssertEqual(broker.apply(.watchdogFired("some-other-session")), [])
        XCTAssertEqual(broker.session?.phase, .inserting) // untouched
    }

    // MARK: - Held set / release grace (Universal Control)
    //
    // With one keyboard shared over Universal Control, a Right Option press
    // is seen by both Macs' event taps. When the pointer crosses back to the
    // other Mac mid-hold, the Mac just left gets a synthetic key-up while the
    // key is still physically held; the real key-up follows shortly after on
    // the other Mac. `heldEdges` tracks every edge whose last hotkey event
    // was a down, and capture only actually stops once that set is empty for
    // a full `releaseGrace` window with nobody re-pressing.

    /// The exact live trace: macbook (mic) and mini (no mic, but the
    /// freshest focus claim) both report the same physical press within 5 ms
    /// of each other, macbook first. The initiator resolves to mini (where
    /// the user actually is), not macbook (who happened to send first).
    /// mini's synthetic release doesn't stop anything — macbook still holds
    /// — and only macbook's real release (after the grace) does.
    func testUniversalControlPointerCrossingSyntheticReleaseDoesNotStopDictation() {
        connectMini(); connectMacbook()
        msg(.focusClaim(appBundleId: "com.apple.TextEdit"), from: "mini") // mini is where the user is

        now = 1
        msg(.hotkeyDown, from: "macbook") // macbook's event tap saw the press first
        XCTAssertNil(broker.session) // waiting for evidence of the shared keyboard

        now = 1.005
        let miniDown = msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(miniDown.first, .cancelPressSettle(1))
        XCTAssertTrue(miniDown.contains(.send("macbook", .captureStart(sessionId: "s1"))))
        XCTAssertEqual(broker.session?.initiator, "mini")
        XCTAssertEqual(broker.session?.micOwner, "macbook")
        XCTAssertEqual(broker.session?.phase, .recording)

        // mini's synthetic release: macbook still holds — no captureStop, no grace.
        let miniUp = msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertEqual(miniUp, [.log("release from mini ignored, still held by macbook")])
        XCTAssertEqual(broker.session?.phase, .recording)

        // macbook's real release empties the held set — grace scheduled, not an immediate stop.
        let macbookUp = msg(.hotkeyUp(reason: .key), from: "macbook")
        XCTAssertEqual(macbookUp, [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])
        XCTAssertEqual(broker.session?.phase, .recording)

        // Only once the grace actually fires does capture stop.
        let fireEffects = broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(fireEffects, [
            .send("macbook", .captureStop(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(processingState())),
            .send("mini", .sessionState(processingState())),
            .scheduleWatchdog("s1", SessionBroker.audioUploadTimeout),
            .log("release grace fired for session s1: stopping capture")
        ])
    }

    func testReleaseGraceCancelledByRePress() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini") // sole holder

        let upEffects = msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertEqual(upEffects, [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])

        let downAgain = msg(.hotkeyDown, from: "mini") // re-press within the grace window
        XCTAssertEqual(downAgain, [
            .cancelReleaseGrace("s1"),
            .log("hotkeyDown from mini joined the hold for session s1")
        ])
        XCTAssertEqual(broker.session?.phase, .recording)

        // A late/stale fire for the grace that was just cancelled must be a no-op.
        XCTAssertEqual(broker.apply(.releaseGraceFired("s1")), [])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testReleaseGraceFiredWithANewHolderIsIgnored() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        msg(.hotkeyUp(reason: .key), from: "mini") // grace scheduled

        msg(.hotkeyDown, from: "macbook") // a different edge joins mid-grace

        // Even a stale `releaseGraceFired` for the earlier grace must not
        // stop capture now that macbook holds.
        XCTAssertEqual(broker.apply(.releaseGraceFired("s1")), [])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    /// The held set can also empty via a disconnect rather than a
    /// `hotkeyUp` — e.g. the only remaining holder's Mac drops off the
    /// network mid-hold. Goes through the same grace path; the
    /// micLost/initiatorLost rules only take precedence when the
    /// disconnecting edge actually is the mic owner or initiator.
    func testDisconnectOfSoleHolderSchedulesGraceThenStops() {
        connectMini(); connectMacbook()
        connect("imac", caps: noMicCaps)

        msg(.hotkeyDown, from: "macbook") // starts the session: micOwner + initiator + sole holder
        msg(.hotkeyDown, from: "imac") // joins the hold

        let macbookUp = msg(.hotkeyUp(reason: .key), from: "macbook")
        XCTAssertEqual(macbookUp, [.log("release from macbook ignored, still held by imac")])
        XCTAssertEqual(broker.session?.phase, .recording)

        // imac — neither mic owner nor initiator, but the sole remaining
        // holder — disconnects instead of releasing normally.
        let disconnectEffects = broker.apply(.edgeDisconnected("imac"))
        XCTAssertEqual(disconnectEffects, [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])
        XCTAssertEqual(broker.session?.phase, .recording)

        let fireEffects = broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(fireEffects.first, .send("macbook", .captureStop(sessionId: "s1")))
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testInitiatorFallsBackToPressingEdgeWhenNoClaim() {
        connectMini(); connectMacbook()
        // Nobody has claimed focus anywhere.
        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(broker.session?.initiator, "mini")
    }

    func testHotkeyCancelDuringGraceClearsEverything() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini") // sole holder

        let upEffects = msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertEqual(upEffects, [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])

        let cancelEffects = msg(.hotkeyCancel, from: "macbook") // cancel can come from any edge
        XCTAssertEqual(cancelEffects, [
            .send("macbook", .captureCancel(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .cancelReleaseGrace("s1"),
            .send("macbook", .sessionState(idleState(outcome: .cancelled(.user)))),
            .send("mini", .sessionState(idleState(outcome: .cancelled(.user))))
        ])
        XCTAssertNil(broker.session)

        // The grace that was pending when the session ended must not be
        // able to resurrect it.
        XCTAssertEqual(broker.apply(.releaseGraceFired("s1")), [])
    }

    // MARK: - Hands-free (tap-to-start/tap-to-stop)
    //
    // With one keyboard shared over Universal Control, a Right Option tap is
    // seen by both Macs' event taps within a few ms — a per-edge toggle
    // would desync, so the on/off decision is made once, here, with
    // `toggleDebounce` absorbing the duplicate copy of the same tap.

    func testHotkeyToggleStartsHandsFreeSessionWithEmptyHeldSet() {
        connectMini(); connectMacbook()

        let effects = msg(.hotkeyToggle, from: "mini")
        XCTAssertEqual(effects, [
            .send("macbook", .sessionState(recordingState())),
            .send("mini", .sessionState(recordingState())),
            .send("macbook", .captureStart(sessionId: "s1")),
            .scheduleWatchdog("s1", EdgeProtocol.maxSessionDuration),
            .scheduleCountdown("s1", EdgeProtocol.maxSessionDuration - EdgeProtocol.countdownLead)
        ])
        XCTAssertEqual(broker.session, SessionSnapshot(id: "s1", phase: .recording, initiator: "mini", micOwner: "macbook", target: "mini", handsFree: true))

        // No hold to join: a bystander's hotkeyDown is ignored outright
        // rather than joining a `heldEdges` set that was never populated.
        XCTAssertEqual(msg(.hotkeyDown, from: "macbook"), [
            .log("hotkeyDown from macbook ignored: hands-free session already active"),
            .send("macbook", .error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
        ])
    }

    func testHotkeyToggleDuplicateTapFromOtherEdgeWithinDebounceIsAbsorbed() {
        connectMini(); connectMacbook()

        now = 1
        msg(.hotkeyToggle, from: "mini")
        now = 1.005 // the live Universal Control trace: ~5 ms apart
        let effects = msg(.hotkeyToggle, from: "macbook")
        XCTAssertEqual(effects, [.log("hotkeyToggle from macbook ignored: duplicate tap absorbed")])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testHotkeyToggleAfterDebounceStopsHandsFreeCapture() {
        XCTAssertEqual(SessionBroker.toggleDebounce, 0.5)
        connectMini(); connectMacbook()

        now = 0
        msg(.hotkeyToggle, from: "mini")
        now = SessionBroker.toggleDebounce
        let effects = msg(.hotkeyToggle, from: "mini")
        XCTAssertEqual(effects, [
            .send("macbook", .captureStop(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(processingState())),
            .send("mini", .sessionState(processingState())),
            .scheduleWatchdog("s1", SessionBroker.audioUploadTimeout),
            .log("hotkeyToggle from mini: stopping hands-free capture")
        ])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testHotkeyUpDuringHandsFreeSessionIsIgnoredEntirely() {
        connectMini(); connectMacbook()
        msg(.hotkeyToggle, from: "mini")

        let keyUp = msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertEqual(keyUp, [.log("hotkeyUp from mini ignored: hands-free session, release means nothing")])
        XCTAssertEqual(broker.session?.phase, .recording)

        // Also covers the modifier-watchdog / listener-loss synthesized reasons.
        let watchdogUp = msg(.hotkeyUp(reason: .modifierWatchdog), from: "macbook")
        XCTAssertEqual(watchdogUp, [.log("hotkeyUp from macbook ignored: hands-free session, release means nothing")])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testHotkeyDownDuringHandsFreeSessionIsIgnored() {
        connectMini(); connectMacbook()
        msg(.hotkeyToggle, from: "mini")

        let effects = msg(.hotkeyDown, from: "macbook")
        XCTAssertEqual(effects, [
            .log("hotkeyDown from macbook ignored: hands-free session already active"),
            .send("macbook", .error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
        ])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testHotkeyCancelDuringHandsFreeSessionEndsIt() {
        connectMini(); connectMacbook()
        msg(.hotkeyToggle, from: "mini")

        let effects = msg(.hotkeyCancel, from: "macbook") // cancel can come from any edge
        XCTAssertEqual(effects, [
            .send("macbook", .captureCancel(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(idleState(outcome: .cancelled(.user)))),
            .send("mini", .sessionState(idleState(outcome: .cancelled(.user))))
        ])
        XCTAssertNil(broker.session)
    }

    func testWatchdogFiresForHandsFreeSessionLikeAnyOther() {
        connectMini(); connectMacbook()
        msg(.hotkeyToggle, from: "mini")

        let effects = broker.apply(.watchdogFired("s1"))
        XCTAssertEqual(effects, [
            .send("macbook", .captureStop(sessionId: "s1")),
            .cancelWatchdog("s1"),
            .cancelCountdown("s1"),
            .send("macbook", .sessionState(processingState(recordingLimitReached: true))),
            .send("mini", .sessionState(processingState(recordingLimitReached: true))),
            .scheduleWatchdog("s1", SessionBroker.audioUploadTimeout),
            .log("watchdog fired for session s1")
        ])
    }

    func testHotkeyToggleIgnoredWhileProcessing() {
        connectMini(); connectMacbook()
        now = 0
        msg(.hotkeyToggle, from: "mini")
        now = SessionBroker.toggleDebounce
        msg(.hotkeyToggle, from: "mini") // stops capture, now processing
        XCTAssertEqual(broker.session?.phase, .processing)

        now += SessionBroker.toggleDebounce // past any duplicate of the stopping tap
        let effects = msg(.hotkeyToggle, from: "mini")
        XCTAssertEqual(effects, [
            .log("hotkeyToggle from mini ignored: session already active"),
            .send("mini", .error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
        ])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testHoldToTalkSessionIgnoresHotkeyToggle() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini") // hold-to-talk, started elsewhere

        let effects = msg(.hotkeyToggle, from: "macbook")
        XCTAssertEqual(effects, [
            .log("hotkeyToggle from macbook ignored: hold-to-talk session already active"),
            .send("macbook", .error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
        ])
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertEqual(broker.session?.handsFree, false)
    }
    // MARK: - "Recording is about to end" countdown

    func testCountdownIsScheduledTenSecondsBeforeTheWatchdogInHoldAndTapModes() {
        connectMini(); connectMacbook()
        XCTAssertEqual(EdgeProtocol.countdownLead, 10)
        XCTAssertTrue(msg(.hotkeyDown, from: "mini").contains(.scheduleCountdown("s1", 110)))
        msg(.hotkeyCancel, from: "mini")
        XCTAssertTrue(msg(.hotkeyToggle, from: "mini").contains(.scheduleCountdown("s1", 110)))
    }

    func testCountdownTellsTheBadgeMacAndTheInitiatorNotTheMicOwner() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        // mini started it and is the target; macbook only has the mic.
        XCTAssertEqual(broker.apply(.countdownFired("s1")), [
            .send("mini", .sessionCountdown(sessionId: "s1", secondsLeft: 10))
        ])
    }

    func testCountdownGoesToBothWhenThePointerMovedTheBadgeElsewhere() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        now = 1
        msg(.pointerPresence, from: "macbook")
        XCTAssertEqual(broker.session?.target, "macbook")
        XCTAssertEqual(broker.apply(.countdownFired("s1")), [
            .send("macbook", .sessionCountdown(sessionId: "s1", secondsLeft: 10)),
            .send("mini", .sessionCountdown(sessionId: "s1", secondsLeft: 10))
        ])
    }

    func testCountdownFollowsTheBadgeToANewTargetWithWhatIsLeft() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        now = 100
        broker.apply(.countdownFired("s1"))
        now = 104
        let effects = msg(.pointerPresence, from: "macbook")
        XCTAssertTrue(effects.contains(.send("macbook", .sessionCountdown(sessionId: "s1", secondsLeft: 6))))
    }

    func testCountdownIsCancelledWhenTheKeyComesUp() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        broker.apply(.countdownFired("s1"))
        msg(.hotkeyUp(reason: .key), from: "mini")
        XCTAssertTrue(broker.apply(.releaseGraceFired("s1")).contains(.cancelCountdown("s1")))
    }

    func testCountdownIsCancelledWhenTheSessionEndsEarly() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        XCTAssertTrue(msg(.hotkeyCancel, from: "mini").contains(.cancelCountdown("s1")))
    }

    func testStaleOrLateCountdownIsIgnored() {
        connectMini(); connectMacbook()
        XCTAssertEqual(broker.apply(.countdownFired("s1")), [])          // no session
        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(broker.apply(.countdownFired("other")), [])       // wrong id
        msg(.hotkeyUp(reason: .key), from: "mini")
        broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(broker.apply(.countdownFired("s1")), [])          // already processing
    }
}

extension SessionBrokerTests {
    func testWorkspaceInsertionBudgetAccumulatesWithOtherLongSteps() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        deliverAudio()
        let plan = VoiceLaunchPlan(commandId: "test", commandName: "Test", slots: [], steps: [
            VoiceStep(kind: .runWorkspace, text: "writing"),
            VoiceStep(kind: .runAppleShortcut, shortcutName: "Synthetic", timeoutSeconds: 120),
            VoiceStep(kind: .confirm, text: "Continue", seconds: 3),
            VoiceStep(kind: .runWorkspace, text: "reading")], mainText: "writing")
        broker.attachLaunch(plan, sessionId: "s1")
        let effects = broker.apply(.transcriptionFinished("s1", text: "writing", inferenceMs: nil, error: nil))
        let timeout = effects.compactMap { effect -> TimeInterval? in
            if case .scheduleWatchdog(_, let seconds) = effect { return seconds }
            return nil
        }.first
        // Two 45-second workspace runs plus a 120-second Apple Shortcut and
        // its cancel pause must fit, even though each exceeds a normal paste.
        XCTAssertGreaterThan(try! XCTUnwrap(timeout), 45 + 120 + 3 + 45)
    }
}

extension SessionBrokerTests {
    func testSessionDestinationUsesTargetMacAppAfterPointerOnlyReport() throws {
        connectMini()
        connectMacbook()
        msg(.focusClaim(appBundleId: "com.test.Mini"), from: "mini")
        msg(.focusClaim(appBundleId: "com.test.Book"), from: "macbook")
        msg(.pointerPresence, from: "macbook")
        msg(.hotkeyDown, from: "macbook")
        XCTAssertEqual(broker.session?.destinationBundleID, "com.test.Book")
        msg(.pointerPresence, from: "mini")
        XCTAssertEqual(broker.session?.destinationBundleID, "com.test.Mini")
    }
}

extension SessionBrokerTests {
    private func resetBroker() {
        now = 0
        broker = SessionBroker(coreId: "test", clock: { self.now }, makeSessionID: { "s1" })
    }

    private func busyError(_ edge: EdgeID) -> BrokerEffect {
        .send(edge, .error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
    }

    func testImmediateStartWithAbsentOrMatchingClaimInBothModes() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            for matching in [false, true] {
                resetBroker()
                connect("here", caps: macbookCaps); connect("there", caps: macbookCaps)
                if matching { msg(.pointerPresence, from: "here") }
                let effects = msg(gesture, from: "here")
                XCTAssertEqual(broker.session?.initiator, "here")
                XCTAssertTrue(effects.contains(.send("here", .captureStart(sessionId: "s1"))))
                XCTAssertFalse(effects.contains { if case .schedulePressSettle = $0 { return true }; return false })
            }
        }
    }

    func testConflictingClaimWaitsThenLonePressRefreshesPointerAndNextPressIsImmediate() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connect("here", caps: macbookCaps); connect("there", caps: macbookCaps)
            msg(.pointerPresence, from: "there")
            now = 1
            XCTAssertEqual(msg(gesture, from: "here"), [.schedulePressSettle(1, 0.15)])
            XCTAssertNil(broker.session)
            now = 1.15
            XCTAssertTrue(broker.apply(.pressSettled(1)).contains(.send("here", .captureStart(sessionId: "s1"))))
            XCTAssertEqual(broker.session?.initiator, "here")
            XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "here")
            msg(.hotkeyCancel, from: "here")
            XCTAssertFalse(msg(gesture, from: "here").contains { if case .schedulePressSettle = $0 { return true }; return false })
            XCTAssertNotNil(broker.session)
        }
    }

    func testMissingMicWaitsWithAbsentOfflineOrMiclessPreferenceInBothModes() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            for preference in [nil, "offline", "mini"] as [EdgeID?] {
                resetBroker()
                connectMini(chooseRemoteMic: false); connectMacbook()
                broker.apply(.micOwnerChanged(preference))
                XCTAssertEqual(msg(gesture, from: "mini"), [.schedulePressSettle(1, 0.15)])
                XCTAssertNil(broker.session)
            }
        }
    }

    func testMissingMicStillNeedsEvidenceOnTheNextPressDespiteRefreshedPointer() {
        connectMini(chooseRemoteMic: false); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        broker.apply(.pressSettled(1))
        XCTAssertNil(broker.session)
        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "mini")
        // The pointer is resolved, but using another mic still requires evidence.
        XCTAssertEqual(msg(.hotkeyDown, from: "mini"), [.schedulePressSettle(2, 0.15)])
    }

    func testValidMicPreferenceAvoidsWaitWithoutConflictingClaimInBothModes() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connectMini(); connectMacbook()
            let effects = msg(gesture, from: "mini")
            XCTAssertEqual(broker.session?.initiator, "mini")
            XCTAssertEqual(broker.session?.micOwner, "macbook")
            XCTAssertFalse(effects.contains { if case .schedulePressSettle = $0 { return true }; return false })
        }
    }

    func testSecondConnectedPresserStartsUsingRestrictedClaimOrFirstPresserInBothModes() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            for claimed in [false, true] {
                resetBroker()
                connect("first", caps: macbookCaps); connect("second", caps: macbookCaps)
                connect("bystander", caps: macbookCaps)
                if claimed { msg(.pointerPresence, from: "second") }
                now = 1
                msg(.pointerPresence, from: "bystander")
                XCTAssertEqual(msg(gesture, from: "first"), [.schedulePressSettle(1, 0.15)])
                now = 1.01
                let effects = msg(gesture, from: "second")
                XCTAssertEqual(effects.first, .cancelPressSettle(1))
                let initiator = claimed ? "second" : "first"
                XCTAssertEqual(broker.session?.initiator, initiator)
                XCTAssertTrue(effects.contains(.send(initiator, .captureStart(sessionId: "s1"))))
                XCTAssertEqual(broker.apply(.pressSettled(1)), [])
                XCTAssertEqual(broker.session?.phase, .recording)
            }
        }
    }

    func testPendingRepeatDifferentGestureAndUnknownReporterAreLoggedAndIgnored() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connectMini(chooseRemoteMic: false); connectMacbook()
            msg(gesture, from: "mini")
            let other: EdgeMessage = gesture == .hotkeyDown ? .hotkeyToggle : .hotkeyDown
            for (message, edge) in [(gesture, "mini"), (other, "macbook"), (gesture, "unknown")] {
                let effects = msg(message, from: edge)
                XCTAssertFalse(effects.isEmpty)
                XCTAssertTrue(effects.allSatisfy { if case .log = $0 { return true }; return false })
                XCTAssertNil(broker.session)
            }
            XCTAssertTrue(broker.apply(.pressSettled(1)).contains(.send("mini", .error(code: "noMic", message: DictationAlert.microphoneOnAnotherMac().encoded))))
        }
    }

    func testPendingQuickReleaseReplaysNormalHoldReleaseAfterSettle() {
        connectMini(); connectMacbook()
        msg(.pointerPresence, from: "macbook")
        msg(.hotkeyDown, from: "mini")
        XCTAssertEqual(msg(.hotkeyUp(reason: .key), from: "mini"), [])
        now = 1
        let effects = broker.apply(.pressSettled(1))
        XCTAssertTrue(effects.contains(.send("macbook", .captureStart(sessionId: "s1"))))
        XCTAssertEqual(effects.last, .scheduleReleaseGrace("s1", SessionBroker.releaseGrace))
        broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testPendingReleasedPresserDoesNotKeepTheSecondPresserHeld() {
        connectMini(chooseRemoteMic: false); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        msg(.hotkeyUp(reason: .key), from: "mini")
        let effects = msg(.hotkeyDown, from: "macbook")
        XCTAssertEqual(effects.first, .cancelPressSettle(1))
        XCTAssertFalse(effects.contains(.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)))
        XCTAssertEqual(msg(.hotkeyUp(reason: .key), from: "macbook"), [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])
    }

    func testPendingToggleReleaseDoesNotStopHandsFreeRecording() {
        connectMini(); connectMacbook()
        msg(.pointerPresence, from: "macbook")
        msg(.hotkeyToggle, from: "mini")
        msg(.hotkeyUp(reason: .key), from: "mini")
        let effects = broker.apply(.pressSettled(1))
        XCTAssertEqual(broker.session?.handsFree, true)
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertFalse(effects.contains { if case .scheduleReleaseGrace = $0 { return true }; return false })
    }

    func testPendingCancelOnlyByPresserAndPressIDsIncrease() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connectMini(chooseRemoteMic: false); connectMacbook()
            msg(gesture, from: "mini")
            XCTAssertEqual(msg(.hotkeyCancel, from: "macbook"), [])
            XCTAssertEqual(msg(.hotkeyCancel, from: "mini"), [.cancelPressSettle(1)])
            XCTAssertNil(broker.session)
            XCTAssertEqual(broker.apply(.pressSettled(1)), [])
            XCTAssertEqual(msg(gesture, from: "mini"), [.schedulePressSettle(2, 0.15)])
            XCTAssertEqual(broker.apply(.pressSettled(1)), [])
            XCTAssertNil(broker.session)
        }
    }

    func testPendingVoiceCommandModeIsInFirstBroadcastInBothModesAndStartPaths() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            for second in [false, true] {
                resetBroker()
                connectMini(); connectMacbook()
                msg(.pointerPresence, from: "macbook")
                msg(gesture, from: "mini")
                msg(.voiceCommandMode(), from: "mini")
                let effects = second ? msg(gesture, from: "macbook") : broker.apply(.pressSettled(1))
                XCTAssertEqual(broker.session?.voiceCommandMode, true)
                let states = effects.compactMap { effect -> SessionStateUpdate? in
                    if case .send(_, .sessionState(let update)) = effect { return update }; return nil
                }
                XCTAssertEqual(states.count, 2)
                XCTAssertTrue(states.allSatisfy { $0.voiceCommandMode == true })
            }
        }
    }

    func testDisconnectOfPendingPresserCancelsAndStaleSettleDoesNothing() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connectMini(chooseRemoteMic: false); connectMacbook()
            msg(gesture, from: "mini")
            XCTAssertEqual(broker.apply(.edgeDisconnected("mini")), [.cancelPressSettle(1)])
            XCTAssertEqual(broker.apply(.pressSettled(1)), [])
            XCTAssertNil(broker.session)
        }
    }

    func testDisconnectOfPendingBystanderPreservesPressAndWrongIDIsIgnored() {
        connect("here", caps: macbookCaps); connect("there", caps: macbookCaps)
        msg(.pointerPresence, from: "there")
        msg(.hotkeyDown, from: "here")
        XCTAssertEqual(broker.apply(.edgeDisconnected("there")), [])
        XCTAssertEqual(broker.apply(.pressSettled(99)), [])
        XCTAssertNil(broker.session)
        broker.apply(.pressSettled(1))
        XCTAssertEqual(broker.session?.initiator, "here")
    }

    func testAnotherPresserSuppliesMicAndExplicitPreferenceStillWins() {
        for preferred in [false, true] {
            resetBroker()
            connectMini(chooseRemoteMic: false); connectMacbook(); connect("chosen", caps: macbookCaps)
            if preferred {
                broker.apply(.micOwnerChanged("chosen"))
                msg(.pointerPresence, from: "chosen")
            }
            msg(.hotkeyDown, from: "mini")
            msg(.hotkeyDown, from: "macbook")
            XCTAssertEqual(broker.session?.initiator, "mini")
            XCTAssertEqual(broker.session?.micOwner, preferred ? "chosen" : "macbook")
        }
    }

    func testNoMicAnywhereReportsLegacyErrorWithoutWaitingInBothModes() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connectMini(chooseRemoteMic: false)
            let effects = msg(gesture, from: "mini")
            XCTAssertTrue(effects.contains(.send("mini", .error(code: "noMic", message: "No connected edge has a microphone."))))
            XCTAssertFalse(effects.contains { if case .schedulePressSettle = $0 { return true }; return false })
            XCTAssertNil(broker.session)
        }
    }

    func testPreSessionClaimsCannotMoveLiveOrFinalTargetInEitherMode() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connectMini(); connectMacbook()
            msg(.pointerPresence, from: "macbook")
            now = 1
            msg(gesture, from: "mini")
            now = 2
            broker.apply(.pressSettled(1))
            XCTAssertEqual(broker.session?.target, "mini")
            now = 3
            XCTAssertEqual(msg(.focusClaim(appBundleId: "bystander"), from: "macbook"), [])
            if gesture == .hotkeyToggle { msg(.hotkeyToggle, from: "mini") }
            else { msg(.hotkeyUp(reason: .key), from: "mini"); broker.apply(.releaseGraceFired("s1")) }
            deliverAudio()
            let effects = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
            XCTAssertTrue(effects.contains(.send("mini", .insert(sessionId: "s1", text: "hi"))))
        }
    }

    func testStalePointerCannotBeatNewPresserKeystrokeAndNewPointerWins() {
        for gesture in [EdgeMessage.hotkeyDown, .hotkeyToggle] {
            resetBroker()
            connectMini(); connectMacbook(); connect("third", caps: macbookCaps)
            msg(.pointerPresence, from: "mini")
            now = 1
            msg(gesture, from: "mini")
            msg(gesture, from: "macbook") // hold join or absorbed toggle adds a presser
            now = 2
            msg(.focusClaim(appBundleId: "pressed"), from: "macbook")
            XCTAssertEqual(broker.session?.target, "macbook")
            now = 3
            msg(.pointerPresence, from: "third")
            XCTAssertEqual(broker.session?.target, "third")
            now = 4
            msg(.focusClaim(appBundleId: "newer-but-ambiguous"), from: "mini")
            XCTAssertEqual(broker.session?.target, "third")
            now = 5
            msg(.pointerPresence, from: "mini")
            XCTAssertEqual(broker.session?.target, "mini")
        }
    }

    func testClaimsAtStartedAtAreEligibleAndTiesUseReceiptOrder() {
        connectMini(); connectMacbook()
        now = 10
        msg(.hotkeyDown, from: "mini")
        msg(.pointerPresence, from: "macbook")
        XCTAssertEqual(broker.session?.target, "macbook")
        msg(.pointerPresence, from: "mini")
        XCTAssertEqual(broker.session?.target, "mini")
    }

    func testAbsorbedToggleAddsAPresserForKeystrokeRouting() {
        connectMini(); connectMacbook()
        msg(.hotkeyToggle, from: "mini")
        now = 0.01
        msg(.hotkeyToggle, from: "macbook")
        now = 1
        msg(.focusClaim(appBundleId: "pressed"), from: "macbook")
        XCTAssertEqual(broker.session?.target, "macbook")
    }

    func testDisconnectedInitiatorAndOnlyBystanderKeystrokesLeaveNoTarget() {
        connectMini(); connectMacbook()
        startAndStopRecording(); deliverAudio()
        broker.apply(.edgeDisconnected("mini"))
        now = 1
        msg(.focusClaim(appBundleId: "unrelated"), from: "macbook")
        XCTAssertNil(broker.session?.target)
        let effects = broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertNil(broker.session)
        XCTAssertFalse(effects.contains { if case .send(_, .insert) = $0 { return true }; return false })
    }

    func testBusyNoticesArePerMacSharedAcrossGesturesAndExpireAtTwoSeconds() {
        connectMini(); connectMacbook()
        startAndStopRecording()
        now = 1
        XCTAssertTrue(msg(.hotkeyDown, from: "mini").contains(busyError("mini")))
        XCTAssertFalse(msg(.hotkeyToggle, from: "mini").contains(busyError("mini")))
        XCTAssertTrue(msg(.hotkeyToggle, from: "macbook").contains(busyError("macbook")))
        now = 2.999
        XCTAssertFalse(msg(.hotkeyDown, from: "mini").contains(busyError("mini")))
        now = 3
        XCTAssertTrue(msg(.hotkeyToggle, from: "mini").contains(busyError("mini")))
        XCTAssertEqual(SessionBroker.busyNoticeInterval, 2)
    }

    func testBothGesturesAreBusyWhileInserting() {
        connectMini(); connectMacbook()
        startAndStopRecording(); deliverAudio()
        broker.apply(.transcriptionFinished("s1", text: "hi", inferenceMs: nil, error: nil))
        XCTAssertTrue(msg(.hotkeyDown, from: "mini").contains(busyError("mini")))
        XCTAssertTrue(msg(.hotkeyToggle, from: "macbook").contains(busyError("macbook")))
        XCTAssertEqual(broker.session?.phase, .inserting)
    }

    func testJoiningAndAbsorbedTogglesDoNotSpendBusyNoticeBudget() {
        connectMini(); connectMacbook()
        msg(.hotkeyDown, from: "mini")
        XCTAssertFalse(msg(.hotkeyDown, from: "macbook").contains(busyError("macbook")))
        XCTAssertTrue(msg(.hotkeyToggle, from: "macbook").contains(busyError("macbook")))
        msg(.hotkeyCancel, from: "mini")
        now = 3
        msg(.hotkeyToggle, from: "mini")
        XCTAssertFalse(msg(.hotkeyToggle, from: "macbook").contains(busyError("macbook")))
        XCTAssertTrue(msg(.hotkeyDown, from: "macbook").contains(busyError("macbook")))
    }

    func testAlertFactoriesMatchTheContract() {
        let mic = DictationAlert.microphoneOnAnotherMac()
        XCTAssertEqual(mic.title, "This Mac has no microphone")
        XCTAssertEqual(mic.detail, "Dictator only listens through another Mac if you choose it. Pick one under Mac that records in Settings › Your Macs.")
        XCTAssertEqual(mic.action, .macs)
        let busy = DictationAlert.dictationStillFinishing()
        XCTAssertEqual(busy.title, "Still finishing your last dictation")
        XCTAssertEqual(busy.detail, "Nothing was recorded from that press. Wait a moment, then press the key again.")
        XCTAssertNil(busy.action)
    }
}
