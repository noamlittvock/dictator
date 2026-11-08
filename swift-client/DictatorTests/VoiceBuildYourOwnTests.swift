import AppKit
import XCTest
@testable import Dictator

final class VoiceBuildYourOwnTests: XCTestCase {
    private func config() -> VoiceLaunchConfig {
        VoiceLaunchConfig(lists: [
            VoiceList(name: "People", fields: ["phone", "email"], entries: [VoiceListEntry(names: ["Noam"], values: ["phone": "1"])]),
            VoiceList(name: "Projects", fields: ["folder"]),
        ])
    }

    private func round(_ pattern: String, file: StaticString = #filePath, line: UInt = #line) -> SentenceBuilder? {
        let builder = SentenceBuilder(pattern: pattern)
        XCTAssertNotNil(builder, pattern, file: file, line: line)
        if let builder {
            XCTAssertEqual(VoicePattern.parse(builder.pattern), VoicePattern.parse(pattern), file: file, line: line)
        }
        return builder
    }

    // MARK: Sentence builder and pattern strings

    func testBuilderWritesThePatternTheEngineReads() {
        var builder = SentenceBuilder(opening: "WhatsApp")
        builder.addList("People")
        builder.addWords(named: "message")
        XCTAssertEqual(builder.pattern, "WhatsApp {person:People} {message}")
        XCTAssertNil(builder.problem(config: config()))
    }

    func testRoundTripsPlainPatterns() {
        for pattern in ["WhatsApp {person:People} {message}", "Google {query}", "Code {project:Projects} {prompt}",
                        "Email {person:People} subject {subject} body {body}", "Open"] {
            let builder = round(pattern)
            XCTAssertEqual(builder?.pattern, pattern)
        }
    }

    func testRoundTripsOptionalPartsAndMarkers() {
        let builder = round("Email {person:People} [subject {subject} body] {body}")
        XCTAssertEqual(builder?.pieces.map(\.canSkip), [false, true, false, false, false])
        XCTAssertEqual(builder?.pieces.map(\.written), ["{person:People}", "subject", "{subject}", "body", "{body}"])
        XCTAssertEqual(builder?.pattern, "Email {person:People} [subject {subject} body] {body}")
        XCTAssertNotNil(round("Note {text} tag [{label}]"))
        XCTAssertNotNil(round("Note [{text} tag] {label}"))
    }

    func testSkippingWordsGroupsThemWithTheirFollowingMarker() {
        var builder = SentenceBuilder(opening: "Mail")
        builder.addWords(named: "message")
        builder.addMarker("subject")
        builder.addWords(named: "subject line")
        builder.pieces[0].canSkip = true
        XCTAssertEqual(builder.pattern, "Mail [{message} subject] {subject_line}")
        XCTAssertNil(builder.problem(config: config()))
    }

    func testSentenceItCannotShowExactlyIsNotRewritten() {
        XCTAssertNil(SentenceBuilder(pattern: "Mail [{a} x {b}]"))
        XCTAssertNil(SentenceBuilder(pattern: "{message}"))
    }

    func testMovingAndRemovingPieces() {
        var builder = SentenceBuilder(opening: "Go")
        builder.addWords(named: "one")
        builder.addMarker("then")
        builder.addWords(named: "two")
        builder.move(builder.pieces[0].id, by: 1)
        XCTAssertEqual(builder.pattern, "Go then {one} {two}")
        builder.move(builder.pieces[0].id, by: -1)
        XCTAssertEqual(builder.pattern, "Go then {one} {two}")
        builder.remove(builder.pieces[0].id)
        XCTAssertEqual(builder.pattern, "Go {one} {two}")
    }

    func testValueNamesAreSafeAndUnique() {
        var builder = SentenceBuilder(opening: "Go")
        builder.addWords(named: "My message!")
        builder.addWords(named: "my message")
        builder.addList("People")
        builder.addList("People")
        XCTAssertEqual(builder.pieces.compactMap(\.slotName), ["my_message", "my_message2", "person", "person2"])
        XCTAssertEqual(SentenceBuilder.slotName(from: "  ", avoiding: []), "message")
    }

    // MARK: Plain validation

