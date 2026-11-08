import SwiftData
import XCTest
@testable import Dictator

/// Dictation connection robustness: a quiet main Mac, a connection lost
/// mid-recording, the listener waiting for Tailscale, and a version
/// mismatch. Mocked links and synthetic state only.
@MainActor
final class ConnectionRobustnessTests: XCTestCase {
    /// A temporary checkpoint folder and a synthetic sample rate: a test
    /// that starts capture never touches the real Recovery folder or the
    /// audio hardware.
    private func makeRuntime() -> EdgeRuntime {
        let store = RecordingCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionRobustnessTests-\(UUID().uuidString)", isDirectory: true))
        let audioService = AudioCaptureService(checkpointStore: store)
        audioService.sampleRateOverrideForTesting = 48_000
        return EdgeRuntime(edgeId: "me", edgeName: "Test Mac", audioService: audioService)
    }

    // MARK: - Quiet main Mac

    func testLivenessRuleTrustsRecentActivity() {
        let now = Date()
        XCTAssertTrue(CoreConnection.isLive(connected: true, lastActivity: now.addingTimeInterval(-1), now: now))
    }

    func testLivenessRuleDistrustsSilenceBeyondOnePingAndAHalf() {
        let now = Date()
        let silent = EdgeProtocol.pingInterval * 1.5 + 0.5
        XCTAssertFalse(CoreConnection.isLive(connected: true, lastActivity: now.addingTimeInterval(-silent), now: now))
    }

    func testLivenessRuleRequiresConnection() {
        let now = Date()
        XCTAssertFalse(CoreConnection.isLive(connected: false, lastActivity: now, now: now))
    }

    func testSendReportsFailureWhenNotConnected() {
        let connection = CoreConnection(
            url: URL(string: "ws://100.64.0.1:7880")!, edgeId: "e", name: "n", token: "t",
            capabilities: EdgeCapabilities(hasMic: false, inputDeviceUID: "", accessibility: false, inputMonitoring: false, hotkeyMode: "none")
        )
        XCTAssertFalse(connection.send(.hotkeyDown))
        XCTAssertFalse(connection.sendAudio(
            header: AudioTakeHeader(sessionId: "s", sampleRate: 16000, frameCount: 0, durationSeconds: 0, byteCount: 0),
            data: Data()
        ))
        XCTAssertFalse(connection.isLive)
    }

    func testKeyDownWithQuietMainMacSwitchesToThisMacAndTellsTheUser() {
        let runtime = makeRuntime()
        var remoteSent: [EdgeMessage] = []
        var localSent: [EdgeMessage] = []
        runtime.send = { remoteSent.append($0) }
        runtime.isMainMacLive = { false }
        runtime.onMainMacUnreachable = { runtime.send = { localSent.append($0) } }

        runtime.startDictation(.hotkeyDown)

        XCTAssertTrue(remoteSent.isEmpty)
        XCTAssertEqual(localSent, [.hotkeyDown])
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
        XCTAssertEqual(EdgeRuntime.cantReachMainMacAlert.title, BrandVoice.cantReach("your main Mac"))
        XCTAssertFalse(EdgeRuntime.cantReachMainMacAlert.detail.contains("Core"))
    }

    func testKeyDownWithLiveMainMacGoesStraightThrough() {
        let runtime = makeRuntime()
        var sent: [EdgeMessage] = []
        var switched = false
        runtime.send = { sent.append($0) }
        runtime.isMainMacLive = { true }
        runtime.onMainMacUnreachable = { switched = true }

        runtime.startDictation(.hotkeyToggle)

        XCTAssertEqual(sent, [.hotkeyToggle])
        XCTAssertFalse(switched)
        XCTAssertNil(runtime.alerts.current)
    }

    func testRefusedKeyDownIsRetriedOnThisMac() {
        let runtime = makeRuntime()
        var localSent: [EdgeMessage] = []
        runtime.send = { _ in }
        runtime.isMainMacLive = { true }
        runtime.onMainMacUnreachable = { runtime.send = { localSent.append($0) } }
        runtime.startDictation(.hotkeyDown)

        runtime.remoteSendFailed(.hotkeyDown, gesture: runtime.pendingStart?.id)

        XCTAssertEqual(localSent, [.hotkeyDown])
        XCTAssertNotNil(runtime.alerts.current)
        XCTAssertNil(runtime.pendingStart)
    }

