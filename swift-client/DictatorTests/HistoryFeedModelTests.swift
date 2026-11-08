import SwiftData
import XCTest
@testable import Dictator

/// Drives `HistoryFeedModel` (the view model behind `HistoryView`) against
/// `Repositories.make(container:)` on a temp `PersistenceLoader.load(applicationSupport:)`
/// container — the same seam `RepositoriesTests`/`HardeningTests` use — plus
/// `HistoryDestructiveAction` (the shared delete guard) against fake
/// repository bundles for the race/identity scenarios that need control over
/// exactly when a `page()` call resolves.
@MainActor
final class HistoryFeedModelTests: XCTestCase {
    private var tempRoot: URL!
    private var container: ModelContainer!
    private var repositories: Repositories!

    private var savedPersistHistory = false
    private var savedSurfacePolicyJSON = ""

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dictator-HistoryFeedModelTests-\(UUID().uuidString)", isDirectory: true
        )
        let result = PersistenceLoader.load(applicationSupport: tempRoot)
        container = try XCTUnwrap(result.container)
        repositories = Repositories.make(container: container)

        let settings = AppSettings.shared
        savedPersistHistory = settings.persistHistory
        savedSurfacePolicyJSON = settings.cachedSurfacePolicyJSON
        settings.persistHistory = true
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "save", defaultVoice: "save", rules: []))
    }

    override func tearDown() async throws {
        let settings = AppSettings.shared
        settings.persistHistory = savedPersistHistory
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

    func testReloadShowsRecordedEntriesNewestFirst() async throws {
        let model = HistoryFeedModel()
        XCTAssertTrue(model.entries.isEmpty)

        try await repositories.history.record(makeRecord(text: "first"))
        try await Task.sleep(nanoseconds: 2_000_000)
        try await repositories.history.record(makeRecord(text: "second"))

        await model.reload(from: repositories)

        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.entries.map(\.text), ["second", "first"])
    }

    /// `HistoryFeedModel` doesn't reload itself after a mutation —
    /// deleting goes through the shared `HistoryDestructiveAction` guard, and
    /// refreshing the list is `RepositoryHub`'s version-bump-driven job (see
    /// `HistoryView`'s `.onChange(of: hub?.historyVersion)`). This test drives
    /// both steps explicitly, the way the view does in production.
    func testDeleteRemovesEntryAndSubsequentReloadReflectsIt() async throws {
        try await repositories.history.record(makeRecord(text: "keep"))
        try await Task.sleep(nanoseconds: 2_000_000)
        try await repositories.history.record(makeRecord(text: "drop"))

        let hub = RepositoryHub(current: repositories)
        let model = HistoryFeedModel()
        await model.reload(from: hub.current)
        let toDelete = try XCTUnwrap(model.entries.first { $0.text == "drop" }?.id)

        let error = await HistoryDestructiveAction.delete(
            ids: [toDelete], boundTo: hub.current, hub: hub, expectedVersion: hub.historyVersion
        )
        XCTAssertNil(error)

        await model.reload(from: hub.current)
        XCTAssertEqual(model.entries.map(\.text), ["keep"])
    }

    /// A delete must also abort if the bound repository's history
    /// version has drifted since confirmation (something else mutated the
    /// same store in between), even though the repository identity itself
    /// didn't change.
    func testDeleteAbortsWhenHistoryVersionChangedSinceConfirmation() async throws {
        try await repositories.history.record(makeRecord(text: "keep-me-2"))
        let hub = RepositoryHub(current: repositories)

        let boundRepo = hub.current
        let confirmedIds = try await boundRepo.history.page(limit: 10, before: nil).map(\.id)
        let confirmedVersion = hub.historyVersion

        // Something else mutates the same repository, bumping historyVersion,
        // before the guarded delete executes.
        try await repositories.history.record(makeRecord(text: "new-arrival"))
        await waitUntil { hub.historyVersion != confirmedVersion }

        let error = await HistoryDestructiveAction.delete(
            ids: confirmedIds, boundTo: boundRepo, hub: hub, expectedVersion: confirmedVersion
        )

        XCTAssertEqual(error, "History changed after Dictator checked it. Choose Clean Up again to check the latest entries.")
        let stillThere = try await boundRepo.history.page(limit: 10, before: nil)
        XCTAssertEqual(stillThere.count, 2, "nothing should have been deleted")
    }

    /// Latest request wins: a slower, earlier `reload` must not
    /// overwrite the result of a faster, later one. Simulated with a fake
    /// `HistoryRepository` whose first `page()` call blocks on a manually
    /// resumed continuation, standing in for a slow Core round trip.
    func testLatestReloadWinsOverSlowerEarlierOne() async throws {
        let blockedEntries = [makeDTO(text: "stale")]
        let freshEntries = [makeDTO(text: "fresh")]
        let blockedRepo = ContinuationHistoryRepository(result: blockedEntries, blocksFirstCall: true)
        let freshRepo = ContinuationHistoryRepository(result: freshEntries, blocksFirstCall: false)

        let blockedBundle = Repositories(
            history: blockedRepo, dictionary: FakeDictionaryRepository(), settings: FakeCoreSettingsRepository()
        )
        let freshBundle = Repositories(
            history: freshRepo, dictionary: FakeDictionaryRepository(), settings: FakeCoreSettingsRepository()
        )

        let model = HistoryFeedModel()

        let staleReload = Task { await model.reload(from: blockedBundle) }
        // Give the stale reload a chance to reach the blocking continuation
        // before starting the one that should win.
        await blockedRepo.waitForFirstCall()

        await model.reload(from: freshBundle)
        XCTAssertEqual(model.entries.map(\.text), ["fresh"])

        // Let the stale reload's late result land — it must not clobber the
        // fresh one that already won.
        blockedRepo.resume()
        _ = await staleReload.value
        XCTAssertEqual(model.entries.map(\.text), ["fresh"])
    }

    func testOpeningAndReturningHomeDoNotWalkWholeHistory() async throws {
        let fake = CountingHistoryRepository(batches: [[makeDTO(text: "newest")], [makeDTO(text: "older")], []])
        let bundle = Repositories(history: fake, dictionary: FakeDictionaryRepository(), settings: FakeCoreSettingsRepository())
        let model = HistoryFeedModel()
        await model.loadIfNeeded(from: bundle, version: 7)
        await Task.yield()
        XCTAssertEqual(fake.pageCalls, 1, "opening Home reads only one page, even if it is short")
        XCTAssertEqual(model.entries.map(\.text), ["newest"])
        XCTAssertTrue(model.hasMore)

        await model.loadMore(from: bundle)
        XCTAssertEqual(model.entries.map(\.text), ["newest", "older"])
        XCTAssertTrue(model.hasMore, "a short page does not imply end of history")
        await model.loadIfNeeded(from: bundle, version: 7)
        XCTAssertEqual(fake.pageCalls, 2, "returning Home reuses all loaded pages")
        XCTAssertEqual(fake.metadataCalls, 1)

        await model.loadMore(from: bundle)
        XCTAssertFalse(model.hasMore)
        await model.loadMore(from: bundle)
        XCTAssertEqual(fake.pageCalls, 3, "an empty page ends pagination")
    }

    func testHistoryRevisionInvalidatesHomeCache() async throws {
        let fake = CountingHistoryRepository(batches: [[makeDTO(text: "before")], [makeDTO(text: "after")]])
        let bundle = Repositories(history: fake, dictionary: FakeDictionaryRepository(), settings: FakeCoreSettingsRepository())
        let model = HistoryFeedModel()
        await model.loadIfNeeded(from: bundle, version: 1)
        await model.loadIfNeeded(from: bundle, version: 2)
        XCTAssertEqual(model.entries.map(\.text), ["after"])
        XCTAssertEqual(fake.pageCalls, 2)
        XCTAssertEqual(fake.metadataCalls, 2)
    }

    func testPagingPreservesFlatFeedIdentitiesAcrossDayBoundary() async throws {
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<109).map { makeDTO(text: "synthetic \($0)", timestamp: newest.addingTimeInterval(-Double($0))) }
        let fake = CountingHistoryRepository(batches: [Array(entries.prefix(100)), Array(entries.dropFirst(100)), []])
        let bundle = Repositories(history: fake, dictionary: FakeDictionaryRepository(), settings: FakeCoreSettingsRepository())
        let model = HistoryFeedModel()
        let label: (Date) -> String = { $0 > newest.addingTimeInterval(-102.5) ? "Today" : "Yesterday" }
        await model.loadIfNeeded(from: bundle, version: 1)
        let initial = HistoryFeedItem.make(from: model.entries, dayLabel: label)
        XCTAssertEqual(initial.count, 101)

        await model.loadMore(from: bundle)
        let expanded = HistoryFeedItem.make(from: model.entries, dayLabel: label)

        XCTAssertEqual(expanded.count, 111, "109 rows and exactly two day headers")
        XCTAssertEqual(Array(expanded.prefix(initial.count)).map(\.id), initial.map(\.id), "pagination preserves existing lazy item identities")
        XCTAssertEqual(expanded.compactMap { item -> UUID? in
            if case .entry(let entry) = item { return entry.id }
            return nil
        }, entries.map(\.id), "every loaded row stays present, ordered and represented once")
        XCTAssertEqual(Set(expanded.map(\.id)).count, expanded.count)
        XCTAssertEqual(expanded.compactMap { item -> String? in
            if case .day(let label) = item { return label }
            return nil
        }, ["Today", "Yesterday"])
    }

    func testOlderPageCannotAppendAfterNewReload() async throws {
        let old = ContinuationHistoryRepository(result: [makeDTO(text: "stale older")], blocksFirstCall: false, blocksSecondCall: true)
        let fresh = CountingHistoryRepository(batches: [[makeDTO(text: "fresh")]])
        let oldBundle = Repositories(history: old, dictionary: FakeDictionaryRepository(), settings: FakeCoreSettingsRepository())
        let freshBundle = Repositories(history: fresh, dictionary: FakeDictionaryRepository(), settings: FakeCoreSettingsRepository())
        let model = HistoryFeedModel()
        await model.reload(from: oldBundle)
        let paging = Task { await model.loadMore(from: oldBundle) }
        await old.waitForFirstCall()
        await model.loadMore(from: oldBundle)
        XCTAssertTrue(model.isLoadingMore, "duplicate load-more requests leave the in-flight page alone")
        await model.reload(from: freshBundle)
        old.resume()
        await paging.value
        XCTAssertEqual(model.entries.map(\.text), ["fresh"])
        XCTAssertFalse(model.isLoadingMore)
    }

    func testFilterFindsOlderEntriesOutsideInitialPage() async throws {
        let context = ModelContext(container)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<250 {
            let entry = DictationEntry(text: "spoken \(i)", durationSeconds: 1, destinationAppName: "Recent app")
            entry.timestamp = timestamp.addingTimeInterval(Double(i))
            context.insert(entry)
        }
        let old = DictationEntry(text: "older typed text", durationSeconds: 0, modality: "typed", destinationAppName: "  Older app  ")
        old.timestamp = timestamp.addingTimeInterval(-1)
        context.insert(old)
        try context.save()
        let model = HistoryFeedModel()
        await model.loadIfNeeded(from: repositories, version: 0)
        XCTAssertEqual(model.entries.count, 100)
        XCTAssertFalse(model.entries.contains { $0.id == old.id })
        XCTAssertTrue(model.destinations.contains("Older app"), "the menu includes destinations in unloaded history")
        model.filterID = "typed"
        await model.loadIfNeeded(from: repositories, version: 0)
        XCTAssertEqual(model.entries.map(\.text), ["older typed text"])
        model.filterID = "destination:Older app"
        await model.loadIfNeeded(from: repositories, version: 0)
        XCTAssertEqual(model.entries.map(\.text), ["older typed text"])
        let all = try await repositories.history.allEntries()
        XCTAssertEqual(all.count, 251, "whole-store actions do not use the feed's page or filter")
    }

    private func makeRecord(text: String) -> HistoryRecordDTO {
        HistoryRecordDTO(
            text: text, durationSeconds: 1, inferenceMs: nil, modality: "voice", source: "dictator"
        )
    }

    /// Polls `condition` on the main actor until it's true or a short budget
    /// elapses — `RepositoryHub`'s `onChange` bump lands via a hop through
    /// `Task { @MainActor in ... }`, not synchronously with the mutating call.
    private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private func makeDTO(text: String, timestamp: Date = Date()) -> DictationEntryDTO {
    DictationEntryDTO(
        id: UUID(), timestamp: timestamp, text: text, durationSeconds: 1, inferenceMs: nil, wordCount: 1,
        modality: "voice", source: "dictator", destinationAppBundleId: nil, destinationAppName: nil,
        destinationURL: nil, insertionMethod: nil, truncated: nil
    )
}

