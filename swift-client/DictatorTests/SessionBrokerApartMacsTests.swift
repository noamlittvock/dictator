import XCTest
@testable import Dictator

/// Contract tests use only fake Macs, a manual clock and synthetic audio.
final class SessionBrokerApartMacsTests: XCTestCase {
    private var now: TimeInterval = 0
    private var broker: SessionBroker!

    override func setUp() {
        super.setUp()
        now = 0
        broker = SessionBroker(coreId: "server", clock: { self.now }, makeSessionID: { "s1" })
    }

    @discardableResult
    private func connect(_ id: EdgeID, mic: Bool = true, screenless: Bool = false) -> [BrokerEffect] {
        let caps = EdgeCapabilities(hasMic: mic, inputDeviceUID: mic ? "synthetic-\(id)" : "",
                                    accessibility: !screenless, inputMonitoring: !screenless,
                                    hotkeyMode: "intercept")
        return broker.apply(.edgeConnected(BrokerEdgeInfo(id: id, name: id, caps: caps)))
    }

    @discardableResult
    private func msg(_ message: EdgeMessage, from mac: EdgeID = "desk") -> [BrokerEffect] {
        broker.apply(.message(message, from: mac))
    }

    private func nonLogs(_ effects: [BrokerEffect]) -> [BrokerEffect] {
        effects.filter { if case .log = $0 { return false }; return true }
    }

    private func sends(_ effects: [BrokerEffect]) -> [BrokerEffect] {
        effects.filter { if case .send = $0 { return true }; return false }
    }

    private func captureStarts(_ effects: [BrokerEffect]) -> [BrokerEffect] {
        effects.filter { if case .send(_, .captureStart) = $0 { return true }; return false }
    }

    private func captureCommands(_ effects: [BrokerEffect]) -> [BrokerEffect] {
        effects.filter {
            switch $0 {
            case .send(_, .captureStart), .send(_, .captureStop), .send(_, .captureCancel): return true
            default: return false
            }
        }
    }

    private func errors(_ effects: [BrokerEffect]) -> [BrokerEffect] {
        effects.filter { if case .send(_, .error) = $0 { return true }; return false }
    }

    private var borrowedMicAlert: DictationAlert {
        DictationAlert(title: "This Mac has no microphone",
                       detail: "Dictator only listens through another Mac if you choose it. Pick one under Mac that records in Settings › Your Macs.",
                       action: .macs)
    }

    private var busyAlert: DictationAlert {
        DictationAlert(title: "Still finishing your last dictation",
                       detail: "Nothing was recorded from that press. Wait a moment, then press the key again.")
    }

    /// Read the timer identity from the effect; its numeric starting value is private.
    private func pendingID(_ effects: [BrokerEffect], file: StaticString = #filePath, line: UInt = #line) throws -> PressID {
        let timers = effects.compactMap { effect -> (PressID, TimeInterval)? in
            if case .schedulePressSettle(let id, let delay) = effect { return (id, delay) }
            return nil
        }
        XCTAssertEqual(timers.count, 1, file: file, line: line)
        let timer = try XCTUnwrap(timers.first, file: file, line: line)
        XCTAssertEqual(timer.1, 0.15, file: file, line: line)
        XCTAssertEqual(timer.1, SessionBroker.pressSettle, file: file, line: line)
        XCTAssertEqual(nonLogs(effects), [.schedulePressSettle(timer.0, timer.1)], file: file, line: line)
        XCTAssertNil(broker.session, file: file, line: line)
        return timer.0
    }

    /// A remote pointer is recent, but is not evidence of a shared keyboard.
    private func waitingPress(_ gesture: EdgeMessage, mic: Bool = true) throws -> PressID {
        connect("desk", mic: mic)
        connect("office")
        now = 1
        msg(.pointerPresence, from: "desk")
        now = 90
        msg(.pointerPresence, from: "office")
        now = 100
        return try pendingID(msg(gesture))
    }

    @discardableResult
    private func settle(_ id: PressID) -> [BrokerEffect] {
        now += SessionBroker.pressSettle
        return broker.apply(.pressSettled(id))
    }

    private func assertRecording(_ effects: [BrokerEffect], initiator: EdgeID = "desk", mic: EdgeID = "desk",
                                 handsFree: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(broker.session?.phase, .recording, file: file, line: line)
        XCTAssertEqual(broker.session?.initiator, initiator, file: file, line: line)
        XCTAssertEqual(broker.session?.micOwner, mic, file: file, line: line)
        XCTAssertEqual(broker.session?.target, initiator, file: file, line: line)
        XCTAssertEqual(broker.session?.handsFree, handsFree, file: file, line: line)
        XCTAssertEqual(captureStarts(effects), [.send(mic, .captureStart(sessionId: "s1"))], file: file, line: line)
        XCTAssertTrue(effects.contains(.scheduleWatchdog("s1", EdgeProtocol.maxSessionDuration)), file: file, line: line)
        XCTAssertTrue(effects.contains(.scheduleCountdown("s1", EdgeProtocol.maxSessionDuration - EdgeProtocol.countdownLead)), file: file, line: line)
    }

    private func assertNoTimer(_ effects: [BrokerEffect], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(effects.contains { if case .schedulePressSettle = $0 { return true }; return false }, file: file, line: line)
    }

    private func assertIgnoredWithLog(_ effects: [BrokerEffect], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(nonLogs(effects), [], file: file, line: line)
        XCTAssertTrue(effects.contains { if case .log = $0 { return true }; return false }, file: file, line: line)
    }

    private func assertNoMic(_ effects: [BrokerEffect], on mac: EdgeID = "desk", remoteMic: Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        let message = remoteMic ? borrowedMicAlert.encoded : "No connected edge has a microphone."
        XCTAssertEqual(sends(effects), [.send(mac, .error(code: "noMic", message: message))], file: file, line: line)
        XCTAssertEqual(captureCommands(effects), [], file: file, line: line)
        XCTAssertNil(broker.session, file: file, line: line)
    }

