import Foundation

/// Why a speech source was given up on without an answer.
enum SpeechChainError: Error, LocalizedError {
    /// The source took the audio but never answered in time.
    case stalled

    var errorDescription: String? { "That Mac didn’t answer in time." }
}

/// Tries the configured speech sources one after another until one turns the
/// audio into text. Used by live dictation and by recovery, so both behave
/// the same. Any failure of a source (unreachable, server error, bad reply,
/// timeout, a hang) moves on to the next; only when every source has failed
/// does it throw. A key/address problem is retained ahead of later outages;
/// otherwise the last source's error explains the failure.
enum SpeechSourceChain {
    /// Every source failed. Keeps the source paired with the error being reported.
    struct Failure: Error {
        let source: SetupRouting.SpeechSource
        let error: Error
    }

    /// How long to wait before giving up on a source that cannot be reached.
    static let connectTimeout: TimeInterval = 4

    /// How long a source may take once it has the audio: a fixed allowance
    /// for loading a model, plus twice the audio length, up to five minutes.
    static func processingLimit(audioSeconds: Double) -> TimeInterval {
        min(300, 45 + 2 * max(0, audioSeconds))
    }

    /// Runs `attempt` on each source in order. `reach` (optional) is a quick
    /// check that a source is there at all, given `connectTimeout`; if it
    /// throws, the source is skipped without waiting for the long limit.
    /// `attempt` is given the processing limit and is abandoned after it.
    static func run<T>(
        sources: [SetupRouting.SpeechSource],
        audioSeconds: Double,
        limit: TimeInterval? = nil,
        reach: ((SetupRouting.SpeechSource, TimeInterval) async throws -> Void)? = nil,
        attempt: @escaping (SetupRouting.SpeechSource, TimeInterval) async throws -> T,
        onFallback: (SetupRouting.SpeechSource, Error) -> Void = { _, _ in }
    ) async throws -> (source: SetupRouting.SpeechSource, index: Int, value: T) {
        let allowance = limit ?? processingLimit(audioSeconds: audioSeconds)
        var last: Failure?
        var configurationFailure: Failure?
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            do {
                if let reach { try await reach(source, connectTimeout) }
                let value = try await withWatchdog(seconds: allowance) { try await attempt(source, allowance) }
                return (source, index, value)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = Failure(source: source, error: error)
                if configurationFailure == nil, DictationAlert.speechConfigurationFailure(error) != nil {
                    configurationFailure = last
                }
                if index < sources.count - 1 { onFallback(source, error) }
            }
        }
        if let failure = configurationFailure ?? last { throw failure }
        throw TranscriptionError.invalidResponse
    }

    /// Runs `work`, but stops waiting for it after `seconds` (throwing
    /// `SpeechChainError.stalled`). The work is cancelled; if it ignores
    /// cancellation it is simply no longer waited for.
    static func withWatchdog<T>(seconds: TimeInterval, _ work: @escaping () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let job = Task {
                    do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    if !Task.isCancelled { gate.finish(.failure(SpeechChainError.stalled)) }
                }
                gate.setCleanup { job.cancel(); timer.cancel() }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Lets exactly one of "work finished", "watchdog fired" or "cancelled" win.
    private final class Gate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?
        private var done = false
        private var onFinish: (() -> Void)?

        func setCleanup(_ cleanup: @escaping () -> Void) {
            lock.lock()
            if done { lock.unlock(); cleanup(); return }
            onFinish = cleanup
            lock.unlock()
        }

        func install(_ c: CheckedContinuation<T, Error>) {
            lock.lock()
            if let pending { lock.unlock(); c.resume(with: pending); return }
            continuation = c
            lock.unlock()
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = continuation
            continuation = nil
            if c == nil { pending = result }
            let cleanup = onFinish
            lock.unlock()
            c?.resume(with: result)
            cleanup?()
        }
    }
}
