import XCTest
@testable import Dictator

final class VoiceLaunchTests: XCTestCase {
    // MARK: Fixtures

    private let people = VoiceList(id: "people", name: "People", fields: ["phone", "email"], entries: [
        VoiceListEntry(id: "d", names: ["Dana", "Danny"], values: ["phone": "+972 50 123", "email": "dana@example.com"]),
        VoiceListEntry(id: "dl", names: ["Dana Levi"], values: ["phone": "+1 555", "email": "dl@example.com"]),
        VoiceListEntry(id: "y", names: ["יוסי"], values: ["phone": "+972 52 999"]),
    ])
    private let projects = VoiceList(id: "projects", name: "Projects", fields: ["folder"], entries: [
        VoiceListEntry(id: "p", names: ["Dictator"], values: ["folder": "/tmp/it's here"]),
    ])

    private func config(_ commands: [VoiceCommand]) -> VoiceLaunchConfig {
        VoiceLaunchConfig(lists: [people, projects], commands: commands)
    }

    private func link(_ name: String, _ pattern: String, _ url: String, cleanUp: String? = nil, enabled: Bool = true) -> VoiceCommand {
        VoiceCommand(id: name, name: name, pattern: pattern, cleanUpSlot: cleanUp,
                            steps: [VoiceStep(kind: .openLink, link: url)], enabled: enabled)
    }

    private func matched(_ transcript: String, _ commands: [VoiceCommand]) -> VoiceLaunchMatch? {
        if case .matched(let m) = VoiceLaunchEngine.match(transcript, in: config(commands)) { return m }
        return nil
    }

    private func text(_ m: VoiceLaunchMatch?, _ slot: String) -> String? {
        if case .text(let t)? = m?.slots[slot] { return t }
        return nil
    }

    private func parts(_ pattern: String) throws -> [PatternPart] {
        switch VoicePattern.parse(pattern) {
        case .success(let parsed): return parsed.parts
        case .failure(let error): throw error
        }
    }

    private func reason(_ pattern: String) -> String? {
        if case .failure(let error) = VoicePattern.parse(pattern) { return error.message }
        return nil
    }

    // MARK: Pattern parser

    func testParsesAllSyntax() throws {
        XCTAssertEqual(try parts("YouTube {query}"), [.literal(["YouTube"]), .textSlot(name: "query")])
        XCTAssertEqual(try parts("Claude Code now {prompt}"), [.literal(["Claude", "Code", "now"]), .textSlot(name: "prompt")])
        XCTAssertEqual(try parts("WhatsApp {person:People} {message}"),
                       [.literal(["WhatsApp"]), .listSlot(name: "person", list: "People"), .textSlot(name: "message")])
        XCTAssertEqual(try parts("Email {person:People} [subject {subject} body] {body}"), [
            .literal(["Email"]), .listSlot(name: "person", list: "People"),
            .optional([.literal(["subject"]), .textSlot(name: "subject"), .literal(["body"])]),
            .textSlot(name: "body"),
        ])
        XCTAssertEqual(try parts("  open   notes  "), [.literal(["open", "notes"])])
        XCTAssertEqual(try parts("Email{body}"), [.literal(["Email"]), .textSlot(name: "body")])
    }

    func testInvalidPatternsExplainWhy() {
        XCTAssertTrue(reason("{query} search")!.contains("start with a word"))
        XCTAssertTrue(reason("[maybe] hello {x}")!.contains("start with a word"))
        XCTAssertTrue(reason("")!.contains("start with a word"))
        XCTAssertTrue(reason("Go {a} {b}")!.contains("{a} needs a fixed word"))
        XCTAssertTrue(reason("Go {a:People} {b} {c}")!.contains("{b} needs a fixed word"))
        XCTAssertTrue(reason("Go {a} then {a}")!.contains("used twice"))
        XCTAssertTrue(reason("Go [a [b]] {x}")!.contains("inside each other"))
        XCTAssertTrue(reason("Go [a {x}")!.contains("missing its ]"))
        XCTAssertTrue(reason("Go a] {x}")!.contains("without a ["))
        XCTAssertTrue(reason("Go {x")!.contains("missing its }"))
        XCTAssertTrue(reason("Go x} y")!.contains("without a {"))
        XCTAssertTrue(reason("Go [] {x}")!.contains("can’t be empty"))
        XCTAssertTrue(reason("Go {}")!.contains("slot name"))
        XCTAssertTrue(reason("Go {a b}")!.contains("slot name"))
        XCTAssertTrue(reason("Go {a:} x")!.contains("name of a list"))
        XCTAssertTrue(reason("Go ??? {x}")!.contains("no letters"))
        // A text slot that ends an optional group must be at the end of the pattern.
        XCTAssertNotNil(reason("Go [with {x}] then {y}"))
        XCTAssertNil(reason("Go x [with {x}]"))
    }

    func testListSlotsMustReferenceExistingLists() {
        let voiceCommand = link("W", "WhatsApp {person:Nobody} {message}", "https://x.test/{message}")
        XCTAssertTrue(config([voiceCommand]).validate()!.contains("“Nobody”"))
        XCTAssertNil(config([link("W", "WhatsApp {person:people} {message}", "https://x.test/{message}")]).validate())
    }

    // MARK: Matcher

    func testLiteralAndFinalSlot() {
        let m = matched("YouTube cute cats", [link("yt", "YouTube {query}", "https://x.test/{query}")])
        XCTAssertEqual(text(m, "query"), "cute cats")
        XCTAssertEqual(m?.specificity, 1)
    }

