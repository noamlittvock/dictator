import SwiftData
import XCTest
@testable import Dictator

@MainActor final class DictionaryLearningStorageTests: XCTestCase {
    private func repositories() throws -> Repositories {
        let schema = Repositories.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return Repositories.make(container: container)
    }

    func testUsageBatchesQuietlyWithoutOutbox() async throws {
        let repos = try repositories()
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        try await repos.dictionary.upsert([row]); repos.outbox.enabled = true
        var changes = 0
        repos.dictionary.onChange = { changes += 1 }
        let local = try XCTUnwrap(repos.dictionary as? LocalDictionaryRepository)
        let batcher = DictionaryUsageBatcher { try local.applyUsage($0) }
        let date = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<30 { batcher.record(text: "Xandor and XANDOR", entries: [row], at: date) }
        let before = try await repos.dictionary.entries()
        XCTAssertEqual(before.first?.useCount, 0); XCTAssertEqual(changes, 0)
        batcher.flush()
        let after = try await repos.dictionary.entries()
        XCTAssertEqual(after.first?.useCount, 60); XCTAssertEqual(after.first?.lastUsedAt, date)
        XCTAssertEqual(changes, 0); XCTAssertEqual(try repos.outbox.count(), 0)
        batcher.flush(); XCTAssertEqual(changes, 0)
    }

