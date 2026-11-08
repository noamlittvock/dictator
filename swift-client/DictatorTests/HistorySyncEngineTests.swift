import Observation
import SwiftData
import XCTest
@testable import Dictator

/// Drives `HistorySyncEngine` end to end with two real local stores — one
/// playing the Edge, one the Core — joined by an in-process transport that
/// hands every `RepoRequest` to a `RepoServer` over the Core's store. No
/// sockets; the transport can be made to fail or go away to model the
/// network.
@MainActor
final class HistorySyncEngineTests: XCTestCase {
    /// `RepoTransport` over a `RepoServer`: what `CoreConnection` does with
    /// a live socket, minus the socket.
    private final class LoopbackTransport: RepoTransport {
        let server: RepoServer
        var failing = false
        var remoteFailureMessage: String?
        var legacyManifest: [HistoryManifestItem]?
        private(set) var requests: [RepoRequest] = []

        init(server: RepoServer) {
            self.server = server
        }

        func send(_ submitted: RepoRequest) async throws -> RepoResult {
            // Include the protocol's default JSON date coding, not just
            // in-memory values, so manifest cursors exercise wire precision.
            let request = try JSONDecoder().decode(RepoRequest.self, from: JSONEncoder().encode(submitted))
            requests.append(request)
            if failing { throw RepositoryError.unavailable("Core connection lost") }
            if let remoteFailureMessage { throw RepositoryError.remote(remoteFailureMessage) }
            if let legacyManifest, case .historyManifest(let limit, let before) = request {
                let ordered = legacyManifest.sorted {
                    if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                    return $0.id.uuidString > $1.id.uuidString
                }
                return .historyManifest(Array(ordered.filter { item in
                    guard let before else { return true }
                    return item.timestamp < before.timestamp || (item.timestamp == before.timestamp && item.id.uuidString < before.id.uuidString)
                }.prefix(limit)))
            }
            let result = await server.handle(request)
            return try JSONDecoder().decode(RepoResult.self, from: JSONEncoder().encode(result))
        }

        func count(where predicate: (RepoRequest) -> Bool) -> Int {
            requests.filter(predicate).count
        }
    }

    private var tempRoots: [URL] = []
    private var storeRoots: [ObjectIdentifier: URL] = [:]
    private var edge: Repositories!
    private var core: Repositories!
    private var transport: LoopbackTransport!
    private var engine: HistorySyncEngine!

    private var savedPersistHistory = false
    private var savedSurfacePolicyJSON = ""

