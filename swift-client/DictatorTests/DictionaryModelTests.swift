import SwiftData
import SwiftUI
import AppKit
import XCTest
@testable import Dictator

/// Drives `DictionaryModel` (the view model behind `DictionaryView`)
/// against `Repositories.make(container:)` on a temp
/// `PersistenceLoader.load(applicationSupport:)` container — the same seam
/// `RepositoriesTests`/`HardeningTests` use.
@MainActor
final class DictionaryModelTests: XCTestCase {
    private var tempRoot: URL!
    private var container: ModelContainer!
    private var repositories: Repositories!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Dictator-DictionaryModelTests-\(UUID().uuidString)", isDirectory: true
        )
        let result = PersistenceLoader.load(applicationSupport: tempRoot)
        container = try XCTUnwrap(result.container)
        repositories = Repositories.make(container: container)
    }

    override func tearDown() async throws {
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

    /// `upsert`/`delete` don't reload themselves (that's
    /// `RepositoryHub.dictionaryVersion`'s job in production, via
    /// `DictionaryView`'s `.onChange`); this test reloads explicitly after
    /// each mutation the way the view's reactive path eventually would.
    func testAddEditDeleteRoundTrip() async throws {
        let model = DictionaryModel()
        await model.reload(from: repositories)
        XCTAssertTrue(model.entries.isEmpty)

        let id = UUID()
        await model.upsert([DictionaryEntryDTO(id: id, pattern: "teh", replacement: "the", isVocabulary: false)], repositories: repositories)
        XCTAssertNil(model.loadError)
        await model.reload(from: repositories)
        XCTAssertEqual(model.entries.map(\.replacement), ["the"])

        // Same id again is an edit, not a second row.
        await model.upsert([DictionaryEntryDTO(id: id, pattern: "teh", replacement: "them", isVocabulary: false)], repositories: repositories)
        await model.reload(from: repositories)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.replacement, "them")

        await model.delete(ids: [id], repositories: repositories)
        await model.reload(from: repositories)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testReloadSortsByPattern() async throws {
        try await repositories.dictionary.upsert([
            DictionaryEntryDTO(id: UUID(), pattern: "zebra", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "apple", replacement: "", isVocabulary: true),
        ])

        let model = DictionaryModel()
        await model.reload(from: repositories)

        XCTAssertEqual(model.entries.map(\.pattern), ["apple", "zebra"])
    }

    /// Mirrors `DictionaryImportParser`'s existing-key matching: a candidate
    /// whose (vocabulary/replacement, normalized pattern) key already exists
    /// is not a new import candidate.
    func testImportCandidatesSkipExistingPatterns() throws {
        let existing = [
            DictionaryEntryDTO(id: UUID(), pattern: "Claude Code", replacement: "", isVocabulary: true),
        ]
        let existingKeys = Set(DictionaryImportParser.existingEntriesByKey(existing).keys)

        let candidates = DictionaryImportParser.parse("Claude Code\nGitHub")
        let newOnes = candidates.filter { !existingKeys.contains($0.key) }

        XCTAssertEqual(newOnes.map(\.pattern), ["GitHub"])
    }

    /// Latest request wins: a slower, earlier `reload` must not
    /// overwrite a faster, later one's result. Simulated with a fake
    /// `DictionaryRepository` whose first `entries()` call blocks on a
    /// manually resumed continuation.
    func testLatestReloadWinsOverSlowerEarlierOne() async throws {
        let staleEntries = [DictionaryEntryDTO(id: UUID(), pattern: "stale", replacement: "", isVocabulary: true)]
        let freshEntries = [DictionaryEntryDTO(id: UUID(), pattern: "fresh", replacement: "", isVocabulary: true)]
        let blockedRepo = ContinuationDictionaryRepository(result: staleEntries, blocksFirstCall: true)
        let freshRepo = ContinuationDictionaryRepository(result: freshEntries, blocksFirstCall: false)

        let blockedBundle = Repositories(
            history: FakeHistoryRepository(), dictionary: blockedRepo, settings: FakeCoreSettingsRepository()
        )
        let freshBundle = Repositories(
            history: FakeHistoryRepository(), dictionary: freshRepo, settings: FakeCoreSettingsRepository()
        )

        let model = DictionaryModel()

        let staleReload = Task { await model.reload(from: blockedBundle) }
        await blockedRepo.waitForFirstCall()

        await model.reload(from: freshBundle)
        XCTAssertEqual(model.entries.map(\.pattern), ["fresh"])

        blockedRepo.resume()
        _ = await staleReload.value
        XCTAssertEqual(model.entries.map(\.pattern), ["fresh"])
    }

    /// A failed Add reports why and returns false (so the sheet keeps
    /// its values); retrying with the same entry then creates exactly one.
    func testFailedAddKeepsErrorAndRetryCreatesExactlyOneEntry() async throws {
        let repo = InMemoryDictionaryRepository()
        repo.failNextWrite = true
        let bundle = Repositories(history: FakeHistoryRepository(), dictionary: repo, settings: FakeCoreSettingsRepository())
        let model = DictionaryModel()
        let entry = DictionaryEntryDTO(id: UUID(), pattern: "Dictator", replacement: "", isVocabulary: true)

        let first = await model.add(entry, repositories: bundle)
        XCTAssertFalse(first)
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(model.isSaving)
        XCTAssertTrue(repo.stored.isEmpty)

        let retry = await model.add(entry, repositories: bundle)
        XCTAssertTrue(retry)
        XCTAssertNil(model.saveError)
        XCTAssertEqual(repo.stored.map(\.pattern), ["Dictator"])
    }

    /// A second Add while the first is still saving is ignored.
    func testAddIgnoresASecondSubmitWhileSaving() async throws {
        let repo = InMemoryDictionaryRepository()
        repo.holdWrites = true
        let bundle = Repositories(history: FakeHistoryRepository(), dictionary: repo, settings: FakeCoreSettingsRepository())
        let model = DictionaryModel()
        let entry = DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false)

        let firstSave = Task { await model.add(entry, repositories: bundle) }
        await repo.waitForHeldWrite()
        XCTAssertTrue(model.isSaving)
        let duplicate = await model.add(DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false), repositories: bundle)
        XCTAssertFalse(duplicate)
        repo.releaseHeldWrite()
        let saved = await firstSave.value
        XCTAssertTrue(saved)
        XCTAssertEqual(repo.stored.count, 1)
    }

    /// The trash button's delete can be undone, restoring the same entry.
    func testDeleteCanBeUndone() async throws {
        let repo = InMemoryDictionaryRepository()
        let entry = DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false)
        repo.stored = [entry]
        let bundle = Repositories(history: FakeHistoryRepository(), dictionary: repo, settings: FakeCoreSettingsRepository())
        let model = DictionaryModel()

        await model.delete(entry, repositories: bundle)
        XCTAssertTrue(repo.stored.isEmpty)
        XCTAssertEqual(model.recentlyDeleted, entry)

        await model.undoDelete(repositories: bundle)
        XCTAssertEqual(repo.stored, [entry])
        XCTAssertNil(model.recentlyDeleted)
    }

    /// A failed delete keeps the entry and offers no Undo.
    func testFailedDeleteOffersNoUndo() async throws {
        let repo = InMemoryDictionaryRepository()
        let entry = DictionaryEntryDTO(id: UUID(), pattern: "teh", replacement: "the", isVocabulary: false)
        repo.stored = [entry]
        repo.failNextWrite = true
        let bundle = Repositories(history: FakeHistoryRepository(), dictionary: repo, settings: FakeCoreSettingsRepository())
        let model = DictionaryModel()

        await model.delete(entry, repositories: bundle)
        XCTAssertEqual(repo.stored, [entry])
        XCTAssertNil(model.recentlyDeleted)
        XCTAssertNotNil(model.loadError)
    }
}