    func testUsageBoundaryAndForgottenExclusion() {
        let active = DictionaryEntryDTO(id: UUID(), pattern: "Arc", replacement: "", isVocabulary: true)
        let forgotten = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true, isForgotten: true)
        let batcher = DictionaryUsageBatcher { _ in }
        batcher.record(text: "March Arc arc Xandor", entries: [active, forgotten])
        XCTAssertEqual(batcher.pending[active.id]?.count, 2); XCTAssertNil(batcher.pending[forgotten.id])
        batcher.discard()
    }

    func testUsageFailureRetainsCountersForQuitRetry() {
        var attempts = 0
        let batcher = DictionaryUsageBatcher { _ in
            attempts += 1
            if attempts == 1 { throw RepositoryError.timeout }
        }
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        batcher.record(text: "Xandor", entries: [row]); batcher.flush()
        XCTAssertEqual(batcher.pending.count, 1)
        batcher.flush(); XCTAssertTrue(batcher.pending.isEmpty)
    }

    func testLearnedHintThenRuleOnSecondDistinctTakeAndForgottenNeverReturns() async throws {
        let repos = try repositories()
        let suite = "DictionaryLearningTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CorrectionLearningService(defaults: defaults)
        let first = CorrectionReport(heard: "Zandor", corrected: "Xandor", entryID: UUID())
        try await service.learn(first, dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        var rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].isVocabulary); XCTAssertEqual(rows[0].origin, "learned")
        try await service.learn(first, dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        rows = try await repos.dictionary.entries(); XCTAssertEqual(rows.count, 1, "replayed report is not a second correction")
        try await service.learn(.init(heard: "Zandor", corrected: "Xandor", entryID: UUID()), dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.filter { !$0.isVocabulary }.count, 1)
        try await repos.dictionary.delete(ids: rows.map(\.id))
        // Reopening the learning service must retain confirmation counts, and
        // tombstones must survive even an older main Mac's empty mirror.
        try await repos.dictionarySync.replaceAll(with: [])
        let reopened = CorrectionLearningService(defaults: defaults)
        try await reopened.learn(.init(heard: "Zandor", corrected: "Xandor", entryID: UUID(), explicit: true), dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0.isForgotten == true })
        let ledger = try XCTUnwrap(defaults.data(forKey: "dictionary.correctionConfirmations.v1"))
        XCTAssertFalse(String(decoding: ledger, as: UTF8.self).contains("Xandor"))
    }

    func testManualCorrectionAddsRuleImmediatelyButStillUsesFilters() async throws {
        let repos = try repositories()
        let suite = "DictionaryLearningTests-\(UUID())"
        // Use an isolated suite; no system spell checker or personal settings.
        let isolated = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { isolated.removePersistentDomain(forName: suite) }
        let service = CorrectionLearningService(defaults: isolated)
        try await service.learn(.init(heard: "Zandor", corrected: "Xandor", explicit: true), dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        try await service.learn(.init(heard: "from", corrected: "form", explicit: true), dictionary: repos.dictionary, languages: [], isKnownWord: { _ in true })
        let rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows.filter { !$0.isVocabulary }.first?.replacement, "Xandor")
    }

    func testDailyLimitPersistsAcrossRestart() async throws {
        let repos = try repositories(), suite = "DictionaryLearningTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = ["Xandor", "Brindel", "Torvin", "Nivarra", "Marinna", "Zelora", "Lorena"]
        let date = Date(timeIntervalSince1970: 1_000_000)
        for name in names {
            let service = CorrectionLearningService(defaults: defaults)
            try await service.learn(.init(heard: name + "a", corrected: name, entryID: UUID()), dictionary: repos.dictionary, languages: [], at: date, isKnownWord: { _ in false })
        }
        let rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.count, CorrectionLearningService.dailyLimit)
        try await CorrectionLearningService(defaults: defaults).learn(.init(heard: "Zeloraa", corrected: "Zelora", entryID: UUID()), dictionary: repos.dictionary, languages: [], at: date.addingTimeInterval(86_400), isKnownWord: { _ in false })
        let next = try await repos.dictionary.entries(); XCTAssertEqual(next.filter(\.isVocabulary).count, 6)
    }

    func testHistoryOffSavesNoStagesAndCannotAddEdit() async throws {
        let settings = AppSettings.shared, prior = AppSettings.shared.persistHistory
        defer { settings.persistHistory = prior }
        settings.persistHistory = false
        let repos = try repositories(), id = UUID()
        var record = HistoryRecordDTO(text: "final", durationSeconds: 1)
        record.id = id; record.heardText = "heard"; record.editedText = "edited"
        try await repos.history.record(record)
        try await repos.history.saveEditedText("later", id: id)
        let rows = try await repos.history.allEntries(); XCTAssertTrue(rows.isEmpty)
    }

    func testStagesReplicateAndLargeStagesFitPageBudget() async throws {
        let repos = try repositories()
        var dto = DictationEntryDTO(id: UUID(), timestamp: Date(), text: "final", durationSeconds: 1, wordCount: 1)
        dto.heardText = "heard"
        try await repos.historySync.insertMissing([dto], asReplica: true)
        dto.editedText = "edited"
        try await repos.historySync.insertMissing([dto], asReplica: true)
        let rows = try await repos.history.allEntries()
        XCTAssertEqual(rows.first?.heardText, "heard"); XCTAssertEqual(rows.first?.editedText, "edited")
        let manifest = try await repos.historySync.manifestPage(limit: 10, before: nil)
        XCTAssertEqual(manifest.first?.hasEditedText, true)
        let huge = String(repeating: "🙂", count: RepoRequestLimits.maxTextLength)
        var large = dto; large.id = UUID(); large.text = huge; large.heardText = huge; large.editedText = huge
        try await repos.historySync.insertMissing([large], asReplica: true)
        let page = try await repos.historySync.fetch(ids: [large.id])
        XCTAssertEqual(page.first?.truncated, true)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(page).count, RepoRequestLimits.pageByteBudget)
    }

    func testDictionaryFieldsRoundTripAndPagesStayUnderBudget() async throws {
        let repos = try repositories()
        let rows = (0..<300).map { index in
            DictionaryEntryDTO(id: UUID(), pattern: String(format: "%04d", index) + String(repeating: "詞", count: 450),
                replacement: String(repeating: "語", count: 500), isVocabulary: false,
                isStarred: true, useCount: index, lastUsedAt: Date(timeIntervalSince1970: 10), origin: "imported", isForgotten: false)
        }
        try await repos.dictionary.upsert(rows)
        var count = 0, cursor: String?
        while true {
            let page = try await repos.dictionary.page(limit: 200, afterPattern: cursor)
            guard let last = page.last else { break }
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(page).count, RepoRequestLimits.pageByteBudget)
            XCTAssertTrue(page.allSatisfy { $0.isStarred == true && $0.origin == "imported" })
            count += page.count; cursor = last.pattern
        }
        XCTAssertEqual(count, rows.count)
    }

    func testTypedConsentControlsEditedStageAndHistoryOffStillLearns() async throws {
        let settings = AppSettings.shared
        let old = (settings.persistHistory, settings.learnFromCorrections, settings.cachedSurfacePolicyJSON, settings.promptCapturePausedUntil)
        defer {
            settings.persistHistory = old.0; settings.learnFromCorrections = old.1
            settings.cachedSurfacePolicyJSON = old.2; settings.promptCapturePausedUntil = old.3
        }
        settings.persistHistory = true; settings.learnFromCorrections = true; settings.promptCapturePausedUntil = nil
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save"))
        let repos = try repositories()
        let rowID = UUID()
        var record = HistoryRecordDTO(text: "Ask Zandor tomorrow", durationSeconds: 1, destinationAppBundleId: "test.synthetic")
        record.id = rowID
        try await repos.history.record(record)
        let suite = "Consent-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learner = CorrectionLearningService(defaults: defaults)
        let report = CorrectionReport(heard: record.text, corrected: "Ask Xandor tomorrow", entryID: record.id, context: record.captureContext)
        try await learner.receive(report, repositories: repos, settings: settings, isKnownWord: { _ in false })
        try await repos.history.saveEditedText("Ask Xandor tomorrow", id: rowID)
        var saved = try await repos.history.entry(id: rowID)
        XCTAssertNil(saved?.editedText)
        var words = try await repos.dictionary.entries()
        XCTAssertEqual(words.map(\.pattern), ["Xandor"])
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "save", defaultVoice: "save"))
        try await learner.receive(report, repositories: repos, settings: settings, isKnownWord: { _ in false })
        saved = try await repos.history.entry(id: rowID)
        XCTAssertEqual(saved?.editedText, "Ask Xandor tomorrow")
        settings.persistHistory = false
        try await learner.receive(.init(heard: "Torven", corrected: "Torvin", entryID: UUID(), pairsOnly: true,
            context: record.captureContext), repositories: repos, settings: settings, isKnownWord: { _ in false })
        words = try await repos.dictionary.entries()
        XCTAssertTrue(words.contains { $0.pattern == "Torvin" })
        let history = try await repos.history.allEntries()
        XCTAssertEqual(history.count, 1)
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: "dictionary.correctionConfirmations.v1")), as: UTF8.self).contains("Torvin"))
    }

    func testLegacyDictionaryPagesSkipForgottenBeforeLimitAndDropOldCopies() async throws {
        let repos = try repositories()
        let forgotten = DictionaryEntryDTO(id: UUID(), pattern: "Aandor", replacement: "", isVocabulary: true, origin: "learned", isForgotten: true)
        let active = DictionaryEntryDTO(id: UUID(), pattern: "Zandor", replacement: "", isVocabulary: true)
        try await repos.dictionary.upsert([forgotten, active])
        let server = RepoServer(repositories: repos)
        var legacyCopies = [forgotten, active]
        guard case .dictionaryPage(let legacy) = await server.handle(.dictionaryPage(limit: 1, afterPattern: nil)) else { return XCTFail() }
        legacyCopies = legacy // older replaceAll discards its previous dictionary
        XCTAssertEqual(legacyCopies.map(\.id), [active.id])
        guard case .dictionaryPage(let modern) = await server.handle(.dictionaryPage(limit: 1, afterPattern: nil, includeForgotten: true)) else { return XCTFail() }
        XCTAssertEqual(modern.map(\.id), [forgotten.id])
        XCTAssertEqual(modern.first?.isForgotten, true)
        guard case .dictionaryPage(let explicitlyActive) = await server.handle(.dictionaryPage(limit: 1, afterPattern: nil, includeForgotten: false)) else { return XCTFail() }
        XCTAssertEqual(explicitlyActive.map(\.id), [active.id])
    }

    func testMirrorNotifiesUIWithoutLocalPushRevisionAndUsageIsQuiet() async throws {
        let repos = try repositories(), hub = RepositoryHub(current: repos)
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        try await repos.dictionarySync.replaceAll(with: [row])
        try await repos.historySync.insertMissing([.init(id: UUID(), timestamp: Date(), text: "synthetic", durationSeconds: 1, wordCount: 1)], asReplica: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(hub.dictionaryVersion, 1); XCTAssertEqual(hub.dictionaryLocalVersion, 0)
        XCTAssertEqual(hub.historyVersion, 1); XCTAssertEqual(hub.historyLocalVersion, 0)
        let local = try XCTUnwrap(repos.dictionary as? LocalDictionaryRepository)
        try local.applyUsage([row.id: .init(count: 3, lastUsedAt: Date())])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(hub.dictionaryVersion, 1); XCTAssertEqual(hub.dictionaryLocalVersion, 0)
        try await repos.dictionary.upsert([.init(id: UUID(), pattern: "Torvin", replacement: "", isVocabulary: true)])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(hub.dictionaryLocalVersion, 1)
        let words = try await repos.dictionary.entries()
        XCTAssertEqual(words.first { $0.id == row.id }?.useCount, 3)
    }

}