    func testPlainValidationMessages() {
        var builder = SentenceBuilder(opening: "  ")
        XCTAssertEqual(builder.problem(config: config()), VoiceBuildCopy.needOpening)
        builder.opening = "Go"
        builder.addWords(named: "message")
        builder.addWords(named: "more")
        XCTAssertEqual(builder.problem(config: config()), "Your words need to come last, or be followed by a word that starts a new part.")
        builder.pieces.removeLast()
        builder.pieces[0].canSkip = true
        builder.addList("People")
        XCTAssertEqual(builder.problem(config: config()), VoiceBuildCopy.skippedWordsNeedMarker)
        var empty = SentenceBuilder(opening: "Go")
        empty.addMarker("  ")
        XCTAssertEqual(empty.problem(config: config()), VoiceBuildCopy.markerNeedsWord)
        var missing = SentenceBuilder(opening: "Go")
        missing.addList("Places")
        XCTAssertEqual(missing.problem(config: config()), VoiceBuildCopy.missingList("Places"))
    }

    func testSkippedWordsAtTheEndNeedAMarkerOnlyWhenNotLast() {
        var builder = SentenceBuilder(opening: "Go")
        builder.addList("People")
        builder.addWords(named: "message")
        builder.pieces[1].canSkip = true
        XCTAssertNil(builder.problem(config: config()))
        builder.addMarker("please")
        builder.pieces[1].canSkip = true
        XCTAssertNil(builder.problem(config: config()))
    }

    func testExampleSentence() {
        XCTAssertEqual(SentenceBuilder.exampleSentence(pattern: "WhatsApp {person:People} {message}", config: config()), "WhatsApp Noam running late")
        let segments = SentenceBuilder.exampleSegments(pattern: "WhatsApp {person:People} {message}", config: config())
        XCTAssertEqual(segments.map(\.role), [.opens, .who, .words])
        XCTAssertEqual(SentenceBuilder.exampleSentence(pattern: "Google {query}", config: .empty), "Google best pizza")
    }

    // MARK: Values in text

    private func values() -> [InsertableValue] {
        InsertableValue.available(pattern: "Code {project:Projects} {message}", config: config()) +
            InsertableValue.available(pattern: "WhatsApp {person:People} {message2}", config: config())
    }

    func testAvailableValuesHavePlainNames() {
        let names = InsertableValue.available(pattern: "WhatsApp {person:People} {message}", config: config()).map(\.name)
        XCTAssertEqual(names, ["person", "person’s phone", "person’s email", "message"])
        XCTAssertEqual(InsertableValue.available(pattern: "Code {project:Projects} {prompt}", config: config()).map(\.name),
                       ["project", "project folder", "prompt"])
    }

    func testTemplateAndPartsRoundTrip() {
        let vals = values()
        for template in ["whatsapp://send?phone={person.phone}&text={message2}", "{message}", "Hi {person}, {message2}!", "plain", ""] {
            XCTAssertEqual(ValueText.template(ValueText.parts(template, values: vals)), template)
        }
        let parts = ValueText.parts("a {message} b", values: vals)
        XCTAssertEqual(parts.count, 3)
        if case .value(let value) = parts[1] { XCTAssertEqual(value.name, "message") } else { XCTFail() }
    }

    func testTypedBracketsNeverBecomeReferences() {
        XCTAssertEqual(ValueText.template([.text("hello {oops}")]), "hello oops")
    }

    func testUnknownValuesStillShowAsPlainBubbles() {
        if case .value(let value)? = ValueText.parts("{gone.phone}", values: []).first {
            XCTAssertEqual(value.name, "gone’s phone")
        } else { XCTFail() }
    }

    func testPlainSummaryOfATemplate() {
        XCTAssertEqual(ValueText.plain("Hi {person}, {message}"), "Hi the person, the message")
    }

