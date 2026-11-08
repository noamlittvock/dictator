import XCTest
@testable import Dictator

@MainActor
final class DictionaryLearningCompatibilityTests: XCTestCase {
    private struct OldDictionary: Codable, Equatable {
        var id: UUID; var pattern: String; var replacement: String; var isVocabulary: Bool
    }
    private struct OldHistory: Codable, Equatable {
        var id: UUID; var timestamp: Date; var text: String; var durationSeconds: Double; var wordCount: Int
    }
    private struct OldSettings: Codable, Equatable {
        var refineLevel: String; var customSystemPrompt: String; var persistHistory: Bool
    }

    func testDictionaryBothDirectionsAndNullFields() throws {
        let old = OldDictionary(id: UUID(), pattern: "Xandor", replacement: "", isVocabulary: true)
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        var new = try decoder.decode(DictionaryEntryDTO.self, from: encoder.encode(old))
        XCTAssertNil(new.isStarred); XCTAssertNil(new.useCount); XCTAssertNil(new.lastUsedAt)
        XCTAssertNil(new.origin); XCTAssertNil(new.isForgotten)
        new.isStarred = true; new.useCount = 4; new.lastUsedAt = Date(); new.origin = "learned"; new.isForgotten = false
        XCTAssertEqual(try decoder.decode(OldDictionary.self, from: encoder.encode(new)), old)
        let nulled = Data("{\"id\":\"\(old.id)\",\"pattern\":\"Xandor\",\"replacement\":\"\",\"isVocabulary\":true,\"useCount\":null,\"isStarred\":null,\"origin\":null,\"isForgotten\":null}".utf8)
        XCTAssertNil(try decoder.decode(DictionaryEntryDTO.self, from: nulled).useCount)
    }

    func testHistoryBothDirections() throws {
        let old = OldHistory(id: UUID(), timestamp: Date(timeIntervalSince1970: 10), text: "final", durationSeconds: 1, wordCount: 1)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var new = try decoder.decode(DictationEntryDTO.self, from: encoder.encode(old))
        XCTAssertNil(new.heardText); XCTAssertNil(new.editedText); XCTAssertNil(new.editedTextRevision)
        new.heardText = "heard"; new.editedText = "edited"; new.editedTextRevision = 2
        XCTAssertEqual(try decoder.decode(OldHistory.self, from: encoder.encode(new)), old)
    }

    func testSettingsBothDirectionsAndOptionalPatch() throws {
        let old = OldSettings(refineLevel: "light", customSystemPrompt: "", persistHistory: true)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var new = try decoder.decode(CoreSettingsDTO.self, from: encoder.encode(old))
        XCTAssertNil(new.learnFromCorrections)
        new.learnFromCorrections = false
        XCTAssertEqual(try decoder.decode(OldSettings.self, from: encoder.encode(new)), old)
        var patch = try decoder.decode(CoreSettingsPatch.self, from: Data("{}".utf8))
        XCTAssertTrue(patch.isEmpty)
        patch.learnFromCorrections = false; XCTAssertFalse(patch.isEmpty)
        XCTAssertEqual(try decoder.decode(CoreSettingsPatch.self, from: encoder.encode(patch)), patch)
    }

    func testCorrectionRequestRoundTripsWithoutProtocolVersionChange() throws {
        let report = CorrectionReport(heard: "Zandor", corrected: "Xandor", entryID: UUID(), explicit: true)
        let request = RepoRequest.correction(report)
        XCTAssertEqual(try JSONDecoder().decode(RepoRequest.self, from: JSONEncoder().encode(request)), request)
        XCTAssertEqual(EdgeProtocol.version, 2)
        XCTAssertNil(RepoServer.validate(request))
        XCTAssertNotNil(RepoServer.validate(.correction(.init(heard: String(repeating: "x", count: RepoRequestLimits.maxTextLength + 1), corrected: "Xandor"))))
    }

    func testManifestEditMarkerIsOptional() throws {
        let item = HistoryManifestItem(id: UUID(), timestamp: Date())
        let data = try JSONEncoder().encode(item)
        XCTAssertNil(try JSONDecoder().decode(HistoryManifestItem.self, from: data).hasEditedText)
        XCTAssertNil(try JSONDecoder().decode(HistoryManifestItem.self, from: data).editedTextRevision)
    }

