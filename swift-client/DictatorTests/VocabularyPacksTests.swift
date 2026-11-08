import XCTest
@testable import Dictator

final class VocabularyPacksTests: XCTestCase {
    private let fixtures: [VocabularyPack] = [
        VocabularyPack(id: "common", name: "Everyday", summary: "Names", language: "en",
                       terms: ["ChatGPT", "YouTube"], apps: [], alwaysOn: true),
        VocabularyPack(id: "software", name: "Software", summary: "Tools", language: "en",
                       terms: ["Kubernetes", "chatgpt"], apps: ["com.test.Editor"]),
        VocabularyPack(id: "music", name: "Music", summary: "Theory", language: "en",
                       terms: ["Ableton", "YouTube"], apps: ["com.test.Music"]),
        VocabularyPack(id: "other-language", name: "Other", summary: "Other language", language: "fr",
                       terms: ["français"], apps: ["com.test.Editor"], alwaysOn: true)
    ]

    private func active(automatic: Bool = true, on: [String] = [], off: [String] = [],
                        installed: Set<String> = [], destination: String? = nil, languages: [String] = ["en"]) -> [String] {
        VocabularyPackCatalog.activeTerms(in: fixtures, automatic: automatic, on: on, off: off,
                                          installedBundleIDs: installed, destinationBundleID: destination, languages: languages)
    }