    func testBubbleTextRoundTripsThroughTheTextView() {
        let vals = values()
        let font = NSFont.systemFont(ofSize: 13)
        for template in ["https://x.com/?q={message}&p={person.phone}", "{message}{message2}", "just text", ""] {
            let attributed = ValueBubbleText.attributed(from: template, values: vals, font: font)
            XCTAssertFalse(attributed.string.contains("{"), template)
            XCTAssertEqual(ValueBubbleText.template(from: attributed), template)
        }
        let text = NSMutableAttributedString(attributedString: ValueBubbleText.attributed(from: "{message}", values: vals, font: font))
        text.append(NSAttributedString(string: " typed {x}", attributes: ValueBubbleText.baseAttributes(font: font)))
        XCTAssertEqual(ValueBubbleText.template(from: text), "{message} typed x")
    }

    // MARK: Example address

    func testExampleAddressReplacesTheSampleWord() {
        XCTAssertEqual(ExampleAddress.convert("https://www.google.com/search?q=TEST", value: "{query}"),
                       .converted("https://www.google.com/search?q={query}"))
        XCTAssertEqual(ExampleAddress.convert("https://x.com/find?term=test&page=1", value: "{query}"),
                       .converted("https://x.com/find?term={query}&page=1"))
        XCTAssertEqual(ExampleAddress.convert("https://x.com/TEST/results/Test", value: "{q}"), .converted("https://x.com/{q}/results/{q}"))
    }

    func testExampleAddressFindsEncodedForms() {
        XCTAssertEqual(ExampleAddress.convert("https://x.com/?q=%54%45%53%54", value: "{q}"), .converted("https://x.com/?q={q}"))
        XCTAssertEqual(ExampleAddress.convert("https://x.com/?q=%54%65%73%54&z=1", value: "{q}"), .converted("https://x.com/?q={q}&z=1"))
        XCTAssertEqual(ExampleAddress.convert("https://x.com/?q=%74%65%73%74", value: "{q}"), .converted("https://x.com/?q={q}"))
    }

    func testExampleAddressMissingOrNotAnAddress() {
        XCTAssertEqual(ExampleAddress.convert("https://www.latest.com/search?q=cats", value: "{q}"), .notFound)
        XCTAssertEqual(ExampleAddress.convert("https://x.com/attestation", value: "{q}"), .notFound)
        XCTAssertEqual(ExampleAddress.convert("not an address", value: "{q}"), .notAnAddress)
        XCTAssertEqual(ExampleAddress.convert("  ", value: "{q}"), .notAnAddress)
    }

    func testConvertedAddressStillPassesTheEngine() {
        guard case .converted(let link) = ExampleAddress.convert("https://www.google.com/search?q=TEST", value: "{query}") else { return XCTFail() }
        let voiceCommand = VoiceCommand(name: "Google", pattern: "Google {query}", steps: [VoiceStep(kind: .openLink, link: link)])
        XCTAssertNil(VoiceBuildProblems.problem(for: voiceCommand, config: .empty, allowedSchemes: ["https"]))
    }

    // MARK: Actions

    func testActionLabels() {
        XCTAssertEqual(VoiceBuildCopy.addable().map(VoiceBuildCopy.actionLabel), [
            "Open a website", "Open an app", "Run a routine", "Wait until I can type", "Type my words", "Run a command in a folder",
            "Wait for me to cancel (3 seconds)", "Press a key", "Run an Apple Shortcut",
            "Send to n8n, Zapier or another webhook", "Add a line to a file",
        ])
        XCTAssertEqual(VoiceStep.keys.map(VoiceBuildCopy.keyChoice), ["Return (send)", "⌘Return (send)", "Tab", "Esc"])
        var confirm = VoiceStep.Kind.confirm.makeStep()
        confirm.seconds = 5
        XCTAssertEqual(VoiceBuildCopy.cardTitle(confirm), "Wait for me to cancel (5 seconds)")
    }

    func testCodingAssistantsMapToCommands() {
        XCTAssertEqual(CodingAssistant.allCases.map(\.name), ["Claude Code", "Codex", "Gemini", "OpenCode"])
        XCTAssertEqual(CodingAssistant.allCases.map(\.command), ["claude", "codex", "gemini", "opencode"])
        XCTAssertEqual(CodingAssistant.named(forCommand: "codex").name, "Codex")
        XCTAssertNil(CodingAssistant.named(forCommand: "my-tool").assistant)
    }

