import XCTest
@testable import Dictator

/// Covers `RecoveryService`'s list/transcribe/discard behavior against a
/// temp-directory `RecordingCheckpointStore` and a fake transcription
/// closure — no real server, no real clipboard-dependent UI.
@MainActor
final class RecoveryServiceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryServiceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> RecordingCheckpointStore {
        RecordingCheckpointStore(directory: tempDirectory)
    }

    private func addTake(_ store: RecordingCheckpointStore, id: String = "edge-s1", frameCount: Int = 1_600, amplitude: Float = 0.1) {
        let data = [Float](repeating: amplitude, count: frameCount).withUnsafeBufferPointer { Data(buffer: $0) }
        store.saveReceivedTake(takeId: id, sessionId: String(id.dropFirst(5)), sampleRate: 16_000, edgeName: "MacBook", data: data)
    }

    private func level(_ data: Data) -> Float {
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    /// A take saved 26 dB too quiet came back with no words from a speech
    /// engine that hears it fine at the level live dictation uses.
    func testAQuietRecordingReachesTheEngineAtLiveLevel() async throws {
        let store = makeStore()
        addTake(store, amplitude: 0.0007)
        var heard: Data?
        let service = RecoveryService(store: store,
            transcribe: { audio in heard = audio.data; return TranscriptionResult(text: "words", inferenceMs: 1) },
            saveEntry: { _, _, _, _ in })
        service.refresh()
        await service.transcribe(try XCTUnwrap(service.takes.first))
        XCTAssertGreaterThan(level(try XCTUnwrap(heard)), 0.03, "36 dB of gain, the same cap as live dictation")
    }

    func testARecordingAtLiveLevelIsLeftAlone() {
        let data = [Float](repeating: 0.1, count: 1_600).withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(level(AudioCaptureService.levelled(data, sampleRate: 16_000)), level(data), accuracy: 0.0001)
        XCTAssertEqual(AudioCaptureService.levelled(Data(), sampleRate: 16_000), Data())
        let digitalSilence = Data(count: 1_600 * 4)
        XCTAssertTrue(RecoveryService.isSilent(AudioCaptureService.levelled(digitalSilence, sampleRate: 16_000)))
    }

    func testRecoveredStagesKeepEngineWordsAndUseNilFallback() async throws {
        for raw: String? in ["engine words", nil] {
            let store = makeStore()
            addTake(store)
            var saved: (String, String)?
            let service = RecoveryService(store: store,
                transcribe: { _ in TranscriptionResult(text: "final words", inferenceMs: 1, rawText: raw) },
                saveEntry: { _, _, _, _ in XCTFail("stage-aware writer must be used") },
                saveEntryWithStages: { text, heard, _, _, _ in saved = (text, heard) })
            service.refresh()
            await service.transcribe(try XCTUnwrap(service.takes.first))
            XCTAssertEqual(saved?.0, "final words")
            XCTAssertEqual(saved?.1, raw ?? "final words")
        }
    }

    func testMissingSpeechKeyShowsAlertAndKeepsRecordingForRetry() async throws {
        let store = makeStore()
        addTake(store)
        let service = RecoveryService(
            store: store,
            transcribe: { _ in throw TranscriptionError.authenticationRequired },
            saveEntry: { _, _, _, _ in XCTFail("No text to save") }
        )
        service.refresh()
        let take = try XCTUnwrap(service.takes.first)
        let original = try Data(contentsOf: take.take.pcmURL)
        await service.transcribe(take)
        XCTAssertEqual(service.lastAlert?.action, .advanced)
        XCTAssertTrue(service.lastNotice?.contains("Settings › Advanced") == true)
        XCTAssertEqual(service.takes.count, 1)
        XCTAssertEqual(try Data(contentsOf: take.take.pcmURL), original)
        XCTAssertEqual(store.listTakes().first?.metadata.status, .failed)
    }

    func testWrappedSpeechConfigurationFailureSurvivesRecovery() async throws {
        let store = makeStore()
        addTake(store)
        let alert = try XCTUnwrap(DictationAlert.speechConfigurationFailure(SpeechEndpointError.unencrypted))
        let service = RecoveryService(
            store: store, transcribe: { _ in throw DictationFailure(alert) },
            saveEntry: { _, _, _, _ in XCTFail("No text to save") }
        )
        service.refresh()
        await service.transcribe(try XCTUnwrap(service.takes.first))
        XCTAssertEqual(service.lastAlert, alert)
        XCTAssertEqual(service.takes.count, 1)
    }

    func testMainMacKeyFailureSurvivesExistingStringReply() async throws {
        let store = makeStore()
        addTake(store)
        let alert = try XCTUnwrap(DictationAlert.speechConfigurationFailure(TranscriptionError.authenticationRequired))
        let service = RecoveryService(
            store: store, transcribe: { _ in throw RepositoryError.unavailable(alert.encoded) },
            saveEntry: { _, _, _, _ in XCTFail("No text to save") }
        )
        service.refresh()
        await service.transcribe(try XCTUnwrap(service.takes.first))
        XCTAssertEqual(service.lastAlert, alert)
        XCTAssertEqual(service.takes.count, 1)
    }

    func testRefreshListsTakesFromTheStore() {
        let store = makeStore()
        addTake(store)
        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })

        service.refresh()

        XCTAssertEqual(service.takes.map(\.id), ["edge-s1"])
    }

    func testDisplayedRemovalDateMatchesPruningBoundary() throws {
        let store = makeStore()
        addTake(store)
        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })
        service.refresh()
        let take = try XCTUnwrap(service.takes.first)
        store.pruneOlderThan(referenceDate: take.removalDate.addingTimeInterval(-1))
        XCTAssertEqual(store.listTakes().count, 1)
        store.pruneOlderThan(referenceDate: take.removalDate.addingTimeInterval(1))
        XCTAssertTrue(store.listTakes().isEmpty)
    }

    func testActiveTakeIdsExcludesTheCurrentSession() {
        let store = makeStore()
        addTake(store, id: "edge-s1")
        addTake(store, id: "edge-s2")
        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })

        service.activeTakeIds = ["edge-s1"]

        XCTAssertEqual(service.takes.map(\.id), ["edge-s2"])
    }

    func testDiscardRemovesTheTakeFromDiskAndFromTheList() {
        let store = makeStore()
        addTake(store)
        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        service.discard(take)

        XCTAssertTrue(service.takes.isEmpty)
        XCTAssertTrue(store.listTakes().isEmpty)
    }

    /// Discarding one recording removes only that recording; every
    /// other recording's audio stays on disk byte for byte.
    func testDiscardRemovesOnlyTheChosenRecording() throws {
        let store = makeStore()
        addTake(store, id: "edge-s1", amplitude: 0.1)
        addTake(store, id: "edge-s2", amplitude: 0.2)
        let keptPCM = tempDirectory.appendingPathComponent("edge-s2.pcm")
        let keptBefore = try Data(contentsOf: keptPCM)
        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })
        service.refresh()
        let doomed = try XCTUnwrap(service.takes.first { $0.id == "edge-s1" })

        service.discard(doomed)

        XCTAssertEqual(service.takes.map(\.id), ["edge-s2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-s1.pcm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-s1.json").path))
        XCTAssertEqual(try Data(contentsOf: keptPCM), keptBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-s2.json").path))
    }

    func testTranscribeSavesToHistoryAndDeletesTheCheckpointOnSuccess() async {
        let store = makeStore()
        addTake(store)
        var savedText: String?
        var savedSource: String?
        let service = RecoveryService(
            store: store,
            transcribe: { _ in TranscriptionResult(text: "recovered words", inferenceMs: 12) },
            saveEntry: { text, _, _, source in
                savedText = text
                savedSource = source
            }
        )
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        await service.transcribe(take)

        XCTAssertEqual(savedText, "recovered words")
        XCTAssertEqual(savedSource, "recovered")
        XCTAssertTrue(store.listTakes().isEmpty)
        XCTAssertNotNil(service.lastNotice)
    }

    func testTranscribeWithEmptyResultOnSilentAudioDiscardsWithoutSavingHistory() async {
        let store = makeStore()
        addTake(store, amplitude: 0)
        var saveCalls = 0
        let service = RecoveryService(
            store: store,
            transcribe: { _ in TranscriptionResult(text: "   ", inferenceMs: nil) },
            saveEntry: { _, _, _, _ in saveCalls += 1 }
        )
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        await service.transcribe(take)

        XCTAssertEqual(saveCalls, 0)
        XCTAssertTrue(store.listTakes().isEmpty)
    }

    func testEmptyResultOnAudibleRecordingKeepsTheCheckpoint() async {
        let store = makeStore()
        addTake(store)
        var saveCalls = 0
        let service = RecoveryService(
            store: store,
            transcribe: { _ in TranscriptionResult(text: "", inferenceMs: nil) },
            saveEntry: { _, _, _, _ in saveCalls += 1 }
        )
        service.refresh()
        await service.transcribe(try! XCTUnwrap(service.takes.first))
        XCTAssertEqual(saveCalls, 0)
        XCTAssertEqual(store.listTakes().count, 1, "a recording with sound must never be deleted on an empty result")
    }

    func testOneEmptyAudibleChunkKeepsTheWholeCheckpointAndSavesNothing() async {
        let store = makeStore()
        addTake(store, frameCount: 16_000 * 130) // over the 110 s chunking threshold
        var saveCalls = 0
        var calls = 0
        let service = RecoveryService(
            store: store,
            transcribe: { _ in
                calls += 1
                return TranscriptionResult(text: calls == 1 ? "first half" : "", inferenceMs: nil)
            },
            saveEntry: { _, _, _, _ in saveCalls += 1 }
        )
        service.refresh()
        await service.transcribe(try! XCTUnwrap(service.takes.first))
        XCTAssertGreaterThanOrEqual(calls, 2)
        XCTAssertEqual(saveCalls, 0, "incomplete text must not be saved")
        XCTAssertEqual(store.listTakes().count, 1)
        XCTAssertNotNil(service.lastNotice)
    }

    func testTranscribeFailureKeepsTheCheckpointOnDisk() async {
        let store = makeStore()
        addTake(store)
        let service = RecoveryService(
            store: store,
            transcribe: { _ in throw TranscriptionError.serverError(500, "boom") },
            saveEntry: { _, _, _, _ in }
        )
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        await service.transcribe(take)

        XCTAssertEqual(store.listTakes().count, 1)
        XCTAssertNotNil(service.lastNotice)
    }

    func testDiscardOnMissingAudioFileIsSafe() {
        let store = makeStore()
        // Metadata with no matching .pcm file on disk (simulates a partially
        // cleaned-up take).
        addTake(store)
        store.delete("edge-s1")
        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })

        service.refresh()

        XCTAssertTrue(service.takes.isEmpty)
    }

    // MARK: - Chunking (also floors partial-frame data)

    func testTranscribeChunksALongRecordingAndIssuesMultipleRequests() async {
        let store = makeStore()
        let totalSeconds = 130.0
        let frameCount = Int(totalSeconds * 16_000)
        let data = [Float](repeating: 0.1, count: frameCount).withUnsafeBufferPointer { Data(buffer: $0) }
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "MacBook", data: data)
        var callCount = 0
        let service = RecoveryService(
            store: store,
            transcribe: { _ in
                callCount += 1
                return TranscriptionResult(text: "piece", inferenceMs: 5)
            },
            saveEntry: { _, _, _, _ in }
        )
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        await service.transcribe(take)

        XCTAssertEqual(callCount, 2, "a >110s recovered take must be chunked, not sent whole (permanent 413 otherwise)")
        XCTAssertTrue(store.listTakes().isEmpty)
    }

    func testTranscribeFloorsAPartialTrailingFrameBeforeSending() async {
        let store = makeStore()
        // 10 whole float32 frames (40 bytes) plus 2 stray bytes — simulates
        // a write that failed mid-flush.
        var data = [Float](repeating: 0.1, count: 10).withUnsafeBufferPointer { Data(buffer: $0) }
        data.append(contentsOf: [0xAB, 0xCD])
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "MacBook", data: data)
        var receivedByteCount: Int?
        let service = RecoveryService(
            store: store,
            transcribe: { audio in
                receivedByteCount = audio.data.count
                return TranscriptionResult(text: "ok", inferenceMs: nil)
            },
            saveEntry: { _, _, _, _ in }
        )
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        await service.transcribe(take)

        XCTAssertEqual(receivedByteCount, 40, "the trailing partial frame must be floored off before sending")
    }

    // MARK: - Idempotency + history-coupled deletion

    func testConcurrentTranscribeCallsForTheSameTakeIssueOnlyOneRequest() async {
        let store = makeStore()
        addTake(store)
        var callCount = 0
        let service = RecoveryService(
            store: store,
            transcribe: { _ in
                callCount += 1
                try? await Task.sleep(for: .milliseconds(50))
                return TranscriptionResult(text: "words", inferenceMs: nil)
            },
            saveEntry: { _, _, _, _ in }
        )
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        async let first: Void = service.transcribe(take)
        try? await Task.sleep(for: .milliseconds(5)) // let the first call mark itself busy first
        async let second: Void = service.transcribe(take)
        _ = await (first, second)

        XCTAssertEqual(callCount, 1, "a take already busy must reject the second concurrent call")
    }

    func testTranscribeWithFailingHistorySaveKeepsTheCheckpointMarkedFailed() async {
        struct SaveError: Error, LocalizedError {
            var errorDescription: String? { "history store unavailable" }
        }
        let store = makeStore()
        addTake(store)
        let service = RecoveryService(
            store: store,
            transcribe: { _ in TranscriptionResult(text: "words", inferenceMs: nil) },
            saveEntry: { _, _, _, _ in throw SaveError() }
        )
        service.refresh()
        let take = try! XCTUnwrap(service.takes.first)

        await service.transcribe(take)

        // The text is still on the clipboard, but the required history
        // entry never landed — this must stay on disk and retryable, not
        // be thrown away.
        let remaining = store.listTakes()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.metadata.status, .failed)
        XCTAssertNotNil(service.lastNotice)
    }

    // MARK: - A still-being-written `.recording` checkpoint stays hidden

    func testRefreshHidesARecentlyTouchedRecordingCheckpointButShowsAnOldOne() {
        let store = makeStore()
        // Still open (status `.recording`), sidecar touched moments ago —
        // a writer may still be mid-`finish()` on the checkpoint queue.
        addTake(store, id: "edge-s1")
        store.markStatus("edge-s1", status: .recording)

        // A genuine crash leftover: also `.recording`, but untouched for a
        // while — nothing is still writing it.
        addTake(store, id: "edge-s2")
        store.markStatus("edge-s2", status: .recording)
        let oldDate = Date(timeIntervalSinceNow: -60)
        try? FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: tempDirectory.appendingPathComponent("edge-s2.json").path
        )

        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })
        service.refresh()

        XCTAssertEqual(service.takes.map(\.id), ["edge-s2"])
    }

    func testPruneAndRefreshOnLaunchRemovesOldTakesAndPopulatesList() {
        let store = makeStore()
        addTake(store, id: "edge-old")
        // Backdate it past the 14-day cutoff directly (the store always
        // stamps `startedAt = Date()` on save).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let old = CheckpointMetadata(
            takeId: "edge-old", sessionId: "old", sampleRate: 16_000,
            startedAt: Date(timeIntervalSinceNow: -20 * 86_400), edgeName: "MacBook", status: .uploaded
        )
        try? encoder.encode(old).write(to: tempDirectory.appendingPathComponent("edge-old.json"))
        addTake(store, id: "edge-recent")

        let service = RecoveryService(store: store, saveEntry: { _, _, _, _ in })
        service.pruneAndRefreshOnLaunch()

        XCTAssertEqual(service.takes.map(\.id), ["edge-recent"])
    }
}
