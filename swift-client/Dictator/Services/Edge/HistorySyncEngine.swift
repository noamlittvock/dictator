import Foundation
import Observation

/// Keeps an Edge's local store converged with its Core.
///
/// Every Mac writes to its own store first (`LocalHistoryRepository.record`
/// leaves the row with `syncedAt == nil`; deletes and dictionary edits go to
/// `SyncOutbox`). While a `CoreSyncClient` is attached this engine:
///
/// 1. replays the outbox (deletes, dictionary edits) in order;
/// 2. applies and retains explicit deletion proofs before uploads, then
///    reconciles live history against the Core's `(id, timestamp)` manifest —
///    pending rows the Core already has are just marked synced, the rest
///    are uploaded with `historyUpsert` (idempotent by id), rows the Core
///    has that we don't are fetched and inserted as replicas, and rows we
///    hold as synced that the Core no longer has are deleted locally
///    (guarded by `shrinkGuard` so a wiped or wrong Core can never empty
///    this machine);
/// 3. mirrors the Core's aggregate stats and its whole dictionary.
///
/// A `repo.changed(.history)` from the Core walks the metadata manifest to
/// consume durable deletes, fetching only unknown live rows; any local
/// change runs a push. Failures back off and retry while attached; a
/// reconnect re-attaches and starts a full pass. The UI reads `status`/
/// `pendingCount` and can call `syncNow()`.
@MainActor
@Observable
final class HistorySyncEngine {
    enum Status: Equatable {
        /// Not an Edge (standalone or Core role): nothing to replicate to.
        case standalone
        /// Edge role, but no Core connection right now — writes queue up.
        case offline
        case syncing
        case synced
        case failed(String)
    }

    private(set) var status: Status = .standalone
    /// Rows written here that no Core has acknowledged, plus queued outbox
    /// mutations. Meaningful in every role (a standalone Mac that later
    /// pairs offers all of it), shown only for Edges.
    private(set) var pendingCount = 0
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    /// Last full-pass summary for the Computers tab.
    private(set) var lastSummary: String?

    /// Refuse to delete locally when the Core's manifest would remove more
    /// than this fraction of the rows this Mac holds as synced (and more
    /// than `shrinkGuardMinimum` rows). A Core whose store was replaced,
    /// wiped, or is simply the wrong machine must never cascade into this
    /// Mac's copy. Explicit durable deletion proofs are
    /// applied first and never inferred from a missing manifest row.
    static let shrinkGuardFraction = 0.25
    static let shrinkGuardMinimum = 50

    private static let uploadBatch = 200
    private static let fetchBatch = 100
    private static let outboxBatch = 100
    private static let retryDelays: [TimeInterval] = [3, 10, 30]

    private var repositories: Repositories
    private var client: CoreSyncClient?
    private var isEdge = false
    /// Bumped by every `attach`/`detach`/`setRepositories` so an in-flight
    /// pass that resumes after the world changed does nothing further.
    private var generation = 0
    private var passTask: Task<Void, Never>?
    private var wantsFull = false
    private var wantsIncremental = false
    private var wantsPush = false
    private var wantsDictionary = false
    private var consecutiveFailures = 0

    /// Test seam: how long to wait before retrying after a failure.
    var retryDelayOverride: TimeInterval?
    /// Test seam: observe each completed pass.
    var onPassCompleted: (() -> Void)?

    init(repositories: Repositories) {
        self.repositories = repositories
    }

    // MARK: - Wiring

    /// Called once the real on-disk bundle exists (the coordinator starts
    /// over an in-memory placeholder).
    func setRepositories(_ repositories: Repositories) {
        generation += 1
        passTask?.cancel()
        passTask = nil
        self.repositories = repositories
        repositories.outbox.enabled = isEdge
        Task { await refreshPendingCount() }
        if client != nil { requestFull() }
    }

    /// `true` in Edge role: the outbox starts queueing and `status` reads
    /// `.offline` until a client is attached.
    func setEdgeRole(_ isEdge: Bool) {
        self.isEdge = isEdge
        repositories.outbox.enabled = isEdge
        if !isEdge {
            detach()
            status = .standalone
        } else if client == nil {
            status = .offline
        }
        Task { await refreshPendingCount() }
    }

    func attach(client: CoreSyncClient) {
        generation += 1
        passTask?.cancel()
        passTask = nil
        self.client = client
        consecutiveFailures = 0
        lastError = nil
        status = .syncing
        SyncDiagnostics.log("engine: attached, full pass queued")
        requestFull()
    }