    func testBundledCatalogLoadsEveryPackAndEveryFileIsValid() throws {
        let expected: Set<String> = ["common", "software", "medicine", "law", "finance", "science", "music", "design-video", "marketing-sales"]
        XCTAssertEqual(Set(VocabularyPackCatalog.all.map(\.id)), expected, "project.yml must bundle the pack folder")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/vocabulary-packs")
        let packs = try VocabularyPackCatalog.load(from: root)
        XCTAssertEqual(Set(packs.map(\.id)), expected)
        XCTAssertEqual(packs.first?.id, "common")
        for pack in packs {
            XCTAssertEqual(pack.language, "en")
            XCTAssertFalse(pack.terms.isEmpty)
            XCTAssertEqual(Set(pack.terms.map { $0.lowercased() }).count, pack.terms.count, pack.id)
            let metadataURL = root.appendingPathComponent("metadata/\(pack.id).json")
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
            metadata["terms"] = pack.terms
            let fromMetadata = try JSONDecoder().decode(VocabularyPack.self, from: JSONSerialization.data(withJSONObject: metadata))
            XCTAssertEqual(fromMetadata, pack)
            let candidates = try String(contentsOf: root.appendingPathComponent("candidates/\(pack.id).txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            XCTAssertTrue((120...160).contains(candidates.count), pack.id)
            XCTAssertEqual(Set(candidates.map { $0.lowercased() }).count, candidates.count, pack.id)
            XCTAssertTrue(Set(pack.terms).isSubset(of: Set(candidates)))
            if ["law", "medicine"].contains(pack.id) { XCTAssertTrue(pack.apps.isEmpty) }
        }
    }

    func testStrictLoaderRejectsDuplicateTerms() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var bad = fixtures[0]
        bad.terms = ["Term", "term"]
        try JSONEncoder().encode(bad).write(to: folder.appendingPathComponent("common.json"))
        XCTAssertThrowsError(try VocabularyPackCatalog.load(from: folder))
    }

    func testAutomaticSelectionAndAlwaysOn() {
        XCTAssertEqual(active(), ["ChatGPT", "YouTube"])
        XCTAssertEqual(VocabularyPackCatalog.automaticIDs(in: fixtures, installedBundleIDs: ["com.test.Music"]), ["music"])
        XCTAssertEqual(active(installed: ["com.test.Editor"]), ["Kubernetes", "ChatGPT", "YouTube"])
        XCTAssertEqual(active(automatic: false, installed: ["com.test.Editor"]), ["ChatGPT", "YouTube"])
        XCTAssertEqual(active(automatic: false, on: ["software"]), ["Kubernetes", "ChatGPT", "YouTube"])
    }

    func testOffBeatsAlwaysOnManualOnAutomaticAndDestination() {
        XCTAssertEqual(active(on: ["software", "common"], off: ["common", "software"], installed: ["com.test.Editor"],
                              destination: "com.test.Editor"), [])
    }

    func testDestinationGoesFirstAndDedupeKeepsFirstSpelling() {
        XCTAssertEqual(active(installed: ["com.test.Editor", "com.test.Music"], destination: "com.test.Editor"),
                       ["Kubernetes", "chatgpt", "Ableton", "YouTube"])
        XCTAssertEqual(active(on: ["music", "software"], destination: "com.test.Music"),
                       ["Ableton", "YouTube", "Kubernetes", "ChatGPT"])
        XCTAssertEqual(active(on: ["music", "software"], destination: "com.unknown.App"),
                       ["Kubernetes", "Ableton", "ChatGPT", "YouTube"])
    }

    func testOnlyConfiguredLanguagesApplyIncludingRegionalVariants() {
        XCTAssertEqual(active(on: ["software"], languages: ["he"]), [])
        XCTAssertEqual(active(on: ["software"], languages: []), [])
        XCTAssertEqual(active(on: ["software"], languages: ["en_US"]), ["Kubernetes", "ChatGPT", "YouTube"])
        XCTAssertEqual(active(languages: ["fr-CA"]), ["français"])
        XCTAssertEqual(active(languages: ["fr", "en-GB"]), ["ChatGPT", "français", "YouTube"])
    }

    func testSelectionValidationRetainsFutureIDsAndBoundsPayloads() {
        XCTAssertTrue(VocabularyPackCatalog.validSelection(["future-pack", "common"]))
        XCTAssertTrue(VocabularyPackCatalog.validSelection([]))
        XCTAssertFalse(VocabularyPackCatalog.validSelection(["common", "common"]))
        XCTAssertFalse(VocabularyPackCatalog.validSelection(["../escape"]))
        XCTAssertFalse(VocabularyPackCatalog.validSelection([String(repeating: "a", count: 65)]))
        XCTAssertFalse(VocabularyPackCatalog.validSelection((0...100).map { "pack-\($0)" }))
    }

    func testOldWireSettingsAndExplicitEmptySelections() throws {
        let old = Data(#"{"refineLevel":"exact","customSystemPrompt":"","persistHistory":true}"#.utf8)
        let decoded = try JSONDecoder().decode(CoreSettingsDTO.self, from: old)
        XCTAssertNil(decoded.vocabularyPacksAutomatic)
        XCTAssertNil(decoded.vocabularyPacksOn)
        XCTAssertNil(decoded.vocabularyPacksOff)
        let patch = CoreSettingsPatch(vocabularyPacksAutomatic: false, vocabularyPacksOn: [], vocabularyPacksOff: ["common"])
        XCTAssertFalse(patch.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(CoreSettingsPatch.self, from: JSONEncoder().encode(patch)), patch)
        XCTAssertTrue(CoreSettingsPatch().isEmpty)
    }
}

extension VocabularyPacksTests {
    func testHintInputIncludesFieldsAndPreservesOtherPrioritiesWithoutNearbyText() {
        var input = VocabularyHintInput(ownerNames: ["Noa"], starred: ["Pinned"], nearby: ["must be empty"])
        input.includeFields(automatic: true, on: ["music"], off: [], installedBundleIDs: ["com.test.Editor"],
                            destinationBundleID: "com.test.Music", languages: ["en-US"], catalog: fixtures)
        XCTAssertEqual(input.nearby, [])
        XCTAssertEqual(input.packs, ["Ableton", "YouTube", "Kubernetes", "ChatGPT"])
        XCTAssertEqual(Array(VocabularyHint.orderedTerms(input).prefix(2)), ["Noa", "Pinned"])
        input.includeFields(automatic: true, on: ["music"], off: ["music", "software"], installedBundleIDs: ["com.test.Editor"],
                            destinationBundleID: "com.test.Music", languages: ["fr"], catalog: fixtures)
        XCTAssertEqual(input.packs, ["français"])
    }
}

extension VocabularyPacksTests {
    func testDestinationOnAnotherMacSelectsItsFieldWithoutLocalInstallation() {
        XCTAssertEqual(active(destination: "com.test.Editor"), ["Kubernetes", "chatgpt", "YouTube"])
        XCTAssertEqual(active(automatic: false, destination: "com.test.Editor"), ["ChatGPT", "YouTube"])
        XCTAssertEqual(active(off: ["software"], destination: "com.test.Editor"), ["ChatGPT", "YouTube"])
    }
}


extension VocabularyPacksTests {
    func testSharedBuilderKeepsStarredAndPersonalWordsAheadOfPacks() {
        let entries = [
            DictionaryEntryDTO(id: UUID(), pattern: "Frequent", replacement: "", isVocabulary: true, useCount: 40),
            DictionaryEntryDTO(id: UUID(), pattern: "Starred", replacement: "", isVocabulary: true, isStarred: true),
            DictionaryEntryDTO(id: UUID(), pattern: "heard star", replacement: "starred", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "Learned", replacement: "", isVocabulary: true, origin: "learned"),
            DictionaryEntryDTO(id: UUID(), pattern: "Forgotten", replacement: "", isVocabulary: true, isStarred: true, isForgotten: true),
        ]
        let input = VocabularyHint.vocabularyHintInput(entries: entries, ownerNames: ["Owner"], voiceLaunch: [],
            forVoiceCommandSession: false, automatic: false, on: ["software"], off: [], installedBundleIDs: [],
            destinationBundleID: nil, languages: ["en"], catalog: fixtures)
        XCTAssertEqual(VocabularyHint.orderedTerms(input),
                       ["Owner", "Starred", "Frequent", "Learned", "Kubernetes", "ChatGPT", "YouTube"])
    }

    func testPriorityAndWeightedRoundsPreservePackOrder() {
        let packs = [
            VocabularyPack(id: "common", name: "Common", summary: "", language: "en", terms: ["c1", "c2", "c3"], apps: [], alwaysOn: true),
            VocabularyPack(id: "auto", name: "Auto", summary: "", language: "en", terms: ["a1", "a2", "a3"], apps: ["app.Auto"]),
            VocabularyPack(id: "manual", name: "Manual", summary: "", language: "en", terms: ["m1", "m2", "m3"], apps: []),
            VocabularyPack(id: "destination", name: "Destination", summary: "", language: "en", terms: ["d1", "d2", "d3", "d4"], apps: ["app.Destination"]),
        ]
        let terms = VocabularyPackCatalog.activeTerms(in: packs, automatic: true, on: ["manual"], off: [],
            installedBundleIDs: ["app.Auto"], destinationBundleID: "app.Destination", languages: ["en"])
        XCTAssertEqual(terms, ["d1", "d2", "m1", "a1", "c1", "d3", "d4", "m2", "a2", "c2", "m3", "a3", "c3"])
    }

    func testRealPacksShareTheTwoHundredTokenBudget() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/vocabulary-packs")
        let packs = try VocabularyPackCatalog.load(from: root)
        func fitted(fields: [String], destination: String? = nil) -> [String] {
            let input = VocabularyHint.vocabularyHintInput(entries: [], ownerNames: ["Test Person"], voiceLaunch: [],
                forVoiceCommandSession: false, automatic: false, on: fields, off: [], installedBundleIDs: [],
                destinationBundleID: destination, languages: ["en"], catalog: packs)
            // Same conservative, frame-inclusive estimate as the preview;
            // no model, tokenizer download or live speech engine in tests.
            return VocabularyHint.fit(VocabularyHint.orderedTerms(input), budget: 200) {
                Int(ceil(Double((" " + VocabularyHint.prompt([$0], language: "en")).utf8.count) / 3))
            }
        }
        func count(_ id: String, in terms: [String]) -> Int {
            let words = Set(packs.first { $0.id == id }!.terms)
            return terms.filter { words.contains($0) }.count
        }
        for fields in [["software"], ["software", "music"], ["software", "music", "medicine"]] {
            let terms = fitted(fields: fields)
            XCTAssertEqual(terms.first, "Test Person")
            for id in ["common"] + fields {
                XCTAssertGreaterThanOrEqual(count(id, in: terms), fields.count == 3 ? 9 : 12, id)
            }
        }
        let destination = fitted(fields: ["software", "music"], destination: "com.apple.dt.Xcode")
        let software = try XCTUnwrap(VocabularyPackCatalog.all.first { $0.id == "software" })
        XCTAssertEqual(Array(destination.prefix(3)), ["Test Person"] + software.terms.prefix(2))
        XCTAssertGreaterThan(count("software", in: destination), count("music", in: destination))
        XCTAssertGreaterThanOrEqual(count("common", in: destination), 8)
        XCTAssertGreaterThanOrEqual(count("music", in: destination), 8)
    }
}