    func testCaseAndPunctuationAreIgnoredButValuesKeepTheirs() {
        let m = matched("YOU-tube, Cute Cats, please.", [link("yt", "you tube {query}", "https://x.test/{query}")])
        // "YOU-tube" is one word, but split and joined spellings of the same
        // letters match (V1 robustness): it is heard as "you tube".
        XCTAssertEqual(text(m, "query"), "Cute Cats, please.")
        let m2 = matched("Claude, Code. Fix the Login bug!", [link("c", "claude code {prompt}", "https://x.test/{prompt}")])
        XCTAssertEqual(text(m2, "prompt"), "Fix the Login bug!")
        XCTAssertEqual(text(matched("  YOUTUBE:   funny   dogs ", [link("yt", "youtube {q}", "https://x.test/{q}")]), "q"), "funny   dogs")
    }

    func testEmptyFinalSlotIsAllowed() {
        let m = matched("YouTube.", [link("yt", "YouTube {query}", "https://x.test/{query}")])
        XCTAssertEqual(text(m, "query"), "")
    }

    func testNoMatchReasons() {
        let yt = link("yt", "YouTube {query}", "https://x.test/{query}")
        XCTAssertEqual(VoiceLaunchEngine.match("", in: config([yt])), .noMatch(.nothingSaid))
        XCTAssertEqual(VoiceLaunchEngine.match("hello", in: VoiceLaunchConfig()), .noMatch(.noCommands))
        XCTAssertEqual(VoiceLaunchEngine.match("please open youtube", in: config([yt])), .noMatch(.noneMatched))
        XCTAssertEqual(VoiceLaunchEngine.match("youtubers rule", in: config([yt])), .noMatch(.noneMatched))
        XCTAssertEqual(VoiceLaunchEngine.match("youtube cats", in: config([link("yt", "YouTube {query}", "https://x.test/", enabled: false)])), .noMatch(.noCommands))
    }

    func testListSlotTakesTheLongestAlias() {
        let wa = link("wa", "WhatsApp {person:People} {message}", "whatsapp://send?phone={person.phone}&text={message}")
        let m = matched("whatsapp dana levi running late", [wa])
        guard case .entry(_, let entry)? = m?.slots["person"] else { return XCTFail("no person") }
        XCTAssertEqual(entry.id, "dl")
        XCTAssertEqual(text(m, "message"), "running late")
        guard case .entry(_, let short)? = matched("whatsapp Danny running late", [wa])?.slots["person"] else { return XCTFail() }
        XCTAssertEqual(short.id, "d", "alias matches")
        XCTAssertNil(matched("whatsapp nobody running late", [wa]))
    }

    func testMarkerEndedTextSlotStopsAtTheFirstMarker() {
        let s = link("code", "Note {title} colon {body}", "https://x.test/{title}/{body}")
        let m = matched("note buy milk colon two liters, colon and eggs", [s])
        XCTAssertEqual(text(m, "title"), "buy milk")
        XCTAssertEqual(text(m, "body"), "two liters, colon and eggs")
        XCTAssertNil(matched("note colon body", [s]), "the slot needs at least one word")
        XCTAssertNil(matched("note buy milk", [s]), "marker missing")
    }

    func testMarkerSlotDropsTheRecognizersComma() {
        let s = link("n", "Note {title} then {body}", "https://x.test/")
        XCTAssertEqual(text(matched("note buy milk, then eggs", [s]), "title"), "buy milk")
    }

    func testOptionalGroupPresentAndAbsent() {
        let email = link("email", "Email {person:People} [subject {subject} body] {body}", "https://x.test/")
        let with = matched("email dana subject lunch tomorrow body are you free", [email])
        XCTAssertEqual(text(with, "subject"), "lunch tomorrow")
        XCTAssertEqual(text(with, "body"), "are you free")
        XCTAssertEqual(with?.specificity, 1 + 1 + 1 + 1) // email, dana, subject, body
        let without = matched("email dana are you free", [email])
        XCTAssertNil(without?.slots["subject"])
        XCTAssertEqual(text(without, "body"), "are you free")
    }

    func testSpecificityPicksTheMostWordsFromLiteralsAndLists() {
        let a = link("a", "Email {person:People} {body}", "https://x.test/a")
        let b = link("b", "Email {body}", "https://x.test/b")
        XCTAssertEqual(matched("email dana hello", [b, a])?.voiceCommand.id, "a")
        XCTAssertEqual(matched("email hello there", [a, b])?.voiceCommand.id, "b")
        let code = link("c", "Claude Code {prompt}", "https://x.test/c")
        let claude = link("d", "Claude {prompt}", "https://x.test/d")
        XCTAssertEqual(matched("claude code fix it", [claude, code])?.voiceCommand.id, "c")
        XCTAssertEqual(matched("claude write a poem", [claude, code])?.voiceCommand.id, "d")
    }

    func testATieBetweenDifferentVoiceCommandsMatchesNothing() {
        let a = link("a", "Search {q}", "https://x.test/a")
        let b = link("b", "search {text}", "https://x.test/b")
        XCTAssertEqual(VoiceLaunchEngine.match("search cats", in: config([a, b])), .noMatch(.tie(["a", "b"])))
    }

    func testHebrew() {
        let s = link("yt", "יוטיוב {query}", "https://x.test/?q={query}")
        XCTAssertEqual(text(matched("יוטיוב, חתולים חמודים", [s]), "query"), "חתולים חמודים")
        let wa = link("wa", "וואטסאפ {person:People} {message}", "whatsapp://send?phone={person.phone}&text={message}")
        let m = matched("וואטסאפ יוסי אני מאחר", [wa])
        guard case .entry(_, let entry)? = m?.slots["person"] else { return XCTFail() }
        XCTAssertEqual(entry.id, "y")
        XCTAssertEqual(text(m, "message"), "אני מאחר")
    }

