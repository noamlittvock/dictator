import XCTest
@testable import Dictator

final class VoiceLaunchToleranceTests: XCTestCase {
    // MARK: Fixtures

    private let people = VoiceList(id: "people", name: "People", fields: ["phone", "email"], entries: [
        VoiceListEntry(id: "d", names: ["Dana", "Danny"], values: ["phone": "+972 50 123", "email": "dana@example.com"]),
        VoiceListEntry(id: "dl", names: ["Dana Levi"], values: ["phone": "+1 555", "email": "dl@example.com"]),
        VoiceListEntry(id: "y", names: ["יוסי"], values: ["phone": "+972 52 999"]),
    ])
    private let apps = VoiceList(id: "apps", name: "Apps", fields: ["url"], entries: [
        VoiceListEntry(id: "w1", names: ["whatsapp"], values: ["url": "whatsapp://"]),
        VoiceListEntry(id: "w2", names: ["whats app"], values: ["url": "whatsapp://"]),
    ])
    private let projects = VoiceList(id: "projects", name: "Projects", fields: ["folder"], entries: [
        VoiceListEntry(id: "p", names: ["Dictator"], values: ["folder": "/tmp/it's here"]),
    ])

    private func config(_ commands: [VoiceCommand]) -> VoiceLaunchConfig {
        VoiceLaunchConfig(lists: [people, apps, projects], commands: commands)
    }

    private func link(_ name: String, _ pattern: String, _ url: String, cleanUp: String? = nil, aliases: [String] = [], enabled: Bool = true) -> VoiceCommand {
        VoiceCommand(id: name, name: name, pattern: pattern, cleanUpSlot: cleanUp,
                            steps: [VoiceStep(kind: .openLink, link: url)], enabled: enabled, triggerAliases: aliases)
    }

    private func matched(_ transcript: String, _ commands: [VoiceCommand]) -> VoiceLaunchMatch? {
        if case .matched(let m) = VoiceLaunchEngine.match(transcript, in: config(commands)) { return m }
        return nil
    }

    private func matchOutcome(_ transcript: String, _ commands: [VoiceCommand]) -> MatchOutcome {
        VoiceLaunchEngine.match(transcript, in: config(commands))
    }

    private func text(_ m: VoiceLaunchMatch?, _ slot: String) -> String? {
        if case .text(let t)? = m?.slots[slot] { return t }
        return nil
    }

    private func entry(_ m: VoiceLaunchMatch?, _ slot: String) -> VoiceListEntry? {
        if case .entry(_, let e)? = m?.slots[slot] { return e }
        return nil
    }

    // MARK: 1. English Fillers