/// An in-memory dictionary whose next write can be made to fail, or held
/// until the test releases it.
@MainActor
private final class InMemoryDictionaryRepository: DictionaryRepository {
    struct WriteFailed: LocalizedError { var errorDescription: String? { "The disk is full." } }

    var onChange: (() -> Void)?
    var stored: [DictionaryEntryDTO] = []
    var failNextWrite = false
    var holdWrites = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldReached: CheckedContinuation<Void, Never>?

    func page(limit: Int, afterPattern: String?) async throws -> [DictionaryEntryDTO] {
        afterPattern == nil ? stored : []
    }

    func upsert(_ entries: [DictionaryEntryDTO]) async throws {
        try await write()
        for entry in entries {
            stored.removeAll { $0.id == entry.id }
            stored.append(entry)
        }
    }

    func delete(ids: [UUID]) async throws {
        try await write()
        stored.removeAll { ids.contains($0.id) }
    }

    private func write() async throws {
        if failNextWrite {
            failNextWrite = false
            throw WriteFailed()
        }
        if holdWrites {
            holdWrites = false
            await withCheckedContinuation { continuation in
                held = continuation
                heldReached?.resume()
                heldReached = nil
            }
        }
    }

    func waitForHeldWrite() async {
        if held != nil { return }
        await withCheckedContinuation { heldReached = $0 }
    }