extension DictionaryLearningStorageTests {
    func testHandFixSavesWithTypedHistoryOffAllowsLaterFixAndObeysGlobalOff() async throws {
        let settings = AppSettings.shared
        let old = (settings.persistHistory, settings.cachedSurfacePolicyJSON, settings.promptCapturePausedUntil)
        defer {
            settings.persistHistory = old.0; settings.cachedSurfacePolicyJSON = old.1
            settings.promptCapturePausedUntil = old.2
        }
        settings.persistHistory = true; settings.promptCapturePausedUntil = nil
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save"))
        let repos = try repositories(), id = UUID()
        var record = HistoryRecordDTO(text: "Ann met Anna", durationSeconds: 1)
        record.id = id
        try await repos.history.record(record)
        let suite = "HandFix-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learner = CorrectionLearningService(defaults: defaults)
        let first = CorrectionReport(heard: "Ann", corrected: "Anne", entryID: id, explicit: true,
            selection: .init(start: 0, end: 3, originalText: record.text))
        let outcome = try await learner.receive(first, repositories: repos, settings: settings, isKnownWord: { _ in true })
        XCTAssertTrue(outcome.historySaved); XCTAssertFalse(outcome.learned)
        XCTAssertEqual(outcome.message, "Correction saved. No new word was learned.")
        let firstSaved = try await repos.history.entry(id: id)
        var saved = try XCTUnwrap(firstSaved)
        XCTAssertEqual(saved.editedText, "Anne met Anna"); XCTAssertEqual(saved.editedTextRevision, 1)
        let second = CorrectionReport(heard: "Anna", corrected: "Ana", entryID: id, explicit: true,
            selection: .init(start: 9, end: 13, originalText: "Anne met Anna"))
        let later = try await learner.receive(second, repositories: repos, settings: settings, isKnownWord: { _ in true })
        XCTAssertTrue(later.historySaved)
        let secondSaved = try await repos.history.entry(id: id)
        saved = try XCTUnwrap(secondSaved)
        XCTAssertEqual(saved.editedText, "Anne met Ana"); XCTAssertEqual(saved.editedTextRevision, 2)
        // Automatic capture remains first-edit-only and typed-consent gated.
        try await repos.history.saveEditedText("automatic", id: id)
        settings.persistHistory = false
        let blocked = try await repos.history.saveManualEdit("disabled", id: id, expectedText: "Anne met Ana")
        XCTAssertFalse(blocked)
        let unchanged = try await repos.history.entry(id: id)
        XCTAssertEqual(unchanged?.editedText, "Anne met Ana")
        // Stale sheet refuses learning as well as the write.
        settings.persistHistory = true
        do {
            _ = try await learner.receive(first, repositories: repos, settings: settings, isKnownWord: { _ in false })
            XCTFail("stale correction should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        let words = try await repos.dictionary.entries()
        XCTAssertTrue(words.isEmpty)
        // A legacy explicit request has no span: it can learn, never replace globally.
        _ = try await learner.receive(.init(heard: "Ann", corrected: "Anne", entryID: id, explicit: true),
            repositories: repos, settings: settings, isKnownWord: { _ in true })
        let legacy = try await repos.history.entry(id: id)
        XCTAssertEqual(legacy?.editedText, "Anne met Ana")
    }

    func testHandFixSelectionUsesSheetCharacterUnitsWithEmojiAndCombiningMarks() throws {
        for text in ["👩🏽‍💻 e\u{301} Ann met Anna", "🙂 Ann Ann", "אב Ann אב"] {
            let ranges = HistoryCorrectionWords.ranges(in: text)
            let index = try XCTUnwrap(ranges.firstIndex { String(text[$0]) == "Ann" })
            let span = try XCTUnwrap(HistoryCorrectionWords.span(in: text, ranges: ranges, selection: index...index))
            let heard = HistoryCorrectionWords.heard(in: text, ranges: ranges, selection: index...index)
            let range = ranges[index]
            let expected = String(text[..<range.lowerBound]) + "Anne" + String(text[range.upperBound...])
            XCTAssertEqual(try span.replacing(in: text, heard: heard, with: "Anne"), expected)
            XCTAssertThrowsError(try span.replacing(in: text + "!", heard: heard, with: "Anne"))
            XCTAssertThrowsError(try span.replacing(in: text, heard: "Anna", with: "Anne"))
        }
        for span in [HistoryCorrectionSpan(start: -1, end: 2, originalText: "Ann"),
                     .init(start: 0, end: Int.max, originalText: "Ann"),
                     .init(start: 2, end: 1, originalText: "Ann")] {
            XCTAssertThrowsError(try span.replacing(in: "Ann", heard: "Ann", with: "Anne"))
            XCTAssertNotNil(RepoServer.validate(.correction(.init(heard: "Ann", corrected: "Anne", entryID: UUID(), explicit: true, selection: span))))
        }
    }

    func testUndoAndManualAddReviveSameLearnedIdentityAndLearningResumes() async throws {
        let repos = try repositories(), model = DictionaryModel()
        let word = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true,
            isStarred: true, useCount: 7, origin: "learned")
        try await repos.dictionary.upsert([word])
        await model.delete(word, repositories: repos)
        await model.undoDelete(repositories: repos)
        var rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.map(\.id), [word.id]); XCTAssertEqual(rows.first?.isForgotten, false)
        XCTAssertEqual(rows.first?.useCount, 7); XCTAssertEqual(rows.first?.isStarred, true)
        let suite = "Revive-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learned = try await CorrectionLearningService(defaults: defaults).learn(
            .init(heard: "Zandor", corrected: "Xandor", entryID: UUID(), explicit: true),
            dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertTrue(learned)
        rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.filter { $0.pattern == "Xandor" }.map(\.id), [word.id])
        XCTAssertEqual(rows.first { !$0.isVocabulary }?.replacement, "Xandor")
        try await repos.dictionary.delete(ids: rows.map(\.id))
        // Old peers omitting forgotten metadata cannot clear the tombstone.
        try await repos.dictionary.upsert([word])
        rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.first { $0.id == word.id }?.isForgotten, true)
        repos.outbox.enabled = true
        let added = await model.saveWord(word: "Xandor", heardAs: [], original: [], newID: UUID(), repositories: repos)
        XCTAssertTrue(added)
        rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.filter { $0.pattern == "Xandor" }.map(\.id), [word.id])
        XCTAssertEqual(rows.first { $0.id == word.id }?.isForgotten, false)
        let queued = try XCTUnwrap(repos.outbox.pending(limit: 10).last)
        guard case .dictionaryUpsert(let restored) = queued.request else { return XCTFail() }
        XCTAssertEqual(restored.first?.id, word.id); XCTAssertEqual(restored.first?.isForgotten, false)
        let service = CorrectionLearningService(defaults: defaults)
        let relearned = try await service.learn(.init(heard: "Sandor", corrected: "Xandor", entryID: UUID(), explicit: true),
            dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertTrue(relearned, "an old forgotten heard-as rule must not suppress a restored word")
        _ = try await service.learn(.init(heard: "Zandor", corrected: "Xandor", entryID: UUID(), explicit: true),
            dictionary: repos.dictionary, languages: [], isKnownWord: { _ in false })
        rows = try await repos.dictionary.entries()
        XCTAssertEqual(rows.filter { $0.pattern == "Zandor" }.count, 1, "do not create another identity beside the forgotten rule")
        XCTAssertEqual(rows.first { $0.pattern == "Zandor" }?.isForgotten, true)
        XCTAssertEqual(rows.first { $0.pattern == "Sandor" }?.isForgotten, false)
    }

    func testDictionaryCompositeCursorKeepsAllDuplicatePatternsAtLimitAndByteBoundary() async throws {
        let repos = try repositories()
        // Different identities with the same pattern remain legal (e.g. vocabulary and rules).
        let rows = (0..<300).map { index in
            DictionaryEntryDTO(id: UUID(), pattern: String(repeating: "詞", count: 450),
                replacement: String(repeating: "語", count: 500) + String(index), isVocabulary: index.isMultiple(of: 2), origin: "imported")
        }
        try await repos.dictionary.upsert(rows)
        let server = RepoServer(repositories: repos)
        for limit in [1, 200] {
            var after: String?, afterID: UUID?
            var received: [UUID] = []
            for _ in 0...rows.count {
                guard case .dictionaryPage(let page) = await server.handle(.dictionaryPage(limit: limit,
                    afterPattern: after, includeForgotten: true, afterID: afterID)) else { return XCTFail() }
                guard let last = page.last else { break }
                if limit == 200 { XCTAssertLessThan(page.count, limit, "exercise a byte-budget page boundary") }
                XCTAssertLessThanOrEqual(try JSONEncoder().encode(page).count, RepoRequestLimits.pageByteBudget)
                received += page.map(\.id); after = last.pattern; afterID = last.id
            }
            XCTAssertEqual(received, rows.map(\.id).sorted { $0.uuidString < $1.uuidString })
            XCTAssertEqual(Set(received).count, rows.count)
        }
        let all = try await repos.dictionary.entries()
        XCTAssertEqual(Set(all.map(\.id)), Set(rows.map(\.id)))
        guard case .dictionaryPage(let legacy) = await server.handle(.dictionaryPage(limit: 1, afterPattern: rows[0].pattern)) else { return XCTFail() }
        XCTAssertTrue(legacy.isEmpty, "old peers retain their pattern-only semantics")
    }
}

