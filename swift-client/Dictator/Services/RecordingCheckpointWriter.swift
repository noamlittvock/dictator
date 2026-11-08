import Foundation

/// Incremental writer for one recording checkpoint (`RecordingCheckpointStore`).
/// Every method is synchronous disk I/O and not thread-safe on its own —
/// `AudioCaptureService` is responsible for only ever touching an instance
/// from its private serial checkpoint queue, off the audio tap thread, which
/// is also what keeps this off the hot path. Tests call the methods directly,
/// with no queue at all.
final class RecordingCheckpointWriter {
    let takeId: String
    /// The `AudioCaptureService.captureGeneration` this writer
    /// was created for — the checkpoint queue re-checks this against the
    /// generation a (possibly delayed) tap-thread buffer was captured
    /// under before ever appending it, so a buffer that got queued after a
    /// stop/start boundary can't be written into the wrong writer's file.
    let generation: Int
    private let store: RecordingCheckpointStore
    private let sampleRate: Int
    private let flushIntervalSeconds: TimeInterval
    private let maxDuration: TimeInterval
    private var fileHandle: FileHandle?
    private var pending: [Float] = []
    private var flushedFrameCount = 0
    /// True once `maxDuration` worth of audio has been written — further
    /// `append` calls are silently dropped, so a stuck hold can't fill the
    /// disk. The in-RAM capture this mirrors is untouched; only the
    /// on-disk checkpoint stops growing.
    private(set) var isCapped = false

    /// `nil` if the checkpoint's files could not be created/opened — the
    /// caller (`AudioCaptureService`) treats that as "no checkpoint for this
    /// take" and moves on; a failure here must never break dictation.
    init?(
        store: RecordingCheckpointStore, takeId: String, sessionId: SessionID, sampleRate: Int, edgeName: String,
        flushIntervalSeconds: TimeInterval = 3, maxDuration: TimeInterval = 30 * 60, generation: Int = 0
    ) {
        guard let handle = store.beginRecording(
            takeId: takeId, sessionId: sessionId, sampleRate: sampleRate, edgeName: edgeName
        ) else { return nil }
        self.store = store
        self.takeId = takeId
        self.sampleRate = sampleRate
        self.flushIntervalSeconds = flushIntervalSeconds
        self.maxDuration = maxDuration
        self.generation = generation
        self.fileHandle = handle
    }

    /// Buffers `samples` (mono, at `sampleRate`) and flushes to disk once at
    /// least `flushIntervalSeconds` of new audio has accumulated. Never
    /// throws — an I/O failure just caps this writer (see `flush()`).
    func append(_ samples: [Float]) {
        guard !isCapped, fileHandle != nil, !samples.isEmpty else { return }
        pending.append(contentsOf: samples)
        guard Double(pending.count) / Double(sampleRate) >= flushIntervalSeconds else { return }
        flush()
    }

    /// Writes whatever is buffered. Returns `false` if there was nothing to
    /// write or the write failed (in which case this writer caps itself —
    /// no point retrying a broken file handle on every future flush).
    /// `pending` is only cleared once `write(contentsOf:)` has actually
    /// succeeded — dropping it before a partial/failed write (disk full,
    /// revoked permission) could leave the on-disk file short of a whole
    /// number of frames (not a multiple of 4 bytes); `Recovery`/the server both assume the PCM
    /// file is exactly `frameCount * 4` bytes.
    @discardableResult
    func flush() -> Bool {
        guard !pending.isEmpty, let fileHandle else { return false }
        let data = pending.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            NSLog("[Checkpoint] write failed for take %@: %@", takeId, error.localizedDescription)
            isCapped = true
            return false
        }
        pending.removeAll(keepingCapacity: true)
        flushedFrameCount += data.count / 4
        if Double(flushedFrameCount) / Double(sampleRate) >= maxDuration {
            isCapped = true
            NSLog("[Checkpoint] take %@ reached the %.0f-minute cap; no longer appending", takeId, maxDuration / 60)
        }
        return true
    }

    /// Final flush, close, and mark `status` (`.uploaded` by default — the
    /// normal end of a capture: stop, or a connection loss the Edge
    /// couldn't hand the audio off across). An engine/device
    /// restart mid-hold instead finalizes with `.interrupted`, via
    /// `AudioCaptureService.interruptCheckpointSegment` — see
    /// `CheckpointStatus.interrupted`'s doc for why that status (and its own
    /// take id) exists. Cleanup by outcome (delete vs. keep for recovery)
    /// happens separately — see `EdgeRuntime`'s `applyCheckpointCleanup`.
    /// Enforces the aggregate disk cap once the file is final.
    func finish(status: CheckpointStatus = .uploaded) {
        flush()
        fileHandle?.closeFile()
        fileHandle = nil
        store.markStatus(takeId, status: status)
        store.enforceSizeCap()
    }

    /// A genuine cancel (user Esc, or `stopCapture()` found no audio):
    /// delete the checkpoint entirely rather than leaving worthless files
    /// for the recovery UI to show.
    func discard() {
        fileHandle?.closeFile()
        fileHandle = nil
        store.delete(takeId)
    }

    // MARK: - Test-only seam

    /// Closes the underlying file descriptor without clearing `fileHandle`
    /// — simulates a write failure (disk full, revoked permission) on the
    /// next `append`/`flush`, so `RecordingCheckpointStoreTests` can cover
    /// the "`pending` is only dropped once the write actually succeeds"
    /// behavior without needing a real full disk.
    func simulateWriteFailureForTesting() {
        fileHandle?.closeFile()
    }
}
