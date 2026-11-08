import XCTest
@testable import Dictator

final class EdgeProtocolTests: XCTestCase {
    private let caps = EdgeCapabilities(
        hasMic: true, inputDeviceUID: "uid-1", accessibility: true, inputMonitoring: false, hotkeyMode: "intercept"
    )

    private func roundTrip(_ message: EdgeMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try EdgeProtocolCodec.encode(message, id: "fixed-id")
        let decoded = try EdgeProtocolCodec.decodeEdgeMessage(data)
        XCTAssertEqual(decoded, message, file: file, line: line)
        XCTAssertEqual(EdgeProtocolCodec.messageType(of: data), message.type, file: file, line: line)
    }

    private func roundTrip(_ message: CoreMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try EdgeProtocolCodec.encode(message, id: "fixed-id")
        let decoded = try EdgeProtocolCodec.decodeCoreMessage(data)
        XCTAssertEqual(decoded, message, file: file, line: line)
        XCTAssertEqual(EdgeProtocolCodec.messageType(of: data), message.type, file: file, line: line)
    }

    func testCredentialRotationMessagesRoundTripWithoutChangingProtocolVersion() throws {
        XCTAssertEqual(EdgeProtocol.version, 2)
        try roundTrip(CoreMessage.pairingTokenRotated(rotationId: "rotation-1", token: "synthetic"))
        try roundTrip(EdgeMessage.pairingTokenSaved(rotationId: "rotation-1"))
        let acknowledgement = try EdgeProtocolCodec.encode(EdgeMessage.pairingTokenSaved(rotationId: "rotation-1"))
        XCTAssertFalse(String(decoding: acknowledgement, as: UTF8.self).contains("synthetic"))
    }

