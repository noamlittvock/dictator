import AVFoundation
import XCTest
@testable import Dictator

/// Covers `EdgeRuntime` behavior that doesn't require a live
/// mic/hotkey/transport, such as `resetSession` and the `insert` session
/// gate. `EdgeRuntime`'s init only constructs its device-bound services
/// (`AudioCaptureService`, `HotkeyService`, `IndicatorWindowController`) —
/// it never starts them until `setup()`, which none of these tests call, so
/// this is safe to run headless. Sounds/indicator visuals are not asserted
/// on; a stub-free test host is fine as long as the calls themselves are
/// harmless (they are: `SoundService`/`IndicatorWindowController` calls are
/// silent no-ops-to-the-eye in a test host).
@MainActor
final class EdgeRuntimeTests: XCTestCase {
    private func makeRuntime(edgeId: EdgeID = "me") -> EdgeRuntime {
        EdgeRuntime(edgeId: edgeId, edgeName: "Test Mac")
    }

    private func recordingState(
        sessionId: SessionID = "s1",
        initiator: EdgeID = "me",
        micOwner: EdgeID = "me",
        target: EdgeID? = nil
    ) -> SessionStateUpdate {
        SessionStateUpdate(sessionId: sessionId, state: .recording, initiator: initiator, micOwner: micOwner, target: target, outcome: nil)
    }

    func testNoMicDecodesAnotherMacAlertAndKeepsLegacyFallback() {
        let runtime = makeRuntime()
        let alert = DictationAlert.microphoneOnAnotherMac()
        runtime.handle(.error(code: "noMic", message: alert.encoded))
        XCTAssertEqual(runtime.alerts.current, alert)
        XCTAssertEqual(runtime.micWarning, alert.title)
        XCTAssertEqual(runtime.alerts.current?.action, .macs)

        runtime.handle(.error(code: "noMic", message: "No connected edge has a microphone."))
        XCTAssertEqual(runtime.alerts.current, .noMicrophone())
        XCTAssertEqual(runtime.micWarning, "None of your Macs has a microphone available.")
    }

    func testBusyReplyAcknowledgesPendingPressWithoutFallingBack() async throws {
        for handsFree in [false, true] {
            let (runtime, sent) = chordRuntime()
            defer { runtime.resetSession(reason: "test cleanup") }
            runtime.handle(.config(handsFree: handsFree))
            runtime.isMainMacLive = { true }
            runtime.startAckTimeout = 0.1
            var fellBack = false
            runtime.onMainMacUnreachable = { fellBack = true }
            runtime.hotkeyService.onStart?()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertNotNil(runtime.pendingStart)
            runtime.handle(.error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
            XCTAssertNil(runtime.pendingStart)
            XCTAssertFalse(runtime.hotkeyService.cancelEligible)
            XCTAssertEqual(runtime.phase, .idle)
            XCTAssertEqual(runtime.alerts.current?.title, DictationAlert.dictationStillFinishing().title)
            XCTAssertEqual(runtime.alerts.current?.tone, .notice)
            XCTAssertNil(runtime.micWarning)
            runtime.hotkeyService.onCharacterChord?()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(fellBack)
            XCTAssertEqual(sent(), [handsFree ? .hotkeyToggle : .hotkeyDown])
        }
    }

    func testBusyReplyPreservesCurrentSessionAndDisarmsRejectedChord() async throws {
        for phase in [SessionPhase.recording, .processing, .inserting] {
            let (runtime, sent) = chordRuntime()
            let state = SessionStateUpdate(sessionId: "earlier", state: phase, initiator: "me", micOwner: "me", target: nil, outcome: nil)
            runtime.handle(.sessionState(state))
            var current = snapshot("earlier", phase)
            runtime.localSession = { current }
            try await pressAndChord(runtime) {
                runtime.handle(.error(code: "sessionBusy", message: DictationAlert.dictationStillFinishing().encoded))
                // Even if a newer recording starts before a character arrives,
                // the rejected press no longer owns its cancellation decision.
                current = self.snapshot("later")
            }
            XCTAssertEqual(sent(), [.hotkeyDown])
            XCTAssertEqual(runtime.lastSessionState, state)
            XCTAssertEqual(runtime.phase, phase)
            XCTAssertEqual(runtime.hotkeyService.cancelEligible, phase == .processing)
            XCTAssertEqual(runtime.alerts.current?.tone, .notice)
        }
    }

    // MARK: - Exclusive Teach / dictation microphone ownership

    private func appendSyntheticAudio(to service: AudioCaptureService) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for i in 0..<160 { buffer.floatChannelData?[0][i] = i.isMultiple(of: 2) ? 0.2 : -0.2 }
        service.finishHandlingAudioBuffer(buffer, generation: try XCTUnwrap(service.beginHandlingAudioBuffer()))
    }