    func releaseHeldWrite() {
        held?.resume()
        held = nil
    }
}

/// Stands in for a slow/controllable Core round trip: the first `entries()`
/// call (when `blocksFirstCall`) suspends on a continuation the test resumes
/// explicitly, so a test can deterministically order two concurrent reloads.
@MainActor
private final class ContinuationDictionaryRepository: DictionaryRepository {
    var onChange: (() -> Void)?

    private let result: [DictionaryEntryDTO]
    private let blocksFirstCall: Bool
    private var callCount = 0
    private var continuation: CheckedContinuation<[DictionaryEntryDTO], Error>?
    private var firstCallReached: CheckedContinuation<Void, Never>?
    private var didReachFirstCall = false

    init(result: [DictionaryEntryDTO], blocksFirstCall: Bool) {
        self.result = result
        self.blocksFirstCall = blocksFirstCall
    }

    func entries() async throws -> [DictionaryEntryDTO] {
        callCount += 1
        if blocksFirstCall && callCount == 1 {
            didReachFirstCall = true
            firstCallReached?.resume()
            firstCallReached = nil
            return try await withCheckedThrowingContinuation { self.continuation = $0 }
        }
        return result
    }

    func page(limit: Int, afterPattern: String?) async throws -> [DictionaryEntryDTO] { [] }
    func upsert(_ entries: [DictionaryEntryDTO]) async throws {}
    func delete(ids: [UUID]) async throws {}