    func testHintWordsCoverLiteralsAndListNames() {
        let wa = link("wa", "WhatsApp {person:People} {message}", "https://x.test/")
        let off = link("off", "Hidden {x}", "https://x.test/", enabled: false)
        let hints = VoiceLaunchEngine.hintWords(config([wa, off]))
        XCTAssertTrue(hints.contains("WhatsApp"))
        XCTAssertTrue(hints.contains("Dana") && hints.contains("Danny") && hints.contains("Dana Levi") && hints.contains("יוסי"))
        XCTAssertFalse(hints.contains("Hidden"))
        XCTAssertFalse(hints.contains("Dictator"), "unused lists add nothing")
    }

    // MARK: Rendering

    private func rendered(_ transcript: String, _ voiceCommand: VoiceCommand) -> VoiceLaunchPlan? {
        if case .plan(let plan) = VoiceLaunchEngine.plan(for: transcript, in: config([voiceCommand])) { return plan }
        return nil
    }

    func testLinkEncoding() {
        XCTAssertEqual(VoiceLaunchLink.encodeQueryComponent("a b&c#d"), "a%20b%26c%23d")
        XCTAssertEqual(VoiceLaunchLink.encodeQueryComponent("x=1+2/3?"), "x%3D1%2B2%2F3%3F")
        XCTAssertEqual(VoiceLaunchLink.encodeQueryComponent("safe-._~AZaz09"), "safe-._~AZaz09")
        XCTAssertEqual(VoiceLaunchLink.encodeQueryComponent("שלום"), "%D7%A9%D7%9C%D7%95%D7%9D")
        XCTAssertEqual(VoiceLaunchLink.encodeQueryComponent("café 🙂"), "caf%C3%A9%20%F0%9F%99%82")
    }