    func testRecordingLimitNoticeIsInitiatorOnlyAndShownOnce() {
        let runtime = makeRuntime()
        var update = SessionStateUpdate(sessionId: "limit", state: .processing,
                                        initiator: "me", micOwner: "mic", target: nil, outcome: nil,
                                        recordingLimitReached: true)
        runtime.handle(.sessionState(update))
        XCTAssertEqual(runtime.alerts.current, .recordingLimitReached)
        XCTAssertEqual(runtime.phase, .processing)
        runtime.alerts.hide()
        runtime.handle(.sessionState(update))
        XCTAssertNil(runtime.alerts.current, "a repeated state must not repeat the notice")
        update.state = .idle
        update.outcome = .pasted
        runtime.handle(.sessionState(update))
        XCTAssertNil(runtime.alerts.current)

        let other = makeRuntime(edgeId: "mic")
        update.state = .processing
        other.handle(.sessionState(update))
        XCTAssertNil(other.alerts.current)
        update.sessionId = "ordinary"
        update.recordingLimitReached = nil
        runtime.handle(.sessionState(update))
        XCTAssertNil(runtime.alerts.current, "older peers and ordinary releases have no notice")
    }

    func testIndicatorShowsVoiceLaunchOnlyOnTheMacShowingIt() {
        let runtime = makeRuntime()
        var update = SessionStateUpdate(sessionId: "s1", state: .recording, initiator: "laptop", micOwner: "laptop", target: "me", outcome: nil)
        runtime.handle(.sessionState(update))
        XCTAssertFalse(runtime.indicator.showsVoiceLaunch)

        update.voiceCommandMode = true
        runtime.handle(.sessionState(update))
        XCTAssertTrue(runtime.indicator.showsVoiceLaunch)

        update.state = .processing
        runtime.handle(.sessionState(update))
        XCTAssertFalse(runtime.indicator.showsVoiceLaunch)

        let elsewhere = makeRuntime(edgeId: "desk")
        update.state = .recording
        elsewhere.handle(.sessionState(update))
        XCTAssertFalse(elsewhere.indicator.showsVoiceLaunch)
    }

    func testDuplicateTeachBeginPreservesTheOriginalTake() throws {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        audio.sampleRateOverrideForTesting = 16_000
        defer { runtime.cancelTeachRecording() }
        XCTAssertTrue(runtime.beginTeachRecording())
        try appendSyntheticAudio(to: audio)
        let generation = audio.captureGeneration

        XCTAssertFalse(runtime.beginTeachRecording())
        XCTAssertEqual(audio.captureGeneration, generation)
        XCTAssertEqual(runtime.endTeachRecording()?.frameCount, 160)
        XCTAssertNil(runtime.endTeachRecording())
        XCTAssertFalse(audio.isCaptureActive)
        XCTAssertTrue(runtime.beginTeachRecording(), "ending a take releases ownership")
    }

    func testTeachCannotStopOrCancelAnActiveDictation() throws {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        audio.sampleRateOverrideForTesting = 16_000
        defer { runtime.resetSession(reason: "test cleanup") }
        runtime.handle(.sessionState(recordingState()))
        runtime.handle(.captureStart(sessionId: "s1"))
        try appendSyntheticAudio(to: audio)
        var frames: Int?
        runtime.sendAudio = { frames = $0.frameCount; _ = $1 }

        XCTAssertFalse(runtime.beginTeachRecording())
        XCTAssertNil(runtime.endTeachRecording())
        runtime.cancelTeachRecording()

        XCTAssertTrue(audio.isCaptureActive)
        runtime.handle(.captureStop(sessionId: "s1"))
        XCTAssertEqual(frames, 160)
    }

    func testTeachRejectsDictationStartsAndIgnoresTheirStopAndCancel() async throws {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        audio.sampleRateOverrideForTesting = 16_000
        defer { runtime.cancelTeachRecording() }
        XCTAssertTrue(runtime.beginTeachRecording())
        try appendSyntheticAudio(to: audio)
        let generation = audio.captureGeneration
        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }

        runtime.startDictation(.hotkeyDown)
        runtime.wireHotkey()
        runtime.hotkeyService.onStop?(.key)
        runtime.hotkeyService.onCancel?()
        runtime.hotkeyService.onVoiceCommandMode?()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(sent.isEmpty, "a local hotkey must not ask the broker to start over Teach")
        runtime.handle(.captureStart(sessionId: "racing-session"))
        XCTAssertEqual(sent, [.captureFailed(sessionId: "racing-session", message: EdgeRuntime.microphoneBusyMessage)])
        runtime.handle(.captureStop(sessionId: "racing-session"))
        runtime.handle(.captureCancel(sessionId: "racing-session"))