    func testNewActionsUseYourWordsAndTheProjectFolder() {
        var steps: [VoiceStep] = []
        steps.addAction(.runInTerminal, pattern: "Code {project:Projects} {prompt}")
        XCTAssertEqual(steps.last?.folder, "{project.folder}")
        XCTAssertEqual(steps.last?.argument, "{prompt}")
        steps.addAction(.typeText, pattern: "Note {text}")
        XCTAssertEqual(steps.last?.text, "{text}")
        var sending: [VoiceStep] = []
        XCTAssertTrue(sending.addAction(.pressKey, pattern: "Go {x}"))
        XCTAssertEqual(sending.first?.kind, .confirm)
    }

    func testProgressNamesTheAssistantNotItsCommand() {
        let step = { (command: String?) in VoiceStep(kind: .runInTerminal, folder: "/work/atlas", command: command) }
        XCTAssertEqual(VoiceStepDescription.short(step("claude")), "Start Claude Code in atlas")
        XCTAssertEqual(VoiceStepDescription.short(step("codex")), "Start Codex in atlas")
        XCTAssertEqual(VoiceStepDescription.short(step("my-agent")), "Start my-agent in atlas")
    }

    func testTwoVoiceCommandsSaidTheSameWayGetThePlainMessage() {
        let existing = VoiceCommand(name: "A", pattern: "Go {x}", steps: [VoiceStep(kind: .typeText, text: "{x}")])
        let clashing = VoiceCommand(name: "B", pattern: "Go {x}", steps: [VoiceStep(kind: .typeText, text: "{x}")])
        var config = VoiceLaunchConfig.empty
        config.commands = [existing]
        XCTAssertEqual(VoiceBuildProblems.problem(for: config, editing: clashing), VoiceBuildCopy.sameSentence)
    }

    func testPlainProblemsForActions() {
        let bad = VoiceCommand(name: "A", pattern: "Go {x}", steps: [VoiceStep(kind: .typeText, text: "{gone}")])
        XCTAssertEqual(VoiceBuildProblems.problem(for: bad, config: .empty), VoiceBuildCopy.unknownValue(1, "gone"))
        let none = VoiceCommand(name: "A", pattern: "Go {x}", steps: [])
        XCTAssertEqual(VoiceBuildProblems.problem(for: none, config: .empty), VoiceBuildCopy.needAnAction)
        let sending = VoiceCommand(name: "A", pattern: "Go {x}", steps: [VoiceStep(kind: .pressKey, key: "return")])
        XCTAssertEqual(VoiceBuildProblems.problem(for: sending, config: .empty), VoiceBuildCopy.needCancelPause)
        let noApp = VoiceCommand(name: "A", pattern: "Go", steps: [VoiceStep(kind: .openApp)])
        XCTAssertEqual(VoiceBuildProblems.problem(for: noApp, config: .empty), "Action 1: choose an app or give its name.")
        let empty = VoiceCommand(name: "", pattern: "", steps: [])
        XCTAssertEqual(VoiceBuildProblems.problem(for: empty, config: .empty), VoiceBuildCopy.needOpening)
        let good = VoiceCommand(name: "A", pattern: "Go {x}", steps: [VoiceStep(kind: .typeText, text: "{x}")])
        XCTAssertNil(VoiceBuildProblems.problem(for: good, config: .empty))
    }

    func testSummariesAreInPlainWords() {
        XCTAssertEqual(VoiceBuildCopy.summary(VoiceStep(kind: .openLink, link: "https://www.google.com/search?q={query}")), "Opens www.google.com")
        XCTAssertEqual(VoiceBuildCopy.summary(VoiceStep(kind: .typeText, text: "{message}")), "Types “the message”")
        XCTAssertEqual(VoiceBuildCopy.summary(VoiceStep(kind: .runInTerminal, folder: "{project.folder}", command: "codex")), "Starts Codex in the project folder")
        XCTAssertEqual(VoiceBuildCopy.summary(VoiceStep(kind: .pressKey, key: "cmdReturn")), "Presses ⌘Return (send)")
    }

