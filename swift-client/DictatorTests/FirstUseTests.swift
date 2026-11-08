import XCTest
@testable import Dictator

/// First use: microphone recovery pacing, readiness wording,
/// plain-words status text, the dictation key choice and the development
/// screens' opt-in. Pure functions only — no microphone, hotkeys or
/// personal settings are touched.
final class FirstUseTests: XCTestCase {

    // MARK: Microphone recovery backoff

    func testRetryBackoffDoublesToItsCeilingThenStaysThere() {
        var backoff = RetryBackoff()
        let start = Date(timeIntervalSince1970: 0)
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            backoff.recordFailure(at: start)
            delays.append(backoff.currentDelay)
        }
        XCTAssertEqual(delays, [5, 10, 20, 40, 80, 160, 300, 300, 300])
    }

    func testRetryBackoffWaitsUntilTheNextAttemptAndResetsOnSuccess() {
        var backoff = RetryBackoff()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(backoff.shouldAttempt(at: start), "first attempt is immediate")
        backoff.recordFailure(at: start)
        backoff.recordFailure(at: start)
        XCTAssertFalse(backoff.shouldAttempt(at: start.addingTimeInterval(9)))
        XCTAssertTrue(backoff.shouldAttempt(at: start.addingTimeInterval(10)))
        backoff.reset()
        XCTAssertTrue(backoff.shouldAttempt(at: start))
        XCTAssertEqual(backoff.failures, 0)
    }

    /// ~19 hours of failures: at a fixed 5 s that would be ~13,700
    /// restarts; with the backoff it stays in the low hundreds.
    func testNineteenHoursOfFailuresStaysBounded() {
        var backoff = RetryBackoff()
        var now = Date(timeIntervalSince1970: 0)
        let end = now.addingTimeInterval(19 * 3_600)
        var attempts = 0
        while now < end {
            if backoff.shouldAttempt(at: now) {
                attempts += 1
                backoff.recordFailure(at: now)
            }
            now = now.addingTimeInterval(5) // the health tick
        }
        XCTAssertLessThan(attempts, 250)
    }

    func testMicrophoneProblemTextNeverShowsARawCoreAudioError() {
        let raw = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
        let text = EdgeRuntime.microphoneProblemText(for: raw)
        XCTAssertFalse(text.contains("-10868"))
        XCTAssertFalse(text.contains("avfaudio"))
        XCTAssertEqual(
            EdgeRuntime.microphoneProblemText(for: AudioCaptureError.noInputDevice),
            AudioCaptureError.noInputDevice.errorDescription
        )
    }

    func testReplacingTheEngineCountsAndKeepsTheServiceUsable() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstUseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AudioCaptureService(checkpointStore: RecordingCheckpointStore(directory: directory))
        service.replaceEngine()
        service.replaceEngine()
        XCTAssertEqual(service.engineReplacementCount, 2)
    }

    // MARK: Readiness in General

    func testConnectedMacWithoutASnapshotIsNotCalledReady() {
        let status = DictationReadiness.evaluate(
            snapshot: nil, coreRole: .edge, serverURL: "", blockingProblem: nil, localRecordingProblem: nil
        )
        XCTAssertFalse(status.ready)
    }

    func testConfiguredAddressWithoutHealthEvidenceIsNotReady() {
        let status = DictationReadiness.evaluate(
            snapshot: nil, coreRole: .standalone, serverURL: "http://100.64.0.1:7878",
            blockingProblem: nil, localRecordingProblem: nil
        )
        XCTAssertFalse(status.ready)
        XCTAssertTrue(status.text.contains("Checking"))
    }

    func testInstalledLocalSpeechCanBeReadyWithoutAServer() {
        var machine = SetupSnapshot.Machine(id: "local", name: "This Mac", profile: nil, hasMic: true,
                                            online: true, lastSeen: Date(), isCore: true, localModels: nil,
                                            speechModels: ["whisperkit:test"])
        func readiness(_ sources: [SetupRouting.SpeechSource]) -> DictationReadiness {
            DictationReadiness.evaluate(snapshot: nil, coreRole: .standalone, serverURL: "",
                                       blockingProblem: nil, localRecordingProblem: nil,
                                       speechSources: sources, machines: [machine])
        }
        let local = SetupRouting.SpeechSource.mac("local", model: "whisperkit:test")
        XCTAssertTrue(readiness([local]).ready)
        let fallback = readiness([.server("http://100.64.0.1:7878"), local])
        XCTAssertTrue(fallback.ready)
        XCTAssertTrue(fallback.text.contains("backup"))
        machine.online = false
        XCTAssertFalse(readiness([local]).ready)
        machine.online = true
        machine.speechModels = []
        XCTAssertFalse(readiness([local]).ready)
    }

    func testLocalRecordingProblemOverridesReadyAndMentionsOtherMacs() {
        let status = DictationReadiness.evaluate(
            snapshot: nil, coreRole: .core, serverURL: "http://100.1.2.3:7878",
            blockingProblem: nil, localRecordingProblem: "The microphone stopped."
        )
        XCTAssertFalse(status.ready)
        XCTAssertTrue(status.text.contains("This Mac can’t record"))
        XCTAssertTrue(status.text.contains("another of your Macs"))

        let alone = DictationReadiness.evaluate(
            snapshot: nil, coreRole: .standalone, serverURL: "http://100.1.2.3:7878",
            blockingProblem: nil, localRecordingProblem: "The microphone stopped."
        )
        XCTAssertFalse(alone.text.contains("another of your Macs"), "a Mac on its own has no other Mac to use")
    }

    func testMissingPermissionsOverrideAnInstalledSpeechModel() {
        let machine = SetupSnapshot.Machine(id: "local", name: "This Mac", profile: nil, hasMic: true,
                                            online: true, lastSeen: Date(), isCore: true, localModels: nil,
                                            speechModels: ["whisperkit:test"])
        let status = DictationReadiness.evaluate(
            snapshot: nil, coreRole: .standalone, serverURL: "", blockingProblem: nil, localRecordingProblem: nil,
            speechSources: [.mac("local", model: "whisperkit:test")], machines: [machine],
            permissions: WelcomePermissions(microphone: true, inputMonitoring: false, accessibility: false)
        )
        XCTAssertFalse(status.ready)
        XCTAssertTrue(status.text.contains("Input Monitoring"))
        XCTAssertTrue(status.text.contains("Accessibility"))
    }

    func testMissingPermissionIsNotReady() {
        let status = DictationReadiness.evaluate(
            snapshot: nil, coreRole: .standalone, serverURL: "http://100.1.2.3:7878",
            blockingProblem: "Input Monitoring not granted", localRecordingProblem: nil
        )
        XCTAssertFalse(status.ready)
    }

    // MARK: Plain words

    func testSyncStatusNeverUsesRoleNamesOrRawErrors() {
        let raw = "The operation couldn’t be completed. (NSURLErrorDomain error -1001.) timed out"
        let statuses: [HistorySyncEngine.Status] = [.standalone, .offline, .syncing, .synced, .failed(raw), .failed("HTTP 401")]
        for role in [CoreRole.standalone, .core, .edge] {
            for status in statuses {
                let text = DictatorViewModel.syncStatusText(status: status, role: role, pending: 2, lastSyncAt: nil)
                for term in ["Core", "Edge", "Standalone", "NSURLErrorDomain", "-1001", "401"] {
                    XCTAssertFalse(text.contains(term), "“\(text)” contains \(term)")
                }
            }
        }
        XCTAssertTrue(DictatorViewModel.syncProblemText("HTTP 401 unauthorized").contains("invitation"))
    }

    func testEmptyHistoryHintNamesTheChosenKeyAndOnlyMentionsTypingWhenOn() {
        let command = DictationKey(keyCode: 54)
        let off = HistoryView.emptyHistoryHint(key: KeyCombo(command), typedHistoryOn: false)
        XCTAssertTrue(off.contains("Right ⌘"))
        XCTAssertFalse(off.localizedCaseInsensitiveContains("type"))
        XCTAssertFalse(off.contains("Right ⌥"))
        let on = HistoryView.emptyHistoryHint(key: KeyCombo(.rightOption), typedHistoryOn: true)
        XCTAssertTrue(on.contains("Right ⌥"))
        XCTAssertTrue(on.contains("apps you chose"))
    }

    // MARK: Dictation key

    func testCharacterChordsStillWorkWithAnotherKey() {
        let command = DictationKey(keyCode: 54)
        XCTAssertTrue(DictationChord.isCharacterChord(
            dictationHeld: true, secondsSincePress: 0.2, pressedKeyCode: 0, trigger: KeyCombo(command), isSynthetic: false
        ))
        XCTAssertFalse(DictationChord.isCharacterChord(
            dictationHeld: true, secondsSincePress: 0.2, pressedKeyCode: 54, trigger: KeyCombo(command), isSynthetic: false
        ))
    }
}