    override func setUp() async throws {
        try await super.setUp()
        edge = try makeStore()
        core = try makeStore()
        transport = LoopbackTransport(server: RepoServer(repositories: core))
        engine = HistorySyncEngine(repositories: edge)
        engine.retryDelayOverride = 0.05
        engine.setEdgeRole(true)

        let settings = AppSettings.shared
        savedPersistHistory = settings.persistHistory
        savedSurfacePolicyJSON = settings.cachedSurfacePolicyJSON
        settings.persistHistory = true
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "save", defaultVoice: "save", rules: []))
    }

    override func tearDown() async throws {
        engine.detach()
        let settings = AppSettings.shared
        settings.persistHistory = savedPersistHistory
        settings.cachedSurfacePolicyJSON = savedSurfacePolicyJSON
        let owners = [WeakTestStoreOwner(engine), WeakTestStoreOwner(transport),
                      WeakTestStoreOwner(edge), WeakTestStoreOwner(core)]
        autoreleasepool {
            engine = nil
            transport = nil
            edge = nil
            core = nil
        }
        // A cancelled pass may still own the engine until its await resumes.
        try await TestStoreTeardown.remove(tempRoots, afterReleasing: owners)
        tempRoots.removeAll()
        storeRoots.removeAll()
        try await super.tearDown()
    }

    private func makeStore() throws -> Repositories {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dictator-HistorySyncEngineTests-\(UUID().uuidString)", isDirectory: true
        )
        tempRoots.append(root)
        let result = PersistenceLoader.load(applicationSupport: root)
        let repositories = Repositories.make(container: try XCTUnwrap(result.container))
        storeRoots[ObjectIdentifier(repositories)] = root
        return repositories
    }

    private func reopen(_ repositories: Repositories) throws -> Repositories {
        let root = try XCTUnwrap(storeRoots[ObjectIdentifier(repositories)])
        let loaded = PersistenceLoader.load(applicationSupport: root)
        XCTAssertNil(loaded.warning)
        let reopened = Repositories.make(container: try XCTUnwrap(loaded.container))
        storeRoots[ObjectIdentifier(reopened)] = root
        return reopened
    }

    private func record(_ repos: Repositories, _ text: String, modality: String = "voice") async throws {
        try await repos.history.record(HistoryRecordDTO(text: text, durationSeconds: 1, modality: modality, source: "dictator"))
        try await Task.sleep(nanoseconds: 2_000_000)
    }

    private func texts(_ repos: Repositories) async throws -> Set<String> {
        Set(try await repos.history.allEntries().map(\.text))
    }

    /// Waits for the engine to finish a pass (or several) and settle.
    private func settle(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        var passes = 0
        engine.onPassCompleted = { passes += 1 }
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if passes > 0, engine.status != .syncing {
                // one more tick to let a queued follow-up pass run
                try? await Task.sleep(nanoseconds: 50_000_000)
                if engine.status != .syncing { return }
            }
        }
        XCTFail("engine never settled (status \(engine.status))")
    }

    // MARK: - Convergence

    func testAttachUploadsPendingAndPullsWhatTheCoreHas() async throws {
        try await record(edge, "typed on the edge while offline")
        try await record(core, "spoken at the core")
        XCTAssertEqual(engine.status, .offline)
        await engine.refreshPendingCount()
        XCTAssertEqual(engine.pendingCount, 1)

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        XCTAssertEqual(engine.status, .synced)
        XCTAssertEqual(engine.pendingCount, 0)
        let value1 = try await texts(edge)
        XCTAssertEqual(value1, ["typed on the edge while offline", "spoken at the core"])
        let value2 = try await texts(core)
        XCTAssertEqual(value2, ["typed on the edge while offline", "spoken at the core"])

        // Same ids on both sides — this is replication, not a copy.
        let edgeIds = Set(try await edge.history.allEntries().map(\.id))
        let coreIds = Set(try await core.history.allEntries().map(\.id))
        XCTAssertEqual(edgeIds, coreIds)

        // The upload counted once, on the Core; the Edge mirrors the Core's stats.
        let coreStats = try await core.history.stats()
        XCTAssertEqual(coreStats?.totalDictations, 2)
        let value3 = try await edge.history.stats()
        XCTAssertEqual(value3, coreStats)
        XCTAssertNotNil(engine.lastSyncAt)
        XCTAssertEqual(engine.lastSummary, "Full sync: 1 uploaded, 1 downloaded, 0 removed, 0 matched.")
    }

    func testClonedStoreIsMatchedWithoutUploading() async throws {
        // The MacBook's store was cloned onto the mini: both hold the same
        // rows by id, and the Edge's copies have never been "synced".
        try await record(edge, "shared row")
        let rows = try await edge.history.allEntries()
        _ = try await core.historySync.insertMissing(rows, asReplica: true)

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(transport.count { if case .historyUpsert = $0 { true } else { false } }, 0, "nothing to upload")
        XCTAssertEqual(engine.lastSummary, "Full sync: 0 uploaded, 0 downloaded, 0 removed, 1 matched.")
        let value4 = try await edge.history.allEntries().first?.syncedAt != nil
        XCTAssertEqual(value4, true)
    }

    func testLocalWriteWhileConnectedIsPushedAndRemoteChangeIsPulled() async throws {
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        try await record(edge, "new on the edge")
        engine.localChanged()
        await settle()
        let value5 = try await texts(core)
        XCTAssertEqual(value5, ["new on the edge"])
        XCTAssertEqual(engine.pendingCount, 0)

        try await record(core, "new on the core")
        engine.remoteChanged(.history)
        await settle()
        let value6 = try await texts(edge)
        XCTAssertEqual(value6, ["new on the edge", "new on the core"])
        // Incremental: no full manifest walk was needed for that pull.
        XCTAssertEqual(transport.count { if case .historyFetch = $0 { true } else { false } }, 1)
    }

    func testPendingUploadContinuesAcrossShortByteBudgetedBatches() async throws {
        let longText = String(repeating: "u", count: 120_000)
        for index in 0..<3 {
            try await record(edge, "\(index)-\(longText)")
        }

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        XCTAssertEqual(engine.status, .synced)
        XCTAssertEqual(engine.pendingCount, 0)
        let coreCount = try await core.history.allEntries().count
        XCTAssertEqual(coreCount, 3)
        XCTAssertEqual(transport.count { if case .historyUpsert = $0 { true } else { false } }, 3)
    }

    func testRowTooBigForOnePageIsNotStoredShortened() async throws {
        let whole = String(repeating: "t", count: 100_000)
        try await core.historySync.insertMissing([DictationEntryDTO(
            id: UUID(), timestamp: Date(), text: whole, durationSeconds: 1, inferenceMs: nil, wordCount: 1,
            modality: "voice", source: "dictator", destinationAppBundleId: nil, destinationAppName: nil,
            destinationURL: nil, insertionMethod: nil, heardText: whole, editedText: whole
        )], asReplica: false)
        try await record(core, "small enough")

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        let replicated = try await texts(edge)
        XCTAssertEqual(replicated, ["small enough"], "the rest still arrives; no partial copy stands in for the row")
    }

    func testOneRowThatCannotGoUpDoesNotHoldBackNewerOnes() async throws {
        try await record(edge, String(repeating: "t", count: 300_000))
        try await record(edge, "newer one")
        try await record(edge, "newest one")

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        let uploaded = try await texts(core)
        XCTAssertEqual(uploaded, ["newer one", "newest one"])
        XCTAssertEqual(engine.pendingCount, 1)
        guard case .failed = engine.status else { return XCTFail("expected the stuck row to be reported, got \(engine.status)") }
    }

    func testTruncatedPendingRowStaysPending() async throws {
        try await record(edge, String(repeating: "t", count: 300_000))

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        guard case .failed(let message) = engine.status else {
            return XCTFail("expected .failed, got \(engine.status)")
        }
        XCTAssertTrue(message.contains("truncated"), message)
        XCTAssertEqual(engine.pendingCount, 1)
        let coreEntries = try await core.history.allEntries()
        XCTAssertTrue(coreEntries.isEmpty)
    }

    func testRemoteOutboxValidationFailureDoesNotBlockLaterItem() async throws {
        let invalid = DictionaryEntryDTO(
            id: UUID(), pattern: String(repeating: "x", count: 513), replacement: "bad", isVocabulary: false
        )
        let valid = DictionaryEntryDTO(
            id: UUID(), pattern: "works", replacement: "Works", isVocabulary: true
        )
        try await edge.dictionary.upsert([invalid])
        try await edge.dictionary.upsert([valid])

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        XCTAssertEqual(engine.status, .synced)
        XCTAssertEqual(try edge.outbox.count(), 0, "failed remote items are no longer retryable")
        let corePatterns = try await core.dictionary.entries().map(\.pattern)
        XCTAssertEqual(corePatterns, ["works"])
    }

    func testRemoteOutboxNonValidationFailureRemainsRetryable() async throws {
        let entry = DictionaryEntryDTO(
            id: UUID(), pattern: "retry", replacement: "Retry", isVocabulary: false
        )
        try await edge.dictionary.upsert([entry])
        transport.remoteFailureMessage = "repository busy"

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        guard case .failed = engine.status else {
            return XCTFail("expected .failed, got \(engine.status)")
        }
        XCTAssertEqual(try edge.outbox.count(), 1, "non-validation remote failures remain retryable")

        transport.remoteFailureMessage = nil
        await settle()

        XCTAssertEqual(engine.status, .synced)
        XCTAssertEqual(try edge.outbox.count(), 0)
        let retryPatterns = try await core.dictionary.entries().map(\.pattern)
        XCTAssertEqual(retryPatterns, ["retry"])
    }

    // MARK: - Deletes

    func testEdgeDeleteReplaysToTheCoreAndCoreDeleteIsMirrored() async throws {
        try await record(edge, "edge deletes this later")
        try await record(edge, "core deletes this later")
        try await record(edge, "stays")
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let value7 = try await texts(core)
        XCTAssertEqual(value7, ["edge deletes this later", "core deletes this later", "stays"])

        // Edge-side delete → outbox → Core.
        let all = try await edge.history.allEntries()
        let edgeDeleted = try XCTUnwrap(all.first { $0.text == "edge deletes this later" }?.id)
        try await edge.history.delete(ids: [edgeDeleted])
        engine.localChanged()
        await settle()
        let value8 = try await texts(core)
        XCTAssertEqual(value8, ["core deletes this later", "stays"])
        XCTAssertEqual(try edge.outbox.count(), 0)

        // Core-side delete → next full pass removes it here.
        let coreDeleted = try XCTUnwrap(all.first { $0.text == "core deletes this later" }?.id)
        try await core.history.delete(ids: [coreDeleted])
        engine.syncNow()
        await settle()
        let value9 = try await texts(edge)
        XCTAssertEqual(value9, ["stays"])
    }

    func testExplicitBulkDeletePropagatesIncrementallyBeyondShrinkGuard() async throws {
        for index in 0..<100 { try await record(core, "bulk row \(index)") }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let entries = try await core.history.allEntries()
        try await core.history.delete(ids: Array(entries.prefix(60).map(\.id)))
        engine.remoteChanged(.history)
        await settle()
        XCTAssertEqual(engine.status, .synced)
        let remaining = try await texts(edge)
        let mainRemaining = try await texts(core)
        XCTAssertEqual(remaining, mainRemaining)
        XCTAssertEqual(remaining.count, 40)
        XCTAssertEqual(try edge.outbox.count(), 0, "received proof never echoes a delete")
    }

    func testOfflineDeletionSurvivesBothStoreReopensAndFullSync() async throws {
        for index in 0..<60 { try await record(edge, "offline delete \(index)") }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        engine.detach()
        let ids = try await edge.history.allEntries().map(\.id)
        try await edge.history.delete(ids: ids)
        edge = try reopen(edge)
        core = try reopen(core)
        transport = LoopbackTransport(server: RepoServer(repositories: core))
        engine.setRepositories(edge)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        XCTAssertEqual(engine.status, .synced)
        let coreRows = try await core.history.allEntries()
        XCTAssertTrue(coreRows.isEmpty)
        XCTAssertEqual(try edge.outbox.count(), 0)
        // A second peer that was offline throughout consumes durable intent,
        // even after the main Mac's repository is reconstructed again.
        let oldPeer = try makeStore()
        let snapshots = ids.map { id in DictationEntryDTO(id: id, timestamp: Date(), text: "stale copy", durationSeconds: 1, inferenceMs: nil, wordCount: 2, modality: "voice", source: "dictator", destinationAppBundleId: nil, destinationAppName: nil, destinationURL: nil, insertionMethod: nil) }
        _ = try await oldPeer.historySync.insertMissing(snapshots, asReplica: true)
        core = try reopen(core)
        engine.detach()
        engine.setRepositories(oldPeer)
        engine.attach(client: CoreSyncClient(transport: LoopbackTransport(server: RepoServer(repositories: core))))
        await settle()
        XCTAssertEqual(engine.status, .synced)
        let oldPeerRows = try await oldPeer.history.allEntries()
        XCTAssertTrue(oldPeerRows.isEmpty)
    }

    func testDeletionProofPreventsStaleUploadAndStaleLocalReinsertion() async throws {
        try await record(core, "deleted while another Mac was offline")
        let beforeDeletion = try await core.history.allEntries()
        let stale = try XCTUnwrap(beforeDeletion.first)
        try await core.history.delete(ids: [stale.id])
        core = try reopen(core)
        let server = RepoServer(repositories: core)
        let replay = await server.handle(.historyUpsert([stale]))
        XCTAssertEqual(replay, .ok, "stale retries are harmless and idempotent")
        let coreRows = try await core.history.allEntries()
        XCTAssertTrue(coreRows.isEmpty)
        // Simulate an old pending local upload, not merely a synced replica.
        let pending = DictationEntry(text: stale.text, durationSeconds: 1)
        pending.id = stale.id
        let root = try XCTUnwrap(storeRoots[ObjectIdentifier(edge)])
        let loaded = PersistenceLoader.load(applicationSupport: root)
        let context = ModelContext(try XCTUnwrap(loaded.container))
        context.insert(pending)
        try context.save()
        engine.attach(client: CoreSyncClient(transport: LoopbackTransport(server: server)))
        await settle()
        XCTAssertEqual(engine.status, .synced)
        XCTAssertEqual(engine.pendingCount, 0)
        let edgeRows = try await edge.history.allEntries()
        XCTAssertTrue(edgeRows.isEmpty)
        let reinserted = try await edge.historySync.insertMissing([stale], asReplica: true)
        XCTAssertEqual(reinserted, 0, "local deletion proof blocks stale pulls too")
    }

    func testConnectedPushConsumesDeletionProofBeforeUploadingStalePendingRow() async throws {
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        try await record(edge, "stale pending copy")
        let rows = try await edge.history.allEntries()
        let stale = try XCTUnwrap(rows.first)
        // The main Mac knows the explicit delete even if this stale upload
        // has never reached it. No remoteChanged callback is needed here.
        try await core.history.delete(ids: [stale.id])
        engine.localChanged()
        await settle()
        XCTAssertEqual(engine.status, .synced)
        XCTAssertEqual(engine.pendingCount, 0)
        let remaining = try await edge.history.allEntries()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(transport.count { if case .historyUpsert = $0 { true } else { false } }, 0)
    }

    func testExplicitProofDoesNotDisableWipeProtectionForOtherRows() async throws {
        for index in 0..<100 { try await record(edge, "protected row \(index)") }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let rows = try await core.history.allEntries()
        let wiped = try makeStore()
        // An explicit deletion authorizes only these IDs, not every missing ID.
        try await wiped.history.delete(ids: Array(rows.prefix(20).map(\.id)))
        engine.detach()
        engine.attach(client: CoreSyncClient(transport: LoopbackTransport(server: RepoServer(repositories: wiped))))
        await settle()
        guard case .failed = engine.status else { return XCTFail("unconfirmed loss must still trip the wipe guard") }
        let kept = try await edge.history.allEntries()
        XCTAssertEqual(kept.count, 80)
    }

    func testLegacyMainWithoutDeletionProofKeepsTheWipeGuard() async throws {
        for index in 0..<100 { try await record(core, "legacy row \(index)") }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        engine.detach()
        let rows = try await core.history.allEntries()
        try await core.history.delete(ids: Array(rows.prefix(60).map(\.id)))
        // An older main Mac's wire manifest has only live rows, no proof.
        transport.legacyManifest = try await core.historySync.localManifest().map(\.item)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        guard case .failed = engine.status else { return XCTFail("legacy disappearance must not bypass the guard") }
        let retained = try await edge.history.allEntries()
        XCTAssertEqual(retained.count, 100)
    }

    func testDeletionAfterKnownFutureDatedPageStillPropagates() async throws {
        let root = try XCTUnwrap(storeRoots[ObjectIdentifier(core)])
        let loaded = PersistenceLoader.load(applicationSupport: root)
        let context = ModelContext(try XCTUnwrap(loaded.container))
        let future = Date().addingTimeInterval(86_400)
        for index in 0...RepoRequestLimits.manifestPageSize {
            let row = DictationEntry(text: "future row \(index)", durationSeconds: 1)
            row.timestamp = future
            context.insert(row)
        }
        let deleted = DictationEntry(text: "older row deleted now", durationSeconds: 1)
        context.insert(deleted)
        let deletedID = deleted.id
        try context.save()
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle(timeout: 15)
        try await core.history.delete(ids: [deletedID])
        engine.remoteChanged(.history)
        await settle(timeout: 15)
        XCTAssertEqual(engine.status, .synced)
        let retained = try await edge.historySync.existingIDs(ids: [deletedID])
        XCTAssertTrue(retained.isEmpty, "an all-known future-dated page must not hide later deletion proof")
    }

    func testStandaloneBulkDeletionReconcilesOnRoleChangeAndIsNotReplayedAfterAck() async throws {
        for index in 0..<100 { try await record(core, "role transition row \(index)") }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        engine.setEdgeRole(false)
        let rows = try await edge.history.allEntries()
        let deleted = Array(rows.prefix(60).map(\.id))
        try await edge.history.delete(ids: deleted)
        XCTAssertEqual(try edge.outbox.count(), 0, "standalone deletes have no Edge outbox")
        edge = try reopen(edge)
        engine.setRepositories(edge)
        engine.setEdgeRole(true)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        XCTAssertEqual(engine.status, .synced)
        let mainRows = try await core.history.allEntries()
        let localRows = try await edge.history.allEntries()
        XCTAssertEqual(mainRows.count, 40)
        XCTAssertEqual(Set(mainRows.map(\.id)), Set(localRows.map(\.id)))
        let requests = transport.count { if case .historyDelete = $0 { true } else { false } }
        XCTAssertEqual(requests, 1)
        engine.syncNow()
        await settle()
        XCTAssertEqual(transport.count { if case .historyDelete = $0 { true } else { false } }, requests, "acknowledged proof is not uploaded again")
    }

    func testLocalProofUploadDoesNotAuthorizeUnrelatedLossOnAWipedMain() async throws {
        for index in 0..<100 { try await record(core, "retained local row \(index)") }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        engine.setEdgeRole(false)
        let rows = try await edge.history.allEntries()
        let deleted = Array(rows.prefix(20).map(\.id))
        try await edge.history.delete(ids: deleted)
        let wiped = try makeStore()
        transport = LoopbackTransport(server: RepoServer(repositories: wiped))
        engine.setEdgeRole(true)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        guard case .failed = engine.status else { return XCTFail("local intent must not bypass the wipe guard for unrelated IDs") }
        let retained = try await edge.history.allEntries()
        XCTAssertEqual(retained.count, 80)
        let sharedProof = try await wiped.historySync.deletionIDs(ids: deleted)
        XCTAssertEqual(sharedProof, Set(deleted))
    }

    func testStandaloneDeletionProofUploadsInBoundedBatches() async throws {
        engine.setEdgeRole(false)
        let ids = (0..<501).map { _ in UUID() }
        try await edge.history.delete(ids: ids)
        XCTAssertEqual(try edge.outbox.count(), 0)
        engine.setEdgeRole(true)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        XCTAssertEqual(engine.status, .synced)
        let batches = transport.requests.compactMap { request -> [UUID]? in
            if case .historyDelete(let ids) = request { return ids }
            return nil
        }
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { $0.count <= RepoRequestLimits.maxIdsPerRequest })
        XCTAssertEqual(Set(batches.flatMap { $0 }), Set(ids))
        let shared = try await core.historySync.deletionIDs(ids: ids)
        XCTAssertEqual(shared, Set(ids))
    }

    func testShrinkGuardRefusesToMirrorAWipedCore() async throws {
        for i in 0..<60 {
            try await record(edge, "row \(i)")
        }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let value10 = try await core.history.allEntries().count
        XCTAssertEqual(value10, 60)

        // The Core's store is replaced by an empty one (wrong machine, wipe, restore gone bad).
        let wiped = try makeStore()
        transport = LoopbackTransport(server: RepoServer(repositories: wiped))
        engine.detach()
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        guard case .failed(let message) = engine.status else {
            return XCTFail("expected .failed, got \(engine.status)")
        }
        XCTAssertTrue(message.contains("not deleting locally"), message)
        let value11 = try await edge.history.allEntries().count
        XCTAssertEqual(value11, 60, "nothing may be deleted locally")
    }

    // MARK: - Offline / failure

    func testOfflineWritesQueueAndFlushOnReconnect() async throws {
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        engine.detach()
        XCTAssertEqual(engine.status, .offline)

        try await record(edge, "written while the core was away")
        engine.localChanged()
        await engine.refreshPendingCount()
        XCTAssertEqual(engine.pendingCount, 1)
        let value12 = try await texts(core).isEmpty
        XCTAssertTrue(value12)

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        XCTAssertEqual(engine.pendingCount, 0)
        let value13 = try await texts(core)
        XCTAssertEqual(value13, ["written while the core was away"])
    }

    func testFailedPassRetriesAndRecovers() async throws {
        try await record(edge, "eventually")
        transport.failing = true
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        guard case .failed = engine.status else {
            return XCTFail("expected .failed, got \(engine.status)")
        }
        XCTAssertEqual(engine.pendingCount, 1)

        transport.failing = false
        await settle(timeout: 5)
        XCTAssertEqual(engine.status, .synced)
        let value14 = try await texts(core)
        XCTAssertEqual(value14, ["eventually"])
    }

    // MARK: - Dictionary & settings mirror

    func testSyncedDictionaryProducesTheSameSpellingsOnBothMacs() async throws {
        try await core.dictionary.upsert([
            DictionaryEntryDTO(id: UUID(), pattern: "GitHub", replacement: "", isVocabulary: true),
        ])
        try await edge.dictionary.upsert([
            DictionaryEntryDTO(id: UUID(), pattern: "norm", replacement: "Noam", isVocabulary: false),
        ])
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        for repositories in [core!, edge!] {
            let dictionary = try await repositories.dictionary.entries().map { ["pattern": $0.pattern, "replacement": $0.replacement] }
            let text = await TextFinisher.finish("send github to norm, not normal", dictionary: dictionary, cleanUp: nil)
            XCTAssertEqual(text, "send GitHub to Noam, not normal")
        }
    }

    func testDictionaryConvergesBothWays() async throws {
        let coreEntry = DictionaryEntryDTO(id: UUID(), pattern: "kubernetes", replacement: "Kubernetes", isVocabulary: true)
        try await core.dictionary.upsert([coreEntry])
        let edgeEntry = DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false)
        try await edge.dictionary.upsert([edgeEntry]) // queued: outbox is enabled in Edge role

        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()

        let edgePatterns = Set(try await edge.dictionary.entries().map(\.pattern))
        let corePatterns = Set(try await core.dictionary.entries().map(\.pattern))
        XCTAssertEqual(edgePatterns, ["kubernetes", "teh"])
        XCTAssertEqual(corePatterns, ["kubernetes", "teh"])

        try await core.dictionary.delete(ids: [coreEntry.id])
        engine.remoteChanged(.dictionary)
        await settle()
        let value15 = try await edge.dictionary.entries().map(\.pattern)
        XCTAssertEqual(value15, ["teh"])
    }



    func testMirrorAppliedDictionaryChangeDoesNotRequestHistoryPushPass() async throws {
        let hub = RepositoryHub(current: edge)
        withObservationTracking {
            _ = hub.dictionaryLocalVersion
        } onChange: { [weak self] in
            Task { @MainActor in self?.engine.localChanged() }
        }
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let historyRequests = transport.count { if case .historyManifest = $0 { return true }; return false }
        try await core.dictionary.upsert([.init(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)])
        engine.remoteChanged(.dictionary)
        await settle()
        XCTAssertEqual(hub.dictionaryVersion, 1)
        XCTAssertEqual(hub.dictionaryLocalVersion, 0)
        XCTAssertEqual(transport.count { if case .historyManifest = $0 { return true }; return false }, historyRequests)
    }

    func testModernMirrorOptsIntoForgottenRowsAndKeepsThemLocally() async throws {
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true, origin: "learned", isForgotten: true)
        try await core.dictionary.upsert([row])
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let rows = try await edge.dictionary.entries()
        XCTAssertEqual(rows.first?.isForgotten, true)
        let pageRequests = transport.requests.filter { if case .dictionaryPage = $0 { return true }; return false }
        XCTAssertFalse(pageRequests.isEmpty)
        XCTAssertTrue(pageRequests.allSatisfy {
            if case .dictionaryPage(_, _, let includeForgotten, _) = $0 { return includeForgotten == true }
            return false
        })
    }

    func testStandaloneRoleNeverQueuesOrSyncs() async throws {
        engine.setEdgeRole(false)
        XCTAssertEqual(engine.status, .standalone)
        XCTAssertFalse(edge.outbox.enabled)
        try await record(edge, "local only")
        try await edge.history.delete(ids: try await edge.history.allEntries().map(\.id))
        XCTAssertEqual(try edge.outbox.count(), 0)
    }
}

