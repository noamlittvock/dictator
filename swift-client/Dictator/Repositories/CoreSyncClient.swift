import Foundation

/// What the sync engine and settings mirror need from the Edge↔Core
/// connection: send a request and get the matching result back.
/// `CoreConnection` implements this using `RepoRequestCorrelator` to match
/// `repo.response` frames back to the request that asked for them.
@MainActor protocol RepoTransport: AnyObject {
    /// Sends `request` and waits for the matching `repo.response`. Throws
    /// `RepositoryError.timeout` if none arrives in time, or
    /// `RepositoryError.unavailable` if the connection is gone.
    func send(_ request: RepoRequest) async throws -> RepoResult
}

/// Typed, one-request-per-method view of a Core over `RepoTransport` — the
/// Edge side of `RepoServer`. Nothing in the UI calls this; it exists for
/// `HistorySyncEngine` and `CoreSettingsMirror`.
@MainActor final class CoreSyncClient {
    private let transport: RepoTransport

    init(transport: RepoTransport) {
        self.transport = transport
    }

    // MARK: History

    func historyManifest(limit: Int, before: HistoryCursor?) async throws -> [HistoryManifestItem] {
        try unwrap(await transport.send(.historyManifest(limit: limit, before: before))) {
            if case .historyManifest(let items) = $0 { items } else { nil }
        }
    }

    /// The Core's whole manifest, newest first, walked page by page.
    func fullHistoryManifest() async throws -> [HistoryManifestItem] {
        var all: [HistoryManifestItem] = []
        var before: HistoryCursor?
        while true {
            let page = try await historyManifest(limit: RepoRequestLimits.manifestPageSize, before: before)
            guard let last = page.last else { break }
            all.append(contentsOf: page)
            before = last.cursor
        }
        return all
    }

    func historyFetch(ids: [UUID]) async throws -> [DictationEntryDTO] {
        try unwrap(await transport.send(.historyFetch(ids: ids))) {
            if case .historyPage(let entries) = $0 { entries } else { nil }
        }
    }

    func historyUpsert(_ entries: [DictationEntryDTO]) async throws {
        try expectOK(await transport.send(.historyUpsert(entries)))
    }

    func historyStats() async throws -> DictationStatsDTO? {
        try unwrap(await transport.send(.historyStats)) {
            if case .historyStats(let stats) = $0 { .some(stats) } else { nil }
        }
    }

    // MARK: Dictionary

    func dictionaryPage(limit: Int, afterPattern: String?, afterID: UUID? = nil) async throws -> [DictionaryEntryDTO] {
        try unwrap(await transport.send(.dictionaryPage(limit: limit, afterPattern: afterPattern, includeForgotten: true, afterID: afterID))) {
            if case .dictionaryPage(let entries) = $0 { entries } else { nil }
        }
    }

    func fullDictionary() async throws -> [DictionaryEntryDTO] {
        var all: [DictionaryEntryDTO] = []
        var after: String?
        var afterID: UUID?
        while true {
            let page = try await dictionaryPage(limit: RepoRequestLimits.dictionaryPageSize, afterPattern: after, afterID: afterID)
            guard let last = page.last else { break }
            all.append(contentsOf: page)
            after = last.pattern
            afterID = last.id
        }
        return all
    }

    func learnCorrection(_ report: CorrectionReport) async throws -> CorrectionOutcome? {
        let result = try await transport.send(.correction(report))
        if case .correctionOutcome(let outcome) = result { return outcome }
        try expectOK(result)
        return nil // Older main Mac acknowledged receipt, without a save outcome.
    }

    // MARK: Outbox replay / settings

    /// Replays one queued outbox mutation (a history delete or a dictionary
    /// upsert/delete) verbatim.
    func replay(_ request: RepoRequest) async throws {
        try expectOK(await transport.send(request))
    }

    func settingsGet() async throws -> CoreSettingsDTO {
        try unwrap(await transport.send(.settingsGet)) {
            if case .settings(let settings) = $0 { settings } else { nil }
        }
    }

    func settingsSet(_ patch: CoreSettingsPatch) async throws {
        try expectOK(await transport.send(.settingsSet(patch)))
    }

    // MARK: Result mapping

    /// Turns a `RepoResult.error` into `RepositoryError.remote`, and any other
    /// mismatch between what was asked and what came back into the same — a
    /// well-behaved `RepoServer` never sends a mismatched result, so this is
    /// a defensive fallback, not an expected path.
    private func expectOK(_ result: RepoResult) throws {
        switch result {
        case .ok, .correctionOutcome:
            return
        case .error(let message):
            throw RepositoryError.remote(message)
        default:
            throw RepositoryError.remote("Your main Mac sent an answer Dictator couldn’t read.")
        }
    }