    /// Use the duration limit to stop either gesture without depending on hold membership.
    @discardableResult
    private func prepareTranscription(mic: EdgeID = "desk") -> [BrokerEffect] {
        let stop = broker.apply(.watchdogFired("s1"))
        XCTAssertEqual(broker.session?.phase, .processing)
        XCTAssertEqual(captureCommands(stop), [.send(mic, .captureStop(sessionId: "s1"))])
        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 1600,
                                     durationSeconds: 0.1, byteCount: 6400)
        msg(.audioTake(header), from: mic)
        broker.apply(.audio(Data(repeating: 7, count: 6400), from: mic))
        return stop
    }

    private func finishTranscription() -> [BrokerEffect] {
        broker.apply(.transcriptionFinished("s1", text: "synthetic words", inferenceMs: nil, error: nil))
    }

    private func assertInsertion(_ effects: [BrokerEffect], on mac: EdgeID,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let inserts = effects.filter { if case .send(_, .insert) = $0 { return true }; return false }
        XCTAssertEqual(inserts, [.send(mac, .insert(sessionId: "s1", text: "synthetic words"))], file: file, line: line)
        XCTAssertEqual(broker.session?.target, mac, file: file, line: line)
        XCTAssertEqual(broker.session?.phase, .inserting, file: file, line: line)
    }

    private func assertBusy(_ effects: [BrokerEffect], on mac: EdgeID,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(errors(effects), [.send(mac, .error(code: "sessionBusy", message: busyAlert.encoded))], file: file, line: line)
        XCTAssertEqual(captureCommands(effects), [], file: file, line: line)
        XCTAssertTrue(effects.contains { if case .log = $0 { return true }; return false }, file: file, line: line)
    }

    func testHoldSolePressKeepsInitiatorMicAndTargetDespiteFresherRemotePointer() throws {
        let id = try waitingPress(.hotkeyDown)
        let effects = settle(id)
        assertRecording(effects, handsFree: false)
        XCTAssertFalse(effects.contains(.send("office", .captureStart(sessionId: "s1"))))
    }

    func testHandsFreeSolePressKeepsInitiatorMicAndTargetDespiteFresherRemotePointer() throws {
        let id = try waitingPress(.hotkeyToggle)
        let effects = settle(id)
        assertRecording(effects, handsFree: true)
        XCTAssertFalse(effects.contains(.send("office", .captureStart(sessionId: "s1"))))
    }

    func testHoldRemotePointerMacPressesSecondAndWinsUniversalControl() throws {
        let id = try waitingPress(.hotkeyDown)
        now += 0.005
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office", handsFree: false)
        assertNoTimer(effects)
    }

    func testHandsFreeRemotePointerMacPressesSecondAndWinsUniversalControl() throws {
        let id = try waitingPress(.hotkeyToggle)
        now += 0.005
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office", handsFree: true)
        assertNoTimer(effects)
    }

    func testHoldRemotePointerMacPressesFirstAndWinsUniversalControl() throws {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let first = msg(.hotkeyDown, from: "office")
        assertNoTimer(first)
        assertRecording(first, initiator: "office", mic: "office", handsFree: false)
        now += 0.005
        let duplicate = msg(.hotkeyDown)
        XCTAssertEqual(errors(duplicate), [])
        XCTAssertEqual(captureCommands(duplicate), [])
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertEqual(broker.session?.initiator, "office")
        XCTAssertEqual(broker.session?.micOwner, "office")
        XCTAssertEqual(broker.session?.target, "office")
    }

    func testHandsFreeRemotePointerMacPressesFirstAndWinsUniversalControl() throws {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let first = msg(.hotkeyToggle, from: "office")
        assertNoTimer(first)
        assertRecording(first, initiator: "office", mic: "office", handsFree: true)
        now += 0.005
        let duplicate = msg(.hotkeyToggle)
        XCTAssertEqual(errors(duplicate), [])
        XCTAssertEqual(captureCommands(duplicate), [])
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertEqual(broker.session?.initiator, "office")
        XCTAssertEqual(broker.session?.micOwner, "office")
        XCTAssertEqual(broker.session?.target, "office")
    }

    func testHoldMiclessMacAloneGetsLegacyNoMicErrorWithoutCapture() throws {
        connect("desk", mic: false)
        let effects = msg(.hotkeyDown)
        assertNoTimer(effects)
        assertNoMic(effects, remoteMic: false)
    }

    func testHandsFreeMiclessMacAloneGetsLegacyNoMicErrorWithoutCapture() throws {
        connect("desk", mic: false)
        let effects = msg(.hotkeyToggle)
        assertNoTimer(effects)
        assertNoMic(effects, remoteMic: false)
    }

    func testHoldMiclessMacWithUnpressedRemoteMicGetsActionableErrorAfterSettle() throws {
        connect("desk", mic: false); connect("office")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        assertNoMic(settle(id), remoteMic: true)
    }

    func testHandsFreeMiclessMacWithUnpressedRemoteMicGetsActionableErrorAfterSettle() throws {
        connect("desk", mic: false); connect("office")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        assertNoMic(settle(id), remoteMic: true)
    }

    func testHoldMiclessPointerMacBorrowsOnlyFromCoPresserArrivingSecond() throws {
        connect("desk", mic: false); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        now += 0.005
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, mic: "office", handsFree: false)
    }

    func testHandsFreeMiclessPointerMacBorrowsOnlyFromCoPresserArrivingSecond() throws {
        connect("desk", mic: false); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        now += 0.005
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, mic: "office", handsFree: true)
    }

    func testHoldMiclessPointerMacBorrowsOnlyFromCoPresserArrivingFirst() throws {
        connect("desk", mic: false); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        let id = try pendingID(msg(.hotkeyDown, from: "office"))
        now += 0.005
        let effects = msg(.hotkeyDown)
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, mic: "office", handsFree: false)
    }

    func testHandsFreeMiclessPointerMacBorrowsOnlyFromCoPresserArrivingFirst() throws {
        connect("desk", mic: false); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        let id = try pendingID(msg(.hotkeyToggle, from: "office"))
        now += 0.005
        let effects = msg(.hotkeyToggle)
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, mic: "office", handsFree: true)
    }

    func testHoldConnectedMicPreferenceAvoidsWaitingForMiclessPresser() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("office"))
        now = 100
        let effects = msg(.hotkeyDown)
        assertNoTimer(effects)
        assertRecording(effects, mic: "office", handsFree: false)
    }

    func testHandsFreeConnectedMicPreferenceAvoidsWaitingForMiclessPresser() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("office"))
        now = 100
        let effects = msg(.hotkeyToggle)
        assertNoTimer(effects)
        assertRecording(effects, mic: "office", handsFree: true)
    }

    func testHoldExplicitMicPreferenceBeatsInitiatorsOwnMic() throws {
        connect("desk"); connect("office")
        broker.apply(.micOwnerChanged("office"))
        let effects = msg(.hotkeyDown)
        assertNoTimer(effects)
        assertRecording(effects, mic: "office", handsFree: false)
    }

    func testHandsFreeExplicitMicPreferenceBeatsInitiatorsOwnMic() throws {
        connect("desk"); connect("office")
        broker.apply(.micOwnerChanged("office"))
        let effects = msg(.hotkeyToggle)
        assertNoTimer(effects)
        assertRecording(effects, mic: "office", handsFree: true)
    }

    func testHoldMicPreferenceDoesNotBypassWaitingForRemoteClaimant() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("office"))
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        assertRecording(settle(id), mic: "office", handsFree: false)
    }

    func testHandsFreeMicPreferenceDoesNotBypassWaitingForRemoteClaimant() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("office"))
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        assertRecording(settle(id), mic: "office", handsFree: true)
    }

    func testHoldDisconnectedMicPreferenceDoesNotAuthorizeAnotherUnpressedMic() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("laptop"))
        let id = try pendingID(msg(.hotkeyDown))
        assertNoMic(settle(id), remoteMic: true)
    }

    func testHandsFreeDisconnectedMicPreferenceDoesNotAuthorizeAnotherUnpressedMic() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("laptop"))
        let id = try pendingID(msg(.hotkeyToggle))
        assertNoMic(settle(id), remoteMic: true)
    }

    func testHoldMiclessPreferenceDoesNotAuthorizeAnotherUnpressedMic() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("desk"))
        let id = try pendingID(msg(.hotkeyDown))
        assertNoMic(settle(id), remoteMic: true)
    }

    func testHandsFreeMiclessPreferenceDoesNotAuthorizeAnotherUnpressedMic() throws {
        connect("desk", mic: false); connect("office")
        broker.apply(.micOwnerChanged("desk"))
        let id = try pendingID(msg(.hotkeyToggle))
        assertNoMic(settle(id), remoteMic: true)
    }

    func testHoldUnpressedThirdMacWithPointerCannotBecomeInitiatorOfCoPress() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        now = 90
        msg(.pointerPresence, from: "laptop")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        now += 0.005
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office", handsFree: false)
    }

    func testHandsFreeUnpressedThirdMacWithPointerCannotBecomeInitiatorOfCoPress() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        now = 90
        msg(.pointerPresence, from: "laptop")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        now += 0.005
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office", handsFree: true)
    }

    func testHoldCoPressWithoutClaimAmongPressersFallsBackToOriginalPresser() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 90
        msg(.pointerPresence, from: "laptop")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, handsFree: false)
    }

    func testHandsFreeCoPressWithoutClaimAmongPressersFallsBackToOriginalPresser() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 90
        msg(.pointerPresence, from: "laptop")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, handsFree: true)
    }

    func testHoldStaleRemotePointerCannotRedirectInsertionAfterSoloSettle() throws {
        let id = try waitingPress(.hotkeyDown)
        assertRecording(settle(id), handsFree: false)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHandsFreeStaleRemotePointerCannotRedirectInsertionAfterSoloSettle() throws {
        let id = try waitingPress(.hotkeyToggle)
        assertRecording(settle(id), handsFree: true)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHoldStalePointerCannotBeatFreshPostStartKeystrokeFromPresser() throws {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now += 0.005
        msg(.hotkeyDown, from: "office")
        now += 1
        let effects = msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        XCTAssertTrue(sends(effects).contains { if case .send(_, .sessionState(let state)) = $0 { return state.target == "office" }; return false })
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHandsFreeStalePointerCannotBeatFreshPostStartKeystrokeFromPresser() throws {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 0.005
        msg(.hotkeyToggle, from: "office")
        now += 1
        let effects = msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        XCTAssertTrue(sends(effects).contains { if case .send(_, .sessionState(let state)) = $0 { return state.target == "office" }; return false })
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHoldPostStartPointerFromNonPresserMovesLiveTargetAndInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now += 1
        let effects = msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        let states = sends(effects).compactMap { effect -> SessionStateUpdate? in
            if case .send(_, .sessionState(let state)) = effect { return state }; return nil
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.target == "office" })
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHandsFreePostStartPointerFromNonPresserMovesLiveTargetAndInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 1
        let effects = msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        let states = sends(effects).compactMap { effect -> SessionStateUpdate? in
            if case .send(_, .sessionState(let state)) = effect { return state }; return nil
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.target == "office" })
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHoldPostStartKeystrokeFromNonPresserCannotMoveLiveTargetOrInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now += 1
        let effects = msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(sends(effects), [])
        XCTAssertEqual(broker.session?.target, "desk")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHandsFreePostStartKeystrokeFromNonPresserCannotMoveLiveTargetOrInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 1
        let effects = msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(sends(effects), [])
        XCTAssertEqual(broker.session?.target, "desk")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHoldPostStartKeystrokeFromCoPresserMovesLiveTargetAndInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now += 0.005
        msg(.hotkeyDown, from: "office")
        now += 1
        let effects = msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        XCTAssertFalse(sends(effects).isEmpty)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHandsFreePostStartKeystrokeFromCoPresserMovesLiveTargetAndInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 0.005
        msg(.hotkeyToggle, from: "office")
        now += 1
        let effects = msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        XCTAssertFalse(sends(effects).isEmpty)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHoldPostStartPointerWinsOverLaterKeystrokeFromCoPresser() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now += 0.005
        msg(.hotkeyDown, from: "office")
        now += 1
        msg(.pointerPresence, from: "laptop")
        now += 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "laptop")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "laptop")
    }

    func testHandsFreePostStartPointerWinsOverLaterKeystrokeFromCoPresser() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 0.005
        msg(.hotkeyToggle, from: "office")
        now += 1
        msg(.pointerPresence, from: "laptop")
        now += 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "laptop")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "laptop")
    }

    func testHoldPointerAtExactSessionStartIsEligibleToMoveTarget() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHandsFreePointerAtExactSessionStartIsEligibleToMoveTarget() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHoldPointerDuringProcessingRedirectsInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        prepareTranscription()
        now += 1
        msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHandsFreePointerDuringProcessingRedirectsInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        prepareTranscription()
        now += 1
        msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHoldNonPresserKeystrokeDuringProcessingCannotRedirectInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        prepareTranscription()
        now += 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "desk")
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHandsFreeNonPresserKeystrokeDuringProcessingCannotRedirectInsertion() throws {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        prepareTranscription()
        now += 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "desk")
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHoldRepeatFromPendingPresserDoesNotStartOrReschedule() throws {
        let id = try waitingPress(.hotkeyDown)
        assertIgnoredWithLog(msg(.hotkeyDown))
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: false)
    }

    func testHandsFreeRepeatFromPendingPresserDoesNotStartOrReschedule() throws {
        let id = try waitingPress(.hotkeyToggle)
        assertIgnoredWithLog(msg(.hotkeyToggle))
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: true)
    }

    func testHoldDifferentPendingGestureDoesNotBecomeCoPressEvidence() throws {
        let id = try waitingPress(.hotkeyDown)
        assertIgnoredWithLog(msg(.hotkeyToggle, from: "office"))
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: false)
    }

    func testHandsFreeDifferentPendingGestureDoesNotBecomeCoPressEvidence() throws {
        let id = try waitingPress(.hotkeyToggle)
        assertIgnoredWithLog(msg(.hotkeyDown, from: "office"))
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: true)
    }

    func testHoldCancelPendingPressPreventsCaptureAndIgnoresLateSettle() throws {
        let id = try waitingPress(.hotkeyDown)
        let effects = msg(.hotkeyCancel)
        XCTAssertEqual(nonLogs(effects), [.cancelPressSettle(id)])
        XCTAssertNil(broker.session)
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertNil(broker.session)
    }

    func testHandsFreeCancelPendingPressPreventsCaptureAndIgnoresLateSettle() throws {
        let id = try waitingPress(.hotkeyToggle)
        let effects = msg(.hotkeyCancel)
        XCTAssertEqual(nonLogs(effects), [.cancelPressSettle(id)])
        XCTAssertNil(broker.session)
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertNil(broker.session)
    }

    func testHoldVoiceCommandModeDuringPendingPressIsAppliedAndBroadcast() throws {
        let id = try waitingPress(.hotkeyDown)
        let pending = msg(.voiceCommandMode())
        XCTAssertEqual(sends(pending), [])
        XCTAssertNil(broker.session)
        let effects = settle(id)
        assertRecording(effects, handsFree: false)
        XCTAssertEqual(broker.session?.voiceCommandMode, true)
        let states = sends(effects).compactMap { effect -> SessionStateUpdate? in
            if case .send(_, .sessionState(let state)) = effect { return state }; return nil
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.voiceCommandMode == true })
    }

    func testHandsFreeVoiceCommandModeDuringPendingPressIsAppliedAndBroadcast() throws {
        let id = try waitingPress(.hotkeyToggle)
        let pending = msg(.voiceCommandMode())
        XCTAssertEqual(sends(pending), [])
        XCTAssertNil(broker.session)
        let effects = settle(id)
        assertRecording(effects, handsFree: true)
        XCTAssertEqual(broker.session?.voiceCommandMode, true)
        let states = sends(effects).compactMap { effect -> SessionStateUpdate? in
            if case .send(_, .sessionState(let state)) = effect { return state }; return nil
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.voiceCommandMode == true })
    }

    func testHoldPendingPresserDisconnectCancelsAndCannotBeResurrected() throws {
        let id = try waitingPress(.hotkeyDown)
        let effects = broker.apply(.edgeDisconnected("desk"))
        XCTAssertEqual(nonLogs(effects), [.cancelPressSettle(id)])
        XCTAssertNil(broker.session)
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertNil(broker.session)
    }

    func testHandsFreePendingPresserDisconnectCancelsAndCannotBeResurrected() throws {
        let id = try waitingPress(.hotkeyToggle)
        let effects = broker.apply(.edgeDisconnected("desk"))
        XCTAssertEqual(nonLogs(effects), [.cancelPressSettle(id)])
        XCTAssertNil(broker.session)
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertNil(broker.session)
    }

    func testHoldPendingBystanderDisconnectDoesNotDropThePress() throws {
        let id = try waitingPress(.hotkeyDown)
        let effects = broker.apply(.edgeDisconnected("office"))
        XCTAssertEqual(nonLogs(effects), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: false)
    }

    func testHandsFreePendingBystanderDisconnectDoesNotDropThePress() throws {
        let id = try waitingPress(.hotkeyToggle)
        let effects = broker.apply(.edgeDisconnected("office"))
        XCTAssertEqual(nonLogs(effects), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: true)
    }

    func testHoldRemoteMicDisconnectWhilePendingProducesNoMicWithoutCapture() throws {
        connect("desk", mic: false); connect("office")
        let id = try pendingID(msg(.hotkeyDown))
        broker.apply(.edgeDisconnected("office"))
        assertNoMic(settle(id), remoteMic: false)
    }

    func testHandsFreeRemoteMicDisconnectWhilePendingProducesNoMicWithoutCapture() throws {
        connect("desk", mic: false); connect("office")
        let id = try pendingID(msg(.hotkeyToggle))
        broker.apply(.edgeDisconnected("office"))
        assertNoMic(settle(id), remoteMic: false)
    }

    func testHoldWrongSettleIDLeavesCurrentPressPending() throws {
        let id = try waitingPress(.hotkeyDown)
        XCTAssertEqual(nonLogs(broker.apply(.pressSettled(id + 1))), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: false)
    }

    func testHandsFreeWrongSettleIDLeavesCurrentPressPending() throws {
        let id = try waitingPress(.hotkeyToggle)
        XCTAssertEqual(nonLogs(broker.apply(.pressSettled(id + 1))), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: true)
    }

    func testHoldLateSettleAfterCoPressCannotStartAnotherCapture() throws {
        let id = try waitingPress(.hotkeyDown)
        now += 0.005
        msg(.hotkeyDown, from: "office")
        let before = broker.session
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertEqual(broker.session, before)
    }

    func testHandsFreeLateSettleAfterCoPressCannotStartAnotherCapture() throws {
        let id = try waitingPress(.hotkeyToggle)
        now += 0.005
        msg(.hotkeyToggle, from: "office")
        let before = broker.session
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertEqual(broker.session, before)
    }

    func testHoldSecondPressAfterCancelHasIncreasingIDAndRejectsOldTimer() throws {
        let first = try waitingPress(.hotkeyDown)
        msg(.hotkeyCancel)
        let second = try pendingID(msg(.hotkeyDown))
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(nonLogs(broker.apply(.pressSettled(first))), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(second), handsFree: false)
    }

    func testHandsFreeSecondPressAfterCancelHasIncreasingIDAndRejectsOldTimer() throws {
        let first = try waitingPress(.hotkeyToggle)
        msg(.hotkeyCancel)
        let second = try pendingID(msg(.hotkeyToggle))
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(nonLogs(broker.apply(.pressSettled(first))), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(second), handsFree: true)
    }

    func testHoldSecondPressAfterNoMicFailureCanStillBorrowFromCoPresser() throws {
        connect("desk", mic: false); connect("office")
        let first = try pendingID(msg(.hotkeyDown))
        assertNoMic(settle(first), remoteMic: true)
        let second = try pendingID(msg(.hotkeyDown))
        XCTAssertGreaterThan(second, first)
        let effects = msg(.hotkeyDown, from: "office")
        assertRecording(effects, mic: "office", handsFree: false)
    }

    func testHandsFreeSecondPressAfterNoMicFailureCanStillBorrowFromCoPresser() throws {
        connect("desk", mic: false); connect("office")
        let first = try pendingID(msg(.hotkeyToggle))
        assertNoMic(settle(first), remoteMic: true)
        let second = try pendingID(msg(.hotkeyToggle))
        XCTAssertGreaterThan(second, first)
        let effects = msg(.hotkeyToggle, from: "office")
        assertRecording(effects, mic: "office", handsFree: true)
    }

    func testHoldSoloSettleRecordsPresenceSoNextPressStartsWithoutWaiting() throws {
        let id = try waitingPress(.hotkeyDown)
        assertRecording(settle(id), handsFree: false)
        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "desk")
        msg(.hotkeyCancel)
        now += 1
        let effects = msg(.hotkeyDown)
        assertNoTimer(effects)
        assertRecording(effects, handsFree: false)
    }

    func testHandsFreeSoloSettleRecordsPresenceSoNextPressStartsWithoutWaiting() throws {
        let id = try waitingPress(.hotkeyToggle)
        assertRecording(settle(id), handsFree: true)
        XCTAssertEqual(broker.focusClaims.freshest(connected: Set(broker.edges.keys)), "desk")
        msg(.hotkeyCancel)
        now += 1
        let effects = msg(.hotkeyToggle)
        assertNoTimer(effects)
        assertRecording(effects, handsFree: true)
    }

    func testHoldSingleMacStartsAtOnceWithUnchangedStartEffects() throws {
        connect("desk")
        now = 100
        let state = SessionStateUpdate(sessionId: "s1", state: .recording, initiator: "desk", micOwner: "desk", target: "desk")
        let effects = msg(.hotkeyDown)
        XCTAssertEqual(effects, [
            .send("desk", .sessionState(state)),
            .send("desk", .captureStart(sessionId: "s1")),
            .scheduleWatchdog("s1", EdgeProtocol.maxSessionDuration),
            .scheduleCountdown("s1", EdgeProtocol.maxSessionDuration - EdgeProtocol.countdownLead)
        ])
        assertRecording(effects, handsFree: false)
    }

    func testHandsFreeSingleMacStartsAtOnceWithUnchangedStartEffects() throws {
        connect("desk")
        now = 100
        let state = SessionStateUpdate(sessionId: "s1", state: .recording, initiator: "desk", micOwner: "desk", target: "desk")
        let effects = msg(.hotkeyToggle)
        XCTAssertEqual(effects, [
            .send("desk", .sessionState(state)),
            .send("desk", .captureStart(sessionId: "s1")),
            .scheduleWatchdog("s1", EdgeProtocol.maxSessionDuration),
            .scheduleCountdown("s1", EdgeProtocol.maxSessionDuration - EdgeProtocol.countdownLead)
        ])
        assertRecording(effects, handsFree: true)
    }

    func testHoldScreenlessMiclessServerNeverReceivesCaptureThroughFullSession() throws {
        connect("server", mic: false, screenless: true)
        connect("desk")
        now = 100
        let start = msg(.hotkeyDown)
        assertNoTimer(start)
        assertRecording(start, handsFree: false)
        let stop = prepareTranscription()
        let finish = finishTranscription()
        assertInsertion(finish, on: "desk")
        let done = msg(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil))
        XCTAssertNil(broker.session)
        let commands = captureCommands(start + stop + finish + done)
        XCTAssertEqual(commands, [.send("desk", .captureStart(sessionId: "s1")), .send("desk", .captureStop(sessionId: "s1"))])
    }

    func testHandsFreeScreenlessMiclessServerNeverReceivesCaptureThroughFullSession() throws {
        connect("server", mic: false, screenless: true)
        connect("desk")
        now = 100
        let start = msg(.hotkeyToggle)
        assertNoTimer(start)
        assertRecording(start, handsFree: true)
        let stop = prepareTranscription()
        let finish = finishTranscription()
        assertInsertion(finish, on: "desk")
        let done = msg(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil))
        XCTAssertNil(broker.session)
        let commands = captureCommands(start + stop + finish + done)
        XCTAssertEqual(commands, [.send("desk", .captureStart(sessionId: "s1")), .send("desk", .captureStop(sessionId: "s1"))])
    }

    func testHoldMiclessServerCannotBeFallbackForMiclessPresser() throws {
        connect("server", mic: false, screenless: true)
        connect("desk", mic: false)
        let effects = msg(.hotkeyDown)
        assertNoTimer(effects)
        assertNoMic(effects, remoteMic: false)
    }

    func testHandsFreeMiclessServerCannotBeFallbackForMiclessPresser() throws {
        connect("server", mic: false, screenless: true)
        connect("desk", mic: false)
        let effects = msg(.hotkeyToggle)
        assertNoTimer(effects)
        assertNoMic(effects, remoteMic: false)
    }

    func testHoldBorrowedMicDisconnectEndsRecordingWithoutStartingUnpressedMic() throws {
        connect("desk", mic: false); connect("office"); connect("laptop")
        let id = try pendingID(msg(.hotkeyDown))
        let start = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(start.contains(.cancelPressSettle(id)))
        assertRecording(start, mic: "office", handsFree: false)
        let effects = broker.apply(.edgeDisconnected("office"))
        XCTAssertNil(broker.session)
        XCTAssertEqual(captureStarts(effects), [])
        XCTAssertFalse(captureCommands(effects).contains(.send("laptop", .captureStart(sessionId: "s1"))))
    }

    func testHandsFreeBorrowedMicDisconnectEndsRecordingWithoutStartingUnpressedMic() throws {
        connect("desk", mic: false); connect("office"); connect("laptop")
        let id = try pendingID(msg(.hotkeyToggle))
        let start = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(start.contains(.cancelPressSettle(id)))
        assertRecording(start, mic: "office", handsFree: true)
        let effects = broker.apply(.edgeDisconnected("office"))
        XCTAssertNil(broker.session)
        XCTAssertEqual(captureStarts(effects), [])
        XCTAssertFalse(captureCommands(effects).contains(.send("laptop", .captureStart(sessionId: "s1"))))
    }

    func testHoldStaleClaimCannotRescueDisconnectedInitiatorAtInsertion() throws {
        connect("desk"); connect("office")
        now = 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        assertRecording(settle(id), handsFree: false)
        prepareTranscription()
        let disconnected = broker.apply(.edgeDisconnected("desk"))
        let effects = finishTranscription()
        XCTAssertFalse((disconnected + effects).contains { if case .send(_, .insert) = $0 { return true }; return false })
        XCTAssertNil(broker.session)
    }

    func testHandsFreeStaleClaimCannotRescueDisconnectedInitiatorAtInsertion() throws {
        connect("desk"); connect("office")
        now = 1
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        assertRecording(settle(id), handsFree: true)
        prepareTranscription()
        let disconnected = broker.apply(.edgeDisconnected("desk"))
        let effects = finishTranscription()
        XCTAssertFalse((disconnected + effects).contains { if case .send(_, .insert) = $0 { return true }; return false })
        XCTAssertNil(broker.session)
    }

    func testQuickHoldTapWhilePendingReplaysReleaseAndStopsOnlyAfterGrace() throws {
        let id = try waitingPress(.hotkeyDown)
        now += 0.01
        XCTAssertEqual(sends(msg(.hotkeyUp(reason: .key))), [])
        XCTAssertNil(broker.session)
        let effects = settle(id)
        assertRecording(effects)
        XCTAssertTrue(effects.contains(.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)))
        XCTAssertFalse(effects.contains(.send("desk", .captureStop(sessionId: "s1"))))
        let stopped = broker.apply(.releaseGraceFired("s1"))
        XCTAssertEqual(captureCommands(stopped), [.send("desk", .captureStop(sessionId: "s1"))])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testPendingHoldReleaseDoesNotLeaveReleasedPresserHoldingCoPressSession() throws {
        let id = try waitingPress(.hotkeyDown)
        msg(.hotkeyUp(reason: .key))
        now += 0.005
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office")
        XCTAssertFalse(effects.contains(.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)))
        XCTAssertEqual(nonLogs(msg(.hotkeyUp(reason: .key), from: "office")), [
            .scheduleReleaseGrace("s1", SessionBroker.releaseGrace)
        ])
        XCTAssertEqual(captureCommands(broker.apply(.releaseGraceFired("s1"))), [
            .send("office", .captureStop(sessionId: "s1"))
        ])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testHoldCoPressKeepsRecordingUntilBothPressersRelease() throws {
        let id = try waitingPress(.hotkeyDown)
        now += 0.005
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office")
        XCTAssertEqual(nonLogs(msg(.hotkeyUp(reason: .key), from: "office")), [])
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertEqual(nonLogs(msg(.hotkeyUp(reason: .key))), [
            .scheduleReleaseGrace("s1", SessionBroker.releaseGrace)
        ])
        XCTAssertEqual(captureCommands(broker.apply(.releaseGraceFired("s1"))), [
            .send("office", .captureStop(sessionId: "s1"))
        ])
    }

    func testPendingHandsFreeKeyUpDoesNotStopOrScheduleReleaseGrace() throws {
        let id = try waitingPress(.hotkeyToggle)
        now += 0.01
        XCTAssertEqual(sends(msg(.hotkeyUp(reason: .key))), [])
        let effects = settle(id)
        assertRecording(effects, handsFree: true)
        XCTAssertFalse(effects.contains(.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)))
        XCTAssertEqual(nonLogs(broker.apply(.releaseGraceFired("s1"))), [])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testTypedCharacterDropsASettlingHoldPress() throws {
        let id = try waitingPress(.hotkeyDown)
        XCTAssertEqual(nonLogs(msg(.pressAbandoned)), [.cancelPressSettle(id)])
        XCTAssertEqual(nonLogs(msg(.hotkeyUp(reason: .key))), [])
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertNil(broker.session)
    }

    func testTypedCharacterDropsASettlingHandsFreePress() throws {
        let id = try waitingPress(.hotkeyToggle)
        msg(.pressAbandoned)
        XCTAssertEqual(captureStarts(settle(id)), [])
        XCTAssertNil(broker.session)
    }

    func testAbandonFromAnotherMacLeavesTheSettlingPressAlone() throws {
        let id = try waitingPress(.hotkeyDown)
        XCTAssertEqual(nonLogs(msg(.pressAbandoned, from: "office")), [])
        assertRecording(settle(id))
    }

    func testAbandonNeverStopsARunningRecording() {
        connect("desk"); connect("office")
        msg(.hotkeyDown)
        XCTAssertEqual(nonLogs(msg(.pressAbandoned)), [])
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testSecondCopyOfTheStoppingTapIsNotReportedAsBusy() {
        connect("desk"); connect("office")
        msg(.hotkeyToggle)
        now += 1
        msg(.hotkeyToggle)
        XCTAssertEqual(broker.session?.phase, .processing)
        now += 0.01
        XCTAssertEqual(errors(msg(.hotkeyToggle, from: "office")), [])
    }

    func testARealTapAfterTheStoppingTapIsReportedAsBusy() {
        connect("desk"); connect("office")
        msg(.hotkeyToggle)
        now += 1
        msg(.hotkeyToggle)
        now += SessionBroker.toggleDebounce
        XCTAssertEqual(errors(msg(.hotkeyToggle, from: "office")).count, 1)
    }

    func testPressingAgainWhilePendingKeepsTheHold() throws {
        let id = try waitingPress(.hotkeyDown)
        msg(.hotkeyUp(reason: .key))
        msg(.hotkeyDown)
        let effects = settle(id)
        XCTAssertFalse(effects.contains(.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)))
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testEveryPresserIsAnsweredWhenNoneOfThemHasAMicrophone() {
        connect("desk", mic: false); connect("office", mic: false); connect("server")
        msg(.hotkeyDown)
        let effects = msg(.hotkeyDown, from: "office")
        let refusal = CoreMessage.error(code: "noMic", message: DictationAlert.microphoneOnAnotherMac().encoded)
        XCTAssertTrue(effects.contains(.send("desk", refusal)))
        XCTAssertTrue(effects.contains(.send("office", refusal)))
        XCTAssertFalse(effects.contains(.send("server", refusal)))
        XCTAssertNil(broker.session)
    }

    func testHandsFreeDuplicateTapAfterPendingCoPressDoesNotStopOrReportBusy() throws {
        let id = try waitingPress(.hotkeyToggle)
        now += 0.005
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office", handsFree: true)
        now += 0.005
        let duplicate = msg(.hotkeyToggle)
        assertIgnoredWithLog(duplicate)
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertEqual(broker.session?.handsFree, true)
    }

    func testHandsFreeDuplicateTapFromOriginalMacDoesNotStopOrReportBusy() {
        connect("desk")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 0.005
        assertIgnoredWithLog(msg(.hotkeyToggle))
        XCTAssertEqual(broker.session?.phase, .recording)
    }

    func testHandsFreeTapAtDebounceBoundaryStopsCapture() {
        connect("desk")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += SessionBroker.toggleDebounce
        let effects = msg(.hotkeyToggle)
        XCTAssertEqual(errors(effects), [])
        XCTAssertEqual(captureCommands(effects), [.send("desk", .captureStop(sessionId: "s1"))])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testSingleMacHoldReleaseRetainsGraceAndInsertionBehavior() {
        connect("desk")
        now = 100
        assertRecording(msg(.hotkeyDown))
        XCTAssertEqual(msg(.hotkeyUp(reason: .key)), [.scheduleReleaseGrace("s1", SessionBroker.releaseGrace)])
        XCTAssertEqual(broker.session?.phase, .recording)
        XCTAssertEqual(captureCommands(broker.apply(.releaseGraceFired("s1"))), [.send("desk", .captureStop(sessionId: "s1"))])
        let header = AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 1600,
                                     durationSeconds: 0.1, byteCount: 6400)
        msg(.audioTake(header))
        broker.apply(.audio(Data(repeating: 7, count: 6400), from: "desk"))
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testSingleMacHandsFreeReleaseIsIgnoredAndLaterTapStops() {
        connect("desk")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        XCTAssertEqual(nonLogs(msg(.hotkeyUp(reason: .key))), [])
        XCTAssertEqual(broker.session?.phase, .recording)
        now += SessionBroker.toggleDebounce
        XCTAssertEqual(captureCommands(msg(.hotkeyToggle)), [.send("desk", .captureStop(sessionId: "s1"))])
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testJoinHoldDoesNotSendBusyOrConsumeTheNextBusyNotice() {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyDown))
        now += 0.005
        assertIgnoredWithLog(msg(.hotkeyDown, from: "office"))
        XCTAssertEqual(broker.session?.phase, .recording)
        assertBusy(msg(.hotkeyToggle, from: "office"), on: "office")
        XCTAssertEqual(broker.session?.handsFree, false)
    }

    func testAbsorbedToggleDoesNotSendBusyOrConsumeTheNextBusyNotice() {
        connect("desk"); connect("office")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 0.005
        assertIgnoredWithLog(msg(.hotkeyToggle, from: "office"))
        XCTAssertEqual(broker.session?.phase, .recording)
        assertBusy(msg(.hotkeyDown, from: "office"), on: "office")
        XCTAssertEqual(broker.session?.handsFree, true)
    }

    func testBusyNoticeIsLimitedPerMacAcrossGestureKinds() {
        connect("desk"); connect("office")
        now = 100
        msg(.hotkeyDown)
        prepareTranscription()
        assertBusy(msg(.hotkeyDown, from: "office"), on: "office")
        now += 0.01
        let repeated = msg(.hotkeyToggle, from: "office")
        XCTAssertEqual(errors(repeated), [])
        XCTAssertEqual(captureCommands(repeated), [])
        XCTAssertEqual(broker.session?.phase, .processing)
        assertBusy(msg(.hotkeyToggle), on: "desk")
    }

    func testBusyNoticeCanRepeatAtTwoSecondsAndSuppressedPressDoesNotExtendInterval() {
        XCTAssertEqual(SessionBroker.busyNoticeInterval, 2)
        connect("desk")
        now = 100
        msg(.hotkeyDown)
        prepareTranscription()
        assertBusy(msg(.hotkeyDown), on: "desk")
        now = 101.999
        let suppressed = msg(.hotkeyDown)
        assertIgnoredWithLog(suppressed)
        XCTAssertEqual(broker.session?.phase, .processing)
        now = 102
        assertBusy(msg(.hotkeyDown), on: "desk")
        XCTAssertEqual(broker.session?.phase, .processing)
    }

    func testBusyNoticeDuringProcessingIsNotResetWhenSessionEntersInserting() {
        connect("desk")
        now = 100
        msg(.hotkeyDown)
        prepareTranscription()
        assertBusy(msg(.hotkeyToggle), on: "desk")
        assertInsertion(finishTranscription(), on: "desk")
        now += 0.01
        assertIgnoredWithLog(msg(.hotkeyDown))
        XCTAssertEqual(broker.session?.phase, .inserting)
    }

    func testMicrophoneOnAnotherMacAlertHasExactContractCopyAndAction() {
        XCTAssertEqual(DictationAlert.microphoneOnAnotherMac(), borrowedMicAlert)
    }

    func testStillFinishingAlertHasExactContractCopyAndNoAction() {
        XCTAssertEqual(DictationAlert.dictationStillFinishing(), busyAlert)
        XCTAssertNil(DictationAlert.dictationStillFinishing().action)
    }

    func testHoldPressDuringProcessingReportsBusyWithoutChangingSession() {
        connect("desk"); connect("office")
        now = 100
        msg(.hotkeyDown)
        prepareTranscription()
        let before = broker.session
        assertBusy(msg(.hotkeyDown, from: "office"), on: "office")
        XCTAssertEqual(broker.session, before)
    }

    func testTogglePressDuringProcessingReportsBusyWithoutChangingSession() {
        connect("desk"); connect("office")
        now = 100
        msg(.hotkeyDown)
        prepareTranscription()
        let before = broker.session
        assertBusy(msg(.hotkeyToggle, from: "office"), on: "office")
        XCTAssertEqual(broker.session, before)
    }

    func testHoldPressDuringInsertingReportsBusyWithoutChangingSession() {
        connect("desk"); connect("office")
        now = 100
        msg(.hotkeyDown)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
        let before = broker.session
        assertBusy(msg(.hotkeyDown, from: "office"), on: "office")
        XCTAssertEqual(broker.session, before)
    }

    func testTogglePressDuringInsertingReportsBusyWithoutChangingSession() {
        connect("desk"); connect("office")
        now = 100
        msg(.hotkeyDown)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
        let before = broker.session
        assertBusy(msg(.hotkeyToggle, from: "office"), on: "office")
        XCTAssertEqual(broker.session, before)
    }

    func testHoldPressDuringHandsFreeReportsBusyWithoutChangingSession() {
        connect("desk"); connect("office")
        now = 100
        msg(.hotkeyToggle)
        let before = broker.session
        assertBusy(msg(.hotkeyDown, from: "office"), on: "office")
        XCTAssertEqual(broker.session, before)
    }

    func testTogglePressDuringHoldReportsBusyWithoutChangingSession() {
        connect("desk"); connect("office")
        now = 100
        msg(.hotkeyDown)
        let before = broker.session
        assertBusy(msg(.hotkeyToggle, from: "office"), on: "office")
        XCTAssertEqual(broker.session, before)
    }

    func testHoldDisconnectedMacCannotSupplyPendingCoPressEvidence() throws {
        let id = try waitingPress(.hotkeyDown)
        XCTAssertEqual(nonLogs(msg(.hotkeyDown, from: "laptop")), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: false)
    }

    func testHoldDisconnectedClaimantCannotDelayImmediateStart() {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence, from: "office")
        broker.apply(.edgeDisconnected("office"))
        now = 100
        let effects = msg(.hotkeyDown)
        assertNoTimer(effects)
        assertRecording(effects, handsFree: false)
    }

    func testHoldDisconnectedFreshTargetFallsBackToNextEligiblePointerAtInsertion() {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        prepareTranscription()
        now = 101
        msg(.pointerPresence, from: "laptop")
        now = 102
        msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        broker.apply(.edgeDisconnected("office"))
        assertInsertion(finishTranscription(), on: "laptop")
    }

    func testHoldFreshestPointerUsesReceiptTimeRatherThanMessageOrder() {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now = 102
        msg(.pointerPresence, from: "office")
        now = 101
        msg(.pointerPresence, from: "laptop")
        XCTAssertEqual(broker.session?.target, "office")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHoldVoiceCommandModeSurvivesImmediateCoPressResolution() throws {
        let id = try waitingPress(.hotkeyDown)
        msg(.voiceCommandMode())
        now += 0.005
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office", handsFree: false)
        XCTAssertEqual(broker.session?.voiceCommandMode, true)
        let states = sends(effects).compactMap { effect -> SessionStateUpdate? in
            if case .send(_, .sessionState(let state)) = effect { return state }; return nil
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.voiceCommandMode == true })
    }

    func testHandsFreeDisconnectedMacCannotSupplyPendingCoPressEvidence() throws {
        let id = try waitingPress(.hotkeyToggle)
        XCTAssertEqual(nonLogs(msg(.hotkeyToggle, from: "laptop")), [])
        XCTAssertNil(broker.session)
        assertRecording(settle(id), handsFree: true)
    }

    func testHandsFreeDisconnectedClaimantCannotDelayImmediateStart() {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence, from: "office")
        broker.apply(.edgeDisconnected("office"))
        now = 100
        let effects = msg(.hotkeyToggle)
        assertNoTimer(effects)
        assertRecording(effects, handsFree: true)
    }

    func testHandsFreeDisconnectedFreshTargetFallsBackToNextEligiblePointerAtInsertion() {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        prepareTranscription()
        now = 101
        msg(.pointerPresence, from: "laptop")
        now = 102
        msg(.pointerPresence, from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        broker.apply(.edgeDisconnected("office"))
        assertInsertion(finishTranscription(), on: "laptop")
    }

    func testHandsFreeFreshestPointerUsesReceiptTimeRatherThanMessageOrder() {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now = 102
        msg(.pointerPresence, from: "office")
        now = 101
        msg(.pointerPresence, from: "laptop")
        XCTAssertEqual(broker.session?.target, "office")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHandsFreeVoiceCommandModeSurvivesImmediateCoPressResolution() throws {
        let id = try waitingPress(.hotkeyToggle)
        msg(.voiceCommandMode())
        now += 0.005
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "office", handsFree: true)
        XCTAssertEqual(broker.session?.voiceCommandMode, true)
        let states = sends(effects).compactMap { effect -> SessionStateUpdate? in
            if case .send(_, .sessionState(let state)) = effect { return state }; return nil
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.voiceCommandMode == true })
    }

    func testHoldCoPressDoesNotLetStaleUnpressedPointerRedirectInsertion() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 90
        msg(.pointerPresence, from: "laptop")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        now += 0.005
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, handsFree: false)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHoldPresserKeystrokeDoesNotRefreshItsStalePointerTimestamp() {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now += 0.005
        msg(.hotkeyDown, from: "office")
        now = 101
        msg(.focusClaim(appBundleId: "test.desk"))
        now = 102
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHoldKeystrokeDoesNotMakeOlderPointerBeatNewerPointer() {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyDown), handsFree: false)
        now = 101
        msg(.pointerPresence, from: "office")
        now = 102
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        now = 101.5
        msg(.pointerPresence, from: "laptop")
        XCTAssertEqual(broker.session?.target, "laptop")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "laptop")
    }

    func testHoldNoMicAlertGoesToSolePresserRatherThanUnpressedClaimant() throws {
        connect("desk", mic: false); connect("office", mic: false)
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        assertNoMic(settle(id), remoteMic: false)
    }

    func testHoldExplicitPreferenceOverridesBothCoPressersMicrophones() throws {
        connect("desk"); connect("office"); connect("laptop")
        broker.apply(.micOwnerChanged("laptop"))
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyDown))
        let effects = msg(.hotkeyDown, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "laptop", handsFree: false)
    }

    func testHoldSettleAfterCompletedStartAndCancelCannotResurrectSession() throws {
        let id = try waitingPress(.hotkeyDown)
        assertRecording(settle(id), handsFree: false)
        msg(.hotkeyCancel)
        XCTAssertNil(broker.session)
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertNil(broker.session)
    }

    func testHandsFreeCoPressDoesNotLetStaleUnpressedPointerRedirectInsertion() throws {
        connect("desk"); connect("office"); connect("laptop")
        now = 90
        msg(.pointerPresence, from: "laptop")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        now += 0.005
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, handsFree: true)
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "desk")
    }

    func testHandsFreePresserKeystrokeDoesNotRefreshItsStalePointerTimestamp() {
        connect("desk"); connect("office")
        now = 1
        msg(.pointerPresence)
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now += 0.005
        msg(.hotkeyToggle, from: "office")
        now = 101
        msg(.focusClaim(appBundleId: "test.desk"))
        now = 102
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        XCTAssertEqual(broker.session?.target, "office")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "office")
    }

    func testHandsFreeKeystrokeDoesNotMakeOlderPointerBeatNewerPointer() {
        connect("desk"); connect("office"); connect("laptop")
        now = 100
        assertRecording(msg(.hotkeyToggle), handsFree: true)
        now = 101
        msg(.pointerPresence, from: "office")
        now = 102
        msg(.focusClaim(appBundleId: "test.office"), from: "office")
        now = 101.5
        msg(.pointerPresence, from: "laptop")
        XCTAssertEqual(broker.session?.target, "laptop")
        prepareTranscription()
        assertInsertion(finishTranscription(), on: "laptop")
    }

    func testHandsFreeNoMicAlertGoesToSolePresserRatherThanUnpressedClaimant() throws {
        connect("desk", mic: false); connect("office", mic: false)
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        assertNoMic(settle(id), remoteMic: false)
    }

    func testHandsFreeExplicitPreferenceOverridesBothCoPressersMicrophones() throws {
        connect("desk"); connect("office"); connect("laptop")
        broker.apply(.micOwnerChanged("laptop"))
        now = 1
        msg(.pointerPresence, from: "office")
        now = 100
        let id = try pendingID(msg(.hotkeyToggle))
        let effects = msg(.hotkeyToggle, from: "office")
        XCTAssertTrue(effects.contains(.cancelPressSettle(id)))
        assertRecording(effects, initiator: "office", mic: "laptop", handsFree: true)
    }

    func testHandsFreeSettleAfterCompletedStartAndCancelCannotResurrectSession() throws {
        let id = try waitingPress(.hotkeyToggle)
        assertRecording(settle(id), handsFree: true)
        msg(.hotkeyCancel)
        XCTAssertNil(broker.session)
        XCTAssertEqual(nonLogs(settle(id)), [])
        XCTAssertNil(broker.session)
    }
}
