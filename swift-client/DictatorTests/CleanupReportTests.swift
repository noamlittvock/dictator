import XCTest
@testable import Dictator

/// What Dictator says clean-up did must match what it did.
final class CleanupReportTests: XCTestCase {
    private func entry(level: String?, outcome: String?, ms: Int? = nil) -> DictationEntryDTO {
        var entry = DictationEntryDTO(id: UUID(), timestamp: Date(), text: "words", durationSeconds: 1, inferenceMs: nil, wordCount: 1)
        entry.cleanupLevel = level
        entry.cleanupOutcome = outcome
        entry.cleanupMs = ms
        return entry
    }

    func testServerResultsAreReadHonestly() {
        XCTAssertEqual(CleanupOutcome(server: "polished", requested: .medium, ran: nil), .applied)
        XCTAssertEqual(CleanupOutcome(server: "polished", requested: .polished, ran: "strong"), .applied)
        XCTAssertEqual(CleanupOutcome(server: "fallback", requested: .polished, ran: "strong"), .fellBack)
        XCTAssertEqual(CleanupOutcome(server: "rejected", requested: .medium, ran: "medium"), .rejected)
        XCTAssertEqual(CleanupOutcome(server: "unavailable", requested: .medium, ran: "medium"), .unavailable)
        XCTAssertNil(CleanupOutcome(server: "raw", requested: .exact, ran: "exact"))
        XCTAssertNil(CleanupOutcome(server: nil, requested: .medium, ran: nil))
    }

    func testOlderServerCannotClaimToHavePolished() {
        XCTAssertEqual(CleanupOutcome(server: "polished", requested: .polished, ran: nil), .fellBack)
    }

    func testStampSaysWhatHappened() {
        XCTAssertEqual(CleanupStamp(level: "exact", outcome: nil)?.label, "As heard")
        XCTAssertEqual(CleanupStamp(level: "medium", outcome: "applied")?.label, "Cleaned up")
        XCTAssertEqual(CleanupStamp(level: "strong", outcome: "applied")?.label, "Polished")
        XCTAssertNil(CleanupStamp(level: "strong", outcome: "applied")?.note)
        XCTAssertEqual(CleanupStamp(level: "strong", outcome: "fallback")?.label, "Cleaned up")
        XCTAssertNotNil(CleanupStamp(level: "strong", outcome: "fallback")?.note)
        XCTAssertEqual(CleanupStamp(level: "medium", outcome: "rejected")?.label, "Kept as heard")
        XCTAssertEqual(CleanupStamp(level: "medium", outcome: "unavailable")?.label, "Kept as heard")
    }

    func testRowsThatRecordedNothingShowNothing() {
        XCTAssertNil(CleanupStamp(level: nil, outcome: nil))
        XCTAssertNil(CleanupStamp(level: "medium", outcome: nil))
    }

    func testSummaryCountsOnlyCleanUpThatRan() {
        let summary = CleanupSummary([
            entry(level: "strong", outcome: "applied", ms: 900),
            entry(level: "medium", outcome: "applied", ms: 700),
            entry(level: "strong", outcome: "fallback", ms: 2100),
            entry(level: "medium", outcome: "rejected", ms: 800),
            entry(level: "medium", outcome: "unavailable"),
            entry(level: "exact", outcome: nil),
            entry(level: nil, outcome: nil),
        ])
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.asChosen, 2)
        XCTAssertEqual(summary.fellBack, 1)
        XCTAssertEqual(summary.kept, 2)
        XCTAssertEqual(summary.typicalMs, 900)
        XCTAssertEqual(summary.line, "Last 5 dictations: 2 as chosen, 1 cleaned up instead of polished, 2 kept as heard. Usually 0.9 s.")
    }

    func testSummaryStaysShortWhenAllIsWell() {
        XCTAssertEqual(CleanupSummary([entry(level: "medium", outcome: "applied", ms: 1200)]).line,
                       "Last dictation: 1 as chosen. Usually 1.2 s.")
        XCTAssertNil(CleanupSummary([entry(level: "exact", outcome: nil)]).line)
        XCTAssertNil(CleanupSummary([]).line)
    }

    func testChangesIgnoreCapitalsAndPunctuation() {
        let pieces = WordChanges.between(heard: "so um ship it today", typed: "So ship it today.")
        XCTAssertEqual(pieces, [
            .init(text: "So", kind: .same),
            .init(text: "um", kind: .removed),
            .init(text: "ship", kind: .same),
            .init(text: "it", kind: .same),
            .init(text: "today.", kind: .same),
        ])
    }

    func testChangesShowRewording() {
        let pieces = WordChanges.between(heard: "we buyed apples", typed: "We bought apples.")
        XCTAssertEqual(pieces.filter { $0.kind == .removed }.map(\.text), ["buyed"])
        XCTAssertEqual(pieces.filter { $0.kind == .added }.map(\.text), ["bought"])
        XCTAssertEqual(pieces.filter { $0.kind != .removed }.map(\.text), ["We", "bought", "apples."])
    }

    func testChangesHandleEmptyText() {
        XCTAssertEqual(WordChanges.between(heard: "", typed: ""), [])
        XCTAssertEqual(WordChanges.between(heard: "", typed: "new"), [.init(text: "new", kind: .added)])
        XCTAssertEqual(WordChanges.between(heard: "old", typed: ""), [.init(text: "old", kind: .removed)])
    }

    func testMetricsSurviveTheRow() {
        let metrics = EntryMetrics(cleanupLevel: "strong", cleanupOutcome: "fallback", cleanupMs: 812)
        let row = DictationEntry(text: "words", durationSeconds: 1, metrics: metrics)
        XCTAssertEqual(row.metrics, metrics)
    }
}
