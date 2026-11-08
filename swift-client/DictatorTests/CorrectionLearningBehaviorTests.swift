import XCTest
@testable import Dictator

@MainActor final class CorrectionLearningBehaviorTests: XCTestCase {
    private final class DictionaryFake: DictionaryRepository {
        var rows: [DictionaryEntryDTO] = []
        var onChange: (() -> Void)?
        func page(limit: Int, afterPattern: String?) async throws -> [DictionaryEntryDTO] {
            Array(rows.filter { afterPattern == nil || $0.pattern > afterPattern! }.sorted { $0.pattern < $1.pattern }.prefix(limit))
        }
        func entries() async throws -> [DictionaryEntryDTO] { rows }
        func upsert(_ entries: [DictionaryEntryDTO]) async throws { rows += entries }
        func delete(ids: [UUID]) async throws { rows.removeAll { ids.contains($0.id) } }
    }

    func testRepeatedCorrectionAndReplayDeduplication() async throws {
        let suite = "LearningBehavior-\(UUID())", dictionary = DictionaryFake()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learner = CorrectionLearningService(defaults: defaults)
        let first = CorrectionReport(heard: "Zandor", corrected: "Xandor", entryID: UUID())
        try await learner.learn(first, dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertEqual(dictionary.rows.count, 1); XCTAssertTrue(dictionary.rows[0].isVocabulary)
        try await learner.learn(first, dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertEqual(dictionary.rows.count, 1)
        try await CorrectionLearningService(defaults: defaults).learn(.init(heard: "Zandor", corrected: "Xandor", entryID: UUID()), dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertEqual(dictionary.rows.count, 2); XCTAssertEqual(dictionary.rows.filter { !$0.isVocabulary }.first?.replacement, "Xandor")
        let data = try XCTUnwrap(defaults.data(forKey: "dictionary.correctionConfirmations.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Zandor"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Xandor"))
    }

    func testExplicitRuleAndForgottenName() async throws {
        let suite = "LearningBehavior-\(UUID())", dictionary = DictionaryFake()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learner = CorrectionLearningService(defaults: defaults)
        dictionary.rows = [.init(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true, origin: "learned", isForgotten: true)]
        try await learner.learn(.init(heard: "Zandor", corrected: "Xandor", explicit: true), dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertEqual(dictionary.rows.count, 1)
        try await learner.learn(.init(heard: "Torven", corrected: "Torvin", explicit: true), dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertEqual(dictionary.rows.count, 3)
        XCTAssertEqual(dictionary.rows.filter { !$0.isVocabulary }.first?.replacement, "Torvin")
    }

    func testDailyLimitCountsRowsIncludingImmediateRules() async throws {
        let suite = "LearningBehavior-\(UUID())", dictionary = DictionaryFake()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for name in ["Xandor", "Torvin", "Brindel", "Nivarra", "Marinna", "Zelora"] {
            try await CorrectionLearningService(defaults: defaults).learn(.init(heard: name + "a", corrected: name, explicit: true), dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        }
        XCTAssertEqual(dictionary.rows.count, CorrectionLearningService.dailyLimit)
    }

    func testManualStillRejectsOrdinaryWordsAndUnsafeText() async throws {
        let suite = "LearningBehavior-\(UUID())", dictionary = DictionaryFake()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learner = CorrectionLearningService(defaults: defaults)
        try await learner.learn(.init(heard: "from", corrected: "form", explicit: true), dictionary: dictionary, languages: [], isKnownWord: { _ in true })
        try await learner.learn(.init(heard: "/tmp/Zandor", corrected: "/tmp/Xandor", explicit: true), dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertTrue(dictionary.rows.isEmpty)
    }
    func testPairAndSentenceReplayOfSameObservationDoesNotConfirmTwice() async throws {
        let suite = "LearningReplay-\(UUID())", dictionary = DictionaryFake()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CorrectionLearningService(defaults: defaults), id = UUID()
        try await service.learn(.init(heard: "Zandor", corrected: "Xandor", entryID: id, pairsOnly: true),
            dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        try await service.learn(.init(heard: "Ask Zandor tomorrow", corrected: "Ask Xandor tomorrow", entryID: id),
            dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertEqual(dictionary.rows.count, 1)
        XCTAssertTrue(dictionary.rows.allSatisfy(\.isVocabulary))
    }

}


extension CorrectionLearningBehaviorTests {
    func testReportsWhetherAnExplicitCorrectionWasLearned() async throws {
        let suite = "LearningResult-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learner = CorrectionLearningService(defaults: defaults)
        let dictionary = DictionaryFake()
        let rejected = try await learner.learn(.init(heard: "from", corrected: "form", explicit: true),
            dictionary: dictionary, languages: [], isKnownWord: { _ in true })
        XCTAssertFalse(rejected)
        let accepted = try await learner.learn(.init(heard: "Zandor", corrected: "Xandor", explicit: true),
            dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertTrue(accepted)
        let repeated = try await learner.learn(.init(heard: "Zandor", corrected: "Xandor", explicit: true),
            dictionary: dictionary, languages: [], isKnownWord: { _ in false })
        XCTAssertFalse(repeated)
    }
}