        XCTAssertEqual(audio.captureGeneration, generation)
        XCTAssertTrue(runtime.isTeachRecording)
        XCTAssertEqual(runtime.endTeachRecording()?.frameCount, 160)
    }

    func testReplayedStartAndStaleStopCannotReplaceOrEndAnotherDictation() throws {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        audio.sampleRateOverrideForTesting = 16_000
        defer { runtime.resetSession(reason: "test cleanup") }
        runtime.handle(.sessionState(recordingState()))
        runtime.handle(.captureStart(sessionId: "s1"))
        try appendSyntheticAudio(to: audio)
        let generation = audio.captureGeneration
        var frames: Int?
        runtime.sendAudio = { frames = $0.frameCount; _ = $1 }

        runtime.handle(.captureStart(sessionId: "s1"))
        runtime.handle(.captureStart(sessionId: "other"))
        runtime.handle(.captureStop(sessionId: "other"))
        runtime.handle(.captureCancel(sessionId: "other"))

        XCTAssertEqual(audio.captureGeneration, generation)
        XCTAssertTrue(audio.isCaptureActive)
        runtime.handle(.captureStop(sessionId: "s1"))
        XCTAssertEqual(frames, 160)
    }

    func testTeachCannotAcquireAudioWhileADictationStartIsPending() {
        let runtime = makeRuntime()
        defer { runtime.resetSession(reason: "test cleanup") }
        runtime.isMainMacLive = { true }
        runtime.startDictation(.hotkeyDown)
        XCTAssertNotNil(runtime.pendingStart)
        XCTAssertFalse(runtime.beginTeachRecording())
    }

    func testSessionResetDoesNotAbandonTeach() throws {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        defer { runtime.cancelTeachRecording() }
        XCTAssertTrue(runtime.beginTeachRecording())
        runtime.handle(.sessionState(recordingState()))
        runtime.resetSession(reason: "transport changed during Teach")
        XCTAssertTrue(audio.isCaptureActive)
        XCTAssertTrue(runtime.isTeachRecording)
    }

    func testConnectionLossDuringTeachKeepsTheTakeWithoutDictationRecoveryAlert() throws {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        audio.sampleRateOverrideForTesting = 16_000
        defer { runtime.cancelTeachRecording() }
        XCTAssertTrue(runtime.beginTeachRecording())
        try appendSyntheticAudio(to: audio)

        runtime.resetSession(reason: "unrelated transport dropped", connectionLost: true)

        XCTAssertNil(runtime.alerts.current)
        XCTAssertTrue(audio.isCaptureActive)
        XCTAssertTrue(runtime.isTeachRecording)
        XCTAssertEqual(runtime.endTeachRecording()?.frameCount, 160)
    }

    func testTeachLeavesAnUnownedExistingCaptureAlone() {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        audio.startCapture()
        defer { audio.cancelCapture() }
        XCTAssertFalse(runtime.beginTeachRecording())
        XCTAssertNil(runtime.endTeachRecording())
        runtime.cancelTeachRecording()
        XCTAssertTrue(audio.isCaptureActive)
    }

    func testResetFinalizesOwnedAudioEvenBetweenProcessingStateAndCaptureStop() {
        let (runtime, _, audio) = makeRuntimeWithCheckpointStore()
        audio.sampleRateOverrideForTesting = 16_000
        defer { runtime.cancelTeachRecording() }
        runtime.handle(.sessionState(recordingState()))
        runtime.handle(.captureStart(sessionId: "s1"))
        runtime.handle(.sessionState(SessionStateUpdate(sessionId: "s1", state: .processing, initiator: "me", micOwner: "me", target: nil, outcome: nil)))

        runtime.resetSession(reason: "connection lost before stop arrived", connectionLost: true)

        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.recordingKeptHereAlert)

        XCTAssertFalse(audio.isCaptureActive)
        XCTAssertTrue(runtime.beginTeachRecording(), "reset releases the old dictation's capture ownership")
    }

    // MARK: - resetSession

    func testResetSessionFromRecordingGoesIdleAndClearsFlags() {
        let runtime = makeRuntime()
        runtime.handle(.sessionState(recordingState()))
        XCTAssertEqual(runtime.phase, .recording)
        XCTAssertTrue(runtime.isInitiator)
        XCTAssertTrue(runtime.isMicOwner)
        XCTAssertFalse(runtime.hotkeyService.cancelEligible) // only true while .processing

        runtime.resetSession(reason: "test transport loss")

        XCTAssertEqual(runtime.phase, .idle)
        XCTAssertFalse(runtime.isInitiator)
        XCTAssertFalse(runtime.isMicOwner)
        XCTAssertFalse(runtime.isTarget)
        XCTAssertNil(runtime.lastSessionState)
        XCTAssertFalse(runtime.hotkeyService.cancelEligible)
    }

    func testResetSessionFromProcessingClearsCancelEligibleAndDictationBusy() {
        let runtime = makeRuntime()
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .processing, initiator: "me", micOwner: "me", target: nil, outcome: nil
        )))
        XCTAssertTrue(runtime.hotkeyService.cancelEligible)

        runtime.resetSession(reason: "test")

        XCTAssertEqual(runtime.phase, .idle)
        XCTAssertFalse(runtime.hotkeyService.cancelEligible)
    }

    // MARK: - Insert session gate

    func testHandleInsertWithoutMatchingInsertingSessionRepliesFailed() {
        let runtime = makeRuntime()
        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }

        // No sessionState has been seen at all — an unsolicited `insert`.
        runtime.handle(.insert(sessionId: "s1", text: "hello"))

        XCTAssertEqual(sent.count, 1)
        guard case .insertResult(let sessionId, let outcome, let destination) = sent.first else {
            return XCTFail("expected an insertResult reply, got \(sent)")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertNil(destination)
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a .failed outcome, got \(outcome)")
        }
        XCTAssertEqual(message, "This Mac got text for a dictation it wasn’t running, so it didn’t type it.")
    }

    func testHandleInsertWithWrongTargetRepliesFailedAndDoesNotPaste() {
        let runtime = makeRuntime(edgeId: "me")
        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }

        // This machine is told it's inserting, but the target is someone else.
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .inserting, initiator: "me", micOwner: "me", target: "other-edge", outcome: nil
        )))
        runtime.handle(.insert(sessionId: "s1", text: "hello"))

        XCTAssertEqual(sent.count, 1)
        guard case .insertResult(_, let outcome, _) = sent.first else {
            return XCTFail("expected an insertResult reply, got \(sent)")
        }
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a .failed outcome, got \(outcome)")
        }
        XCTAssertEqual(message, "This Mac got text for a dictation it wasn’t running, so it didn’t type it.")
    }

    func testHandleInsertWithStaleSessionIdRepliesFailed() {
        let runtime = makeRuntime(edgeId: "me")
        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }

        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .inserting, initiator: "me", micOwner: "me", target: "me", outcome: nil
        )))
        // A different (e.g. replayed/stale) session id arrives as `insert`.
        runtime.handle(.insert(sessionId: "s0-stale", text: "hello"))

        XCTAssertEqual(sent.count, 1)
        guard case .insertResult(let sessionId, let outcome, _) = sent.first else {
            return XCTFail("expected an insertResult reply, got \(sent)")
        }
        XCTAssertEqual(sessionId, "s0-stale")
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a .failed outcome, got \(outcome)")
        }
        XCTAssertEqual(message, "This Mac got text for a dictation it wasn’t running, so it didn’t type it.")
    }

    // MARK: - sessionState → captureStart marks initiator (order dependency)

    func testSessionStateRecordingThenCaptureStartMarksInitiator() {
        // Temp checkpoint store and a fixed sample rate, so no real audio
        // hardware is asked for its format.
        let (runtime, _, audioService) = makeRuntimeWithCheckpointStore(edgeId: "me")
        audioService.sampleRateOverrideForTesting = 48_000
        runtime.handle(.sessionState(recordingState()))
        XCTAssertTrue(runtime.isInitiator)
        XCTAssertEqual(runtime.phase, .recording)

        // Once `sessionState(recording)` has landed first, `captureStart`
        // reads a fresh `isInitiator` rather than a stale one — the fix for
        // the missing start-sound bug lives on the broker's send order
        // (out of this agent's scope); this only confirms EdgeRuntime's own
        // side reads current state, not a snapshot from hello time.
        runtime.handle(.captureStart(sessionId: "s1"))
        XCTAssertTrue(runtime.isInitiator)
        XCTAssertEqual(runtime.phase, .recording)
    }

    // MARK: - A typed-character chord only drops the session its own press started

    private func chordRuntime() -> (EdgeRuntime, () -> [EdgeMessage]) {
        let runtime = makeRuntime()
        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }
        runtime.wireHotkey()
        return (runtime, { sent })
    }

    private func snapshot(_ id: SessionID, initiator: EdgeID = "me", _ phase: SessionPhase = .recording) -> SessionSnapshot {
        SessionSnapshot(id: id, phase: phase, initiator: initiator, micOwner: initiator, target: nil)
    }

    private func pressAndChord(_ runtime: EdgeRuntime, whileHeld: (() -> Void)? = nil) async throws {
        runtime.hotkeyService.onStart?()
        try await Task.sleep(nanoseconds: 50_000_000)
        whileHeld?()
        runtime.hotkeyService.onCharacterChord?()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testLocalBrokerOwnNewRecordingIsCancelledByAChord() async throws {
        let (runtime, sent) = chordRuntime()
        var current: SessionSnapshot?
        runtime.localSession = { current }
        try await pressAndChord(runtime) { current = self.snapshot("new") }
        XCTAssertEqual(sent(), [.hotkeyDown, .pressAbandoned, .hotkeyCancel])
    }

    func testLocalBrokerEarlierProcessingSessionIsNeverCancelled() async throws {
        let (runtime, sent) = chordRuntime()
        runtime.localSession = { self.snapshot("s1", .processing) }
        try await pressAndChord(runtime)
        XCTAssertEqual(sent(), [.hotkeyDown, .pressAbandoned, .hotkeyUp(reason: .key)])
    }

    func testLocalBrokerEarlierRecordingOfThisMacIsNotNewSoNotCancelled() async throws {
        let (runtime, sent) = chordRuntime()
        runtime.localSession = { self.snapshot("s1") }
        try await pressAndChord(runtime)
        XCTAssertEqual(sent(), [.hotkeyDown, .pressAbandoned, .hotkeyUp(reason: .key)])
    }

    func testRemoteMainMacOnlyReleasesEvenWhenThisMacIsTheInitiator() async throws {
        let (runtime, sent) = chordRuntime() // no local broker: remote
        try await pressAndChord(runtime) {
            runtime.handle(.sessionState(SessionStateUpdate(
                sessionId: "new", state: .recording, initiator: "me", micOwner: "me", target: nil, outcome: nil)))
        }
        XCTAssertEqual(sent(), [.hotkeyDown, .pressAbandoned, .hotkeyUp(reason: .key)])
    }

    func testHandsFreeLocalOwnRecordingIsCancelledByAChord() async throws {
        let (runtime, sent) = chordRuntime()
        runtime.handle(.config(handsFree: true))
        var current: SessionSnapshot?
        runtime.localSession = { current }
        try await pressAndChord(runtime) { current = self.snapshot("new") }
        XCTAssertEqual(sent(), [.hotkeyToggle, .pressAbandoned, .hotkeyCancel])
    }

    func testRemoteHandsFreeChordSendsNothingMore() async throws {
        let (runtime, sent) = chordRuntime() // no local broker: remote
        runtime.handle(.config(handsFree: true))
        try await pressAndChord(runtime)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(sent(), [.hotkeyToggle, .pressAbandoned], "only the press's own toggle; the chord adds nothing")
    }

    func testRemoteHoldChordSendsOnlyHotkeyUp() async throws {
        let (runtime, sent) = chordRuntime()
        try await pressAndChord(runtime)
        XCTAssertEqual(sent(), [.hotkeyDown, .pressAbandoned, .hotkeyUp(reason: .key)])
    }

    func testChordActionIsPureAndNeverCancelsRemotely() {
        let own = snapshot("new")
        XCTAssertEqual(EdgeRuntime.chordAction(handsFree: false, attachedLocally: false, localSession: own, edgeId: "me",
                                               baselineSessionId: nil), .release)
        XCTAssertEqual(EdgeRuntime.chordAction(handsFree: false, attachedLocally: true, localSession: own, edgeId: "me",
                                               baselineSessionId: nil), .cancel)
    }

    // MARK: - capabilities() reflects mic/hotkey state, not a frozen snapshot

    func testCapabilitiesReflectsCurrentMicAvailability() {
        let runtime = makeRuntime()
        XCTAssertFalse(runtime.capabilities().hasMic) // never started in this test
    }

    // MARK: - Hands-free: `config` flips which hotkey messages this runtime speaks

    /// `wireHotkey()` is exercised directly through `hotkeyService`'s
    /// `onStart`/`onStop` closures rather than a live CGEvent tap. Both
    /// closures hop onto the main actor via `Task { @MainActor in ... }`
    /// (they're written for a real CGEvent-tap callback thread), so — like
    /// `CoreHostTests`' effect-chain assertions — this waits on an
    /// expectation rather than asserting immediately after the call.
    func testConfigHandsFreeTrueSendsToggleOnPressAndNothingOnRelease() {
        let runtime = makeRuntime()
        var sent: [EdgeMessage] = []
        let toggleSent = expectation(description: "toggle sent")
        runtime.send = { message in
            sent.append(message)
            if message == .hotkeyToggle { toggleSent.fulfill() }
        }
        runtime.wireHotkey()

        runtime.handle(.config(handsFree: true))
        XCTAssertTrue(runtime.handsFree)

        runtime.hotkeyService.onStart?()
        wait(for: [toggleSent], timeout: 2)
        XCTAssertEqual(sent, [.hotkeyToggle])

        runtime.hotkeyService.onStop?(.key)
        // Give a (wrongly sent) release message a moment to land before
        // confirming release really sends nothing in hands-free mode.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(sent, [.hotkeyToggle])
    }

    func testConfigHandsFreeFalseSendsDownAndUpAgain() {
        let runtime = makeRuntime()
        var sent: [EdgeMessage] = []
        let upSent = expectation(description: "up sent")
        runtime.send = { message in
            sent.append(message)
            if case .hotkeyUp = message { upSent.fulfill() }
        }
        runtime.wireHotkey()

        runtime.handle(.config(handsFree: true))
        runtime.handle(.config(handsFree: false))
        XCTAssertFalse(runtime.handsFree)

        runtime.hotkeyService.onStart?()
        runtime.hotkeyService.onStop?(.key)
        wait(for: [upSent], timeout: 2)
        XCTAssertEqual(sent, [.hotkeyDown, .hotkeyUp(reason: .key)])
    }

    // MARK: - Pointer presence (Universal Control initiator/target fix)

    /// `wirePointerPresence()` is exercised directly through
    /// `hotkeyService.onPointerPresence` rather than a live CGEvent tap —
    /// same reasoning as `wireHotkey`'s tests above.
    func testWirePointerPresenceSendsPointerPresenceMessage() {
        let runtime = makeRuntime()
        var sent: [EdgeMessage] = []
        let presenceSent = expectation(description: "pointer presence sent")
        runtime.send = { message in
            sent.append(message)
            if message == .pointerPresence { presenceSent.fulfill() }
        }
        runtime.wirePointerPresence()

        runtime.hotkeyService.onPointerPresence?()
        wait(for: [presenceSent], timeout: 2)
        XCTAssertEqual(sent, [.pointerPresence])
    }

    // MARK: - Recording-checkpoint cleanup

    /// A runtime wired to a temp-directory `RecordingCheckpointStore` (via
    /// the injectable `AudioCaptureService`) so these tests never touch the
    /// developer's real `~/Library/Application Support/Dictator/Recovery`.
    private func makeRuntimeWithCheckpointStore(edgeId: EdgeID = "me") -> (EdgeRuntime, RecordingCheckpointStore, AudioCaptureService) {
        let store = RecordingCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeRuntimeTests-\(UUID().uuidString)", isDirectory: true))
        let audioService = AudioCaptureService(checkpointStore: store)
        let runtime = EdgeRuntime(edgeId: edgeId, edgeName: "Test Mac", audioService: audioService)
        return (runtime, store, audioService)
    }

    private func idleUpdate(sessionId: SessionID = "s1", micOwner: EdgeID = "me", outcome: SessionOutcome) -> SessionStateUpdate {
        SessionStateUpdate(sessionId: sessionId, state: .idle, initiator: "me", micOwner: micOwner, target: nil, outcome: outcome)
    }

    private func seedCheckpoint(_ store: RecordingCheckpointStore, sessionId: SessionID = "s1") {
        store.saveReceivedTake(
            takeId: RecordingCheckpointStore.edgeTakeId(sessionId), sessionId: sessionId, sampleRate: 16_000,
            edgeName: "Test Mac", data: Data([1, 2, 3, 4])
        )
    }

    func testCheckpointDeletedOnPastedOutcomeWhenThisMachineIsMicOwner() {
        let (runtime, store, audioService) = makeRuntimeWithCheckpointStore()
        seedCheckpoint(store)

        runtime.handle(.sessionState(idleUpdate(outcome: .pasted)))
        audioService.drainCheckpointQueueForTesting()

        XCTAssertTrue(store.listTakes().isEmpty)
    }

    func testCheckpointDeletedOnClipboardOnlyAndEmptyOutcomes() {
        for outcome: SessionOutcome in [.clipboardOnly(reason: "no field", needsAccessibility: false), .empty] {
            let (runtime, store, audioService) = makeRuntimeWithCheckpointStore()
            seedCheckpoint(store)

            runtime.handle(.sessionState(idleUpdate(outcome: outcome)))
            audioService.drainCheckpointQueueForTesting()

            XCTAssertTrue(store.listTakes().isEmpty, "expected deletion for outcome \(outcome)")
        }
    }

    func testCheckpointDeletedOnUserCancelAndNoAudio() {
        for reason: CancelReason in [.user, .noAudio] {
            let (runtime, store, audioService) = makeRuntimeWithCheckpointStore()
            seedCheckpoint(store)

            runtime.handle(.sessionState(idleUpdate(outcome: .cancelled(reason))))
            audioService.drainCheckpointQueueForTesting()

            XCTAssertTrue(store.listTakes().isEmpty, "expected deletion for cancel reason \(reason)")
        }
    }

    func testCheckpointKeptOnFailedAndLostEdgeOutcomes() {
        let keptOutcomes: [SessionOutcome] = [
            .failed(message: "server unreachable"),
            .cancelled(.micLost), .cancelled(.initiatorLost), .cancelled(.targetLost), .cancelled(.watchdog),
        ]
        for outcome in keptOutcomes {
            let (runtime, store, audioService) = makeRuntimeWithCheckpointStore()
            seedCheckpoint(store)

            runtime.handle(.sessionState(idleUpdate(outcome: outcome)))
            audioService.drainCheckpointQueueForTesting()

            XCTAssertEqual(store.listTakes().count, 1, "expected the checkpoint kept for outcome \(outcome)")
        }
    }

    func testCheckpointUntouchedWhenThisMachineIsNotTheMicOwner() {
        let (runtime, store, audioService) = makeRuntimeWithCheckpointStore(edgeId: "me")
        seedCheckpoint(store)

        // micOwner is some other edge — this machine never held the file, so
        // it must not touch it (its own store just happens to have one from
        // the seed, standing in for "this machine's checkpoint store has
        // unrelated content it shouldn't react to").
        runtime.handle(.sessionState(idleUpdate(micOwner: "other-mac", outcome: .pasted)))
        audioService.drainCheckpointQueueForTesting()

        XCTAssertEqual(store.listTakes().count, 1)
    }

    // MARK: - captureCancel on initiator loss keeps the file; on
    // a genuine user cancel it's deleted once the matching idle outcome
    // arrives.

    func testCaptureCancelThenInitiatorLostIdleKeepsTheCheckpoint() {
        let (runtime, store, audioService) = makeRuntimeWithCheckpointStore(edgeId: "mic-owner")
        audioService.sampleRateOverrideForTesting = 48_000
        runtime.handle(.sessionState(recordingState(sessionId: "s1", initiator: "other-mac", micOwner: "mic-owner")))
        runtime.handle(.captureStart(sessionId: "s1"))
        audioService.drainCheckpointQueueForTesting()
        XCTAssertEqual(store.listTakes().count, 1, "a writer should have opened for this take")

        // The broker sends `captureCancel` to the mic owner when the
        // initiator disconnects — this must finalize-and-keep, not delete.
        runtime.handle(.captureCancel(sessionId: "s1"))
        audioService.drainCheckpointQueueForTesting()
        XCTAssertEqual(store.listTakes().count, 1, "captureCancel must not delete the checkpoint outright")

        // The matching idle broadcast then arrives with the "keep" outcome.
        runtime.handle(.sessionState(idleUpdate(sessionId: "s1", micOwner: "mic-owner", outcome: .cancelled(.initiatorLost))))
        audioService.drainCheckpointQueueForTesting()
        XCTAssertEqual(store.listTakes().count, 1, "kept for recovery — the initiator, not the mic owner, is who's gone")
    }

    func testCaptureCancelThenUserCancelIdleDeletesTheCheckpoint() {
        let (runtime, store, audioService) = makeRuntimeWithCheckpointStore(edgeId: "mic-owner")
        audioService.sampleRateOverrideForTesting = 48_000
        runtime.handle(.sessionState(recordingState(sessionId: "s1", initiator: "mic-owner", micOwner: "mic-owner")))
        runtime.handle(.captureStart(sessionId: "s1"))
        audioService.drainCheckpointQueueForTesting()
        XCTAssertEqual(store.listTakes().count, 1)

        // Same wire message (`captureCancel`) as above, followed this time
        // by the "delete" outcome (Esc pressed while recording).
        runtime.handle(.captureCancel(sessionId: "s1"))
        audioService.drainCheckpointQueueForTesting()
        XCTAssertEqual(store.listTakes().count, 1, "captureCancel itself never deletes")

        runtime.handle(.sessionState(idleUpdate(sessionId: "s1", micOwner: "mic-owner", outcome: .cancelled(.user))))
        audioService.drainCheckpointQueueForTesting()
        XCTAssertTrue(store.listTakes().isEmpty, "a genuine user cancel deletes once the idle outcome lands")
    }

    // MARK: - Session-outcome reconciliation

    func testQueryOutcomesForUploadedCheckpointsSendsOnlyUploadedTakeSessionIds() {
        let (runtime, store, _) = makeRuntimeWithCheckpointStore()
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "Test Mac", data: Data([1, 2, 3, 4]))
        store.markStatus("edge-s1", status: .uploaded) // finished, might have missed the idle broadcast
        store.saveReceivedTake(takeId: "edge-s2", sessionId: "s2", sampleRate: 16_000, edgeName: "Test Mac", data: Data([1, 2, 3, 4]))
        store.markStatus("edge-s2", status: .recording) // still open — nothing to reconcile

        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }

        runtime.queryOutcomesForUploadedCheckpoints()

        XCTAssertEqual(sent.count, 1)
        guard case .sessionOutcomeQuery(let sessionIds) = sent.first else {
            return XCTFail("expected a sessionOutcomeQuery, got \(sent)")
        }
        XCTAssertEqual(sessionIds, ["s1"])
    }

    func testQueryOutcomesForUploadedCheckpointsSendsNothingWhenNoneAreUploaded() {
        let (runtime, _, _) = makeRuntimeWithCheckpointStore()
        var sent: [EdgeMessage] = []
        runtime.send = { sent.append($0) }

        runtime.queryOutcomesForUploadedCheckpoints()

        XCTAssertTrue(sent.isEmpty)
    }

    func testSessionOutcomesReconciliationDeletesForSafeOutcomes() {
        let deletedOutcomes: [SessionOutcome] = [
            .pasted, .clipboardOnly(reason: "no field", needsAccessibility: false), .empty, .cancelled(.user),
        ]
        for outcome in deletedOutcomes {
            let (runtime, store, audioService) = makeRuntimeWithCheckpointStore()
            seedCheckpoint(store, sessionId: "s1")

            runtime.handle(.sessionOutcomes(["s1": outcome]))
            audioService.drainCheckpointQueueForTesting()

            XCTAssertTrue(store.listTakes().isEmpty, "expected deletion for reconciled outcome \(outcome)")
        }
    }

    func testSessionOutcomesReconciliationKeepsEverythingElse() {
        let keptOutcomes: [SessionOutcome] = [
            .failed(message: "server unreachable"), .cancelled(.noAudio),
            .cancelled(.micLost), .cancelled(.initiatorLost), .cancelled(.targetLost), .cancelled(.watchdog),
        ]
        for outcome in keptOutcomes {
            let (runtime, store, audioService) = makeRuntimeWithCheckpointStore()
            seedCheckpoint(store, sessionId: "s1")

            runtime.handle(.sessionOutcomes(["s1": outcome]))
            audioService.drainCheckpointQueueForTesting()

            XCTAssertEqual(store.listTakes().count, 1, "expected the checkpoint kept for reconciled outcome \(outcome)")
        }
    }

    func testSessionOutcomesReconciliationLeavesAnUnansweredIdUntouched() {
        let (runtime, store, audioService) = makeRuntimeWithCheckpointStore()
        seedCheckpoint(store, sessionId: "s1")

        // The Core answered for a different session — this one wasn't in
        // its ring buffer (still in flight, or aged out); must stay put.
        runtime.handle(.sessionOutcomes(["s2": .pasted]))
        audioService.drainCheckpointQueueForTesting()

        XCTAssertEqual(store.listTakes().count, 1)
    }
}