    func testRefusedNonKeyFrameDoesNotSwitchOrAlert() {
        let runtime = makeRuntime()
        var switched = false
        runtime.onMainMacUnreachable = { switched = true }

        runtime.remoteSendFailed(.hotkeyUp(reason: .key))

        XCTAssertFalse(switched)
        XCTAssertNil(runtime.alerts.current)
    }

    func testStoppingAHandsFreeRecordingIsNotTurnedIntoANewOne() {
        let runtime = makeRuntime()
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .recording, initiator: "me", micOwner: "me", target: nil, outcome: nil)))
        var sent: [EdgeMessage] = []
        var switched = false
        runtime.send = { sent.append($0) }
        runtime.isMainMacLive = { false }
        runtime.onMainMacUnreachable = { switched = true }

        runtime.startDictation(.hotkeyToggle)

        XCTAssertFalse(switched)
        XCTAssertEqual(sent, [.hotkeyToggle])
    }

    // MARK: - Connection lost mid-recording

    func testConnectionLostWhileRecordingOffersTheKeptRecording() {
        let runtime = makeRuntime()
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .recording, initiator: "me", micOwner: "me", target: nil, outcome: nil)))

        runtime.resetSession(reason: "dropped", connectionLost: true)

        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.recordingKeptHereAlert)
        XCTAssertEqual(EdgeRuntime.recordingKeptHereAlert.action, .history)
        XCTAssertEqual(runtime.phase, .idle)
    }

    func testResetWithoutConnectionLossStaysQuiet() {
        let runtime = makeRuntime()
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .recording, initiator: "me", micOwner: "me", target: nil, outcome: nil)))

        runtime.resetSession(reason: "leaving Edge role")

        XCTAssertNil(runtime.alerts.current)
    }

    func testConnectionLostWhileIdleStaysQuiet() {
        let runtime = makeRuntime()
        runtime.resetSession(reason: "dropped", connectionLost: true)
        XCTAssertNil(runtime.alerts.current)
    }

    func testLostUploadIsExplained() {
        let runtime = makeRuntime()
        runtime.remoteAudioSendFailed()
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.recordingKeptHereAlert)
    }

    // MARK: - Listener waits for Tailscale

    func testWatcherReportsAddressAppearing() {
        var address: String? = nil
        var reported: [String?] = []
        let watcher = TailscaleAddressWatcher(addressProvider: { address }, needsRetry: { false }, onChange: { reported.append($0) })

        watcher.evaluate()
        XCTAssertTrue(reported.isEmpty)

        address = "100.100.1.2"
        watcher.evaluate()
        XCTAssertEqual(reported, ["100.100.1.2"])

        watcher.evaluate()
        XCTAssertEqual(reported, ["100.100.1.2"], "unchanged address is not reported again")
        watcher.stop()
    }

    func testWatcherRetriesWhileListenerIsDownAndAddressExists() {
        var calls = 0
        let watcher = TailscaleAddressWatcher(addressProvider: { "100.100.1.2" }, needsRetry: { true }, onChange: { _ in calls += 1 })
        watcher.evaluate()
        watcher.evaluate()
        XCTAssertEqual(calls, 2, "first sight of the address, then a retry on the next tick")
        watcher.stop()
    }

    func testWatcherDoesNotRetryWithoutAnAddress() {
        var calls = 0
        let watcher = TailscaleAddressWatcher(addressProvider: { nil }, needsRetry: { true }, onChange: { _ in calls += 1 })
        watcher.evaluate()
        XCTAssertEqual(calls, 0)
        watcher.stop()
    }

    func testRetryBackoffIsBounded() {
        XCTAssertEqual(TailscaleAddressWatcher.retryDelay(attempt: 0), 5)
        XCTAssertEqual(TailscaleAddressWatcher.retryDelay(attempt: 3), 30)
        XCTAssertEqual(TailscaleAddressWatcher.retryDelay(attempt: 50), 30)
        XCTAssertEqual(TailscaleAddressWatcher.retryDelay(attempt: -1), 5)
    }

    // MARK: - Version mismatch

    func testOlderMainMacIsClassified() {
        XCTAssertEqual(ProtocolMismatch(peerVersion: 1, ownVersion: 2), .mainMacOlder)
        XCTAssertEqual(ProtocolMismatch(peerVersion: 3, ownVersion: 2), .thisMacOlder)
    }

    func testMismatchSurvivesTheDropReason() {
        XCTAssertEqual(ProtocolMismatch(reason: ProtocolMismatch.mainMacOlder.reason), .mainMacOlder)
        XCTAssertEqual(ProtocolMismatch(reason: ProtocolMismatch.thisMacOlder.reason), .thisMacOlder)
        XCTAssertNil(ProtocolMismatch(reason: "keepalive timeout"))
        XCTAssertNil(ProtocolMismatch(reason: nil))
    }

    func testUpdateCopyNamesTheMacToUpdate() {
        XCTAssertTrue(ProtocolMismatch.mainMacOlder.updateMessage(mainMacName: "Studio").hasPrefix("Update Dictator on Studio."))
        XCTAssertTrue(ProtocolMismatch.mainMacOlder.updateMessage(mainMacName: "your main Mac").hasPrefix("Update Dictator on your main Mac."))
        XCTAssertTrue(ProtocolMismatch.thisMacOlder.updateMessage(mainMacName: "Studio").hasPrefix("Update Dictator on this Mac."))
        XCTAssertFalse(ProtocolMismatch.thisMacOlder.updateMessage(mainMacName: "Studio").contains("Can’t reach"))
    }

    func testFrameFromAnotherVersionIsReportedAsUnsupportedVersion() throws {
        let frame = Data(#"{"v":\#(EdgeProtocol.version + 1),"t":"welcome","id":"x"}"#.utf8)
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeCoreMessage(frame)) { error in
            XCTAssertEqual(error as? EdgeProtocolError, .unsupportedVersion(EdgeProtocol.version + 1))
        }
    }

    // MARK: - Fallback, alerts and listener retry

    private func recording(micOwner: EdgeID = "me") -> CoreMessage {
        .sessionState(SessionStateUpdate(sessionId: "s1", state: .recording, initiator: "me", micOwner: micOwner, target: nil, outcome: nil))
    }

    /// A main Mac that looked alive but never answers the key press.
    func testKeyPressTheMainMacNeverAnswersFallsBackToThisMac() async throws {
        let runtime = makeRuntime()
        runtime.startAckTimeout = 0.05
        var remoteSent: [EdgeMessage] = []
        var localSent: [EdgeMessage] = []
        runtime.send = { remoteSent.append($0) }
        runtime.isMainMacLive = { true }
        runtime.onMainMacUnreachable = { runtime.send = { localSent.append($0) } }

        runtime.startDictation(.hotkeyDown)
        XCTAssertEqual(remoteSent, [.hotkeyDown])
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(localSent, [.hotkeyDown])
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
    }

    func testKeyPressTheMainMacAnswersStaysRemote() async throws {
        let runtime = makeRuntime()
        runtime.startAckTimeout = 0.05
        var switched = false
        runtime.send = { _ in }
        runtime.isMainMacLive = { true }
        runtime.onMainMacUnreachable = { switched = true }

        runtime.startDictation(.hotkeyDown)
        runtime.handle(recording())
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(switched)
        XCTAssertNil(runtime.alerts.current)
    }

    func testKeyReleasedBeforeTheMainMacAnsweredSaysNothingWasRecorded() async throws {
        let runtime = makeRuntime()
        runtime.startAckTimeout = 0.1
        var localSent: [EdgeMessage] = []
        runtime.send = { _ in }
        runtime.isMainMacLive = { true }
        runtime.onMainMacUnreachable = { runtime.send = { localSent.append($0) } }
        runtime.wireHotkey()

        runtime.startDictation(.hotkeyDown)
        runtime.hotkeyService.onStop?(.key)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(localSent.isEmpty, "no recording starts for a key that is already up")
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacMissedAlert)
    }

    /// The local broker's recording state arrives after the fallback send and
    /// must not hide the notice.
    func testFallbackNoticeSurvivesTheRecordingStateThatFollows() {
        let runtime = makeRuntime()
        var queued: [EdgeMessage] = []
        runtime.send = { _ in }
        runtime.isMainMacLive = { false }
        runtime.onMainMacUnreachable = { runtime.send = { queued.append($0) } }

        runtime.startDictation(.hotkeyDown)
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
        runtime.handle(recording())

        XCTAssertEqual(runtime.phase, .recording)
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
    }

    func testFallbackNoticeSurvivesWhenTheRecordingStateIsDeliveredDuringTheSend() {
        let runtime = makeRuntime()
        runtime.send = { _ in }
        runtime.isMainMacLive = { false }
        runtime.onMainMacUnreachable = {
            runtime.send = { _ in runtime.handle(self.recording()) }
        }

        runtime.startDictation(.hotkeyDown)

        XCTAssertEqual(runtime.phase, .recording)
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
    }

    func testAnOrdinaryRecordingStillClearsOtherAlerts() {
        let runtime = makeRuntime()
        runtime.alerts.show(.nothingHeard)
        runtime.handle(recording())
        XCTAssertNil(runtime.alerts.current)
    }

    func testInitiatorWithoutTheMicrophoneIsNotSentToItsOwnRecoveryList() {
        let runtime = makeRuntime()
        runtime.handle(recording(micOwner: "studio"))

        runtime.resetSession(reason: "dropped", connectionLost: true)

        let alert = try? XCTUnwrap(runtime.alerts.current)
        XCTAssertNil(alert?.action)
        XCTAssertTrue(alert?.detail.contains("Your recording is kept on ") ?? false)
        XCTAssertFalse(alert?.detail.contains("kept on this Mac") ?? true)
    }

    func testKeptElsewhereAlertNamesTheMac() {
        let alert = EdgeRuntime.recordingKeptElsewhereAlert(macName: "Studio")
        XCTAssertTrue(alert.detail.contains("kept on Studio"))
        XCTAssertNil(alert.action)
    }

    func testMicOwnerGetsTheRecoveryAction() {
        let runtime = makeRuntime()
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .recording, initiator: "studio", micOwner: "me", target: nil, outcome: nil)))
        runtime.resetSession(reason: "dropped", connectionLost: true)
        XCTAssertEqual(runtime.alerts.current?.action, .history)
    }

    func testAMicOwnerThatIsNotTheInitiatorOrOwnerIsQuiet() {
        let runtime = makeRuntime()
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .recording, initiator: "studio", micOwner: "studio", target: nil, outcome: nil)))
        runtime.resetSession(reason: "dropped", connectionLost: true)
        XCTAssertNil(runtime.alerts.current)
    }

    func testListenerFailureClearsListeningStateAndTriggersRetry() {
        let schema = Repositories.schema
        let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let host = CoreHost(
            coreId: "core-1", repositories: Repositories.make(container: container), clock: { 0 }, makeSessionID: { "s1" },
            transcribe: { _, _ in ("", nil) }, recordHistory: { _, _, _, _, _, _ in },
            checkpointStore: RecordingCheckpointStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ConnRobust-\(UUID().uuidString)", isDirectory: true)))
        var failures = 0
        host.onListenerFailed = { failures += 1 }

        host.handleListenerHealth(healthy: false, message: "address not available")
        XCTAssertNil(host.listeningAddress)
        XCTAssertEqual(host.listenerWarning, "address not available")
        XCTAssertEqual(failures, 1)

        host.handleListenerHealth(healthy: true, message: nil)
        XCTAssertNil(host.listenerWarning)
        XCTAssertEqual(failures, 1)
    }

    func testWatcherRearmsItsRetryAfterAListenerFailure() {
        var needsRetry = false
        let watcher = TailscaleAddressWatcher(addressProvider: { "100.100.1.2" }, needsRetry: { needsRetry }, onChange: { _ in })
        watcher.evaluate()
        XCTAssertFalse(watcher.isRetryScheduled)

        needsRetry = true
        watcher.rearm()
        XCTAssertTrue(watcher.isRetryScheduled)
        watcher.stop()
        XCTAssertFalse(watcher.isRetryScheduled)
    }

    func testAcceptedSendWithoutALiveSocketReportsNothingToQueue() {
        let connection = CoreConnection(
            url: URL(string: "ws://100.64.0.1:7880")!, edgeId: "e", name: "n", token: "t",
            capabilities: EdgeCapabilities(hasMic: false, inputDeviceUID: "", accessibility: false, inputMonitoring: false, hotkeyMode: "none")
        )
        var failures = 0
        XCTAssertFalse(connection.send(.hotkeyDown, onFailure: { failures += 1 }))
        XCTAssertFalse(connection.sendAudio(
            header: AudioTakeHeader(sessionId: "s", sampleRate: 16000, frameCount: 0, durationSeconds: 0, byteCount: 0),
            data: Data(), onFailure: { failures += 1 }))
        XCTAssertEqual(failures, 0, "a refusal is the return value; the callback is for failures after acceptance")
    }

    // MARK: - PendingStart gesture model

    /// A runtime wired to a main Mac that accepts everything and answers nothing.
    private func makeSilentMainMacRuntime(timeout: TimeInterval = 5) -> (EdgeRuntime, remote: () -> [EdgeMessage], local: () -> [EdgeMessage]) {
        let runtime = makeRuntime()
        runtime.startAckTimeout = timeout
        var remote: [EdgeMessage] = []
        var local: [EdgeMessage] = []
        runtime.send = { remote.append($0) }
        runtime.isMainMacLive = { true }
        runtime.onMainMacUnreachable = { runtime.send = { local.append($0) } }
        runtime.wireHotkey()
        return (runtime, { remote }, { local })
    }

    func testDisconnectAfterAcceptedStartReplaysHeldPressLocally() {
        let (runtime, remote, local) = makeSilentMainMacRuntime()
        runtime.startDictation(.hotkeyDown)
        XCTAssertEqual(remote(), [.hotkeyDown])

        // The view model's disconnect order: reset, clear hooks, attach local, resolve.
        runtime.resetSession(reason: "dropped", connectionLost: true)
        XCTAssertNotNil(runtime.pendingStart, "a lost connection leaves the press for the caller to resolve")
        var replayed: [EdgeMessage] = []
        runtime.send = { replayed.append($0) }
        runtime.isMainMacLive = nil
        runtime.onMainMacUnreachable = nil
        runtime.resolvePendingStartAfterDisconnect()

        XCTAssertEqual(replayed, [.hotkeyDown])
        XCTAssertTrue(local().isEmpty)
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
        XCTAssertNil(runtime.pendingStart)
    }

    func testDisconnectAfterReleasedPressOnlyReportsTheMissedRecording() async throws {
        let (runtime, _, _) = makeSilentMainMacRuntime()
        runtime.startDictation(.hotkeyDown)
        runtime.hotkeyService.onStop?(.key)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.pendingStart?.state, .released)

        runtime.resetSession(reason: "dropped", connectionLost: true)
        var replayed: [EdgeMessage] = []
        runtime.send = { replayed.append($0) }
        runtime.onMainMacUnreachable = nil
        runtime.resolvePendingStartAfterDisconnect()

        XCTAssertTrue(replayed.isEmpty)
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacMissedAlert)
        XCTAssertNil(runtime.pendingStart)
    }

    func testDelayedSendFailureAfterReleaseDoesNotStartARecording() async throws {
        let (runtime, _, local) = makeSilentMainMacRuntime()
        runtime.startDictation(.hotkeyDown)
        let gesture = runtime.pendingStart?.id
        runtime.hotkeyService.onStop?(.key)
        try await Task.sleep(for: .milliseconds(100))

        runtime.remoteSendFailed(.hotkeyDown, gesture: gesture)

        XCTAssertTrue(local().isEmpty, "no hotkeyDown after a hotkeyUp")
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacMissedAlert)
        XCTAssertNil(runtime.pendingStart)
    }

    func testEscBeforeTheAnswerCancelsQuietlyEvenWhenTheDeadlineFires() async throws {
        let (runtime, remote, local) = makeSilentMainMacRuntime(timeout: 0.1)
        runtime.startDictation(.hotkeyDown)
        let gesture = runtime.pendingStart?.id
        runtime.hotkeyService.onCancel?()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runtime.pendingStart?.state, .cancelled)
        XCTAssertEqual(remote(), [.hotkeyDown, .hotkeyCancel])

        try await Task.sleep(for: .milliseconds(400)) // the deadline passes
        runtime.remoteSendFailed(.hotkeyDown, gesture: gesture) // and a late failure arrives

        XCTAssertTrue(local().isEmpty)
        XCTAssertNil(runtime.alerts.current, "the user cancelled, so no notice")
        XCTAssertNil(runtime.pendingStart)
    }

    func testCharacterChordDuringTheWaitIsNeverReplayedLocally() async throws {
        let (runtime, remote, local) = makeSilentMainMacRuntime(timeout: 0.1)
        runtime.startDictation(.hotkeyDown)
        let gesture = runtime.pendingStart?.id
        runtime.hotkeyService.onCharacterChord?() // ⌥ + a letter: a typed character
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runtime.pendingStart?.state, .cancelled)

        try await Task.sleep(for: .milliseconds(400)) // the deadline passes
        runtime.remoteSendFailed(.hotkeyDown, gesture: gesture) // a late failure
        runtime.resolvePendingStartAfterDisconnect() // and a disconnect

        XCTAssertTrue(local().isEmpty, "nothing recorded on this Mac")
        XCTAssertNil(runtime.alerts.current)
        XCTAssertEqual(remote().first, .hotkeyDown)
    }

    func testFailureForAnOlderPressIsIgnored() {
        let (runtime, _, local) = makeSilentMainMacRuntime()
        runtime.startDictation(.hotkeyDown)
        let older = runtime.pendingStart?.id
        runtime.handle(recording()) // answered
        XCTAssertNil(runtime.pendingStart)
        runtime.handle(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .idle, initiator: "me", micOwner: "me", target: nil, outcome: .pasted)))
        runtime.startDictation(.hotkeyDown)
        XCTAssertNotEqual(runtime.pendingStart?.id, older)

        runtime.remoteSendFailed(.hotkeyDown, gesture: older)

        XCTAssertTrue(local().isEmpty)
        XCTAssertNotNil(runtime.pendingStart, "the current press is untouched")
    }

    func testEveryExitFromAPendingStartClearsIt() {
        // Answer.
        var (runtime, _, _) = makeSilentMainMacRuntime()
        runtime.startDictation(.hotkeyDown)
        XCTAssertNotNil(runtime.pendingStart)
        runtime.handle(recording())
        XCTAssertNil(runtime.pendingStart)
        // Reset for another reason.
        (runtime, _, _) = makeSilentMainMacRuntime()
        runtime.startDictation(.hotkeyDown)
        runtime.resetSession(reason: "leaving Edge role")
        XCTAssertNil(runtime.pendingStart)
        // Error from the main Mac.
        (runtime, _, _) = makeSilentMainMacRuntime()
        runtime.startDictation(.hotkeyDown)
        runtime.handle(.error(code: "noMic", message: "x"))
        XCTAssertNil(runtime.pendingStart)
    }

    func testHandsFreeTapThroughTheSameModelReplaysOnTheDeadline() async throws {
        let (runtime, _, local) = makeSilentMainMacRuntime(timeout: 0.05)
        runtime.startDictation(.hotkeyToggle)
        XCTAssertEqual(runtime.pendingStart?.state, .held)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(local(), [.hotkeyToggle])
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
        XCTAssertNil(runtime.pendingStart)
    }

    func testSecondHandsFreeTapBeforeTheAnswerCountsAsStop() async throws {
        let (runtime, remote, local) = makeSilentMainMacRuntime(timeout: 0.1)
        runtime.startDictation(.hotkeyToggle)
        runtime.startDictation(.hotkeyToggle)
        XCTAssertEqual(runtime.pendingStart?.state, .released)
        XCTAssertEqual(remote(), [.hotkeyToggle, .hotkeyToggle])
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(local().isEmpty)
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacMissedAlert)
    }

    // MARK: - Stale frames and hands-free waits

    func testStaleRemoteCaptureStartAfterFallbackLeavesLocalCaptureAlone() {
        let (runtime, _, _) = makeSilentMainMacRuntime()
        runtime.isMainMacLive = { false }
        runtime.startDictation(.hotkeyDown) // falls back; the view model clears these hooks
        runtime.isMainMacLive = nil
        runtime.onMainMacUnreachable = nil
        runtime.handle(.captureStart(sessionId: "local")) // the local broker's capture
        let generation = runtime.audioService.captureGeneration

        let accepted = runtime.handleRemote(.captureStart(sessionId: "stale-remote"))

        XCTAssertFalse(accepted)
        XCTAssertEqual(runtime.audioService.captureGeneration, generation, "buffers and checkpoint writer untouched")
        runtime.audioService.cancelCapture()
    }

    func testRemoteSessionFramesAreAcceptedWhileTheMainMacIsActive() {
        let (runtime, _, _) = makeSilentMainMacRuntime()
        XCTAssertTrue(runtime.handleRemote(recording()))
        XCTAssertEqual(runtime.phase, .recording)
        XCTAssertTrue(runtime.handleRemote(.config(handsFree: true)), "non-session frames always pass")
    }

    func testRemoteSessionFramesAreDroppedWhenNoRemoteTransportIsActive() {
        let runtime = makeRuntime()
        XCTAssertFalse(runtime.handleRemote(recording()))
        XCTAssertEqual(runtime.phase, .idle)
    }

    func testEscDuringAHandsFreeWaitGetsThroughTheRealEventGate() async throws {
        let (runtime, remote, local) = makeSilentMainMacRuntime(timeout: 0.1)
        runtime.startDictation(.hotkeyToggle) // tap, released: isPressed is false
        XCTAssertTrue(runtime.hotkeyService.cancelEligible)
        let esc = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))

        _ = runtime.hotkeyService.handleEventForTesting(esc)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runtime.pendingStart?.state, .cancelled)
        XCTAssertEqual(remote(), [.hotkeyToggle, .hotkeyCancel])

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(local().isEmpty)
        XCTAssertNil(runtime.alerts.current)
        XCTAssertFalse(runtime.hotkeyService.cancelEligible)
    }

    func testEscIsIgnoredWhenNothingIsPending() throws {
        let runtime = makeRuntime()
        runtime.wireHotkey()
        var cancelled = false
        runtime.hotkeyService.onCancel = { cancelled = true }
        let esc = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        _ = runtime.hotkeyService.handleEventForTesting(esc)
        XCTAssertFalse(cancelled)
    }

    func testSecondHandsFreeTapStillStopsWhenTheLinkWentQuietBetweenTaps() async throws {
        let (runtime, remote, local) = makeSilentMainMacRuntime(timeout: 0.1)
        var live = true
        runtime.isMainMacLive = { live }
        runtime.startDictation(.hotkeyToggle)
        live = false // the link goes stale between the taps

        runtime.startDictation(.hotkeyToggle)

        XCTAssertEqual(runtime.pendingStart?.state, .released)
        XCTAssertEqual(remote(), [.hotkeyToggle, .hotkeyToggle])
        XCTAssertTrue(local().isEmpty, "the stop must not start a local recording")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(local().isEmpty)
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacMissedAlert)
    }

    // MARK: - The replay keeps the gesture

    private func idleAfterSession() -> CoreMessage {
        .sessionState(SessionStateUpdate(sessionId: "s1", state: .idle, initiator: "me", micOwner: "me", target: nil, outcome: .pasted))
    }

    /// Runtime whose fallback attaches a local broker with its own hands-free setting.
    private func makeFallbackRuntime(mainHandsFree: Bool, localHandsFree: Bool)
        -> (EdgeRuntime, remote: () -> [EdgeMessage], local: () -> [EdgeMessage]) {
        let runtime = makeRuntime()
        runtime.startAckTimeout = 0.05
        var remote: [EdgeMessage] = []
        var local: [EdgeMessage] = []
        runtime.send = { remote.append($0) }
        runtime.isMainMacLive = { true }
        runtime.onMainMacUnreachable = {
            runtime.isMainMacLive = nil
            runtime.onMainMacUnreachable = nil
            runtime.send = { local.append($0) }
            runtime.handle(.config(handsFree: localHandsFree)) // what attaching the local edge delivers
        }
        runtime.wireHotkey()
        runtime.handle(.config(handsFree: mainHandsFree))
        return (runtime, { remote }, { local })
    }

    func testHoldGestureReplayedOnAHandsFreeMacStillEndsOnRelease() async throws {
        let (runtime, _, local) = makeFallbackRuntime(mainHandsFree: false, localHandsFree: true)
        runtime.startDictation(.hotkeyDown)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(local(), [.hotkeyDown])

        runtime.hotkeyService.onStop?(.key)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(local(), [.hotkeyDown, .hotkeyUp(reason: .key)], "release ends the hold gesture")

        // Next gesture uses this Mac's own (hands-free) setting.
        runtime.handle(recording())
        runtime.handle(idleAfterSession())
        runtime.hotkeyService.onStart?()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(local().last, .hotkeyToggle)
    }

    func testHandsFreeGestureReplayedOnAHoldMacIgnoresReleaseAndStopsOnTheNextTap() async throws {
        let (runtime, _, local) = makeFallbackRuntime(mainHandsFree: true, localHandsFree: false)
        runtime.startDictation(.hotkeyToggle)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(local(), [.hotkeyToggle])
        runtime.handle(recording())

        runtime.hotkeyService.onStop?(.key) // releasing the key means nothing in hands-free
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(local(), [.hotkeyToggle])

        runtime.hotkeyService.onStart?() // the stopping tap
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(local(), [.hotkeyToggle, .hotkeyToggle])

        runtime.handle(idleAfterSession())
        runtime.hotkeyService.onStart?() // next gesture: this Mac's hold setting
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(local().last, .hotkeyDown)
    }

    func testVoiceLaunchChosenWhileUnansweredIsReplayedLocally() async throws {
        let (runtime, remote, local) = makeFallbackRuntime(mainHandsFree: false, localHandsFree: false)
        runtime.startAckTimeout = 0.4
        let service = runtime.hotkeyService
        service.frontmostAppBundleID = { "org.example.editor" }
        service.dictationKeyIsDown = { true }
        service.applyModifierState(rightHeld: true, shiftHeld: true)
        service.stopModifierWatchdog()
        defer { service.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.pendingStart?.voiceCommand, true)
        XCTAssertEqual(runtime.pendingStart?.commandAppBundleID, "org.example.editor")
        XCTAssertEqual(remote(), [.hotkeyDown, .voiceCommandMode(appBundleId: "org.example.editor")])

        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(local(), [.hotkeyDown, .voiceCommandMode(appBundleId: "org.example.editor")])
    }

    func testPlainPressIsReplayedWithoutVoiceLaunch() async throws {
        let (runtime, _, local) = makeFallbackRuntime(mainHandsFree: false, localHandsFree: false)
        runtime.startDictation(.hotkeyDown)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(local(), [.hotkeyDown])
    }

    func testTapAfterEscCancelledTheLastOneStartsAFreshGesture() async throws {
        let (runtime, _, local) = makeSilentMainMacRuntime(timeout: 0.4)
        runtime.startDictation(.hotkeyToggle)
        let first = runtime.pendingStart?.id
        runtime.hotkeyService.onCancel?()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runtime.pendingStart?.state, .cancelled)

        runtime.startDictation(.hotkeyToggle) // the immediate re-tap

        XCTAssertNotEqual(runtime.pendingStart?.id, first)
        XCTAssertEqual(runtime.pendingStart?.state, .held)
        runtime.remoteSendFailed(.hotkeyToggle, gesture: first) // the old id is still rejected
        XCTAssertTrue(local().isEmpty)

        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(local(), [.hotkeyToggle], "the new tap records here")
        XCTAssertEqual(runtime.alerts.current, EdgeRuntime.cantReachMainMacAlert)
    }
}
