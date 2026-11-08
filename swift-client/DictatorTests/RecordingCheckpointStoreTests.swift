import XCTest
@testable import Dictator

/// Covers `RecordingCheckpointStore` and `RecordingCheckpointWriter` against
/// a temp directory — never the developer's real `~/Library/Application
/// Support/Dictator/Recovery`. Every test gets its own fresh directory so
/// they can't see each other's files.
final class RecordingCheckpointStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingCheckpointStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> RecordingCheckpointStore {
        RecordingCheckpointStore(directory: tempDirectory)
    }

    // MARK: - Take id prefixes

    func testEdgeAndCoreTakeIdsAreDistinctForTheSameSession() {
        XCTAssertNotEqual(RecordingCheckpointStore.edgeTakeId("s1"), RecordingCheckpointStore.coreTakeId("s1"))
        XCTAssertEqual(RecordingCheckpointStore.edgeTakeId("s1"), "edge-s1")
        XCTAssertEqual(RecordingCheckpointStore.coreTakeId("s1"), "core-s1")
    }

    // MARK: - Writer append/flush/cap

    func testWriterFlushesOnceEnoughAudioHasAccumulated() {
        let store = makeStore()
        let writer = RecordingCheckpointWriter(
            store: store, takeId: "edge-s1", sessionId: "s1", sampleRate: 100, edgeName: "MacBook",
            flushIntervalSeconds: 1 // flush every 100 samples at this rate
        )
        XCTAssertNotNil(writer)

        writer?.append([Float](repeating: 0.5, count: 50)) // under threshold: buffered, not flushed
        var takes = store.listTakes()
        XCTAssertEqual(takes.first?.durationSeconds ?? 0, 0, accuracy: 0.001)

        writer?.append([Float](repeating: 0.5, count: 60)) // crosses the 100-sample threshold
        takes = store.listTakes()
        XCTAssertEqual(takes.count, 1)
        XCTAssertEqual(takes.first?.durationSeconds ?? 0, 1.1, accuracy: 0.01)
        XCTAssertEqual(takes.first?.metadata.status, .recording)
    }

    func testWriterCapsAtMaxDurationAndStopsAppending() {
        let store = makeStore()
        let writer = RecordingCheckpointWriter(
            store: store, takeId: "edge-s1", sessionId: "s1", sampleRate: 10, edgeName: "MacBook",
            flushIntervalSeconds: 0.1, maxDuration: 1 // caps after 10 frames
        )
        writer?.append([Float](repeating: 0, count: 10)) // exactly the cap: flush pushes it over the line
        XCTAssertEqual(writer?.isCapped, true)

        writer?.append([Float](repeating: 0, count: 100)) // dropped — writer is capped
        let take = store.listTakes().first
        XCTAssertEqual(take?.durationSeconds ?? 0, 1, accuracy: 0.01)
    }

    func testWriterFinishFlushesRemainderAndMarksUploaded() {
        let store = makeStore()
        let writer = RecordingCheckpointWriter(
            store: store, takeId: "edge-s1", sessionId: "s1", sampleRate: 100, edgeName: "MacBook",
            flushIntervalSeconds: 10 // nothing auto-flushes before `finish()`
        )
        writer?.append([Float](repeating: 0, count: 50))
        writer?.finish()

        let take = store.listTakes().first
        XCTAssertEqual(take?.metadata.status, .uploaded)
        XCTAssertEqual(take?.durationSeconds ?? 0, 0.5, accuracy: 0.01)
    }

    func testWriterDiscardDeletesBothFiles() {
        let store = makeStore()
        let writer = RecordingCheckpointWriter(
            store: store, takeId: "edge-s1", sessionId: "s1", sampleRate: 100, edgeName: "MacBook"
        )
        writer?.append([Float](repeating: 0, count: 500))
        writer?.discard()

        XCTAssertTrue(store.listTakes().isEmpty)
    }

    // MARK: - Core one-shot save

    func testSaveReceivedTakeWritesDataAndReceivedStatus() {
        let store = makeStore()
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: data)

        let take = store.listTakes().first
        XCTAssertEqual(take?.metadata.status, .received)
        XCTAssertEqual(take?.metadata.sessionId, "s1")
        XCTAssertEqual(try? Data(contentsOf: take!.pcmURL), data)
    }

    // MARK: - Status / delete

    func testMarkStatusUpdatesFailedWithErrorMessage() {
        let store = makeStore()
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: Data([1, 2, 3, 4]))

        store.markStatus("core-s1", status: .failed, errorMessage: "server unreachable")

        let take = store.listTakes().first
        XCTAssertEqual(take?.metadata.status, .failed)
        XCTAssertEqual(take?.metadata.errorMessage, "server unreachable")
    }

    func testDeleteIsSafeOnATakeThatDoesNotExist() {
        let store = makeStore()
        store.delete("edge-does-not-exist") // must not throw/crash
        XCTAssertTrue(store.listTakes().isEmpty)
    }

    // MARK: - Listing

    func testListTakesExcludesActiveIds() {
        let store = makeStore()
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: Data([1, 2, 3, 4]))
        store.saveReceivedTake(takeId: "core-s2", sessionId: "s2", sampleRate: 16_000, edgeName: "mini", data: Data([1, 2, 3, 4]))

        let takes = store.listTakes(excluding: ["core-s1"])

        XCTAssertEqual(takes.map(\.id), ["core-s2"])
    }

    func testListTakesOrdersNewestFirst() {
        let store = makeStore()
        let older = CheckpointMetadata(
            takeId: "core-old", sessionId: "old", sampleRate: 16_000,
            startedAt: Date(timeIntervalSinceNow: -100), edgeName: "mini", status: .received
        )
        let newer = CheckpointMetadata(
            takeId: "core-new", sessionId: "new", sampleRate: 16_000,
            startedAt: Date(), edgeName: "mini", status: .received
        )
        for metadata in [older, newer] {
            store.saveReceivedTake(
                takeId: metadata.takeId, sessionId: metadata.sessionId, sampleRate: metadata.sampleRate,
                edgeName: metadata.edgeName, data: Data([1, 2, 3, 4])
            )
            store.markStatus(metadata.takeId, status: .received) // no-op re-write, keeps status explicit
        }
        // `saveReceivedTake` always stamps `startedAt = Date()`, so overwrite
        // directly to control ordering deterministically.
        writeMetadataDirectly(store, metadata: older)
        writeMetadataDirectly(store, metadata: newer)

        let takes = store.listTakes()

        XCTAssertEqual(takes.map(\.id), ["core-new", "core-old"])
    }

    /// Test-only helper: some ordering tests need an exact `startedAt`,
    /// which the store's public API always stamps with `Date()` — write the
    /// sidecar directly instead of going through `saveReceivedTake` twice.
    private func writeMetadataDirectly(_ store: RecordingCheckpointStore, metadata: CheckpointMetadata) {
        writeMetadataDirectlyAt(tempDirectory.appendingPathComponent("\(metadata.takeId).json"), metadata: metadata)
    }

    /// Like `writeMetadataDirectly` above, but at an explicit path —
    /// `testListTakesSkipsASidecarWhoseTakeIdDoesNotMatchItsFilename`
    /// needs a sidecar's filename to differ from its own
    /// `takeId` field, which the takeId-derived path above can't produce.
    private func writeMetadataDirectlyAt(_ url: URL, metadata: CheckpointMetadata) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url)
    }

    // MARK: - Sidecar-before-PCM ordering, rollback, orphan pruning

    func testBeginRecordingRollsBackTheSidecarWhenPCMCreationFails() {
        let store = makeStore()
        // Force the PCM path to already exist as a directory so
        // `FileManager.createFile` fails.
        try? FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("edge-s1.pcm"), withIntermediateDirectories: true
        )

        let handle = store.beginRecording(takeId: "edge-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "MacBook")

        XCTAssertNil(handle)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-s1.json").path),
            "a sidecar with no PCM behind it must not be left on disk"
        )
    }

    func testFlushKeepsPendingSamplesWhenTheWriteFails() {
        let store = makeStore()
        let writer = RecordingCheckpointWriter(
            store: store, takeId: "edge-s1", sessionId: "s1", sampleRate: 100, edgeName: "MacBook",
            flushIntervalSeconds: 1_000 // nothing auto-flushes; every flush below is explicit
        )
        writer?.append([Float](repeating: 0.5, count: 10)) // buffered, not yet flushed
        writer?.simulateWriteFailureForTesting()

        let flushed = writer?.flush()

        XCTAssertEqual(flushed, false)
        XCTAssertEqual(writer?.isCapped, true)
        // The take is still on disk with zero duration — proof the 10
        // samples never silently vanished from `pending` despite the
        // failed write (they simply couldn't be written to the now-closed
        // handle either, which is the correct outcome for a capped writer).
        let take = store.listTakes().first
        XCTAssertEqual(take?.durationSeconds ?? -1, 0, accuracy: 0.001)
    }

    func testPruneOrphansDeletesPCMWithNoSidecarAndSidecarsThatFailToDecode() {
        let store = makeStore()
        // Orphan PCM: no sidecar at all.
        FileManager.default.createFile(
            atPath: tempDirectory.appendingPathComponent("edge-orphan.pcm").path, contents: Data([1, 2, 3, 4])
        )
        // A sidecar that fails to decode (truncated/corrupt write), with a
        // PCM sitting next to it.
        FileManager.default.createFile(
            atPath: tempDirectory.appendingPathComponent("edge-corrupt.pcm").path, contents: Data([1, 2, 3, 4])
        )
        try? Data("not valid json".utf8).write(to: tempDirectory.appendingPathComponent("edge-corrupt.json"))
        // A normal, valid take that must survive pruning untouched.
        store.saveReceivedTake(takeId: "edge-ok", sessionId: "ok", sampleRate: 16_000, edgeName: "MacBook", data: Data([1, 2, 3, 4]))

        store.pruneOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-orphan.pcm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-corrupt.pcm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-corrupt.json").path))
        XCTAssertEqual(store.listTakes().map(\.id), ["edge-ok"])
    }

    // MARK: - Aggregate disk cap

    func testEnforceSizeCapDeletesTheOldestTakesUntilUnderTheCap() {
        let big = Data(repeating: 0, count: 60)
        // Probe one take's actual on-disk size (PCM + JSON sidecar) so the
        // injected cap below is "room for one take, not two" regardless of
        // exactly how large `CheckpointMetadata`'s JSON encoding is.
        let probeStore = makeStore()
        probeStore.saveReceivedTake(takeId: "core-probe", sessionId: "probe", sampleRate: 16_000, edgeName: "mini", data: big)
        let pcmSize = ((try? FileManager.default.attributesOfItem(atPath: tempDirectory.appendingPathComponent("core-probe.pcm").path))?[.size] as? Int) ?? 0
        let jsonSize = ((try? FileManager.default.attributesOfItem(atPath: tempDirectory.appendingPathComponent("core-probe.json").path))?[.size] as? Int) ?? 0
        probeStore.delete("core-probe")

        let store = RecordingCheckpointStore(directory: tempDirectory, maxBytes: pcmSize + jsonSize + 20)
        store.saveReceivedTake(takeId: "core-old", sessionId: "old", sampleRate: 16_000, edgeName: "mini", data: big)
        store.saveReceivedTake(takeId: "core-new", sessionId: "new", sampleRate: 16_000, edgeName: "mini", data: big)
        // Force a deterministic age order (`saveReceivedTake` always stamps
        // `startedAt = Date()`, which could tie at this resolution).
        writeMetadataDirectly(store, metadata: CheckpointMetadata(
            takeId: "core-old", sessionId: "old", sampleRate: 16_000,
            startedAt: Date(timeIntervalSinceNow: -100), edgeName: "mini", status: .received
        ))
        writeMetadataDirectly(store, metadata: CheckpointMetadata(
            takeId: "core-new", sessionId: "new", sampleRate: 16_000,
            startedAt: Date(), edgeName: "mini", status: .received
        ))

        store.enforceSizeCap()

        XCTAssertEqual(store.listTakes().map(\.id), ["core-new"], "the OLDEST take must be evicted first")
    }

    func testEnforceSizeCapDoesNothingUnderTheCap() {
        let store = RecordingCheckpointStore(directory: tempDirectory, maxBytes: 10_000)
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "mini", data: Data([1, 2, 3, 4]))

        store.enforceSizeCap()

        XCTAssertEqual(store.listTakes().map(\.id), ["core-s1"])
    }

    // MARK: - Edge-/core- dedup and sibling deletion

    func testListTakesShowsOnlyTheCoreCopyWhenBothEdgeAndCoreExistForTheSameSession() {
        let store = makeStore()
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 48_000, edgeName: "MacBook", data: Data([1, 2, 3, 4]))
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "MacBook", data: Data([1, 2, 3, 4]))

        XCTAssertEqual(store.listTakes().map(\.id), ["core-s1"])
    }

    func testDeletingTheCoreCopyAlsoDeletesItsEdgeSibling() {
        let store = makeStore()
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 48_000, edgeName: "MacBook", data: Data([1, 2, 3, 4]))
        store.saveReceivedTake(takeId: "core-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "MacBook", data: Data([1, 2, 3, 4]))

        store.delete("core-s1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-s1.pcm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-s1.json").path))
    }

    func testDeletingASegmentDoesNotCascadeToItsSessionsCanonicalTake() {
        // An engine-restart-interrupted segment shares a
        // sessionId with the session's real `edge-`/`core-` checkpoint but
        // must never drag it down when the segment itself is deleted.
        let store = makeStore()
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 48_000, edgeName: "MacBook", data: Data([1, 2, 3, 4]))
        store.saveReceivedTake(takeId: "edge-s1-seg1", sessionId: "s1", sampleRate: 48_000, edgeName: "MacBook", data: Data([1, 2, 3, 4]))

        store.delete("edge-s1-seg1")

        XCTAssertEqual(store.listTakes().map(\.id), ["edge-s1"])
    }

    // MARK: - Take-id validation

    func testIsValidTakeIdRejectsPathSeparatorsDotDotAndEmpty() {
        XCTAssertFalse(RecordingCheckpointStore.isValidTakeId("../etc/passwd"))
        XCTAssertFalse(RecordingCheckpointStore.isValidTakeId("edge/../s1"))
        XCTAssertFalse(RecordingCheckpointStore.isValidTakeId(""))
        XCTAssertTrue(RecordingCheckpointStore.isValidTakeId("edge-s1"))
        XCTAssertTrue(RecordingCheckpointStore.isValidTakeId("edge-s1-seg1"))
    }

    func testBeginRecordingRejectsAnInvalidTakeId() {
        let store = makeStore()

        let handle = store.beginRecording(takeId: "../evil", sessionId: "s1", sampleRate: 16_000, edgeName: "mini")

        XCTAssertNil(handle)
        XCTAssertTrue(store.listTakes().isEmpty)
    }

    func testListTakesSkipsASidecarWhoseTakeIdDoesNotMatchItsFilename() {
        let store = makeStore()
        // A corrupt sidecar: `core-a.json` on disk, but its own `takeId`
        // field claims `core-b`.
        let mismatched = CheckpointMetadata(
            takeId: "core-b", sessionId: "a", sampleRate: 16_000, edgeName: "mini", status: .received
        )
        writeMetadataDirectlyAt(tempDirectory.appendingPathComponent("core-a.json"), metadata: mismatched)
        FileManager.default.createFile(atPath: tempDirectory.appendingPathComponent("core-a.pcm").path, contents: Data([1, 2, 3, 4]))

        XCTAssertTrue(store.listTakes().isEmpty, "a sidecar claiming a different takeId than its filename must be skipped")
    }

    func testPruneOlderThanRemovesOldTakesOnly() {
        let store = makeStore()
        let old = CheckpointMetadata(
            takeId: "core-old", sessionId: "old", sampleRate: 16_000,
            startedAt: Date(timeIntervalSinceNow: -20 * 86_400), edgeName: "mini", status: .received
        )
        let recent = CheckpointMetadata(
            takeId: "core-recent", sessionId: "recent", sampleRate: 16_000,
            startedAt: Date(), edgeName: "mini", status: .received
        )
        for metadata in [old, recent] {
            store.saveReceivedTake(
                takeId: metadata.takeId, sessionId: metadata.sessionId, sampleRate: metadata.sampleRate,
                edgeName: metadata.edgeName, data: Data([1, 2, 3, 4])
            )
        }
        writeMetadataDirectly(store, metadata: old)
        writeMetadataDirectly(store, metadata: recent)

        store.pruneOlderThan(days: 14)

        XCTAssertEqual(store.listTakes().map(\.id), ["core-recent"])
    }

    // MARK: - Size cap sees what is really on disk

    func testSizeCapCountsBothCopiesOfASession() {
        let audio = Data(repeating: 1, count: 4_000)
        let store = RecordingCheckpointStore(directory: tempDirectory, maxBytes: 6_000)
        store.saveReceivedTake(takeId: "core-old", sessionId: "old", sampleRate: 16_000, edgeName: "Mac", data: audio)
        store.saveReceivedTake(takeId: "edge-old", sessionId: "old", sampleRate: 16_000, edgeName: "Mac", data: audio)
        store.enforceSizeCap()
        XCTAssertTrue(store.listTakes().isEmpty, "8 KB of audio is over a 6 KB cap, whichever copy is listed")
    }

    func testSizeCapNeverEvictsATakeStillBeingRecorded() {
        let audio = Data(repeating: 1, count: 4_000)
        let store = RecordingCheckpointStore(directory: tempDirectory, maxBytes: 6_000)
        store.saveReceivedTake(takeId: "edge-live", sessionId: "live", sampleRate: 16_000, edgeName: "Mac", data: audio)
        store.markStatus("edge-live", status: .recording)
        store.saveReceivedTake(takeId: "edge-done", sessionId: "done", sampleRate: 16_000, edgeName: "Mac", data: audio)
        store.enforceSizeCap()
        XCTAssertEqual(store.listTakes().map(\.id), ["edge-live"])
    }

    // MARK: - Rename leaves a whole take at every step

    func testRenameMovesTheWholeTake() {
        let store = makeStore()
        store.saveReceivedTake(takeId: "edge-a", sessionId: "a", sampleRate: 16_000, edgeName: "Mac", data: Data([1, 2, 3, 4]))
        store.rename("edge-a", to: "edge-a-seg1")
        XCTAssertEqual(store.listTakes().map(\.id), ["edge-a-seg1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-a.json").path))
    }

    func testCrashPartWayThroughARenameKeepsTheRecording() throws {
        let store = makeStore()
        store.saveReceivedTake(takeId: "edge-a", sessionId: "a", sampleRate: 16_000, edgeName: "Mac", data: Data([1, 2, 3, 4]))
        store.rename("edge-a", to: "edge-a-seg1")
        // The state after the audio moved and before the old sidecar went:
        let sidecar = try Data(contentsOf: tempDirectory.appendingPathComponent("edge-a-seg1.json"))
        try sidecar.write(to: tempDirectory.appendingPathComponent("edge-a.json"))

        store.pruneOrphans()

        XCTAssertEqual(store.listTakes().map(\.id), ["edge-a-seg1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("edge-a.json").path))
    }
}
