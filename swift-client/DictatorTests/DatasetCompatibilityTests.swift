import XCTest
@testable import Dictator

@MainActor
final class DatasetCompatibilityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func testRowHostsComeFromWebURLsOnly() {
        let legacy = DatasetRow(id: UUID(), timestamp: now, text: "hello there friend", wordCount: 3, modality: "typed", durationSeconds: 0,
                              source: "codex_session", insertionMethod: "historical_import", destinationAppBundleId: "com.openai.codex",
                              destinationAppName: "Codex", destinationURL: "https://www.docs.google.com/document/x", originEdgeId: nil,
                              attribution: PromptAttribution(), metrics: EntryMetrics())
        XCTAssertEqual(legacy.webHost, "docs.google.com")
        XCTAssertEqual(legacy.destinationURL, "https://www.docs.google.com/document/x")
        XCTAssertNil(DatasetRow.host(of: "terminal://com.googlecode.iterm2/ttys001"))
        XCTAssertNil(DatasetRow.host(of: "unknown"))
    }
    func testImportIDsAreStableAndBatchIDsParse() {
        XCTAssertEqual(DatasetStore.importID("chatgpt:c1:m1"), DatasetStore.importID("chatgpt:c1:m1"))
        XCTAssertNotEqual(DatasetStore.importID("chatgpt:c1:m1"), DatasetStore.importID("chatgpt:c1:m2"))
        let batch = DatasetStore.makeBatchID(.claudeCode, date: Date(timeIntervalSince1970: 1_700_000_000))
        let parsed = DatasetStore.parseBatchID(batch)
        XCTAssertEqual(parsed.kind, .claudeCode)
        XCTAssertEqual(parsed.date, Date(timeIntervalSince1970: 1_700_000_000))

        let prompt = ImportedPrompt(text: "fix the tests", timestamp: now, sourceKey: "claude-code:u1")
        let dto = DatasetStore.dto(for: prompt, kind: .claudeCode, batchID: batch)
        XCTAssertEqual(dto.importBatchId, batch)
        XCTAssertEqual(dto.captureSource, "import")
        XCTAssertEqual(DatasetRow(dto).isImported, true)
    }

    func testEntryWireFieldsAreOptional() throws {
        var dto = DatasetStore.dto(for: ImportedPrompt(text: "one two three", timestamp: now, sourceKey: "k"), kind: .textFile, batchID: "b")
        dto.typingSeconds = 12.5
        dto.latencyMs = 1_400
        dto.polishModel = "gemma"
        dto.firstTakeAfterLoad = true
        dto.sessionId = "s1"
        let decoded = try JSONDecoder().decode(DictationEntryDTO.self, from: JSONEncoder().encode(dto))
        XCTAssertEqual(decoded, dto)
        XCTAssertEqual(decoded.metrics, EntryMetrics(typingSeconds: 12.5, latencyMs: 1_400, polishModel: "gemma", firstTakeAfterLoad: true))

        // A peer built before these fields existed omits them.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
        for key in ["typingSeconds", "latencyMs", "polishModel", "firstTakeAfterLoad", "sessionId", "importBatchId"] {
            object.removeValue(forKey: key)
        }
        let old = try JSONDecoder().decode(DictationEntryDTO.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.latencyMs)
        XCTAssertNil(old.importBatchId)

        let destination = try JSONDecoder().decode(InsertDestination.self, from: Data(#"{"insertionMethod":"paste"}"#.utf8))
        XCTAssertNil(destination.releaseToInsertMs)
    }

}
