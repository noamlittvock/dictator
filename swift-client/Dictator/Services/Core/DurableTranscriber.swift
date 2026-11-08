import Foundation

/// Wraps the Core's `transcribeAudio` closure with durability behaviors: persists the take to disk
/// before transcription starts, retries transient failures with backoff, and splits audio too long for
/// the inference server to accept into sequential chunks cut at low-energy points. Pure orchestration
/// around injected dependencies (store, the transcribe closure, a sleep function) so
/// `DurableTranscriberTests` can drive every branch — retry, no-retry-on-4xx, no-retry-after-cancel,
/// chunking — without a real store, network, or clock.
final class DurableTranscriber {
    /// 1s, then 3s, then 6s: up to 3 retries (4 attempts total) of a
    /// transient failure.
    static let retryDelays: [TimeInterval] = [1, 3, 6]
    /// No new attempt starts more than this long after the
    /// first attempt began — a server that's simply slow (rather than
    /// actually unreachable) must not be retried into duplicate expensive
    /// inference work indefinitely; see `withRetry`.
    static let retryBudgetSeconds: TimeInterval = 45
    /// Above this, `transcribe` splits the take instead of sending it whole
    /// (the server rejects anything over 120s; 110 leaves margin).
    static let longRecordingThreshold: Double = 110
    static let maxChunkSeconds: Double = 100

    private let store: RecordingCheckpointStore
    private let transcribeChunk: (AudioTakeHeader, Data) async throws -> (text: String, inferenceMs: Int?, rawText: String?)
    private let sleep: (TimeInterval) async -> Void
    /// Injected so `DurableTranscriberTests` can simulate the
    /// passage of time without a real 45s wait — defaults to a monotonic
    /// wall clock, same pattern as `SessionBroker`'s injected `clock`.
    private let clock: () -> TimeInterval

    convenience init(
        store: RecordingCheckpointStore,
        transcribe: @escaping (AudioTakeHeader, Data) async throws -> (text: String, inferenceMs: Int?),
        sleep: @escaping (TimeInterval) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.init(store: store, transcribeWithRawText: { header, data in
            let result = try await transcribe(header, data)
            return (result.text, result.inferenceMs, nil)
        }, sleep: sleep, clock: clock)
    }

    init(
        store: RecordingCheckpointStore,
        transcribeWithRawText: @escaping (AudioTakeHeader, Data) async throws -> (text: String, inferenceMs: Int?, rawText: String?),
        sleep: @escaping (TimeInterval) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.transcribeChunk = transcribeWithRawText
        self.sleep = sleep
        self.clock = clock
    }

    /// Must be called before `transcribe(...)` for the same session — persists
    /// `data` to the Core's checkpoint store with status `.received`.
    /// Synchronous and best-effort: an I/O failure here is logged and never
    /// blocks transcription (`RecordingCheckpointStore` itself never throws).
    func persistReceivedTake(sessionId: SessionID, header: AudioTakeHeader, data: Data, edgeName: String) {
        store.saveReceivedTake(
            takeId: Self.takeId(sessionId), sessionId: sessionId, sampleRate: header.sampleRate,
            edgeName: edgeName, data: data
        )
    }

    /// Runs transcription for `data`/`header`: retries transient failures,
    /// chunks audio over `longRecordingThreshold`, and — on final failure —
    /// marks the checkpoint `.failed` (kept on disk for "retry from the
    /// menu"). Deleting the checkpoint on success is the caller's job
    /// (`CoreHost` only does that once the history write has actually
    /// landed — see `discardCheckpoint`).
    func transcribe(sessionId: SessionID, header: AudioTakeHeader, data: Data) async throws -> (text: String, inferenceMs: Int?, rawText: String?) {
        do {
            return try await Self.transcribeStagesChunkingIfNeeded(header: header, data: data) { chunkHeader, chunkData in
                let result = try await self.withRetry { try await self.transcribeChunk(chunkHeader, chunkData) }
                // An empty answer does not prove silence. Do not paste a partial
                // long take, or discard audible audio that can still be retried.
                if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !Self.isSilent(chunkData) {
                    throw DictationFailure(DictationAlert(
                        title: "Some words couldn’t be turned into text",
                        detail: "Nothing was typed. Your recording is kept in History & Privacy so you can try again.",
                        action: .history))
                }
                return result
            }
        } catch {
            if !isCancellation(error) {
                store.markStatus(Self.takeId(sessionId), status: .failed, errorMessage: (error as? DictationFailure).map { "\($0.alert.title)." } ?? error.localizedDescription)
            }
            throw error
        }
    }