    func testOpenLinkEncodesEveryValueForAQuery() {
        let plan = rendered("google a&b=c #x", link("g", "Google {q}", "https://www.google.com/search?q={q}"))
        XCTAssertEqual(plan?.steps.first?.link, "https://www.google.com/search?q=a%26b%3Dc%20%23x")
        let hebrew = rendered("google שלום עולם", link("g", "Google {q}", "https://x.test/?q={q}"))
        let url = URL(string: hebrew!.steps[0].link!)!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "שלום עולם")
    }

    func testListFieldsAndDisplayNameInTemplates() {
        let wa = link("wa", "WhatsApp {person:People} {message}", "whatsapp://send?phone={person.phone}&text={message}&who={person}")
        let plan = rendered("whatsapp dana running late.", wa)
        XCTAssertEqual(plan?.steps[0].link, "whatsapp://send?phone=%2B972%2050%20123&text=running%20late&who=Dana")
        XCTAssertEqual(plan?.slots.map(\.name), ["person", "message"])
        XCTAssertEqual(plan?.slots.first?.fields?["email"], "dana@example.com")
    }

    func testTrailingPunctuationTrimmedInLinksUnlessCleanedUp() {
        let plain = rendered("youtube cute cats.", link("y", "YouTube {q}", "https://x.test/?q={q}"))
        XCTAssertEqual(plain?.steps[0].link, "https://x.test/?q=cute%20cats")
        let cleaned = rendered("youtube cute cats.", link("y", "YouTube {q}", "https://x.test/?q={q}", cleanUp: "q"))
        XCTAssertEqual(cleaned?.steps[0].link, "https://x.test/?q=cute%20cats%2E".replacingOccurrences(of: "%2E", with: "."))
    }

    func testMissingOptionalSlotRendersEmpty() {
        let email = link("e", "Email {person:People} [subject {s} body] {body}", "https://m.test/?to={person.email}&su={s}&body={body}")
        XCTAssertEqual(rendered("email dana hi there", email)?.steps[0].link, "https://m.test/?to=dana%40example.com&su=&body=hi%20there")
        XCTAssertEqual(rendered("email יוסי hi", email)?.steps[0].link, "https://m.test/?to=&su=&body=hi", "a missing field is empty")
    }

    func testRawStepsAndDefaults() {
        let s = VoiceCommand(id: "s", name: "S", pattern: "Note {text}", steps: [
            VoiceStep(kind: .openApp, bundleId: "com.apple.Notes"),
            VoiceStep(kind: .waitForTextField),
            VoiceStep(kind: .typeText, text: "a&b {text}!"),
            VoiceStep(kind: .runInTerminal, folder: "{text}", command: " ", argument: "{text}"),
            VoiceStep(kind: .confirm, text: "Sending: {text}"),
        ])
        let plan = rendered("note it's $(x) & more", s)!
        XCTAssertEqual(plan.steps[1].seconds, 8)
        XCTAssertEqual(plan.steps[2].text, "a&b it's $(x) & more!")
        XCTAssertEqual(plan.steps[3].folder, "it's $(x) & more")
        XCTAssertEqual(plan.steps[3].command, "claude")
        XCTAssertEqual(plan.steps[3].argument, "it's $(x) & more")
        XCTAssertEqual(plan.steps[4].seconds, 3)
        XCTAssertEqual(plan.mainText, "it's $(x) & more")
    }

    func testMainTextPrefersTheCleanUpSlot() {
        let s = VoiceCommand(name: "S", pattern: "Note {a} then {b}", cleanUpSlot: "a", steps: [VoiceStep(kind: .typeText, text: "{b}")])
        XCTAssertEqual(rendered("note one then two", s)?.mainText, "one")
    }

    func testWebhookBodyIsJSONWithListObjects() throws {
        let s = VoiceCommand(name: "S", pattern: "Ping {person:People} {msg}", steps: [
            VoiceStep(kind: .confirm, text: "Sure?"), VoiceStep(kind: .webhook, link: "https://hooks.test/x")])
        let body = rendered("ping dana say \"hi\"\nthere", s)!.steps[1].text!
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        XCTAssertEqual(json["msg"] as? String, "say \"hi\"\nthere")
        let person = json["person"] as! [String: String]
        XCTAssertEqual(person["name"], "Dana")
        XCTAssertEqual(person["phone"], "+972 50 123")
    }

    // MARK: Shell quoting

    func testSingleQuoteEscaping() {
        XCTAssertEqual(ShellQuote.single("hello"), "'hello'")
        XCTAssertEqual(ShellQuote.single("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.single("$(rm -rf ~)"), "'$(rm -rf ~)'")
        XCTAssertEqual(ShellQuote.single("`id`"), "'`id`'")
        XCTAssertEqual(ShellQuote.single("a\nb"), "'a\nb'")
        XCTAssertEqual(ShellQuote.single("''"), "''\\'''\\'''")
    }

    /// The generated script, run by a real shell against a synthetic argv
    /// printer, hands the text over as exactly one argument.
    func testScriptPassesTextAsOneArgument() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "it's $(touch pwned) `touch pwned2` \"q\" ; touch pwned3\nsecond line"
        let script = ShellQuote.terminalScript(folder: dir.path, command: "printf %s", argument: text)
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh -il\nrm -f -- \"$0\"\n"))
        let body = script.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
            .replacingOccurrences(of: "exec ", with: "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", body]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testScriptDefaultsToClaudeAndOmitsEmptyArgument() {
        let script = ShellQuote.terminalScript(folder: "/tmp/it's here", command: "  ", argument: "")
        XCTAssertTrue(script.contains("cd -- '/tmp/it'\\''s here' || exit 1"))
        XCTAssertTrue(script.hasSuffix("exec claude\n"))
    }

    // MARK: Validation

    private func step(_ kind: VoiceStep.Kind, _ edit: (inout VoiceStep) -> Void = { _ in }) -> VoiceStep {
        var s = VoiceStep(kind: kind)
        switch kind {
        case .openLink: s.link = "https://x.test/?q={q}"
        case .openApp: s.bundleId = "com.apple.Notes"
        case .typeText, .runWorkspace: s.text = "{q}"
        case .pressKey: s.key = "return"
        case .runInTerminal: s.folder = "/tmp"; s.command = "claude"; s.argument = "{q}"
        case .confirm: s.text = "Sending {q}"
        case .runAppleShortcut: s.shortcutName = "Do it"; s.text = "{q}"
        case .webhook: s.link = "https://hooks.test/x"
        case .appendToFile: s.path = "/tmp/log.txt"; s.text = "{q}"
        case .waitForTextField: break
        }
        edit(&s)
        return s
    }

    private func problem(_ steps: [VoiceStep], pattern: String = "Do {q}", cleanUp: String? = nil) -> String? {
        config([VoiceCommand(name: "Do", pattern: pattern, cleanUpSlot: cleanUp, steps: steps)]).validate()
    }

    func testActingStepsNeedAnEarlierConfirm() {
        for acting in [step(.pressKey), step(.pressKey) { $0.key = "cmdReturn" }, step(.runAppleShortcut), step(.webhook)] {
            XCTAssertTrue(problem([acting])!.contains("Wait for me to cancel"), "\(acting.kind)")
            XCTAssertTrue(problem([step(.confirm), acting]) == nil, "\(acting.kind)")
            XCTAssertNotNil(problem([acting, step(.confirm)]), "the confirm must come first")
        }
        XCTAssertNil(problem([step(.pressKey) { $0.key = "tab" }]), "tab isn't acting")
        XCTAssertNil(problem([step(.pressKey) { $0.key = "escape" }]))
    }

    func testUnknownReferencesAreRejected() {
        XCTAssertNil(problem([step(.openLink)]))
        XCTAssertTrue(problem([step(.openLink) { $0.link = "https://x.test/{nope}" }])!.contains("{nope}"))
        XCTAssertNotNil(problem([step(.typeText) { $0.text = "{q.phone}" }]), "text slots have no fields")
        XCTAssertNotNil(problem([step(.typeText) { $0.text = "{person.nope}" }], pattern: "Do {person:People} {q}"))
        XCTAssertNil(problem([step(.typeText) { $0.text = "{person.phone} {person} {q}" }], pattern: "Do {person:People} {q}"))
        XCTAssertNotNil(problem([step(.typeText) { $0.text = "{broken" }]))
        XCTAssertNotNil(problem([step(.typeText)], cleanUp: "person"), "clean-up names a text slot")
        XCTAssertNotNil(problem([step(.typeText)], cleanUp: "missing"))
        XCTAssertNil(problem([step(.typeText)], cleanUp: "q"))
    }

    func testLinkSchemesAndOtherStepRules() {
        for ok in ["http://a.test/{q}", "https://a.test/{q}", "mailto:?body={q}", "whatsapp://send?text={q}", "sms:123&body={q}", "HTTPS://a.test"] {
            XCTAssertNil(problem([step(.openLink) { $0.link = ok }]), ok)
        }
        for bad in ["javascript:alert({q})", "file:///etc/{q}", "{q}://x", "no scheme", "", "data:text/html,{q}"] {
            XCTAssertNotNil(problem([step(.openLink) { $0.link = bad }]), bad)
        }
        XCTAssertNotNil(problem([step(.openApp) { $0.bundleId = "" }]))
        XCTAssertNotNil(problem([step(.pressKey) { $0.key = "space" }]))
        XCTAssertNotNil(problem([step(.runInTerminal) { $0.folder = "relative" }]))
        XCTAssertNil(problem([step(.runInTerminal) { $0.folder = "{project.folder}" }], pattern: "Do {project:Projects} {q}"))
        XCTAssertNotNil(problem([step(.runInTerminal) { $0.command = "claude; rm -rf ~" }]))
        XCTAssertNil(problem([step(.runInTerminal) { $0.command = "claude --model opus" }]))
        XCTAssertNotNil(problem([step(.waitForTextField) { $0.seconds = 0 }]))
        XCTAssertNotNil(problem([step(.confirm), step(.webhook) { $0.link = "ftp://x" }]))
        XCTAssertNotNil(problem([step(.appendToFile) { $0.path = "log.txt" }]))
        XCTAssertNotNil(problem([step(.confirm), step(.runAppleShortcut) { $0.shortcutName = " " }]))
        XCTAssertNotNil(problem([]), "a shortcut needs steps")
    }

    func testCaps() {
        func commands(_ n: Int) -> [VoiceCommand] { (0..<n).map { link("s\($0)", "Word\($0) {q}", "https://x.test/{q}") } }
        XCTAssertNil(VoiceLaunchConfig(commands: commands(100)).validate())
        XCTAssertNotNil(VoiceLaunchConfig(commands: commands(101)).validate())
        let lists = (0..<21).map { VoiceList(name: "L\($0)") }
        XCTAssertNil(VoiceLaunchConfig(lists: Array(lists.prefix(20))).validate())
        XCTAssertNotNil(VoiceLaunchConfig(lists: lists).validate())
        let entries = (0..<501).map { VoiceListEntry(names: ["n\($0)"]) }
        XCTAssertNil(VoiceLaunchConfig(lists: [VoiceList(name: "A", entries: Array(entries.prefix(500)))]).validate())
        XCTAssertNotNil(VoiceLaunchConfig(lists: [VoiceList(name: "A", entries: entries)]).validate())
        let manySteps = Array(repeating: step(.typeText), count: 21)
        XCTAssertNotNil(problem(manySteps))
        XCTAssertNil(problem(Array(manySteps.prefix(20))))
    }

    func testListAndDuplicateRules() {
        XCTAssertNotNil(VoiceLaunchConfig(lists: [VoiceList(name: "A"), VoiceList(name: "a")]).validate())
        XCTAssertNotNil(VoiceLaunchConfig(lists: [VoiceList(name: "A", fields: ["x", "X"])]).validate())
        XCTAssertNotNil(VoiceLaunchConfig(lists: [VoiceList(name: "A", entries: [VoiceListEntry(names: ["  "])])]).validate())
        let a = link("a", "Search {q}", "https://x.test/{q}")
        var b = a; b.id = "b"; b.name = "b"
        XCTAssertNotNil(config([a, b]).validate(), "same pattern twice")
        XCTAssertNotNil(config([link("a", "Bad {x} {y}", "https://x.test/")]).validate(), "pattern rules apply on save")
    }

    func testCodableRoundTripAndVersionCheck() {
        let original = config([link("a", "Search {q}", "https://x.test/{q}")])
        XCTAssertEqual(VoiceLaunchConfig.decode(original.encoded()), original)
        XCTAssertEqual(VoiceLaunchConfig.decode(""), VoiceLaunchConfig())
        XCTAssertNil(VoiceLaunchConfig.decode("not json"))
        XCTAssertNil(VoiceLaunchConfig.decode(#"{"version":1,"lists":[],"shortcuts":[]}"#))
    }

    // MARK: Catalog

    func testCatalogTemplatesAreValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/shortcut-catalog.json")
        let catalog = try JSONDecoder().decode(VoiceCommandCatalog.self, from: Data(contentsOf: url))
        XCTAssertEqual(catalog.version, 5)
        XCTAssertEqual(catalog.allowedLinkSchemes, ["http", "https", "mailto", "whatsapp", "sms"])
        XCTAssertEqual(catalog.lists.map(\.name), ["People", "Projects", "Your Shortcuts"])
        XCTAssertEqual(catalog.templates.map(\.name), ["Email", "WhatsApp", "WhatsApp and send", "YouTube", "Google", "Marketplace", "ChatGPT", "Claude", "Claude Code", "Run a Shortcut", "Run a Shortcut (right away)", "Open an app", "Workspaces"])
        var config = VoiceLaunchConfig()
        for template in catalog.available { catalog.add(template, to: &config) }
        XCTAssertNil(config.validate(allowedSchemes: catalog.allowedLinkSchemes))
        XCTAssertEqual(config.lists.map(\.name), ["People", "Projects", "Your Shortcuts"])
        XCTAssertEqual(config.lists[0].fields, ["phone", "email"])
        XCTAssertEqual(config.commands.count, catalog.available.count)
        // Adding twice doesn't duplicate lists.
        catalog.add(catalog.templates[0], to: &config)
        XCTAssertEqual(config.lists.count, 3)
    }

    func testReadyMadeEmailWithAPerson() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/shortcut-catalog.json")
        let catalog = try JSONDecoder().decode(VoiceCommandCatalog.self, from: Data(contentsOf: url))
        var config = VoiceLaunchConfig()
        catalog.available.forEach { catalog.add($0, to: &config) }
        config.lists[0].entries = people.entries
        guard case .plan(let withPerson) = VoiceLaunchEngine.plan(for: "Email Dana subject Hi body See you soon.", in: config) else { return XCTFail() }
        XCTAssertEqual(withPerson.steps[0].link, "https://mail.google.com/mail/?view=cm&fs=1&to=dana%40example.com&su=Hi&body=See%20you%20soon.")
    }

    // MARK: Settings mirror

    func testSettingsDTOWithAndWithoutTheField() throws {
        let old = Data(#"{"refineLevel":"medium","customSystemPrompt":"","persistHistory":true,"voiceShortcutsJSON":"[]"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CoreSettingsDTO.self, from: old).voiceLaunchJSON)
        let patch = CoreSettingsPatch(voiceLaunchJSON: "{}")
        XCTAssertFalse(patch.isEmpty)
        let again = try JSONDecoder().decode(CoreSettingsPatch.self, from: JSONEncoder().encode(patch))
        XCTAssertEqual(again.voiceLaunchJSON, "{}")
        XCTAssertTrue(CoreSettingsPatch().isEmpty)
    }

    @MainActor func testRepoServerValidatesTheSetting() {
        let good = config([link("a", "Search {q}", "https://x.test/{q}")]).encoded()
        XCTAssertNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(voiceLaunchJSON: good))))
        XCTAssertNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(voiceLaunchJSON: VoiceLaunchConfig().encoded()))))
        XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(voiceLaunchJSON: "nope"))))
        XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(voiceLaunchJSON: #"[{"id":"1"}]"#))), "the old list is not accepted")
        let bad = config([link("a", "Search {q}", "javascript:alert({q})")]).encoded()
        XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(voiceLaunchJSON: bad))))
        let noConfirm = config([VoiceCommand(name: "x", pattern: "Go {q}", steps: [step(.webhook)])]).encoded()
        XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(voiceLaunchJSON: noConfirm))))
        let huge = String(repeating: "x", count: RepoRequestLimits.maxVoiceLaunchJSONLength + 1)
        XCTAssertNotNil(RepoServer.validate(.settingsSet(CoreSettingsPatch(voiceLaunchJSON: huge))))
    }

    // MARK: Protocol

    func testLaunchMessageRoundTripsAndOldMessagesStillDecode() throws {
        let data = try EdgeProtocolCodec.encode(EdgeMessage.voiceCommandMode(), id: "1")
        XCTAssertEqual(try EdgeProtocolCodec.decodeEdgeMessage(data), .voiceCommandMode())

        let plan = try XCTUnwrap(rendered("whatsapp dana hello", link("wa", "WhatsApp {person:People} {message}", "whatsapp://send?phone={person.phone}&text={message}")))
        let launch = CoreMessage.launchInsert(sessionId: "s1", plan: plan)
        let encoded = try EdgeProtocolCodec.encode(launch, id: "2")
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(encoded), launch)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"insert.launch\""))

        let insert = CoreMessage.voiceCommandInsert(sessionId: "s1", delivery: VoiceCommandDelivery(text: "cute cats", notice: nil))
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(EdgeProtocolCodec.encode(insert, id: "3")), insert)
        let bare = Data(#"{"v":2,"t":"insert.shortcut","id":"3","sessionId":"s1","delivery":{"text":"hi"}}"#.utf8)
        XCTAssertEqual(try EdgeProtocolCodec.decodeCoreMessage(bare), .voiceCommandInsert(sessionId: "s1", delivery: VoiceCommandDelivery(text: "hi")))

        try XCTAssertEqual(EdgeProtocolCodec.decodeEdgeMessage(EdgeProtocolCodec.encode(EdgeMessage.hotkeyDown, id: "4")), .hotkeyDown)
        let plain = CoreMessage.insert(sessionId: "s1", text: "hello")
        try XCTAssertEqual(EdgeProtocolCodec.decodeCoreMessage(EdgeProtocolCodec.encode(plain, id: "5")), plain)
        XCTAssertEqual(EdgeProtocol.version, 2, "an optional message doesn't bump the version")
    }

    // MARK: Broker

    private func brokerAtProcessing(voiceCommandMode: Bool) -> SessionBroker {
        var now: TimeInterval = 0
        _ = now
        let broker = SessionBroker(coreId: "core", clock: { now }, makeSessionID: { "s1" })
        let caps = EdgeCapabilities(hasMic: true, inputDeviceUID: "u", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
        _ = broker.apply(.edgeConnected(BrokerEdgeInfo(id: "mac", name: "mac", caps: caps)))
        _ = broker.apply(.message(.hotkeyDown, from: "mac"))
        if voiceCommandMode { _ = broker.apply(.message(.voiceCommandMode(), from: "mac")) }
        _ = broker.apply(.message(.hotkeyUp(reason: .key), from: "mac"))
        _ = broker.apply(.releaseGraceFired("s1"))
        now = 1
        return broker
    }

    func testVoiceCommandModeIsRememberedOnlyWhenSent() {
        XCTAssertEqual(brokerAtProcessing(voiceCommandMode: true).session?.voiceCommandMode, true)
        XCTAssertEqual(brokerAtProcessing(voiceCommandMode: false).session?.voiceCommandMode, false)
    }

    private func recordingBroker() -> SessionBroker {
        let broker = SessionBroker(coreId: "core", clock: { 0 }, makeSessionID: { "s1" })
        let caps = EdgeCapabilities(hasMic: true, inputDeviceUID: "u", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
        _ = broker.apply(.edgeConnected(BrokerEdgeInfo(id: "mac", name: "mac", caps: caps)))
        _ = broker.apply(.edgeConnected(BrokerEdgeInfo(id: "other", name: "other", caps: caps)))
        _ = broker.apply(.message(.hotkeyDown, from: "mac"))
        return broker
    }

    func testChordTellsEveryMacSoTheIndicatorCanChange() {
        let broker = recordingBroker()
        let effects = broker.apply(.message(.voiceCommandMode(), from: "mac"))
        let told = effects.compactMap { effect -> (EdgeID, SessionStateUpdate)? in
            if case .send(let edge, .sessionState(let update)) = effect { return (edge, update) }
            return nil
        }
        XCTAssertEqual(told.map(\.0), ["mac", "other"])
        XCTAssertTrue(told.allSatisfy { $0.1.state == .recording && $0.1.voiceCommandMode == true })
    }

    func testChordIsAnnouncedOnce() {
        let broker = recordingBroker()
        _ = broker.apply(.message(.voiceCommandMode(), from: "mac"))
        XCTAssertTrue(broker.apply(.message(.voiceCommandMode(), from: "mac")).isEmpty)
    }

    func testPlainRecordingSaysNothingAboutVoiceLaunch() throws {
        let broker = SessionBroker(coreId: "core", clock: { 0 }, makeSessionID: { "s1" })
        let caps = EdgeCapabilities(hasMic: true, inputDeviceUID: "u", accessibility: true, inputMonitoring: true, hotkeyMode: "intercept")
        _ = broker.apply(.edgeConnected(BrokerEdgeInfo(id: "mac", name: "mac", caps: caps)))
        let effects = broker.apply(.message(.hotkeyDown, from: "mac"))
        let update = try XCTUnwrap(effects.lazy.compactMap { effect -> SessionStateUpdate? in
            if case .send(_, .sessionState(let update)) = effect { return update }
            return nil
        }.first)
        XCTAssertNil(update.voiceCommandMode)
    }

    func testSessionUpdateFromAnOlderMainMacStillDecodes() throws {
        let json = #"{"sessionId":"s1","state":"recording","initiator":"mac"}"#
        let update = try JSONDecoder().decode(SessionStateUpdate.self, from: Data(json.utf8))
        XCTAssertNil(update.voiceCommandMode)
    }

    @MainActor
    func testIndicatorModelClearsVoiceLaunchWhenTheRecordingEnds() {
        let model = WalkieTalkieIndicatorModel()
        XCTAssertFalse(model.hasLabel)
        model.voiceLaunch = true
        XCTAssertTrue(model.hasLabel)
        model.setProcessing()
        XCTAssertFalse(model.voiceLaunch)
        XCTAssertFalse(model.hasLabel)
        model.setRecording()
        model.voiceLaunch = true
        model.reset()
        XCTAssertFalse(model.voiceLaunch)
    }

    func testVoiceCommandModeAfterReleaseIsIgnored() {
        let broker = brokerAtProcessing(voiceCommandMode: false)
        _ = broker.apply(.message(.voiceCommandMode(), from: "mac"))
        XCTAssertEqual(broker.session?.voiceCommandMode, false)
    }

    func testMatchedPlanGoesOutAsALaunchInsertEvenWithNoWords() throws {
        let broker = brokerAtProcessing(voiceCommandMode: true)
        let plan = try XCTUnwrap(rendered("youtube", link("yt", "YouTube {q}", "https://x.test/?q={q}")))
        XCTAssertEqual(plan.mainText, "")
        broker.attachLaunch(plan, sessionId: "s1")
        let effects = broker.apply(.transcriptionFinished("s1", text: "", inferenceMs: nil, error: nil))
        XCTAssertTrue(effects.contains(.send("mac", .launchInsert(sessionId: "s1", plan: plan))))
    }

    func testNoMatchNoticeStillUsesTheFirstMessage() {
        let broker = brokerAtProcessing(voiceCommandMode: true)
        broker.attachVoiceCommand(VoiceCommandDelivery(text: "", notice: "n"), sessionId: "s1")
        let effects = broker.apply(.transcriptionFinished("s1", text: "hello", inferenceMs: nil, error: nil))
        XCTAssertTrue(effects.contains(.send("mac", .voiceCommandInsert(sessionId: "s1", delivery: VoiceCommandDelivery(text: "hello", notice: "n")))))
    }

    func testPlainSessionStillGetsAPlainInsert() {
        let broker = brokerAtProcessing(voiceCommandMode: false)
        let effects = broker.apply(.transcriptionFinished("s1", text: "hello", inferenceMs: nil, error: nil))
        XCTAssertTrue(effects.contains(.send("mac", .insert(sessionId: "s1", text: "hello"))))
        let empty = brokerAtProcessing(voiceCommandMode: false)
        XCTAssertEqual(empty.apply(.transcriptionFinished("s1", text: "", inferenceMs: nil, error: nil)).contains(.send("mac", .insert(sessionId: "s1", text: ""))), false)
    }

    // MARK: Same words, different slot names

    func testPatternsThatHearTheSameWordsAreRejectedWhateverTheSlotNames() throws {
        let a = link("YouTube", "YouTube {query}", "https://www.youtube.com/results?search_query={query}")
        let b = link("Videos", "youtube {search}", "https://www.youtube.com/results?search_query={search}")
        let problem = try XCTUnwrap(config([a, b]).validate())
        XCTAssertTrue(problem.contains("“Videos”") && problem.contains("“YouTube”"), problem)
        let c = link("Text", "WhatsApp {who:People} {message}", "whatsapp://send?phone={who.phone}&text={message}")
        let d = link("Text 2", "WhatsApp {person:People} {words}", "whatsapp://send?phone={person.phone}&text={words}")
        XCTAssertNotNil(config([c, d]).validate(), "renamed list and text slots")
        let e = link("Projects", "WhatsApp {person:Projects} {words}", "whatsapp://send?text={words}")
        XCTAssertNil(config([c, e]).validate(), "a different list is heard differently")
        let f = link("Search more", "YouTube [please] {query}", "https://www.youtube.com/results?search_query={query}")
        XCTAssertNil(config([a, f]).validate(), "an optional word changes what is heard")
    }

    // MARK: A detail the person doesn't have

    func testAMissingPhoneNumberStopsThePlanWithAPlainReason() {
        var list = people
        list.entries.append(VoiceListEntry(id: "n", names: ["Noa"], values: ["phone": " ", "email": "noa@example.com"]))
        let wa = link("wa", "WhatsApp {person:People} {message}", "whatsapp://send?phone={person.phone}&text={message}")
        let config = VoiceLaunchConfig(lists: [list, projects], commands: [wa])
        guard case .plan(let missing) = VoiceLaunchEngine.plan(for: "WhatsApp Noa hello", in: config) else { return XCTFail("no plan") }
        XCTAssertEqual(missing.missingDetail, "Noa doesn’t have a phone number yet")
        guard case .plan(let fine) = VoiceLaunchEngine.plan(for: "WhatsApp Dana hello", in: config) else { return XCTFail("no plan") }
        XCTAssertNil(fine.missingDetail)
        // A detail no step uses doesn't matter: יוסי has no email.
        guard case .plan(let other) = VoiceLaunchEngine.plan(for: "WhatsApp יוסי hello", in: config) else { return XCTFail("no plan") }
        XCTAssertNil(other.missingDetail)
    }
}


extension VoiceLaunchTests {
    func testExactTargetNameNormalizationAndRefusal() {
        let names = ["ChatGPT.app", "T3 Code (Beta)", "Résumé", "Safari", "Safari Technology Preview"]
        for (spoken, index) in [("chat gpt.", 0), ("T3 Code", 1), ("T3-Code (Beta).app", 1), ("resume!", 2), ("SAFARI", 3)] {
            XCTAssertEqual(VoiceNameResolver.matches(spoken, in: names), [index], spoken)
        }
        for spoken in ["chat", "Saf", "safary", "Technology Preview", "", " ... ", "(Beta)"] {
            XCTAssertTrue(VoiceNameResolver.matches(spoken, in: names).isEmpty, spoken)
        }
        XCTAssertEqual(VoiceNameResolver.matches("chat gpt", in: ["ChatGPT", "Chat GPT (Beta)"]), [0, 1])
        XCTAssertEqual(VoiceNameResolver.matches("Safari", in: ["Safari", "Safari"]), [0, 1])
        XCTAssertEqual(VoiceNameResolver.matches("כתיבה", in: ["כתיבה", "כתיבת"]), [0])
    }

    func testNamedStepsRenderValidateAndRoundTrip() {
        for kind in [VoiceStep.Kind.openApp, .runWorkspace] {
            let voiceCommand = VoiceCommand(name: "Named", pattern: "Go {name}", steps: [VoiceStep(kind: kind, text: "{name}")])
            let config = VoiceLaunchConfig(commands: [voiceCommand])
            XCTAssertNil(config.validate())
            guard case .plan(let plan) = VoiceLaunchEngine.plan(for: "Go Chat GPT.", in: config) else { return XCTFail() }
            XCTAssertEqual(plan.steps.first?.text, "Chat GPT.")
            XCTAssertEqual(VoiceLaunchConfig.decode(config.encoded()), config)
            var invalid = config
            invalid.commands[0].steps[0].text = "{absent}"
            XCTAssertNotNil(invalid.validate())
        }
        let fixed = VoiceStep(kind: .openApp, bundleId: "com.apple.Safari", text: "{ignored}")
        XCTAssertEqual(VoiceStepRenderer.templateFields(of: fixed), [:])
        XCTAssertEqual(VoiceStepRenderer.render(fixed, context: .init()), fixed)
        XCTAssertNil(VoiceLaunchConfig.decode(#"{"version":2,"lists":[],"shortcuts":[{"id":"x","name":"X","enabled":true,"pattern":"X","steps":[{"kind":"futureUnknownKind"}]}]}"#), "Kind decoding stays strict")
    }

    func testNamedStepsCanUseEarlierVoiceCommandAnswers() {
        for kind in [VoiceStep.Kind.openApp, .runWorkspace] {
            let original = VoiceStep(kind: kind, text: "{answer_name}")
            XCTAssertTrue(VoiceStepRenderer.needsDeferral(original))
            let deferred = VoiceStepRenderer.deferring(original, slots: [], cleanUpSlot: nil, said: "Go")
            XCTAssertEqual(deferred.text, "")
            XCTAssertEqual(VoiceStepRenderer.resolve(deferred, answers: ["answer_name": .text("Writing")], mac: "Target").text, "Writing")
        }
    }

    func testAppHintsFollowVoiceCommandWordsAndRespectLimit() {
        let config = VoiceLaunchConfig(commands: [VoiceCommand(name: "Open", pattern: "Open {app}", steps: [VoiceStep(kind: .openApp, text: "{app}")])])
        XCTAssertEqual(VoiceLaunchEngine.hintWords(config, appNames: ["Safari", "ChatGPT", "safari"], limit: 3), ["Open", "Safari", "ChatGPT"])
        XCTAssertEqual(VoiceLaunchEngine.hintWords(config, appNames: ["Safari"], limit: 1), ["Open"])
        XCTAssertEqual(VoiceLaunchEngine.hintWords(config, appNames: ["Safari"], limit: 0), [])
    }

    func testInstalledAppEnumerationIsShallowAndDeduplicatesRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Safari.app", "Utilities/Monitor.app", "Vendor/ChatGPT.app", "Vendor/Deep/Hidden.app", "Safari.app/Contents/Nested.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let apps = VoiceInstalledApps.scan(roots: [root, root.appendingPathComponent("Utilities"), root.appendingPathComponent("Missing")])
        XCTAssertEqual(apps.map(\.name), ["ChatGPT", "Monitor", "Safari"])
        XCTAssertEqual(Set(apps.map(\.url)).count, 3)
    }
}
