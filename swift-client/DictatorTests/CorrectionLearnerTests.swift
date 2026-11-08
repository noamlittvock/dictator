import XCTest
@testable import Dictator

final class CorrectionLearnerTests: XCTestCase {
    private func learn(_ before: String, _ after: String, known: (String) -> Bool = { _ in false }) -> [CorrectionLearner.Substitution] {
        CorrectionLearner.substitutions(inserted: before, edited: after, isKnownWord: known)
    }

    func testFindsSubstitutionInsideUnchangedProse() {
        XCTAssertEqual(learn("Ask Zandor about it.", "Ask Xandor about it."), [.init(heard: "Zandor", corrected: "Xandor")])
    }

    func testShortPhraseAndSplitBrand() {
        XCTAssertTrue(learn("Ask Open ai tomorrow", "Ask OpenAI tomorrow").isEmpty, "Only one-to-one substitutions are owned")
        XCTAssertEqual(learn("Visit San Fransisco soon", "Visit San Francisco soon"), [.init(heard: "Fransisco", corrected: "Francisco")])
    }

    func testNamesInMultipleScriptsAndCombiningMarks() {
        for pair in [("נעם", "נועם"), ("ليله", "ليلى"), ("Марина", "Маринна"), ("山田花子", "山田華子"),
                     ("Renée", "Renéé"), ("Andre", "André"), ("O’Connel", "O’Connell")] {
            XCTAssertEqual(learn(pair.0, pair.1).count, 1, "\(pair)")
        }
    }

    func testEverydayWordsAreRejectedInAnyLanguage() {
        let known: Set<String> = ["form", "house", "שלום", "bonjour", "casa"]
        for pair in [("from", "form"), ("hous", "house"), ("שלומ", "שלום"), ("bonjor", "bonjour"), ("cassa", "casa")] {
            XCTAssertTrue(learn(pair.0, pair.1, known: { known.contains($0) }).isEmpty)
        }
    }

    func testBrandInternalCapitalsBypassKnownWordFilter() {
        for pair in [("Github", "GitHub"), ("Iphone", "iPhone"), ("Openai", "OpenAI")] {
            XCTAssertEqual(learn(pair.0, pair.1, known: { _ in true }).count, 1)
        }
        XCTAssertTrue(learn("hello", "Hello").isEmpty)
        XCTAssertTrue(learn("HELLO", "Hello").isEmpty)
    }

    func testRealSimilarityRejectsRewritesOfSameLength() {
        for pair in [("call Susan", "meet David"), ("write the draft", "erase the notes"), ("Zandor", "Marble"), ("alpha", "omega")] {
            XCTAssertTrue(learn(pair.0, pair.1).isEmpty, "\(pair)")
        }
        XCTAssertFalse(CorrectionLearner.similar("book", "tablet"))
        XCTAssertTrue(CorrectionLearner.similar("fransisco", "francisco"))
    }

    func testRejectsFourChangedSpansIncludingPureAdditions() {
        XCTAssertTrue(learn("Zandor and Brindle then Torven or Nivara", "Xandor and Brindel then Torvin or Nivarra").isEmpty)
        XCTAssertTrue(learn("Zandor and Brindle then Torven or Nivara", "Xandor and Brindel then Torvin or Nivara extra").isEmpty)
        XCTAssertEqual(learn("Zandor and Brindle then Torven", "Xandor and Brindel then Torvin").count, 3)
    }

    func testRejectsInsertionsDeletionsAndLongPhrases() {
        XCTAssertTrue(learn("hello", "hello Xandor").isEmpty)
        XCTAssertTrue(learn("hello Xandor", "hello").isEmpty)
        XCTAssertTrue(learn("Alpha Bravo Charlie Delta", "Alphaa Bravoo Charliee Deltaa").isEmpty)
    }

    func testRejectsNonVocabulary() {
        let pairs = [
            ("/tmp/Zandor", "/tmp/Xandor"), ("~/Zandor", "~/Xandor"), ("C:\\Zandor", "C:\\Xandor"),
            ("https://zandor.test", "https://xandor.test"), ("zandor.com", "xandor.com"),
            ("zandor@example.test", "xandor@example.test"), ("foo_bar", "foo_barr"),
            ("foo.bar", "foo.barr"), ("foo()", "fooo()"), ("$ZANDOR", "$XANDOR"),
            ("sk_live_secret", "sk_live_secrett"), ("\"Zandor\":", "\"Xandor\":"), ("Zandor:", "Xandor:"), ("deadbeef", "deadbeee"),
            ("abc123def", "abc124def"), ("12345", "12346"), ("2026-10-05", "2026-10-06"),
            ("**Zandor**", "**Xandor**"), ("`Zandor`", "`Xandor`"), ("#Zandor", "#Xandor"),
            ("[Zandor](url)", "[Xandor](url)"), ("Zandor🙂", "Xandor🙂"), ("an", "a"),
            (String(repeating: "a", count: 41), String(repeating: "a", count: 40) + "b")
        ]
        for pair in pairs { XCTAssertTrue(learn(pair.0, pair.1).isEmpty, "\(pair)") }
    }

    func testSentencePunctuationDoesNotEnterTerm() {
        XCTAssertEqual(learn("Ask Zandor.", "Ask Xandor.").first?.corrected, "Xandor")
        XCTAssertTrue(learn("Zandor", "Zandor!").isEmpty)
        for context in ["# Zandor", "- Zandor", "let Zandor = value", "`Zandor`", "[Zandor](target)"] {
            XCTAssertTrue(learn(context, context.replacingOccurrences(of: "Zandor", with: "Xandor")).isEmpty)
        }
    }

    func testIdenticalEmptyAndOversizedInputs() {
        XCTAssertTrue(learn("", "Zandor").isEmpty)
        XCTAssertTrue(learn("Zandor", "Zandor").isEmpty)
        XCTAssertTrue(learn(Array(repeating: "Zandor", count: 513).joined(separator: " "), "Xandor").isEmpty)
    }
}