extension EdgeRuntimeTests {
    func testVoiceFailureTravelsToDictatingMacWithFullAlert() async {
        let target = makeRuntime(edgeId: "target")
        var services = VoiceLaunchServices(confirm: { _, _ in true }, setClipboard: { _ in }, pressKey: { _ in true },
            frontmostBundleId: { nil }, runProcess: { _, _, _ in nil }, session: URLSession(configuration: .ephemeral), now: Date.init)
        var clipboard = ""
        services.setClipboard = { clipboard = $0 }
        services.workspaceRoutines = { [WorkspaceRoutine(id: "writing", name: "Writing")] }
        services.runWorkspace = { _ in throw WorkspaceLaunchError.unavailable("Synthetic workspace failure") }
        target.voiceLaunchServices = services
        let inserting = SessionStateUpdate(sessionId: "voice-test", state: .inserting, initiator: "dictating", micOwner: "dictating", target: "target", outcome: nil)
        target.handle(.sessionState(inserting))
        let replied = expectation(description: "Target reports execution failure")
        var outcome: SessionOutcome?
        target.send = { message in
            if case .insertResult(_, let result, _) = message { outcome = result; replied.fulfill() }
        }
        let plan = VoiceLaunchPlan(commandId: "test", commandName: "Test", slots: [], steps: [VoiceStep(kind: .runWorkspace, text: "Writing")], mainText: "Writing")
        target.handle(.launchInsert(sessionId: "voice-test", plan: plan))
        await fulfillment(of: [replied], timeout: 2)
        guard case .failed(let message)? = outcome else { return XCTFail("Expected encoded failure, not a clipboard-only outcome") }
        XCTAssertEqual(clipboard, "Writing")
        XCTAssertNil(target.alerts.current, "The target must not own the failure notice")
        let initiator = makeRuntime(edgeId: "dictating")
        var idle = inserting
        idle.state = .idle
        idle.outcome = outcome
        initiator.handle(.sessionState(idle))
        XCTAssertEqual(initiator.alerts.current, DictationAlert.decode(failure: message))
        XCTAssertEqual(initiator.alerts.current?.title, "Synthetic workspace failure")
        initiator.alerts.hide()
    }
}