    func testRecordingLimitFieldIsOptionalAndRoundTrips() throws {
        let legacy = Data(#"{"sessionId":"s","state":"processing","initiator":"mac"}"#.utf8)
        var update = try JSONDecoder().decode(SessionStateUpdate.self, from: legacy)
        XCTAssertNil(update.recordingLimitReached)
        update.recordingLimitReached = true
        XCTAssertEqual(try JSONDecoder().decode(SessionStateUpdate.self, from: JSONEncoder().encode(update)), update)
        XCTAssertEqual(EdgeProtocol.version, 2)
    }

    func testEveryEdgeMessageRoundTrips() throws {
        try roundTrip(.hello(edgeId: "e1", name: "MacBook", token: "abc", caps: caps))
        try roundTrip(.capabilities(caps))
        try roundTrip(.ping)
        try roundTrip(.hotkeyDown)
        try roundTrip(.hotkeyUp(reason: .modifierWatchdog))
        try roundTrip(.hotkeyToggle)
        try roundTrip(.hotkeyCancel)
        try roundTrip(.pressAbandoned)
        try roundTrip(.focusClaim(appBundleId: "com.apple.Notes"))
        try roundTrip(.focusClaim(appBundleId: nil))
        try roundTrip(.pointerPresence)
        try roundTrip(EdgeMessage.level(rms: 0.25))
        try roundTrip(.audioTake(AudioTakeHeader(sessionId: "s1", sampleRate: 16000, frameCount: 32000, durationSeconds: 2, byteCount: 128_000)))
        try roundTrip(.captureFailed(sessionId: "s1", message: "Another recording is using the microphone."))
        try roundTrip(.insertResult(
            sessionId: "s1",
            outcome: .clipboardOnly(reason: "No editable field", needsAccessibility: true),
            destination: InsertDestination(bundleId: "com.apple.Notes", appName: "Notes", url: nil, insertionMethod: "paste")
        ))
        try roundTrip(.insertResult(sessionId: "s1", outcome: .pasted, destination: nil))
        try roundTrip(.repoRequest(id: "r1", request: .historyPage(limit: 200, before: nil)))
        try roundTrip(.repoRequest(id: "r2", request: .historyPage(
            limit: 50, before: HistoryCursor(timestamp: Date(timeIntervalSince1970: 1_700_000_000), id: UUID())
        )))
        try roundTrip(.repoRequest(id: "r3", request: .historyDelete(ids: [UUID(), UUID()])))
        try roundTrip(.repoRequest(id: "r4", request: .historyStats))
        try roundTrip(.repoRequest(id: "r5", request: .historyUpsert([DictationEntryDTO(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), text: "hello world",
            durationSeconds: 2.5, inferenceMs: 120, wordCount: 2, modality: "voice", source: "dictator",
            destinationAppBundleId: "com.apple.Notes", destinationAppName: "Notes", destinationURL: nil,
            insertionMethod: "paste", originEdgeId: "edge-1", syncedAt: nil
        )])))
        try roundTrip(.repoRequest(id: "r5b", request: .historyManifest(limit: 2_000, before: nil)))
        try roundTrip(.repoRequest(id: "r5c", request: .historyManifest(
            limit: 100, before: HistoryCursor(timestamp: Date(timeIntervalSince1970: 1_700_000_000), id: UUID())
        )))
        try roundTrip(.repoRequest(id: "r5d", request: .historyFetch(ids: [UUID(), UUID()])))
        try roundTrip(.repoRequest(id: "r6", request: .dictionaryPage(limit: 200, afterPattern: nil)))
        try roundTrip(.repoRequest(id: "r6b", request: .dictionaryPage(limit: 50, afterPattern: "teh")))
        try roundTrip(.repoRequest(id: "r7", request: .dictionaryUpsert([
            DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false)
        ])))
        try roundTrip(.repoRequest(id: "r8", request: .dictionaryDelete(ids: [UUID()])))
        try roundTrip(.repoRequest(id: "r9", request: .settingsGet))
        try roundTrip(.repoRequest(id: "r10", request: .settingsSet(CoreSettingsPatch(
            refineLevel: "strong", customSystemPrompt: nil, persistHistory: true
        ))))
        try roundTrip(.repoRequest(id: "r11", request: .settingsSet(CoreSettingsPatch(
            surfacePolicyJSON: "{\"default_typed\":\"ignore\",\"default_voice\":\"save\",\"rules\":[]}"
        ))))
        try roundTrip(.sessionOutcomeQuery(sessionIds: ["s1", "s2"]))
        try roundTrip(.sessionOutcomeQuery(sessionIds: []))
    }

    func testEveryCoreMessageRoundTrips() throws {
        try roundTrip(.welcome(coreId: "core-1", micOwner: "e1", protocolVersion: EdgeProtocol.version))
        try roundTrip(.welcome(coreId: "core-1", micOwner: nil, protocolVersion: EdgeProtocol.version))
        try roundTrip(.config(handsFree: true))
        try roundTrip(.pong)
        try roundTrip(.captureStart(sessionId: "s1"))
        try roundTrip(.captureStop(sessionId: "s1"))
        try roundTrip(.captureCancel(sessionId: "s1"))
        try roundTrip(.insert(sessionId: "s1", text: "hello / world"))
        try roundTrip(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .idle, initiator: "e1", micOwner: "e2", target: "e1", outcome: .cancelled(.micLost)
        )))
        try roundTrip(.sessionState(SessionStateUpdate(
            sessionId: "s1", state: .recording, initiator: "e1", micOwner: nil, target: nil, outcome: nil
        )))
        try roundTrip(CoreMessage.level(rms: 0.9))
        try roundTrip(.sessionCountdown(sessionId: "s1", secondsLeft: 10))
        try roundTrip(.error(code: "auth", message: "bad token"))
        try roundTrip(.repoResponse(requestId: "r1", result: .historyPage([
            DictationEntryDTO(
                id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), text: "hello world",
                durationSeconds: 2.5, inferenceMs: 120, wordCount: 2, modality: "voice", source: "dictator",
                destinationAppBundleId: "com.apple.Notes", destinationAppName: "Notes", destinationURL: nil,
                insertionMethod: "paste"
            )
        ])))
        try roundTrip(.repoResponse(requestId: "r2", result: .historyStats(
            DictationStatsDTO(totalWords: 120, totalDictations: 8, totalAudioSeconds: 60)
        )))
        try roundTrip(.repoResponse(requestId: "r3", result: .historyStats(nil)))
        try roundTrip(.repoResponse(requestId: "r3b", result: .historyManifest([
            HistoryManifestItem(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            HistoryManifestItem(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_001)),
        ])))
        try roundTrip(.repoResponse(requestId: "r4", result: .dictionaryPage([
            DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false)
        ])))
        try roundTrip(.repoResponse(requestId: "r5", result: .settings(
            CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true, surfacePolicyJSON: "{}")
        )))
        try roundTrip(.repoResponse(requestId: "r6", result: .ok))
        try roundTrip(.repoResponse(requestId: "r7", result: .error("boom")))
        try roundTrip(.repoChanged(.history))
        try roundTrip(.repoChanged(.dictionary))
        try roundTrip(.repoChanged(.settings))
        try roundTrip(.sessionOutcomes(["s1": .pasted, "s2": .cancelled(.user), "s3": .failed(message: "boom")]))
        try roundTrip(.sessionOutcomes([:]))
    }

    /// A full `RepoRequestLimits.historyPageSize`-entry page with realistic
    /// 300-char texts must still fit under `EdgeProtocol.maxTextFrameBytes` —
    /// the limit `EdgeProtocolCodec.encode` enforces on every frame.
    func testSetupMessagesRoundTrip() throws {
        let profile = MachineProfile(productName: "Mac Studio (2023)", memoryGB: 96, tailscaleIP: "100.64.0.3")
        var withMachine = caps
        withMachine.machine = profile
        withMachine.localModels = ["gemma3:4b"]
        try roundTrip(.capabilities(withMachine))
        try roundTrip(EdgeMessage.cleanupResult(requestId: "r1", output: "Hello.", error: nil))
        try roundTrip(EdgeMessage.cleanupResult(requestId: "r2", output: nil, error: "Ollama isn’t running on this Mac."))
        try roundTrip(.modelPullProgress(requestId: "p1", progress: ModelPullProgress(status: "pulling", completed: 10, total: 100, done: false)))
        let snapshot = SetupSnapshot(
            coreId: "core",
            machines: [SetupSnapshot.Machine(id: "core", name: "Mac mini", profile: profile, hasMic: false, online: true,
                                             lastSeen: Date(timeIntervalSince1970: 1_000), isCore: true, localModels: nil)],
            speech: SetupSnapshot.SpeechService(address: "http://100.64.0.1:7878", machineId: "core", reachable: true,
                                                speechModel: "whisper-small", cleanupModel: "gemma4:e2b-it-qat",
                                                cleanupMachineId: "core", checkedAt: Date(timeIntervalSince1970: 1_000)),
            cleanupOn: true, generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try roundTrip(CoreMessage.setup(snapshot))
        try roundTrip(CoreMessage.cleanupRequest(requestId: "r1", job: CleanupJob(model: "gemma3:4b", messages: [ChatMessage(role: "user", content: "hi")], options: ["temperature": 0])))
        try roundTrip(CoreMessage.modelPull(requestId: "p1", model: "gemma3:4b"))
        try roundTrip(EdgeMessage.pairRequest(edgeId: "e9", name: "iMac", caps: caps))
        try roundTrip(CoreMessage.pairCode(code: "482913", coreName: "Mac mini"))
        try roundTrip(CoreMessage.pairApproved(token: "t"))
        try roundTrip(CoreMessage.pairDenied(reason: "no"))
        try roundTrip(CoreMessage.speechRequest(SpeechJob(requestId: "s1", model: "whisperkit:openai_whisper-small", languages: ["en", "he"],
                                                          vocabulary: ["Dictator"], sampleRate: 16000, byteCount: 64)))
        try roundTrip(EdgeMessage.speechResult(requestId: "s1", text: "Hello.", error: nil))
        var withSpeech = caps
        withSpeech.speechModels = ["apple:he-IL"]
        withSpeech.appleSpeech = true
        try roundTrip(.capabilities(withSpeech))
    }

    /// A Mac on an older build doesn't send the machine fields at all.
    func testCapabilitiesWithoutMachineFieldsStillDecode() throws {
        let json = #"{"v":2,"t":"caps","id":"x","caps":{"hasMic":true,"inputDeviceUID":"","accessibility":true,"inputMonitoring":true,"hotkeyMode":"intercept"}}"#
        guard case .capabilities(let decoded) = try EdgeProtocolCodec.decodeEdgeMessage(Data(json.utf8)) else {
            return XCTFail("expected caps")
        }
        XCTAssertNil(decoded.machine)
        XCTAssertNil(decoded.localModels)
    }

    func testFullHistoryPageFitsUnderMaxTextFrameBytes() throws {
        let longText = String(repeating: "a", count: 300)
        let entries = (0..<RepoRequestLimits.historyPageSize).map { _ in
            DictationEntryDTO(
                id: UUID(), timestamp: Date(), text: longText, durationSeconds: 12.3, inferenceMs: 250,
                wordCount: 1, modality: "voice", source: "dictator",
                destinationAppBundleId: "com.apple.Notes", destinationAppName: "Notes",
                destinationURL: "https://example.com/very/long/path/for/realism", insertionMethod: "paste"
            )
        }
        let message = CoreMessage.repoResponse(requestId: "r1", result: .historyPage(entries))
        let data = try EdgeProtocolCodec.encode(message)
        XCTAssertLessThan(data.count, EdgeProtocol.maxTextFrameBytes)
    }

    /// A full manifest page is tiny per row but many rows — it must still
    /// fit one text frame with room to spare.
    func testFullManifestPageFitsUnderMaxTextFrameBytes() throws {
        let items = (0..<RepoRequestLimits.manifestPageSize).map { _ in
            HistoryManifestItem(id: UUID(), timestamp: Date())
        }
        let message = CoreMessage.repoResponse(requestId: "r1", result: .historyManifest(items))
        let data = try EdgeProtocolCodec.encode(message)
        XCTAssertLessThan(data.count, EdgeProtocol.maxTextFrameBytes)
    }

    func testDeletionManifestFieldIsOptionalAndOlderReadersIgnoreIt() throws {
        struct OlderItem: Codable { var id: UUID; var timestamp: Date }
        let old = OlderItem(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let decodedOld = try JSONDecoder().decode(HistoryManifestItem.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decodedOld.deletedAt)
        let deletion = HistoryManifestItem(id: old.id, timestamp: old.timestamp, deletedAt: old.timestamp)
        let data = try JSONEncoder().encode(deletion)
        let decodedLegacy = try JSONDecoder().decode(OlderItem.self, from: data)
        XCTAssertEqual(decodedLegacy.id, old.id)
        XCTAssertEqual(try JSONDecoder().decode(HistoryManifestItem.self, from: data), deletion)
    }

    func testEnvelopeIsFlatWithVersionTypeAndId() throws {
        let data = try EdgeProtocolCodec.encode(EdgeMessage.hotkeyUp(reason: .key), id: "id-7")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, EdgeProtocol.version)
        XCTAssertEqual(object["t"] as? String, "hotkey.up")
        XCTAssertEqual(object["id"] as? String, "id-7")
        XCTAssertEqual(object["reason"] as? String, "key")
        XCTAssertEqual(object.count, 4)
    }

    func testOutcomeEncodesFlatKind() throws {
        let data = try JSONEncoder().encode(SessionOutcome.failed(message: "boom"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "failed")
        XCTAssertEqual(object["message"] as? String, "boom")
    }

    func testRejectsWrongVersionUnknownTypeAndGarbage() {
        let wrongVersion = Data(#"{"v":99,"t":"ping","id":"x"}"#.utf8)
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeEdgeMessage(wrongVersion)) { error in
            XCTAssertEqual(error as? EdgeProtocolError, .unsupportedVersion(99))
        }
        // A peer still on the previous protocol is refused too.
        let previousVersion = Data(#"{"v":1,"t":"ping","id":"x"}"#.utf8)
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeEdgeMessage(previousVersion)) { error in
            XCTAssertEqual(error as? EdgeProtocolError, .unsupportedVersion(1))
        }
        let unknown = Data("{\"v\":\(EdgeProtocol.version),\"t\":\"teleport\",\"id\":\"x\"}".utf8)
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeCoreMessage(unknown)) { error in
            XCTAssertEqual(error as? EdgeProtocolError, .unknownType("teleport"))
        }
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeEdgeMessage(Data("not json".utf8)))
        XCTAssertNil(EdgeProtocolCodec.messageType(of: Data("{}".utf8)))
    }

    func testMissingPayloadFieldIsMalformed() {
        let noReason = Data("{\"v\":\(EdgeProtocol.version),\"t\":\"hotkey.up\",\"id\":\"x\"}".utf8)
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeEdgeMessage(noReason)) { error in
            guard case .malformed = error as? EdgeProtocolError else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testOversizedTextFrameIsRefusedOnBothSides() {
        let huge = String(repeating: "x", count: EdgeProtocol.maxTextFrameBytes + 1)
        XCTAssertThrowsError(try EdgeProtocolCodec.encode(CoreMessage.insert(sessionId: "s", text: huge)))
        var padded = Data(#"{"v":1,"t":"ping","id":"x","pad":""#.utf8)
        padded.append(Data(repeating: 0x61, count: EdgeProtocol.maxTextFrameBytes))
        padded.append(Data(#""}"#.utf8))
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeEdgeMessage(padded)) { error in
            guard case .frameTooLarge = error as? EdgeProtocolError else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }

    func testLimitsMatchPlan() {
        XCTAssertEqual(EdgeProtocol.corePort, 7880)
        XCTAssertEqual(EdgeProtocol.maxEdges, 8)
        XCTAssertEqual(EdgeProtocol.helloTimeout, 2)
        XCTAssertEqual(EdgeProtocol.maxBinaryFrameBytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(EdgeProtocol.maxSessionDuration, 120)
    }

    func testSessionCountdownIsANewOptionalMessage() throws {
        XCTAssertEqual(EdgeProtocol.version, 2) // no bump
        let data = try EdgeProtocolCodec.encode(CoreMessage.sessionCountdown(sessionId: "s1", secondsLeft: 3))
        XCTAssertEqual(EdgeProtocolCodec.messageType(of: data), "session.countdown")
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(data), .sessionCountdown(sessionId: "s1", secondsLeft: 3))
        // An older peer's decoder has no case for it and reports an unknown
        // type, which the connection layer ignores.
        let unknown = Data(#"{"v":2,"t":"session.countdown.future","id":1}"#.utf8)
        XCTAssertThrowsError(try EdgeProtocolCodec.decodeCoreMessage(unknown))
        // Sessions without it are unchanged.
        let state = CoreMessage.sessionState(SessionStateUpdate(sessionId: "s1", state: .recording, initiator: "e1", micOwner: "e1", target: "e1", outcome: nil))
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(try EdgeProtocolCodec.encode(state)), state)
    }

    func testWorkspaceMessagesRoundTrip() throws {
        let layout = WorkspaceSavedLayout(macName: "Mac mini", capturedAt: Date(timeIntervalSinceReferenceDate: 1000),
                                          screens: [WorkspaceDisplay(id: "1", name: "Studio Display", visibleFrame: WorkspaceRect(x: 0, y: 25, width: 2560, height: 1415), isMain: true)],
                                          windows: [WorkspaceSavedWindow(bundleID: "com.apple.Safari", appName: "Safari", screenID: "1", place: WorkspaceRect(x: 0, y: 0, width: 0.5, height: 1))])
        try roundTrip(EdgeMessage.workspaceRememberAll(requestId: "r"))
        try roundTrip(EdgeMessage.workspaceCaptureResult(requestId: "r", macID: "m", layout: layout, error: nil))
        try roundTrip(EdgeMessage.workspaceCaptureResult(requestId: "r", macID: "m", layout: nil, error: "no windows"))
        try roundTrip(EdgeMessage.workspaceRunAll(requestId: "r", routineID: "desk", undo: true))
        try roundTrip(EdgeMessage.workspaceRunAll(requestId: "r", routineID: "desk", undo: true, operationID: "op-1"))
        try roundTrip(EdgeMessage.workspaceRunResult(requestId: "r", summary: "done, 3 changes."))
        try roundTrip(CoreMessage.workspaceCapture(requestId: "r"))
        try roundTrip(CoreMessage.workspaceRemembered(requestId: "r", layouts: ["m": layout], unanswered: ["iMac"]))
        try roundTrip(CoreMessage.workspaceRemembered(requestId: "r", layouts: [:], unanswered: [], busy: ["Mac mini"]))
        try roundTrip(CoreMessage.workspaceRun(requestId: "r", routineID: "desk", undo: false, from: "MacBook Pro"))
        try roundTrip(CoreMessage.workspaceRun(requestId: "r", routineID: "desk", undo: true, from: "MacBook Pro", operationID: "op-1"))
        try roundTrip(CoreMessage.workspaceRunReport(requestId: "r", reports: [WorkspaceRunReport(macName: "Mac mini", summary: "done.")]))
    }
}


extension EdgeProtocolTests {
    func testWorkspaceCountsAreOptionalAndRoundTripWithoutAProtocolBump() throws {
        var counts = WorkspaceRunCounts(windowsMoved: 5, windowsBroughtBack: 2, appsOpened: 1)
        counts.record([.init(bundleID: "com.synthetic.app", reason: .otherSpace, count: 2)])
        try roundTrip(EdgeMessage.workspaceRunResult(requestId: "r", summary: "done", counts: counts))
        try roundTrip(CoreMessage.workspaceRunReport(requestId: "r", reports: [.init(macName: "Synthetic Mac", summary: "done", counts: counts)]))
        let old = Data(#"{"v":2,"t":"workspace.run.result","id":"x","requestId":"r","summary":"done"}"#.utf8)
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(old), .workspaceRunResult(requestId: "r", summary: "done"))
        let oldReport = Data(#"{"macName":"Synthetic Mac","summary":"done"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceRunReport.self, from: oldReport).counts)
        XCTAssertEqual(EdgeProtocol.version, 2)
    }

    func testWorkspaceFailureFieldIsOptionalAndRoundTrips() throws {
        try roundTrip(EdgeMessage.workspaceRunResult(requestId: "test", summary: "Stopped", failure: "Synthetic failure"))
        let old = Data(#"{"macName":"Test Mac","summary":"done"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceRunReport.self, from: old).failure)
        let report = WorkspaceRunReport(macName: "Test Mac", summary: "Stopped", failure: "Synthetic failure")
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceRunReport.self, from: JSONEncoder().encode(report)), report)
    }
}