    private func unwrap<T>(_ result: RepoResult, as extract: (RepoResult) -> T?) throws -> T {
        if case .error(let message) = result {
            throw RepositoryError.remote(message)
        }
        guard let value = extract(result) else {
            throw RepositoryError.remote("Your main Mac sent an answer Dictator couldn’t read.")
        }
        return value
    }
}

/// `CoreSettingsRepository` over a `CoreSyncClient` — what `CoreSettingsMirror`
/// talks to while connected.
@MainActor final class RemoteCoreSettingsRepository: CoreSettingsRepository {
    private let client: CoreSyncClient
    var onChange: (() -> Void)?

    init(client: CoreSyncClient) {
        self.client = client
    }

    func get() async throws -> CoreSettingsDTO {
        try await client.settingsGet()
    }

    func set(_ patch: CoreSettingsPatch) async throws {
        try await client.settingsSet(patch)
    }
}

/// Correlates a single connection's `RepoRequest`/`repo.response` round-trips:
/// `begin()` mints a fresh `requestId` and a `Task` that resolves the moment
/// `complete(requestId:result:)` is called with a match, or throws
/// `RepositoryError.timeout` after `timeout` seconds with no reply.
/// `CoreConnection` calls `complete` from its `onMessage` handler when a
/// `.repoResponse` arrives.
@MainActor final class RepoRequestCorrelator {
    /// `begin()` reserves `id` in `slots` synchronously, before it returns —
    /// not only once the returned `Task` gets around to awaiting it. Without
    /// this, a caller that sends its request frame right after `begin()`
    /// could race a fast reply's `complete()` against a continuation that
    /// hasn't been registered yet and lose it until timeout. `.early`/
    /// `.timedOut`/`.failed` are what let `complete()`/the timeout land on a
    /// slot nothing is awaiting yet without that being lost.
    private enum Slot {
        case reserved
        case waiting(CheckedContinuation<RepoResult, Error>)
        case early(RepoResult)
        case timedOut
        case failed(Error)
    }

    private var slots: [String: Slot] = [:]
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    func begin() -> (id: String, result: Task<RepoResult, Error>) {
        let id = UUID().uuidString
        slots[id] = .reserved
        scheduleTimeout(id: id)
        let task = Task<RepoResult, Error> { [weak self] in
            guard let self else { throw RepositoryError.timeout }
            return try await self.awaitResult(id: id)
        }
        return (id, task)
    }

    /// Resolves the pending `begin()` for `requestId`, if any — an unknown
    /// id (never issued, or already resolved/timed out) is silently ignored.
    func complete(requestId: String, result: RepoResult) {
        switch slots[requestId] {
        case .waiting(let continuation):
            slots[requestId] = nil
            continuation.resume(returning: result)
        case .reserved:
            slots[requestId] = .early(result)
        case .early, .timedOut, .failed, .none:
            break
        }
    }

    /// Fails every currently pending request — used by `CoreConnection`
    /// when the underlying transport drops, so a caller `await`ing
    /// `RepoTransport.send(_:)` doesn't have to wait out the full timeout to
    /// learn the Core is gone.
    func failAll(with error: Error) {
        for (id, slot) in slots {
            switch slot {
            case .waiting(let continuation):
                slots[id] = nil
                continuation.resume(throwing: error)
            case .reserved:
                slots[id] = .failed(error)
            case .early, .timedOut, .failed:
                break
            }
        }
    }

    private func awaitResult(id: String) async throws -> RepoResult {
        switch slots[id] {
        case .early(let result):
            slots[id] = nil
            return result
        case .timedOut:
            slots[id] = nil
            throw RepositoryError.timeout
        case .failed(let error):
            slots[id] = nil
            throw error
        case .reserved, .none:
            return try await withCheckedThrowingContinuation { continuation in
                slots[id] = .waiting(continuation)
            }
        case .waiting:
            preconditionFailure("RepoRequestCorrelator.awaitResult(id:) called twice for \(id)")
        }
    }

    private func scheduleTimeout(id: String) {
        let seconds = timeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self else { return }
            switch self.slots[id] {
            case .waiting(let continuation):
                self.slots[id] = nil
                continuation.resume(throwing: RepositoryError.timeout)
            case .reserved:
                self.slots[id] = .timedOut
            case .early, .timedOut, .failed, .none:
                break
            }
        }
    }
}