/// Stands in for a slow/controllable Core round trip: the first `page()`
/// call (when `blocksFirstCall`) suspends on a continuation the test resumes
/// explicitly, so a test can deterministically order two concurrent reloads.
@MainActor
private final class ContinuationHistoryRepository: HistoryRepository {
    var onChange: (() -> Void)?

    private let result: [DictationEntryDTO]
    private let blocksFirstCall: Bool
    private let blocksSecondCall: Bool
    private var callCount = 0
    private var continuation: CheckedContinuation<[DictationEntryDTO], Error>?
    private var firstCallReached: CheckedContinuation<Void, Never>?
    private var didReachFirstCall = false
    /// `HistoryFeedModel`'s background pager keeps calling `page()` until an
    /// empty page (a short-but-nonempty page can be mid-store under
    /// byte-budget pagination), so this fake must return
    /// `result` exactly once and `[]` on every call after, or the model's
    /// "keep paging past a non-empty page" loop never terminates.
    private var hasReturnedResult = false

    init(result: [DictationEntryDTO], blocksFirstCall: Bool, blocksSecondCall: Bool = false) {
        self.result = result
        self.blocksFirstCall = blocksFirstCall
        self.blocksSecondCall = blocksSecondCall
    }

    func destinationNames() async throws -> [String] { [] }