    /// The take made it all the way to a recorded history entry — the Core's
    /// retained copy is no longer needed for recovery.
    func discardCheckpoint(sessionId: SessionID) {
        store.delete(Self.takeId(sessionId))
    }

    /// The Core's copy is a duplicate, but on a main or standalone Mac the mic
    /// owner's copy sits in the same folder: leave that one for recovery.
    func discardCoreCopy(sessionId: SessionID) {
        store.deleteLeavingSibling(Self.takeId(sessionId))
    }

    func markCheckpointFailed(sessionId: SessionID, message: String) {
        store.markStatus(Self.takeId(sessionId), status: .failed, errorMessage: message)
    }

    static func takeId(_ sessionId: SessionID) -> String { RecordingCheckpointStore.coreTakeId(sessionId) }

    /// Use the same conservative silence check for live and recovered takes.
    static func isSilent(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Float.self).allSatisfy { abs($0) < 0.001 }
        }
    }

    // MARK: - Chunking

    /// Splits `data` into sequential chunks and transcribes each with
    /// `transcribe`, joining the resulting text with spaces — or, when
    /// `header.durationSeconds` is under `longRecordingThreshold`, just
    /// calls `transcribe` once with the whole take. `static` and free of
    /// any `DurableTranscriber` instance state (no checkpoint store, no
    /// retry policy) precisely so `RecoveryService`'s recovery path — which
    /// has no session/broker context, just a checkpoint's header and bytes —
    /// can chunk a take exactly the same way `CoreHost`'s live path does,
    /// instead of sending it whole and getting a permanent HTTP 413 for any
    /// recovered take over the server's limit. `transcribe` is called once
    /// per chunk (or once, whole); whatever retry policy the caller wants
    /// wraps its own closure — this function has no opinion on retries.
    /// The chunker itself is frame-based (`LongRecordingChunker.chunkBounds`
    /// takes `sampleRate` explicitly), so this works correctly regardless of
    /// whether `header.sampleRate` is the Edge's device rate or the Core's
    /// 16 kHz.
    static func transcribeStagesChunkingIfNeeded(
        header: AudioTakeHeader, data: Data,
        transcribe: (AudioTakeHeader, Data) async throws -> (text: String, inferenceMs: Int?, rawText: String?)
    ) async throws -> (text: String, inferenceMs: Int?, rawText: String?) {
        guard header.durationSeconds > Self.longRecordingThreshold else {
            return try await transcribe(header, data)
        }
        let bytesPerFrame = 4
        let bounds = LongRecordingChunker.chunkBounds(
            totalFrames: header.frameCount,
            sampleRate: header.sampleRate,
            maxChunkSeconds: Self.maxChunkSeconds,
            rms: { range in Self.rms(of: data, frameRange: range) }
        )
        var pieces: [String] = []
        var heardPieces: [String] = []
        var totalInferenceMs = 0
        var sawInferenceMs = false
        for bound in bounds {
            let byteRange = (bound.startFrame * bytesPerFrame)..<(bound.endFrame * bytesPerFrame)
            let chunkData = data.subdata(in: byteRange)
            let frameCount = bound.endFrame - bound.startFrame
            let chunkHeader = AudioTakeHeader(
                sessionId: header.sessionId,
                sampleRate: header.sampleRate,
                frameCount: frameCount,
                durationSeconds: Double(frameCount) / Double(header.sampleRate),
                byteCount: chunkData.count
            )
            let result = try await transcribe(chunkHeader, chunkData)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            let heard = (result.rawText ?? result.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !heard.isEmpty { heardPieces.append(heard) }
            if let ms = result.inferenceMs {
                totalInferenceMs += ms
                sawInferenceMs = true
            }
        }
        return (pieces.joined(separator: " "), sawInferenceMs ? totalInferenceMs : nil, heardPieces.joined(separator: " "))
    }

    private static func rms(of data: Data, frameRange: Range<Int>) -> Float {
        guard !frameRange.isEmpty else { return 0 }
        let byteRange = (frameRange.lowerBound * 4)..<(frameRange.upperBound * 4)
        guard byteRange.lowerBound >= 0, byteRange.upperBound <= data.count else { return 0 }
        var sum: Double = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float32.self)
            let start = byteRange.lowerBound / 4
            let end = byteRange.upperBound / 4
            for i in start..<end {
                let sample = Double(floats[i])
                sum += sample * sample
            }
        }
        return Float((sum / Double(frameRange.count)).squareRoot())
    }

    // MARK: - Retry

    /// Retries `attempt` up to `retryDelays.count` additional times on a
    /// transient failure, sleeping `retryDelays[n]` before retry `n+1`.
    /// Never retries a cancellation, and never retries a non-transient error
    /// (a 4xx from the server, an unrecognized failure, or a
    /// `.timedOut`: the server may still be working on the request, and a
    /// retry would just queue a duplicate, equally expensive transcription
    /// behind it) at all.
    ///
    /// Also enforces an overall retry budget — no new attempt
    /// starts more than `retryBudgetSeconds` after the first one began, so a
    /// server that's merely slow (rather than actually unreachable) can't
    /// hold the broker in `.processing` for the full sum of every attempt's
    /// own request timeout. Cancellation is checked again right
    /// after `sleep` returns, not just before it — the default `sleep`
    /// swallows a cancelled `Task.sleep` with `try?` (so it returns
    /// normally instead of throwing), and without this second check a
    /// cancel delivered during the backoff would still trigger one more
    /// (wasted, and potentially session-resurrecting) attempt.
    private func withRetry<T>(_ attempt: () async throws -> T) async throws -> T {
        let startedAt = clock()
        var lastError: Error!
        for index in 0...Self.retryDelays.count {
            if Task.isCancelled { throw CancellationError() }
            if index > 0 {
                await sleep(Self.retryDelays[index - 1])
                if Task.isCancelled { throw CancellationError() }
                if clock() - startedAt > Self.retryBudgetSeconds { throw lastError }
            }
            do {
                return try await attempt()
            } catch {
                if isCancellation(error) { throw error }
                lastError = error
                guard isRetryable(error), index < Self.retryDelays.count,
                      clock() - startedAt <= Self.retryBudgetSeconds else { throw error }
            }
        }
        throw lastError
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Only connection-level `URLError`s (the request never
    /// reached/heard back from the server at all) and HTTP 502/503/504
    /// (the server itself reported it's overloaded/restarting/gatewaying)
    /// are retried. `.timedOut` is deliberately excluded — per the server's
    /// own note, cancelling a client request does not stop its worker, so
    /// retrying a timeout risks queuing a duplicate, equally expensive
    /// transcription behind a request that may still be running. Everything
    /// else (a 4xx validation error, a malformed response, an unrecognized
    /// error type) is not retried either — retrying it wouldn't change the
    /// outcome.
    func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .cannotFindHost, .resourceUnavailable, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        if case TranscriptionError.serverError(let code, _) = error {
            return code == 502 || code == 503 || code == 504
        }
        return false
    }
}
