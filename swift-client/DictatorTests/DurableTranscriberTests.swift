import XCTest
@testable import Dictator

/// Covers `DurableTranscriber`'s retry policy, checkpoint persistence, and
/// chunking — the Core side of recording checkpoints.
/// The injected `sleep` is a no-op so these tests never actually wait out
/// the real 1s/3s/6s backoff.
final class DurableTranscriberTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableTranscriberTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> RecordingCheckpointStore {
        RecordingCheckpointStore(directory: tempDirectory)
    }

    private func header(durationSeconds: Double = 1, frameCount: Int = 16_000) -> AudioTakeHeader {
        AudioTakeHeader(sessionId: "s1", sampleRate: 16_000, frameCount: frameCount, durationSeconds: durationSeconds, byteCount: frameCount * 4)
    }

    private func silentData(frameCount: Int) -> Data {
        [Float](repeating: 0, count: frameCount).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Persistence happens before transcription

    func testPersistReceivedTakeWritesBeforeTranscribeIsEverCalled() {
        let store = makeStore()
        let transcriber = DurableTranscriber(store: store, transcribe: { _, _ in ("hi", nil) }, sleep: { _ in })
        let data = silentData(frameCount: 100)

        transcriber.persistReceivedTake(sessionId: "s1", header: header(frameCount: 100), data: data, edgeName: "mini")

        let take = store.listTakes().first
        XCTAssertEqual(take?.id, "core-s1")
        XCTAssertEqual(take?.metadata.status, .received)
    }

    // MARK: - Retry policy

    func testRetriesTransientFailureAndEventuallySucceeds() async throws {
        let store = makeStore()
        var attempts = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                if attempts < 3 { throw URLError(.networkConnectionLost) }
                return ("recovered text", 5)
            },
            sleep: { _ in } // no real waiting
        )

        let result = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))

        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(result.text, "recovered text")
    }

    // MARK: - Retry limits

    func testTimedOutIsNeverRetried() async {
        let store = makeStore()
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: silentData(frameCount: 16_000))
        var attempts = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                throw URLError(.timedOut)
            },
            sleep: { _ in }
        )

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))
            XCTFail("expected a thrown error")
        } catch {
            // A `.timedOut` server may still be working on the request — a
            // retry would risk queuing a duplicate, equally expensive
            // transcription behind it (server.py notes client cancellation
            // does not stop its worker), so this must never retry.
            XCTAssertEqual(attempts, 1)
        }
        XCTAssertEqual(store.listTakes().first?.metadata.status, .failed)
    }

    func testOnly502503504AreRetriedNotOtherServerErrors() async {
        let store = makeStore()
        var attempts = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                throw TranscriptionError.serverError(500, "internal error")
            },
            sleep: { _ in }
        )

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertEqual(attempts, 1, "a plain 500 is not one of the retried codes (502/503/504)")
        }
    }

    func testRetryBudgetStopsNewAttemptsMoreThan45SecondsAfterTheFirst() async {
        let store = makeStore()
        var attempts = 0
        var now: TimeInterval = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                throw URLError(.networkConnectionLost)
            },
            // Simulates each attempt+backoff round trip actually taking 50s
            // of wall-clock time — comfortably over the 45s budget — without
            // the test really waiting that long.
            sleep: { _ in now += 50 },
            clock: { now }
        )
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: silentData(frameCount: 16_000))

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))
            XCTFail("expected a thrown error")
        } catch {
            // 1 initial attempt, then the very first retry's sleep already
            // pushes the clock past the 45s budget — no further attempts.
            XCTAssertEqual(attempts, 1)
        }
    }

    // MARK: - Cancellation during the retry sleep

    func testCancellingARealTaskDuringTheRetrySleepNeverInvokesAnotherAttempt() async {
        let store = makeStore()
        var attempts = 0
        let sleeping = expectation(description: "sleeping")
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                throw URLError(.networkConnectionLost)
            },
            // Mirrors the real default sleeper: swallows cancellation with
            // `try?` instead of throwing, so `withRetry` must be the one
            // that notices the cancellation once this returns.
            sleep: { _ in
                sleeping.fulfill()
                try? await Task.sleep(for: .seconds(60))
            }
        )

        let task = Task {
            try await transcriber.transcribe(sessionId: "s1", header: self.header(), data: self.silentData(frameCount: 16_000))
        }
        await fulfillment(of: [sleeping], timeout: 2)
        task.cancel()
        _ = await task.result

        XCTAssertEqual(attempts, 1, "cancelling during the retry sleep must not invoke another attempt")
    }

    func testRetries5xxServerErrorsAsTransient() async throws {
        let store = makeStore()
        var attempts = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                if attempts < 2 { throw TranscriptionError.serverError(503, "warming up") }
                return ("ok", nil)
            },
            sleep: { _ in }
        )

        _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))

        XCTAssertEqual(attempts, 2)
    }

    func testNeverRetriesA4xxValidationError() async {
        let store = makeStore()
        var attempts = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                throw TranscriptionError.serverError(400, "bad request")
            },
            sleep: { _ in }
        )
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: silentData(frameCount: 16_000))

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertEqual(attempts, 1)
        }

        // Kept on disk, marked failed, for "retry from the menu."
        let take = store.listTakes().first
        XCTAssertEqual(take?.metadata.status, .failed)
    }

    func testNeverRetriesAfterCancellation() async {
        let store = makeStore()
        var attempts = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                throw CancellationError()
            },
            sleep: { _ in }
        )

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(attempts, 1)

        // Cancellation must not mark the checkpoint `.failed` — no sidecar
        // exists to mark in this test (persist was never called), and
        // `markStatus` on a missing take id is a safe no-op either way.
    }

    func testExhaustingAllRetriesThrowsAndMarksCheckpointFailedWithMessage() async {
        let store = makeStore()
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: silentData(frameCount: 16_000))
        var attempts = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                attempts += 1
                throw URLError(.networkConnectionLost)
            },
            sleep: { _ in }
        )

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: silentData(frameCount: 16_000))
            XCTFail("expected a thrown error")
        } catch {
            // 1 initial attempt + 3 retries (1s/3s/6s backoff) = 4 total.
            XCTAssertEqual(attempts, 4)
        }
        let take = store.listTakes().first
        XCTAssertEqual(take?.metadata.status, .failed)
        XCTAssertNotNil(take?.metadata.errorMessage)
    }

    // MARK: - Success discards the checkpoint

    func testDiscardCheckpointRemovesTheTakeFromDisk() {
        let store = makeStore()
        let transcriber = DurableTranscriber(store: store, transcribe: { _, _ in ("hi", nil) }, sleep: { _ in })
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: silentData(frameCount: 16_000))

        transcriber.discardCheckpoint(sessionId: "s1")

        XCTAssertTrue(store.listTakes().isEmpty)
    }

    func testLostOutcomesLeaveTheMicOwnersCopyOnAMainMac() {
        let store = makeStore()
        let transcriber = DurableTranscriber(store: store, transcribe: { _, _ in ("hi", nil) }, sleep: { _ in })
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: silentData(frameCount: 16_000))
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: silentData(frameCount: 16_000))

        transcriber.discardCoreCopy(sessionId: "s1")

        XCTAssertEqual(store.listTakes().map(\.id), ["edge-s1"])
    }

    @MainActor func testEveryOutcomeThatLostTheWordsKeepsARecording() {
        for reason in [CancelReason.micLost, .initiatorLost, .targetLost, .watchdog] {
            XCTAssertEqual(CoreHost.checkpointFate(for: .cancelled(reason)), .discardCoreCopy)
        }
        XCTAssertEqual(CoreHost.checkpointFate(for: .failed(message: "x")), .keep)
        XCTAssertEqual(CoreHost.checkpointFate(for: .cancelled(.user)), .discardBoth)
    }

    // MARK: - Chunking

    func testAudibleRecordingWithNoWordsKeepsFailedCheckpoint() async throws {
        let store = makeStore()
        let data = [Float](repeating: 0.2, count: 16_000).withUnsafeBufferPointer { Data(buffer: $0) }
        let transcriber = DurableTranscriber(store: store, transcribe: { _, _ in ("  ", nil) }, sleep: { _ in })
        transcriber.persistReceivedTake(sessionId: "s1", header: header(), data: data, edgeName: "Test Mac")

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: header(), data: data)
            XCTFail("Sound without a transcript must remain recoverable")
        } catch {
            XCTAssertTrue(error is DictationFailure)
        }
        XCTAssertEqual(store.listTakes().first?.metadata.status, .failed)
    }

    func testMissingAudibleChunkDoesNotReturnPartialTranscriptAsSuccess() async throws {
        let store = makeStore()
        let frames = 120 * 16_000
        let data = [Float](repeating: 0.2, count: frames).withUnsafeBufferPointer { Data(buffer: $0) }
        var calls = 0
        let transcriber = DurableTranscriber(store: store, transcribe: { _, _ in
            calls += 1
            return (calls == 1 ? "first part" : "", 10)
        }, sleep: { _ in })
        let takeHeader = header(durationSeconds: 120, frameCount: frames)
        transcriber.persistReceivedTake(sessionId: "s1", header: takeHeader, data: data, edgeName: "Test Mac")

        do {
            _ = try await transcriber.transcribe(sessionId: "s1", header: takeHeader, data: data)
            XCTFail("A partial transcript must not be pasted or delete the recording")
        } catch {
            XCTAssertTrue(error is DictationFailure)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.listTakes().first?.metadata.status, .failed)
    }

    func testSilentChunkCanBeOmittedWithoutLosingWords() async throws {
        let frames = 120 * 16_000
        var calls = 0
        let transcriber = DurableTranscriber(store: makeStore(), transcribe: { _, _ in
            calls += 1
            return (calls == 1 ? "first part" : "", 10)
        }, sleep: { _ in })
        let result = try await transcriber.transcribe(sessionId: "s1", header: header(durationSeconds: 120, frameCount: frames), data: silentData(frameCount: frames))
        XCTAssertEqual(result.text, "first part")
    }

    func testLongRecordingIsSplitIntoMultipleTranscribeCalls() async throws {
        let store = makeStore()
        var receivedDurations: [Double] = []
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { header, _ in
                receivedDurations.append(header.durationSeconds)
                return ("piece", 10)
            },
            sleep: { _ in }
        )
        let totalSeconds = 130.0
        let frameCount = Int(totalSeconds * 16_000)
        let data = silentData(frameCount: frameCount)

        let result = try await transcriber.transcribe(
            sessionId: "s1", header: header(durationSeconds: totalSeconds, frameCount: frameCount), data: data
        )

        XCTAssertGreaterThan(receivedDurations.count, 1)
        XCTAssertEqual(receivedDurations.reduce(0, +), totalSeconds, accuracy: 0.01)
        XCTAssertEqual(result.text, Array(repeating: "piece", count: receivedDurations.count).joined(separator: " "))
        for duration in receivedDurations {
            XCTAssertLessThanOrEqual(duration, DurableTranscriber.maxChunkSeconds + 0.01)
        }
    }

    func testShortRecordingIsNotChunked() async throws {
        let store = makeStore()
        var callCount = 0
        let transcriber = DurableTranscriber(
            store: store,
            transcribe: { _, _ in
                callCount += 1
                return ("whole", 10)
            },
            sleep: { _ in }
        )

        _ = try await transcriber.transcribe(sessionId: "s1", header: header(durationSeconds: 30, frameCount: 30 * 16_000), data: silentData(frameCount: 30 * 16_000))

        XCTAssertEqual(callCount, 1)
    }

    func testLongTakeAggregatesRawAndFinalChunksInOrderWithPerChunkFallback() async throws {
        var calls = 0
        let transcriber = DurableTranscriber(store: makeStore(), transcribeWithRawText: { _, _ in
            calls += 1
            return ("final\(calls)", 10, calls == 2 ? nil : "raw\(calls)")
        }, sleep: { _ in })
        let frames = 120 * 16_000
        let result = try await transcriber.transcribe(sessionId: "s1", header: header(durationSeconds: 120, frameCount: frames), data: silentData(frameCount: frames))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.text, "final1 final2")
        XCTAssertEqual(result.rawText, "raw1 final2")
        XCTAssertEqual(result.inferenceMs, 20)
    }

}