    func page(limit: Int, before: HistoryCursor?) async throws -> [DictationEntryDTO] {
        callCount += 1
        if blocksFirstCall && callCount == 1 || blocksSecondCall && callCount == 2 {
            didReachFirstCall = true
            firstCallReached?.resume()
            firstCallReached = nil
            let value = try await withCheckedThrowingContinuation { self.continuation = $0 }
            hasReturnedResult = true
            return value
        }
        guard !hasReturnedResult else { return [] }
        hasReturnedResult = true
        return result
    }

    func stats() async throws -> DictationStatsDTO? { nil }
    func delete(ids: [UUID]) async throws {}
    func record(_ entry: HistoryRecordDTO) async throws {}

    func resume() {
        continuation?.resume(returning: result)
        continuation = nil
    }

    /// Suspends until this fake's blocking `page()` call has actually been
    /// entered, so the test doesn't race a fixed `sleep` against it.
    func waitForFirstCall() async {
        if didReachFirstCall { return }
        await withCheckedContinuation { self.firstCallReached = $0 }
    }
}

@MainActor
private final class FakeDictionaryRepository: DictionaryRepository {
    var onChange: (() -> Void)?
    func page(limit: Int, afterPattern: String?) async throws -> [DictionaryEntryDTO] { [] }
    func upsert(_ entries: [DictionaryEntryDTO]) async throws {}
    func delete(ids: [UUID]) async throws {}
}

