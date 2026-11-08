import SwiftData
import SQLite3
import XCTest
@testable import Dictator

/// Covers the repository layer end to end: `LocalSwiftDataRepositories`
/// against a temp `PersistenceLoader.load(applicationSupport:)` container
/// (same seam `HardeningTests` uses) — the UI-facing protocols and the
/// replication seams (`HistorySyncStore`, `DictionarySyncStore`,
/// `SyncOutbox`) — plus `RepoServer` round-tripping every `RepoRequest`
/// kind against those same local repos, and `RepoRequestCorrelator` on its
/// own. `HistorySyncEngineTests` covers the engine that drives the seams.
@MainActor
final class RepositoriesTests: XCTestCase {
    private var tempRoot: URL!
    private var container: ModelContainer!
    private var repositories: Repositories!

    private var savedPersistHistory = false
    private var savedRefineLevel: RefineLevel = .medium
    private var savedCustomSystemPrompt = ""
    private var savedSurfacePolicyJSON = ""

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dictator-RepositoriesTests-\(UUID().uuidString)", isDirectory: true
        )
        let result = PersistenceLoader.load(applicationSupport: tempRoot)
        container = try XCTUnwrap(result.container)
        repositories = Repositories.make(container: container)

        // AppSettings.shared is a process-wide singleton over UserDefaults —
        // save/restore everything this test touches.
        let settings = AppSettings.shared
        savedPersistHistory = settings.persistHistory
        savedRefineLevel = settings.refineLevel
        savedCustomSystemPrompt = settings.customSystemPrompt
        savedSurfacePolicyJSON = settings.cachedSurfacePolicyJSON
        settings.persistHistory = true
        // Deterministic default: save both modalities unless a test says
        // otherwise, so `record()`'s persist-gate isn't at the mercy of
        // whatever surface policy a previous run cached to disk.
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "save", defaultVoice: "save", rules: []))
    }

    override func tearDown() async throws {
        let settings = AppSettings.shared
        settings.persistHistory = savedPersistHistory
        settings.refineLevel = savedRefineLevel
        settings.customSystemPrompt = savedCustomSystemPrompt
        settings.cachedSurfacePolicyJSON = savedSurfacePolicyJSON
        // Deleting a live SQLite store invalidates its open WAL/SHM handles.
        let owners = [WeakTestStoreOwner(container), WeakTestStoreOwner(repositories)]
        autoreleasepool {
            repositories = nil
            container = nil
        }
        try await TestStoreTeardown.remove([tempRoot], afterReleasing: owners)
        tempRoot = nil
        try await super.tearDown()
    }

    private func record(_ text: String, modality: String = "voice", source: String = "dictator", duration: Double = 1, inferenceMs: Int? = nil) async throws {
        try await repositories.history.record(HistoryRecordDTO(
            text: text, durationSeconds: duration, inferenceMs: inferenceMs, modality: modality, source: source
        ))
        try await Task.sleep(nanoseconds: 2_000_000)
    }

    // MARK: - LocalHistoryRepository

    func testRecordOrderAndVoiceOnlyStats() async throws {
        let history = repositories.history
        var onChangeCount = 0
        history.onChange = { onChangeCount += 1 }

        try await record("first entry", duration: 2, inferenceMs: 100)
        try await record("second entry two words", duration: 3, inferenceMs: 150)
        try await record("typed draft", modality: "typed", source: "ghost_text", duration: 0)
        XCTAssertEqual(onChangeCount, 3)

        let page = try await history.page(limit: 10, before: nil)
        XCTAssertEqual(page.map(\.text), ["typed draft", "second entry two words", "first entry"]) // newest first
        XCTAssertTrue(page.allSatisfy { $0.syncedAt == nil }, "a freshly recorded row is pending replication")

        let all = try await history.allEntries()
        XCTAssertEqual(all.map(\.text), page.map(\.text))

        // Typed drafts land in the feed but never move spoken WPM.
        let stats = try await history.stats()
        XCTAssertEqual(stats?.totalDictations, 2)
        XCTAssertEqual(stats?.totalWords, 6) // "first entry" (2) + "second entry two words" (4)
        XCTAssertEqual(stats?.totalAudioSeconds, 5)

        let toDelete = try XCTUnwrap(page.first?.id) // "typed draft"
        try await history.delete(ids: [toDelete])
        XCTAssertEqual(onChangeCount, 4)
        let afterDelete = try await history.page(limit: 10, before: nil)
        XCTAssertEqual(afterDelete.count, 2)
        XCTAssertFalse(afterDelete.contains { $0.id == toDelete })
    }

    func testRecordKeepsOriginEdgeId() async throws {
        try await repositories.history.record(HistoryRecordDTO(text: "from the laptop", durationSeconds: 1, originEdgeId: "edge-laptop"))
        let page = try await repositories.history.page(limit: 1, before: nil)
        XCTAssertEqual(page.first?.originEdgeId, "edge-laptop")
    }

    /// Pagination cursor: `before` is exclusive, newest first.
    func testPageBeforeCursorWalksBackward() async throws {
        let history = repositories.history
        for i in 0..<3 {
            try await record("entry \(i)")
        }

        let firstPage = try await history.page(limit: 2, before: nil)
        XCTAssertEqual(firstPage.map(\.text), ["entry 2", "entry 1"])

        let cursor = try XCTUnwrap(firstPage.last).cursor
        let secondPage = try await history.page(limit: 2, before: cursor)
        XCTAssertEqual(secondPage.map(\.text), ["entry 0"])
    }

    /// Rows sharing the exact boundary timestamp must not be silently
    /// dropped by a timestamp-only cursor. 2,250 entries backdated to the
    /// same timestamp, paged with `limit: 100`, must together cover every
    /// row exactly once.
    func testPageWithTiedTimestampsCoversEveryRowExactlyOnce() async throws {
        let context = ModelContext(container)
        let tied = Date(timeIntervalSince1970: 1_700_000_000)
        var expectedIds = Set<UUID>()
        for i in 0..<2_250 {
            let entry = DictationEntry(text: "tied \(i)", durationSeconds: 1, modality: "voice", source: "dictator")
            entry.timestamp = tied
            context.insert(entry)
            expectedIds.insert(entry.id)
        }
        try context.save()

        var seenIds = Set<UUID>()
        var seenOrder: [DictationEntryDTO] = []
        var cursor: HistoryCursor?
        while true {
            let page = try await repositories.history.page(limit: 100, before: cursor)
            guard let last = page.last else { break }
            for entry in page {
                XCTAssertTrue(seenIds.insert(entry.id).inserted, "duplicate row \(entry.id) across pages")
            }
            seenOrder.append(contentsOf: page)
            cursor = last.cursor
        }

        XCTAssertEqual(seenIds, expectedIds)
        // Deterministic (timestamp desc, id desc) order across the whole walk.
        XCTAssertEqual(seenOrder.map(\.id.uuidString), seenOrder.map(\.id.uuidString).sorted(by: >))

        // The manifest walks the same order with the same cursor scheme.
        var manifestIds: [UUID] = []
        var manifestCursor: HistoryCursor?
        while true {
            let page = try await repositories.historySync.manifestPage(limit: 100, before: manifestCursor)
            guard let last = page.last else { break }
            manifestIds.append(contentsOf: page.map(\.id))
            manifestCursor = last.cursor
        }
        XCTAssertEqual(manifestIds, seenOrder.map(\.id))
    }

    func testLocalBrowsingAndWholeStoreActionsPreserveLongText() async throws {
        let context = ModelContext(container)
        let longText = String(repeating: "synthetic words ", count: 30_000)
        let typed = DictationEntry(text: longText, durationSeconds: 0, modality: "typed")
        typed.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(typed)
        let legacy = DictationEntry(text: "legacy spoken", durationSeconds: 1)
        legacy.modality = nil
        legacy.timestamp = typed.timestamp.addingTimeInterval(1)
        context.insert(legacy)
        try context.save()

        let matching = try await repositories.history.browsePage(limit: 100, before: nil, filter: .typed)
        XCTAssertEqual(matching.map(\.text), [longText])
        XCTAssertNil(matching.first?.truncated)
        let spoken = try await repositories.history.browsePage(limit: 100, before: nil, filter: .spoken)
        XCTAssertEqual(spoken.map(\.text), ["legacy spoken"])
        let all = try await repositories.history.allEntries()
        XCTAssertEqual(all.map(\.text), ["legacy spoken", longText])
    }

    /// The default `allEntries()` protocol extension loops `page()` until an
    /// empty page signals the end — not a short-of-`limit` one, since the
    /// byte budget can make `page()` return fewer than `limit` rows well
    /// before the actual end of the store.
    func testAllEntriesDefaultImplementationLoopsUntilEmptyPage() async throws {
        let fullPage = (0..<RepoRequestLimits.historyPageSize).map { makeDTO(text: "full-\($0)") }
        let shortPage = [makeDTO(text: "tail-0"), makeDTO(text: "tail-1")]
        let fake = FakePagingHistoryRepository(batches: [fullPage, shortPage])

        let all = try await fake.allEntries()
        XCTAssertEqual(all.count, RepoRequestLimits.historyPageSize + 2)
        XCTAssertEqual(fake.requestedBefores.count, 3)
        XCTAssertNil(fake.requestedBefores[0])
    }

    func testPersistGateHonouredStatsStillUpdated() async throws {
        AppSettings.shared.persistHistory = false
        try await record("won't be saved", duration: 4)

        let page = try await repositories.history.page(limit: 10, before: nil)
        XCTAssertTrue(page.isEmpty)

        // Aggregate stats are recorded regardless of the persist gate.
        let stats = try await repositories.history.stats()
        XCTAssertEqual(stats?.totalDictations, 1)
        XCTAssertEqual(stats?.totalWords, 3)
    }

    // MARK: - Byte-budgeted pagination

    func testHistoryPageStaysWithinByteBudgetForOversizedTexts() async throws {
        let history = repositories.history
        let longText = String(repeating: "a", count: 131_072)
        for _ in 0..<4 {
            try await record(longText)
        }

        let page = try await history.page(limit: 200, before: nil)
        // A single 131_072-char entry's own encoded size is already close to
        // the 200 KB budget, so a second one can never fit alongside it.
        XCTAssertEqual(page.count, 1)
        XCTAssertNil(page.first?.truncated, "one entry fits whole; it must not be marked truncated")
        let encoded = try JSONEncoder().encode(page).count
        XCTAssertLessThanOrEqual(encoded, RepoRequestLimits.pageByteBudget)

        // `fetch(ids:)` is budgeted the same way — the sync engine re-asks
        // for whatever a short answer left out.
        let ids = try await repositories.historySync.localManifest().map(\.item.id)
        XCTAssertEqual(ids.count, 4)
        let fetched = try await repositories.historySync.fetch(ids: ids)
        XCTAssertEqual(fetched.count, 1)
    }

    func testHistoryPresenceProjectionIsNotByteBudgeted() async throws {
        let longText = String(repeating: "p", count: 131_072)
        for _ in 0..<4 {
            try await record(longText)
        }

        let ids = try await repositories.historySync.localManifest().map(\.item.id)
        let present = try await repositories.historySync.existingIDs(ids: ids)
        XCTAssertEqual(present, Set(ids), "id-only presence must see every row even when full rows exceed the page budget")
    }

    func testHistoryPageTruncatesASingleOversizedEntry() async throws {
        let history = repositories.history
        // Bigger than `RepoRequestLimits.maxTextLength`, modelling a row
        // already in the store from before that bound existed — big enough
        // that the entry alone exceeds `pageByteBudget`.
        let hugeText = String(repeating: "b", count: 300_000)
        try await record(hugeText)

        let page = try await history.page(limit: 200, before: nil)
        XCTAssertEqual(page.count, 1)
        let entry = try XCTUnwrap(page.first)
        XCTAssertEqual(entry.truncated, true)
        XCTAssertLessThan(entry.text.count, hugeText.count)
        let encoded = try JSONEncoder().encode(entry).count
        XCTAssertLessThanOrEqual(encoded, RepoRequestLimits.pageByteBudget)
    }

    // MARK: - HistorySyncStore

    func testPendingSyncMarkSyncedAndManifest() async throws {
        try await record("one")
        try await record("two")
        let sync = repositories.historySync

        let value1 = try await sync.pendingCount()
        XCTAssertEqual(value1, 2)
        let pending = try await sync.pendingSync(limit: 10, excluding: [])
        XCTAssertEqual(pending.map(\.text), ["one", "two"], "oldest first")

        try await sync.markSynced(ids: [pending[0].id])
        let value2 = try await sync.pendingCount()
        XCTAssertEqual(value2, 1)
        let value3 = try await sync.pendingSync(limit: 10, excluding: []).map(\.text)
        XCTAssertEqual(value3, ["two"])

        let manifest = try await sync.localManifest()
        XCTAssertEqual(manifest.count, 2)
        XCTAssertEqual(manifest.first { $0.item.id == pending[0].id }?.pending, false)
        XCTAssertEqual(manifest.first { $0.item.id == pending[1].id }?.pending, true)

        let page = try await repositories.history.page(limit: 10, before: nil)
        XCTAssertNotNil(page.first { $0.id == pending[0].id }?.syncedAt)
    }

    func testInsertMissingIsIdempotentAndKeepsIdsTimestamps() async throws {
        let sync = repositories.historySync
        var onChangeCount = 0
        repositories.history.onChange = { onChangeCount += 1 }
        let when = Date(timeIntervalSince1970: 1_690_000_000)
        let a = makeDTO(text: "from core a", timestamp: when)
        let b = makeDTO(text: "from core b", timestamp: when.addingTimeInterval(1))

        let inserted = try await sync.insertMissing([a, b], asReplica: true)
        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(onChangeCount, 1)

        let again = try await sync.insertMissing([a, b, makeDTO(text: "c")], asReplica: true)
        XCTAssertEqual(again, 1, "only the new id lands; repeats are ignored")

        let page = try await repositories.history.page(limit: 10, before: nil)
        let storedA = try XCTUnwrap(page.first { $0.id == a.id })
        XCTAssertEqual(storedA.timestamp, when)
        XCTAssertNotNil(storedA.syncedAt, "a replica is never pending")
        let value4 = try await sync.pendingCount()
        XCTAssertEqual(value4, 0)

        // Replicas never touch the aggregate stats…
        let value5 = try await repositories.history.stats()
        XCTAssertNil(value5)
        // …but a Core accepting an Edge's upload counts it once.
        let uploaded = makeDTO(text: "uploaded two words", timestamp: when)
        _ = try await sync.insertMissing([uploaded], asReplica: false)
        let stats = try await repositories.history.stats()
        XCTAssertEqual(stats?.totalDictations, 1)
        XCTAssertEqual(stats?.totalWords, uploaded.wordCount)
        let value6 = try await sync.pendingCount()
        XCTAssertEqual(value6, 0, "the Core's own copy of an upload is not pending either")
    }

    func testDeleteReplicasNeverQueuesOutboxAndDeleteDoesWhenEdge() async throws {
        try await record("keep")
        try await record("core removed this")
        try await record("user removed this")
        let sync = repositories.historySync
        let outbox = repositories.outbox
        let page = try await repositories.history.page(limit: 10, before: nil)
        let coreRemoved = try XCTUnwrap(page.first { $0.text == "core removed this" }?.id)
        let userRemoved = try XCTUnwrap(page.first { $0.text == "user removed this" }?.id)

        outbox.enabled = true
        try await sync.deleteReplicas(ids: [coreRemoved])
        XCTAssertEqual(try outbox.count(), 0, "a Core-side deletion is applied, never echoed back")

        try await repositories.history.delete(ids: [userRemoved])
        XCTAssertEqual(try outbox.count(), 1)
        let queued = try outbox.pending(limit: 10)
        XCTAssertEqual(queued.first?.request, .historyDelete(ids: [userRemoved]))

        outbox.enabled = false
        let keep = try XCTUnwrap(page.first { $0.text == "keep" }?.id)
        try await repositories.history.delete(ids: [keep])
        XCTAssertEqual(try outbox.count(), 1, "standalone/Core roles never queue")

        try outbox.remove(ids: [queued[0].id])
        XCTAssertEqual(try outbox.count(), 0)
    }

    func testHistoryDeleteChunksOutboxAt500Ids() async throws {
        let context = ModelContext(container)
        var ids: [UUID] = []
        for index in 0..<1_001 {
            let entry = DictationEntry(text: "delete \(String(index))", durationSeconds: 1)
            ids.append(entry.id)
            context.insert(entry)
        }
        try context.save()

        repositories.outbox.enabled = true
        try await repositories.history.delete(ids: ids)

        let queued = try repositories.outbox.pending(limit: 10)
        let chunkSizes = queued.compactMap { request -> Int? in
            guard case .historyDelete(let ids) = request.request else { return nil }
            return ids.count
        }
        XCTAssertEqual(chunkSizes.count, 3)
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= 500 })
        XCTAssertEqual(chunkSizes.reduce(0, +), ids.count)
        let queuedIDs = queued.flatMap { request -> [UUID] in
            guard case .historyDelete(let ids) = request.request else { return [] }
            return ids
        }
        XCTAssertEqual(Set(queuedIDs), Set(ids))
        let remaining = try await repositories.historySync.localManifest()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeletedImportIDCannotBeRecreatedByARepeatedImport() async throws {
        let imports = try XCTUnwrap(repositories.history as? HistoryDatasetStore)
        let row = makeDTO(text: "synthetic imported prompt")
        let first = try await imports.insertImported([row])
        XCTAssertEqual(first, 1)
        try await repositories.history.delete(ids: [row.id])
        let repeated = try await imports.insertImported([row])
        XCTAssertEqual(repeated, 0)
        let rows = try await repositories.history.allEntries()
        XCTAssertTrue(rows.isEmpty)
    }

    func testDeletionManifestPaginationIsStableAndDoesNotFetchDeletedText() async throws {
        for index in 0..<23 { try await record("manifest row \(index)") }
        let initial = try await repositories.history.allEntries()
        let ids = Array(initial.prefix(17).map(\.id))
        try await repositories.history.delete(ids: ids)
        var items: [HistoryManifestItem] = []
        var cursor: HistoryCursor?
        while true {
            let page = try await repositories.historySync.manifestPage(limit: 4, before: cursor)
            guard let last = page.last else { break }
            items += page
            cursor = last.cursor
        }
        XCTAssertEqual(items.count, 23)
        XCTAssertEqual(Set(items.map(\.id)).count, 23)
        XCTAssertEqual(Set(items.filter { $0.deletedAt != nil }.map(\.id)), Set(ids))
        XCTAssertTrue(items.prefix(17).allSatisfy { $0.deletedAt != nil })
        let deletedRows = try await repositories.historySync.fetch(ids: ids)
        XCTAssertTrue(deletedRows.isEmpty)
        // Unknown IDs also need proof: their delayed upload may arrive later.
        let unknown = UUID()
        try await repositories.history.delete(ids: [unknown])
        let proofs = try await repositories.historySync.deletionIDs(ids: [unknown])
        XCTAssertEqual(proofs, [unknown])
    }

    func testLargeDeletionManifestStaysByteBudgetedAcrossPages() async throws {
        let ids = (0..<5_000).map { _ in UUID() }
        try await repositories.history.delete(ids: ids)
        var found: [UUID] = []
        var cursor: HistoryCursor?
        while true {
            let page = try await repositories.historySync.manifestPage(limit: 5_000, before: cursor)
            guard let last = page.last else { break }
            let message = CoreMessage.repoResponse(requestId: "proof-page", result: .historyManifest(page))
            XCTAssertLessThan(try EdgeProtocolCodec.encode(message).count, EdgeProtocol.maxTextFrameBytes)
            XCTAssertTrue(page.allSatisfy { $0.deletedAt != nil })
            found += page.map(\.id)
            cursor = last.cursor
        }
        XCTAssertEqual(found.count, ids.count)
        XCTAssertEqual(Set(found), Set(ids))
    }

    func testDeletionOrderKeyPreservesExactDatesAndUUIDTieBreaks() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let seconds: [Double] = [-800_000_000, -1, 0, 1, 800_000_000, Double(800_000_000).nextUp]
        let keys = seconds.map { HistoryDeletion.key(id: id, date: Date(timeIntervalSinceReferenceDate: $0)) }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, seconds.count, "sub-microsecond dates must not collapse into one sort prefix")
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertLessThan(HistoryDeletion.key(id: id, date: date), HistoryDeletion.key(id: otherID, date: date))
    }

    func testBulkDeletionPagingUsesIndexedRangeAndScalesWithRows() async throws {
        let smallRoot = tempRoot.appendingPathComponent("small-proof-store", isDirectory: true)
        let smallLoaded = PersistenceLoader.load(applicationSupport: smallRoot)
        let small = Repositories.make(container: try XCTUnwrap(smallLoaded.container))
        try await small.history.delete(ids: (0..<500).map { _ in UUID() })
        try await repositories.history.delete(ids: (0..<5_000).map { _ in UUID() })

        // Inspect the actual temporary Core Data SQLite store's query plan.
        // The unique attribute must produce an index supporting the same
        // range/sort/limit used by fetchDeletions, without a temporary sort.
        var database: OpaquePointer?
        let path = tempRoot.appendingPathComponent("Dictator/Dictator.store").path
        XCTAssertEqual(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "EXPLAIN QUERY PLAN SELECT ZID, ZDELETEDAT FROM ZHISTORYDELETION WHERE ZSORTKEY < 'FFFFFFFFFFFFFFFF:FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF' ORDER BY ZSORTKEY DESC LIMIT 100"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var plan: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let detail = sqlite3_column_text(statement, 3) { plan.append(String(cString: detail)) }
        }
        let details = plan.joined(separator: " ").uppercased()
        XCTAssertTrue(details.contains("USING INDEX") || details.contains("USING COVERING INDEX"), details)
        XCTAssertFalse(details.contains("TEMP B-TREE"), details)

        func walk(_ store: Repositories, expected: Int) async throws -> TimeInterval {
            let started = ProcessInfo.processInfo.systemUptime
            var cursor: HistoryCursor?
            var seen = Set<UUID>()
            while true {
                let page = try await store.historySync.manifestPage(limit: 100, before: cursor)
                guard let last = page.last else { break }
                XCTAssertLessThanOrEqual(page.count, 100)
                seen.formUnion(page.map(\.id))
                cursor = last.cursor
            }
            XCTAssertEqual(seen.count, expected)
            return ProcessInfo.processInfo.systemUptime - started
        }
        // Warm both stores, then use medians and a generous relative bound.
        // A quadratic tie-group scan tends toward 100x work for 10x rows;
        // indexed bounded pages grow with the number of metadata rows.
        _ = try await walk(small, expected: 500)
        _ = try await walk(repositories, expected: 5_000)
        var smallTimes: [TimeInterval] = []
        var largeTimes: [TimeInterval] = []
        for _ in 0..<3 {
            smallTimes.append(try await walk(small, expected: 500))
            largeTimes.append(try await walk(repositories, expected: 5_000))
        }
        let ratio = largeTimes.sorted()[1] / max(smallTimes.sorted()[1], 0.000_001)
        print("DELETION-PAGING plan=\(details) small=\(smallTimes) large=\(largeTimes) ratio=\(ratio)")
        XCTAssertLessThan(ratio, 35, "10x markers must not approach quadratic timestamp-group scans")
    }

    func testPreDeletionSchemaMigratesWithoutLosingSyntheticRows() async throws {
        let root = tempRoot.appendingPathComponent("pre-deletion", isDirectory: true)
        let folder = root.appendingPathComponent("Dictator", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = folder.appendingPathComponent("Dictator.store")
        try autoreleasepool {
            let schema = Schema([DictationEntry.self, DictationStats.self, DictionaryEntry.self, SyncOutboxItem.self])
            let oldContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: store)])
            let context = ModelContext(oldContainer)
            context.insert(DictationEntry(text: "synthetic row before deletion metadata", durationSeconds: 1))
            try context.save()
        }
        let loaded = PersistenceLoader.load(applicationSupport: root)
        XCTAssertNil(loaded.warning, "additive model migration must not archive/recover the store")
        let upgraded = Repositories.make(container: try XCTUnwrap(loaded.container))
        let rows = try await upgraded.history.allEntries()
        XCTAssertEqual(rows.map(\.text), ["synthetic row before deletion metadata"])
        try await upgraded.history.delete(ids: rows.map(\.id))
        let markers = try await upgraded.historySync.deletionIDs(ids: rows.map(\.id))
        XCTAssertEqual(markers, Set(rows.map(\.id)))
    }

    func testReplaceStatsOverwritesAggregate() async throws {
        try await record("one two three", duration: 6)
        try await repositories.historySync.replaceStats(DictationStatsDTO(totalWords: 500, totalDictations: 40, totalAudioSeconds: 900))
        let stats = try await repositories.history.stats()
        XCTAssertEqual(stats, DictationStatsDTO(totalWords: 500, totalDictations: 40, totalAudioSeconds: 900))
    }

    // MARK: - LocalDictionaryRepository

    func testDictionaryUpsertUpdateAndDelete() async throws {
        let dictionary = repositories.dictionary
        var onChangeCount = 0
        dictionary.onChange = { onChangeCount += 1 }
        let id = UUID()

        try await dictionary.upsert([DictionaryEntryDTO(id: id, pattern: "teh", replacement: "the", isVocabulary: false)])
        var entries = try await dictionary.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.replacement, "the")

        // Same id again is an update, not a second row.
        try await dictionary.upsert([DictionaryEntryDTO(id: id, pattern: "teh", replacement: "them", isVocabulary: false)])
        entries = try await dictionary.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.replacement, "them")

        try await dictionary.delete(ids: [id])
        entries = try await dictionary.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(onChangeCount, 3)
        XCTAssertEqual(try repositories.outbox.count(), 0, "outbox disabled: nothing queued")
    }

    func testDictionaryEditsQueueForTheCoreWhenEdge() async throws {
        repositories.outbox.enabled = true
        let id = UUID()
        let dto = DictionaryEntryDTO(id: id, pattern: "teh", replacement: "the", isVocabulary: false)
        try await repositories.dictionary.upsert([dto])
        try await repositories.dictionary.delete(ids: [id])
        let queued = try repositories.outbox.pending(limit: 10)
        XCTAssertEqual(queued.map(\.request), [.dictionaryUpsert([dto]), .dictionaryDelete(ids: [id])])
    }

    func testALargeDictionaryEditQueuesInBatchesTheCoreAccepts() async throws {
        repositories.outbox.enabled = true
        let entries = (0..<250).map { DictionaryEntryDTO(id: UUID(), pattern: "word\($0)", replacement: "", isVocabulary: true) }
        let ids = (0..<1_200).map { _ in UUID() }
        try repositories.outbox.enqueue(.dictionaryUpsert(entries))
        try repositories.outbox.enqueue(.dictionaryDelete(ids: ids))
        let queued = try repositories.outbox.pending(limit: 20)
        XCTAssertEqual(queued.count, 6)
        for item in queued { XCTAssertNil(RepoServer.validate(item.request)) }
    }

    func testDictionaryReplaceAllConvergesWithoutTouchingOutbox() async throws {
        repositories.outbox.enabled = true
        let keep = DictionaryEntryDTO(id: UUID(), pattern: "keep", replacement: "kept", isVocabulary: true)
        let change = DictionaryEntryDTO(id: UUID(), pattern: "chg", replacement: "old", isVocabulary: false)
        let drop = DictionaryEntryDTO(id: UUID(), pattern: "drop", replacement: "gone", isVocabulary: false)
        try await repositories.dictionary.upsert([keep, change, drop])
        let queuedBefore = try repositories.outbox.count()

        var changed = change
        changed.replacement = "new"
        let added = DictionaryEntryDTO(id: UUID(), pattern: "add", replacement: "added", isVocabulary: false)
        var onChangeCount = 0
        repositories.dictionary.onChange = { onChangeCount += 1 }
        try await repositories.dictionarySync.replaceAll(with: [keep, changed, added])

        let entries = try await repositories.dictionary.entries()
        XCTAssertEqual(Set(entries.map(\.pattern)), ["keep", "chg", "add"])
        XCTAssertEqual(entries.first { $0.id == change.id }?.replacement, "new")
        XCTAssertEqual(onChangeCount, 1)
        XCTAssertEqual(try repositories.outbox.count(), queuedBefore, "a mirror never queues")

        try await repositories.dictionarySync.replaceAll(with: [keep, changed, added])
        XCTAssertEqual(onChangeCount, 1, "no change → no notification")
    }

    func testDictionaryPageWalksForwardByPatternAndEntriesLoopsAllPages() async throws {
        let dictionary = repositories.dictionary
        let entries = (0..<5).map { i in DictionaryEntryDTO(id: UUID(), pattern: "p\(i)", replacement: "r\(i)", isVocabulary: false) }
        try await dictionary.upsert(entries)

        let firstPage = try await dictionary.page(limit: 2, afterPattern: nil)
        XCTAssertEqual(firstPage.map(\.pattern), ["p0", "p1"])

        let secondPage = try await dictionary.page(limit: 2, afterPattern: firstPage.last?.pattern)
        XCTAssertEqual(secondPage.map(\.pattern), ["p2", "p3"])

        let all = try await dictionary.entries()
        XCTAssertEqual(all.map(\.pattern), ["p0", "p1", "p2", "p3", "p4"])
    }

    func testRecordingMacWireFieldSupportsOldPeersAndExplicitAutomatic() throws {
        let old = Data(#"{"refineLevel":"medium","customSystemPrompt":"","persistHistory":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CoreSettingsDTO.self, from: old).micOwnerEdgeID)
        XCTAssertNil(try JSONDecoder().decode(CoreSettingsPatch.self, from: Data("{}".utf8)).micOwnerEdgeID)
        XCTAssertTrue(CoreSettingsPatch().isEmpty)
        for id in ["qa-recorder", ""] {
            let patch = CoreSettingsPatch(micOwnerEdgeID: id)
            XCTAssertFalse(patch.isEmpty)
            XCTAssertEqual(try JSONDecoder().decode(CoreSettingsPatch.self, from: JSONEncoder().encode(patch)), patch)
            let dto = CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true, micOwnerEdgeID: id)
            XCTAssertEqual(try JSONDecoder().decode(CoreSettingsDTO.self, from: JSONEncoder().encode(dto)), dto)
        }
    }

    func testRecordingMacRepositoryAndServerValidateBeforeApplyingAnyField() async throws {
        let settings = AppSettings.shared
        let saved = settings.micOwnerEdgeID
        defer { settings.micOwnerEdgeID = saved }
        let server = RepoServer(repositories: repositories)
        var changes = 0
        repositories.settings.onChange = { changes += 1 }
        for id in ["qa-offline-recorder", ""] {
            let result = await server.handle(.settingsSet(CoreSettingsPatch(micOwnerEdgeID: id)))
            XCTAssertEqual(result, .ok)
            let dto = try await repositories.settings.get()
            XCTAssertEqual(dto.micOwnerEdgeID, id)
            XCTAssertEqual(settings.micOwnerEdgeID, id)
        }
        XCTAssertEqual(changes, 2)
        try await repositories.settings.set(CoreSettingsPatch(customSystemPrompt: "unrelated"))
        XCTAssertEqual(settings.micOwnerEdgeID, "", "Omitting the field preserves the choice")
        for id in [String(repeating: "a", count: RepoRequestLimits.maxEdgeIdLength + 1), " ", "qa\nrecorder", "qa\0recorder"] {
            let patch = CoreSettingsPatch(persistHistory: false, micOwnerEdgeID: id)
            XCTAssertNotNil(RepoServer.validate(.settingsSet(patch)))
            let result = await server.handle(.settingsSet(patch))
            guard case .error = result else { return XCTFail("Expected invalid Mac rejection") }
            do {
                try await repositories.settings.set(patch)
                XCTFail("Expected local validation too")
            } catch RepositoryError.unavailable {}
            XCTAssertTrue(settings.persistHistory, "Invalid patches must apply no fields")
            XCTAssertEqual(settings.micOwnerEdgeID, "")
        }
        XCTAssertEqual(changes, 3, "Rejected patches must not notify")
        XCTAssertNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(micOwnerEdgeID: String(repeating: "a", count: RepoRequestLimits.maxEdgeIdLength)))))
    }

    // MARK: - LocalCoreSettingsRepository

    func testCoreSettingsGetSetRoundTripsThroughAppSettings() async throws {
        let settingsRepo = repositories.settings
        var onChangeCount = 0
        settingsRepo.onChange = { onChangeCount += 1 }

        let before = try await settingsRepo.get()
        XCTAssertEqual(before.persistHistory, true) // set in setUp
        XCTAssertEqual(before.surfacePolicyJSON, AppSettings.shared.cachedSurfacePolicyJSON)

        let policy = SurfacePolicy(defaultTyped: "save", defaultVoice: "ignore", rules: [], version: 2, tools: ["codex": ToolSwitch(typed: true)])
        let policyJSON = String(data: try JSONEncoder().encode(policy), encoding: .utf8)!
        try await settingsRepo.set(CoreSettingsPatch(refineLevel: "light", customSystemPrompt: "be terse", persistHistory: false, surfacePolicyJSON: policyJSON))
        XCTAssertEqual(onChangeCount, 1)

        let after = try await settingsRepo.get()
        XCTAssertEqual(after.refineLevel, "medium")
        XCTAssertEqual(after.customSystemPrompt, "be terse")
        XCTAssertEqual(after.persistHistory, false)
        XCTAssertEqual(AppSettings.shared.refineLevel, .medium)
        XCTAssertEqual(AppSettings.shared.surfacePolicy, policy)
    }

    func testCoreSettingsSetRejectsUnknownRefineLevelAndBadPolicy() async throws {
        do {
            try await repositories.settings.set(CoreSettingsPatch(refineLevel: "made-up"))
            XCTFail("expected an error")
        } catch RepositoryError.unavailable {}
        do {
            try await repositories.settings.set(CoreSettingsPatch(surfacePolicyJSON: "not json"))
            XCTFail("expected an error")
        } catch RepositoryError.unavailable {}
    }

    // MARK: - RepoServer

    func testRepoServerRoundTripsEveryRequestKind() async throws {
        let server = RepoServer(repositories: repositories)

        let entry = makeDTO(text: "hi")
        let result1 = await server.handle(.historyUpsert([entry]))
        XCTAssertEqual(result1, .ok)
        let result2 = await server.handle(.historyUpsert([entry]))
        XCTAssertEqual(result2, .ok, "idempotent")
        guard case .historyPage(let page) = await server.handle(.historyPage(limit: 10, before: nil)) else {
            return XCTFail("expected historyPage")
        }
        XCTAssertEqual(page.map(\.id), [entry.id])

        guard case .historyManifest(let manifest) = await server.handle(.historyManifest(limit: 10, before: nil)) else {
            return XCTFail("expected historyManifest")
        }
        XCTAssertEqual(manifest.map(\.id), [entry.id])

        guard case .historyPage(let fetched) = await server.handle(.historyFetch(ids: [entry.id, UUID()])) else {
            return XCTFail("expected historyPage from historyFetch")
        }
        XCTAssertEqual(fetched.map(\.text), ["hi"])

        guard case .historyStats(let stats) = await server.handle(.historyStats) else {
            return XCTFail("expected historyStats")
        }
        XCTAssertEqual(stats?.totalDictations, 1)

        let result3 = await server.handle(.historyDelete(ids: [entry.id]))

        XCTAssertEqual(result3, .ok)
        guard case .historyPage(let emptyPage) = await server.handle(.historyPage(limit: 10, before: nil)) else {
            return XCTFail("expected historyPage")
        }
        XCTAssertTrue(emptyPage.isEmpty)

        let dictId = UUID()
        let result4 = await server.handle(.dictionaryUpsert([DictionaryEntryDTO(id: dictId, pattern: "teh", replacement: "the", isVocabulary: false)]))
        XCTAssertEqual(result4, .ok)
        guard case .dictionaryPage(let list) = await server.handle(.dictionaryPage(limit: 10, afterPattern: nil)) else {
            return XCTFail("expected dictionaryPage")
        }
        XCTAssertEqual(list.map(\.id), [dictId])
        let result5 = await server.handle(.dictionaryDelete(ids: [dictId]))
        XCTAssertEqual(result5, .ok)
        guard case .settings(let settingsBefore) = await server.handle(.settingsGet) else {
            return XCTFail("expected settings")
        }
        XCTAssertEqual(settingsBefore.persistHistory, true)

        let result6 = await server.handle(.settingsSet(CoreSettingsPatch(refineLevel: "strong", customSystemPrompt: "custom")))

        XCTAssertEqual(result6, .ok)
        guard case .settings(let settingsAfter) = await server.handle(.settingsGet) else {
            return XCTFail("expected settings")
        }
        XCTAssertEqual(settingsAfter.refineLevel, "strong")
        XCTAssertEqual(settingsAfter.customSystemPrompt, "custom")
    }

    func testRepoServerMapsRepositoryErrorsToErrorResult() async {
        let server = RepoServer(repositories: repositories)
        let result = await server.handle(.settingsSet(CoreSettingsPatch(refineLevel: "made-up")))
        guard case .error(let message) = result else {
            return XCTFail("expected .error, got \(result)")
        }
        XCTAssertTrue(message.contains("made-up"))
    }

    // MARK: - RepoServer request bounds

    private func assertInvalid(_ request: RepoRequest, file: StaticString = #filePath, line: UInt = #line) async {
        let server = RepoServer(repositories: repositories)
        let result = await server.handle(request)
        guard case .error(let message) = result else {
            return XCTFail("expected .error, got \(result)", file: file, line: line)
        }
        XCTAssertTrue(message.hasPrefix("invalid request:"), "got: \(message)", file: file, line: line)
    }

    private func makeEntry(text: String = "hi", durationSeconds: Double = 1, inferenceMs: Int? = nil, modality: String = "voice", source: String = "dictator", originEdgeId: String? = nil) -> DictationEntryDTO {
        DictationEntryDTO(
            id: UUID(), timestamp: Date(), text: text, durationSeconds: durationSeconds, inferenceMs: inferenceMs, wordCount: 1,
            modality: modality, source: source, destinationAppBundleId: nil, destinationAppName: nil,
            destinationURL: nil, insertionMethod: nil, originEdgeId: originEdgeId
        )
    }

    func testRepoServerRejectsLimitOutOfRange() async {
        await assertInvalid(.historyPage(limit: 0, before: nil))
        await assertInvalid(.historyPage(limit: 501, before: nil))
        await assertInvalid(.historyManifest(limit: 0, before: nil))
        await assertInvalid(.historyManifest(limit: 5_001, before: nil))
        await assertInvalid(.dictionaryPage(limit: 0, afterPattern: nil))
        await assertInvalid(.dictionaryPage(limit: 501, afterPattern: nil))
    }

    func testRepoServerRejectsTooManyIds() async {
        let tooMany = (0..<501).map { _ in UUID() }
        await assertInvalid(.historyDelete(ids: tooMany))
        await assertInvalid(.historyFetch(ids: tooMany))
        await assertInvalid(.dictionaryDelete(ids: tooMany))
    }

    func testRepoServerRejectsTooManyUpsertEntries() async {
        let tooMany = (0..<501).map { _ in DictionaryEntryDTO(id: UUID(), pattern: "p", replacement: "r", isVocabulary: false) }
        await assertInvalid(.dictionaryUpsert(tooMany))
        await assertInvalid(.historyUpsert((0..<501).map { _ in makeEntry() }))
    }

    func testRepoServerRejectsOversizedPatternOrReplacement() async {
        let longPattern = String(repeating: "p", count: 513)
        let longReplacement = String(repeating: "r", count: 513)
        await assertInvalid(.dictionaryUpsert([DictionaryEntryDTO(id: UUID(), pattern: longPattern, replacement: "r", isVocabulary: false)]))
        await assertInvalid(.dictionaryUpsert([DictionaryEntryDTO(id: UUID(), pattern: "p", replacement: longReplacement, isVocabulary: false)]))
    }

    func testRepoServerRejectsMalformedUpsertEntries() async {
        await assertInvalid(.historyUpsert([makeEntry(text: String(repeating: "a", count: 131_073))]))
        await assertInvalid(.historyUpsert([makeEntry(durationSeconds: -1)]))
        await assertInvalid(.historyUpsert([makeEntry(durationSeconds: 181)]))
        await assertInvalid(.historyUpsert([makeEntry(durationSeconds: .infinity)]))
        await assertInvalid(.historyUpsert([makeEntry(durationSeconds: .nan)]))
        await assertInvalid(.historyUpsert([makeEntry(inferenceMs: -1)]))
        await assertInvalid(.historyUpsert([makeEntry(inferenceMs: 300_001)]))
        await assertInvalid(.historyUpsert([makeEntry(modality: "screaming")]))
        await assertInvalid(.historyUpsert([makeEntry(source: String(repeating: "s", count: 129))]))
        await assertInvalid(.historyUpsert([makeEntry(originEdgeId: String(repeating: "e", count: 129))]))
        await assertInvalid(.settingsSet(CoreSettingsPatch(surfacePolicyJSON: String(repeating: "{", count: 64 * 1_024 + 1))))
    }

    func testRepoServerAcceptsValuesAtTheBoundary() async throws {
        let server = RepoServer(repositories: repositories)
        let entry = makeEntry(
            text: String(repeating: "a", count: 131_072),
            durationSeconds: 180,
            inferenceMs: 300_000,
            modality: "typed",
            source: String(repeating: "s", count: 128),
            originEdgeId: String(repeating: "e", count: 128)
        )
        let result7 = await server.handle(.historyUpsert([entry]))
        XCTAssertEqual(result7, .ok)
    }

    // MARK: - CoreSyncClient

    private final class FakeTransport: RepoTransport {
        var handler: (RepoRequest) throws -> RepoResult = { _ in .ok }
        private(set) var sent: [RepoRequest] = []

        func send(_ request: RepoRequest) async throws -> RepoResult {
            sent.append(request)
            return try handler(request)
        }
    }

    func testCoreSyncClientUnwrapsResultsAndMapsErrors() async throws {
        let transport = FakeTransport()
        let dto = makeDTO(text: "hi")
        let item = HistoryManifestItem(id: dto.id, timestamp: dto.timestamp)
        transport.handler = { request in
            switch request {
            case .historyManifest(_, let before): return .historyManifest(before == nil ? [item] : [])
            case .historyFetch: return .historyPage([dto])
            case .historyUpsert, .historyDelete: return .ok
            case .settingsGet: return .settings(CoreSettingsDTO(refineLevel: "light", customSystemPrompt: "", persistHistory: true))
            default: return .error("nope")
            }
        }
        let client = CoreSyncClient(transport: transport)

        let value7 = try await client.fullHistoryManifest()
        XCTAssertEqual(value7, [item])
        let value8 = try await client.historyFetch(ids: [dto.id])
        XCTAssertEqual(value8, [dto])
        try await client.historyUpsert([dto])
        try await client.replay(.historyDelete(ids: [dto.id]))
        let value9 = try await client.settingsGet().refineLevel
        XCTAssertEqual(value9, "light")

        do {
            _ = try await client.historyStats()
            XCTFail("expected RepositoryError.remote")
        } catch RepositoryError.remote(let message) {
            XCTAssertEqual(message, "nope")
        }
        XCTAssertEqual(transport.sent.count, 7)
    }

    // MARK: - RepositoryHub

    func testRepositoryHubPerDomainVersionsBumpIndependently() async throws {
        let hub = RepositoryHub(current: repositories)
        XCTAssertEqual(hub.historyVersion, 0)
        XCTAssertEqual(hub.dictionaryVersion, 0)
        XCTAssertEqual(hub.settingsVersion, 0)
        XCTAssertEqual(hub.version, 0)

        try await repositories.settings.set(CoreSettingsPatch(customSystemPrompt: "hub test"))
        // `RepositoryHub.subscribe` defers its bump by one Task hop — give
        // it a moment to run.
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(hub.settingsVersion, 1)
        XCTAssertEqual(hub.historyVersion, 0, "a settings-only change must not bump history")
        XCTAssertEqual(hub.dictionaryVersion, 0, "a settings-only change must not bump dictionary")
        XCTAssertEqual(hub.version, 1)
    }

    func testRepositoryHubInstallBumpsEveryDomainAndUnsubscribesThePreviousBundle() {
        let hub = RepositoryHub(current: repositories)
        let previous = repositories!
        XCTAssertNotNil(previous.history.onChange)

        let next = Repositories.make(container: container)
        hub.install(next)

        XCTAssertEqual(hub.historyVersion, 1)
        XCTAssertEqual(hub.dictionaryVersion, 1)
        XCTAssertEqual(hub.settingsVersion, 1)
        XCTAssertEqual(hub.version, 1)
        XCTAssertTrue(hub.current === next)
        XCTAssertNil(previous.history.onChange, "the dropped bundle must stop notifying the hub")
        XCTAssertNotNil(next.history.onChange)
    }

    func testRepositoryHubNotifyExternalChangeBumpsOnlyThatDomain() {
        let hub = RepositoryHub(current: repositories)
        hub.notifyExternalChange(.dictionary)
        XCTAssertEqual(hub.dictionaryVersion, 1)
        XCTAssertEqual(hub.historyVersion, 0)
        XCTAssertEqual(hub.settingsVersion, 0)
        XCTAssertEqual(hub.version, 1)
    }

    // MARK: - RepoRequestCorrelator

    func testCorrelatorCompletesMatchingId() async throws {
        let correlator = RepoRequestCorrelator(timeout: 5)
        let (id, task) = correlator.begin()
        correlator.complete(requestId: id, result: .ok)
        let result = try await task.value
        XCTAssertEqual(result, .ok)
    }

    /// The continuation is reserved synchronously in `begin()`, so a reply
    /// that races the caller's own send (arriving before the returned
    /// `Task` has had a chance to start awaiting it) is still delivered.
    func testCorrelatorSurvivesReplyThatRacesRegistration() async throws {
        let correlator = RepoRequestCorrelator(timeout: 5)
        let (id, task) = correlator.begin()
        correlator.complete(requestId: id, result: .historyStats(nil))
        let result = try await task.value
        XCTAssertEqual(result, .historyStats(nil))
    }

    func testCorrelatorIgnoresUnknownId() async throws {
        let correlator = RepoRequestCorrelator(timeout: 5)
        correlator.complete(requestId: "does-not-exist", result: .ok) // must not crash or affect anything

        let (id, task) = correlator.begin()
        correlator.complete(requestId: id, result: .ok)
        let result = try await task.value
        XCTAssertEqual(result, .ok)
    }

    func testCorrelatorTimesOut() async throws {
        let correlator = RepoRequestCorrelator(timeout: 0.05)
        let (_, task) = correlator.begin()
        do {
            _ = try await task.value
            XCTFail("expected RepositoryError.timeout")
        } catch RepositoryError.timeout {
            // expected
        }
    }
}