    func resume() {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func waitForFirstCall() async {
        if didReachFirstCall { return }
        await withCheckedContinuation { self.firstCallReached = $0 }
    }
}

@MainActor
private final class FakeHistoryRepository: HistoryRepository {
    var onChange: (() -> Void)?
    func page(limit: Int, before: HistoryCursor?) async throws -> [DictationEntryDTO] { [] }
    func stats() async throws -> DictationStatsDTO? { nil }
    func delete(ids: [UUID]) async throws {}
    func record(_ entry: HistoryRecordDTO) async throws {}
}

@MainActor
private final class FakeCoreSettingsRepository: CoreSettingsRepository {
    var onChange: (() -> Void)?
    func get() async throws -> CoreSettingsDTO {
        CoreSettingsDTO(refineLevel: "medium", customSystemPrompt: "", persistHistory: true)
    }
    func set(_ patch: CoreSettingsPatch) async throws {}
}

extension DictionaryModelTests {
    func testGroupsFinalSpellingsRulesAndHidesForgottenRows() {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "Zandor", replacement: "xandor", isVocabulary: false, origin: "learned"),
            DictionaryEntryDTO(id: UUID(), pattern: "Sander", replacement: "Xandor", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "hidden", replacement: "", isVocabulary: true, isForgotten: true),
        ]
        let groups = DictionaryWords.groups(rows)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].spelling, "Xandor")
        XCTAssertEqual(Set(groups[0].heardAs), ["Zandor", "Sander"])
        XCTAssertTrue(groups[0].learned)
        XCTAssertEqual(DictionaryWords.groups(rows, search: "zand").count, 1)
        XCTAssertTrue(DictionaryWords.groups(rows, search: "hidden").isEmpty)
    }

    func testGroupSortsStarThenUsageThenAlphabetically() {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "Zulu", replacement: "", isVocabulary: true, isStarred: true),
            DictionaryEntryDTO(id: UUID(), pattern: "Beta", replacement: "", isVocabulary: true, useCount: 8),
            DictionaryEntryDTO(id: UUID(), pattern: "Alpha", replacement: "", isVocabulary: true, useCount: 8),
            // Usage of a grouped word is the highest stored count, not the sum
            // of its rules: each rule can count the same final dictated term.
            DictionaryEntryDTO(id: UUID(), pattern: "Alfa", replacement: "Alpha", isVocabulary: false, useCount: 8),
            DictionaryEntryDTO(id: UUID(), pattern: "Gamma", replacement: "", isVocabulary: true, useCount: 1),
        ]
        XCTAssertEqual(DictionaryWords.groups(rows).map(\.spelling), ["Zulu", "Alpha", "Beta", "Gamma"])
        XCTAssertEqual(DictionaryWords.groups(rows).first { $0.spelling == "Alpha" }?.useCount, 8)
    }

    func testFieldChipMovesAutomaticOnToOffAndBackToExplicitOn() {
        var on = ["future-field"]
        var off: [String] = []
        XCTAssertTrue(DictionaryFields.isOn("medicine", automatic: true, on: on, off: off, automaticIDs: ["medicine"]))
        DictionaryFields.toggle("medicine", automatic: true, on: &on, off: &off, automaticIDs: ["medicine"])
        XCTAssertEqual(off, ["medicine"])
        XCTAssertEqual(on, ["future-field"])
        DictionaryFields.toggle("medicine", automatic: true, on: &on, off: &off, automaticIDs: ["medicine"])
        XCTAssertEqual(on, ["future-field", "medicine"])
        XCTAssertTrue(off.isEmpty)
        XCTAssertTrue(DictionaryFields.isOn("medicine", automatic: false, on: on, off: off, automaticIDs: []))
        DictionaryFields.toggle("law", automatic: false, on: &on, off: &off, automaticIDs: [])
        XCTAssertTrue(on.contains("law"))
        XCTAssertFalse(DictionaryFields.isOn("medicine", automatic: true, on: on, off: ["medicine"], automaticIDs: ["medicine"]))
    }

    func testDeleteAndUndoEntireMixedGroupWithLearnedTombstones() async throws {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true, isStarred: true, useCount: 7, origin: "learned"),
            DictionaryEntryDTO(id: UUID(), pattern: "Zandor", replacement: "Xandor", isVocabulary: false, origin: "learned"),
            DictionaryEntryDTO(id: UUID(), pattern: "Sander", replacement: "Xandor", isVocabulary: false, origin: "manual"),
        ]
        try await repositories.dictionary.upsert(rows)
        let model = DictionaryModel()
        await model.deleteGroup(rows, repositories: repositories)
        await model.reload(from: repositories)
        XCTAssertTrue(model.entries.isEmpty)
        let deleted = try await repositories.dictionary.entries()
        XCTAssertEqual(deleted.filter { $0.isForgotten == true }.count, 2)
        XCTAssertNotNil(model.recentlyDeleted)
        await model.undoDelete(repositories: repositories)
        await model.reload(from: repositories)
        XCTAssertEqual(model.entries.count, 3)
        let stored = try await repositories.dictionary.entries()
        XCTAssertEqual(Set(stored.map(\.id)), Set(rows.map(\.id)))
        XCTAssertTrue(stored.allSatisfy { $0.isForgotten != true })
        let group = try XCTUnwrap(DictionaryWords.groups(model.entries).first)
        XCTAssertEqual(Set(group.heardAs), ["Zandor", "Sander"])
        XCTAssertTrue(group.starred)
        XCTAssertEqual(group.useCount, 7)
        XCTAssertEqual(model.entries.first { $0.origin == "manual" }?.id, rows[2].id)
        XCTAssertNil(model.recentlyDeleted)
    }

    func testEditPreservesIdentityAndMetadataAndRemovesHeardAs() async throws {
        let word = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true, isStarred: true, useCount: 9, origin: "manual")
        let rule = DictionaryEntryDTO(id: UUID(), pattern: "Zandor", replacement: "Xandor", isVocabulary: false)
        let removed = DictionaryEntryDTO(id: UUID(), pattern: "Sander", replacement: "Xandor", isVocabulary: false)
        try await repositories.dictionary.upsert([word, rule, removed])
        let model = DictionaryModel()
        let saved = await model.saveWord(word: "Xander", heardAs: ["Zandor", "Xandar", "xandar", ""],
                                         original: [word, rule, removed], newID: UUID(), repositories: repositories)
        XCTAssertTrue(saved)
        await model.reload(from: repositories)
        XCTAssertEqual(model.entries.count, 3)
        let edited = try XCTUnwrap(model.entries.first { $0.id == word.id })
        XCTAssertEqual(edited.pattern, "Xander")
        XCTAssertEqual(edited.useCount, 9)
        XCTAssertEqual(edited.isStarred, true)
        XCTAssertEqual(model.entries.first { $0.id == rule.id }?.replacement, "Xander")
        XCTAssertFalse(model.entries.contains { $0.id == removed.id })
    }

    func testFailedGroupEditKeepsSheetErrorAndRestoresOriginal() async throws {
        let repo = InMemoryDictionaryRepository()
        let original = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        repo.stored = [original]
        repo.failNextWrite = true
        let bundle = Repositories(history: FakeHistoryRepository(), dictionary: repo, settings: FakeCoreSettingsRepository())
        let model = DictionaryModel()
        let saved = await model.saveWord(word: "Xander", heardAs: ["Zandor"], original: [original], newID: UUID(), repositories: bundle)
        XCTAssertFalse(saved)
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(repo.stored, [original])
    }

    func testImportConflictReplaceUpdatesExistingID() async throws {
        let existing = DictionaryEntryDTO(id: UUID(), pattern: "Zandor", replacement: "Xandor", isVocabulary: false, isStarred: true, useCount: 3)
        let candidates = DictionaryImportParser.parse("Zandor -> Xander\nNewName\nNewName")
        XCTAssertEqual(DictionaryWords.importing(candidates, existing: [existing], replace: false).map(\.pattern), ["NewName"])
        let writes = DictionaryWords.importing(candidates, existing: [existing], replace: true)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].id, existing.id)
        XCTAssertEqual(writes[0].replacement, "Xander")
        XCTAssertEqual(writes[0].isStarred, true)
        XCTAssertEqual(writes[0].useCount, 3)
        try await repositories.dictionary.upsert([existing])
        try await repositories.dictionary.upsert(writes)
        let rows = try await repositories.dictionary.entries()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == existing.id }?.replacement, "Xander")
    }

    func testExportImportRoundTripIncludingEscapedWords() {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "Zandor", replacement: "Xandor", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "#Name", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "a -> b", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "two\nlines", replacement: "right\nlines", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "@word name", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "forgotten", replacement: "", isVocabulary: true, isForgotten: true),
        ]
        let exported = DictionaryWords.export(rows)
        let imported = DictionaryWords.importing(DictionaryImportParser.parse(exported), existing: [], replace: false)
        let signature: (DictionaryEntryDTO) -> String = { "\($0.isVocabulary)|\($0.pattern)|\($0.replacement)" }
        XCTAssertEqual(Set(imported.map(signature)), Set(rows.filter { $0.isForgotten != true }.map(signature)))
        XCTAssertTrue(exported.contains("Zandor -> Xandor"))
    }

    func testPhrasePreviewUsesDictationFiltering() {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "cloud code", replacement: "Claude Code", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "API", replacement: "", isVocabulary: true, origin: "learned"),
            DictionaryEntryDTO(id: UUID(), pattern: "hidden", replacement: "Wrong", isVocabulary: false, isForgotten: true),
        ]
        XCTAssertEqual(DictionaryWords.matching(rows).count, 1)
        XCTAssertEqual(CleanupPrompt.applyReplacements("cloud code and hidden", dictionary: DictionaryWords.matching(rows)), "Claude Code and hidden")
    }
}