@MainActor
private final class FakeCoreSettingsRepository: CoreSettingsRepository {
    var onChange: (() -> Void)?
    func get() async throws -> CoreSettingsDTO {
        CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true)
    }
    func set(_ patch: CoreSettingsPatch) async throws {}
}

@MainActor
private final class CountingHistoryRepository: HistoryRepository {
    var onChange: (() -> Void)?
    var pageCalls = 0
    var metadataCalls = 0
    let batches: [[DictationEntryDTO]]

    init(batches: [[DictationEntryDTO]]) { self.batches = batches }
    func page(limit: Int, before: HistoryCursor?) async throws -> [DictationEntryDTO] {
        defer { pageCalls += 1 }
        return pageCalls < batches.count ? batches[pageCalls] : []
    }
    func destinationNames() async throws -> [String] { metadataCalls += 1; return [] }
    func stats() async throws -> DictationStatsDTO? { nil }
    func delete(ids: [UUID]) async throws {}
    func record(_ entry: HistoryRecordDTO) async throws {}
}

extension HistoryFeedModelTests {
    func testCorrectionChipsKeepTheExactSelectedSpan() {
        let text = "Meet Zandor,  then Xandar."
        let ranges = HistoryCorrectionWords.ranges(in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Meet", "Zandor", "then", "Xandar"])
        XCTAssertEqual(HistoryCorrectionWords.heard(in: text, ranges: ranges, selection: 1...2), "Zandor,  then")
        XCTAssertEqual(HistoryCorrectionWords.heard(in: text, ranges: ranges, selection: nil), "")
        XCTAssertEqual(HistoryCorrectionWords.heard(in: text, ranges: ranges, selection: 8...9), "")
    }
}