    func detach() {
        guard client != nil || passTask != nil else { return }
        generation += 1
        passTask?.cancel()
        passTask = nil
        client = nil
        status = isEdge ? .offline : .standalone
        SyncDiagnostics.log("engine: detached")
    }

    /// A `repo.changed` broadcast from the Core.
    func remoteChanged(_ change: RepoChange) {
        switch change {
        case .history: wantsIncremental = true
        case .dictionary: wantsDictionary = true
        case .settings: return
        }
        schedulePass()
    }

    /// Something changed in this Mac's own store (any domain).
    func localChanged() {
        Task { await refreshPendingCount() }
        wantsPush = true
        schedulePass()
    }

    /// "Sync Now": a full pass.
    func syncNow() {
        requestFull()
    }

    private func requestFull() {
        wantsFull = true
        schedulePass()
    }

    func refreshPendingCount() async {
        let entries = (try? await repositories.historySync.pendingCount()) ?? 0
        let outbox = (try? repositories.outbox.count()) ?? 0
        pendingCount = entries + outbox
    }

    // MARK: - Pass scheduling

    private func schedulePass(after delay: TimeInterval = 0) {
        guard client != nil, passTask == nil else { return }
        let myGeneration = generation
        passTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled, myGeneration == self.generation else { return }
            await self.runPasses(generation: myGeneration)
        }
    }

    private func runPasses(generation myGeneration: Int) async {
        defer { passTask = nil }
        while myGeneration == generation, let client, wantsFull || wantsIncremental || wantsPush || wantsDictionary {
            let full = wantsFull
            let incremental = wantsIncremental
            let dictionary = wantsDictionary
            let push = wantsPush
            wantsFull = false
            wantsIncremental = false
            wantsPush = false
            wantsDictionary = false
            status = .syncing
            do {
                if full {
                    try await fullPass(client: client, generation: myGeneration)
                } else {
                    try await drainOutbox(client: client, generation: myGeneration)
                    // Read explicit deletion proofs before uploads, so a stale
                    // pending copy cannot resurrect an intentionally deleted ID.
                    if incremental || push { try await incrementalPull(client: client, generation: myGeneration) }
                    try await pushPending(client: client, generation: myGeneration)
                    if incremental || push { try await mirrorStats(client: client, generation: myGeneration) }
                    if dictionary {
                        try await mirrorDictionary(client: client, generation: myGeneration)
                    }
                }
                guard myGeneration == generation else { return }
                consecutiveFailures = 0
                lastError = nil
                lastSyncAt = Date()
                status = .synced
                await refreshPendingCount()
                onPassCompleted?()
            } catch is CancellationError {
                return
            } catch {
                guard myGeneration == generation else { return }
                let message = error.localizedDescription
                lastError = message
                status = .failed(message)
                SyncDiagnostics.log("engine: pass failed: \(message)")
                onPassCompleted?()
                // Re-request what we were doing and back off before the
                // next attempt; a transport drop detaches us and stops this.
                wantsFull = wantsFull || full
                wantsIncremental = wantsIncremental || incremental
                wantsDictionary = wantsDictionary || dictionary
                wantsPush = true
                let delay = retryDelayOverride
                    ?? Self.retryDelays[min(consecutiveFailures, Self.retryDelays.count - 1)]
                consecutiveFailures += 1
                passTask = nil
                schedulePass(after: delay)
                return
            }
        }
    }

    // MARK: - Passes

    private func fullPass(client: CoreSyncClient, generation myGeneration: Int) async throws {
        try await drainOutbox(client: client, generation: myGeneration)

        var manifest = try await client.fullHistoryManifest()
        try checkGeneration(myGeneration)
        // Deletion intent exists even if this Mac was standalone when the
        // user deleted it, or an older main-store restore lost the proof.
        // Reconcile durable IDs, rather than relying only on an Edge outbox.
        let localProof = try await repositories.historySync.localDeletions()
        try checkGeneration(myGeneration)
        let remoteProofIDs = Set(manifest.filter { $0.deletedAt != nil }.map(\.id))
        let unshared = Set(localProof.map(\.id)).subtracting(remoteProofIDs)
        for batch in Array(unshared).chunked(RepoRequestLimits.maxIdsPerRequest) {
            try checkGeneration(myGeneration)
            try await client.replay(.historyDelete(ids: batch))
            try checkGeneration(myGeneration)
        }
        if !unshared.isEmpty {
            // The original snapshot may still contain the rows just deleted.
            // Refresh before matching pending rows or pulling live content.
            manifest = try await client.fullHistoryManifest()
            try checkGeneration(myGeneration)
        }
        let deletions = manifest.filter { $0.deletedAt != nil }
        var explicitlyRemoved = 0
        for batch in deletions.chunked(Self.fetchBatch) {
            explicitlyRemoved += try await repositories.historySync.existingIDs(ids: batch.map(\.id)).count
            try checkGeneration(myGeneration)
            try await repositories.historySync.applyDeletions(batch)
            try checkGeneration(myGeneration)
        }
        let deletedIDs = Set(deletions.map(\.id))
        let remote = manifest.filter { $0.deletedAt == nil && !deletedIDs.contains($0.id) }
        let local = try await repositories.historySync.localManifest()
        try checkGeneration(myGeneration)

        let remoteIds = Set(remote.map(\.id))
        let localIds = Set(local.map(\.item.id))
        let pendingIds = Set(local.filter(\.pending).map(\.item.id))

        // Pending rows the Core already holds (e.g. this store was cloned
        // from the Core's, or an earlier upload's ack was lost) need no
        // upload — just the bookkeeping.
        let alreadyThere = Array(pendingIds.intersection(remoteIds))
        if !alreadyThere.isEmpty {
            try await repositories.historySync.markSynced(ids: alreadyThere)
        }

        let uploaded = try await pushPending(client: client, generation: myGeneration)

        // Rows the Core has that we don't.
        let localEdited = Dictionary(uniqueKeysWithValues: local.filter { $0.item.hasEditedText == true }.map { ($0.item.id, $0.item.editedTextRevision ?? 0) })
        let missing = remote.filter { !localIds.contains($0.id) || ($0.hasEditedText == true && (localEdited[$0.id] == nil || ($0.editedTextRevision ?? 0) > (localEdited[$0.id] ?? 0))) }
        let fetched = try await pull(missing.map(\.id), client: client, generation: myGeneration)

        // Rows we hold as synced that the Core no longer has: deleted there.
        let syncedLocal = local.filter { !$0.pending }.map(\.item.id)
        let gone = syncedLocal.filter { !remoteIds.contains($0) }
        var deleted = explicitlyRemoved
        if !gone.isEmpty {
            let fraction = Double(gone.count) / Double(max(syncedLocal.count, 1))
            if gone.count > Self.shrinkGuardMinimum, fraction > Self.shrinkGuardFraction {
                let message = "Core has \(gone.count) fewer entries than this Mac (\(Int(fraction * 100))%) — not deleting locally. Check the Core's history."
                SyncDiagnostics.log("engine: shrink guard tripped: \(message)")
                throw RepositoryError.unavailable(message)
            }
            for batch in gone.chunked(Self.fetchBatch) {
                try checkGeneration(myGeneration)
                try await repositories.historySync.deleteReplicas(ids: batch)
                deleted += batch.count
            }
        }

        try await mirrorStats(client: client, generation: myGeneration)
        try await mirrorDictionary(client: client, generation: myGeneration)

        let summary = "Full sync: \(uploaded) uploaded, \(fetched) downloaded, \(deleted) removed, \(alreadyThere.count) matched."
        lastSummary = summary
        SyncDiagnostics.log("engine: \(summary) core=\(remote.count) local=\(local.count)")
    }

    private func incrementalPull(client: CoreSyncClient, generation myGeneration: Int) async throws {
        var unknown: [UUID] = []
        let local = try await repositories.historySync.localManifest()
        let localEdited = Dictionary(uniqueKeysWithValues: local.filter { $0.item.hasEditedText == true }.map { ($0.item.id, $0.item.editedTextRevision ?? 0) })
        var before: HistoryCursor?
        while true {
            let page = try await client.historyManifest(limit: RepoRequestLimits.manifestPageSize, before: before)
            try checkGeneration(myGeneration)
            guard let last = page.last else { break }
            let present = try await repositories.historySync.existingIDs(ids: page.map(\.id))
            let deletions = page.filter { $0.deletedAt != nil }
            try await repositories.historySync.applyDeletions(deletions)
            try checkGeneration(myGeneration)
            let newOnes = page.filter { $0.deletedAt == nil && (!present.contains($0.id) || ($0.hasEditedText == true && (localEdited[$0.id] == nil || ($0.editedTextRevision ?? 0) > (localEdited[$0.id] ?? 0)))) }.map(\.id)
            unknown.append(contentsOf: newOnes)
            // Walk every metadata page: imported/future-dated entries can
            // precede a new deletion marker even if this page is all known.
            // Only unknown live rows are fetched; history text is not scanned.
            before = last.cursor
        }
        let fetched = try await pull(unknown, client: client, generation: myGeneration)
        if fetched > 0 {
            SyncDiagnostics.log("engine: incremental pull fetched=\(fetched)")
        }
    }

    /// Uploads every pending row in batches; returns how many went up.
    @discardableResult
    private func pushPending(client: CoreSyncClient, generation myGeneration: Int) async throws -> Int {
        var uploaded = 0
        // One row that can't go up stays pending and is reported, but it must
        // not hold back everything newer than it.
        var skipped = Set<UUID>()
        var problem: String?
        while true {
            try checkGeneration(myGeneration)
            let batch = try await repositories.historySync.pendingSync(limit: Self.uploadBatch, excluding: skipped)
            guard !batch.isEmpty else { break }
            let invalid = batch.filter { $0.truncated == true || RepoServer.validateEntry($0) != nil }
            for row in invalid {
                let reason = row.truncated == true
                    ? "row was truncated by the local byte budget"
                    : (RepoServer.validateEntry(row) ?? "row failed Core validation")
                let message = "Cannot upload history row \(row.id): \(reason)"
                SyncDiagnostics.log("engine: \(message); leaving it pending")
                skipped.insert(row.id)
                problem = problem ?? message
            }
            let valid = batch.filter { !skipped.contains($0.id) }
            guard !valid.isEmpty else { continue }
            try await client.historyUpsert(valid)
            try checkGeneration(myGeneration)
            try await repositories.historySync.markSynced(ids: valid.map(\.id))
            uploaded += valid.count
        }
        if uploaded > 0 {
            SyncDiagnostics.log("engine: uploaded \(uploaded)")
        }
        await refreshPendingCount()
        if let problem { throw RepositoryError.unavailable(problem) }
        return uploaded
    }

    /// Fetches full rows for `ids` and inserts them as replicas; returns the
    /// number actually inserted.
    private func pull(_ ids: [UUID], client: CoreSyncClient, generation myGeneration: Int) async throws -> Int {
        var inserted = 0
        for batch in ids.chunked(Self.fetchBatch) {
            try checkGeneration(myGeneration)
            var remaining = batch
            // `historyFetch` is byte-budgeted, so a batch can come back
            // short; ask again for what's still missing until it's empty.
            while !remaining.isEmpty {
                let entries = try await client.historyFetch(ids: remaining)
                try checkGeneration(myGeneration)
                guard !entries.isEmpty else { break }
                // A row too big for one page arrives shortened. A replica
                // must never pass off part of a row as the whole of it.
                let whole = entries.filter { $0.truncated != true }
                if whole.count != entries.count {
                    SyncDiagnostics.log("engine: skipped \(entries.count - whole.count) row(s) too big to replicate")
                }
                inserted += try await repositories.historySync.insertMissing(whole, asReplica: true)
                let got = Set(entries.map(\.id))
                remaining.removeAll { got.contains($0) }
            }
        }
        return inserted
    }

    private func drainOutbox(client: CoreSyncClient, generation myGeneration: Int) async throws {
        while true {
            try checkGeneration(myGeneration)
            let items = try repositories.outbox.pending(limit: Self.outboxBatch)
            guard !items.isEmpty else { break }
            for item in items {
                try checkGeneration(myGeneration)
                do {
                    try await client.replay(item.request)
                    try repositories.outbox.remove(ids: [item.id])
                } catch RepositoryError.remote(let message) where message.hasPrefix("invalid request:") {
                    try repositories.outbox.markFailed(id: item.id, message: message)
                    SyncDiagnostics.log("engine: outbox item \(item.id) marked failed: \(message)")
                }
            }
            if items.count < Self.outboxBatch { break }
        }
        await refreshPendingCount()
    }

    private func mirrorStats(client: CoreSyncClient, generation myGeneration: Int) async throws {
        guard let stats = try await client.historyStats() else { return }
        try checkGeneration(myGeneration)
        try await repositories.historySync.replaceStats(stats)
    }

    private func mirrorDictionary(client: CoreSyncClient, generation myGeneration: Int) async throws {
        // Anything still queued locally would be overwritten by the Core's
        // copy — drain first so the mirror reflects our own edits.
        try await drainOutbox(client: client, generation: myGeneration)
        let entries = try await client.fullDictionary()
        try checkGeneration(myGeneration)
        try await repositories.dictionarySync.replaceAll(with: entries)
    }

    private func checkGeneration(_ myGeneration: Int) throws {
        if myGeneration != generation || Task.isCancelled {
            throw CancellationError()
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