extension DictionaryModelTests {
    func testEditLearnedWordKeepsItsOriginAndUsage() {
        let original = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true,
                                          isStarred: true, useCount: 8, origin: "learned")
        let edited = DictionaryWords.edited(word: "Xander", heardAs: [], original: [original], newID: UUID())
        XCTAssertEqual(edited[0].id, original.id)
        XCTAssertEqual(edited[0].origin, "learned")
        XCTAssertEqual(edited[0].useCount, 8)
        XCTAssertEqual(edited[0].isStarred, true)
    }

    func testLegacyImportDoesNotInterpretEscapeLookingWordWithoutHeader() {
        let word = #"@word ["Name","","word"]"#
        XCTAssertEqual(DictionaryImportParser.parse(word).first?.pattern, word)
        XCTAssertEqual(DictionaryImportParser.parse("# Dictator words 1\r\n" + word).first?.pattern, "Name")
    }
}


extension DictionaryModelTests {
    func testPreviewUsesThePagesLoadedEntriesAndDictationBuilder() async throws {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "Moptop", replacement: "", isVocabulary: true, isStarred: true),
            DictionaryEntryDTO(id: UUID(), pattern: "mop top", replacement: "Moptop", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "Frequent", replacement: "", isVocabulary: true, useCount: 30),
            DictionaryEntryDTO(id: UUID(), pattern: "Learned", replacement: "", isVocabulary: true, origin: "learned"),
            DictionaryEntryDTO(id: UUID(), pattern: "Forgotten", replacement: "", isVocabulary: true, isStarred: true, isForgotten: true),
        ]
        let repo = InMemoryDictionaryRepository()
        repo.stored = rows
        let bundle = Repositories(history: FakeHistoryRepository(), dictionary: repo, settings: FakeCoreSettingsRepository())
        let model = DictionaryModel()
        func terms() -> [String] {
            VocabularyHint.orderedTerms(VocabularyHint.vocabularyHintInput(entries: model.entries,
                ownerNames: [], voiceLaunch: [], forVoiceCommandSession: false, automatic: false, on: [], off: [],
                installedBundleIDs: [], destinationBundleID: nil, languages: ["en"], catalog: []))
        }
        XCTAssertTrue(terms().isEmpty)
        await model.reload(from: bundle)
        XCTAssertEqual(terms(), ["Moptop", "Frequent", "Learned"])
        XCTAssertEqual(Set(terms()), Set(DictionaryWords.groups(model.entries).map(\.spelling)))
        // Reloaded edits immediately feed the preview, without a hub-version
        // task racing the dictionary load or a second singleton store read.
        repo.stored = [DictionaryEntryDTO(id: UUID(), pattern: "New Star", replacement: "", isVocabulary: true, isStarred: true)]
        await model.reload(from: bundle)
        XCTAssertEqual(terms(), ["New Star"])
    }

    func testPatternCursorAndPageSortUseTheSameComparison() throws {
        let rows = ["Moptop", "mop top", "GitHub", "git hub", "Kineret"].map {
            DictionaryEntryDTO(id: UUID(), pattern: $0, replacement: "", isVocabulary: true)
        }
        let localized = rows.sorted(using: SortDescriptor(\.pattern, order: .forward))
        let oldCursor = try XCTUnwrap(localized.last?.pattern)
        XCTAssertFalse(rows.filter { $0.pattern > oldCursor }.isEmpty,
                       "A localized page leaves already-read lowercase rows beyond its lexical cursor")
        let lexical = rows.sorted(using: SortDescriptor(\.pattern, comparator: .lexical, order: .forward))
        let cursor = try XCTUnwrap(lexical.last?.pattern)
        XCTAssertTrue(rows.filter { $0.pattern > cursor }.isEmpty)
    }

    func testOneStoredHeardAsRuleAppearsOnceAcrossRepositoryPages() async throws {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "Moptop", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "mop top", replacement: "Moptop", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "GitHub", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "git hub", replacement: "GitHub", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "Kineret", replacement: "", isVocabulary: true),
        ]
        try await repositories.dictionary.upsert(rows)
        let loaded = try await repositories.dictionary.entries()
        XCTAssertEqual(loaded.count, rows.count)
        XCTAssertEqual(Set(loaded.map(\.id)).count, loaded.count)
        let model = DictionaryModel()
        await model.reload(from: repositories)
        XCTAssertEqual(DictionaryWords.groups(model.entries).first { $0.spelling == "Moptop" }?.heardAs, ["mop top"])
        // A cursor must advance monotonically with small pages too.
        var cursor: String?
        var paged: [DictionaryEntryDTO] = []
        for _ in 0..<(rows.count + 1) {
            let page = try await repositories.dictionary.page(limit: 2, afterPattern: cursor)
            if page.isEmpty { break }
            paged += page
            cursor = page.last?.pattern
        }
        XCTAssertEqual(paged.map(\.id), loaded.map(\.id))
    }

    func testHeardAsDeduplicatesCaseWithoutRemovingStoredRules() throws {
        let rows = [
            DictionaryEntryDTO(id: UUID(), pattern: "Moptop", replacement: "", isVocabulary: true),
            DictionaryEntryDTO(id: UUID(), pattern: "mop top", replacement: "Moptop", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "MOP TOP", replacement: "moptop", isVocabulary: false),
        ]
        let group = try XCTUnwrap(DictionaryWords.groups(rows).first)
        XCTAssertEqual(group.heardAs.map { $0.lowercased() }, ["mop top"])
        XCTAssertEqual(group.entries.count, 3, "Grouping must preserve identities for editing/deleting")
    }

    func testFieldChipsWrapAtEveryWidthWithUniformHeightsAndNoOverflow() {
        let widths: [CGFloat] = [110, 90, 170, 75, 115, 90, 120, 160]
        for width in stride(from: 1, through: 1000, by: 7) {
            let frames = DictionaryChipLayout.frames(widths: widths, availableWidth: CGFloat(width))
            XCTAssertEqual(frames.count, widths.count)
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, CGFloat(width))
                XCTAssertEqual(frame.height, DictionaryChipLayout.chipHeight)
            }
            for (previous, next) in zip(frames, frames.dropFirst()) {
                XCTAssertTrue(next.minY > previous.minY || next.minX >= previous.maxX + 8)
            }
            if width < 100 { XCTAssertEqual(Set(frames.map(\.minY)).count, widths.count) }
        }
    }

    func testOverflowShowsCountAndOnlyExpandsTheListOnRequest() {
        XCTAssertEqual(DictionaryOverflowWords.summary(count: 312), "312 more words didn’t fit")
        XCTAssertEqual(DictionaryOverflowWords.summary(count: 1), "1 more word didn’t fit")
        let terms = (0..<312).map { "Test word \($0)" }
        func height(expanded: Bool) -> CGFloat {
            let host = NSHostingView(rootView: DictionaryOverflowWords(terms: terms, isExpanded: .constant(expanded))
                .frame(width: 320).fixedSize(horizontal: false, vertical: true))
            return host.fittingSize.height
        }
        let collapsed = height(expanded: false)
        XCTAssertLessThan(collapsed, 45, "312 words should take only the summary row when collapsed")
        XCTAssertGreaterThan(height(expanded: true), collapsed + 100)
    }
}


extension DictionaryModelTests {
    func testWelcomeLoadsAndUsesBothFieldListsAndSkipLeavesBothUntouched() {
        let settings = AppSettings.shared
        let old = (settings.vocabularyPacksOn, settings.vocabularyPacksOff)
        defer { settings.vocabularyPacksOn = old.0; settings.vocabularyPacksOff = old.1 }
        settings.vocabularyPacksOn = ["medicine"]
        settings.vocabularyPacksOff = ["law"]
        var fields = WelcomeFieldsSelection()
        fields.load(from: settings)
        XCTAssertEqual(fields.on, ["medicine"]); XCTAssertEqual(fields.off, ["law"])
        fields.on = ["law"]; fields.off = ["medicine"]
        fields.finish(use: false, settings: settings)
        XCTAssertEqual(settings.vocabularyPacksOn, ["medicine"])
        XCTAssertEqual(settings.vocabularyPacksOff, ["law"])
        fields.finish(use: true, settings: settings)
        XCTAssertEqual(settings.vocabularyPacksOn, ["law"])
        XCTAssertEqual(settings.vocabularyPacksOff, ["medicine"])
    }
}