extension HistorySyncEngineTests {
    func testLaterHandFixReplicatesOverExistingEditOnIncrementalAndFullSync() async throws {
        let id = UUID()
        let row = DictationEntryDTO(id: id, timestamp: Date(), text: "Ann met Anna", durationSeconds: 1, wordCount: 3)
        try await core.historySync.insertMissing([row], asReplica: true)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let first = try await core.history.saveManualEdit("Anne met Anna", id: id, expectedText: row.text)
        XCTAssertTrue(first)
        engine.remoteChanged(.history)
        await settle()
        var local = try await edge.history.entry(id: id)
        XCTAssertEqual(local?.editedText, "Anne met Anna"); XCTAssertEqual(local?.editedTextRevision, 1)
        let second = try await core.history.saveManualEdit("Anne met Ana", id: id, expectedText: "Anne met Anna")
        XCTAssertTrue(second)
        engine.remoteChanged(.history)
        await settle()
        local = try await edge.history.entry(id: id)
        XCTAssertEqual(local?.editedText, "Anne met Ana"); XCTAssertEqual(local?.editedTextRevision, 2)
        // Replayed old uploads must not overwrite the later fix.
        var stale = row; stale.editedText = "Anne met Anna"; stale.editedTextRevision = 1
        try await core.historySync.insertMissing([stale], asReplica: false)
        engine.detach()
        let third = try await core.history.saveManualEdit("Anne meets Ana", id: id, expectedText: "Anne met Ana")
        XCTAssertTrue(third)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        local = try await edge.history.entry(id: id)
        XCTAssertEqual(local?.editedText, "Anne meets Ana"); XCTAssertEqual(local?.editedTextRevision, 3)
    }

    func testUndoClearsSameTombstoneAcrossConnectedMacs() async throws {
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true, origin: "learned")
        try await core.dictionary.upsert([row])
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let model = DictionaryModel()
        await model.delete(row, repositories: edge)
        engine.localChanged()
        await settle()
        let forgotten = try await core.dictionary.entries()
        XCTAssertEqual(forgotten.first?.id, row.id); XCTAssertEqual(forgotten.first?.isForgotten, true)
        await model.undoDelete(repositories: edge)
        engine.localChanged()
        await settle()
        for repos in [core!, edge!] {
            let restored = try await repos.dictionary.entries()
            XCTAssertEqual(restored.map(\.id), [row.id])
            XCTAssertEqual(restored.first?.isForgotten, false)
        }
    }

    func testDictionarySyncRetainsAllIdentitiesSharingAPattern() async throws {
        let rows = (0..<205).map { _ in DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true) }
        try await core.dictionary.upsert(rows)
        engine.attach(client: CoreSyncClient(transport: transport))
        await settle()
        let received = try await edge.dictionary.entries()
        XCTAssertEqual(Set(received.map(\.id)), Set(rows.map(\.id)))
    }
}