    func testTryItDescribesWhatWouldHappenInPlainWords() {
        var config = config()
        config.commands = [VoiceCommand(name: "Note", pattern: "Note {text}", steps: [
            VoiceStep(kind: .openApp, bundleId: "com.apple.Notes"), VoiceStep(kind: .waitForTextField, seconds: 8), VoiceStep(kind: .typeText, text: "{text}"),
        ])]
        let sentence = VoiceTryItResult.actionSentence(for: "Note running late", in: config)
        XCTAssertTrue(sentence?.hasSuffix("then types “running late”") == true, sentence ?? "nil")
        XCTAssertNil(VoiceTryItResult.actionSentence(for: "nothing matches", in: config))
    }

    // MARK: Copy rules

    func testNoBuildYourOwnCopyShowsHowItWorks() {
        let banned = ["slot", "field", "pattern", "trigger", "alias", "template", "step", "token"]
        for text in VoiceBuildCopy.allText {
            XCTAssertFalse(text.isEmpty)
            for character in ["{", "}", "[", "]"] { XCTAssertFalse(text.contains(character), "“\(text)” shows \(character)") }
            XCTAssertFalse(text.contains("."+"field"), text)
            for word in banned { XCTAssertFalse(text.lowercased().contains(word), "“\(text)” says \(word)") }
        }
    }

    func testPlainProblemsFromTheEngineNeverLeakSyntax() {
        for message in ["{message} needs a fixed word right after it, so Dictator knows where it ends.",
                        "{message} needs a word after it to show where it ends. Put a fixed word before the ] or move the optional part to the end.",
                        "The name {x} is used twice. Each slot needs its own name."] {
            let plain = SentenceBuilder.plain(PatternError(message: message))
            XCTAssertFalse(plain.contains("{") || plain.contains("["), plain)
        }
        XCTAssertEqual(VoiceListEditor.plain("Field names in “People” can only use letters, digits and _."),
                       "Detail names in “People” can only use letters, digits and _.")
    }

    func testTheTerminalChoiceIsOnlyInTheCodingAssistantAndItsCard() throws {
        // The simple list shows no terminal picker: only the card's own sheet and the action have one.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Dictator/Views")
        for file in ["VoiceLaunchView.swift", "VoicePeopleSection.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("voiceCommandTerminalApp"), file)
        }
        let cards = try String(contentsOf: root.appendingPathComponent("VoiceCardsSection.swift"), encoding: .utf8)
        let sheet = try XCTUnwrap(cards.range(of: "struct VoiceCardQuestionSheet"))
        let rows = try XCTUnwrap(cards.range(of: "struct VoiceProjectsRows"))
        XCTAssertFalse(cards[rows.lowerBound...].contains("voiceCommandTerminalApp"))
        XCTAssertTrue(cards[sheet.lowerBound..<rows.lowerBound].contains("voiceCommandTerminalApp"))
    }
}


extension VoiceBuildYourOwnTests {
    func testEditorRejectsEquivalentPatternsAndAllowsEditingItself() {
        let existing = VoiceCommand(name: "One", pattern: "Open {app}", steps: [VoiceStep(kind: .openApp, text: "{app}")])
        let config = VoiceLaunchConfig(commands: [existing])
        let duplicate = VoiceCommand(name: "Two", pattern: "OPEN! {name}", steps: [VoiceStep(kind: .openApp, text: "{name}")])
        XCTAssertEqual(VoiceBuildProblems.problem(for: duplicate, config: config), VoiceBuildCopy.sameSentence)
        XCTAssertEqual(VoiceBuildProblems.problem(for: config, editing: duplicate), VoiceBuildCopy.sameSentence)
        XCTAssertNil(VoiceBuildProblems.problem(for: config, editing: existing))
        for kind in [VoiceStep.Kind.openApp, .runWorkspace] {
            var voiceCommand = VoiceCommand(name: "Named", pattern: "Go {name}", steps: [VoiceStep(kind: kind, text: "{name}")])
            XCTAssertNil(VoiceBuildProblems.problem(for: voiceCommand, config: VoiceLaunchConfig()))
            voiceCommand.steps[0].text = ""
            XCTAssertNotNil(VoiceBuildProblems.problem(for: voiceCommand, config: VoiceLaunchConfig()))
            XCTAssertTrue(VoiceBuildCopy.addable().contains(kind))
        }
    }
}