extension DictionaryLearningStorageTests {
    private final class ServerTransport: RepoTransport {
        let server: RepoServer
        init(_ server: RepoServer) { self.server = server }
        func send(_ request: RepoRequest) async throws -> RepoResult {
            let result = await server.handle(request)
            return try JSONDecoder().decode(RepoResult.self, from: JSONEncoder().encode(result))
        }
    }

    private final class FailingDictionary: DictionaryRepository {
        var onChange: (() -> Void)?
        func page(limit: Int, afterPattern: String?) async throws -> [DictionaryEntryDTO] { [] }
        func upsert(_ entries: [DictionaryEntryDTO]) async throws { throw RepositoryError.remote("Synthetic dictionary save failed") }
        func delete(ids: [UUID]) async throws {}
    }

    func testServerReturnsFailedSaveInsteadOfReceiptAndReportsPartialSuccess() async throws {
        let repos = try repositories(), server = RepoServer(repositories: try repositories())
        let client = CoreSyncClient(transport: ServerTransport(server))
        let report = CorrectionReport(heard: "Zandor", corrected: "Xandor", explicit: true)
        server.onCorrection = { _ in throw RepositoryError.remote("Synthetic save failed") }
        do {
            _ = try await client.learnCorrection(report)
            XCTFail("server must not acknowledge a failed save as success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic save failed")) }
        server.onCorrection = nil
        do {
            _ = try await client.learnCorrection(report)
            XCTFail("no receiver must not acknowledge saving")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }

        let settings = AppSettings.shared, old = settings.persistHistory
        defer { settings.persistHistory = old }
        settings.persistHistory = true
        let id = UUID()
        let dto = DictationEntryDTO(id: id, timestamp: Date(), text: "Zandor", durationSeconds: 1, wordCount: 1)
        try await repos.historySync.insertMissing([dto], asReplica: true)
        let failing = Repositories(history: repos.history, dictionary: FailingDictionary(), settings: repos.settings)
        let suite = "PartialFix-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CorrectionLearningService(defaults: defaults)
        server.onCorrection = { report in
            try await service.receive(report, repositories: failing, settings: settings, isKnownWord: { _ in false })
        }
        let outcome = try await client.learnCorrection(.init(heard: "Zandor", corrected: "Xandor", entryID: id, explicit: true,
            selection: .init(start: 0, end: 6, originalText: "Zandor")))
        XCTAssertEqual(outcome?.historySaved, true); XCTAssertEqual(outcome?.learningFailed, true)
        XCTAssertTrue(outcome?.message.hasPrefix("Correction saved.") == true)
        let saved = try await repos.history.entry(id: id)
        XCTAssertEqual(saved?.editedText, "Xandor")
    }
}