    func testLeadingFillersEnglish() {
        let yt = link("yt", "YouTube {query}", "https://x.test/{query}")
        let fillers = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "ah", "oh", "okay", "ok", "so", "well"]
        for filler in fillers {
            let transcript = "\(filler) YouTube cute cats"
            let m = matched(transcript, [yt])
            XCTAssertNotNil(m, "Expected match with filler '\(filler)'")
            XCTAssertEqual(text(m, "query"), "cute cats")
            XCTAssertEqual(m?.specificity, 1)
            XCTAssertEqual(m?.said, transcript)
        }
    }

    // MARK: 2. Hebrew Fillers

    func testLeadingFillersHebrew() {
        let yt = link("yt", "YouTube {query}", "https://x.test/{query}")
        let fillers = ["אה", "אהה", "אמ", "אממ", "נו", "טוב"]
        for filler in fillers {
            let transcript = "\(filler) YouTube cute cats"
            let m = matched(transcript, [yt])
            XCTAssertNotNil(m, "Expected match with Hebrew filler '\(filler)'")
            XCTAssertEqual(text(m, "query"), "cute cats")
            XCTAssertEqual(m?.specificity, 1)
            XCTAssertEqual(m?.said, transcript)
        }
    }

    // MARK: 3. Multiple Fillers

    func testMultipleFillers() {
        let yt = link("yt", "YouTube {query}", "https://x.test/{query}")
        let m1 = matched("um uh so well YouTube cute cats", [yt])
        XCTAssertEqual(text(m1, "query"), "cute cats")
        XCTAssertEqual(m1?.specificity, 1)

        let m2 = matched("אה נו טוב YouTube cute cats", [yt])
        XCTAssertEqual(text(m2, "query"), "cute cats")
        XCTAssertEqual(m2?.specificity, 1)

        let m3 = matched("um אה ok טוב YouTube cute cats", [yt])
        XCTAssertEqual(text(m3, "query"), "cute cats")
        XCTAssertEqual(m3?.specificity, 1)
    }

    // MARK: 4. Trigger Starting with a Filler

    func testTriggerStartingWithFiller() {
        let og = link("og", "okay Google {query}", "https://x.test/{query}")
        // Matches at offset 0
        let m0 = matched("okay Google cats", [og])
        XCTAssertEqual(text(m0, "query"), "cats")
        XCTAssertEqual(m0?.specificity, 2)

        // Matches at offset 1 when preceded by another filler
        let m1 = matched("um okay Google cats", [og])
        XCTAssertEqual(text(m1, "query"), "cats")
        XCTAssertEqual(m1?.specificity, 2)
        XCTAssertEqual(m1?.said, "um okay Google cats")

        // Matches when preceded by the same filler word
        let m2 = matched("okay okay Google cats", [og])
        XCTAssertEqual(text(m2, "query"), "cats")
        XCTAssertEqual(m2?.specificity, 2)

        let m3 = matched("so okay Google cats", [og])
        XCTAssertEqual(text(m3, "query"), "cats")
        XCTAssertEqual(m3?.specificity, 2)
    }

    // MARK: 5. Filler-Only Transcripts

    func testFillerOnlyTranscriptYieldsNoMatch() {
        let yt = link("yt", "YouTube {query}", "https://x.test/{query}")
        let samples = ["um", "um uh", "טוב נו אה", "okay so well", "ah hmm er"]
        for sample in samples {
            let outcome = matchOutcome(sample, [yt])
            XCTAssertEqual(outcome, .noMatch(.noneMatched), "Sample '\(sample)' should yield .noMatch(.noneMatched)")
        }
    }

    // MARK: 6. Fillers Never Appear in Slot Text

    func testFillersNeverAppearInSlotText() {
        let yt = link("yt", "YouTube {query}", "https://x.test/{query}")
        let m = matched("um so YouTube cats", [yt])
        XCTAssertEqual(text(m, "query"), "cats")
        XCTAssertEqual(m?.said, "um so YouTube cats")

        // Non-leading fillers inside slot text remain part of the slot value
        let m2 = matched("YouTube cats um so", [yt])
        XCTAssertEqual(text(m2, "query"), "cats um so")
    }

    // MARK: 7. Joined Trigger

    func testJoinedTrigger() {
        // Expected single word, spoken split
        let cg = link("cg", "chatgpt {query}", "https://x.test/{query}")
        let m1 = matched("chat gpt cats", [cg])
        XCTAssertEqual(text(m1, "query"), "cats")
        XCTAssertEqual(m1?.specificity, 1)

        // Expected single word trigger, spoken split into two
        let wa = link("wa", "whatsapp {person:People} {message}", "https://x.test/")
        let m2 = matched("whats app Dana running late", [wa])
        XCTAssertEqual(entry(m2, "person")?.id, "d")
        XCTAssertEqual(text(m2, "message"), "running late")
        XCTAssertEqual(m2?.specificity, 2) // 1 trigger word + 1 person
    }

    // MARK: 8. Split Trigger

    func testSplitTrigger() {
        // Expected multiple words, spoken joined
        let cg = link("cg", "chat gpt {query}", "https://x.test/{query}")
        let m1 = matched("chatgpt cats", [cg])
        XCTAssertEqual(text(m1, "query"), "cats")
        XCTAssertEqual(m1?.specificity, 2)

        let yt = link("yt", "you tube {query}", "https://x.test/{query}")
        let m2 = matched("youtube cats", [yt])
        XCTAssertEqual(text(m2, "query"), "cats")
        XCTAssertEqual(m2?.specificity, 2)
    }

    // MARK: 9. Joined / Split List Entry

    func testJoinedAndSplitListEntry() {
        let open = link("open", "Open {app:Apps}", "https://x.test/{app}")

        // Both spellings saved: the one heard exactly wins.
        XCTAssertEqual(entry(matched("open whats app", [open]), "app")?.id, "w2")
        XCTAssertEqual(entry(matched("open whatsapp", [open]), "app")?.id, "w1")

        // Only the joined name saved, heard split: it still matches and scores as one word.
        let joinedOnly = VoiceList(id: "apps", name: "Apps", fields: ["url"], entries: [
            VoiceListEntry(id: "w1", names: ["whatsapp"], values: ["url": "whatsapp://"])])
        let m1 = VoiceLaunchEngine.match("open whats app", in: VoiceLaunchConfig(lists: [joinedOnly], commands: [open]))
        guard case .matched(let split) = m1 else { return XCTFail("split name should match") }
        XCTAssertEqual(split.specificity, 1 + 1)

        // Only the split name saved, heard joined: it scores as two words.
        let splitOnly = VoiceList(id: "apps", name: "Apps", fields: ["url"], entries: [
            VoiceListEntry(id: "w2", names: ["whats app"], values: ["url": "whatsapp://"])])
        let m2 = VoiceLaunchEngine.match("open whatsapp", in: VoiceLaunchConfig(lists: [splitOnly], commands: [open]))
        guard case .matched(let joined) = m2 else { return XCTFail("joined name should match") }
        XCTAssertEqual(joined.specificity, 1 + 2)
    }

    // MARK: 10. Joined Literal in Middle of Pattern

    func testJoinedLiteralInMiddleOfPattern() {
        // Marker has 2 expected words ["you", "tube"]; spoken joined as "youtube"
        let s1 = link("s1", "Search {query} on you tube", "https://x.test/")
        let m1 = matched("search cute cats on youtube", [s1])
        XCTAssertEqual(text(m1, "query"), "cute cats")
        XCTAssertEqual(m1?.specificity, 1 + 1 + 2) // search (1) + on (1) + you tube (2)

        // Marker has 1 expected word ["youtube"]; spoken split as "you tube"
        let s2 = link("s2", "Search {query} on youtube", "https://x.test/")
        let m2 = matched("search cute cats on you tube", [s2])
        XCTAssertEqual(text(m2, "query"), "cute cats")
        XCTAssertEqual(m2?.specificity, 1 + 1 + 1) // search (1) + on (1) + youtube (1)
    }

    // MARK: 11. Joined Match Specificity Equals Canonical Word Count

    func testJoinedMatchSpecificityEqualsCanonicalWordCount() {
        let split = link("split", "chat gpt {query}", "https://x.test/")
        let joined = link("joined", "chatgpt {query}", "https://x.test/")

        // Spoken "chatgpt cats": split trigger matches with canonical count 2
        let m1 = matched("chatgpt cats", [split])
        XCTAssertEqual(m1?.specificity, 2)

        // Spoken "chat gpt cats": joined trigger matches with canonical count 1
        let m2 = matched("chat gpt cats", [joined])
        XCTAssertEqual(m2?.specificity, 1)
    }

    // MARK: 12. Tie Behaviour Preserved Between Shortcuts

    func testTieBehaviourPreservedBetweenTwoVoiceCommands() {
        let a = link("a", "Search {query}", "https://x.test/a")
        let b = link("b", "Find {query}", "https://x.test/b", aliases: ["Search"])

        // Direct tie
        let outcome1 = matchOutcome("search cats", [a, b])
        XCTAssertEqual(outcome1, .noMatch(.tie(["a", "b"])))

        // Tie with leading filler
        let outcome2 = matchOutcome("um search cats", [a, b])
        XCTAssertEqual(outcome2, .noMatch(.tie(["a", "b"])))

        // Tie with joined trigger
        let c = link("c", "chat gpt {query}", "https://x.test/c")
        let d = link("d", "ai tool {query}", "https://x.test/d", aliases: ["chat gpt"])
        let outcome3 = matchOutcome("chatgpt cats", [c, d])
        XCTAssertEqual(outcome3, .noMatch(.tie(["c", "d"])))
    }

    func testVoiceCommandWithoutSkippedFillerBeatsOneThatSkipsIt() {
        let so = link("so", "so {text}", "https://x.test/so")
        let email = link("email", "email {body}", "https://x.test/email")
        let m = matched("so email Dana", [so, email])
        XCTAssertEqual(m?.voiceCommand.name, "so")
        XCTAssertEqual(m?.skippedFillers, 0)
        XCTAssertEqual(text(m, "text"), "email Dana")
        XCTAssertEqual(matched("um email Dana", [so, email])?.skippedFillers, 1)
    }

    // MARK: Matching precedence and segmentation

    private func hebrewConfig(_ names: [String], _ commands: [VoiceCommand]) -> VoiceLaunchConfig {
        let list = VoiceList(id: "p", name: "People", fields: [], entries: names.map { VoiceListEntry(id: $0, names: [$0], values: [:]) })
        return VoiceLaunchConfig(lists: [list], commands: commands)
    }

    func testExactHebrewNameBeatsAPrefixedShorterNameInEitherOrder() {
        let send = link("send", "שלח {person:People} {message}", "https://x.test/{message}")
        for names in [["רון", "שרון"], ["שרון", "רון"]] {
            guard case .matched(let m) = VoiceLaunchEngine.match("שלח שרון שלום", in: hebrewConfig(names, [send])) else { return XCTFail() }
            guard case .entry(_, let entry)? = m.slots["person"] else { return XCTFail() }
            XCTAssertEqual(entry.id, "שרון", "\(names)")
        }
    }

    func testPrefixAndJoinedNameCombine() {
        let send = link("send", "שלח {person:People} {message}", "https://x.test/{message}")
        guard case .matched(let m) = VoiceLaunchEngine.match("שלח ליוסיכהן שלום", in: hebrewConfig(["יוסי כהן"], [send])) else { return XCTFail() }
        guard case .entry(_, let entry)? = m.slots["person"] else { return XCTFail() }
        XCTAssertEqual(entry.id, "יוסי כהן")
        XCTAssertEqual(m.specificity, 1 + 2)
    }

    func testSpecificityBeatsFewerSkippedFillers() {
        let so = link("so", "so [well] {text}", "https://x.test/so")
        let m = matched("so so well hello", [so])
        XCTAssertEqual(m?.specificity, 2)
        XCTAssertEqual(text(m, "text"), "hello")
        XCTAssertEqual(m?.skippedFillers, 1)
    }

    func testJoinedNameMayBeSplitIntoManyWords() {
        let gpt = link("gpt", "ChatGPT {query}", "https://x.test/{query}")
        let m = matched("chat g p t cats", [gpt])
        XCTAssertEqual(text(m, "query"), "cats")
        XCTAssertEqual(m?.specificity, 1)
    }

    func testExactTriggerAliasBeatsAJoinedPrimaryTrigger() {
        let notebook = link("nb", "Notebook {text}", "https://x.test/nb", aliases: ["note"])
        XCTAssertEqual(text(matched("note book a table for Friday", [notebook]), "text"), "book a table for Friday")
    }

    func testPrefixSegmentationIsDeterministicAndKeepsTheMostWords() {
        let send = link("send", "שלח {person:People} {message}", "https://x.test/{message}")
        for _ in 0..<5 {
            guard case .matched(let m) = VoiceLaunchEngine.match("שלח ושש ש ש ש שלום", in: hebrewConfig(["שש שש"], [send])) else { return XCTFail() }
            guard case .text(let message)? = m.slots["message"] else { return XCTFail() }
            XCTAssertEqual(message, "ש שלום")
        }
    }

    // MARK: 13. Hebrew Prefix on List Entry

    func testHebrewPrefixMatchingListEntry() {
        let send = link("send", "שלח {person:People} {message}", "https://x.test/")
        let prefixes = ["ו", "ה", "ב", "ל", "מ", "ש", "כ", "וה", "וב", "ול", "ומ", "וש", "שה", "שב", "של", "מה", "לה", "בה", "כש"]

        for prefix in prefixes {
            let spoken = "שלח \(prefix)יוסי שלום"
            let m = matched(spoken, [send])
            XCTAssertNotNil(m, "Prefix '\(prefix)' should match entry 'יוסי'")
            XCTAssertEqual(entry(m, "person")?.id, "y")
            XCTAssertEqual(text(m, "message"), "שלום")
            XCTAssertEqual(m?.specificity, 2) // "שלח" (1) + "יוסי" (1)
        }
    }

    // MARK: 14. Hebrew Prefix Not Applied to English Alias

    func testHebrewPrefixNotAppliedToEnglishAlias() {
        let email = link("email", "Email {person:People} {body}", "https://x.test/")
        // Danny is English script; Hebrew prefixes should not attach
        XCTAssertNil(matched("email לדני hello", [email]))
        XCTAssertNil(matched("email לDanny hello", [email]))
        XCTAssertNil(matched("email לdanny hello", [email]))
    }

    // MARK: 15. Hebrew Prefix Not Applied to Trigger or Literal Words

    func testHebrewPrefixNotAppliedToTriggerOrLiteralWords() {
        let trigger = link("trig", "יוסי {query}", "https://x.test/")
        // Prefix should not apply to trigger literal
        XCTAssertNil(matched("ליוסי cats", [trigger]))

        let lit = link("lit", "Search {query} יוסי", "https://x.test/")
        // Prefix should not apply to pattern literal marker
        XCTAssertNil(matched("search cats ליוסי", [lit]))
    }

    // MARK: 16. Existing Exact Behaviour Unchanged

    func testExistingExactBehaviourUnchanged() {
        let yt = link("yt", "YouTube {query}", "https://x.test/{query}")
        let wa = link("wa", "WhatsApp {person:People} {message}", "https://x.test/")
        let email = link("email", "Email {person:People} {body}", "https://x.test/")

        let m1 = matched("YouTube cute cats", [yt])
        XCTAssertEqual(text(m1, "query"), "cute cats")
        XCTAssertEqual(m1?.specificity, 1)

        let m2 = matched("WhatsApp Dana running late", [wa])
        XCTAssertEqual(entry(m2, "person")?.id, "d")
        XCTAssertEqual(text(m2, "message"), "running late")
        XCTAssertEqual(m2?.specificity, 2)

        let m3 = matched("Email Dana Levi lunch tomorrow", [email])
        XCTAssertEqual(entry(m3, "person")?.id, "dl")
        XCTAssertEqual(text(m3, "body"), "lunch tomorrow")
        XCTAssertEqual(m3?.specificity, 3) // email (1) + Dana Levi (2)
    }
}