    func testDictionaryPageForgottenOptInIsOptionalOnWire() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let old = try decoder.decode(RepoRequest.self, from: Data(#"{"kind":"dictionaryPage","limit":1}"#.utf8))
        XCTAssertEqual(old, .dictionaryPage(limit: 1, afterPattern: nil))
        let new = RepoRequest.dictionaryPage(limit: 1, afterPattern: nil, includeForgotten: true)
        XCTAssertEqual(try decoder.decode(RepoRequest.self, from: encoder.encode(new)), new)
        struct OldPage: Decodable { let kind: String; let limit: Int; let afterPattern: String? }
        XCTAssertEqual(try decoder.decode(OldPage.self, from: encoder.encode(new)).limit, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        XCTAssertNil(json["includeForgotten"])
    }

}

extension DictionaryLearningCompatibilityTests {
    private final class ReplyTransport: RepoTransport {
        var reply: RepoResult = .ok
        func send(_ request: RepoRequest) async throws -> RepoResult {
            try JSONDecoder().decode(RepoResult.self, from: JSONEncoder().encode(reply))
        }
    }

    func testCorrectionOutcomeReachesConnectedMacAndOldOKRemainsReadable() async throws {
        let transport = ReplyTransport(), client = CoreSyncClient(transport: ReplyTransport())
        let report = CorrectionReport(heard: "Ann", corrected: "Anne", explicit: true)
        let legacy = try await client.learnCorrection(report)
        XCTAssertNil(legacy, "old receipt acknowledgement must not claim saving succeeded")
        let modern = CoreSyncClient(transport: transport)
        for outcome in [CorrectionOutcome(historySaved: true, learned: false),
                        .init(historySaved: false, learned: false),
                        .init(historySaved: false, learned: true),
                        .init(historySaved: true, learned: false, learningFailed: true)] {
            transport.reply = .correctionOutcome(outcome)
            let received = try await modern.learnCorrection(report)
            XCTAssertEqual(received, outcome)
            XCTAssertEqual(received?.message, outcome.message)
            struct OldReply: Decodable { let kind: String }
            let data = try JSONEncoder().encode(transport.reply)
            XCTAssertEqual(try JSONDecoder().decode(OldReply.self, from: data).kind, "ok")
        }
        transport.reply = .error("Synthetic save failed")
        do {
            _ = try await modern.learnCorrection(report)
            XCTFail("a failed save must propagate to the connected Mac")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic save failed")) }
    }

    func testSelectionAndCompositeDictionaryCursorAreOptionalForOldPeers() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let legacy = try decoder.decode(CorrectionReport.self, from: Data(#"{"heard":"Ann","corrected":"Anne","explicit":true}"#.utf8))
        XCTAssertNil(legacy.selection)
        var modern = legacy
        modern.entryID = UUID()
        modern.selection = .init(start: 0, end: 3, originalText: "Ann met Anna")
        XCTAssertEqual(try decoder.decode(CorrectionReport.self, from: encoder.encode(modern)), modern)
        struct OldCorrection: Decodable { let heard: String; let corrected: String }
        XCTAssertEqual(try decoder.decode(OldCorrection.self, from: encoder.encode(modern)).heard, "Ann")
        let oldPage = try decoder.decode(RepoRequest.self, from: Data(#"{"kind":"dictionaryPage","limit":1,"afterPattern":"Ann"}"#.utf8))
        XCTAssertEqual(oldPage, .dictionaryPage(limit: 1, afterPattern: "Ann"))
        let page = RepoRequest.dictionaryPage(limit: 1, afterPattern: "Ann", includeForgotten: true, afterID: UUID())
        XCTAssertEqual(try decoder.decode(RepoRequest.self, from: encoder.encode(page)), page)
        struct OldPage: Decodable { let kind: String; let afterPattern: String? }
        XCTAssertEqual(try decoder.decode(OldPage.self, from: encoder.encode(page)).afterPattern, "Ann")
        XCTAssertNotNil(RepoServer.validate(.dictionaryPage(limit: 1, afterPattern: nil, afterID: UUID())))
    }
}
