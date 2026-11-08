import XCTest
@testable import Dictator

/// A dictation that continues earlier text joins it with the right space
/// and case, and only the start of the new text ever changes.
final class InsertionSeamTests: XCTestCase {
    private func assertJoin(_ preceding: String?, _ text: String, _ expected: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(InsertionSeam.join(text, after: preceding), expected,
                       "\(preceding.debugDescription) + \(text.debugDescription)", file: file, line: line)
    }

    func testNothingReadableBeforeTheCaretLeavesTheTextAlone() {
        assertJoin(nil, "Two.", "Two.")
        assertJoin("", "Two.", "Two.")
        assertJoin("That's one", "", "")
    }

    func testAddsTheSpaceBetweenTwoDictations() {
        assertJoin("That's one.", "Two.", " Two.")
        assertJoin("Is it ready?", "Ship it.", " Ship it.")
        assertJoin("He said “yes”", "Great.", " Great.")
        assertJoin("שלום.", "מה שלומך?", " מה שלומך?")
        assertJoin("version 2", "(beta)", " (beta)")
    }

    func testNoSecondSpaceWhenTheFieldAlreadyHasOne() {
        assertJoin("That's one. ", "Two.", "Two.")
        assertJoin("That's one. ", " Two.", "Two.")
        assertJoin("First line\n", "Second line.", "Second line.")
        assertJoin("Done.\t", "Next.", "Next.")
    }

    func testNoSpaceBeforePunctuationThatAttaches() {
        assertJoin("That's one", ", two.", ", two.")
        assertJoin("That's one", ".", ".")
        assertJoin("Up 20", "%.", "%.")
        assertJoin("(see above", ")", ")")
    }

    func testNoSpaceAfterAnOpeningBracketQuoteOrSlash() {
        assertJoin("Note (", "Draft.", "Draft.")
        assertJoin("She wrote “", "Hello.", "Hello.")
        assertJoin("She wrote \"", "Hello.", "Hello.")
        assertJoin("'", "Quoted.", "Quoted.")
        assertJoin("~/", "Documents", "Documents")
    }

    func testAClosingStraightQuoteStillGetsASpace() {
        assertJoin("She wrote \"hi\"", "Then left.", " Then left.")
        assertJoin("the users'", "Settings.", " Settings.")
    }

    func testMidSentenceLowercasesACommonFirstWord() {
        assertJoin("That's one", "Two.", " two.")
        assertJoin("Hi Dana,", "The report is done.", " the report is done.")
        assertJoin("We shipped it;", "It's live.", " it's live.")
        assertJoin("We shipped it;", "It’s live.", " it’s live.")
        assertJoin("page 4", "And then stop.", " and then stop.")
    }

    func testMidSentenceKeepsNamesAcronymsAndI() {
        assertJoin("Ask", "Dana about it.", " Dana about it.")
        assertJoin("Send it to", "NASA.", " NASA.")
        assertJoin("Yes,", "I agree.", " I agree.")
        assertJoin("Yes,", "I'm in.", " I'm in.")
        assertJoin("That's one", "TWO.", " TWO.")
    }

    func testAfterASentenceEndTheCapitalStays() {
        assertJoin("That's one.", "The next one.", " The next one.")
        assertJoin("Really!", "It works.", " It works.")
        assertJoin("Options:", "The first.", " The first.")
    }

    func testOnlyTheFirstWordChanges() {
        assertJoin("That's one", "The Report is The best.", " the Report is The best.")
    }

    func testPrecedingTextIsTheTailBeforeTheCaret() {
        XCTAssertEqual(InsertionSeam.preceding("Hello world", caret: 5), "Hello")
        XCTAssertEqual(InsertionSeam.preceding("Hello world", caret: 99), "Hello world")
        XCTAssertEqual(InsertionSeam.preceding("Hello world", caret: -1), "")
        XCTAssertEqual(InsertionSeam.preceding("abcdef", caret: 6, maxLength: 3), "def")
        XCTAssertEqual(InsertionSeam.preceding("line one\nline two", caret: 9), "line one\n")
        // Accessibility offsets count UTF-16 units: the emoji is two.
        XCTAssertEqual(InsertionSeam.preceding("hi 👋 there", caret: 5), "hi 👋")
    }
}