private func makeDTO(text: String, timestamp: Date = Date()) -> DictationEntryDTO {
    DictationEntryDTO(
        id: UUID(), timestamp: timestamp, text: text, durationSeconds: 1, inferenceMs: nil,
        wordCount: text.split(separator: " ").count,
        modality: "voice", source: "dictator", destinationAppBundleId: nil, destinationAppName: nil,
        destinationURL: nil, insertionMethod: nil
    )
}

/// Drives `HistoryRepository.allEntries()`'s default protocol-extension
/// implementation without needing 200+ real SwiftData rows.
@MainActor
private final class FakePagingHistoryRepository: HistoryRepository {
    var onChange: (() -> Void)?
    private var batches: [[DictationEntryDTO]]
    private(set) var requestedBefores: [HistoryCursor?] = []

    init(batches: [[DictationEntryDTO]]) {
        self.batches = batches
    }

    func page(limit: Int, before: HistoryCursor?) async throws -> [DictationEntryDTO] {
        requestedBefores.append(before)
        guard !batches.isEmpty else { return [] }
        return batches.removeFirst()
    }

    func stats() async throws -> DictationStatsDTO? { nil }
    func delete(ids: [UUID]) async throws {}
    func record(_ entry: HistoryRecordDTO) async throws {}
}

/// Test-only ownership barrier: never unlink a SQLite fixture while its
/// repositories or container are alive. Waiting observes actual ownership;
/// there is no fixed settling sleep and a failed release leaves files intact.
@MainActor
final class WeakTestStoreOwner {
    weak var value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
}

@MainActor
enum TestStoreTeardown {
    static func remove(
        _ roots: [URL], afterReleasing owners: [WeakTestStoreOwner],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while owners.contains(where: { $0.value != nil }) {
            guard clock.now < deadline else {
                XCTFail("Test store still has live owners; leaving its files intact.", file: file, line: line)
                return
            }
            await Task.yield()
        }
        try autoreleasepool {
            for root in roots { try FileManager.default.removeItem(at: root) }
        }
    }
}