extension EdgeRuntimeTests {
    func testTieDeliveryPreservesNamesInstructionsAndAction() {
        let target = makeRuntime(edgeId: "target")
        var clipboard = ""
        target.voiceLaunchServices = VoiceLaunchServices(confirm: { _, _ in true }, setClipboard: { clipboard = $0 }, pressKey: { _ in true },
            frontmostBundleId: { nil }, runProcess: { _, _, _ in nil }, session: URLSession(configuration: .ephemeral), now: Date.init)
        target.handle(.sessionState(SessionStateUpdate(sessionId: "tie-test", state: .inserting, initiator: "dictating", micOwner: "dictating", target: "target", outcome: nil)))
        let alert = DictationAlert.voiceCommandTie(heard: "Open Safari", names: ["Browse", "Work"])
        var outcome: SessionOutcome?
        target.send = { message in if case .insertResult(_, let result, _) = message { outcome = result } }
        target.handle(.voiceCommandInsert(sessionId: "tie-test", delivery: VoiceCommandDelivery(text: "Open Safari", notice: alert.encoded)))
        guard case .failed(let message)? = outcome else { return XCTFail("Expected initiator notice") }
        XCTAssertEqual(message, alert.encoded, "Names and instructions must survive delivery")
        XCTAssertEqual(DictationAlert.decode(failure: message).action, .voiceLaunch)
        XCTAssertEqual(clipboard, "Open Safari")
        XCTAssertNil(target.alerts.current)
    }
}
