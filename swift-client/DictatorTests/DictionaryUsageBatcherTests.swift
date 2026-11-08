import XCTest
@testable import Dictator

@MainActor final class DictionaryUsageBatcherTests: XCTestCase {
    func testManyDictationsBecomeOneWriteAndWordBoundariesAreRespected() {
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Arc", replacement: "", isVocabulary: true)
        var writes: [[UUID: DictionaryUsage]] = []
        let batcher = DictionaryUsageBatcher { writes.append($0) }
        let date = Date(timeIntervalSince1970: 10)
        for _ in 0..<30 { batcher.record(text: "March Arc ARC Arcadia", entries: [row], at: date) }
        XCTAssertTrue(writes.isEmpty)
        batcher.flush(); batcher.flush()
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0][row.id]?.count, 60)
        XCTAssertEqual(writes[0][row.id]?.lastUsedAt, date)
    }

    func testConnectedMacDoesNotCountAndRoleChangeDiscardsPendingUsage() {
        var main = false, writes = 0
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        let batcher = DictionaryUsageBatcher(isMain: { main }) { _ in writes += 1 }
        batcher.record(text: "Xandor", entries: [row]); XCTAssertTrue(batcher.pending.isEmpty)
        main = true; batcher.record(text: "Xandor", entries: [row]); XCTAssertEqual(batcher.pending.count, 1)
        main = false; batcher.flush()
        XCTAssertEqual(writes, 0); XCTAssertTrue(batcher.pending.isEmpty)
    }

    func testFailedFlushRetriesOnQuitAndForgottenTermsAreIgnored() {
        var attempts = 0
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        var forgotten = row; forgotten.id = UUID(); forgotten.isForgotten = true
        let batcher = DictionaryUsageBatcher { _ in
            attempts += 1
            if attempts == 1 { throw NSError(domain: "synthetic", code: 1) }
        }
        batcher.record(text: "Xandor", entries: [row, forgotten])
        XCTAssertEqual(batcher.pending.count, 1)
        batcher.flush(); XCTAssertEqual(batcher.pending.count, 1)
        batcher.flush(); XCTAssertTrue(batcher.pending.isEmpty)
        XCTAssertEqual(attempts, 2)
    }

    func testMinuteTimerFlushesOnce() async throws {
        var writes = 0
        let row = DictionaryEntryDTO(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        let batcher = DictionaryUsageBatcher(interval: 0.01) { _ in writes += 1 }
        for _ in 0..<10 { batcher.record(text: "Xandor", entries: [row]) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(writes, 1); XCTAssertTrue(batcher.pending.isEmpty)
    }
}
