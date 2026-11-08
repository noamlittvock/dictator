import XCTest
@testable import Dictator

final class VocabularyHintTests: XCTestCase {
    func testPriorityRankingRecencyDedupeAndVoiceLaunch() {
        let input = VocabularyHintInput(
            ownerNames: ["Noa", "  "], starred: ["Keep", "NOA"],
            ranked: [
                .init(text: "Older", useCount: 2, lastUsedAt: Date(timeIntervalSince1970: 1)),
                .init(text: "Frequent", useCount: 8, lastUsedAt: nil),
                .init(text: "Recent", useCount: 2, lastUsedAt: Date(timeIntervalSince1970: 2)),
            ], voiceLaunch: ["Launch", "keep"], nearby: ["Nearby"], packs: ["Pack", "NOA"]
        )
        XCTAssertEqual(VocabularyHint.orderedTerms(input), ["Noa", "Keep", "Frequent", "Recent", "Older", "Launch", "Nearby", "Pack"])
        var launch = input
        launch.isVoiceLaunch = true
        XCTAssertEqual(VocabularyHint.orderedTerms(launch), ["Launch", "keep", "Noa", "Frequent", "Recent", "Older", "Nearby", "Pack"])
    }

    func testWholeTermsFitWithFrameIncludedAndKeepOrder() {
        // An injected tokenizer counts whitespace tokens, including the frame.
        // A too-large term is skipped whole, leaving room for later terms.
        let long = Array(repeating: "oversized", count: 300).joined(separator: " ")
        let terms = ["Noa", long, "GitHub", "Claude Code"]
        let fitted = VocabularyHint.fit(terms, budget: 10) {
            VocabularyHint.prompt([$0], language: "en").split(whereSeparator: \.isWhitespace).count
        }
        XCTAssertEqual(fitted, ["Noa", "GitHub"])
        XCTAssertTrue(VocabularyHint.fit(["Noa"], budget: 0, tokens: { $0.count }).isEmpty)
        XCTAssertEqual(VocabularyHint.budget, 200)
    }

    func testSharedSentenceFramesAndFallback() {
        XCTAssertEqual(VocabularyHint.prompt(["Noa", "GitHub"], language: "en"), "Hello. Today we talked about Noa, GitHub, and more. Thanks.")
        for language in ["he", "es", "fr", "de", "ja"] {
            let prompt = VocabularyHint.prompt(["Noa", "GitHub"], language: language)
            XCTAssertTrue(prompt.hasSuffix("."))
            XCTAssertTrue(prompt.contains("Noa, GitHub"))
        }
        XCTAssertEqual(VocabularyHint.prompt(["Noa"], language: "ja"), "Noa.")
        XCTAssertEqual(VocabularyHint.prompt(["Noa"], language: nil), "Noa.")
        XCTAssertEqual(VocabularyHint.prompt(["Noa"], language: "fr-CA"), VocabularyHint.prompt(["Noa"], language: "fr"))
        XCTAssertEqual(VocabularyHint.prompt([], language: "en"), "")
    }

    func testServerReceivesHintWithoutReplacementRulesAndDecodesRaw() async throws {
        let secrets = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        LocalSecret.directoryOverrideForTesting = secrets
        defer {
            LocalSecret.directoryOverrideForTesting = nil
            try? FileManager.default.removeItem(at: secrets)
        }
        MockURLProtocol.seen = []
        MockURLProtocol.handler = { _, _ in (200, Data(#"{"text":"GitHub","raw":"git hub"}"#.utf8)) }
        defer { MockURLProtocol.handler = nil; MockURLProtocol.seen = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = TranscriptionService(session: URLSession(configuration: config))
        let hint = VocabularyHintInput(ownerNames: ["Noa"], starred: ["GitHub"], voiceLaunch: ["Launch"], isVoiceLaunch: true)
        let audio = CapturedAudio(data: Data(repeating: 0, count: 640), durationSeconds: 0.01, sampleRate: 16_000, frameCount: 160)
        let result = try await service.transcribe(audio: audio, serverURL: "http://100.64.0.1:7878", refineLevel: .exact,
                                                 dictionary: [], vocabularyHint: hint)
        XCTAssertEqual(result.text, "GitHub")
        XCTAssertEqual(result.rawText, "git hub")
        let request = try XCTUnwrap(MockURLProtocol.seen.last?.0)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Dictionary"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Vocabulary-Hint"))
        let data = try XCTUnwrap(Data(base64Encoded: header))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        XCTAssertEqual(payload["terms"], ["Launch", "Noa", "GitHub"])
    }
}
